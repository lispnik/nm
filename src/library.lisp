;;; library.lisp
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Matthew Kennedy
;;;
;;; Namespace acquisition and low-level GObject Introspection helpers
;;; shared by the rest of the binding.

(in-package #:nm)

(defparameter +nm-version+ "1.0"
  "The NM typelib version to require.  NetworkManager only ever shipped
a `NM-1.0' introspection namespace, even across 1.x library releases.")

(defvar *namespace* nil
  "Memoized handle to the introspected `NM' namespace.")

(defun namespace ()
  "Return the introspected NM namespace, loading the typelib on first use.

This is deliberately lazy: simply loading the system must not require
libnm (or even gobject-introspection) to be present, so that the code
can be compiled on hosts where NetworkManager is unavailable.  The
typelib is only touched once a caller actually reaches into the API."
  (or *namespace*
      (setf *namespace* (gir:require-namespace "NM" +nm-version+))))

(defun ensure-loaded ()
  "Force the NM typelib to load now, signalling immediately if libnm or
its introspection data is missing.  Returns the namespace object."
  (namespace))

;;; ---------------------------------------------------------------------------
;;; Enum decoding
;;;
;;; cl-gobject-introspection marshals enum *return* values to raw integers
;;; (see enum-type's MEM-GET, which reads a :uint).  To present an idiomatic
;;; API we map those integers back to keywords using the enum descriptor's
;;; value table.  Lookups are cached per enum name.

(defun keywordize (name)
  "Turn a GI value name such as \"activated\" or \"ip_config\" into a keyword."
  (intern (string-upcase (substitute #\- #\_ name)) :keyword))

;;; Pure decoders, separated from the namespace lookup so they can be unit
;;; tested without a running NetworkManager (see nm/test/unit).  ALIST is a
;;; list of (VALUE-NAME-STRING . INTEGER) as returned by gir:values-of.

(defun decode-enum (alist value)
  "Map integer VALUE to its keyword via ALIST, or return VALUE if unmatched."
  (loop for (name . v) in alist
        when (eql v value) return (keywordize name)
        finally (return value)))

(defun decode-flags (alist value)
  "Decode bitfield VALUE to the list of keywords whose single-bit flag is set."
  (loop for (name . v) in alist
        when (and (plusp v)
                  (zerop (logand v (1- v)))   ; single bit only
                  (logtest v value))
          collect (keywordize name)))

(defstruct (enum-cache (:constructor %make-enum-cache))
  "Per-enum decode tables: a value->keyword hash and the raw name/value alist."
  (reverse (make-hash-table) :type hash-table)
  (alist nil :type list))

(defvar *enum-tables* (make-hash-table :test 'equal)
  "Cache of ENUM-NAME -> ENUM-CACHE.")

(defun enum-table (enum-name)
  (or (gethash enum-name *enum-tables*)
      (let* ((alist (gir:values-of (gir:nget-desc (namespace) enum-name)))
             (reverse (make-hash-table)))
        (loop for (name . v) in alist
              do (setf (gethash v reverse) (keywordize name)))
        (setf (gethash enum-name *enum-tables*)
              (%make-enum-cache :reverse reverse :alist alist)))))

(defun enum->keyword (enum-name value)
  "Decode integer VALUE of NM enum ENUM-NAME to a keyword (O(1) lookup).

Falls back to the raw integer when no matching value is found (for forward
compatibility with newer libnm releases)."
  (multiple-value-bind (kw present)
      (gethash value (enum-cache-reverse (enum-table enum-name)))
    (if present kw value)))

(defun flags->keywords (enum-name value)
  "Decode integer bitfield VALUE of NM flags type ENUM-NAME to a list of
keywords, one per set single-bit flag.  Returns NIL for an empty bitfield,
e.g. (:KEY-MGMT-PSK :PAIR-CCMP)."
  (decode-flags (enum-cache-alist (enum-table enum-name)) value))

;;; ---------------------------------------------------------------------------
;;; Conditions

(define-condition nm-error (error)
  ((message :initarg :message :initform nil :reader nm-error-message)
   (cause :initarg :cause :initform nil :reader nm-error-cause))
  (:report (lambda (c stream)
             (format stream "NetworkManager error: ~A"
                     (or (nm-error-message c) (nm-error-cause c) "unknown"))))
  (:documentation "Signalled when a NetworkManager operation fails.  CAUSE
holds a printable description of the underlying error, if any."))

(defmacro with-nm-error ((&optional message) &body body)
  "Run BODY, re-signalling any error as an NM-ERROR carrying MESSAGE.  The
underlying error is normalised to its printed string as the CAUSE, so a
gir-path failure (which raises a gir::gerror object) surfaces with a readable
message rather than an opaque object."
  `(handler-case (progn ,@body)
     (nm-error (e) (error e))
     (error (e) (error 'nm-error :message ,message :cause (princ-to-string e)))))

;;; ---------------------------------------------------------------------------
;;; Object helpers

(defun null-object-p (object)
  "True when a GI call returned a NULL GObject (represented as NIL or a
null foreign pointer)."
  (or (null object)
      (and (cffi:pointerp object) (cffi:null-pointer-p object))))

(defmacro getter (object method)
  "Invoke a nullary getter METHOD on OBJECT, yielding NIL for NULL objects."
  (let ((o (gensym "OBJ")))
    `(let ((,o ,object))
       (unless (null-object-p ,o)
         (gir:invoke (,o ,method))))))

(defun value-pointer (x)
  "The raw foreign pointer behind a gir wrapper X (struct or object instance),
X itself if it is already a pointer, or a NULL pointer for NIL.  Used to reach
unmarshaled containers (GHashTable, GPtrArray) that gir hands back wrapped."
  (cond ((null x) (cffi:null-pointer))
        ((cffi:pointerp x) x)
        (t (gir::this-of x))))

;;; ---------------------------------------------------------------------------
;;; GPtrArray unpacking
;;;
;;; cl-gobject-introspection only marshals C arrays; a GPtrArray return type
;;; falls through to a raw foreign pointer (see PARSE-ARRAY-TYPE-INFO).  NM
;;; uses GPtrArray pervasively (device lists, access points, IP addresses),
;;; so we unpack it by hand and re-wrap each element as a gir object.
;;;
;;; LIFETIME: these accessors return (transfer none) data owned by the
;;; NMClient's object cache.  The wrapper objects we hand back do not take
;;; a reference, so they are only valid while the originating NMClient (and
;;; for IP-address structs, the owning NMIPConfig) is alive and unchanged.
;;; Treat all returned objects as snapshots: read what you need promptly
;;; rather than stashing them across the client's lifetime.

(cffi:defcstruct g-ptr-array
  (pdata :pointer)
  (len :uint))

(defun ptr-array-pointers (array)
  "Return the element pointers of a GPtrArray ARRAY (a raw foreign pointer),
or NIL when ARRAY is NULL."
  (unless (null-object-p array)
    (cffi:with-foreign-slots ((pdata len) array (:struct g-ptr-array))
      (loop for i below len
            collect (cffi:mem-aref pdata :pointer i)))))

(defun ptr-array-objects (array)
  "Unpack a GPtrArray of GObjects into a list of gir object wrappers, each
built with its most-derived introspected type (so e.g. a Wi-Fi device
comes back as an NMDeviceWifi, not a bare NMDevice)."
  (loop for p in (ptr-array-pointers array)
        unless (cffi:null-pointer-p p)
          collect (gir::gobject (gir::gtype p) p)))

(defun most-derived (object)
  "Re-wrap a gir OBJECT as its most-derived introspected type.

gir wraps a single-object *return value* using the function's statically
declared type, so e.g. NMClient.get_device_by_iface yields a bare
NMDevice even for a Wi-Fi device.  Re-reading the live GType off the
pointer recovers the real class (NMDeviceWifi, NMVpnConnection, ...)."
  (unless (null-object-p object)
    (let ((ptr (gir::this-of object)))
      (gir::gobject (gir::gtype ptr) ptr))))

(defun ptr-array-structs (array struct-name)
  "Unpack a GPtrArray of boxed structs named STRUCT-NAME (in the NM
namespace, e.g. \"IPAddress\") into a list of gir struct wrappers."
  (let ((class (gir:nget (namespace) struct-name)))
    (loop for p in (ptr-array-pointers array)
          unless (cffi:null-pointer-p p)
            collect (gir::build-struct-ptr class p))))

(defun gbytes->octets (bytes)
  "Copy a GLib.Bytes instance into a freshly allocated octet vector.
Returns NIL when BYTES is NULL."
  (unless (null-object-p bytes)
    (let ((data (gir:invoke (bytes 'get-data))))
      ;; GLib.Bytes.get_data is introspected as a byte array, which the
      ;; library returns as a CL sequence of (UNSIGNED-BYTE 8).
      (map '(simple-array (unsigned-byte 8) (*)) #'identity data))))

(defun octets->string (octets)
  "Best-effort decode of an octet vector to a string.  SSIDs are not
guaranteed to be valid UTF-8, so undecodable input falls back to a
Latin-1 reading rather than signalling."
  (when octets
    (let ((octets (coerce octets '(simple-array (unsigned-byte 8) (*)))))
      (handler-case
          (babel:octets-to-string octets :encoding :utf-8)
        (error ()
          (babel:octets-to-string octets :encoding :latin-1))))))

(defun string->octets (string)
  "Encode STRING to a UTF-8 octet vector."
  (babel:string-to-octets string :encoding :utf-8))