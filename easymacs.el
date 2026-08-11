;;; easymacs.el --- A kickstart.nvim-style Emacs config -*- lexical-binding: t -*-
;;; Commentary:
;; One readable file with sensible defaults. No framework, no layers—just
;; use-package declarations you can understand and extend.
;; Requires Emacs 30+

;; macOS modifier keys (must be set before anything else)
;; (when (eq system-type 'darwin)
;;   (setq mac-command-modifier 'meta
;;         mac-option-modifier 'super))
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))

;; Load the newer of .el/.elc so edits to this config take effect without
;; a manual byte-recompile.
(setq load-prefer-newer t)

(require 'package)
;; Basic package repositories and use-package bootstrap
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(package-initialize)
(eval-and-compile
  (require 'use-package)
  (setq use-package-always-ensure t
        use-package-expand-minimally t))
(setq frame-resize-pixelwise t)

;; Custom group and variables
(defgroup easymacs nil
  "Opinionated Emacs config for Maxime Rousseau."
  :group 'convenience)

(defcustom easymacs-font-face "Hack"
  "Font family for Easymacs."
  :type 'string
  :group 'easymacs)

(defcustom easymacs-font-size "14"
  "Font size for Easymacs."
  :type 'string
  :group 'easymacs)

(defcustom easymacs-snippets-dir (expand-file-name "~/code/easymacs/snippets")
  "Directory for personal yasnippet snippets."
  :type 'directory
  :group 'easymacs)

;; GUI Emacs launched from the macOS Applications folder starts via launchd
;; with a minimal PATH and never sources ~/.zshrc, so tools under ~/.local/bin
;; (uv, etc.), Homebrew, cargo, and friends are invisible to eshell/compile.
;; Import the real shell environment.  A terminal `emacs -nw' already inherits
;; a correct PATH from the shell it was launched in, so only pay the
;; shell-spawn cost for GUI/daemon frames.
(use-package exec-path-from-shell
  :if (or (memq window-system '(mac ns x)) (daemonp))
  :config
  (exec-path-from-shell-initialize))

;; Store Emacs backup and auto-save files outside the repo
(defcustom easymacs-backup-dir (expand-file-name "backups" user-emacs-directory)
  "Directory for Emacs backup files."
  :type 'directory
  :group 'easymacs)

(defcustom easymacs-autosave-dir (expand-file-name "autosaves" user-emacs-directory)
  "Directory for Emacs auto-save files."
  :type 'directory
  :group 'easymacs)

;; Ensure directories exist
(dolist (dir (list easymacs-backup-dir easymacs-autosave-dir))
  (unless (file-exists-p dir)
    (make-directory dir t)))

(setq backup-directory-alist `(("." . ,easymacs-backup-dir))
      auto-save-file-name-transforms `((".*" ,easymacs-autosave-dir t))
      auto-save-list-file-prefix (expand-file-name ".saves-" easymacs-autosave-dir))

;; Suppress startup screen
(setq inhibit-startup-screen t)

;; Completion & Search — ivy is eager because we wire it into leader keys
;; below, but its setup is cheap.
(use-package ivy
  :custom
  (ivy-use-virtual-buffers t)
  (ivy-count-format "(%d/%d) ")
  :config
  (ivy-mode 1))

(use-package counsel
  :after ivy
  :defer t)

(use-package swiper
  :after ivy
  :defer t)

;; Auto-revert: defer until the first buffer hooks us in.
(add-hook 'emacs-startup-hook #'global-auto-revert-mode)

;; Terminal
(use-package eat
  :hook (eat-mode . eat-line-mode))

(use-package mistty
  :bind (("C-c s" . mistty-in-project)
         ("C-c S" . mistty)
         ("C-c M-s" . mistty-create)))

;; Appearance
(setq ring-bell-function 'ignore
      display-line-numbers-type 'relative)
(setq-default tab-width 4
              indent-tabs-mode t
              fill-column 120)

;; These are cheap and wanted everywhere.
(blink-cursor-mode -1)
(global-hl-line-mode 1)

(setq-default cursor-type 'box)

;; Font is a GUI-only concern; setting it in a TTY frame is a no-op that
;; still costs work.  Run it after init on the first graphical frame.
(defun easymacs--set-font (&optional frame)
  (when (display-graphic-p frame)
    (set-frame-font (concat easymacs-font-face " " easymacs-font-size) nil t)
    (remove-hook 'after-make-frame-functions #'easymacs--set-font)))
(if (daemonp)
    (add-hook 'after-make-frame-functions #'easymacs--set-font)
  (add-hook 'emacs-startup-hook #'easymacs--set-font))

;; Time in modeline — defer a tick so it doesn't run during init.
(add-hook 'emacs-startup-hook #'display-time-mode)

;; Mouse support in TTY frames.  Without `xterm-mouse-mode', tmux (which
;; has `mouse on') swallows scroll-wheel events and enters its own
;; copy-mode instead of passing them through to Emacs.  Enabling this
;; makes Emacs declare mouse tracking, and tmux forwards events.
;; tty-setup-hook fires on each new TTY frame (also handles daemon case).
(add-hook 'tty-setup-hook #'xterm-mouse-mode)
(unless (display-graphic-p) (xterm-mouse-mode 1))

;; TTY clipboard sync via OSC 52.  In GUI frames Emacs hands kills to the
;; system pasteboard automatically; in a terminal it has no direct
;; channel, so we encode the killed text as an OSC 52 escape sequence and
;; send it to the terminal.  Ghostty interprets it; tmux passes it
;; through because `set-clipboard on' is set in ~/.config/tmux/tmux.conf.
(defun easymacs--osc52-copy (text)
  "Write TEXT to the terminal's clipboard via OSC 52."
  (send-string-to-terminal
   (concat "\e]52;c;"
           (base64-encode-string (encode-coding-string text 'utf-8) t)
           "\e\\")))

(defun easymacs--enable-tty-clipboard (&optional _frame)
  (unless (display-graphic-p)
    (setq interprogram-cut-function #'easymacs--osc52-copy)))
(add-hook 'tty-setup-hook #'easymacs--enable-tty-clipboard)
(easymacs--enable-tty-clipboard)

(add-hook 'prog-mode-hook #'display-line-numbers-mode)
(add-hook 'text-mode-hook #'turn-on-auto-fill)
(add-hook 'prog-mode-hook #'turn-on-auto-fill)

(use-package aggressive-indent
  :hook (emacs-lisp-mode . aggressive-indent-mode))

(use-package dired
  :ensure nil
  :custom
  (dired-listing-switches "-l")
  :hook (dired-mode . dired-hide-details-mode))

(use-package mood-line
  :hook (emacs-startup . mood-line-mode)
  :custom
  (mood-line-glyph-alist mood-line-glyphs-fira-code))

(use-package breadcrumb
  :hook (emacs-startup . breadcrumb-mode))

;; (use-package catppuccin-theme
;;   :config
;;   (setq catppuccin-flavor 'mocha)
;;   (load-theme 'catppuccin :no-confirm))
(use-package modus-themes
  :config
  (modus-themes-load-theme 'modus-vivendi-tinted))

;; Multi-eshell helpers (C-; C-e new / C-; e switch).  Named buffers beat
;; `C-u M-x eshell' numbering; ivy-mode makes the plain `completing-read'
;; a proper fuzzy menu, so no aweshell dependency needed.
(defun easymacs-eshell-new (name)
  "Open (or switch to) an eshell session named NAME."
  (interactive "sEshell name: ")
  (let ((eshell-buffer-name (format "*eshell: %s*" name)))
    (eshell)))

;; Type `cdi' at any eshell prompt to pick the target directory with ivy
;; (navigate with C-j to descend, RET to accept) instead of typing the path.
(defun eshell/cdi (&rest _)
  "Interactively choose a directory with completion and cd into it."
  (eshell/cd (read-directory-name "cd: ")))

(defun easymacs-eshell-switch ()
  "Switch to an eshell buffer, with completion when there are several."
  (interactive)
  (let ((bufs (seq-filter (lambda (b)
                            (eq (buffer-local-value 'major-mode b) 'eshell-mode))
                          (buffer-list))))
    (cond
     ((null bufs) (call-interactively #'easymacs-eshell-new))
     ((null (cdr bufs)) (switch-to-buffer (car bufs)))
     (t (switch-to-buffer
         (completing-read "Eshell: " (mapcar #'buffer-name bufs) nil t))))))

;; Manual toggle between catppuccin mocha (dark) and latte (light).
;; Bound to C-; t below.
(defun easymacs-toggle-theme ()
  "Toggle between catppuccin mocha and latte."
  (interactive)
  (let ((next (if (eq catppuccin-flavor 'mocha) 'latte 'mocha)))
    (mapc #'disable-theme custom-enabled-themes)
    (setq catppuccin-flavor next)
    (load-theme 'catppuccin :no-confirm)
    (message "theme: catppuccin %s" next)))

;; In a TTY frame, themes paint the `default' face with an explicit
;; background, which Ghostty renders opaquely — killing the terminal's
;; `background-opacity' window transparency.  Clearing the default bg to
;; `unspecified-bg' tells Emacs to leave cells unpainted so the terminal
;; shows through.  Runs after every theme load (including our toggle).
(defun easymacs--tty-transparent-bg (&rest _)
  (unless (display-graphic-p)
    (set-face-background 'default "unspecified-bg")
    ;; Line-number column paints bg too; match it so it also inherits.
    (set-face-background 'line-number "unspecified-bg")))
(advice-add 'load-theme :after #'easymacs--tty-transparent-bg)
(easymacs--tty-transparent-bg)

(use-package rainbow-delimiters
  :hook (prog-mode . rainbow-delimiters-mode))

;; yasnippet was eager with `yas-global-mode', which reload-all's hundreds
;; of snippet files at startup.  Defer until a real editing buffer opens.
(use-package yasnippet
  :defer t
  :hook ((prog-mode text-mode) . yas-minor-mode)
  :config
  (add-to-list 'yas-snippet-dirs easymacs-snippets-dir)
  (yas-reload-all))

(use-package yasnippet-snippets
  :after yasnippet)

(use-package magit
  :bind (("C-x g" . magit-status)
         ("C-x C-g" . magit-status)))

(use-package forge
  :after magit)

;; Navigation & Commands (C-; prefix)
(use-package avy
  :defer t
  :commands (avy-goto-char-2 avy-goto-line))

(use-package ace-window
  :bind ("M-o" . ace-window)
  :custom
  (aw-keys '(?a ?s ?d ?f ?g ?h ?j ?k ?l))
  (aw-scope 'frame))

(define-prefix-command 'easymacs-leader-map)
(global-set-key (kbd "C-;") 'easymacs-leader-map)
(global-set-key (kbd "C-x C-b") 'switch-to-buffer)

;; Unbind `suspend-frame' so a stray C-z (muscle memory from tmux's new
;; prefix) doesn't accidentally background Emacs when running outside tmux.
(global-unset-key (kbd "C-z"))
(global-unset-key (kbd "C-x C-z"))

(define-key easymacs-leader-map (kbd "f") #'counsel-find-file)
(define-key easymacs-leader-map (kbd "b") #'switch-to-buffer)
(define-key easymacs-leader-map (kbd "h") #'eldoc-box-help-at-point)
;; (define-key easymacs-leader-map (kbd "SPC") #'avy-goto-char-2)
(define-key easymacs-leader-map (kbd "j") #'avy-goto-char-2)
(define-key easymacs-leader-map (kbd "C-;") #'avy-goto-char-2)
(define-key easymacs-leader-map (kbd "l") #'avy-goto-line)
(define-key easymacs-leader-map (kbd "i") #'consult-imenu-multi)
(define-key easymacs-leader-map (kbd "s") #'swiper-isearch)
(define-key easymacs-leader-map (kbd "g") #'counsel-rg)
(define-key easymacs-leader-map (kbd "a") #'swiper-all)
(define-key easymacs-leader-map (kbd "x") #'company-yasnippet)
(define-key easymacs-leader-map (kbd "t") #'easymacs-toggle-theme)
(define-key easymacs-leader-map (kbd "u") #'revert-buffer-quick)
(define-key easymacs-leader-map (kbd "e") #'easymacs-eshell-switch)
(define-key easymacs-leader-map (kbd "C-e") #'easymacs-eshell-new)

;; Python keybindings (C-; p prefix)
(define-prefix-command 'easymacs-python-map)
(define-key easymacs-leader-map (kbd "p") 'easymacs-python-map)

(define-key easymacs-python-map (kbd "r") #'run-python)
(define-key easymacs-python-map (kbd "s") #'python-shell-send-statement)
(define-key easymacs-python-map (kbd "d") #'python-shell-send-defun)
(define-key easymacs-python-map (kbd "v") #'python-shell-send-region)
(define-key easymacs-python-map (kbd "b") #'python-shell-send-buffer)
(define-key easymacs-python-map (kbd "l") #'python-shell-send-current-line)

(add-hook 'emacs-startup-hook
          (lambda () (when (display-graphic-p) (tab-bar-mode 1)))) ;; tabs (GUI only)
(define-key easymacs-leader-map (kbd "TAB") #'tab-switch)       ;; ivy-powered tab switch
(define-key easymacs-leader-map (kbd "T")   #'tab-new)
(define-key easymacs-leader-map (kbd "w")   #'tab-close)

;; which-key is builtin on Emacs 30+, but enabling it eagerly costs a
;; little; defer to after startup.
(setq which-key-idle-delay 0.5
      which-key-side-window-location 'bottom
      which-key-max-description-length 27
      which-key-max-display-columns 4)
(add-hook 'emacs-startup-hook #'which-key-mode)

;; Treesitter — defer until a real file opens.  `global-treesit-auto-mode'
;; only needs to be on before the first visit, so emacs-startup-hook is fine.
(use-package treesit-auto
  :defer t
  :hook (emacs-startup . global-treesit-auto-mode)
  :custom
  (treesit-auto-install 'prompt)
  :config
  (treesit-auto-add-to-auto-mode-alist 'all))

(use-package pyvenv
  :defer t)

;; Activate the repo's .venv before starting eglot so the LSP server
;; inherits the right interpreter + site-packages.
(defun easymacs--python-setup ()
  (require 'pyvenv)
  (when-let* ((proj (project-current))
              (root (project-root proj))
              (venv (expand-file-name ".venv" root))
              ((file-directory-p venv)))
    (pyvenv-activate venv))
  (eglot-ensure))

(use-package eglot
  :ensure nil ;; builtin
  :hook ((python-mode . easymacs--python-setup)
         (python-ts-mode . easymacs--python-setup))
  :config
  (add-to-list 'eglot-server-programs
               '((python-mode python-ts-mode) . ("zubanls"))))

(use-package ruff-format
  :hook ((python-mode . ruff-format-on-save-mode)
         (python-ts-mode . ruff-format-on-save-mode)))

(use-package company
  :defer t
  :hook ((prog-mode . company-mode)
         (text-mode . company-mode))
  :custom
  (company-idle-delay 0.2)
  (company-minimum-prefix-length 1)
  (company-tooltip-limit 20)
  (company-show-numbers t)
  (company-tooltip-align-annotations t))

;; Eldoc
(use-package eldoc-box
  :defer t
  :custom
  (eldoc-box-only-multi-line t))

;; Python settings
(setq python-shell-interpreter "ipython"
      python-shell-interpreter-args "-i --simple-prompt")

(defun easymacs--python-style ()
  (setq-local indent-tabs-mode nil
              tab-width 2
              python-indent-offset 2)
  (add-hook 'before-save-hook #'delete-trailing-whitespace nil t))

;; Apply to both classic and tree-sitter modes — treesit-auto remaps
;; .py files to `python-ts-mode', which has its own hook.
(add-hook 'python-mode-hook    #'easymacs--python-style)
(add-hook 'python-ts-mode-hook #'easymacs--python-style)

(provide 'easymacs)
;;; easymacs.el ends here
