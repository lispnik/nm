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

(defmacro with-cli-errors (&body body)
  "Run BODY, reporting any error (NM-ERROR or otherwise) to stderr and exiting
non-zero.  Used to wrap mutating operations."
  `(handler-case (progn ,@body)
     (nm:nm-error (e)
       (format *error-output* "error: ~A~%" (nm:nm-error-message e))
       (clingon:exit 1))
     (error (e)
       (format *error-output* "error: ~A~%" e)
       (clingon:exit 1))))

(defun parse-bool (string)
  "Parse an on/off-style STRING to a boolean."
  (cond ((member string '("on" "yes" "true" "enable" "enabled" "1")
                 :test #'string-equal) t)
        ((member string '("off" "no" "false" "disable" "disabled" "0")
                 :test #'string-equal) nil)
        (t (error "expected on/off, got ~S" string))))

(defun require-arg (cmd usage)
  "Return the first positional argument of CMD, or print USAGE and exit."
  (or (first (clingon:command-arguments cmd))
      (progn (format *error-output* "usage: ~A~%" usage) (clingon:exit 1))))

(defun find-profile (name client)
  "Find a saved profile by UUID or by id."
  (or (nm:find-connection name client)
      (find name (nm:connections client)
            :key #'nm:connection-id :test #'string=)))

(defun find-active (name client)
  "Find an active connection by id or UUID."
  (find-if (lambda (ac)
             (or (string= name (nm:ac-id ac)) (string= name (nm:ac-uuid ac))))
           (nm:active-connections client)))

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
          do (format t "~22A ~A~%" (format nil "IP4.DNS[~D]:" i) dns))
    (loop for (addr . prefix) in (nm:device-ip6-addresses d)
          for i from 1
          do (format t "~22A ~A/~A~%"
                     (format nil "IP6.ADDRESS[~D]:" i) addr prefix))
    (when (nm:device-ip6-gateway d)
      (format t "~22A ~A~%" "IP6.GATEWAY:" (nm:device-ip6-gateway d)))
    (loop for dns in (nm:device-ip6-nameservers d)
          for i from 1
          do (format t "~22A ~A~%" (format nil "IP6.DNS[~D]:" i) dns))))

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
    (format t "~2A ~32A ~8A ~14A ~6A ~A~%" "" "SSID" "MODE" "SECURITY" "SIGNAL" "FREQ")
    (dolist (ap (sort (nm:access-points dev) #'> :key #'nm:ap-strength))
      (format t "~2A ~32A ~8A ~14A ~4D%  ~5D MHz~%"
              (if (and active (string= (nm:ap-bssid ap) (nm:ap-bssid active)))
                  "*" "")
              (or (nm:ap-ssid ap) "--")
              (kw (nm:ap-mode ap))
              (let ((sec (nm:ap-security ap)))
                (if sec
                    (format nil "~{~A~^/~}" (mapcar #'kw sec))
                    "open"))
              (nm:ap-strength ap)
              (nm:ap-frequency ap)))))

(defun wifi-connect/handler (cmd)
  (let ((client (ensure-client))
        (ssid (require-arg cmd "nm wifi connect SSID [--password PSK] [--ifname DEV] [--hidden]")))
    (with-cli-errors
      (let ((ac (nm:connect-wifi ssid
                                 :psk (clingon:getopt cmd :password)
                                 :device (clingon:getopt cmd :ifname)
                                 :hidden (clingon:getopt cmd :hidden)
                                 :client client)))
        (format t "connecting to ~A ... ~(~A~)~%" ssid (nm:ac-state ac))))))

(defcmd wifi-connect
  :name "connect"
  :description "connect to a Wi-Fi network: connect SSID [--password PSK]"
  :usage "SSID"
  :options (list (clingon:make-option
                  :string :description "WPA-PSK passphrase"
                  :short-name #\p :long-name "password" :key :password)
                 (clingon:make-option
                  :string :description "Wi-Fi interface to use"
                  :short-name #\i :long-name "ifname" :key :ifname)
                 (clingon:make-option
                  :flag :description "SSID is hidden (non-broadcast)"
                  :long-name "hidden" :key :hidden))
  :handler #'wifi-connect/handler)

(defcmd wifi
  :name "wifi"
  :description "list visible Wi-Fi access points (subcommand: connect)"
  :aliases '("w")
  :options (list (clingon:make-option
                  :string
                  :description "Wi-Fi interface to use (default: first found)"
                  :short-name #\i
                  :long-name "ifname"
                  :key :ifname))
  :handler #'wifi/handler
  :sub-commands (list (wifi-connect/command)))

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

(defun con-up/handler (cmd)
  (let* ((client (ensure-client))
         (name (require-arg cmd "nm connection up <id|uuid>")))
    (with-cli-errors
      (let ((prof (find-profile name client)))
        (unless prof
          (format *error-output* "error: no such profile: ~A~%" name)
          (clingon:exit 1))
        (let ((ac (nm:activate-and-wait prof :client client :timeout 30)))
          (format t "activated ~A (~(~A~))~%" (nm:ac-id ac) (nm:ac-state ac)))))))

(defcmd con-up
  :name "up"
  :description "activate a saved connection profile by id or uuid"
  :usage "<id|uuid>"
  :handler #'con-up/handler)

(defun con-down/handler (cmd)
  (let* ((client (ensure-client))
         (name (require-arg cmd "nm connection down <id|uuid>")))
    (with-cli-errors
      (let ((ac (find-active name client)))
        (unless ac
          (format *error-output* "error: no active connection: ~A~%" name)
          (clingon:exit 1))
        (nm:deactivate ac client)
        (format t "deactivated ~A~%" name)))))

(defcmd con-down
  :name "down"
  :description "deactivate an active connection by id or uuid"
  :usage "<id|uuid>"
  :handler #'con-down/handler)

(defun con-delete/handler (cmd)
  (let* ((client (ensure-client))
         (name (require-arg cmd "nm connection delete <id|uuid>")))
    (with-cli-errors
      (let ((prof (find-profile name client)))
        (unless prof
          (format *error-output* "error: no such profile: ~A~%" name)
          (clingon:exit 1))
        (nm:delete-connection prof)
        (format t "deleted ~A~%" name)))))

(defcmd con-delete
  :name "delete"
  :description "delete a saved connection profile by id or uuid"
  :usage "<id|uuid>"
  :handler #'con-delete/handler)

(defcmd connection
  :name "connection"
  :description "list active connections (subcommands: up, down, delete)"
  :aliases '("con" "c")
  :handler #'connection/handler
  :sub-commands (list (con-up/command) (con-down/command) (con-delete/command)))

;;; ---------------------------------------------------------------------------
;;; networking / radio toggles

(defun show-toggle (label state)
  (format t "~A ~:[disabled~;enabled~]~%" label state))

(defun networking/handler (cmd)
  (let ((client (ensure-client))
        (arg (first (clingon:command-arguments cmd))))
    (with-cli-errors
      (when arg (nm:set-networking-enabled (parse-bool arg) client))
      ;; Re-read through a fresh client: a just-set property isn't reflected in
      ;; the original client's cache until its change signal is processed.
      (show-toggle "networking"
                   (nm:networking-enabled-p (if arg (nm:make-client) client))))))

(defcmd networking
  :name "networking"
  :description "show or set global networking: networking [on|off]"
  :usage "[on|off]"
  :handler #'networking/handler)

(defun radio/handler (cmd)
  (let* ((client (ensure-client))
         (args (clingon:command-arguments cmd))
         (which (first args))
         (state (second args)))
    (with-cli-errors
      (flet ((toggle (label getter setter)
               (when state (funcall setter (parse-bool state) client))
               ;; fresh client for read-back after a set (see networking/handler)
               (show-toggle label (funcall getter (if state (nm:make-client) client)))))
        (cond ((null which)
               (toggle "wifi" #'nm:wireless-enabled-p #'nm:set-wireless-enabled)
               (toggle "wwan" #'nm:wwan-enabled-p #'nm:set-wwan-enabled))
              ((string-equal which "wifi")
               (toggle "wifi" #'nm:wireless-enabled-p #'nm:set-wireless-enabled))
              ((string-equal which "wwan")
               (toggle "wwan" #'nm:wwan-enabled-p #'nm:set-wwan-enabled))
              (t (format *error-output* "error: unknown radio '~A' (wifi|wwan)~%" which)
                 (clingon:exit 1)))))))

(defcmd radio
  :name "radio"
  :description "show or set radios: radio [wifi|wwan] [on|off]"
  :usage "[wifi|wwan] [on|off]"
  :handler #'radio/handler)

;;; ---------------------------------------------------------------------------
;;; monitor

(defun monitor/handler (cmd)
  (declare (ignore cmd))
  (let ((client (ensure-client)))
    (nm:on-device-added
     (lambda (d) (format t "+ device ~A (~(~A~))~%"
                         (nm:device-interface d) (nm:device-type d))
       (force-output)))
    (nm:on-device-removed
     (lambda (d) (format t "- device ~A~%" (nm:device-interface d)) (force-output)))
    (nm:on-connectivity-changed
     (lambda (state) (format t "~~ connectivity ~(~A~)~%" state) (force-output)))
    (dolist (d (nm:devices client))
      (let ((iface (nm:device-interface d)))
        (nm:on-state-changed
         (lambda (new old reason)
           (declare (ignore old))
           (format t "= ~A ~(~A~) (~(~A~))~%" iface new reason) (force-output))
         d)))
    (format t "monitoring NetworkManager events (Ctrl-C to stop) ...~%")
    (force-output)
    (nm:start-event-loop)
    (unwind-protect
         (loop (sleep 1))
      (nm:stop-event-loop))))

(defcmd monitor
  :name "monitor"
  :description "watch NetworkManager events until interrupted"
  :aliases '("mon")
  :handler #'monitor/handler)

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
                       (connection/command)
                       (networking/command)
                       (radio/command)
                       (monitor/command))))

(defun main ()
  "Entry point for the nm CLI executable."
  (clingon:run (toplevel)))