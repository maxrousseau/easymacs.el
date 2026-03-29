;;; cc.el --- Minimal Claude Code Q&A wrapper -*- lexical-binding: t -*-
(require 'json)
(defvar cc--line-buf "")
(defvar cc--session nil)
(defvar cc--busy nil)
(defvar cc--prompt-file
  (expand-file-name "cc-prompt.txt" (file-name-directory (or load-file-name buffer-file-name))))

(defun cc--buf ()
  (let ((buf (get-buffer-create "*cc*")))
    (with-current-buffer buf (unless (derived-mode-p 'org-mode) (org-mode)))
    buf))

(defun cc--append (text)
  (with-current-buffer (cc--buf) (goto-char (point-max)) (insert text))
  (when-let ((win (get-buffer-window "*cc*" t)))
    (set-window-point win (buffer-size (cc--buf)))))

(defun cc--show ()
  (display-buffer (cc--buf)
                  '(display-buffer-in-side-window
                    (side . bottom) (window-height . 0.3))))

(defun cc--build-cmd (prompt)
  (let ((tools "Read Glob Grep WebSearch WebFetch"))
    (format "claude -p %s --allowedTools %s --output-format stream-json --verbose --append-system-prompt-file %s%s"
            (shell-quote-argument prompt)
            (shell-quote-argument tools)
            (shell-quote-argument cc--prompt-file)
            (if cc--session " -c" ""))))

(defun cc--tool-str (name input)
  "Format a tool_use item with clickable links."
  (let ((file (alist-get 'file_path input))
        (url (alist-get 'url input))
        (pat (or (alist-get 'pattern input) (alist-get 'command input))))
    (cond
     (file (format "=→ %s= [[file:%s][%s]]\n" name file (file-name-nondirectory file)))
     (url (format "=→ %s= [[%s]]\n" name url))
     (pat (format "=→ %s= =%s=\n" name pat))
     (t (format "=→ %s=\n" name)))))

(defun cc--parse-one (json)
  "Handle a single parsed JSON event."
  (pcase (alist-get 'type json)
    ("content_block_start"
     (when-let ((block (alist-get 'content_block json)))
       (when (equal (alist-get 'type block) "tool_use")
         (cc--append (format "=→ %s=\n" (alist-get 'name block))))))
    ("content_block_delta"
     (when-let ((delta (alist-get 'delta json)))
       (pcase (alist-get 'type delta)
         ("text_delta" (cc--append (alist-get 'text delta)))
         ("thinking_delta" (cc--append (alist-get 'thinking delta))))))
    ("assistant"
     (when-let ((content (alist-get 'content (alist-get 'message json))))
       (when (vectorp content)
         (dolist (item (append content nil))
           (pcase (alist-get 'type item)
             ("thinking"
              (when-let ((text (alist-get 'thinking item)))
                (cc--append (format "#+BEGIN_QUOTE\n%s\n#+END_QUOTE\n" text))))
             ("text" (cc--append (alist-get 'text item)))
             ("tool_use"
              (cc--append (cc--tool-str (alist-get 'name item) (alist-get 'input item)))))))))
    ("result"
     (cc--append (format "\n:META:\n:COST: $%.4f\n:TURNS: %s\n:END:\n"
                         (or (alist-get 'total_cost_usd json) 0)
                         (or (alist-get 'num_turns json) "?"))))))

(defun cc--parse-line (line)
  (condition-case err
      (let ((parsed (json-parse-string line :object-type 'alist)))
        (if (vectorp parsed)
            (dolist (item (append parsed nil)) (cc--parse-one item))
          (cc--parse-one parsed)))
    (error (message "cc parse error: %S" err))))

(defun cc--filter (_proc output)
  (setq cc--line-buf (concat cc--line-buf output))
  (let ((lines (split-string cc--line-buf "\n")))
    (setq cc--line-buf (car (last lines)))
    (dolist (line (butlast lines))
      (when (> (length line) 0)
        (cc--parse-line line)))))

(defun cc--sentinel (_proc event)
  (when (string-match-p "finished\\|exited\\|killed" event)
    (when (> (length cc--line-buf) 0)
      (cc--parse-line cc--line-buf) (setq cc--line-buf ""))
    (setq cc--busy nil cc--session t)
    (with-current-buffer (cc--buf) (setq header-line-format "done"))))

(defun cc-query (prompt)
  "Send PROMPT to Claude. Streams response to *cc* org buffer."
  (interactive "sClaude: ")
  (when cc--busy (user-error "Claude is busy — cc-stop to cancel"))
  (let* ((file buffer-file-name)
         (context (when file (format " ([[file:%s::%d][%s:%d]])"
                                    file (line-number-at-pos)
                                    (file-name-nondirectory file) (line-number-at-pos))))
         (content (buffer-substring-no-properties
                   (point-min) (min (point-max) (* 64 1024))))
         (full (if file
                   (format "Current file: %s (line %d)\n\n```\n%s```\n\nQuery: %s"
                           file (line-number-at-pos) content prompt)
                 (format "Buffer content:\n```\n%s```\n\nQuery: %s" content prompt)))
         (cmd (cc--build-cmd full)))
    (with-current-buffer (cc--buf)
      (setq cc--line-buf "" header-line-format "working..."))
    (cc--append (format "\n* %s%s\n" prompt (or context "")))
    (cc--show)
    (setq cc--busy t)
    (let ((proc (start-process-shell-command "cc" nil cmd)))
      (set-process-filter proc #'cc--filter)
      (set-process-sentinel proc #'cc--sentinel))))

(defun cc-stop ()
  "Kill the running Claude process."
  (interactive)
  (when-let ((proc (get-process "cc")))
    (when (process-live-p proc) (kill-process proc)))
  (setq cc--busy nil)
  (with-current-buffer (cc--buf) (setq header-line-format "stopped")))

(defun cc-new-session ()
  "Next query starts fresh (no -c flag)."
  (interactive)
  (setq cc--session nil))

(defun cc-dismiss ()
  "Close *cc* window."
  (interactive)
  (when-let ((win (get-buffer-window "*cc*" t))) (delete-window win)))

(provide 'cc)
;;; cc.el ends here
