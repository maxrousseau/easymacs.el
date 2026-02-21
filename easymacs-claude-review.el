;;; easymacs-claude-review.el --- Review queue for Claude edits -*- lexical-binding: t -*-

(require 'diff)
(require 'subr-x)
(require 'cl-lib)

(defface easymacs-claude-review-added-face
  '((t :inherit diff-added :foreground unspecified :weight normal :slant normal :extend t))
  "Face for added hunks in the Claude review queue.")

(defface easymacs-claude-review-removed-face
  '((t :inherit diff-removed :foreground unspecified :weight normal :slant normal :extend t))
  "Face for removed hunks in the Claude review queue.")

(defface easymacs-claude-review-count-added-face
  '((t :inherit success :weight bold))
  "Face for added-line counts in the modeline indicator.")

(defface easymacs-claude-review-count-removed-face
  '((t :inherit error :weight bold))
  "Face for removed-line counts in the modeline indicator.")

(defcustom easymacs-claude-review-queue t
  "When non-nil, build a review queue after Claude edits."
  :type 'boolean
  :group 'easymacs)

(defcustom easymacs-claude-review-show-diff-buffer nil
  "When non-nil, also display the *Claude Diff* buffer after a run."
  :type 'boolean
  :group 'easymacs)

(defvar-local easymacs-claude--review-items nil
  "Vector of pending review items for the current buffer.")
(defvar-local easymacs-claude--review-total 0
  "Total number of review items created for the current buffer.")
(defvar-local easymacs-claude--review-index 0
  "Current review index in `easymacs-claude--review-items'.")

(defvar easymacs-claude-review-mode-line
  '(:eval (easymacs-claude--review-mode-line-value))
  "Mode-line construct used to show Claude review progress.")

(defun easymacs-claude--review-pending ()
  "Return the number of pending review items in the current buffer."
  (let ((items easymacs-claude--review-items)
        (count 0))
    (when (vectorp items)
      (dotimes (i (length items) count)
        (when (aref items i)
          (setq count (1+ count)))))))

(defun easymacs-claude--review-pending-line-counts ()
  "Return `(ADDED . REMOVED)' for pending review items."
  (let ((items easymacs-claude--review-items)
        (added 0)
        (removed 0))
    (when (vectorp items)
      (dotimes (i (length items))
        (when-let ((item (aref items i)))
          (setq added (+ added (or (plist-get item :added-count) 0))
                removed (+ removed (or (plist-get item :removed-count) 0))))))
    (cons added removed)))

(defun easymacs-claude--review-lighter ()
  "Modeline lighter for the review queue."
  (if (and (vectorp easymacs-claude--review-items)
           (> easymacs-claude--review-total 0))
      (let* ((counts (easymacs-claude--review-pending-line-counts))
             (added (car counts))
             (removed (cdr counts))
             (added-text (propertize (format "+%d" added)
                                     'face 'easymacs-claude-review-count-added-face))
             (removed-text (propertize (format "-%d" removed)
                                       'face 'easymacs-claude-review-count-removed-face)))
        (concat (format " ClaudeReview:%d/%d "
                        (easymacs-claude--review-pending)
                        easymacs-claude--review-total)
                added-text
                removed-text))
    " ClaudeReview:0/0"))

(defun easymacs-claude--review-mood-line-segment ()
  "Return mood-line segment for review line deltas."
  (when (and easymacs-claude-review-mode
             (> easymacs-claude--review-total 0))
    (let* ((counts (easymacs-claude--review-pending-line-counts))
           (added (car counts))
           (removed (cdr counts))
           (added-text (propertize (format "+%d" added)
                                   'face 'easymacs-claude-review-count-added-face))
           (removed-text (propertize (format "-%d" removed)
                                     'face 'easymacs-claude-review-count-removed-face)))
      (concat "CR:" added-text removed-text))))

(defun easymacs-claude--review-mode-line-value ()
  "Return mode-line text for the current buffer's review queue."
  (when (and easymacs-claude-review-mode
             (> easymacs-claude--review-total 0)
             (not (bound-and-true-p mood-line-mode)))
    (easymacs-claude--review-lighter)))

(defun easymacs-claude--review-install-mode-line ()
  "Install Claude review indicator into `global-mode-string'."
  (let* ((entry easymacs-claude-review-mode-line)
         (cur (default-value 'global-mode-string))
         (cur-list (cond
                    ((null cur) nil)
                    ((listp cur) cur)
                    (t (list cur)))))
    (unless (member entry cur-list)
      (setq-default global-mode-string
                    (append cur-list (list entry))))))

(defun easymacs-claude--review-sanitize-mode-line-misc-info ()
  "Remove Claude review entry from `mode-line-misc-info' defaults."
  (let ((entry easymacs-claude-review-mode-line))
    (setq-default mode-line-misc-info
                  (cl-remove entry (default-value 'mode-line-misc-info)
                             :test #'equal))))

(defun easymacs-claude--review-refresh-mode-line ()
  "Refresh mode line after review state changes."
  (force-mode-line-update t))

(defun easymacs-claude--review-sanitize-mood-line-format ()
  "Remove legacy Claude review segments from `mood-line-format'."
  (when (and (boundp 'mood-line-format)
             (consp mood-line-format))
    (let* ((legacy '(easymacs-claude--review-mood-line-segment . "  "))
           (segment '(easymacs-claude--review-mood-line-segment))
           (left (car mood-line-format))
           (right (cadr mood-line-format))
           (left2 (if (listp left)
                      (cl-remove-if (lambda (seg) (or (equal seg legacy)
                                                      (equal seg segment)))
                                    left)
                    left))
           (right2
            (if (listp right)
                (let (out)
                  (while right
                    (let ((cur (car right))
                          (next (cadr right)))
                      (cond
                       ((equal cur legacy)
                        (setq right (cdr right)))
                       ((equal cur segment)
                        (setq right (cdr right))
                        (when (equal (car right) "  ")
                          (setq right (cdr right))))
                       ((and (equal cur "  ")
                             (or (equal next segment)
                                 (null next)))
                        (setq right (cdr right)))
                       (t
                        (push cur out)
                        (setq right (cdr right))))))
                  (nreverse out))
              right)))
      (unless (and (equal left left2) (equal right right2))
        (setq mood-line-format (list left2 right2))
        (when (fboundp 'mood-line--refresh)
          (mood-line--refresh))
        (easymacs-claude--review-refresh-mode-line)))))

(defun easymacs-claude--review-install-mood-line-segment ()
  "Install a dedicated review delta segment into `mood-line-format'."
  (when (and (boundp 'mood-line-format)
             (consp mood-line-format))
    (let* ((segment '(easymacs-claude--review-mood-line-segment))
           (left (car mood-line-format))
           (right (cadr mood-line-format)))
      (when (and (listp right)
                 (not (member segment right)))
        ;; Mood-line expects raw eval forms and separator strings, not cons cells.
        (setq mood-line-format (list left (append right (list segment "  "))))
        (when (fboundp 'mood-line--refresh)
          (mood-line--refresh))
        (easymacs-claude--review-refresh-mode-line)))))

(defvar easymacs-claude-review-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-a") #'easymacs-claude-review-accept)
    (define-key map (kbd "C-c C-r") #'easymacs-claude-review-reject)
    (define-key map (kbd "C-c C-n") #'easymacs-claude-review-next)
    (define-key map (kbd "C-c C-p") #'easymacs-claude-review-prev)
    (define-key map (kbd "C-c C-k") #'easymacs-claude-review-clear)
    (define-key map (kbd "C-c C-s") #'easymacs-claude-review-select)
    map)
  "Keymap for `easymacs-claude-review-mode'.")

(define-minor-mode easymacs-claude-review-mode
  "Minor mode for reviewing Claude edits as a queue."
  :lighter nil
  :keymap easymacs-claude-review-mode-map)

(defconst easymacs-claude-review-queue-buffer-name "*Claude Review Queue*"
  "Buffer name used for the swiper-friendly Claude review queue list.")

(defvar easymacs-claude-review-queue-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'easymacs-claude-review-queue-visit)
    (define-key map (kbd "g") #'easymacs-claude-review-queue-refresh)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `easymacs-claude-review-queue-mode'.")

(define-derived-mode easymacs-claude-review-queue-mode special-mode "ClaudeReviewQueue"
  "Major mode for the aggregated Claude review queue buffer.")

(defun easymacs-claude--review-item-preview (item)
  "Return a concise preview string for review ITEM."
  (let* ((after (string-trim (or (plist-get item :after) "")))
         (before (string-trim (or (plist-get item :before) "")))
         (raw (if (string-empty-p after) before after))
         (line (car (split-string raw "\n" t))))
    (if line
        (truncate-string-to-width line 110 nil nil "...")
      "<empty hunk>")))

(defun easymacs-claude--review-collect-pending ()
  "Return a list of pending review items across all live buffers."
  (let (entries)
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (when (and (vectorp easymacs-claude--review-items)
                   (> easymacs-claude--review-total 0))
          (dotimes (idx (length easymacs-claude--review-items))
            (when-let ((item (aref easymacs-claude--review-items idx)))
              (when-let ((pos (marker-position (plist-get item :start))))
                (push (list :buffer buf
                            :index idx
                            :line (line-number-at-pos pos t)
                            :added (or (plist-get item :added-count) 0)
                            :removed (or (plist-get item :removed-count) 0)
                            :preview (easymacs-claude--review-item-preview item))
                      entries)))))))
    (nreverse entries)))

(defun easymacs-claude--review-entry-path (entry)
  "Return a display path string for review ENTRY."
  (let ((src (plist-get entry :buffer))
        (file (plist-get entry :file)))
    (or (and src
             (abbreviate-file-name
              (or (buffer-file-name src) (buffer-name src))))
        (and file (abbreviate-file-name file))
        "<unknown>")))

(defun easymacs-claude--review-entry-label (entry)
  "Return minibuffer label text for review ENTRY."
  (format "%s:%d  +%d -%d  %s"
          (easymacs-claude--review-entry-path entry)
          (or (plist-get entry :line) 1)
          (or (plist-get entry :added) 0)
          (or (plist-get entry :removed) 0)
          (or (plist-get entry :preview) "<empty hunk>")))

(defun easymacs-claude--review-visit-entry (entry)
  "Visit a review ENTRY in its source buffer."
  (let ((src (plist-get entry :buffer))
        (idx (plist-get entry :index))
        (file (plist-get entry :file))
        (line (or (plist-get entry :line) 1)))
    (cond
     ((and src idx (buffer-live-p src))
      (pop-to-buffer src)
      (easymacs-claude--review-goto idx))
     ((and file (file-exists-p file))
      (pop-to-buffer (find-file-noselect file))
      (goto-char (point-min))
      (forward-line (max 0 (1- line)))
      (recenter))
     (t
      (message "Source location for this review entry is unavailable.")))))

(defun easymacs-claude--review-refresh-queue-buffer-if-open ()
  "Refresh queue buffer when it is currently open."
  (when-let ((buf (get-buffer easymacs-claude-review-queue-buffer-name)))
    (with-current-buffer buf
      (let ((line (line-number-at-pos)))
        (easymacs-claude-review-queue-refresh)
        (goto-char (point-min))
        (forward-line (max 0 (1- line)))))))

(defun easymacs-claude-review-queue-refresh ()
  "Refresh the aggregated review queue buffer and return pending entries."
  (interactive)
  (let ((entries (easymacs-claude--review-collect-pending)))
    (with-current-buffer (get-buffer-create easymacs-claude-review-queue-buffer-name)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (easymacs-claude-review-queue-mode)
        (if entries
            (dolist (entry entries)
              (let ((line-start (point)))
                (insert (concat (easymacs-claude--review-entry-label entry) "\n"))
                (put-text-property line-start (point)
                                   'easymacs-claude-review-entry entry)))
          (insert "No pending Claude review items.\n"))
        (goto-char (point-min))))
    entries))

(defun easymacs-claude-review-queue-visit ()
  "Visit the review item at point in the aggregated review queue buffer."
  (interactive)
  (if-let ((entry (get-text-property (point) 'easymacs-claude-review-entry)))
      (easymacs-claude--review-visit-entry entry)
    (message "No review item on this line.")))

(defun easymacs-claude-review-select ()
  "Pick a pending Claude review item from the minibuffer and jump to it."
  (interactive)
  (let ((entries (easymacs-claude--review-collect-pending)))
    (if entries
        (let* ((choices (cl-loop for entry in entries
                                 for n from 1
                                 collect (cons (format "%d. %s"
                                                       n
                                                       (easymacs-claude--review-entry-label entry))
                                               entry)))
               (selection (completing-read "Review change: "
                                           (mapcar #'car choices)
                                           nil t))
               (entry (cdr (assoc selection choices))))
          (when entry
            (easymacs-claude--review-visit-entry entry)))
      (message "No pending Claude review items."))))

(defalias 'easymacs-claude-review-swiper #'easymacs-claude-review-select)

(defun easymacs-claude--diff-text (old-file new-file)
  "Return unified diff text between OLD-FILE and NEW-FILE."
  (let ((buf (diff-no-select old-file new-file nil 'noasync)))
    (when buf
      (with-current-buffer buf
        (prog1 (buffer-substring-no-properties (point-min) (point-max))
          (kill-buffer buf))))))

(defun easymacs-claude--plist-push (plist key value)
  "Push VALUE onto the list at KEY in PLIST, returning the new plist."
  (let ((cur (plist-get plist key)))
    (plist-put plist key (cons value cur))))

(defun easymacs-claude--parse-diff (text)
  "Parse unified diff TEXT into a list of hunk plists."
  (let ((lines (split-string text "\n"))
        hunks current)
    (dolist (line lines)
      (cond
       ((string-match
         "^@@ -\\([0-9]+\\)\\(,\\([0-9]+\\)\\)? +\\+\\([0-9]+\\)\\(,\\([0-9]+\\)\\)? @@"
         line)
        (when current (push current hunks))
        (setq current (list :start (string-to-number (match-string 4 line))
                            :before-lines nil
                            :after-lines nil
                            :after-kinds nil
                            :removed-lines nil)))
       ((and current (string-prefix-p "+" line))
        (let ((txt (substring line 1)))
          (setq current (easymacs-claude--plist-push current :after-lines txt))
          (setq current (easymacs-claude--plist-push current :after-kinds 'added))))
       ((and current (string-prefix-p "-" line))
        (let ((txt (substring line 1)))
          (setq current (easymacs-claude--plist-push current :before-lines txt))
          (setq current (easymacs-claude--plist-push current :removed-lines txt))))
       ((and current (string-prefix-p " " line))
        (let ((txt (substring line 1)))
          (setq current (easymacs-claude--plist-push current :before-lines txt))
          (setq current (easymacs-claude--plist-push current :after-lines txt))
          (setq current (easymacs-claude--plist-push current :after-kinds 'context))))))
    (when current (push current hunks))
    (mapcar (lambda (h)
              (dolist (key '(:before-lines :after-lines :after-kinds :removed-lines))
                (setq h (plist-put h key (nreverse (plist-get h key)))))
              h)
            (nreverse hunks))))

(defun easymacs-claude--lines->text (lines trailing-nl)
  "Join LINES with newlines and add a trailing newline if TRAILING-NL."
  (let ((text (mapconcat #'identity lines "\n")))
    (if (and trailing-nl (> (length text) 0))
        (concat text "\n")
      text)))

(defun easymacs-claude--format-removed (lines)
  "Format removed LINES for inline display."
  (when lines
    (let ((text (mapconcat (lambda (l) (concat "- " l)) lines "\n")))
      (concat (propertize text 'face 'easymacs-claude-review-removed-face) "\n"))))

(defun easymacs-claude--review-make-item (hunk)
  "Create a review item plist from HUNK at point in the current buffer."
  (let* ((start-line (plist-get hunk :start))
         (after-lines (plist-get hunk :after-lines))
         (after-kinds (plist-get hunk :after-kinds))
         (before-lines (plist-get hunk :before-lines))
         (removed-lines (plist-get hunk :removed-lines))
         (after-count (length after-lines))
         (addedp (memq 'added after-kinds))
         (added-count (cl-count 'added after-kinds :test #'eq))
         (removed-count (length removed-lines))
         (start-pos (save-excursion
                      (goto-char (point-min))
                      (forward-line (max 0 (1- start-line)))
                      (line-beginning-position)))
         (end-pos (save-excursion
                    (goto-char start-pos)
                    (forward-line after-count)
                    (point)))
         (after-text (buffer-substring-no-properties start-pos end-pos))
         (trailing-nl (and (> (length after-text) 0)
                           (eq (aref after-text (1- (length after-text))) ?\n)))
         (before-text (easymacs-claude--lines->text before-lines trailing-nl))
         (overlays nil)
         (removed-overlay nil))
    (when (and addedp (> after-count 0))
      (let ((ov (make-overlay start-pos end-pos)))
        (overlay-put ov 'face 'easymacs-claude-review-added-face)
        (overlay-put ov 'easymacs-claude-review t)
        (push ov overlays)))
    (when removed-lines
      (let ((ov (make-overlay start-pos start-pos)))
        (overlay-put ov 'before-string (easymacs-claude--format-removed removed-lines))
        (overlay-put ov 'easymacs-claude-review t)
        (setq removed-overlay ov)))
    (list :start (copy-marker start-pos)
          :end (copy-marker end-pos t)
          :before before-text
          :after after-text
          :added-count added-count
          :removed-count removed-count
          :overlays overlays
          :removed-overlay removed-overlay)))

(defun easymacs-claude--review-clear-item (item)
  "Remove overlays associated with ITEM."
  (dolist (ov (plist-get item :overlays))
    (delete-overlay ov))
  (when-let ((ov (plist-get item :removed-overlay)))
    (delete-overlay ov)))

(defun easymacs-claude-review-clear ()
  "Clear the review queue and remove overlays in the current buffer."
  (interactive)
  (when (vectorp easymacs-claude--review-items)
    (dotimes (i (length easymacs-claude--review-items))
      (when-let ((item (aref easymacs-claude--review-items i)))
        (easymacs-claude--review-clear-item item))))
  (setq easymacs-claude--review-items nil
        easymacs-claude--review-total 0
        easymacs-claude--review-index 0)
  (easymacs-claude-review-mode -1)
  (easymacs-claude--review-refresh-mode-line)
  (easymacs-claude--review-refresh-queue-buffer-if-open))

(defun easymacs-claude--review-current ()
  "Return the current review item or nil."
  (when (and (vectorp easymacs-claude--review-items)
             (< easymacs-claude--review-index
                (length easymacs-claude--review-items)))
    (aref easymacs-claude--review-items easymacs-claude--review-index)))

(defun easymacs-claude--review-goto (index)
  "Move point to the review item at INDEX."
  (let ((items easymacs-claude--review-items))
    (when (and (vectorp items) (>= index 0) (< index (length items)))
      (when-let ((item (aref items index)))
        (setq easymacs-claude--review-index index)
        (let ((pos (marker-position (plist-get item :start))))
          (goto-char pos)
          (when-let ((win (get-buffer-window (current-buffer) t)))
            (with-selected-window win
              (goto-char pos)
              (recenter))))))))

(defun easymacs-claude--review-find (start step)
  "Find the next pending item index from START moving by STEP."
  (let ((items easymacs-claude--review-items)
        (idx start))
    (when (vectorp items)
      (while (and (>= idx 0)
                  (< idx (length items))
                  (null (aref items idx)))
        (setq idx (+ idx step)))
      (when (and (>= idx 0) (< idx (length items)))
        idx))))

(defun easymacs-claude-review-next ()
  "Jump to the next pending review item."
  (interactive)
  (let* ((start (1+ easymacs-claude--review-index))
         (idx (or (easymacs-claude--review-find start 1)
                  (easymacs-claude--review-find 0 1))))
    (if idx
        (easymacs-claude--review-goto idx)
      (message "No pending review items."))))

(defun easymacs-claude-review-prev ()
  "Jump to the previous pending review item."
  (interactive)
  (let* ((start (1- easymacs-claude--review-index))
         (idx (or (easymacs-claude--review-find start -1)
                  (easymacs-claude--review-find (1- easymacs-claude--review-total) -1))))
    (if idx
        (easymacs-claude--review-goto idx)
      (message "No pending review items."))))

(defun easymacs-claude--review-finish-current ()
  "Remove overlays for current item and advance the queue."
  (when-let ((item (easymacs-claude--review-current)))
    (easymacs-claude--review-clear-item item)
    (aset easymacs-claude--review-items easymacs-claude--review-index nil)
    (easymacs-claude--review-refresh-mode-line)
    (easymacs-claude--review-refresh-queue-buffer-if-open)
    (if (> (easymacs-claude--review-pending) 0)
        (easymacs-claude-review-next)
      (message "Claude review complete.")
      (easymacs-claude-review-clear))))

(defun easymacs-claude-review-accept ()
  "Accept the current review item (keep Claude's change)."
  (interactive)
  (easymacs-claude--review-finish-current))

(defun easymacs-claude-review-reject ()
  "Reject the current review item (revert to pre-Claude text)."
  (interactive)
  (when-let ((item (easymacs-claude--review-current)))
    (let* ((start (marker-position (plist-get item :start)))
           (end (marker-position (plist-get item :end)))
           (before (plist-get item :before)))
      (easymacs-claude--review-clear-item item)
      (save-excursion
        (goto-char start)
        (delete-region start end)
        (insert before))
      (aset easymacs-claude--review-items easymacs-claude--review-index nil)
      (easymacs-claude--review-refresh-mode-line)
      (easymacs-claude--review-refresh-queue-buffer-if-open)
      (if (> (easymacs-claude--review-pending) 0)
          (easymacs-claude-review-next)
        (message "Claude review complete.")
        (easymacs-claude-review-clear)))))

(defun easymacs-claude--review-default-backups ()
  "Return the latest known file-backup alist from Claude state."
  (or (and (boundp 'easymacs-claude--last-run-backups)
           easymacs-claude--last-run-backups)
      (and (boundp 'easymacs-claude--source-file)
           (boundp 'easymacs-claude--temp-file)
           easymacs-claude--source-file
           easymacs-claude--temp-file
           (list (cons easymacs-claude--source-file easymacs-claude--temp-file)))))

(defun easymacs-claude--review-build-for-file (source-file temp-file focus)
  "Build a review queue in SOURCE-FILE from TEMP-FILE.
When FOCUS is non-nil, move point to the first pending hunk."
  (let ((buf (find-file-noselect source-file))
        (count 0))
    (with-current-buffer buf
      (save-restriction
        (widen)
        (easymacs-claude-review-clear)
        (let* ((diff-text (easymacs-claude--diff-text temp-file source-file))
               (hunks (and diff-text (easymacs-claude--parse-diff diff-text)))
               (items (mapcar #'easymacs-claude--review-make-item hunks)))
          (setq easymacs-claude--review-items (vconcat items)
                easymacs-claude--review-total (length items)
                easymacs-claude--review-index 0)
          (setq count easymacs-claude--review-total)
          (if (> count 0)
              (progn
                (easymacs-claude-review-mode 1)
                (easymacs-claude--review-refresh-mode-line)
                (when focus
                  (unless (get-buffer-window buf t)
                    (display-buffer buf '(display-buffer-reuse-window
                                          display-buffer-pop-up-window)))
                  (easymacs-claude--review-goto 0)))
            (easymacs-claude-review-mode -1)
            (easymacs-claude--review-refresh-mode-line)))))
    count))

(defun easymacs-claude-review-start (&optional file-backups)
  "Create review queues for FILE-BACKUPS, an alist of (SOURCE . TEMP) files."
  (when easymacs-claude-review-queue
    (let* ((backups (or file-backups (easymacs-claude--review-default-backups)))
           (changed-files nil))
      (dolist (entry backups)
        (pcase-let ((`(,source-file . ,temp-file) entry))
          (when (and source-file
                     temp-file
                     (file-exists-p source-file)
                     (file-exists-p temp-file))
            (when (> (easymacs-claude--review-build-for-file
                      source-file temp-file (null changed-files))
                     0)
              (push source-file changed-files)))))
      (setq changed-files (nreverse changed-files))
      (if changed-files
          (message "Claude review queue ready in %d file(s): %s. C-c C-a accept, C-c C-r reject."
                   (length changed-files)
                   (mapconcat #'abbreviate-file-name changed-files ", "))
        (message "No Claude changes to review."))
      (easymacs-claude--review-refresh-queue-buffer-if-open)
      changed-files)))

(defun easymacs-claude-review-after-run (&optional file-backups)
  "Run review queues and optionally show the diff buffer."
  (if easymacs-claude-review-queue
      (progn
        (easymacs-claude-review-start file-backups)
        (when easymacs-claude-review-show-diff-buffer
          (when (fboundp 'easymacs-claude--show-diff)
            (easymacs-claude--show-diff))))
    (when (fboundp 'easymacs-claude--show-diff)
      (easymacs-claude--show-diff))))

(easymacs-claude--review-install-mode-line)
(easymacs-claude--review-sanitize-mode-line-misc-info)
(easymacs-claude--review-sanitize-mood-line-format)
(easymacs-claude--review-install-mood-line-segment)
(with-eval-after-load 'mood-line
  (easymacs-claude--review-sanitize-mood-line-format)
  (easymacs-claude--review-install-mood-line-segment))

(provide 'easymacs-claude-review)
;;; easymacs-claude-review.el ends here
