;;; gvalue.lisp

;;; Low-level GObject/CFFI helpers shared by the v2 layers: loading the
;;; foreign libraries, the lazy GLib namespace, and a GValue-based setter for
;;; boxed-typed GObject properties.
;;;
;;; The boxed-property setter exists because cl-gobject-introspection cannot
;;; set boxed/GBytes-typed properties through gir:property (it passes the
;;; wrapper where a pointer is expected -- verified against live NM).  We set
;;; them the canonical GObject way: init a GValue, stuff the boxed pointer in,
;;; and call g_object_set_property.

(in-package #:nm)

;;; ---------------------------------------------------------------------------
;;; Foreign libraries
;;;
;;; cl-gobject-introspection resolves calls through the typelib and never
;;; loads these into the process symbol namespace, so our raw CFFI defcfuns
;;; cannot find their symbols until we load the libraries ourselves.  Done
;;; lazily so the system still loads on hosts without libnm.

(cffi:define-foreign-library libglib
  (t (:or "libglib-2.0.so.0" "libglib-2.0.so" "libglib-2.0.dylib")))

(cffi:define-foreign-library libgobject
  (t (:or "libgobject-2.0.so.0" "libgobject-2.0.so" "libgobject-2.0.dylib")))

(cffi:define-foreign-library libgio
  (t (:or "libgio-2.0.so.0" "libgio-2.0.so" "libgio-2.0.dylib")))

(cffi:define-foreign-library libnm
  (t (:or "libnm.so.0" "libnm.so" "libnm.dylib")))

(defvar *foreign-loaded* nil)

(defun ensure-libnm ()
  "Load libglib, libgobject, libgio and libnm into the process so the raw CFFI
calls in the v2 layer can resolve their symbols.  Idempotent."
  (or *foreign-loaded*
      (setf *foreign-loaded*
            (progn (cffi:use-foreign-library libglib)
                   (cffi:use-foreign-library libgobject)
                   (cffi:use-foreign-library libgio)
                   (cffi:use-foreign-library libnm)
                   t))))

;;; GLib namespace (lazy, like the NM namespace)

(defvar *glib* nil)

(defun glib-namespace ()
  (or *glib* (setf *glib* (gir:require-namespace "GLib" "2.0"))))

;;; GValue + boxed-property setting

;;; GType is gsize; the value union is two pointer-sized words.  24 bytes on
;;; a 64-bit platform.
(cffi:defcstruct g-value
  (g-type :unsigned-long)
  (data0 :uint64)
  (data1 :uint64))

(cffi:defcfun ("g_value_init" %g-value-init) :pointer
  (value :pointer)
  (g-type :unsigned-long))

(cffi:defcfun ("g_value_set_boxed" %g-value-set-boxed) :void
  (value :pointer)
  (boxed :pointer))

(cffi:defcfun ("g_value_unset" %g-value-unset) :void
  (value :pointer))

(cffi:defcfun ("g_object_set_property" %g-object-set-property) :void
  (object :pointer)
  (name :string)
  (value :pointer))

(cffi:defcfun ("g_bytes_get_type" %g-bytes-get-type) :unsigned-long)

;;; Reference ownership and cancellation

(cffi:defcfun ("g_object_unref" %g-object-unref) :void
  (object :pointer))

(cffi:defcfun ("g_cancellable_new" %g-cancellable-new) :pointer)

(cffi:defcfun ("g_cancellable_cancel" %g-cancellable-cancel) :void
  (cancellable :pointer))

(defun adopt-ref (object)
  "Take ownership of one (transfer-full) reference on the gir OBJECT, releasing
it with g_object_unref when the Lisp wrapper is garbage-collected.

Use for objects returned by libnm `..._finish' calls that we wrap by hand via
gir::gobject (which, unlike gir's own return path, sets up no GC).  Adopts the
existing reference -- it does NOT take an additional one."
  (when object
    (let ((address (cffi:pointer-address (gir::this-of object))))
      (trivial-garbage:finalize
       object
       (lambda () (%g-object-unref (cffi:make-pointer address))))))
  object)

(defun set-boxed-property (object name gtype boxed-ptr)
  "Set the boxed-typed GObject property NAME of gir OBJECT to BOXED-PTR (a
pointer to a boxed value of GType GTYPE), via a GValue and g_object_set_property.

Use this for properties gir:property cannot set, such as an NMSettingWireless
SSID (a GBytes).  GTYPE is typically obtained from a `..._get_type' call."
  (ensure-libnm)
  (cffi:with-foreign-object (val '(:struct g-value))
    (dotimes (i 3)                      ; zero the GValue (G_VALUE_INIT)
      (setf (cffi:mem-aref val :uint64 i) 0))
    (%g-value-init val gtype)
    (%g-value-set-boxed val boxed-ptr)
    (%g-object-set-property (gir::this-of object) name val)
    (%g-value-unset val)))

;;; GHashTable<string,string> unpacking
;;;
;;; Like GPtrArray, GHashTable isn't marshaled by cl-gobject-introspection, so
;;; we iterate it by hand.  Used for DHCP option dictionaries.

(cffi:defcfun ("g_hash_table_iter_init" %g-hash-table-iter-init) :void
  (iter :pointer)
  (table :pointer))

(cffi:defcfun ("g_hash_table_iter_next" %g-hash-table-iter-next) :boolean
  (iter :pointer)
  (key :pointer)
  (value :pointer))

(defun ghash-string->alist (table-ptr)
  "Unpack a GHashTable<string,string> (a raw foreign pointer) into an alist of
(KEY . VALUE) strings.  Returns NIL for a NULL table."
  (ensure-libnm)
  (when (and table-ptr (not (cffi:null-pointer-p table-ptr)))
    ;; GHashTableIter is an opaque struct of a handful of pointers; 8 is ample.
    (cffi:with-foreign-object (iter :pointer 8)
      (cffi:with-foreign-objects ((key :pointer) (value :pointer))
        (%g-hash-table-iter-init iter table-ptr)
        (loop while (%g-hash-table-iter-next iter key value)
              collect (cons (cffi:foreign-string-to-lisp (cffi:mem-ref key :pointer))
                            (cffi:foreign-string-to-lisp (cffi:mem-ref value :pointer))))))))
