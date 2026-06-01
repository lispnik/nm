;;; client.lisp
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Your Name
;;;
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

Signals an error if NetworkManager is not running or cannot be reached."
  (let ((client (gir:invoke ((namespace) "Client" 'new) nil)))
    (when default
      (setf *client* client))
    client))

(defun client (&optional (client *client*))
  "Return CLIENT, defaulting to *CLIENT*, creating one on demand."
  (or client (make-client)))

;;; ---------------------------------------------------------------------------
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