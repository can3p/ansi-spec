(defsystem ansi-spec
  :version "0.1"
  :author "Fernando Borretti"
  :homepage "https://github.com/eudoxia0/cl-ansi-spec"
  :license "MIT"
  :depends-on (:plump-tex
               :uiop
               :cl-ppcre
               :split-sequence
               :anaphora)
  :components ((:module "src"
                :serial t
                :components
                ((:file "file")
                 (:file "preprocess")
                 (:file "explicit-body")
                 (:file "traverse")
                 (:file "modes")
                 (:file "main"))))
  :description "The ANSI Common Lisp draft specification, parsed from TeX sources."
  :long-description
  #.(uiop:read-file-string
     (uiop:subpathname *load-pathname* "README.md"))
  :in-order-to ((test-op (test-op ansi-spec-test))))