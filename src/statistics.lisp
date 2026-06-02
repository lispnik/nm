;;; statistics.lisp

;;; Device traffic statistics.
;;;
;;; libnm's client API does NOT expose device statistics -- they live only on
;;; the org.freedesktop.NetworkManager.Device.Statistics D-Bus interface (no
;;; nm_device_get_tx_bytes function, no tx-bytes GObject property; verified
;;; against libnm 1.52 and the libnm reference manual).  So we read them over
;;; D-Bus via the DBUS-GET-PROPERTY / DBUS-SET-PROPERTY utility (dbus.lisp),
;;; using libnm only to discover the device's object path.

(in-package #:nm)

;; NMDevice.get_path returns the *hardware* path; the D-Bus object path is
;; NMObject.get_path (which gir's method lookup shadows), so bind it directly.
(cffi:defcfun ("nm_object_get_path" %nm-object-get-path) :string (object :pointer))

(defparameter +statistics-interface+
  "org.freedesktop.NetworkManager.Device.Statistics")

(defun device-path (device)
  "The D-Bus object path of DEVICE, e.g.
\"/org/freedesktop/NetworkManager/Devices/3\"."
  (when (null-object-p device)
    (error 'nm-error :message "device-path: no such device (got NIL -- check the interface name)"))
  (ensure-libnm)
  (%nm-object-get-path (gir::this-of device)))

(defun enable-statistics (device &key (interval-ms 1000))
  "Ask NetworkManager to refresh DEVICE's traffic counters every INTERVAL-MS
milliseconds (0 disables).  Counters are unavailable until this is called.
Returns DEVICE."
  (dbus-set-property (device-path device) +statistics-interface+
                     "RefreshRateMs" :uint32 interval-ms)
  device)

(defun device-tx-bytes (device)
  "Total bytes transmitted by DEVICE (kernel counter), or 0 until statistics
have been enabled and the daemon has refreshed at least once."
  (dbus-get-property (device-path device) +statistics-interface+ "TxBytes"))

(defun device-rx-bytes (device)
  "Total bytes received by DEVICE (kernel counter)."
  (dbus-get-property (device-path device) +statistics-interface+ "RxBytes"))

(defun device-statistics (device &key (interval-ms 1000))
  "Enable statistics on DEVICE, wait one refresh interval for the daemon to
populate the counters, and return (:TX tx-bytes :RX rx-bytes)."
  (enable-statistics device :interval-ms interval-ms)
  (sleep (+ 0.25 (/ interval-ms 1000.0)))
  (list :tx (device-tx-bytes device) :rx (device-rx-bytes device)))
