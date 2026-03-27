;;; cc.el --- Minimal Claude Code wrapper -*- lexical-binding: t -*-
;; cc-query → streams to *cc* bottom window, C-c C-c accept, C-c C-k reject
(require 'json)
(defvar-local cc--source nil "Real file path.")
(defvar-local cc--snapshot nil "Frozen copy at prompt time.")
(defvar-local cc--tmp nil "Claude's working copy.")
(defvar-local cc--line-buf "" "Incomplete JSON line accumulator.")
(defvar cc--session nil "Non-nil after first run (enables -c).")
(defvar cc--busy nil "Non-nil while Claude is running.")

;;; Display
(defun cc--buf ()
  (let ((buf (get-buffer-create "*cc*")))
    (with-current-buffer buf
      (unless (derived-mode-p 'special-mode)
        (special-mode)
        (setq-local buffer-read-only nil)))
    buf))

(defun cc--append (text &optional face)
  (let ((buf (cc--buf)))
    (with-current-buffer buf
      (goto-char (point-max))
      (insert (if face (propertize text 'face face) text)))
    (when-let ((win (get-buffer-window buf t)))
      (set-window-point win (buffer-size buf)))))

(defun cc--show ()
  (display-buffer (cc--buf)
                  '(display-buffer-in-side-window
                    (side . bottom) (window-height . 0.2) (dedicated . t))))

;;; Tmp file management
(defun cc--make-copies (source)
  (let* ((dir (file-name-directory source))
         (name (file-name-nondirectory source))
         (snapshot (expand-file-name (concat ".cc-snapshot-" name) dir))
         (tmp (expand-file-name (concat ".cc-tmp-" name) dir)))
    (copy-file source snapshot t)
    (copy-file source tmp t)
    (cons snapshot tmp)))

(defun cc--cleanup ()
  (with-current-buffer (cc--buf)
    (dolist (f (list cc--snapshot cc--tmp))
      (when (and f (file-exists-p f)) (delete-file f)))
    (setq cc--snapshot nil cc--tmp nil)))

;;; Command builder
(defun cc--build-cmd (prompt source tmp)
  (let* ((src-buf (find-buffer-visiting source))
         (mode (if src-buf (with-current-buffer src-buf (symbol-name major-mode)) "fundamental"))
         (line (if src-buf (with-current-buffer src-buf (line-number-at-pos)) 1))
         (full-prompt (format "File: %s (mode: %s, line: %d). Edit ONLY the copy at %s. Query: %s"
                              source mode line tmp prompt))
         (tools (format "Edit(%s) Write(%s) Read Glob Grep WebSearch WebFetch" tmp tmp)))
    (format "claude -p %s --allowedTools %s --permission-mode acceptEdits --output-format stream-json --verbose%s"
            (shell-quote-argument full-prompt)
            (shell-quote-argument tools)
            (if cc--session " -c" ""))))

;;; JSON stream parsing
(defun cc--parse-json-line (line)
  (condition-case nil
      (let* ((json (json-parse-string line :object-type 'alist))
             (type (alist-get 'type json)))
        (pcase type
          ("content_block_delta"
           (when-let ((delta (alist-get 'delta json)))
             (when (equal (alist-get 'type delta) "text_delta")
               (cc--append (alist-get 'text delta)))))
          ("assistant"
           (when-let ((content (alist-get 'content (alist-get 'message json))))
             (when (vectorp content)
               (dolist (item (append content nil))
                 (pcase (alist-get 'type item)
                   ("text" (cc--append (alist-get 'text item)))
                   ("tool_use"
                    (let ((name (alist-get 'name item))
                          (file (alist-get 'file_path (alist-get 'input item))))
                      (cc--append (format " [%s%s]\n" name
                                          (if file (concat " " (file-name-nondirectory file)) ""))
                                  'font-lock-comment-face))))))))
          ("result"
           (cc--append (format "\n-- %s turn(s) | $%.4f --\n"
                               (or (alist-get 'num_turns json) "?")
                               (or (alist-get 'total_cost_usd json) 0))
                       'font-lock-doc-face))))
    (error nil)))

(defun cc--filter (_proc output)
  (with-current-buffer (cc--buf)
    (setq cc--line-buf (concat cc--line-buf output))
    (let ((lines (split-string cc--line-buf "\n")))
      (setq cc--line-buf (car (last lines)))
      (dolist (line (butlast lines))
        (when (> (length line) 0)
          (cc--parse-json-line line))))))

;;; Diff display & sentinel
(defun cc--show-diff ()
  (let (snapshot tmp)
    (with-current-buffer (cc--buf)
      (setq snapshot cc--snapshot tmp cc--tmp))
    (when (and snapshot tmp (file-exists-p snapshot) (file-exists-p tmp))
      (let ((diff (with-temp-buffer
                    (call-process "diff" nil t nil "-u" snapshot tmp)
                    (buffer-string))))
        (if (string-empty-p diff)
            (cc--append "\n(no changes)\n" 'font-lock-comment-face)
          (let ((buf (get-buffer-create "*cc-diff*")))
            (with-current-buffer buf
              (let ((inhibit-read-only t)) (erase-buffer) (insert diff))
              (diff-mode)
              (cc-diff-mode 1)
              (goto-char (point-min)))
            (display-buffer buf '(display-buffer-in-side-window
                                  (side . bottom) (window-height . 0.3)))
            (cc--append "\n[C-c C-c] accept  [C-c C-k] reject\n"
                        'font-lock-doc-face)))))))

(defun cc--sentinel (_proc event)
  (when (string-match-p "finished\\|exited\\|killed" event)
    (with-current-buffer (cc--buf)
      (when (> (length cc--line-buf) 0)
        (cc--parse-json-line cc--line-buf)
        (setq cc--line-buf ""))
      (setq cc--busy nil cc--session t
            header-line-format "done"))
    (condition-case err
        (cc--show-diff)
      (error (message "cc: diff error: %S" err)))))

;;; Accept / Reject / Stop
(defvar cc-diff-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'cc-accept)
    (define-key map (kbd "C-c C-k") #'cc-reject)
    map))

(define-minor-mode cc-diff-mode
  "Minor mode active in *cc* when reviewing a diff."
  :lighter " cc-diff" :keymap cc-diff-mode-map)

(defun cc-accept ()
  "Apply Claude's changes to the real file via patch."
  (interactive)
  (with-current-buffer (cc--buf)
    (unless (and cc--snapshot cc--tmp cc--source)
      (user-error "No pending changes"))
    (let ((patch-file (make-temp-file "cc-patch-")))
      (unwind-protect
          (progn
            (call-process "diff" nil (list :file patch-file) nil "-u" cc--snapshot cc--tmp)
            (let ((ret (call-process "patch" nil nil nil "--unified" "--force" cc--source patch-file)))
              (when-let ((buf (find-buffer-visiting cc--source)))
                (with-current-buffer buf (revert-buffer t t)))
              (if (zerop ret)
                  (progn (setq header-line-format "accepted")
                         (message "cc: changes merged"))
                (setq header-line-format "conflicts — check .rej file")
                (message "cc: patch had conflicts, see %s.rej" cc--source))))
        (delete-file patch-file)))
    (cc-diff-mode -1)
    (cc--cleanup)))

(defun cc-reject ()
  "Discard Claude's changes."
  (interactive)
  (cc--cleanup)
  (cc-diff-mode -1)
  (with-current-buffer (cc--buf) (setq header-line-format "rejected"))
  (message "cc: changes rejected"))

(defun cc-stop ()
  "Kill the running Claude process."
  (interactive)
  (when-let ((proc (get-process "cc")))
    (when (process-live-p proc) (kill-process proc)))
  (setq cc--busy nil)
  (with-current-buffer (cc--buf) (setq header-line-format "stopped"))
  (message "cc: stopped"))

;;; Entry points
(defun cc-query (prompt)
  "Send PROMPT to Claude Code for the current file."
  (interactive "sClaude: ")
  (unless buffer-file-name (user-error "Buffer must be visiting a file"))
  (when cc--busy (user-error "Claude is busy — cc-stop to cancel"))
  (save-buffer)
  (let* ((source (expand-file-name buffer-file-name))
         (copies (cc--make-copies source))
         (cmd (cc--build-cmd prompt source (cdr copies))))
    (with-current-buffer (cc--buf)
      (let ((inhibit-read-only t)) (erase-buffer))
      (setq cc--source source cc--snapshot (car copies)
            cc--tmp (cdr copies) cc--line-buf ""
            header-line-format "working..."))
    (cc--append (format "> %s\n" prompt) 'font-lock-keyword-face)
    (cc--show)
    (setq cc--busy t)
    (let ((proc (start-process-shell-command "cc" nil cmd)))
      (set-process-filter proc #'cc--filter)
      (set-process-sentinel proc #'cc--sentinel))))

(defun cc-new-session ()
  "Reset session — next query starts fresh (no -c flag)."
  (interactive)
  (setq cc--session nil)
  (message "cc: session reset"))

(provide 'cc)
;;; cc.el ends here
