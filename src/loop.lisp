;;; loop.lisp
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Your Name
;;;
;;; The shared event loop and async marshaling core (v2 improvement #4).
;;;
;;; There is exactly ONE GLib main loop, running on a dedicated thread.  All
;;; asynchronous operations start their `..._async' call on that thread (via
;;; g_main_context_invoke) and the calling thread blocks on a condition
;;; variable until the completion callback -- which also runs on the loop
;;; thread -- signals it.  Nothing ever spins a second loop, so the old
;;; dual-loop hazard (two threads trying to run one GMainContext) cannot occur:
;;; monitoring and mutating operations coexist freely.
;;;
;;; Consequence: a synchronous NM operation must not be called from within a
;;; signal handler (which runs on the loop thread) -- that would block the very
;;; thread meant to run the work.  CALL-ASYNC-SYNC detects this and signals
;;; rather than deadlocking.

(in-package #:nm)

(defvar *async-timeout* 30
  "Default seconds to wait for an async operation before cancelling it and
signalling NM-ERROR.  NIL waits indefinitely.")

;;; ---------------------------------------------------------------------------
;;; Continuation registry (shared by async-ready callbacks and loop thunks)

(defvar *pending-callbacks* (make-hash-table)
  "Maps the integer address of a token to its Lisp continuation/thunk.")

(defun %register-continuation (fn)
  "Allocate a token bound to FN; returns the token pointer."
  (let ((token (cffi:foreign-alloc :int)))
    (setf (gethash (cffi:pointer-address token) *pending-callbacks*) fn)
    token))

(defun %take-continuation (token)
  "Look up and unregister the function for TOKEN, freeing the token."
  (let ((addr (cffi:pointer-address token)))
    (multiple-value-prog1 (gethash addr *pending-callbacks*)
      (remhash addr *pending-callbacks*)
      (cffi:foreign-free token))))

;;; ---------------------------------------------------------------------------
;;; C entry points

(cffi:defcallback %async-ready :void
    ((source :pointer) (result :pointer) (user-data :pointer))
  "GAsyncReadyCallback: libnm invokes this when an async op completes."
  (let ((cont (%take-continuation user-data)))
    (when cont (funcall cont source result))))

(cffi:defcfun ("g_main_context_invoke_full" %g-main-context-invoke-full) :void
  (context :pointer)
  (priority :int)
  (function :pointer)
  (data :pointer)
  (notify :pointer))

(cffi:defcallback %source-func :int ((data :pointer))
  "GSourceFunc: runs a marshaled Lisp thunk on the loop thread, once."
  (let ((thunk (%take-continuation data)))
    (when thunk
      (handler-case (funcall thunk)
        (error (e) (format *error-output* "~&nm: error in loop task: ~A~%" e)))))
  0)                                    ; G_SOURCE_REMOVE

;;; ---------------------------------------------------------------------------
;;; The loop thread

(defvar *event-loop* nil)
(defvar *event-loop-thread* nil)
(defvar *event-loop-lock* (sb-thread:make-mutex :name "nm-event-loop"))

(defun event-loop-running-p ()
  "True when the shared event loop thread is running."
  (and *event-loop-thread* t))

(defun loop-thread-p ()
  "True when called on the event-loop thread."
  (and *event-loop-thread*
       (eq sb-thread:*current-thread* *event-loop-thread*)))

(defun ensure-event-loop ()
  "Start the shared event-loop thread if it is not already running.  Idempotent."
  (ensure-libnm)
  (sb-thread:with-mutex (*event-loop-lock*)
    (unless *event-loop-thread*
      (let ((mloop (gir:invoke ((glib-namespace) "MainLoop" 'new) nil nil)))
        (setf *event-loop* mloop
              *event-loop-thread*
              (sb-thread:make-thread (lambda () (gir:invoke (mloop 'run)))
                                     :name "nm-event-loop")))))
  t)

(defun start-event-loop ()
  "Start the shared event loop so subscribed signal handlers are dispatched.
Idempotent; returns T."
  (ensure-event-loop))

(defun stop-event-loop ()
  "Stop the shared event loop and join its thread.  Returns T."
  (sb-thread:with-mutex (*event-loop-lock*)
    (let ((mloop *event-loop*)
          (thread *event-loop-thread*))
      (setf *event-loop* nil *event-loop-thread* nil)
      (when mloop (gir:invoke (mloop 'quit)))
      (when (and thread (not (eq thread sb-thread:*current-thread*)))
        (ignore-errors (sb-thread:join-thread thread)))))
  t)

;;; ---------------------------------------------------------------------------
;;; Marshaling

(defun run-on-loop (thunk)
  "Queue THUNK to run on the event-loop thread (fire-and-forget)."
  (ensure-event-loop)
  (let ((token (%register-continuation thunk)))
    (%g-main-context-invoke-full (cffi:null-pointer) 0
                                 (cffi:callback %source-func)
                                 token (cffi:null-pointer))))

(defun call-on-loop (thunk &key (timeout *async-timeout*))
  "Run THUNK on the event-loop thread and return its value (or re-raise its
error) on the calling thread.  Used to confine *synchronous* libnm calls (e.g.
client creation, the enable/disable toggles) to the one thread that owns the
GMainContext, avoiding cross-thread context contention.  Runs THUNK directly
if already on the loop thread."
  (ensure-event-loop)
  (if (loop-thread-p)
      (funcall thunk)
      (let ((lock (sb-thread:make-mutex :name "nm-call-on-loop"))
            (cv (sb-thread:make-waitqueue))
            (result nil) (problem nil) (done nil))
        (run-on-loop
         (lambda ()
           (handler-case (setf result (funcall thunk))
             (error (e) (setf problem e)))
           (sb-thread:with-mutex (lock)
             (setf done t)
             (sb-thread:condition-notify cv))))
        (sb-thread:with-mutex (lock)
          (loop until done do
            (unless (sb-thread:condition-wait cv lock :timeout timeout)
              (unless done
                (setf problem (make-condition 'nm-error :message "loop call timed out")
                      done t)))))
        (when problem (error problem))
        result)))

(defun call-async-sync (start finish &key (timeout *async-timeout*))
  "Drive an asynchronous libnm operation to completion synchronously.

START is called (on the loop thread) with (CALLBACK-PTR TOKEN CANCELLABLE) and
must launch the async op.  FINISH is called (on the loop thread) with
(SOURCE-PTR RESULT-PTR) from the completion callback and should call the
matching `..._finish' and return a value or signal.  The calling thread blocks
until completion or TIMEOUT seconds (after which the op is cancelled and
NM-ERROR is signalled).  FINISH's value is returned; an error it signals is
re-raised here."
  (ensure-event-loop)
  (when (loop-thread-p)
    (error 'nm-error :message
           "cannot call a synchronous NM operation from within an event handler"))
  (let ((cancellable (%g-cancellable-new))
        (lock (sb-thread:make-mutex :name "nm-async"))
        (cv (sb-thread:make-waitqueue))
        (result nil) (problem nil) (done nil) (timed-out nil))
    (run-on-loop
     (lambda ()
       (let ((token (%register-continuation
                     (lambda (source res)
                       (unless timed-out
                         (handler-case (setf result (funcall finish source res))
                           (error (e) (setf problem e)))
                         (sb-thread:with-mutex (lock)
                           (setf done t)
                           (sb-thread:condition-notify cv)))))))
         (funcall start (cffi:callback %async-ready) token cancellable))))
    (sb-thread:with-mutex (lock)
      (loop until done do
        (unless (sb-thread:condition-wait cv lock :timeout timeout)
          (unless done
            (setf timed-out t done t
                  problem (make-condition 'nm-error :message "operation timed out"))
            (run-on-loop (lambda () (%g-cancellable-cancel cancellable)))))))
    (run-on-loop (lambda () (%g-object-unref cancellable)))
    (when problem (error problem))
    result))
