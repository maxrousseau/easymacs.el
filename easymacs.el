;;; easymacs.el --- Opinionated Emacs config, refactored -*- lexical-binding: t -*-

;;; Commentary:
;; Refactored using DRY helper macro, defcustom for user variables,
;; and use-package :custom/:hook keywords for clarity and maintainability.

;;; Features:
;; Single file config as a program, objective <300 LOC
;; @TODO: AI tab complete (no prompting*, just ghost text w/ minuet.el+ollama)
;; @TODO: highlights...
;; @TODO: a decent term w/ eat, vterm or mistt

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

;; Helper macro for feature definition and invocation
(defmacro easy-feature (name doc &rest body)
  "Define and immediately run an easy-NAME function with DOC and BODY."
  `(progn
     (defun ,(intern (concat "easy-" name)) ()
       ,doc
       ,@body)
     (,(intern (concat "easy-" name)))))

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

;; Feature: Completion & Search
(easy-feature "completion"
			  "Configure Ivy, Counsel, and Swiper for enhanced completion and search."
			  (global-auto-revert-mode 1) ;; claude code
			  (use-package ivy
				:custom
				(ivy-use-virtual-buffers t)
				(ivy-count-format "(%d/%d) ")
				:config
				(ivy-mode 1))
			  (use-package swiper :hook (ivy-mode . swiper))
			  (use-package counsel :hook (ivy-mode . counsel-mode)))

;; Feature: terminal with eshell, eat, and mistty
(easy-feature "terminal"
			  "Terminal emulation with eat and mistty."
			  (use-package eat
				:ensure t
				:hook
				(eat-mode . eat-line-mode))
			  (use-package mistty
				:ensure t
				:bind (("C-c s" . mistty-in-project)
					   ("C-c S" . mistty))))

;; Feature: Basic Appearances
(easy-feature "appearance"
			  "Default appearance settings for Easymacs."
			  (setq ring-bell-function 'ignore
					display-line-numbers-type 'relative)
			  (add-hook 'prog-mode-hook #'display-line-numbers-mode)
			  (display-time-mode 1)
			  (blink-cursor-mode -1)
			  (global-hl-line-mode 1)
			  (menu-bar-mode -1)
			  (tool-bar-mode -1)
			  (scroll-bar-mode -1)
			  (set-frame-font (concat easymacs-font-face " " easymacs-font-size) nil t)
			  (setq-default tab-width 4 indent-tabs-mode t
							fill-column 120)
			  (add-hook 'text-mode-hook #'turn-on-auto-fill)
			  (add-hook 'prog-mode-hook #'turn-on-auto-fill)
			  (use-package aggressive-indent :hook (emacs-lisp-mode . aggressive-indent-mode)))

;; Feature: Dired Enhancements
(easy-feature "dired"
"Set some Dired options."
(use-package dired
  :ensure nil
  :custom
  (dired-listing-switches "-l")
  :hook (dired-mode . dired-hide-details-mode)))

;; Feature: Themes & Padding
(easy-feature "eyecandy"
			  "Load theme and set frame padding."
			  (use-package mood-line
				;; Enable mood-line
				:config
				(mood-line-mode)
				;; Use pretty Fira Code-compatible glyphs
				:custom
				(mood-line-glyph-alist mood-line-glyphs-fira-code))
			  (use-package breadcrumb
				:ensure t
				:config
				(breadcrumb-mode))
			  (use-package catppuccin-theme
				:config
				(load-theme 'catppuccin :no-confirm)
				(setq catppuccin-flavor 'mocha) ;; or 'latte, 'macchiato, or 'mocha
				(catppuccin-reload)
				)
			  (use-package rainbow-delimiters :hook (prog-mode . rainbow-delimiters-mode)))

;; Feature: Snippets
(easy-feature "snippets"
			  "Configure yasnippet with personal and community snippet dirs."
			  (use-package yasnippet
				:custom
				(yas-snippet-dirs (list easymacs-snippets-dir))
				:config
				(yas-reload-all)
				(yas-global-mode 1)
				:hook (prog-mode . yas-minor-mode))
			  (use-package yasnippet-snippets :after yasnippet))
(easy-feature "git"
			  "Configure magit integration for version control"
			  (use-package magit
				:ensure t
				:bind (("C-x g" . magit-status)
					   ("C-x C-g" . magit-status))))

(easy-feature "ai-inline"
			  "Configure simple AI inline assistant with minuet"
			  (use-package minuet
				:bind
				(
				 ("M-i" . #'minuet-show-suggestion) ;; use overlay for completion
				 ("C-c m" . #'minuet-configure-provider)
				 :map minuet-active-mode-map
				 ;; These keymaps activate only when a minuet suggestion is displayed in the current buffer
				 ("M-p" . #'minuet-previous-suggestion) ;; invoke completion or cycle to next completion
				 ("M-n" . #'minuet-next-suggestion) ;; invoke completion or cycle to previous completion
				 ("M-a" . #'minuet-accept-suggestion) ;; accept whole completion
				 )
				:config
				(setq minuet-provider 'openai-compatible)
				(setq minuet-request-timeout 2.5) ;; TODO alert user when timeout exceeded
				;; TODO setup a system prompt
				(plist-put minuet-openai-compatible-options :end-point "https://openrouter.ai/api/v1/chat/completions")
				(plist-put minuet-openai-compatible-options :api-key "OPENROUTER_API_KEY")
				(plist-put minuet-openai-compatible-options :model "anthropic/claude-haiku-4.5")
				;; Prioritize throughput for faster completion
				(minuet-set-optional-options minuet-openai-compatible-options :provider '(:sort "latency"))
				(minuet-set-optional-options minuet-openai-compatible-options :max_tokens 256)
				(minuet-set-optional-options minuet-openai-compatible-options :top_p 0.9)))

;; Feature: Evil Motions
(easy-feature "motions"
			  "Vim-based motions and keybindings."
			  (use-package avy :ensure t)
			  (use-package evil
				:config
				(evil-mode 1)
				(evil-set-leader 'normal (kbd "SPC"))
				;; Make M-x work properly in all Evil states
				(evil-define-key '(normal insert visual emacs) 'global
				  (kbd "M-x") #'execute-extended-command)
				(evil-define-key 'insert 'global
				  (kbd "C-c x") #'yas-expand
				  )
				(evil-define-key 'insert 'global
				  (kbd "C-; x") #'company-yasnippet)
				(evil-define-key 'normal 'global
				  ;; <leader> f f → find-file
				  ;;(kbd "<leader> f") #'counsel-fzf ;; TODO should be setup to use repo root
				  (kbd "<leader> f") #'counsel-find-file
				  (kbd "<leader> b") #'switch-to-buffer
				  ;;(kbd "<leader> x b") #'kill-buffer
				  (kbd "<leader> h") #'eldoc-box-help-at-point


				  ;; avy navigation
				  (kbd "<leader> <SPC>") #'avy-goto-char-2
				  (kbd "<leader> l") #'avy-goto-line
				  (kbd "<leader> c i") #'consult-imenu-multi

				  ;; search
				  (kbd "<leader> s") #'swiper-isearch
				  (kbd "<leader> g") #'counsel-rg
				  (kbd "<leader> a") #'swiper-all

				  ;; snippets
				  (kbd "<leader> x")
				  (lambda ()
					(interactive)
					(evil-insert-state)
					(call-interactively #'company-yasnippet)))
				)

			  ;; python
			  (with-eval-after-load 'python          ;runs when either mode loads
				(dolist (map '(python-mode-map python-ts-mode-map))
				  (evil-define-key 'normal (symbol-value map)
					(kbd "<leader> p r") #'run-python
					(kbd "<leader> p s") #'python-shell-send-statement
					(kbd "<leader> p d") #'python-shell-send-defun
					(kbd "<leader> p v") #'python-shell-send-region
					(kbd "<leader> p b") #'python-shell-send-buffer
					(kbd "<leader> p l") #'python-shell-send-current-line)))
			  (use-package which-key
				:defer nil
				:diminish which-key-mode
				:custom
				(which-key-idle-delay 0.5)
				(which-key-popup-type 'side-window)
				(which-key-side-window-location 'bottom)
				(which-key-max-description-length 27)
				(which-key-max-display-columns 4)
				:config
				(which-key-mode))

			  )

;; Feature: Treesitter & LSP for Python
(easy-feature "python-ide"
			  "Setup Python LSP, formatting, and completion."
			  (use-package treesit-auto
				:custom
				(treesit-auto-install 'prompt)
				:config
				(treesit-auto-add-to-auto-mode-alist 'all)
				(global-treesit-auto-mode))
			  (use-package pyvenv :defer t)
			  (use-package eglot
				:hook ((python-mode . eglot-ensure)
					   (python-ts-mode . eglot-ensure))
				:config
				(add-to-list 'eglot-server-programs
							 '((python-mode python-ts-mode) . ("zubanls")))))
(use-package ruff-format :hook ((python-mode . ruff-format-on-save-mode)
								(python-ts-mode . ruff-format-on-save-mode)))
(use-package company
  :custom
  (company--idle-delay 0.2)
  (company-minimum-prefix-length 1)
  (company-tooltip-limit 20)
  (company-show-numbers t)
  (company-tooltip-align-annotations t)
  :config
  (global-company-mode)
  )
;; ─── Pop the box only when I ask ──────────────────────────────────────────────
(use-package eldoc-box
  :defer t                     ; don’t activate anything until we call it
  ;; no :hook line → hover modes stay off
  :custom
  ;; one-liners still go to the minibuffer; multi-line docs need the key-press
  (eldoc-box-only-multi-line t))
;; Show Eldoc in a child-frame anchored to the lower-right corner
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
