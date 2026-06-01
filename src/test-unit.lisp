;;; test-unit.lisp
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Matthew Kennedy
;;;
;;; Pure unit tests for the binding's decoding and unpacking logic.  These do
;;; NOT touch NetworkManager (no client, no typelib calls), so they run on any
;;; platform -- useful for CI on non-Linux hosts.

(defpackage #:nm.test.unit
  (:use #:cl)
  (:export #:run #:run-tests))

(in-package #:nm.test.unit)

(defvar *pass* 0)
(defvar *fail* 0)

(defmacro check (form &optional desc)
  (let ((d (gensym)))
    `(let ((,d (or ,desc ',form)))
       (handler-case
           (if ,form
               (progn (incf *pass*) (format t "  ok   ~A~%" ,d))
               (progn (incf *fail*) (format t "  FAIL ~A~%" ,d)))
         (error (e)
           (incf *fail*)
           (format t "  ERR  ~A~%         => ~A~%" ,d e))))))

(defun run-tests ()
  "Run the pure unit tests.  Returns the number of failures."
  (setf *pass* 0 *fail* 0)

  (format t "~&keywordize~%")
  (check (eq (nm::keywordize "activated") :activated))
  (check (eq (nm::keywordize "ip_config") :ip-config) "underscores become dashes")
  (check (eq (nm::keywordize "key_mgmt_802_1x") :key-mgmt-802-1x))

  (format t "~&decode-enum~%")
  (let ((tbl '(("unknown" . 0) ("ethernet" . 1) ("wifi" . 2))))
    (check (eq (nm::decode-enum tbl 2) :wifi))
    (check (eq (nm::decode-enum tbl 0) :unknown))
    (check (eql (nm::decode-enum tbl 99) 99) "unmatched value passes through"))

  (format t "~&decode-flags~%")
  (let ((tbl '(("none" . 0) ("privacy" . 1) ("wps" . 2) ("wps-pbc" . 4))))
    (check (equal (nm::decode-flags tbl 0) '()) "empty bitfield -> nil")
    (check (equal (nm::decode-flags tbl 1) '(:privacy)))
    (check (equal (nm::decode-flags tbl 3) '(:privacy :wps)))
    (check (equal (nm::decode-flags tbl 5) '(:privacy :wps-pbc))))
  (let ((tbl '(("a" . 1) ("b" . 2) ("ab" . 3))))
    (check (equal (nm::decode-flags tbl 3) '(:a :b))
           "combined (multi-bit) entries are skipped"))

  (format t "~&octet/string round-trip~%")
  (check (string= (nm::octets->string (nm::string->octets "hello")) "hello"))
  (check (string= (nm::octets->string (nm::string->octets "héllo-wørld"))
                  "héllo-wørld")
         "UTF-8 round-trips")
  (check (string= (nm::octets->string #(72 105)) "Hi"))
  (check (null (nm::octets->string nil)))

  (format t "~&GPtrArray unpacking~%")
  (let ((n 4))
    (cffi:with-foreign-object (arr '(:struct nm::g-ptr-array))
      (let ((pdata (cffi:foreign-alloc :pointer :count n)))
        (unwind-protect
             (progn
               (dotimes (i n)
                 (setf (cffi:mem-aref pdata :pointer i)
                       (cffi:make-pointer (+ 1000 i))))
               (setf (cffi:foreign-slot-value arr '(:struct nm::g-ptr-array) 'nm::pdata)
                     pdata
                     (cffi:foreign-slot-value arr '(:struct nm::g-ptr-array) 'nm::len)
                     n)
               (let ((ptrs (nm::ptr-array-pointers arr)))
                 (check (= (length ptrs) n) "unpacks all elements")
                 (check (equal (mapcar #'cffi:pointer-address ptrs)
                               '(1000 1001 1002 1003))
                        "element pointers are correct")))
          (cffi:foreign-free pdata)))))
  (check (null (nm::ptr-array-pointers (cffi:null-pointer)))
         "NULL GPtrArray -> nil")

  (format t "~%~D passed, ~D failed~%" *pass* *fail*)
  *fail*)

(defun run ()
  "Entry point: run unit tests and exit non-zero on any failure."
  (uiop:quit (if (zerop (run-tests)) 0 1)))
