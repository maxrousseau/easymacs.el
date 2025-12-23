;;; easymacs.el --- Opinionated Emacs config, refactored -*- lexical-binding: t -*-

;;; Commentary:
;; Opinionated Emacs config using use-package for package management,
;; defcustom for user variables, and :custom/:hook keywords for clarity.

;;; Features:
;; Single file config as a program, objective <300 LOC
;; - AI tab complete (no prompting*, just ghost text w/ minuet.el)
;; - A decent term w/ eat, vterm or mistt

;; macOS modifier keys (must be set before anything else)
(when (eq system-type 'darwin)
  (setq mac-command-modifier 'meta
        mac-option-modifier 'super))

(require 'package)
;; Basic package repositories and use-package bootstrap
(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/") t)
(package-initialize)
(unless (package-installed-p 'use-package)
  (package-refresh-contents)
  (package-install 'use-package))
(eval-and-compile
  (require 'use-package)
  (setq use-package-always-ensure t
        use-package-expand-minimally t))
(setq frame-resize-pixelwise t)

;; Custom group and variables
(defgroup easymacs nil
  "Opinionated Emacs config for Maxime Rousseau."
  :group 'convenience)

(defcustom easymacs-font-face "FiraCode Nerd Font"
  "Font family for Easymacs."
  :type 'string
  :group 'easymacs)

(defcustom easymacs-font-size "16"
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

;; Completion & Search
(global-auto-revert-mode 1)

(use-package ivy
  :demand t
  :custom
  (ivy-use-virtual-buffers t)
  (ivy-count-format "(%d/%d) ")
  :config
  (ivy-mode 1))

(use-package swiper
  :after ivy)


;; Terminal
(use-package eat
  :hook (eat-mode . eat-line-mode))

(use-package mistty
  :bind (("C-c s" . mistty-in-project)
         ("C-c S" . mistty)))

;; Appearance
(setq ring-bell-function 'ignore
      display-line-numbers-type 'relative)
(setq-default tab-width 4
              indent-tabs-mode t
              fill-column 120)

(display-time-mode 1)
(blink-cursor-mode -1)
(global-hl-line-mode 1)
(menu-bar-mode -1)
(tool-bar-mode -1)
(scroll-bar-mode -1)
(set-frame-font (concat easymacs-font-face " " easymacs-font-size) nil t)

(add-hook 'prog-mode-hook #'display-line-numbers-mode)
(add-hook 'text-mode-hook #'turn-on-auto-fill)
(add-hook 'prog-mode-hook #'turn-on-auto-fill)

(use-package aggressive-indent
  :hook (emacs-lisp-mode . aggressive-indent-mode))

;; Dired
(use-package dired
  :ensure nil
  :custom
  (dired-listing-switches "-l")
  :hook (dired-mode . dired-hide-details-mode))

;; Themes & Eye Candy
(use-package mood-line
  :custom
  (mood-line-glyph-alist mood-line-glyphs-fira-code)
  :config
  (mood-line-mode))

(use-package breadcrumb
  :config
  (breadcrumb-mode))

(use-package catppuccin-theme
  :config
  (setq catppuccin-flavor 'mocha)
  (load-theme 'catppuccin :no-confirm)
  (catppuccin-reload))

(use-package rainbow-delimiters
  :hook (prog-mode . rainbow-delimiters-mode))

;; Snippets
(use-package yasnippet
  :custom
  (yas-snippet-dirs (list easymacs-snippets-dir))
  :hook (prog-mode . yas-minor-mode)
  :config
  (yas-reload-all)
  (yas-global-mode 1))

(use-package yasnippet-snippets
  :after yasnippet)

;; Git
(use-package magit
  :bind (("C-x g" . magit-status)
         ("C-x C-g" . magit-status)))

;; AI Inline Completion
(use-package minuet
  :bind
  (("M-i" . minuet-show-suggestion)
   ("C-c m" . minuet-configure-provider)
   :map minuet-active-mode-map
   ("M-p" . minuet-previous-suggestion)
   ("M-n" . minuet-next-suggestion)
   ("M-a" . minuet-accept-suggestion))
  :config
  (setq minuet-provider 'openai-compatible)
  (setq minuet-request-timeout 2.5)
  (plist-put minuet-openai-compatible-options :end-point "https://openrouter.ai/api/v1/chat/completions")
  (plist-put minuet-openai-compatible-options :api-key "OPENROUTER_API_KEY")
  (plist-put minuet-openai-compatible-options :model "anthropic/claude-haiku-4.5")
  (minuet-set-optional-options minuet-openai-compatible-options :provider '(:sort "latency"))
  (minuet-set-optional-options minuet-openai-compatible-options :max_tokens 256)
  (minuet-set-optional-options minuet-openai-compatible-options :top_p 0.9))

;; Navigation & Commands (C-; prefix)
(use-package avy)

(define-prefix-command 'easymacs-leader-map)
(global-set-key (kbd "C-;") 'easymacs-leader-map)

(define-key easymacs-leader-map (kbd "f") #'counsel-find-file)
(define-key easymacs-leader-map (kbd "b") #'switch-to-buffer)
(define-key easymacs-leader-map (kbd "h") #'eldoc-box-help-at-point)
(define-key easymacs-leader-map (kbd "SPC") #'avy-goto-char-2)
(define-key easymacs-leader-map (kbd "l") #'avy-goto-line)
(define-key easymacs-leader-map (kbd "i") #'consult-imenu-multi)
(define-key easymacs-leader-map (kbd "s") #'swiper-isearch)
(define-key easymacs-leader-map (kbd "g") #'counsel-rg)
(define-key easymacs-leader-map (kbd "a") #'swiper-all)
(define-key easymacs-leader-map (kbd "x") #'company-yasnippet)

;; Python keybindings (C-; p prefix)
(define-prefix-command 'easymacs-python-map)
(define-key easymacs-leader-map (kbd "p") 'easymacs-python-map)

(define-key easymacs-python-map (kbd "r") #'run-python)
(define-key easymacs-python-map (kbd "s") #'python-shell-send-statement)
(define-key easymacs-python-map (kbd "d") #'python-shell-send-defun)
(define-key easymacs-python-map (kbd "v") #'python-shell-send-region)
(define-key easymacs-python-map (kbd "b") #'python-shell-send-buffer)
(define-key easymacs-python-map (kbd "l") #'python-shell-send-current-line)

(use-package which-key
  :diminish which-key-mode
  :custom
  (which-key-idle-delay 0.5)
  (which-key-popup-type 'side-window)
  (which-key-side-window-location 'bottom)
  (which-key-max-description-length 27)
  (which-key-max-display-columns 4)
  :config
  (which-key-mode))

;; Treesitter & LSP for Python
(use-package treesit-auto
  :custom
  (treesit-auto-install 'prompt)
  :config
  (treesit-auto-add-to-auto-mode-alist 'all)
  (global-treesit-auto-mode))

(use-package pyvenv
  :defer t)

(use-package eglot
  :hook ((python-mode . eglot-ensure)
         (python-ts-mode . eglot-ensure))
  :config
  (add-to-list 'eglot-server-programs
               '((python-mode python-ts-mode) . ("zubanls"))))

(use-package ruff-format
  :hook ((python-mode . ruff-format-on-save-mode)
         (python-ts-mode . ruff-format-on-save-mode)))

(use-package company
  :custom
  (company-idle-delay 0.2)
  (company-minimum-prefix-length 1)
  (company-tooltip-limit 20)
  (company-show-numbers t)
  (company-tooltip-align-annotations t)
  :config
  (global-company-mode))

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
                        tab-width 4
                        py-indent-tabs-mode t)
            (add-hook 'before-save-hook #'delete-trailing-whitespace nil t)))

(provide 'easymacs)
;;; easymacs.el ends here
