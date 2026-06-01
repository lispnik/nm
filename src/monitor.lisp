;;; monitor.lisp
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Your Name
;;;
;;; v2 Phase 5: event monitoring and a background GLib main loop, plus
;;; ACTIVATE-AND-WAIT (which blocks until an activation settles by watching
;;; the active connection's state-changed signal).
;;;
;;; Signals work out of the box through gir:connect (verified in the original
;;; feasibility spike); the only machinery needed is a running main loop so
;;; they get dispatched.
;;;
;;; THREADING: subscribed handlers run on whichever thread runs the loop.
;;; START-EVENT-LOOP runs it on a dedicated thread, so handlers fire there --
;;; do not concurrently invoke other NM operations (ACTIVATE, ADD-CONNECTION,
;;; ...), which spin their own private loops on the calling thread, while the
;;; background loop is running: two threads cannot run the same GMainContext.

(in-package #:nm)

;;; ---------------------------------------------------------------------------
;;; Background event loop

(defvar *event-loop* nil)
(defvar *event-loop-thread* nil)

(defun event-loop-running-p ()
  "True when the background event loop is running."
  (and *event-loop-thread* t))

(defun start-event-loop ()
  "Start a background thread running a GLib main loop so subscribed signal
handlers are dispatched.  Idempotent; returns T.  See the threading note in
this file's header."
  (unless *event-loop-thread*
    (let ((mloop (gir:invoke ((glib-namespace) "MainLoop" 'new) nil nil)))
      (setf *event-loop* mloop
            *event-loop-thread*
            (sb-thread:make-thread (lambda () (gir:invoke (mloop 'run)))
                                   :name "nm-event-loop"))))
  t)

(defun stop-event-loop ()
  "Stop the background event loop and join its thread.  Returns T."
  (when *event-loop*
    (gir:invoke (*event-loop* 'quit)))
  (when *event-loop-thread*
    (ignore-errors (sb-thread:join-thread *event-loop-thread*))
    (setf *event-loop-thread* nil *event-loop* nil))
  t)

;;; ---------------------------------------------------------------------------
;;; Subscriptions
;;;
;;; Each returns the handler id from gir:connect, usable with DISCONNECT-HANDLER.

(defun on-device-added (fn &optional (client *client*))
  "Call FN with the new device whenever a device is added."
  (gir:connect (client client) "device-added"
               (lambda (c d) (declare (ignore c)) (funcall fn (most-derived d)))))

(defun on-device-removed (fn &optional (client *client*))
  "Call FN with the removed device whenever a device is removed."
  (gir:connect (client client) "device-removed"
               (lambda (c d) (declare (ignore c)) (funcall fn (most-derived d)))))

(defun on-state-changed (fn device)
  "Call FN with (NEW-STATE OLD-STATE REASON) keywords on each DEVICE state
change."
  (gir:connect device "state-changed"
               (lambda (dev new old reason)
                 (declare (ignore dev))
                 (funcall fn (enum->keyword "DeviceState" new)
                          (enum->keyword "DeviceState" old)
                          (enum->keyword "DeviceStateReason" reason)))))

(defun watch-property (object property fn)
  "Call FN with OBJECT whenever its PROPERTY (a string, e.g. \"connectivity\")
changes, via the GObject notify signal."
  (gir:connect object (format nil "notify::~A" property)
               (lambda (obj pspec) (declare (ignore pspec)) (funcall fn obj))))

(defun on-connectivity-changed (fn &optional (client *client*))
  "Call FN with the new connectivity keyword whenever it changes."
  (let ((c (client client)))
    (watch-property c "connectivity"
                    (lambda (obj) (declare (ignore obj)) (funcall fn (connectivity c))))))

(defun disconnect-handler (object handler-id)
  "Remove a previously connected signal handler."
  (gir:disconnect object handler-id))

;;; ---------------------------------------------------------------------------
;;; Activate and wait for the result to settle

(defun await-active (ac timeout)
  "Block until active connection AC reaches :ACTIVATED (returned) or fails /
TIMEOUT seconds elapse (NM-ERROR), by running a private main loop and watching
AC's state-changed signal."
  (when (eq (ac-state ac) :activated)
    (return-from await-active ac))
  (let ((mloop (gir:invoke ((glib-namespace) "MainLoop" 'new) nil nil))
        (problem nil)
        (done nil))
    (flet ((finish (&optional err)
             (setf problem err done t)
             (gir:invoke (mloop 'quit))))
      (gir:connect ac "state-changed"
                   (lambda (obj new reason)
                     (declare (ignore obj))
                     (case (enum->keyword "ActiveConnectionState" new)
                       (:activated (finish))
                       ((:deactivating :deactivated)
                        (finish (format nil "activation failed (reason ~A)" reason))))))
      ;; Guard against the state settling between ACTIVATE returning and the
      ;; handler being connected.
      (if (eq (ac-state ac) :activated)
          (return-from await-active ac)
          (let ((watchdog
                  (sb-thread:make-thread
                   (lambda ()
                     (loop repeat (round (* timeout 20)) until done do (sleep 0.05))
                     (unless done
                       (setf problem "activation timed out")
                       (gir:invoke (mloop 'quit))))
                   :name "nm-activate-watchdog")))
            (gir:invoke (mloop 'run))
            (setf done t)
            (ignore-errors (sb-thread:join-thread watchdog)))))
    (when problem (error 'nm-error :message problem))
    ac))

(defun activate-and-wait (connection &key device specific-object
                                          (client *client*) (timeout 30))
  "Like ACTIVATE, but block until the activation settles: returns the
NMActiveConnection once it is :ACTIVATED, or signals NM-ERROR on failure or
after TIMEOUT seconds.

Do not call while a background event loop (START-EVENT-LOOP) is running on the
same context -- this spins its own loop."
  (await-active (activate connection :device device
                                     :specific-object specific-object
                                     :client client)
                timeout))
