;;; dbus.lisp
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Matthew Kennedy
;;;
;;; A small GDBus utility for the handful of NetworkManager features that are
;;; exposed only on D-Bus and not through libnm's client API (e.g. device
;;; statistics).  It provides typed DBUS-GET-PROPERTY / DBUS-SET-PROPERTY over
;;; org.freedesktop.DBus.Properties, with GVariant<->Lisp marshaling for the
;;; common scalar types and arrays of them.
;;;
;;; g_dbus_connection_call_sync is synchronous and thread-safe and drives its
;;; own context, so none of this needs the shared event loop.

(in-package #:nm)

;;; ---------------------------------------------------------------------------
;;; Foreign declarations (libgio / libglib)

(cffi:defcfun ("g_bus_get_sync" %g-bus-get-sync) :pointer
  (bus-type :int) (cancellable :pointer) (error :pointer))   ; SYSTEM = 1

(cffi:defcfun ("g_dbus_connection_call_sync" %g-dbus-connection-call-sync) :pointer
  (connection :pointer) (bus-name :string) (object-path :string)
  (interface :string) (method :string) (parameters :pointer)
  (reply-type :pointer) (flags :int) (timeout-msec :int)
  (cancellable :pointer) (error :pointer))

;; GVariant constructors (return floating refs)
(cffi:defcfun ("g_variant_new_tuple" %g-variant-new-tuple) :pointer
  (children :pointer) (n-children :unsigned-long))
(cffi:defcfun ("g_variant_new_variant" %g-variant-new-variant) :pointer (value :pointer))
(cffi:defcfun ("g_variant_new_string" %g-variant-new-string) :pointer (string :string))
(cffi:defcfun ("g_variant_new_object_path" %g-variant-new-object-path) :pointer (path :string))
(cffi:defcfun ("g_variant_new_boolean" %g-variant-new-boolean) :pointer (value :boolean))
(cffi:defcfun ("g_variant_new_byte" %g-variant-new-byte) :pointer (value :uint8))
(cffi:defcfun ("g_variant_new_int16" %g-variant-new-int16) :pointer (value :int16))
(cffi:defcfun ("g_variant_new_uint16" %g-variant-new-uint16) :pointer (value :uint16))
(cffi:defcfun ("g_variant_new_int32" %g-variant-new-int32) :pointer (value :int32))
(cffi:defcfun ("g_variant_new_uint32" %g-variant-new-uint32) :pointer (value :uint32))
(cffi:defcfun ("g_variant_new_int64" %g-variant-new-int64) :pointer (value :int64))
(cffi:defcfun ("g_variant_new_uint64" %g-variant-new-uint64) :pointer (value :uint64))
(cffi:defcfun ("g_variant_new_double" %g-variant-new-double) :pointer (value :double))

;; GVariant accessors
(cffi:defcfun ("g_variant_classify" %g-variant-classify) :int (value :pointer))
(cffi:defcfun ("g_variant_n_children" %g-variant-n-children) :unsigned-long (value :pointer))
(cffi:defcfun ("g_variant_get_child_value" %g-variant-get-child-value) :pointer
  (value :pointer) (index :unsigned-long))
(cffi:defcfun ("g_variant_get_variant" %g-variant-get-variant) :pointer (value :pointer))
(cffi:defcfun ("g_variant_unref" %g-variant-unref) :void (value :pointer))
(cffi:defcfun ("g_variant_get_boolean" %g-variant-get-boolean) :boolean (value :pointer))
(cffi:defcfun ("g_variant_get_byte" %g-variant-get-byte) :uint8 (value :pointer))
(cffi:defcfun ("g_variant_get_int16" %g-variant-get-int16) :int16 (value :pointer))
(cffi:defcfun ("g_variant_get_uint16" %g-variant-get-uint16) :uint16 (value :pointer))
(cffi:defcfun ("g_variant_get_int32" %g-variant-get-int32) :int32 (value :pointer))
(cffi:defcfun ("g_variant_get_uint32" %g-variant-get-uint32) :uint32 (value :pointer))
(cffi:defcfun ("g_variant_get_int64" %g-variant-get-int64) :int64 (value :pointer))
(cffi:defcfun ("g_variant_get_uint64" %g-variant-get-uint64) :uint64 (value :pointer))
(cffi:defcfun ("g_variant_get_double" %g-variant-get-double) :double (value :pointer))
(cffi:defcfun ("g_variant_get_string" %g-variant-get-string) :string
  (value :pointer) (length :pointer))

(defparameter +nm-bus-name+ "org.freedesktop.NetworkManager")
(defparameter +props-interface+ "org.freedesktop.DBus.Properties")

;;; ---------------------------------------------------------------------------
;;; GVariant <-> Lisp

(defun %variant-tuple (children)
  "Build a floating tuple GVariant from a list of GVariant* CHILDREN (whose
floating refs the tuple absorbs)."
  (let ((n (length children)))
    (cffi:with-foreign-object (arr :pointer n)
      (loop for c in children for i from 0 do (setf (cffi:mem-aref arr :pointer i) c))
      (%g-variant-new-tuple arr n))))

(defun %variant->lisp (variant)
  "Convert a GVariant to a Lisp value: scalars to numbers/strings/booleans,
arrays/tuples to lists, nested variants unwrapped.  Signals NM-ERROR on a type
not handled (e.g. dict entries)."
  (case (code-char (%g-variant-classify variant))
    (#\b (%g-variant-get-boolean variant))
    (#\y (%g-variant-get-byte variant))
    (#\n (%g-variant-get-int16 variant))
    (#\q (%g-variant-get-uint16 variant))
    (#\i (%g-variant-get-int32 variant))
    (#\u (%g-variant-get-uint32 variant))
    (#\x (%g-variant-get-int64 variant))
    (#\t (%g-variant-get-uint64 variant))
    (#\d (%g-variant-get-double variant))
    ((#\s #\o #\g) (%g-variant-get-string variant (cffi:null-pointer)))
    (#\v (let ((inner (%g-variant-get-variant variant)))
           (unwind-protect (%variant->lisp inner) (%g-variant-unref inner))))
    (#\{                                ; dict entry -> (KEY . VALUE)
     (flet ((child (i) (let ((c (%g-variant-get-child-value variant i)))
                         (unwind-protect (%variant->lisp c) (%g-variant-unref c)))))
       (cons (child 0) (child 1))))
    ((#\a #\( #\r)                      ; array/tuple -> list (a{..} -> alist)
     (loop for i below (%g-variant-n-children variant)
           for child = (%g-variant-get-child-value variant i)
           collect (unwind-protect (%variant->lisp child) (%g-variant-unref child))))
    (t (error 'nm-error :message
              (format nil "unhandled D-Bus type '~A'"
                      (code-char (%g-variant-classify variant)))))))

(defun %make-variant (type value)
  "Build a floating GVariant of TYPE (a keyword) holding VALUE."
  (ecase type
    (:string (%g-variant-new-string value))
    (:object-path (%g-variant-new-object-path value))
    (:boolean (%g-variant-new-boolean value))
    (:byte (%g-variant-new-byte value))
    (:int16 (%g-variant-new-int16 value))
    (:uint16 (%g-variant-new-uint16 value))
    (:int32 (%g-variant-new-int32 value))
    (:uint32 (%g-variant-new-uint32 value))
    (:int64 (%g-variant-new-int64 value))
    (:uint64 (%g-variant-new-uint64 value))
    (:double (%g-variant-new-double (coerce value 'double-float)))))

;;; ---------------------------------------------------------------------------
;;; Connection + calls

(defvar *system-bus* nil "Cached GDBusConnection for the system bus.")

(defun system-bus ()
  "Return (and cache) the system-bus GDBusConnection."
  (ensure-libnm)
  (or *system-bus*
      (cffi:with-foreign-object (err :pointer)
        (setf (cffi:mem-ref err :pointer) (cffi:null-pointer))
        (let ((conn (%g-bus-get-sync 1 (cffi:null-pointer) err)))
          (maybe-signal-gerror err "could not connect to the system bus")
          (setf *system-bus* conn)))))

(defun dbus-call (path interface method params
                  &key (bus-name +nm-bus-name+) (timeout-msec 25000))
  "Call METHOD on INTERFACE of object PATH (owned by BUS-NAME) with PARAMS (a
floating GVariant tuple, or NIL).  Returns the reply GVariant* (the caller must
g_variant_unref it); signals NM-ERROR on failure."
  (cffi:with-foreign-object (err :pointer)
    (setf (cffi:mem-ref err :pointer) (cffi:null-pointer))
    (let ((reply (%g-dbus-connection-call-sync
                  (system-bus) bus-name path interface method
                  (or params (cffi:null-pointer))
                  (cffi:null-pointer) 0 timeout-msec (cffi:null-pointer) err)))
      (maybe-signal-gerror err (format nil "~A.~A" interface method))
      (when (cffi:null-pointer-p reply)
        (error 'nm-error :message (format nil "~A.~A returned no reply"
                                          interface method)))
      reply)))

(defun dbus-get-property (path interface property &key (bus-name +nm-bus-name+))
  "Read D-Bus PROPERTY of INTERFACE on object PATH (org.freedesktop.DBus
.Properties.Get), returning it as a Lisp value."
  (let ((reply (dbus-call path +props-interface+ "Get"
                          (%variant-tuple (list (%g-variant-new-string interface)
                                                (%g-variant-new-string property)))
                          :bus-name bus-name)))
    (unwind-protect
         (let ((box (%g-variant-get-child-value reply 0))) ; "(v)" -> the variant box
           (unwind-protect (%variant->lisp box) (%g-variant-unref box)))
      (%g-variant-unref reply))))

(defun dbus-get-all (path interface &key (bus-name +nm-bus-name+))
  "All properties of INTERFACE on object PATH (org.freedesktop.DBus.Properties
.GetAll) as an alist of (NAME . VALUE), values marshaled to Lisp."
  (let ((reply (dbus-call path +props-interface+ "GetAll"
                          (%variant-tuple (list (%g-variant-new-string interface)))
                          :bus-name bus-name)))
    (unwind-protect
         (let ((dict (%g-variant-get-child-value reply 0))) ; "(a{sv})" -> the dict
           (unwind-protect (%variant->lisp dict) (%g-variant-unref dict)))
      (%g-variant-unref reply))))

(defun dbus-set-property (path interface property type value
                          &key (bus-name +nm-bus-name+))
  "Set D-Bus PROPERTY of INTERFACE on object PATH to VALUE, marshaled as TYPE
(a keyword such as :UINT32, :STRING, :BOOLEAN).  Returns T."
  (let ((reply (dbus-call path +props-interface+ "Set"
                          (%variant-tuple
                           (list (%g-variant-new-string interface)
                                 (%g-variant-new-string property)
                                 (%g-variant-new-variant (%make-variant type value))))
                          :bus-name bus-name)))
    (%g-variant-unref reply)
    t))
