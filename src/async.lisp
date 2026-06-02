;;; async.lisp
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Matthew Kennedy
;;;
;;; v2 Phase 0: the asynchronous core.
;;;
;;; libnm's mutating operations are asynchronous: a `..._async' call that
;;; takes a GAsyncReadyCallback, paired with a `..._finish' that retrieves
;;; the result inside that callback.  Two facts about cl-gobject-introspection
;;; shape this layer (both verified against live NM):
;;;
;;;   * It will NOT marshal a Lisp function as a callback *argument* -- such
;;;     args are passed as a bare :pointer.  So the callback must be a real
;;;     CFFI callback, demultiplexed via the GAsyncReadyCallback `user_data'
;;;     slot.
;;;   * Re-marshalling the opaque GAsyncResult back through gir inside the
;;;     callback is awkward, so each `..._finish' is declared as a thin
;;;     CFFI defcfun and called on raw pointers.
;;;
;;; On top of this we expose a synchronous facade, CALL-ASYNC-SYNC, which
;;; spins a private GLib main loop until the operation completes -- keeping
;;; the management API blocking-and-simple for callers.

(in-package #:nm)

;;; (Foreign-library loading, the GLib namespace, and the GValue/boxed-property
;;; helper live in gvalue.lisp, which loads before this file.)

;;; GError plumbing

(cffi:defcstruct g-error
  (domain :uint32)
  (code :int32)
  (message :pointer))

(cffi:defcfun ("g_error_free" %g-error-free) :void
  (error :pointer))

(defun maybe-signal-gerror (err-box &optional message)
  "ERR-BOX is a GError** (a foreign cell holding a GError*).  If it holds a
non-NULL error, free it and signal NM-ERROR, preferring MESSAGE for the
report but carrying the GError text as the cause."
  (let ((err (cffi:mem-ref err-box :pointer)))
    (unless (cffi:null-pointer-p err)
      (let ((text (cffi:foreign-string-to-lisp
                   (cffi:foreign-slot-value err '(:struct g-error) 'message))))
        (%g-error-free err)
        (error 'nm-error :message (or message text) :cause text)))))

;;; (The continuation registry, the GAsyncReadyCallback bridge, the shared
;;; event loop, and CALL-ASYNC-SYNC live in loop.lisp, which loads before this
;;; file.)

;;; Reference consumer: connectivity check via the async API
;;;
;;; This proves the whole async core end-to-end on a read-only operation.

(cffi:defcfun ("nm_client_check_connectivity_async"
               %nm-client-check-connectivity-async) :void
  (client :pointer)
  (cancellable :pointer)
  (callback :pointer)
  (user-data :pointer))

(cffi:defcfun ("nm_client_check_connectivity_finish"
               %nm-client-check-connectivity-finish) :int
  (client :pointer)
  (result :pointer)
  (error :pointer))

(defun check-connectivity-async (&optional (c *client*))
  "Actively re-check connectivity via libnm's asynchronous API, driven by a
private GLib main loop, returning the resulting NMConnectivityState keyword.

Functionally equivalent to CHECK-CONNECTIVITY, but exercising the Phase-0
async core (the GAsyncReadyCallback bridge and CALL-ASYNC-SYNC facade)."
  (ensure-libnm)
  (let ((client-ptr (gir::this-of (client c))))
    (enum->keyword
     "ConnectivityState"
     (call-async-sync
      (lambda (callback token cancellable)
        (%nm-client-check-connectivity-async
         client-ptr cancellable callback token))
      (lambda (source result)
        (declare (ignore source))
        (cffi:with-foreign-object (err :pointer)
          (setf (cffi:mem-ref err :pointer) (cffi:null-pointer))
          (let ((state (%nm-client-check-connectivity-finish
                        client-ptr result err)))
            (maybe-signal-gerror err "connectivity check failed")
            state)))))))

;;; activate/deactivate connections

(cffi:defcfun ("nm_client_activate_connection_async"
               %nm-client-activate-connection-async) :void
  (client :pointer)
  (connection :pointer)
  (device :pointer)
  (specific-object :string)
  (cancellable :pointer)
  (callback :pointer)
  (user-data :pointer))

(cffi:defcfun ("nm_client_activate_connection_finish"
               %nm-client-activate-connection-finish) :pointer
  (client :pointer)
  (result :pointer)
  (error :pointer))

(cffi:defcfun ("nm_client_deactivate_connection_async"
               %nm-client-deactivate-connection-async) :void
  (client :pointer)
  (active :pointer)
  (cancellable :pointer)
  (callback :pointer)
  (user-data :pointer))

(cffi:defcfun ("nm_client_deactivate_connection_finish"
               %nm-client-deactivate-connection-finish) :boolean
  (client :pointer)
  (result :pointer)
  (error :pointer))

(defun %resolve-device (device client)
  "Accept a device object or an interface-name string, return a device ptr
or a NULL pointer."
  (let ((dev (cond ((null device) nil)
                   ((stringp device) (find-device device client))
                   (t device))))
    (if dev (gir::this-of dev) (cffi:null-pointer))))

(defun activate (connection &key device specific-object (client *client*))
  "Activate CONNECTION on DEVICE, blocking until NetworkManager responds, and
return the resulting NMActiveConnection.

CONNECTION is a saved profile (an NMRemoteConnection, e.g. from CONNECTIONS or
FIND-CONNECTION) or NIL to let NetworkManager pick the best profile.  DEVICE is
a device object or an interface-name string, or NIL.  SPECIFIC-OBJECT is an
optional object path (e.g. a Wi-Fi AP's path).  Signals NM-ERROR on failure
(including PolicyKit denials)."
  (ensure-libnm)
  (let ((client-ptr (gir::this-of (client client)))
        (conn-ptr (if connection (gir::this-of connection) (cffi:null-pointer)))
        (dev-ptr (%resolve-device device client)))
    (call-async-sync
     (lambda (callback token cancellable)
       (%nm-client-activate-connection-async
        client-ptr conn-ptr dev-ptr
        (or specific-object (cffi:null-pointer)) ; :string accepts a string or a pointer, not NIL
        cancellable callback token))
     (lambda (source result)
       (declare (ignore source))
       (cffi:with-foreign-object (err :pointer)
         (setf (cffi:mem-ref err :pointer) (cffi:null-pointer))
         (let ((ac (%nm-client-activate-connection-finish client-ptr result err)))
           (maybe-signal-gerror err "activation failed")
           ;; transfer-full: adopt the returned NMActiveConnection's ref.
           (unless (cffi:null-pointer-p ac)
             (adopt-ref (gir::gobject (gir::gtype ac) ac)))))))))

(defun deactivate (active-connection &optional (client *client*))
  "Deactivate ACTIVE-CONNECTION (an NMActiveConnection, e.g. from
ACTIVE-CONNECTIONS or DEVICE-ACTIVE-CONNECTION), blocking until NetworkManager
responds.  Returns T on success; signals NM-ERROR on failure."
  (ensure-libnm)
  (let ((client-ptr (gir::this-of (client client)))
        (ac-ptr (gir::this-of active-connection)))
    (call-async-sync
     (lambda (callback token cancellable)
       (%nm-client-deactivate-connection-async
        client-ptr ac-ptr cancellable callback token))
     (lambda (source result)
       (declare (ignore source))
       (cffi:with-foreign-object (err :pointer)
         (setf (cffi:mem-ref err :pointer) (cffi:null-pointer))
         (let ((ok (%nm-client-deactivate-connection-finish client-ptr result err)))
           (maybe-signal-gerror err "deactivation failed")
           ok))))))

;;; Device disconnect

(cffi:defcfun ("nm_device_disconnect_async" %nm-device-disconnect-async) :void
  (device :pointer)
  (cancellable :pointer)
  (callback :pointer)
  (user-data :pointer))

(cffi:defcfun ("nm_device_disconnect_finish" %nm-device-disconnect-finish) :boolean
  (device :pointer)
  (result :pointer)
  (error :pointer))

(defun disconnect-device (device &optional (client *client*))
  "Disconnect DEVICE (a device object or interface-name string), deactivating
its connection and blocking auto-activation until the next manual activation.
Returns T; signals NM-ERROR on failure."
  (ensure-libnm)
  (let* ((dev (if (stringp device) (find-device device client) device))
         (dev-ptr (gir::this-of dev)))
    (call-async-sync
     (lambda (callback token cancellable)
       (%nm-device-disconnect-async dev-ptr cancellable callback token))
     (lambda (source result)
       (declare (ignore source))
       (cffi:with-foreign-object (err :pointer)
         (setf (cffi:mem-ref err :pointer) (cffi:null-pointer))
         (let ((ok (%nm-device-disconnect-finish dev-ptr result err)))
           (maybe-signal-gerror err "device disconnect failed")
           ok))))))

;;; add/update/delete saved profiles

(cffi:defcfun ("nm_client_add_connection_async"
               %nm-client-add-connection-async) :void
  (client :pointer)
  (connection :pointer)
  (save-to-disk :boolean)
  (cancellable :pointer)
  (callback :pointer)
  (user-data :pointer))

(cffi:defcfun ("nm_client_add_connection_finish"
               %nm-client-add-connection-finish) :pointer
  (client :pointer)
  (result :pointer)
  (error :pointer))

(cffi:defcfun ("nm_remote_connection_delete_async"
               %nm-remote-connection-delete-async) :void
  (connection :pointer)
  (cancellable :pointer)
  (callback :pointer)
  (user-data :pointer))

(cffi:defcfun ("nm_remote_connection_delete_finish"
               %nm-remote-connection-delete-finish) :boolean
  (connection :pointer)
  (result :pointer)
  (error :pointer))

(cffi:defcfun ("nm_remote_connection_commit_changes_async"
               %nm-remote-connection-commit-changes-async) :void
  (connection :pointer)
  (save-to-disk :boolean)
  (cancellable :pointer)
  (callback :pointer)
  (user-data :pointer))

(cffi:defcfun ("nm_remote_connection_commit_changes_finish"
               %nm-remote-connection-commit-changes-finish) :boolean
  (connection :pointer)
  (result :pointer)
  (error :pointer))

(defun add-connection (connection &key (save t) (client *client*))
  "Add CONNECTION (built with MAKE-CONNECTION) as a new saved profile,
blocking until NetworkManager responds, and return the resulting
NMRemoteConnection.

When SAVE is true the profile is persisted to disk; otherwise it exists only
in the daemon's memory until reboot.  Signals NM-ERROR on failure (including
verification errors and PolicyKit denials)."
  (ensure-libnm)
  (let ((client-ptr (gir::this-of (client client)))
        (conn-ptr (gir::this-of connection)))
    (call-async-sync
     (lambda (callback token cancellable)
       (%nm-client-add-connection-async
        client-ptr conn-ptr (and save t) cancellable callback token))
     (lambda (source result)
       (declare (ignore source))
       (cffi:with-foreign-object (err :pointer)
         (setf (cffi:mem-ref err :pointer) (cffi:null-pointer))
         (let ((rc (%nm-client-add-connection-finish client-ptr result err)))
           (maybe-signal-gerror err "add-connection failed")
           ;; transfer-full: adopt the returned NMRemoteConnection's ref.
           (unless (cffi:null-pointer-p rc)
             (adopt-ref (gir::gobject (gir::gtype rc) rc)))))))))

(defun update-connection (profile &key (save t))
  "Commit in-memory changes made to the saved PROFILE (an NMRemoteConnection)
to NetworkManager, blocking until it responds.  Mutate the profile's settings
first (see CONNECTION-SETTING / SETTING-PROPERTY), then call this.  Returns T;
signals NM-ERROR on failure."
  (ensure-libnm)
  (let ((conn-ptr (gir::this-of profile)))
    (call-async-sync
     (lambda (callback token cancellable)
       (%nm-remote-connection-commit-changes-async
        conn-ptr (and save t) cancellable callback token))
     (lambda (source result)
       (declare (ignore source))
       (cffi:with-foreign-object (err :pointer)
         (setf (cffi:mem-ref err :pointer) (cffi:null-pointer))
         (let ((ok (%nm-remote-connection-commit-changes-finish
                    conn-ptr result err)))
           (maybe-signal-gerror err "update-connection failed")
           ok))))))

(defun delete-connection (profile)
  "Delete the saved PROFILE (an NMRemoteConnection) from NetworkManager,
blocking until it responds.  Returns T; signals NM-ERROR on failure."
  (ensure-libnm)
  (let ((conn-ptr (gir::this-of profile)))
    (call-async-sync
     (lambda (callback token cancellable)
       (%nm-remote-connection-delete-async
        conn-ptr cancellable callback token))
     (lambda (source result)
       (declare (ignore source))
       (cffi:with-foreign-object (err :pointer)
         (setf (cffi:mem-ref err :pointer) (cffi:null-pointer))
         (let ((ok (%nm-remote-connection-delete-finish conn-ptr result err)))
           (maybe-signal-gerror err "delete-connection failed")
           ok))))))

;;; add-and-activate, and Wi-Fi connect

(cffi:defcfun ("nm_client_add_and_activate_connection_async"
               %nm-client-add-and-activate-connection-async) :void
  (client :pointer)
  (partial :pointer)
  (device :pointer)
  (specific-object :string)
  (cancellable :pointer)
  (callback :pointer)
  (user-data :pointer))

(cffi:defcfun ("nm_client_add_and_activate_connection_finish"
               %nm-client-add-and-activate-connection-finish) :pointer
  (client :pointer)
  (result :pointer)
  (error :pointer))

(defun add-and-activate (connection &key device specific-object (client *client*))
  "Add CONNECTION as a new profile and activate it in a single operation,
blocking until NetworkManager responds, and return the resulting
NMActiveConnection.

CONNECTION may be partial (e.g. only wireless + security settings) -- NM
completes and saves it.  DEVICE is a device object or interface-name string
(NIL lets NM choose).  As with ACTIVATE, this returns once activation has
started; the connection may still be `:activating'.  Signals NM-ERROR on
failure."
  (ensure-libnm)
  (let ((client-ptr (gir::this-of (client client)))
        (conn-ptr (gir::this-of connection))
        (dev-ptr (%resolve-device device client)))
    (call-async-sync
     (lambda (callback token cancellable)
       (%nm-client-add-and-activate-connection-async
        client-ptr conn-ptr dev-ptr
        (or specific-object (cffi:null-pointer))
        cancellable callback token))
     (lambda (source result)
       (declare (ignore source))
       (cffi:with-foreign-object (err :pointer)
         (setf (cffi:mem-ref err :pointer) (cffi:null-pointer))
         (let ((ac (%nm-client-add-and-activate-connection-finish
                    client-ptr result err)))
           (maybe-signal-gerror err "add-and-activate failed")
           ;; transfer-full: adopt the returned NMActiveConnection's ref.
           (unless (cffi:null-pointer-p ac)
             (adopt-ref (gir::gobject (gir::gtype ac) ac)))))))))

(defun connect-wifi (ssid &key psk device hidden (key-mgmt "wpa-psk")
                               eap identity eap-password (client *client*))
  "Connect to the Wi-Fi network SSID (a string).

Personal: pass PSK (KEY-MGMT \"wpa-psk\" for WPA/WPA2, \"sae\" for WPA3).
Enterprise: pass EAP (e.g. \"peap\") with IDENTITY and EAP-PASSWORD.

Builds a new Wi-Fi profile (see MAKE-WIFI-CONNECTION) and add-and-activates it
on DEVICE (a Wi-Fi device object or interface-name string; NIL lets NM choose
a Wi-Fi device).  HIDDEN marks the SSID as non-broadcast.  Returns the
resulting NMActiveConnection; activation may still be in progress on return."
  (add-and-activate (make-wifi-connection ssid :psk psk :hidden hidden
                                               :key-mgmt key-mgmt :eap eap
                                               :identity identity
                                               :eap-password eap-password)
                    :device device :client client))
