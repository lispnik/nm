;;; connection.lisp
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Your Name
;;;
;;; v2 Phase 3 (construction half): building NMConnection objects from
;;; NMSetting objects.  This is deliberately object-based -- we set GObject
;;; properties on typed setting instances and add them to the connection --
;;; which keeps us off the GVariant a{sa{sv}} path entirely for scalar
;;; properties (proven feasible against live NM).  Complex/boxed properties
;;; (Wi-Fi SSID, address lists) are deferred to Phase 4.
;;;
;;; The add/update/delete operations that push these to the daemon are async
;;; and live in async.lisp.

(in-package #:nm)

(defun make-setting (name)
  "Create a fresh NMSetting named NAME, e.g. \"SettingConnection\",
\"SettingWired\", \"SettingIP4Config\"."
  (gir:invoke ((namespace) name 'new)))

(defun setting-property (setting key)
  "Read property KEY (a symbol/string, e.g. 'autoconnect) of SETTING."
  (gir:property setting key))

(defun (setf setting-property) (value setting key)
  "Set scalar property KEY of SETTING to VALUE."
  (setf (gir:property setting key) value))

(defun add-setting (connection setting)
  "Add SETTING to CONNECTION, returning CONNECTION (so calls can be chained)."
  (gir:invoke (connection 'add-setting) setting)
  connection)

(defun generate-uuid ()
  "Return a freshly generated connection UUID string."
  (gir:invoke ((namespace) 'utils-uuid-generate)))

(defun connection-setting (connection)
  "The NMSettingConnection of CONNECTION (an NMConnection / profile), or NIL.
Use this to read or mutate the core connection settings before UPDATE-CONNECTION."
  (let ((s (gir:invoke (connection 'get-setting-connection))))
    (unless (null-object-p s) s)))

(defun make-connection (&key id type uuid (autoconnect :unset) interface)
  "Build and return a new in-memory NMSimpleConnection carrying an
NMSettingConnection.

TYPE is the connection type string (e.g. \"802-3-ethernet\", \"dummy\").
A UUID is generated when not supplied.  AUTOCONNECT is only set when given a
boolean (otherwise NetworkManager's default applies).  The result is not yet
saved -- pass it to ADD-CONNECTION."
  (let ((conn (gir:invoke ((namespace) "SimpleConnection" 'new)))
        (s-con (make-setting "SettingConnection")))
    (when id (setf (gir:property s-con 'id) id))
    (when type (setf (gir:property s-con 'type) type))
    (setf (gir:property s-con 'uuid) (or uuid (generate-uuid)))
    (when interface (setf (gir:property s-con 'interface-name) interface))
    (unless (eq autoconnect :unset)
      (setf (gir:property s-con 'autoconnect) (and autoconnect t)))
    (add-setting conn s-con)
    conn))

(defun add-ip4-setting (connection &key (method "auto"))
  "Attach an NMSettingIP4Config with the given METHOD string
(\"auto\", \"manual\", \"disabled\", \"link-local\", \"shared\") to CONNECTION.
Manual addresses are a Phase-4 concern (boxed property)."
  (let ((s (make-setting "SettingIP4Config")))
    (setf (gir:property s 'method) method)
    (add-setting connection s)))

(defun add-ip6-setting (connection &key (method "auto"))
  "Attach an NMSettingIP6Config with the given METHOD string
(\"auto\", \"manual\", \"disabled\", \"ignore\", \"link-local\") to CONNECTION."
  (let ((s (make-setting "SettingIP6Config")))
    (setf (gir:property s 'method) method)
    (add-setting connection s)))

;;; ---------------------------------------------------------------------------
;;; Wi-Fi (v2 Phase 4)
;;;
;;; The SSID is a GBytes property, which gir:property cannot set, so it goes
;;; through SET-BOXED-PROPERTY (see gvalue.lisp).

(defun setting-set-ssid (setting ssid)
  "Set the SSID (a string) on an NMSettingWireless SETTING.  The SSID is
encoded as UTF-8 octets wrapped in a GBytes."
  (let* ((octets (coerce (sb-ext:string-to-octets ssid :external-format :utf-8)
                         'list))
         (bytes (gir:invoke ((glib-namespace) "Bytes" 'new) octets)))
    (set-boxed-property setting "ssid" (%g-bytes-get-type) (gir::this-of bytes))))

(defun make-wifi-connection (ssid &key psk hidden interface)
  "Build (but do not activate) a Wi-Fi NMConnection for SSID.

With PSK, adds a WPA-PSK security setting; HIDDEN marks the SSID as
non-broadcast.  IPv4 and IPv6 default to automatic.  Pass the result to
ADD-AND-ACTIVATE (or use CONNECT-WIFI, which does both)."
  (let ((conn (make-connection :id ssid :type "802-11-wireless"
                               :interface interface))
        (s-wifi (make-setting "SettingWireless")))
    (setting-set-ssid s-wifi ssid)
    (when hidden (setf (gir:property s-wifi 'hidden) t))
    (add-setting conn s-wifi)
    (when psk
      (let ((s-sec (make-setting "SettingWirelessSecurity")))
        (setf (gir:property s-sec 'key-mgmt) "wpa-psk")
        (setf (gir:property s-sec 'psk) psk)
        (add-setting conn s-sec)))
    (add-ip4-setting conn :method "auto")
    (add-ip6-setting conn :method "auto")
    conn))
