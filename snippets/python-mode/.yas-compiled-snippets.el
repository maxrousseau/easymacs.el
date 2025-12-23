;;; Compiled snippets and support files for `python-mode'
;;; Snippet definitions:
;;;
(yas-define-snippets 'python-mode
					 '(("nn"
						"class $1(nn.Module):\n      \"\"\"\n      $2\n      \"\"\"\n      def __init__(self):\n          super().__init__()\n\n      def forward(self, x):\n          $3\n          return $4"
						"nn module" nil nil nil "/Users/mrousseau/code/easymacs/snippets/python-mode/nn-module" nil nil)))


;;; Do not edit! File generated at Wed Apr 16 20:58:19 2025
