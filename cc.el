;;; cc.el --- Minimal Claude Code Q&A wrapper -*- lexical-binding: t -*-
(require 'json)
(defvar cc--line-buf "")
(defvar cc--session nil)
(defvar cc--busy nil)

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
  (let* ((tools "Read Glob Grep WebSearch WebFetch")
         (sys "Respond in org-mode format. Use #+BEGIN_SRC lang / #+END_SRC for code blocks."))
    (format "claude -p %s --allowedTools %s --output-format stream-json --verbose --append-system-prompt %s%s"
            (shell-quote-argument prompt)
            (shell-quote-argument tools)
            (shell-quote-argument sys)
            (if cc--session " -c" ""))))

(defun cc--parse-line (line)
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
                 (when (equal (alist-get 'type item) "text")
                   (cc--append (alist-get 'text item)))))))
          ("result"
           (cc--append (format "\n# %s turn(s) | $%.4f\n"
                               (or (alist-get 'num_turns json) "?")
                               (or (alist-get 'total_cost_usd json) 0))))))
    (error nil)))

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
    (setq cc--busy nil cc--session t)))

(defun cc-query (prompt)
  "Send PROMPT to Claude. Streams response to *cc* org buffer."
  (interactive "sClaude: ")
  (when cc--busy (user-error "Claude is busy — cc-stop to cancel"))
  (let ((context (when buffer-file-name
                   (format " (from %s, line %d)" buffer-file-name (line-number-at-pos))))
        (cmd (cc--build-cmd prompt)))
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
  (setq cc--busy nil))

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
