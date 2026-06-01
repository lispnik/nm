;;; test-mutation.lisp
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Matthew Kennedy
;;;
;;; Mutation test suite for the v2 management layer.  Unlike nm/test (which is
;;; read-only and safe), this CREATES, ACTIVATES, MODIFIES and DELETES a real
;;; connection profile, so it is gated behind the NM_TEST_MUTATE=1 environment
;;; variable and requires root/PolicyKit authorization.
;;;
;;; It operates only on a throwaway `dummy' device (no IP), so it never touches
;;; real connectivity -- crucially, never the interface you may be connected
;;; over.  All artifacts are removed in an unwind-protect.

(defpackage #:nm.test.mutation
  (:use #:cl)
  (:export #:run #:run-tests))

(in-package #:nm.test.mutation)

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

(defparameter +id+ "nm-mutation-test")
(defparameter +iface+ "nmmut0")

(defun profile-named (id)
  (find id (nm:connections (nm:make-client))
        :key #'nm:connection-id :test #'string=))

(defun run-tests ()
  "Run the mutation tests.  Returns the number of failures.  Skips (returning
0) unless NM_TEST_MUTATE=1."
  (unless (equal (uiop:getenv "NM_TEST_MUTATE") "1")
    (format t "~&nm/test/mutation: SKIPPED~%  (set NM_TEST_MUTATE=1 to run; ~
requires root + a running NetworkManager)~%")
    (return-from run-tests 0))
  (setf *pass* 0 *fail* 0)
  (let ((c (nm:make-client))
        (prof nil)
        (ac nil))
    (unwind-protect
         (progn
           (format t "~&build + add~%")
           (let ((conn (nm:make-connection :id +id+ :type "dummy"
                                           :interface +iface+ :autoconnect nil)))
             (nm:add-ip4-setting conn :method "disabled")
             (nm:add-ip6-setting conn :method "ignore")
             (setf prof (nm:add-connection conn :client c)))
           (check prof "add-connection returns an NMRemoteConnection")
           (check (profile-named +id+) "profile is listed after add")

           (format t "~&activate (and wait until settled)~%")
           (setf ac (nm:activate-and-wait prof :client c :timeout 20))
           (check (eq (nm:ac-state ac) :activated)
                  "activate-and-wait reaches :activated")
           (check (nm:find-device +iface+ (nm:make-client))
                  "activation created the device")

           (format t "~&update (commit a setting change)~%")
           (setf (nm:setting-property (nm:connection-setting prof) 'autoconnect) t)
           (nm:update-connection prof)
           (check (nm:connection-autoconnect-p
                   (nm:find-connection (nm:connection-uuid prof) (nm:make-client)))
                  "update-connection persisted autoconnect=t")

           (format t "~&deactivate~%")
           (check (nm:deactivate ac c) "deactivate returns T"))

      ;; ---- cleanup (always) ----
      (format t "~&cleanup~%")
      (ignore-errors
       (let ((p (profile-named +id+)))
         (when p (nm:delete-connection p))))
      (ignore-errors (nm:stop-event-loop)))

    (check (not (profile-named +id+)) "profile removed after delete")
    (format t "~%~D passed, ~D failed~%" *pass* *fail*)
    *fail*))

(defun run ()
  "Entry point: run the mutation tests and exit non-zero on any failure."
  (handler-case
      (uiop:quit (if (zerop (run-tests)) 0 1))
    (error (e)
      (format *error-output* "~&fatal: ~A~%" e)
      (uiop:quit 2))))
