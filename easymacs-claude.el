;;; easymacs-claude.el --- Claude Code integration for Easymacs -*- lexical-binding: t -*-

;;; Commentary:
;; Provides Claude Code integration with streaming output and diff review.

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

(defun easymacs-claude--build-context ()
  "Build context string with current file and position."
  (format "File: %s\nLine: %d\nMode: %s"
          (or buffer-file-name "unnamed buffer")
          (line-number-at-pos)
          major-mode))

(defun easymacs-claude--save-temp-copy ()
  "Save a temp copy of the current file for later diffing/reverting."
  (when buffer-file-name
    (let ((temp-file (make-temp-file "claude-backup-" nil
                                      (concat "." (file-name-extension buffer-file-name)))))
      (copy-file buffer-file-name temp-file t)
      (setq easymacs-claude--temp-file temp-file)
      (setq easymacs-claude--edits nil))))

(defun easymacs-claude--show-diff ()
  "Show diff between temp copy and current file below the Claude buffer."
  (when (and easymacs-claude--temp-file
             easymacs-claude--source-file
             (file-exists-p easymacs-claude--temp-file))
    ;; Revert the source buffer to show changes
    (let ((buf (find-buffer-visiting easymacs-claude--source-file)))
      (when buf
        (with-current-buffer buf
          (revert-buffer t t t))))
    ;; Show diff below the Claude buffer
    (let ((diff-buf (diff-no-select easymacs-claude--temp-file
                                     easymacs-claude--source-file
                                     nil 'noasync))
          (claude-win (get-buffer-window "*Claude*")))
      (when diff-buf
        (if claude-win
            (with-selected-window claude-win
              (let ((diff-win (split-window-below)))
                (set-window-buffer diff-win diff-buf)))
          (display-buffer diff-buf))))))

(defun easymacs-claude--insert (text &optional face)
  "Insert TEXT into the Claude output buffer with optional FACE."
  (when-let ((buf (get-buffer "*Claude*")))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (goto-char (point-max))
        (if face
            (insert (propertize text 'face face))
          (insert text))))))

(defun easymacs-claude--handle-tool-use (item)
  "Handle a tool_use ITEM and display it."
  (let ((tool-name (alist-get 'name item))
        (input (alist-get 'input item)))
    (cond
     ((string= tool-name "Read")
      (easymacs-claude--insert "\n[Reading: " 'easymacs-claude-tool-face)
      (easymacs-claude--insert (alist-get 'file_path input) 'easymacs-claude-file-face)
      (easymacs-claude--insert "]\n" 'easymacs-claude-tool-face))
     ((string= tool-name "Edit")
      (let ((file (alist-get 'file_path input))
            (old-str (alist-get 'old_string input))
            (new-str (alist-get 'new_string input)))
        (push (list file old-str new-str) easymacs-claude--edits)
        (easymacs-claude--insert "\n[Editing: " 'easymacs-claude-tool-face)
        (easymacs-claude--insert file 'easymacs-claude-file-face)
        (easymacs-claude--insert "]\n" 'easymacs-claude-tool-face)
        (easymacs-claude--insert
         (format "  - %s\n" (truncate-string-to-width (or old-str "") 60 nil nil "..."))
         'easymacs-claude-removed-face)
        (easymacs-claude--insert
         (format "  + %s\n" (truncate-string-to-width (or new-str "") 60 nil nil "..."))
         'easymacs-claude-added-face)))
     ((string= tool-name "Write")
      (easymacs-claude--insert "\n[Writing: " 'easymacs-claude-tool-face)
      (easymacs-claude--insert (alist-get 'file_path input) 'easymacs-claude-file-face)
      (easymacs-claude--insert "]\n" 'easymacs-claude-tool-face))
     (t
      (easymacs-claude--insert (format "\n[Using: %s]\n" tool-name) 'easymacs-claude-tool-face)))))

(defun easymacs-claude--handle-assistant (json)
  "Handle an assistant message JSON."
  (let* ((message (alist-get 'message json))
         (content (alist-get 'content message)))
    (when (vectorp content)
      (seq-doseq (item content)
        (let ((item-type (alist-get 'type item)))
          (cond
           ((string= item-type "text")
            (easymacs-claude--insert (alist-get 'text item)))
           ((string= item-type "tool_use")
            (easymacs-claude--handle-tool-use item))))))))

(defun easymacs-claude--filter (proc output)
  "Filter PROC OUTPUT to extract and display Claude's process."
  (dolist (line (split-string output "\n" t))
    (condition-case nil
        (let* ((json (json-parse-string line :object-type 'alist))
               (type (alist-get 'type json))
               (subtype (alist-get 'subtype json)))
          (cond
           ;; Init message
           ((and (string= type "system") (string= subtype "init"))
            (easymacs-claude--insert
             (format "[Session: %s | Model: %s]\n\n"
                     (alist-get 'session_id json)
                     (alist-get 'model json))
             'easymacs-claude-header-face))
           ;; Assistant message
           ((string= type "assistant")
            (easymacs-claude--handle-assistant json))
           ;; Tool result errors
           ((string= type "user")
            (let ((content (alist-get 'content (alist-get 'message json))))
              (when (vectorp content)
                (seq-doseq (item content)
                  (when (and (string= (alist-get 'type item) "tool_result")
                             (alist-get 'is_error item))
                    (easymacs-claude--insert
                     (format "\n[Error: %s]\n" (alist-get 'content item))
                     'easymacs-claude-error-face))))))
           ;; Result summary
           ((string= type "result")
            (let ((cost (alist-get 'total_cost_usd json))
                  (turns (alist-get 'num_turns json)))
              (easymacs-claude--insert "\n\n--- Summary ---\n" 'easymacs-claude-header-face)
              (easymacs-claude--insert
               (format "Turns: %s | Cost: $%.4f\nEdits: %d file(s) modified\n"
                       turns (or cost 0) (length easymacs-claude--edits))
               'easymacs-claude-summary-face)))))
      (error nil))))

(defun easymacs-claude--sentinel (proc event)
  "Handle Claude PROC completion EVENT."
  (when (string-match-p "finished" event)
    (setq easymacs-claude-session-active t)
    (easymacs-claude--show-diff)
    (run-hooks 'easymacs-claude-after-edit-hook)))

(defun easymacs-claude (prompt)
  "Send PROMPT to Claude with file context. Continues session if one exists."
  (interactive "sClaude: ")
  (unless buffer-file-name
    (user-error "Buffer must be visiting a file"))
  (save-buffer)
  (easymacs-claude--save-temp-copy)
  (let* ((context (easymacs-claude--build-context))
         (full-prompt (concat context "\n---\n" prompt))
         (output-buffer (get-buffer-create "*Claude*"))
         (allowed-tools (format "Edit:%s,Read" buffer-file-name))
         (quoted-prompt (shell-quote-argument full-prompt))
         (cmd (format "claude -p %s --allowedTools '%s' --permission-mode acceptEdits --output-format stream-json --verbose%s"
                      quoted-prompt
                      allowed-tools
                      (if easymacs-claude-session-active " -c" ""))))
    (setq easymacs-claude--source-file buffer-file-name)
    (with-current-buffer output-buffer
      (goto-char (point-max))
      (insert (propertize "\n\n========================================\n" 'face 'easymacs-claude-header-face))
      (insert (propertize "--- User ---\n" 'face 'easymacs-claude-user-face))
      (insert prompt)
      (insert (propertize "\n\n--- Claude ---\n" 'face 'easymacs-claude-assistant-face)))
    (display-buffer output-buffer)
    (let ((proc (start-process-shell-command "claude" nil cmd)))
      (set-process-filter proc #'easymacs-claude--filter)
      (set-process-sentinel proc #'easymacs-claude--sentinel))))

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
