;;; client.lisp

;;; The NMClient: the entry point into NetworkManager.  All accessors here
;;; are read-only and synchronous, so no GMainLoop is required.

(in-package #:nm)

(defvar *client* nil
  "The default NMClient used by the convenience query functions when no
explicit client is supplied.  Populated by MAKE-CLIENT.")

(defun make-client (&key (default t))
  "Create and return a new NMClient, synchronously connecting to the
NetworkManager daemon over D-Bus and populating its object cache.

When DEFAULT is true (the default) the new client is also stored in
*CLIENT* so the other query functions can be called without arguments.

Signals an NM-ERROR if NetworkManager is not running or cannot be reached.

The client is created on the shared event-loop thread (see loop.lisp) so it
binds to, and its signals dispatch on, the one thread that owns the
GMainContext."
  (let ((client (call-on-loop
                 (lambda ()
                   (with-nm-error ("could not connect to NetworkManager")
                     (gir:invoke ((namespace) "Client" 'new) nil))))))
    (when default
      (setf *client* client))
    client))

(defun client (&optional (client *client*))
  "Return CLIENT, defaulting to *CLIENT*, creating one on demand."
  (or client (make-client)))

;;; Client-level queries

(defun version (&optional (client *client*))
  "The version string of the running NetworkManager daemon."
  (gir:invoke ((client client) 'get-version)))

(defun networking-enabled-p (&optional (client *client*))
  (gir:invoke ((client client) 'networking-get-enabled)))

(defun wireless-enabled-p (&optional (client *client*))
  (gir:invoke ((client client) 'wireless-get-enabled)))

(defun wwan-enabled-p (&optional (client *client*))
  (gir:invoke ((client client) 'wwan-get-enabled)))

(defun set-networking-enabled (enabled &optional (client *client*))
  "Globally enable or disable all networking.  Returns the resulting state.
Disabling networking deactivates every connection -- use with care."
  (with-nm-error ("could not change networking state")
    (call-on-loop (lambda ()
                    (gir:invoke ((client client) 'networking-set-enabled) (and enabled t)))))
  (networking-enabled-p client))

(defun set-wireless-enabled (enabled &optional (client *client*))
  "Enable or disable Wi-Fi (the radio kill switch).  Returns the resulting state."
  (with-nm-error ("could not change wireless state")
    (call-on-loop (lambda ()
                    (gir:invoke ((client client) 'wireless-set-enabled) (and enabled t)))))
  (wireless-enabled-p client))

(defun set-wwan-enabled (enabled &optional (client *client*))
  "Enable or disable mobile broadband (WWAN).  Returns the resulting state."
  (with-nm-error ("could not change WWAN state")
    (call-on-loop (lambda ()
                    (gir:invoke ((client client) 'wwan-set-enabled) (and enabled t)))))
  (wwan-enabled-p client))

(defun nm-running-p (&optional (client *client*))
  "True when the NetworkManager daemon is running and reachable."
  (gir:invoke ((client client) 'get-nm-running)))

(defun state (&optional (client *client*))
  "Overall NMState as a keyword, e.g. :CONNECTED-GLOBAL, :CONNECTED-LOCAL,
:DISCONNECTED, :ASLEEP."
  (enum->keyword "State" (gir:invoke ((client client) 'get-state))))

(defun metered (&optional (client *client*))
  "Whether the primary connection is metered, as a keyword: :YES, :NO,
:GUESS-YES, :GUESS-NO or :UNKNOWN."
  (enum->keyword "Metered" (gir:invoke ((client client) 'get-metered))))

(defun permission (perm &optional (client *client*))
  "The caller's PolicyKit result for permission PERM as a keyword.

PERM is a keyword naming an NMClientPermission, e.g.
:ENABLE-DISABLE-NETWORK, :SETTINGS-MODIFY-SYSTEM, :WIFI-SHARE-OPEN.  The
result is :YES, :NO, :AUTH (authorization required) or :UNKNOWN."
  (enum->keyword "ClientPermissionResult"
                 (gir:invoke ((client client) 'get-permission-result)
                             (gir:nget (namespace) "ClientPermission" perm))))

(defun connectivity (&optional (client *client*))
  "The last-known NMConnectivityState as a keyword, e.g. :FULL, :LIMITED,
:PORTAL, :NONE or :UNKNOWN.  Uses the cached value (does not block)."
  (enum->keyword "ConnectivityState"
                 (gir:invoke ((client client) 'get-connectivity))))

(defun check-connectivity (&optional (client *client*))
  "Actively re-check connectivity, blocking until the daemon answers, and
return the resulting state keyword.  Prefer CONNECTIVITY for a cheap,
non-blocking read."
  (enum->keyword "ConnectivityState"
                 (gir:invoke ((client client) 'check-connectivity) nil)))

(defun devices (&optional (client *client*))
  "List of all network devices known to NetworkManager."
  (ptr-array-objects (gir:invoke ((client client) 'get-devices))))

(defun find-device (interface &optional (client *client*))
  "Return the device whose interface name is INTERFACE (e.g. \"wlan0\"),
or NIL if there is none."
  (most-derived
   (gir:invoke ((client client) 'get-device-by-iface) interface)))

(defun active-connections (&optional (client *client*))
  "List of currently active connections (NMActiveConnection)."
  (ptr-array-objects (gir:invoke ((client client) 'get-active-connections))))

(defun primary-connection (&optional (client *client*))
  "The active connection that owns the default route, or NIL."
  (let ((ac (gir:invoke ((client client) 'get-primary-connection))))
    (unless (null-object-p ac) ac)))

;;; These are the stored profiles NetworkManager can activate, as opposed to
;;; the currently *active* connections above.  Read-only accessors only.

(defun connections (&optional (client *client*))
  "List of all saved connection profiles (NMRemoteConnection)."
  (ptr-array-objects (gir:invoke ((client client) 'get-connections))))

(defun find-connection (uuid &optional (client *client*))
  "Return the saved profile with the given UUID, or NIL."
  (let ((c (gir:invoke ((client client) 'get-connection-by-uuid) uuid)))
    (unless (null-object-p c) c)))

(defun connection-id (connection)
  "Human-readable name of the saved profile."
  (gir:invoke (connection 'get-id)))

(defun connection-uuid (connection)
  (gir:invoke (connection 'get-uuid)))

(defun connection-type (connection)
  "Connection type string, e.g. \"802-11-wireless\" or \"802-3-ethernet\"."
  (gir:invoke (connection 'get-connection-type)))

(defun connection-interface (connection)
  "The interface name the profile is bound to, or NIL if unbound."
  (gir:invoke (connection 'get-interface-name)))

(defun connection-path (connection)
  "The D-Bus object path of the saved profile."
  (gir:invoke (connection 'get-path)))

(defun connection-autoconnect-p (connection)
  "True when the profile is configured to auto-connect."
  (let ((setting (gir:invoke (connection 'get-setting-connection))))
    (unless (null-object-p setting)
      (gir:invoke (setting 'get-autoconnect)))))
