;;; monitor.lisp

(in-package #:nm)

;;; Subscriptions
;;;
;;; Each returns the handler id from gir:connect, usable with DISCONNECT-HANDLER.
;;;
;;; Handlers are dispatched from the C main loop via a gir trampoline, so a
;;; Lisp error escaping a handler would unwind into C (undefined behaviour).
;;; CALL-HANDLER traps and reports errors to keep them out of the loop.

(defun call-handler (fn &rest args)
  "Invoke user signal handler FN on ARGS, trapping any error so it cannot
unwind into the C main loop."
  (handler-case (apply fn args)
    (error (e)
      (format *error-output* "~&nm: error in signal handler: ~A~%" e))))

(defun on-device-added (fn &optional (client *client*))
  "Call FN with the new device whenever a device is added."
  (gir:connect (client client) "device-added"
               (lambda (c d) (declare (ignore c)) (call-handler fn (most-derived d)))))

(defun on-device-removed (fn &optional (client *client*))
  "Call FN with the removed device whenever a device is removed."
  (gir:connect (client client) "device-removed"
               (lambda (c d) (declare (ignore c)) (call-handler fn (most-derived d)))))

(defun on-state-changed (fn device)
  "Call FN with (NEW-STATE OLD-STATE REASON) keywords on each DEVICE state
change."
  (gir:connect device "state-changed"
               (lambda (dev new old reason)
                 (declare (ignore dev))
                 (call-handler fn
                               (enum->keyword "DeviceState" new)
                               (enum->keyword "DeviceState" old)
                               (enum->keyword "DeviceStateReason" reason)))))

(defun watch-property (object property fn)
  "Call FN with OBJECT whenever its PROPERTY (a string, e.g. \"connectivity\")
changes, via the GObject notify signal."
  (gir:connect object (format nil "notify::~A" property)
               (lambda (obj pspec) (declare (ignore pspec)) (call-handler fn obj))))

(defun on-connectivity-changed (fn &optional (client *client*))
  "Call FN with the new connectivity keyword whenever it changes."
  (let ((c (client client)))
    (watch-property c "connectivity"
                    (lambda (obj) (declare (ignore obj)) (call-handler fn (connectivity c))))))

(defun disconnect-handler (object handler-id)
  "Remove a previously connected signal handler."
  (gir:disconnect object handler-id))

;;; Activate and wait for the result to settle

(defun await-active (ac timeout)
  "Block until active connection AC reaches :ACTIVATED (returned) or fails /
TIMEOUT seconds elapse (NM-ERROR), by watching AC's state-changed signal on
the shared event loop and waiting on a condition variable."
  (when (eq (ac-state ac) :activated)
    (return-from await-active ac))
  (ensure-event-loop)
  (let ((lock (bt:make-lock "nm-await"))
        (cv (bt:make-condition-variable))
        (problem nil)
        (done nil))
    (labels ((settle (&optional err)
               (bt:with-lock-held (lock)
                 (when err (setf problem err))
                 (setf done t)
                 (bt:condition-notify cv))))
      (let ((handler-id
              (gir:connect ac "state-changed"
                           (lambda (obj new reason)
                             (declare (ignore obj))
                             (case (enum->keyword "ActiveConnectionState" new)
                               (:activated (settle))
                               ((:deactivating :deactivated)
                                (settle (format nil "activation failed (reason ~A)"
                                                reason))))))))
        ;; Guard against the state settling between ACTIVATE returning and the
        ;; handler being connected.
        (when (eq (ac-state ac) :activated) (settle))
        (bt:with-lock-held (lock)
          (loop until done do
            (unless (bt:condition-wait cv lock :timeout timeout)
              (unless done (setf problem "activation timed out" done t)))))
        (ignore-errors (disconnect-handler ac handler-id))))
    (when problem (error 'nm-error :message problem))
    ac))

(defun activate-and-wait (connection &key device specific-object
                                          (client *client*) (timeout 30))
  "Like ACTIVATE, but block until the activation settles: returns the
NMActiveConnection once it is :ACTIVATED, or signals NM-ERROR on failure or
after TIMEOUT seconds."
  (await-active (activate connection :device device
                                     :specific-object specific-object
                                     :client client)
                timeout))
