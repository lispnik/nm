;;; main.lisp
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Your Name
;;;
;;; A small demonstration driver that prints a human-readable snapshot of
;;; the system's NetworkManager state using the read-only binding.

(in-package #:nm)

(defun summary (&optional (client (client)))
  "Return a snapshot of NetworkManager state as a property list."
  (list :version (version client)
        :connectivity (connectivity client)
        :networking-enabled (networking-enabled-p client)
        :wireless-enabled (wireless-enabled-p client)
        :devices
        (loop for dev in (devices client)
              collect (list* :interface (device-interface dev)
                             :type (device-type dev)
                             :state (device-state dev)
                             :driver (device-driver dev)
                             :hw-address (device-hw-address dev)
                             :ip4-addresses (device-ip4-addresses dev)
                             :ip4-gateway (device-ip4-gateway dev)
                             (when (and (wifi-device-p dev)
                                        (eq (device-state dev) :activated))
                               (let ((ap (active-access-point dev)))
                                 (when ap
                                   (list :ssid (ap-ssid ap)
                                         :strength (ap-strength ap)))))))))

(defun print-summary (&optional (client (client)) (stream *standard-output*))
  "Print a formatted overview of NetworkManager state to STREAM."
  (format stream "~&NetworkManager ~a  (connectivity: ~(~a~))~%"
          (version client) (connectivity client))
  (format stream "  networking ~:[off~;on~], wireless ~:[off~;on~]~%"
          (networking-enabled-p client) (wireless-enabled-p client))
  (dolist (dev (devices client))
    (format stream "~%  ~a  [~(~a~)]  ~(~a~)~@[  driver=~a~]~%"
            (device-interface dev) (device-type dev)
            (device-state dev) (device-driver dev))
    (when (device-hw-address dev)
      (format stream "      mac ~a~%" (device-hw-address dev)))
    (loop for (addr . prefix) in (device-ip4-addresses dev)
          do (format stream "      inet ~a/~a~%" addr prefix))
    (when (device-ip4-gateway dev)
      (format stream "      gateway ~a~%" (device-ip4-gateway dev)))
    (when (wifi-device-p dev)
      (let ((active (active-access-point dev)))
        (dolist (ap (access-points dev))
          (format stream "      ~:[ ~;*~] ~24a ~3d%  ~5d MHz~%"
                  (and active (string= (ap-bssid ap) (ap-bssid active)))
                  (or (ap-ssid ap) "<hidden>")
                  (ap-strength ap) (ap-frequency ap))))))
  (values))

(defun main ()
  "Entry point: print a snapshot of the local NetworkManager state."
  (handler-case
      (print-summary (make-client))
    (error (e)
      (format *error-output* "~&Could not query NetworkManager: ~a~%" e)
      (uiop:quit 1)))
  (values))