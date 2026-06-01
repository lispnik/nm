;;; nm.asd
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Your Name

(asdf:defsystem #:nm
  :description "Common Lisp bindings to libnm (NetworkManager) via GObject Introspection."
  :author      "Your Name"
  :license     "MIT"
  :version     "0.1.0"
  :depends-on  ("cffi" "cl-gobject-introspection")
  :serial t
  :components ((:file "src/package")
               (:file "src/library")
               (:file "src/client")
               (:file "src/device")
               (:file "src/main")))

(asdf:defsystem #:nm/cli
  :description "An nmcli-like command-line tool exercising the nm binding."
  :author      "Your Name"
  :license     "MIT"
  :version     "0.1.0"
  :depends-on  ("nm" "clingon")
  :serial t
  :components ((:file "src/cli"))
  :build-operation "program-op"
  :build-pathname "nm-cli"
  :entry-point "nm.cli:main")
