;; objective <600 LOC
;; @DONE: initialize use-package so that everything is nicely setup for you
;; @DONE: simplify startup (keep in dir)
;; @DONE: snippets (yas)
;; @DONE python lsp + autocomplete

;; AI tab complete (no prompting*, just ghost text w/ minuet.el+ollama)
;; @TODO: python floating window repl (chatgpt how to do this)
;; @TODO: fix up the essential evil keybindings
;; @NOTE: python dap (some package supports this like vscode) -> just use vscode in this case...

(provide 'easymacs)

(setq easy-font-face       "Hack"
      easy-font-size       "16"
      easy-personal-snippets (expand-file-name "~/code/easymacs/snippets")
      )
(setenv "PATH" (concat (getenv "PATH") "/opt/homebrew/bin"))
(setq exec-path (append exec-path '("/opt/homebrew/bin")))

(use-package aggressive-indent
  :ensure t
  :config
  (add-hook 'emacs-lisp-mode-hook #'aggressive-indent-mode))

(progn
  (defun easy-setup-packages ()
	"Setup the packages repositories and USE-PACKAGE."
	(require 'package)
	(add-to-list 'package-archives '("melpa" . "https://melpa.org/packages/"))
	(package-initialize)

	(unless (package-installed-p 'use-package)
	  (package-refresh-contents)
	  (package-install 'use-package))

	(eval-and-compile
	  (setq use-package-always-ensure t
			use-package-expand-minimally t))

	(eval-when-compile
	  (require 'use-package)))
  (setq inhibit-startup-screen t) ;; no startup screen
  (easy-setup-packages))

(progn
  (defun easy-completion-and-selection ()
	"Configure Ivy, Counsel, and Swiper for enhanced completion and search.

Enables `ivy-mode` for Ivy-based completion, with virtual buffers and count format.
Sets up Swiper for improved buffer search and Counsel for extended command enhancements."
	(use-package ivy
	  :config
	  (ivy-mode 1)
	  (setq ivy-use-virtual-buffers t)
	  (setq ivy-count-format "(%d/%d) "))
	(use-package swiper)
	(use-package counsel))
  (easy-completion-and-selection))


(progn
  (defun easy-basic-appearances ()
	"Default appearance settings for easymacs."
	
	(setq ring-bell-function 'ignore) ;; bell
	(global-hi-lock-mode 1) ;; actually don't remember what this does
	(setq display-line-numbers-type 'relative)
	(add-hook 'prog-mode-hook 'display-line-numbers-mode) ;; only for prog mode

	;; highlights
	(defun keyword-highlight()
	  (interactive)
	  "highlight todos, notes and more"
	  (highlight-regexp "@TODO" 'hi-pink)
	  (highlight-regexp "@BUG" 'hi-red)
	  (highlight-regexp "@HERE" 'hi-green)
	  (highlight-regexp "@NOTE" 'hi-blue))
	(add-hook 'find-file-hook (lambda () (keyword-highlight)))

	;; disable all GUI bars
	(display-time-mode 1)
	(blink-cursor-mode -1)
	(global-hl-line-mode 1)
	(menu-bar-mode -1)
	(tool-bar-mode -1)
	(scroll-bar-mode -1)

	;; fonts
	(set-frame-font (concat easy-font-face " " easy-font-size) nil t) ;; fonts

	;; indentation
	(setq-default tab-width 4 indent-tabs-mode t)

	;; autrowrap 120
	(setq-default fill-column 120)
	(setq auto-fill-mode t)
	(add-hook 'text-mode-hook 'turn-on-auto-fill)
	(add-hook 'prog-mode-hook 'turn-on-auto-fill))
  (easy-basic-appearances))

(progn
  (defun easy-dired-options ()
	"Set some Dired options."
	(setq dired-listing-switches "-l")
	(add-hook 'dired-mode-hook
			  (lambda ()
				(dired-hide-details-mode))))
  (easy-dired-options))

(progn
  (defun easy-eyecandy ()
	"Set light/dark theme and other preferences."
	(use-package modus-themes
	  :ensure t
	  :config
	  (load-theme 'modus-vivendi-tinted :no-confirm)
	  )
	(use-package spacious-padding
	  :ensure t
	  :config
	  (setq spacious-padding-subtle-mode-line t)
	  (setq spacious-padding-widths
			'(
			  :internal-border-width 40
			  :right-divider-width -1)
			)
	  (spacious-padding-mode 1)
	  )
	)
  (use-package rainbow-delimiters
	:ensure t
	:config
	(rainbow-delimiters-mode 1)
	(add-hook 'prog-mode-hook 'rainbow-delimiters-mode)
	)
  (easy-eyecandy))

(progn
  (defun easy-snippets ()
    "Configures local directory and builtin snippets with yasnippet."

	;; bring in yasnippet itself
	(use-package yasnippet
	  :ensure t
	  :init
	  (setq yas-snippet-dirs
			(list easy-personal-snippets)) 
	  :config
	  (yas-reload-all)
	  (yas-global-mode 1)
	  (add-hook 'prog-mode-hook #'yas-minor-mode))

	;; then install & load the community snippets
	(use-package yasnippet-snippets
	  :after yasnippet
	  :ensure t
	  :config

      (yas-recompile-all)
      (yas-reload-all)
      (yas-global-mode 1)
      (add-hook 'prog-mode-hook #'yas-minor-mode))
	)

  (easy-snippets))

;; @HERE
(progn
  (defun easy-motions ()
	"vim based motions and text editing keybindings."
	(use-package evil
	  :ensure t
	  :config
	  (evil-mode 1)) ;; map <space> as localleader
	)
  (easy-motions)
  )

(progn
  (use-package treesit-auto
	:custom
	(treesit-auto-install 'prompt)
	:config
	(treesit-auto-add-to-auto-mode-alist 'all)
	(global-treesit-auto-mode))

  (use-package pyvenv
	:ensure t
	:defer t)

  (use-package eglot
	:hook ((python-mode    . eglot-ensure)
		   (python-ts-mode . eglot-ensure))
	:config
	(add-to-list 'eglot-server-programs
				 '(python-mode . ("pyright-langserver" "--stdio")))
	)

  (use-package ruff-format
	:ensure t
	:config
	(add-hook 'python-mode-hook 'ruff-format-on-save-mode)
	(add-hook 'python-ts-mode-hook 'ruff-format-on-save-mode)
	)

  ;; programming
  (add-hook 'python-mode-hook
			(lambda ()
			  (setq-default indent-tabs-mode nil)
			  (setq-default tab-width 4)
			  (setq-default py-indent-tabs-mode t)
			  (add-to-list 'write-file-functions 'delete-trailing-whitespace)))

  ;; Company-mode setup
  (use-package company
	:ensure t
	:init
	(global-company-mode)
	:custom
	(company-idle-delay 0.0)                ;; Immediate completion
	(company-minimum-prefix-length 1)       ;; Start completing after typing 1 character
	(company-tooltip-limit 20)              ;; Limit number of suggestions
	(company-show-numbers t)                ;; Number suggestions for quick selection
	(company-tooltip-align-annotations t))  ;; Align annotations nicely

  ;; Company quickhelp for popup documentation
  (use-package company-quickhelp
	:ensure t
	:after company
	:init
	(company-quickhelp-mode)
	:custom
	(company-quickhelp-delay 0.2))          ;; Popup documentation delay

  ;; Eldoc-box (remains the same)
  (use-package eldoc-box
	:ensure t
	:hook (eldoc-mode . eldoc-box-hover-mode))

  ;; Enable Company backends (similar to cape functionality)
  (add-to-list 'company-backends '(company-capf company-dabbrev company-files company-keywords company-elisp))

  ;; Keybinding to manually invoke Company completions documentation
  (with-eval-after-load 'company
	(define-key company-active-map (kbd "M-d") #'company-quickhelp-manual-begin))
  )
