;;; easymacs-claude.el --- Claude Code integration for Easymacs -*- lexical-binding: t -*-

(require 'diff)
(require 'json)
(require 'subr-x)
(require 'easymacs-claude-review)

(defmacro easymacs-claude--define-faces (&rest specs)
  "Define easymacs-claude faces from SPECS."
  `(progn ,@(mapcar (lambda (spec) `(defface ,@spec)) specs)))

(easymacs-claude--define-faces
  (easymacs-claude-header-face '((t :foreground "#61afef" :weight bold))
                               "Face for session headers and separators.")
  (easymacs-claude-user-face '((t :foreground "#98c379" :weight bold))
                             "Face for user prompt labels.")
  (easymacs-claude-assistant-face '((t :foreground "#c678dd" :weight bold))
                                  "Face for assistant labels.")
  (easymacs-claude-tool-face '((t :foreground "#e5c07b"))
                             "Face for tool usage messages.")
  (easymacs-claude-file-face '((t :foreground "#56b6c2" :slant italic))
                             "Face for file paths.")
  (easymacs-claude-added-face '((t :foreground "#98c379"))
                              "Face for added content in edits.")
  (easymacs-claude-removed-face '((t :foreground "#e06c75"))
                                "Face for removed content in edits.")
  (easymacs-claude-error-face '((t :foreground "#e06c75" :weight bold))
                              "Face for error messages.")
  (easymacs-claude-summary-face '((t :foreground "#abb2bf" :slant italic))
                                "Face for summary information.")
  (easymacs-claude-ghost-face '((t :inherit shadow :slant italic))
                              "Face for inline ghost text overlay."))

(defcustom easymacs-claude-display-mode 'inline
  "How to display Claude's response.
`buffer' shows output in a side *Claude* buffer.
`inline' shows output as ghost text overlay at the invocation point (default)."
  :type '(choice (const :tag "Side buffer" buffer)
                 (const :tag "Inline ghost text" inline))
  :group 'easymacs)

(defvar easymacs-claude-session-active nil
  "Non-nil when a Claude session has been started this Emacs session.")
(defvar easymacs-claude-after-edit-hook nil
  "Hook run after Claude finishes and the buffer is reverted.")
(defvar easymacs-claude--source-file nil "Source file for current Claude invocation.")
(defvar easymacs-claude--temp-file nil "Temp copy of source file before Claude edits.")
(defvar easymacs-claude--run-root nil
  "Directory used to resolve relative file paths for the active run.")
(defvar easymacs-claude--run-backups nil
  "Alist mapping edited files to pre-Claude temp backups for the active run.")
(defvar easymacs-claude--last-run-backups nil
  "Alist mapping edited files to pre-Claude temp backups from the last run.")
(defvar easymacs-claude--run-file-exists nil
  "Alist mapping edited files to whether they existed before the active run.")
(defvar easymacs-claude--last-run-file-exists nil
  "Alist mapping edited files to whether they existed before the last run.")
(defvar easymacs-claude--edits nil "List of edits made during current Claude session.")
(defconst easymacs-claude--spinner-frames
  '("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
  "Frames for the spinner animation.")
(defvar easymacs-claude--spinner-index 0 "Current frame index for spinner.")
(defvar easymacs-claude--spinner-timer nil "Timer for spinner animation.")
(defvar easymacs-claude--process-line-buffer nil
  "Alist mapping process to its incomplete JSON line buffer.")
(defvar easymacs-claude--queue nil "Queue of pending prompts to send to Claude.")
(defvar easymacs-claude--busy nil "Non-nil when Claude is currently processing a request.")
(defvar easymacs-claude--paused nil "Non-nil when Claude process is suspended (SIGSTOP).")
(defvar easymacs-claude--inline-overlay nil "Overlay used for inline ghost text display.")
(defvar easymacs-claude--inline-buffer nil "The source buffer where inline ghost text should appear.")
(defvar easymacs-claude--inline-point nil
  "The buffer position where the invocation happened (overlay anchor).")
(defvar easymacs-claude--inline-text "" "Accumulated streaming text for the inline overlay.")
(defvar easymacs-claude--inline-spinner-timer nil "Timer for the inline spinner animation.")
(defvar easymacs-claude--inline-spinner-index 0 "Current frame index for the inline spinner.")
(defvar easymacs-claude--inline-status nil "Current status message shown in the inline spinner.")
(defvar easymacs-claude--inline-hidden nil "Non-nil when inline ghost text is hidden.")
(defvar easymacs-claude--last-summary nil "Summary string from the last completed Claude result.")
(defun easymacs-claude--insert (text &optional face)
  "Insert TEXT into the Claude output buffer with optional FACE."
  (when-let ((buf (get-buffer "*Claude*")))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (goto-char (point-max))
        (insert (if face (propertize text 'face face) text)))
      (when-let ((win (get-buffer-window buf t)))
        (with-selected-window win
          (goto-char (point-max))
          (recenter -1))))))
(defun easymacs-claude--append-inline (text)
  "Append TEXT to inline transcript and refresh full inline status."
  (setq easymacs-claude--inline-text (concat easymacs-claude--inline-text text))
  (unless (string-empty-p easymacs-claude--inline-text)
    (setq easymacs-claude--inline-status easymacs-claude--inline-text)))
(defun easymacs-claude--normalize-file-path (file)
  "Return FILE as an absolute path resolved from `easymacs-claude--run-root'."
  (when (and (stringp file) (not (string-empty-p file)))
    (expand-file-name file easymacs-claude--run-root)))
(defun easymacs-claude--cleanup-backups (backups)
  "Delete temp backup files listed in BACKUPS."
  (dolist (entry backups)
    (when-let ((temp-file (cdr entry)))
      (when (file-exists-p temp-file)
        (delete-file temp-file)))))
(defun easymacs-claude--track-file (file)
  "Ensure FILE has a pre-edit temp backup and return the normalized path."
  (when-let ((path (easymacs-claude--normalize-file-path file)))
    (unless (assoc path easymacs-claude--run-backups)
      (let* ((ext (file-name-extension path))
             (suffix (if ext (concat "." ext) ""))
             (temp-file (make-temp-file "claude-backup-" nil suffix))
             (existed-before (file-exists-p path)))
        (if existed-before
            (copy-file path temp-file t)
          (with-temp-file temp-file))
        (push (cons path temp-file) easymacs-claude--run-backups)
        (push (cons path existed-before) easymacs-claude--run-file-exists)))
    path))
(defun easymacs-claude--prepare-run-state (source-file)
  "Reset run state and capture initial backup for SOURCE-FILE."
  (easymacs-claude--cleanup-backups easymacs-claude--last-run-backups)
  (setq easymacs-claude--last-run-backups nil
        easymacs-claude--last-run-file-exists nil
        easymacs-claude--run-backups nil
        easymacs-claude--run-file-exists nil
        easymacs-claude--edits nil
        easymacs-claude--run-root (file-name-directory source-file)
        easymacs-claude--source-file source-file
        easymacs-claude--temp-file nil)
  (when-let ((tracked (easymacs-claude--track-file source-file)))
    (setq easymacs-claude--source-file tracked
          easymacs-claude--temp-file (cdr (assoc tracked easymacs-claude--run-backups)))))
(defun easymacs-claude--backup-for-file (file)
  "Return the most recent backup path for FILE, or nil if unavailable."
  (cdr (assoc (expand-file-name file)
              (or easymacs-claude--last-run-backups
                  easymacs-claude--run-backups))))
(defun easymacs-claude--file-existed-before-p (file)
  "Return whether FILE existed before the tracked run, or `unknown'."
  (let* ((path (expand-file-name file))
         (cell (assoc path
                      (or easymacs-claude--last-run-file-exists
                          easymacs-claude--run-file-exists))))
    (if cell
        (cdr cell)
      'unknown)))
(defun easymacs-claude--inline-create-overlay ()
  "Create the ghost text overlay at `easymacs-claude--inline-point'."
  (easymacs-claude--inline-delete-overlay)
  (when-let ((buf easymacs-claude--inline-buffer)
             ((buffer-live-p buf))
             (pt easymacs-claude--inline-point))
    (with-current-buffer buf
      (let* ((bol (save-excursion (goto-char pt) (line-beginning-position)))
             (ov (make-overlay bol bol)))
        (overlay-put ov 'easymacs-claude-inline t)
        (overlay-put ov 'priority 100)
        (overlay-put ov 'easymacs-claude-hidden nil)
        (setq easymacs-claude--inline-hidden nil)
        (setq easymacs-claude--inline-overlay ov)))))
(defun easymacs-claude--inline-update ()
  "Update the inline ghost overlay with the latest status."
  (when-let ((ov easymacs-claude--inline-overlay)
             ((overlay-buffer ov))
             ((not (overlay-get ov 'easymacs-claude-hidden))))
    (let* ((frame (nth easymacs-claude--inline-spinner-index
                       easymacs-claude--spinner-frames))
           (status (or easymacs-claude--inline-status "Claude is thinking..."))
           (display-text (propertize (format "%s %s\n" frame status)
                                     'face 'easymacs-claude-ghost-face)))
      (overlay-put ov 'before-string display-text))))
(defun easymacs-claude--inline-delete-overlay ()
  "Remove the inline ghost text overlay."
  (when easymacs-claude--inline-overlay
    (delete-overlay easymacs-claude--inline-overlay)
    (setq easymacs-claude--inline-overlay nil
          easymacs-claude--inline-hidden nil)))
(defun easymacs-claude--inline-dismiss ()
  "Dismiss the inline ghost text overlay."
  (interactive)
  (easymacs-claude--inline-delete-overlay)
  (easymacs-claude--inline-spinner-stop))
(defun easymacs-claude--inline-spinner-start ()
  "Start an inline spinner as ghost text at the invocation point."
  (easymacs-claude--inline-spinner-stop)
  (easymacs-claude--inline-create-overlay)
  (setq easymacs-claude--inline-spinner-index 0
        easymacs-claude--inline-text ""
        easymacs-claude--inline-status nil
        easymacs-claude--inline-hidden nil)
  (setq easymacs-claude--inline-spinner-timer
        (run-with-timer 0 0.1 #'easymacs-claude--inline-spinner-update)))
(defun easymacs-claude--inline-spinner-update ()
  "Update the inline spinner animation frame and refresh overlay."
  (when (and easymacs-claude--inline-overlay
             (overlay-buffer easymacs-claude--inline-overlay))
    (setq easymacs-claude--inline-spinner-index
          (mod (1+ easymacs-claude--inline-spinner-index)
               (length easymacs-claude--spinner-frames)))
    (easymacs-claude--inline-update)))
(defun easymacs-claude--inline-spinner-stop ()
  "Stop the inline spinner timer."
  (when easymacs-claude--inline-spinner-timer
    (cancel-timer easymacs-claude--inline-spinner-timer)
    (setq easymacs-claude--inline-spinner-timer nil)))
(defun easymacs-claude--inline-final-display ()
  "Return finalized inline text for the ghost overlay."
  (let* ((summary (or easymacs-claude--last-summary "finished"))
         (response easymacs-claude--inline-text)
         (display-text (if (string-empty-p response)
                           (format "✓ %s" summary)
                         (concat "✓ " response)))
         (suffix (if (string-suffix-p "\n" display-text) "" "\n")))
    (propertize (concat display-text suffix) 'face 'easymacs-claude-ghost-face)))
(defun easymacs-claude--inline-show-final ()
  "Show the finalized inline output when a run is complete."
  (when-let ((ov easymacs-claude--inline-overlay)
             ((overlay-buffer ov))
             ((not (overlay-get ov 'easymacs-claude-hidden))))
    (overlay-put ov 'before-string (easymacs-claude--inline-final-display))))
(defun easymacs-claude-toggle-inline-ghost-text ()
  "Toggle visibility of the current inline Claude ghost text."
  (interactive)
  (if (not (eq easymacs-claude-display-mode 'inline))
      (message "Claude display mode is %s (switch to inline to toggle ghost text)."
               easymacs-claude-display-mode)
    (if (not (and easymacs-claude--inline-overlay
                  (overlay-buffer easymacs-claude--inline-overlay)))
        (message "No inline Claude ghost text to toggle.")
      (setq easymacs-claude--inline-hidden (not easymacs-claude--inline-hidden))
      (overlay-put easymacs-claude--inline-overlay
                   'easymacs-claude-hidden
                   easymacs-claude--inline-hidden)
      (if easymacs-claude--inline-hidden
          (progn
            (overlay-put easymacs-claude--inline-overlay 'before-string nil)
            (message "Claude ghost text hidden."))
        (if easymacs-claude--busy
            (easymacs-claude--inline-update)
          (easymacs-claude--inline-show-final))
        (message "Claude ghost text shown.")))))
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
      (let ((frame (nth easymacs-claude--spinner-index
                        easymacs-claude--spinner-frames)))
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
(defun easymacs-claude--record-edit (verb file &optional old-string new-string)
  "Track a file edit action VERB for FILE and update edit accounting."
  (let ((tracked (easymacs-claude--track-file file)))
    (when tracked
      (push (list tracked old-string new-string) easymacs-claude--edits))
    (easymacs-claude--note-tool verb (or tracked file))))
(defun easymacs-claude--files-differ-p (file1 file2)
  "Return t if FILE1 and FILE2 have different contents."
  (not (string=
        (with-temp-buffer (insert-file-contents file1) (buffer-string))
        (with-temp-buffer (insert-file-contents file2) (buffer-string)))))
(defun easymacs-claude--show-diff ()
  "Show diff between temp copy and current file below the Claude buffer."
  (when (and easymacs-claude--temp-file
             easymacs-claude--source-file
             (file-exists-p easymacs-claude--temp-file)
             (file-exists-p easymacs-claude--source-file))
    (when-let ((buf (find-buffer-visiting easymacs-claude--source-file)))
      (with-current-buffer buf
        (revert-buffer t t t)))
    (if (easymacs-claude--files-differ-p easymacs-claude--temp-file
                                         easymacs-claude--source-file)
        (let* ((diff-buf-name "*Claude Diff*")
               (existing-buf (get-buffer diff-buf-name))
               (existing-win (and existing-buf (get-buffer-window existing-buf t)))
               (diff-buf (diff-no-select easymacs-claude--temp-file
                                         easymacs-claude--source-file
                                         nil 'noasync))
               (claude-win (get-buffer-window "*Claude*")))
          (when diff-buf
            (when existing-buf (kill-buffer existing-buf))
            (with-current-buffer diff-buf (rename-buffer diff-buf-name))
            (cond
             (existing-win (set-window-buffer existing-win diff-buf))
             (claude-win
              (with-selected-window claude-win
                (set-window-buffer (split-window-below) diff-buf)))
             (t
              (display-buffer diff-buf '(display-buffer-reuse-window
                                         display-buffer-pop-up-window))))))
      (when-let ((existing-buf (get-buffer "*Claude Diff*")))
        (when-let ((win (get-buffer-window existing-buf t)))
          (delete-window win))
        (kill-buffer existing-buf)))))
(defun easymacs-claude--note-tool (verb file)
  "Insert a tool usage line for VERB on FILE."
  (let ((short (file-name-nondirectory (or file "?"))))
    (easymacs-claude--insert " * " 'easymacs-claude-tool-face)
    (easymacs-claude--insert (format "%s " verb) 'easymacs-claude-tool-face)
    (easymacs-claude--insert short 'easymacs-claude-file-face)
    (easymacs-claude--insert "\n")
    (setq easymacs-claude--inline-status (format "%s %s..." verb short))))
(defun easymacs-claude--handle-tool-use (item)
  "Handle a tool_use ITEM and display it."
  (let ((tool-name (alist-get 'name item))
        (input (alist-get 'input item)))
    (pcase tool-name
      ("Read" (easymacs-claude--note-tool "read" (easymacs-claude--normalize-file-path
                                                 (alist-get 'file_path input))))
      ("Write" (easymacs-claude--record-edit "write" (alist-get 'file_path input)))
      ("Edit" (easymacs-claude--record-edit "edit"
                                            (alist-get 'file_path input)
                                            (alist-get 'old_string input)
                                            (alist-get 'new_string input)))
      ("MultiEdit"
       (let ((file (alist-get 'file_path input))
             (edits (alist-get 'edits input)))
         (if (and edits (vectorp edits))
             (dolist (edit (append edits nil))
               (easymacs-claude--record-edit "multiedit"
                                             file
                                             (alist-get 'old_string edit)
                                             (alist-get 'new_string edit)))
           (easymacs-claude--record-edit "multiedit" file))))
      (_ (let ((verb (downcase tool-name)))
           (easymacs-claude--insert (format " * %s\n" verb)
                                    'easymacs-claude-tool-face)
           (setq easymacs-claude--inline-status (format "%s..." verb)))))))
(defun easymacs-claude--emit-text (text &optional ensure-newline)
  "Emit TEXT and update inline status."
  (when text
    (easymacs-claude--insert text)
    (when (and ensure-newline (not (string-suffix-p "\n" text)))
      (easymacs-claude--insert "\n"))
    (easymacs-claude--append-inline text)))
(defun easymacs-claude--handle-assistant (json)
  "Handle an assistant message JSON."
  (let ((content (alist-get 'content (alist-get 'message json))))
    (when (vectorp content)
      (dolist (item (append content nil))
        (pcase (alist-get 'type item)
          ("text" (easymacs-claude--emit-text (alist-get 'text item) t))
          ("tool_use" (easymacs-claude--handle-tool-use item)))))))
(defun easymacs-claude--handle-user-errors (json)
  "Handle tool errors in a user JSON message."
  (let ((content (alist-get 'content (alist-get 'message json))))
    (when (vectorp content)
      (dolist (item (append content nil))
        (when (and (equal (alist-get 'type item) "tool_result")
                   (alist-get 'is_error item))
          (easymacs-claude--insert
           (format " [err: %s]\n" (alist-get 'content item))
           'easymacs-claude-error-face))))))
(defun easymacs-claude--handle-result (json)
  "Handle the final result JSON."
  (let* ((cost (alist-get 'total_cost_usd json))
         (turns (alist-get 'num_turns json))
         (edits (length easymacs-claude--edits))
         (files (length (delete-dups (mapcar #'car easymacs-claude--edits))))
         (summary (format "%s turn(s) | $%.4f%s"
                          turns
                          (or cost 0)
                          (if (> edits 0)
                              (format " | %d edit(s) in %d file(s)" edits files)
                            ""))))
    (setq easymacs-claude--last-summary summary)
    (easymacs-claude--insert
     (format "-- %s --\n" summary)
     'easymacs-claude-summary-face)))
(defun easymacs-claude--process-json-line (line)
  "Process a single JSON LINE and display appropriate output."
  (condition-case nil
      (let* ((json (json-parse-string line :object-type 'alist))
             (type (alist-get 'type json)))
        (pcase type
          ("content_block_delta"
           (let ((delta (alist-get 'delta json)))
             (when (equal (alist-get 'type delta) "text_delta")
               (easymacs-claude--emit-text (alist-get 'text delta)))))
          ("system"
           (when (equal (alist-get 'subtype json) "init")
             (easymacs-claude--insert
              (format "-- %s | %s --\n"
                      (alist-get 'session_id json)
                      (alist-get 'model json))
              'easymacs-claude-header-face)))
          ("assistant" (easymacs-claude--handle-assistant json))
          ("user" (easymacs-claude--handle-user-errors json))
          ("result" (easymacs-claude--handle-result json)))
        t)
    (error nil)))
(defun easymacs-claude--filter (proc output)
  "Filter PROC OUTPUT to extract and display Claude's process."
  (let* ((line-buf (or (alist-get proc easymacs-claude--process-line-buffer) ""))
         (combined (concat line-buf output))
         (lines (split-string combined "\n")))
    (setf (alist-get proc easymacs-claude--process-line-buffer) (car (last lines)))
    (dolist (line (butlast lines))
      (when (> (length line) 0)
        (easymacs-claude--process-json-line line)))))
(defun easymacs-claude--finalize-inline ()
  "Finalize inline overlay output when a run finishes."
  (when (and (eq easymacs-claude-display-mode 'inline)
             easymacs-claude--inline-overlay
             (overlay-buffer easymacs-claude--inline-overlay))
    (let ((summary (or easymacs-claude--last-summary "finished")))
      (easymacs-claude--inline-show-final)
      (message "Claude done [%s]. C-; C-g toggles ghost text." summary))))
(defun easymacs-claude--sentinel (proc event)
  "Handle Claude PROC completion EVENT."
  (when (string-match-p "finished\\|exited\\|killed" event)
    (let ((remaining (or (alist-get proc easymacs-claude--process-line-buffer) "")))
      (when (> (length remaining) 0)
        (easymacs-claude--process-json-line remaining))
      (setq easymacs-claude--process-line-buffer
            (assq-delete-all proc easymacs-claude--process-line-buffer)))
    (let ((run-backups (nreverse easymacs-claude--run-backups)))
      (setq easymacs-claude--last-run-backups run-backups
            easymacs-claude--run-backups nil))
    (let ((run-file-exists (nreverse easymacs-claude--run-file-exists)))
      (setq easymacs-claude--last-run-file-exists run-file-exists
            easymacs-claude--run-file-exists nil))
    (easymacs-claude--spinner-stop)
    (easymacs-claude--inline-spinner-stop)
    (setq easymacs-claude-session-active t
          easymacs-claude--busy nil
          easymacs-claude--paused nil)
    (easymacs-claude--finalize-inline)
    (if (fboundp 'easymacs-claude-review-after-run)
        (easymacs-claude-review-after-run easymacs-claude--last-run-backups)
      (easymacs-claude--show-diff))
    (run-hooks 'easymacs-claude-after-edit-hook)
    (easymacs-claude--process-queue)))
(defun easymacs-claude--run-prompt (prompt source-file)
  "Actually run PROMPT for SOURCE-FILE. Internal function."
  (setq source-file (expand-file-name source-file))
  (easymacs-claude--prepare-run-state source-file)
  (let* ((source-buf (find-buffer-visiting source-file))
         (line (if source-buf
                   (with-current-buffer source-buf (line-number-at-pos))
                 1))
         (mode (if source-buf
                   (with-current-buffer source-buf major-mode)
                 'fundamental-mode))
         (context (format "File: %s\nLine: %d\nMode: %s" source-file line mode))
         (full-prompt (concat context "\n---\n" prompt))
         (output-buffer (get-buffer-create "*Claude*"))
         (allowed-tools "Edit MultiEdit Write Read Glob Grep Task WebSearch WebFetch")
         (cmd (format "claude -p %s --allowedTools %s --permission-mode acceptEdits --output-format stream-json --verbose%s"
                      (shell-quote-argument full-prompt)
                      (shell-quote-argument allowed-tools)
                      (if easymacs-claude-session-active " -c" ""))))
    (setq easymacs-claude--source-file source-file
          easymacs-claude--busy t)
    (with-current-buffer output-buffer
      (goto-char (point-max))
      (insert (propertize "<you> " 'face 'easymacs-claude-user-face))
      (insert prompt)
      (insert (propertize "\n<claude> " 'face 'easymacs-claude-assistant-face)))
    (if (eq easymacs-claude-display-mode 'inline)
        (progn
          (setq easymacs-claude--inline-buffer source-buf
                easymacs-claude--inline-point
                (if source-buf (with-current-buffer source-buf (point)) (point)))
          (easymacs-claude--inline-spinner-start))
      (let ((claude-win (get-buffer-window output-buffer t)))
        (unless claude-win
          (setq claude-win (split-window nil nil 'right))
          (set-window-buffer claude-win output-buffer))
        (with-selected-window claude-win
          (goto-char (point-max))))
      (easymacs-claude--spinner-start))
    (condition-case err
        (let ((proc (start-process-shell-command "claude" nil cmd)))
          (set-process-filter proc #'easymacs-claude--filter)
          (set-process-sentinel proc #'easymacs-claude--sentinel))
      (error
       (setq easymacs-claude--busy nil)
       (easymacs-claude--spinner-stop)
       (easymacs-claude--inline-spinner-stop)
       (easymacs-claude--inline-delete-overlay)
       (easymacs-claude--cleanup-backups easymacs-claude--run-backups)
       (setq easymacs-claude--run-backups nil
             easymacs-claude--run-file-exists nil)
       (easymacs-claude--insert
        (format "\n[Failed to start Claude: %s]\n" (error-message-string err))
        'easymacs-claude-error-face)))))
(defun easymacs-claude--process-queue ()
  "Process the next item in the queue if not busy."
  (when (and (not easymacs-claude--busy)
             easymacs-claude--queue)
    (pcase-let ((`(,prompt . ,file) (pop easymacs-claude--queue)))
      (easymacs-claude--run-prompt prompt file))))
(defun easymacs-claude (prompt)
  "Send PROMPT to Claude with file context. Continues session if one exists.
If Claude is busy, the prompt is queued and will run when idle."
  (interactive "sClaude: ")
  (unless buffer-file-name
    (user-error "Buffer must be visiting a file"))
  (save-buffer)
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
  (setq easymacs-claude-session-active nil
        easymacs-claude--edits nil)
  (message "Claude session reset. Next call starts fresh."))
(defun easymacs-claude-revert ()
  "Revert the current file to the pre-Claude state from the latest run."
  (interactive)
  (let* ((target-file (or (and buffer-file-name (expand-file-name buffer-file-name))
                          easymacs-claude--source-file))
         (backup-file (and target-file (easymacs-claude--backup-for-file target-file)))
         (existed-before (and target-file
                              (easymacs-claude--file-existed-before-p target-file))))
    (if (and backup-file (file-exists-p backup-file))
        (when (y-or-n-p (format "Revert %s to pre-Claude state? "
                                (abbreviate-file-name target-file)))
          (if (eq existed-before nil)
              (when (file-exists-p target-file)
                (delete-file target-file))
            (copy-file backup-file target-file t))
          (when-let ((buf (find-buffer-visiting target-file)))
            (if (file-exists-p target-file)
                (with-current-buffer buf
                  (revert-buffer t t t))
              (kill-buffer buf)))
          (message "Reverted %s to pre-Claude state%s."
                   (abbreviate-file-name target-file)
                   (if (eq existed-before nil) " (file removed)" "")))
      (user-error "No Claude backup available for this file"))))
(defun easymacs-claude-toggle-display-mode ()
  "Toggle between buffer and inline display modes."
  (interactive)
  (setq easymacs-claude-display-mode
        (if (eq easymacs-claude-display-mode 'buffer) 'inline 'buffer))
  (message "Claude display mode: %s" easymacs-claude-display-mode))
(defun easymacs-claude-interrupt ()
  "Toggle pause/resume of the running Claude process."
  (interactive)
  (let ((proc (get-process "claude")))
    (cond
     ((not (and proc (process-live-p proc)))
      (user-error "No Claude process running"))
     (easymacs-claude--paused
      (signal-process proc 'CONT)
      (setq easymacs-claude--paused nil)
      (easymacs-claude--spinner-start)
      (message "Claude resumed."))
     (t
      (signal-process proc 'STOP)
      (setq easymacs-claude--paused t)
      (easymacs-claude--spinner-stop)
      (easymacs-claude--inline-spinner-stop)
      (easymacs-claude--insert "\n[Paused]\n" 'easymacs-claude-tool-face)
      (message "Claude paused.")))))
(defun easymacs-claude-stop ()
  "Kill the running Claude process and clear the queue."
  (interactive)
  (let ((proc (get-process "claude")))
    (when (and proc (process-live-p proc))
      (when easymacs-claude--paused
        (signal-process proc 'CONT))
      (kill-process proc)))
  (setq easymacs-claude--queue nil
        easymacs-claude--busy nil
        easymacs-claude--paused nil)
  (easymacs-claude--spinner-stop)
  (easymacs-claude--inline-spinner-stop)
  (easymacs-claude--inline-delete-overlay)
  (easymacs-claude--insert "\n[Stopped by user]\n" 'easymacs-claude-error-face)
  (message "Claude stopped."))

(provide 'easymacs-claude)
;;; easymacs-claude.el ends here
