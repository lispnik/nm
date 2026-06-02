;;; test.lisp

;;; A lightweight smoke test that exercises the read-only binding against a
;;; live NetworkManager.  It asserts shape/type invariants rather than exact
;;; values, so it is portable across hosts.  Requires a running NM (Linux).

(defpackage #:nm.test
  (:use #:cl)
  (:export #:run #:run-tests))

(in-package #:nm.test)

(defvar *pass* 0)
(defvar *fail* 0)

(defmacro check (form &optional desc)
  "Assert FORM is true, tallying the result."
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
  "Run the smoke tests, printing results.  Returns the number of failures."
  (setf *pass* 0 *fail* 0)
  (let ((client (nm:make-client)))
    (format t "~&client~%")
    (check client "make-client returns a client")
    (check (stringp (nm:version client)) "version is a string")
    (check (keywordp (nm:connectivity client)) "connectivity is a keyword")
    (check (member (nm:networking-enabled-p client) '(t nil))
           "networking-enabled-p is boolean")

    (format t "~&devices~%")
    (let ((devices (nm:devices client)))
      (check (listp devices) "devices is a list")
      (check (plusp (length devices)) "at least one device")
      (dolist (d devices)
        (check (stringp (nm:device-interface d))
               (format nil "~A: interface is a string" (nm:device-interface d)))
        (check (keywordp (nm:device-type d))
               (format nil "~A: type is a keyword" (nm:device-interface d)))
        (check (keywordp (nm:device-state d))
               (format nil "~A: state is a keyword" (nm:device-interface d)))
        (check (listp (nm:device-ip4-addresses d))
               (format nil "~A: ip4-addresses is a list" (nm:device-interface d)))
        (check (listp (nm:device-ip6-addresses d))
               (format nil "~A: ip6-addresses is a list" (nm:device-interface d)))))

    (format t "~&loopback~%")
    (let ((lo (nm:find-device "lo" client)))
      (check lo "find-device \"lo\" succeeds")
      (when lo
        (check (eq (nm:device-type lo) :loopback) "lo is type :loopback")
        (check (member "127.0.0.1"
                       (mapcar #'car (nm:device-ip4-addresses lo))
                       :test #'string=)
               "lo has 127.0.0.1")))

    (format t "~&connections~%")
    (check (listp (nm:active-connections client)) "active-connections is a list")
    (check (listp (nm:connections client)) "saved connections is a list")
    (dolist (c (nm:connections client))
      (check (stringp (nm:connection-uuid c))
             (format nil "profile ~A: uuid is a string" (nm:connection-id c))))

    (format t "~&wi-fi~%")
    (let ((wifi (find-if #'nm:wifi-device-p (nm:devices client))))
      (if (null wifi)
          (format t "  skip (no Wi-Fi device)~%")
          (let ((aps (nm:access-points wifi)))
            (check (listp aps) "access-points is a list")
            (dolist (ap aps)
              (check (integerp (nm:ap-strength ap)) "ap-strength is an integer")
              (check (listp (nm:ap-security ap)) "ap-security is a list")))))

    (format t "~%~D passed, ~D failed~%" *pass* *fail*)
    *fail*))

(defun run ()
  "Entry point: run smoke tests and exit non-zero on any failure."
  (handler-case
      (let ((failures (run-tests)))
        (uiop:quit (if (zerop failures) 0 1)))
    (error (e)
      (format *error-output* "~&fatal: ~A~%" e)
      (uiop:quit 2))))
