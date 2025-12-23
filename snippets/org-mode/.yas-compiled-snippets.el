;;; Compiled snippets and support files for `org-mode'
;;; Snippet definitions:
;;;
(yas-define-snippets 'org-mode
					 '(("nb" "** $1\n\n$2\n\n#+BEGIN_SRC\n$3\n#+END_SRC" "new noteblock" nil nil nil
						"/Users/mrousseau/code/easymacs/snippets/org-mode/note-block" nil nil)
					   ("newim"
						"#+CAPTION: $1\n#+NAME:   $2\n#+ATTR_HTML: :width 500px\n[[~/code/ebrain/notes/media/$3]]\n"
						"add a new image" nil nil nil "/Users/mrousseau/code/easymacs/snippets/org-mode/new-org-image"
						nil nil)
					   ("m*" "$$1$" "math" nil nil nil "/Users/mrousseau/code/easymacs/snippets/org-mode/math" nil nil)
					   ("cc" "$1 \\{\\{c1::$2\\}\\} $3 |" "cloze-card" nil nil nil
						"/Users/mrousseau/code/easymacs/snippets/org-mode/cloze_card" nil nil)
					   ("bc" "$1? | $2" "basic-card" nil nil nil
						"/Users/mrousseau/code/easymacs/snippets/org-mode/basic-card" nil nil)))


;;; Do not edit! File generated at Wed Apr 16 20:58:19 2025
