;;; cli.lisp
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Your Name
;;;
;;; A small nmcli-like command-line front end that exercises the nm
;;; binding, built with clingon.

(defpackage #:nm.cli
  (:use #:cl)
  (:export #:main #:toplevel))

(in-package #:nm.cli)

;;; ---------------------------------------------------------------------------
;;; Helpers

(defun kw (value)
  "Render an enum keyword (or integer fallback) the way nmcli would, e.g.
:WIFI -> \"wifi\"."
  (string-downcase (princ-to-string value)))

(defun ensure-client ()
  "Connect to NetworkManager, exiting with a diagnostic on failure."
  (handler-case (nm:make-client)
    (error (e)
      (format *error-output* "error: cannot reach NetworkManager: ~A~%" e)
      (clingon:exit 1))))

(defmacro defcmd (name &body make-command-args)
  "Define a zero-argument constructor NAME/COMMAND returning a clingon
command built from MAKE-COMMAND-ARGS."
  `(defun ,(intern (format nil "~A/COMMAND" name)) ()
     (clingon:make-command ,@make-command-args)))

;;; ---------------------------------------------------------------------------
;;; general

(defun general/handler (cmd)
  (declare (ignore cmd))
  (let ((c (ensure-client)))
    (format t "~12A ~A~%" "VERSION" (nm:version c))
    (format t "~12A ~A~%" "STATE" (kw (nm:connectivity c)))
    (format t "~12A ~:[disabled~;enabled~]~%" "NETWORKING" (nm:networking-enabled-p c))
    (format t "~12A ~:[disabled~;enabled~]~%" "WIFI" (nm:wireless-enabled-p c))))

(defcmd general
  :name "general"
  :description "show overall NetworkManager status"
  :aliases '("g" "status")
  :handler #'general/handler)

;;; ---------------------------------------------------------------------------
;;; device

(defun device-connection-name (device)
  (let ((ac (nm:device-active-connection device)))
    (if ac (nm:ac-id ac) "--")))

(defun list-devices (client)
  (format t "~16A ~10A ~14A ~A~%" "DEVICE" "TYPE" "STATE" "CONNECTION")
  (dolist (d (nm:devices client))
    (format t "~16A ~10A ~14A ~A~%"
            (nm:device-interface d)
            (kw (nm:device-type d))
            (kw (nm:device-state d))
            (device-connection-name d))))

(defun show-device (client iface)
  (let ((d (nm:find-device iface client)))
    (unless d
      (format *error-output* "error: device '~A' not found~%" iface)
      (clingon:exit 1))
    (format t "~22A ~A~%" "GENERAL.DEVICE:" (nm:device-interface d))
    (format t "~22A ~A~%" "GENERAL.TYPE:" (kw (nm:device-type d)))
    (when (nm:device-hw-address d)
      (format t "~22A ~A~%" "GENERAL.HWADDR:" (nm:device-hw-address d)))
    (format t "~22A ~A~%" "GENERAL.STATE:" (kw (nm:device-state d)))
    (when (nm:device-driver d)
      (format t "~22A ~A~%" "GENERAL.DRIVER:" (nm:device-driver d)))
    (when (plusp (nm:device-mtu d))
      (format t "~22A ~A~%" "GENERAL.MTU:" (nm:device-mtu d)))
    (format t "~22A ~A~%" "GENERAL.CONNECTION:" (device-connection-name d))
    (loop for (addr . prefix) in (nm:device-ip4-addresses d)
          for i from 1
          do (format t "~22A ~A/~A~%"
                     (format nil "IP4.ADDRESS[~D]:" i) addr prefix))
    (when (nm:device-ip4-gateway d)
      (format t "~22A ~A~%" "IP4.GATEWAY:" (nm:device-ip4-gateway d)))
    (loop for dns in (nm:device-ip4-nameservers d)
          for i from 1
          do (format t "~22A ~A~%" (format nil "IP4.DNS[~D]:" i) dns))))

(defun device/handler (cmd)
  (let ((client (ensure-client))
        (args (clingon:command-arguments cmd)))
    (if args
        (dolist (iface args) (show-device client iface))
        (list-devices client))))

(defcmd device
  :name "device"
  :description "list network devices, or show one by interface name"
  :aliases '("dev" "d")
  :usage "[IFACE ...]"
  :handler #'device/handler)

;;; ---------------------------------------------------------------------------
;;; wifi

(defun wifi-device (client ifname)
  "Resolve the Wi-Fi device to operate on: IFNAME when given, else the
first Wi-Fi device found."
  (let ((d (if ifname
               (nm:find-device ifname client)
               (find-if #'nm:wifi-device-p (nm:devices client)))))
    (cond ((null d)
           (format *error-output* "error: ~:[no Wi-Fi device found~;device '~:*~A' not found~]~%"
                   ifname)
           (clingon:exit 1))
          ((not (nm:wifi-device-p d))
           (format *error-output* "error: '~A' is not a Wi-Fi device~%"
                   (nm:device-interface d))
           (clingon:exit 1))
          (t d))))

(defun wifi/handler (cmd)
  (let* ((client (ensure-client))
         (dev (wifi-device client (clingon:getopt cmd :ifname)))
         (active (nm:active-access-point dev)))
    (format t "~2A ~32A ~8A ~6A ~A~%" "" "SSID" "MODE" "SIGNAL" "FREQ")
    (dolist (ap (sort (nm:access-points dev) #'> :key #'nm:ap-strength))
      (format t "~2A ~32A ~8A ~4D%  ~5D MHz~%"
              (if (and active (string= (nm:ap-bssid ap) (nm:ap-bssid active)))
                  "*" "")
              (or (nm:ap-ssid ap) "--")
              (kw (nm:ap-mode ap))
              (nm:ap-strength ap)
              (nm:ap-frequency ap)))))

(defcmd wifi
  :name "wifi"
  :description "list visible Wi-Fi access points"
  :aliases '("w")
  :options (list (clingon:make-option
                  :string
                  :description "Wi-Fi interface to use (default: first found)"
                  :short-name #\i
                  :long-name "ifname"
                  :key :ifname))
  :handler #'wifi/handler)

;;; ---------------------------------------------------------------------------
;;; connection

(defun connection/handler (cmd)
  (declare (ignore cmd))
  (let ((client (ensure-client)))
    (format t "~34A ~16A ~10A ~A~%" "NAME" "TYPE" "STATE" "DEFAULT")
    (dolist (ac (nm:active-connections client))
      (format t "~34A ~16A ~10A ~:[no~;yes~]~%"
              (nm:ac-id ac)
              (nm:ac-type ac)
              (kw (nm:ac-state ac))
              (nm:ac-default-p ac)))))

(defcmd connection
  :name "connection"
  :description "list active connections"
  :aliases '("con" "c")
  :handler #'connection/handler)

;;; ---------------------------------------------------------------------------
;;; top level

(defun toplevel/handler (cmd)
  "With no sub-command, print usage."
  (clingon:print-usage-and-exit cmd t))

(defun toplevel ()
  (clingon:make-command
   :name "nm"
   :description "a small nmcli-like tool built on the nm libnm binding"
   :version "0.1.0"
   :license "MIT"
   :handler #'toplevel/handler
   :sub-commands (list (general/command)
                       (device/command)
                       (wifi/command)
                       (connection/command))))

(defun main ()
  "Entry point for the nm CLI executable."
  (clingon:run (toplevel)))