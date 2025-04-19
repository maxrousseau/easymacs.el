<div class="header" align="center">

# easymacs

<div class="logo">
<p align="center">
<img src="./media/mr-emacs-mascott.png" alt="mr-emacs-mascott.png" width="100px" />
<br>
A minimal emacs configuration.
</p>
</div>

</div>


## Motivation

Emacs is great. This project aims to create a simple configuration which contains the minimum viable components to make it a decent python editor with just a single file (similar to kickstart.nvim).

## Features

- Vim motions powered by Evil
- Python IDE-like experience
  - LSP
  - Documentation on function hover
  - Autocompletion
  - Snippets
  - REPL

### Not yet implemented
- Local LLM tab completion with minuet.el

## Installation and usage

This package requires Emacs version 29.1+

To use easymacs, first clone the repo.

Then simply add this to your ```~/.emacs``` or ```~/.emacs.d/init.el```
```lisp
;; Add the directory containing mr-simple to the load-path
(add-to-list 'load-path "path/to/easymacs/")
;; Require the package to load it
(require 'easymacs)
```

Then all packages should install automatically when you start emacs.


