<div class="header" align="center">

# mr-emacs

<div class="logo">
<p align="center">
<img src="./media/mr-emacs-mascott.png" alt="mr-emacs-mascott.png" width="100px" />
<br>
A minimal emacs configuration.
</p>
</div>

</div>


## Motivation

Emacs is great. This project aims to create a simple configuration which contains the minimum viable components to make it a decent user interface with just a single file (similar to kickstart).

## Features

- Vim motions powered by Evil
- Python IDE-like experience
  - LSP
  - Documentation on function hover
  - Autocompletion
  - Snippets
  - REPL
- Local LLM ghosttext

## Installation and usage

Requires Emacs version 29.1+

Simply add this to your ```~/.emacs``` or ```~/.emacs.d/init.el```
```lisp
;; Add the directory containing mr-simple to the load-path
(add-to-list 'load-path "path/to/easymacs/")
;; Require the package to load it
(require 'easymacs)
```
