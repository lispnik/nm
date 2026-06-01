;;; nm.asd
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Matthew Kennedy

(asdf:defsystem #:nm
  :description "Common Lisp bindings to libnm (NetworkManager) via GObject Introspection."
  :author      "Matthew Kennedy"
  :license     "MIT"
  :version     "0.1.0"
  :depends-on  ("cffi" "cl-gobject-introspection" "trivial-garbage"
                "bordeaux-threads" "babel")
  :serial t
  :components ((:file "src/package")
               (:file "src/library")
               (:file "src/gvalue")
               (:file "src/loop")
               (:file "src/client")
               (:file "src/device")
               (:file "src/connection")
               (:file "src/async")
               (:file "src/monitor")
               (:file "src/main")))

(asdf:defsystem #:nm/cli
  :description "An nmcli-like command-line tool exercising the nm binding."
  :author      "Matthew Kennedy"
  :license     "MIT"
  :version     "0.1.0"
  :depends-on  ("nm" "clingon")
  :serial t
  :components ((:file "src/cli"))
  :build-operation "program-op"
  :build-pathname "nm-cli"
  :entry-point "nm.cli:main")

(asdf:defsystem #:nm/test
  :description "Smoke tests for the nm binding (requires a running NetworkManager)."
  :author      "Matthew Kennedy"
  :license     "MIT"
  :version     "0.1.0"
  :depends-on  ("nm")
  :serial t
  :components ((:file "src/test")))

(asdf:defsystem #:nm/test/unit
  :description "Pure unit tests for decoding/unpacking logic (no NetworkManager needed)."
  :author      "Matthew Kennedy"
  :license     "MIT"
  :version     "0.1.0"
  :depends-on  ("nm")
  :serial t
  :components ((:file "src/test-unit")))

(asdf:defsystem #:nm/test/mutation
  :description "Gated mutation tests (NM_TEST_MUTATE=1; requires root + NetworkManager)."
  :author      "Matthew Kennedy"
  :license     "MIT"
  :version     "0.1.0"
  :depends-on  ("nm")
  :serial t
  :components ((:file "src/test-mutation")))
