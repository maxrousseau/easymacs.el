;;; easymacs-claude.el --- Claude Code integration for Easymacs -*- lexical-binding: t -*-

;;; Commentary:
;; Provides Claude Code integration with streaming output and diff review.
;; IRC-style message formatting for clean output.

;;; Code:

(require 'json)
(require 'diff)

;; Faces for colorized output
(defface easymacs-claude-header-face
  '((t :foreground "#61afef" :weight bold))
  "Face for session headers and separators.")

(defface easymacs-claude-user-face
  '((t :foreground "#98c379" :weight bold))
  "Face for user prompt labels.")

(defface easymacs-claude-assistant-face
  '((t :foreground "#c678dd" :weight bold))
  "Face for assistant labels.")

(defface easymacs-claude-tool-face
  '((t :foreground "#e5c07b"))
  "Face for tool usage messages.")

(defface easymacs-claude-file-face
  '((t :foreground "#56b6c2" :slant italic))
  "Face for file paths.")

(defface easymacs-claude-added-face
  '((t :foreground "#98c379"))
  "Face for added content in edits.")

(defface easymacs-claude-removed-face
  '((t :foreground "#e06c75"))
  "Face for removed content in edits.")

(defface easymacs-claude-error-face
  '((t :foreground "#e06c75" :weight bold))
  "Face for error messages.")

(defface easymacs-claude-summary-face
  '((t :foreground "#abb2bf" :slant italic))
  "Face for summary information.")

(defvar easymacs-claude-session-active nil
  "Non-nil when a Claude session has been started this Emacs session.")

(defvar easymacs-claude-after-edit-hook nil
  "Hook run after Claude finishes and the buffer is reverted.")

(defvar easymacs-claude--source-file nil
  "Source file for current Claude invocation.")

(defvar easymacs-claude--temp-file nil
  "Temp copy of source file before Claude edits.")

(defvar easymacs-claude--edits nil
  "List of edits made during current Claude session.")

(defvar easymacs-claude--spinner-frames '("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  "Frames for the spinner animation.")

(defvar easymacs-claude--spinner-index 0
  "Current frame index for spinner.")

(defvar easymacs-claude--spinner-timer nil
  "Timer for spinner animation.")

(defvar easymacs-claude--process-line-buffer nil
  "Alist mapping process to its incomplete JSON line buffer.")

(defvar easymacs-claude--queue nil
  "Queue of pending prompts to send to Claude.")

(defvar easymacs-claude--busy nil
  "Non-nil when Claude is currently processing a request.")

(defun easymacs-claude--spinner-start ()
  "Start the spinner animation in the Claude buffer header line."
  (easymacs-claude--spinner-stop)
  (when-let ((buf (get-buffer "*Claude*")))
    (with-current-buffer buf
      (setq header-line-format
            (propertize " ⠋ Claude is working..." 'face 'easymacs-claude-tool-face)))
    (setq easymacs-claude--spinner-index 0)
    (setq easymacs-claude--spinner-timer
          (run-with-timer 0 0.1 #'easymacs-claude--spinner-update))))

(defun easymacs-claude--spinner-update ()
  "Update the spinner animation frame."
  (when-let ((buf (get-buffer "*Claude*")))
    (when (buffer-live-p buf)
      (setq easymacs-claude--spinner-index
            (mod (1+ easymacs-claude--spinner-index)
                 (length easymacs-claude--spinner-frames)))
      (let ((frame (nth easymacs-claude--spinner-index easymacs-claude--spinner-frames)))
        (with-current-buffer buf
          (setq header-line-format
                (propertize (format " %s Claude is working..." frame)
                            'face 'easymacs-claude-tool-face)))))))

(defun easymacs-claude--spinner-stop ()
  "Stop the spinner animation and show idle status."
  (when easymacs-claude--spinner-timer
    (cancel-timer easymacs-claude--spinner-timer)
    (setq easymacs-claude--spinner-timer nil))
  (when-let ((buf (get-buffer "*Claude*")))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq header-line-format
              (propertize " ✓ Claude idle" 'face 'easymacs-claude-added-face))))))

(defun easymacs-claude--build-context ()
  "Build context string with current file and position."
  (format "File: %s\nLine: %d\nMode: %s"
          (or buffer-file-name "unnamed buffer")
          (line-number-at-pos)
          major-mode))

(defun easymacs-claude--save-temp-copy ()
  "Save a temp copy of the current file for later diffing/reverting."
  (when buffer-file-name
    ;; Clean up previous temp file if it exists
    (when (and easymacs-claude--temp-file
               (file-exists-p easymacs-claude--temp-file))
      (delete-file easymacs-claude--temp-file))
    (let* ((ext (file-name-extension buffer-file-name))
           (suffix (if ext (concat "." ext) ""))
           (temp-file (make-temp-file "claude-backup-" nil suffix)))
      (copy-file buffer-file-name temp-file t)
      (setq easymacs-claude--temp-file temp-file)
      (setq easymacs-claude--edits nil))))

(defun easymacs-claude--files-differ-p (file1 file2)
  "Return t if FILE1 and FILE2 have different contents."
  (not (string= (with-temp-buffer
                  (insert-file-contents file1)
                  (buffer-string))
                (with-temp-buffer
                  (insert-file-contents file2)
                  (buffer-string)))))

(defun easymacs-claude--show-diff ()
  "Show diff between temp copy and current file below the Claude buffer."
  (when (and easymacs-claude--temp-file
             easymacs-claude--source-file
             (file-exists-p easymacs-claude--temp-file)
             (file-exists-p easymacs-claude--source-file))
    ;; Revert the source buffer to show changes
    (let ((buf (find-buffer-visiting easymacs-claude--source-file)))
      (when buf
        (with-current-buffer buf
          (revert-buffer t t t))))
    ;; Only show diff if files actually differ
    (if (easymacs-claude--files-differ-p easymacs-claude--temp-file
                                          easymacs-claude--source-file)
        (let* ((diff-buf-name "*Claude Diff*")
               (existing-buf (get-buffer diff-buf-name))
               (existing-win (when existing-buf (get-buffer-window existing-buf t)))
               (diff-buf (diff-no-select easymacs-claude--temp-file
                                          easymacs-claude--source-file
                                          nil 'noasync))
               (claude-win (get-buffer-window "*Claude*")))
          (when diff-buf
            ;; Rename to our consistent buffer name
            (when existing-buf
              (kill-buffer existing-buf))
            (with-current-buffer diff-buf
              (rename-buffer diff-buf-name))
            ;; Reuse existing window or create new one
            (if existing-win
                (set-window-buffer existing-win diff-buf)
              (if claude-win
                  (with-selected-window claude-win
                    (let ((diff-win (split-window-below)))
                      (set-window-buffer diff-win diff-buf)))
                (display-buffer diff-buf '(display-buffer-reuse-window
                                           display-buffer-pop-up-window))))))
      ;; No diff - delete the window and kill the buffer if they exist
      (when-let ((existing-buf (get-buffer "*Claude Diff*")))
        (when-let ((win (get-buffer-window existing-buf t)))
          (delete-window win))
        (kill-buffer existing-buf)))))

(defun easymacs-claude--insert (text &optional face)
  "Insert TEXT into the Claude output buffer with optional FACE."
  (when-let ((buf (get-buffer "*Claude*")))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (goto-char (point-max))
        (if face
            (insert (propertize text 'face face))
          (insert text)))
      ;; Scroll window to show new content
      (when-let ((win (get-buffer-window buf t)))
        (with-selected-window win
          (goto-char (point-max))
          (recenter -1))))))

(defun easymacs-claude--handle-tool-use (item)
  "Handle a tool_use ITEM and display it."
  (let ((tool-name (alist-get 'name item))
        (input (alist-get 'input item)))
    (cond
     ((equal tool-name "Read")
      (let ((file-path (alist-get 'file_path input)))
        (easymacs-claude--insert " * " 'easymacs-claude-tool-face)
        (easymacs-claude--insert "read " 'easymacs-claude-tool-face)
        (easymacs-claude--insert (file-name-nondirectory (or file-path "?")) 'easymacs-claude-file-face)
        (easymacs-claude--insert "\n")))
     ((equal tool-name "Edit")
      (let ((file (or (alist-get 'file_path input) "unknown"))
            (old-str (alist-get 'old_string input))
            (new-str (alist-get 'new_string input)))
        (push (list file old-str new-str) easymacs-claude--edits)
        (easymacs-claude--insert " * " 'easymacs-claude-tool-face)
        (easymacs-claude--insert "edit " 'easymacs-claude-tool-face)
        (easymacs-claude--insert (file-name-nondirectory file) 'easymacs-claude-file-face)
        (easymacs-claude--insert "\n")))
     ((equal tool-name "Write")
      (let ((file-path (alist-get 'file_path input)))
        (easymacs-claude--insert " * " 'easymacs-claude-tool-face)
        (easymacs-claude--insert "write " 'easymacs-claude-tool-face)
        (easymacs-claude--insert (file-name-nondirectory (or file-path "?")) 'easymacs-claude-file-face)
        (easymacs-claude--insert "\n")))
     (t
      (easymacs-claude--insert (format " * %s\n" (downcase tool-name)) 'easymacs-claude-tool-face)))))

(defun easymacs-claude--handle-assistant (json)
  "Handle an assistant message JSON."
  (let* ((message (alist-get 'message json))
         (content (alist-get 'content message)))
    (when (vectorp content)
      (seq-doseq (item content)
        (let ((item-type (alist-get 'type item)))
          (cond
           ((equal item-type "text")
            (let ((text (alist-get 'text item)))
              (easymacs-claude--insert text)
              (unless (string-suffix-p "\n" text)
                (easymacs-claude--insert "\n"))))
           ((equal item-type "tool_use")
            (easymacs-claude--handle-tool-use item))))))))

(defun easymacs-claude--get-line-buffer (proc)
  "Get the line buffer for PROC, creating if needed."
  (or (alist-get proc easymacs-claude--process-line-buffer)
      ""))

(defun easymacs-claude--set-line-buffer (proc value)
  "Set the line buffer for PROC to VALUE."
  (setf (alist-get proc easymacs-claude--process-line-buffer) value))

(defun easymacs-claude--process-json-line (line)
  "Process a single JSON LINE and display appropriate output."
  (condition-case nil
      (let* ((json (json-parse-string line :object-type 'alist))
             (type (alist-get 'type json))
             (subtype (alist-get 'subtype json)))
        (cond
         ;; Content block delta (streaming text)
         ((equal type "content_block_delta")
          (let* ((delta (alist-get 'delta json))
                 (delta-type (alist-get 'type delta)))
            (when (equal delta-type "text_delta")
              (easymacs-claude--insert (alist-get 'text delta)))))
         ;; Init message
         ((and (equal type "system") (equal subtype "init"))
          (easymacs-claude--insert
           (format "-- %s | %s --\n"
                   (alist-get 'session_id json)
                   (alist-get 'model json))
           'easymacs-claude-header-face))
         ;; Assistant message
         ((equal type "assistant")
          (easymacs-claude--handle-assistant json))
         ;; Tool result errors
         ((equal type "user")
          (let ((content (alist-get 'content (alist-get 'message json))))
            (when (vectorp content)
              (seq-doseq (item content)
                (when (and (equal (alist-get 'type item) "tool_result")
                           (alist-get 'is_error item))
                  (easymacs-claude--insert
                   (format " [err: %s]\n" (alist-get 'content item))
                   'easymacs-claude-error-face))))))
         ;; Result summary
         ((equal type "result")
          (let ((cost (alist-get 'total_cost_usd json))
                (turns (alist-get 'num_turns json))
                (edits (length easymacs-claude--edits))
                (files (length (seq-uniq (mapcar #'car easymacs-claude--edits)))))
            (easymacs-claude--insert
             (format "-- %s turn(s) | $%.4f%s --\n"
                     turns
                     (or cost 0)
                     (if (> edits 0)
                         (format " | %d edit(s) in %d file(s)" edits files)
                       ""))
             'easymacs-claude-summary-face))))
        t) ; return t on success
    (error nil))) ; return nil on parse error

(defun easymacs-claude--filter (proc output)
  "Filter PROC OUTPUT to extract and display Claude's process."
  ;; Append new output to process-local buffer
  (let* ((line-buf (easymacs-claude--get-line-buffer proc))
         (combined (concat line-buf output))
         (lines (split-string combined "\n")))
    ;; Keep the last (possibly incomplete) line in the buffer
    (easymacs-claude--set-line-buffer proc (car (last lines)))
    ;; Process all complete lines (all but the last)
    (dolist (line (butlast lines))
      (when (> (length line) 0)
        (easymacs-claude--process-json-line line)))))

(defun easymacs-claude--sentinel (proc event)
  "Handle Claude PROC completion EVENT."
  (when (string-match-p "finished\\|exited\\|killed" event)
    ;; Process any remaining content in the line buffer
    (let ((remaining (easymacs-claude--get-line-buffer proc)))
      (when (> (length remaining) 0)
        (easymacs-claude--process-json-line remaining))
      ;; Clean up process from alist
      (setq easymacs-claude--process-line-buffer
            (assq-delete-all proc easymacs-claude--process-line-buffer)))
    (easymacs-claude--spinner-stop)
    (setq easymacs-claude-session-active t)
    (setq easymacs-claude--busy nil)
    (easymacs-claude--show-diff)
    (run-hooks 'easymacs-claude-after-edit-hook)
    ;; Process next item in queue if any
    (easymacs-claude--process-queue)))

(defun easymacs-claude--run-prompt (prompt source-file)
  "Actually run PROMPT for SOURCE-FILE. Internal function."
  (let* ((source-buf (find-buffer-visiting source-file))
         (context (format "File: %s\nLine: %d\nMode: %s"
                          source-file
                          (if source-buf
                              (with-current-buffer source-buf (line-number-at-pos))
                            1)
                          (if source-buf
                              (with-current-buffer source-buf major-mode)
                            'fundamental-mode)))
         (full-prompt (concat context "\n---\n" prompt))
         (output-buffer (get-buffer-create "*Claude*"))
         (allowed-tools (format "Edit:%s Read Glob Grep Task WebSearch WebFetch" source-file))
         (quoted-prompt (shell-quote-argument full-prompt))
         (quoted-tools (shell-quote-argument allowed-tools))
         (cmd (format "claude -p %s --allowedTools %s --permission-mode acceptEdits --output-format stream-json --verbose%s"
                      quoted-prompt
                      quoted-tools
                      (if easymacs-claude-session-active " -c" ""))))
    (setq easymacs-claude--source-file source-file)
    (setq easymacs-claude--busy t)
    (with-current-buffer output-buffer
      (goto-char (point-max))
      (insert (propertize "<you> " 'face 'easymacs-claude-user-face))
      (insert prompt)
      (insert (propertize "\n<claude> " 'face 'easymacs-claude-assistant-face)))
    (let ((claude-win (get-buffer-window output-buffer t)))
      (unless claude-win
        ;; Not visible, split once to the right
        (setq claude-win (split-window nil nil 'right))
        (set-window-buffer claude-win output-buffer))
      ;; Scroll to end
      (with-selected-window claude-win
        (goto-char (point-max))))
    (easymacs-claude--spinner-start)
    (condition-case err
        (let ((proc (start-process-shell-command "claude" nil cmd)))
          (set-process-filter proc #'easymacs-claude--filter)
          (set-process-sentinel proc #'easymacs-claude--sentinel))
      (error
       (setq easymacs-claude--busy nil)
       (easymacs-claude--spinner-stop)
       (easymacs-claude--insert
        (format "\n[Failed to start Claude: %s]\n" (error-message-string err))
        'easymacs-claude-error-face)))))

(defun easymacs-claude--process-queue ()
  "Process the next item in the queue if not busy."
  (when (and (not easymacs-claude--busy)
             easymacs-claude--queue)
    (let ((item (pop easymacs-claude--queue)))
      (easymacs-claude--run-prompt (car item) (cdr item)))))

(defun easymacs-claude (prompt)
  "Send PROMPT to Claude with file context. Continues session if one exists.
If Claude is busy, the prompt is queued and will run when idle."
  (interactive "sClaude: ")
  (unless buffer-file-name
    (user-error "Buffer must be visiting a file"))
  (save-buffer)
  (easymacs-claude--save-temp-copy)
  (let ((source-file buffer-file-name))
    (if easymacs-claude--busy
        (progn
          (setq easymacs-claude--queue
                (append easymacs-claude--queue (list (cons prompt source-file))))
          (message "Claude is busy. Prompt queued (%d in queue)."
                   (length easymacs-claude--queue)))
      (easymacs-claude--run-prompt prompt source-file))))

(defun easymacs-claude-newsession ()
  "Start a fresh Claude session (next call won't use -c)."
  (interactive)
  (setq easymacs-claude-session-active nil)
  (setq easymacs-claude--edits nil)
  (message "Claude session reset. Next call starts fresh."))

(defun easymacs-claude-revert ()
  "Revert current file to the state before Claude's edits."
  (interactive)
  (if (and easymacs-claude--temp-file
           (file-exists-p easymacs-claude--temp-file)
           easymacs-claude--source-file)
      (when (y-or-n-p "Revert file to pre-Claude state? ")
        (copy-file easymacs-claude--temp-file easymacs-claude--source-file t)
        (let ((buf (find-buffer-visiting easymacs-claude--source-file)))
          (when buf
            (with-current-buffer buf
              (revert-buffer t t t))))
        (message "Reverted to pre-Claude state."))
    (user-error "No Claude backup available for this file")))

(provide 'easymacs-claude)
;;; easymacs-claude.el ends here
