;;; easymacs.el --- A kickstart.nvim-style Emacs config -*- lexical-binding: t -*-
;;; Commentary:
;; One readable file with sensible defaults. No framework, no layers—just
;; use-package declarations you can understand and extend.
;; Requires Emacs 29.1+

;; macOS modifier keys (must be set before anything else)
;; (when (eq system-type 'darwin)
;;   (setq mac-command-modifier 'meta
;;         mac-option-modifier 'super))
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))

(require 'package)
;; Basic package repositories and use-package bootstrap
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(package-initialize)
(eval-and-compile
  (require 'use-package)
  (setq use-package-always-ensure t
        use-package-expand-minimally t))
(setq frame-resize-pixelwise t)

;; `exec-path-from-shell' was here, but it spawns a subshell on every start
;; (hundreds of ms).  We set PATH explicitly below, which is all we actually
;; need on this machine.

;; Custom group and variables
(defgroup easymacs nil
  "Opinionated Emacs config for Maxime Rousseau."
  :group 'convenience)

(defcustom easymacs-font-face "FiraCode Nerd Font"
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


;; Adjust PATH for Homebrew binaries, optional based on your config
(setenv "PATH" (concat (getenv "PATH") ":/opt/homebrew/bin"))
(add-to-list 'exec-path "/opt/homebrew/bin")

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

(use-package catppuccin-theme
  :config
  (setq catppuccin-flavor 'mocha)
  (load-theme 'catppuccin :no-confirm))

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
(define-key easymacs-leader-map (kbd "t") #'load-theme)

;; Python keybindings (C-; p prefix)
(define-prefix-command 'easymacs-python-map)
(define-key easymacs-leader-map (kbd "p") 'easymacs-python-map)

(define-key easymacs-python-map (kbd "r") #'run-python)
(define-key easymacs-python-map (kbd "s") #'python-shell-send-statement)
(define-key easymacs-python-map (kbd "d") #'python-shell-send-defun)
(define-key easymacs-python-map (kbd "v") #'python-shell-send-region)
(define-key easymacs-python-map (kbd "b") #'python-shell-send-buffer)
(define-key easymacs-python-map (kbd "l") #'python-shell-send-current-line)

(add-hook 'emacs-startup-hook #'tab-bar-mode) ;; tabs
(define-key easymacs-leader-map (kbd "TAB") #'tab-switch)       ;; ivy-powered tab switch
(define-key easymacs-leader-map (kbd "T")   #'tab-new)
(define-key easymacs-leader-map (kbd "w")   #'tab-close)

;; Claude Code Integration — autoload rather than require so cc.el and its
;; (cheap but non-zero) deps aren't touched until you invoke a command.
(autoload 'cc-query "cc" nil t)
(autoload 'cc-new-session "cc" nil t)
(autoload 'cc-stop "cc" nil t)
(autoload 'cc-dismiss "cc" nil t)
(define-prefix-command 'easymacs-claude-map)
(define-key easymacs-leader-map (kbd "C-c") 'easymacs-claude-map)
(define-key easymacs-claude-map (kbd "c") #'cc-query)
(define-key easymacs-claude-map (kbd "n") #'cc-new-session)
(define-key easymacs-claude-map (kbd "k") #'cc-stop)


;; setup god-mode — autoload on first toggle instead of eagerly loading.
(use-package god-mode
  :defer t
  :commands (god-mode-all god-local-mode)
  :init
  ;; GUI: <escape> is a real key, bind it directly.
  ;; TTY: <escape> is the Meta prefix (\e + key == M-key), so binding it
  ;; would break every Meta keystroke.  Use C-\ in terminal instead.
  (if (display-graphic-p)
      (global-set-key (kbd "<escape>") #'god-mode-all)
    (global-set-key (kbd "C-\\") #'god-mode-all))
  :config
  (setq god-exempt-major-modes nil
        god-exempt-predicates
        (list (lambda () (derived-mode-p 'magit-mode 'dired-mode))))
  (defun my-god-mode-update-cursor-type ()
    (setq cursor-type (if (or god-local-mode buffer-read-only) 'box 'hbar)))
  (add-hook 'post-command-hook #'my-god-mode-update-cursor-type))

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

(use-package eglot
  :ensure nil ;; builtin
  :hook ((python-mode . eglot-ensure)
         (python-ts-mode . eglot-ensure))
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

(add-hook 'python-mode-hook
          (lambda ()
            (setq-local indent-tabs-mode nil
                        tab-width 2
                        python-indent-offset 2)
            (add-hook 'before-save-hook #'delete-trailing-whitespace nil t)))

(provide 'easymacs)
;;; easymacs.el ends here
