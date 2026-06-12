# easymacs

<p align="center">
<img src="./media/mr-emacs-mascott.png" alt="mr-emacs-mascott" width="100px" />
<br>
A minimal Emacs configuration.
</p>

## Why

A single-file Emacs config (à la kickstart.nvim) with sensible defaults for Python development. No framework, no layers—just a readable starting point you can understand and extend.

## Features

- Python IDE: LSP (eglot), completion, snippets, REPL
- avy/ace-window for quick navigation

## Installation

Requires Emacs 29.1+

```lisp
(add-to-list 'load-path "path/to/easymacs/")
(require 'easymacs)
```

## Keybindings

| Key | Action |
|-----|--------|
| `C-;` | Leader prefix |
| `C-; j` | avy-goto-char-2 |
| `C-; l` | avy-goto-line |
| `M-o` | ace-window |
