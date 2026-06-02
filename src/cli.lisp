;;; cli.lisp
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Matthew Kennedy
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

;;; --- JSON output ----------------------------------------------------------
;;; Objects are (cons :obj alist), arrays (cons :arr list); booleans use T and
;;; :false to stay unambiguous against NIL (which prints as null).

(defun jobj (alist) (cons :obj alist))
(defun jarr (list) (cons :arr list))

(defun json-string (x stream)
  (write-char #\" stream)
  (loop for ch across (string x) do
    (case ch
      (#\" (write-string "\\\"" stream))
      (#\\ (write-string "\\\\" stream))
      (#\Newline (write-string "\\n" stream))
      (t (write-char ch stream))))
  (write-char #\" stream))

(defun write-json (v stream)
  (cond ((eq v t) (write-string "true" stream))
        ((eq v :false) (write-string "false" stream))
        ((null v) (write-string "null" stream))
        ((integerp v) (princ v stream))
        ((stringp v) (json-string v stream))
        ((keywordp v) (json-string (string-downcase (symbol-name v)) stream))
        ((and (consp v) (eq (car v) :obj))
         (write-char #\{ stream)
         (loop for ((k . val) . more) on (cdr v) do
           (json-string (string k) stream) (write-char #\: stream)
           (write-json val stream) (when more (write-char #\, stream)))
         (write-char #\} stream))
        ((and (consp v) (eq (car v) :arr))
         (write-char #\[ stream)
         (loop for (item . more) on (cdr v) do
           (write-json item stream) (when more (write-char #\, stream)))
         (write-char #\] stream))
        (t (json-string (princ-to-string v) stream))))

(defun json (v) (write-json v *standard-output*) (terpri))

(defun jbool (x) (if x t :false))

(defun coerce-setting-value (string)
  "Heuristically coerce a CLI STRING to a boolean/integer/string for setting a
connection property."
  (cond ((member string '("yes" "true" "on") :test #'string-equal) t)
        ((member string '("no" "false" "off") :test #'string-equal) nil)
        ((and (plusp (length string)) (every #'digit-char-p string))
         (parse-integer string))
        (t string)))

(defun connection-setting-object (profile prefix)
  "Resolve the NMSetting named by PREFIX (e.g. \"ipv4\", \"connection\") on a
saved PROFILE, or NIL."
  (let ((s (cond ((string-equal prefix "connection")
                  (gir:invoke (profile 'get-setting-connection)))
                 ((string-equal prefix "ipv4")
                  (gir:invoke (profile 'get-setting-ip4-config)))
                 ((string-equal prefix "ipv6")
                  (gir:invoke (profile 'get-setting-ip6-config)))
                 ((member prefix '("wifi" "802-11-wireless") :test #'string-equal)
                  (gir:invoke (profile 'get-setting-wireless)))
                 ((member prefix '("wifi-sec" "802-11-wireless-security")
                          :test #'string-equal)
                  (gir:invoke (profile 'get-setting-wireless-security)))
                 (t nil))))
    (unless (nm:null-object-p s) s)))

;;; ---------------------------------------------------------------------------
;;; general

(defparameter +permissions+
  '(:enable-disable-network :enable-disable-wifi :enable-disable-wwan
    :network-control :wifi-share-protected :wifi-share-open
    :settings-modify-system :settings-modify-own :reload)
  "Permissions reported by the `general permissions' command.")

(defun general/handler (cmd)
  (let* ((c (ensure-client))
         (version (nm:version c))
         (state (kw (nm:state c)))
         (connectivity (kw (nm:connectivity c)))
         (metered (kw (nm:metered c)))
         (net (nm:networking-enabled-p c))
         (wifi (nm:wireless-enabled-p c))
         (wwan (nm:wwan-enabled-p c)))
    (cond
      ((clingon:getopt cmd :json)
       (json (jobj (list (cons "version" version) (cons "state" state)
                         (cons "connectivity" connectivity) (cons "metered" metered)
                         (cons "networking" (jbool net)) (cons "wifi" (jbool wifi))
                         (cons "wwan" (jbool wwan))))))
      ((clingon:getopt cmd :terse)
       (format t "~A:~A:~A:~A:~:[disabled~;enabled~]:~:[disabled~;enabled~]:~:[disabled~;enabled~]~%"
               version state connectivity metered net wifi wwan))
      (t
       (format t "~14A ~A~%" "VERSION" version)
       (format t "~14A ~A~%" "STATE" state)
       (format t "~14A ~A~%" "CONNECTIVITY" connectivity)
       (format t "~14A ~A~%" "METERED" metered)
       (format t "~14A ~:[disabled~;enabled~]~%" "NETWORKING" net)
       (format t "~14A ~:[disabled~;enabled~]~%" "WIFI" wifi)
       (format t "~14A ~:[disabled~;enabled~]~%" "WWAN" wwan)))))

(defun general-permissions/handler (cmd)
  (declare (ignore cmd))
  (let ((c (ensure-client)))
    (dolist (p +permissions+)
      (format t "~36A ~A~%" (string-downcase (symbol-name p)) (kw (nm:permission p c))))))

(defcmd general-permissions
  :name "permissions"
  :description "show the caller's PolicyKit permissions"
  :handler #'general-permissions/handler)

(defcmd general
  :name "general"
  :description "show overall NetworkManager status (subcommand: permissions)"
  :aliases '("g" "status")
  :options (list (clingon:make-option
                  :flag :description "terse, colon-separated output"
                  :short-name #\t :long-name "terse" :key :terse)
                 (clingon:make-option
                  :flag :description "JSON output"
                  :short-name #\j :long-name "json" :key :json))
  :handler #'general/handler
  :sub-commands (list (general-permissions/command)))

;;; ---------------------------------------------------------------------------
;;; device

(defun device-connection-name (device)
  (let ((ac (nm:device-active-connection device)))
    (if ac (nm:ac-id ac) "--")))

(defun list-devices (client &key terse json)
  (cond
    (json
     (json (jarr (mapcar (lambda (d)
                           (jobj (list (cons "device" (nm:device-interface d))
                                       (cons "type" (kw (nm:device-type d)))
                                       (cons "state" (kw (nm:device-state d)))
                                       (cons "connection" (let ((n (device-connection-name d)))
                                                            (unless (string= n "--") n))))))
                         (nm:devices client)))))
    (t
     (unless terse
       (format t "~16A ~10A ~14A ~A~%" "DEVICE" "TYPE" "STATE" "CONNECTION"))
     (dolist (d (nm:devices client))
       (if terse
           (format t "~A:~(~A~):~(~A~):~A~%"
                   (nm:device-interface d) (nm:device-type d)
                   (nm:device-state d) (device-connection-name d))
           (format t "~16A ~10A ~14A ~A~%"
                   (nm:device-interface d)
                   (kw (nm:device-type d))
                   (kw (nm:device-state d))
                   (device-connection-name d)))))))

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
          do (format t "~22A ~A~%" (format nil "IP6.DNS[~D]:" i) dns))
    (flet ((routes (label routes)
             (loop for r in routes for i from 1
                   do (format t "~22A ~A/~A~@[ via ~A~]~@[ metric ~A~]~%"
                              (format nil "~A.ROUTE[~D]:" label i)
                              (getf r :dest) (getf r :prefix) (getf r :next-hop)
                              (let ((m (getf r :metric))) (when (and m (>= m 0)) m)))))
           (domains (label doms)
             (loop for dom in doms for i from 1
                   do (format t "~22A ~A~%" (format nil "~A.DOMAIN[~D]:" label i) dom))))
      (routes "IP4" (nm:device-ip4-routes d))
      (domains "IP4" (nm:device-ip4-domains d))
      (routes "IP6" (nm:device-ip6-routes d))
      (domains "IP6" (nm:device-ip6-domains d)))
    (let ((caps (nm:device-capabilities d)))
      (when caps (format t "~22A ~{~(~A~)~^, ~}~%" "CAPABILITIES:" caps)))
    (let ((speed (nm:device-speed d)))
      (when (and speed (plusp speed)) (format t "~22A ~A Mb/s~%" "SPEED:" speed)))
    (loop for (k . v) in (nm:device-dhcp4-options d) for i from 1
          do (format t "~22A ~A = ~A~%" (format nil "DHCP4.OPTION[~D]:" i) k v))))

(defun device/handler (cmd)
  (let ((client (ensure-client))
        (args (clingon:command-arguments cmd)))
    (if args
        (dolist (iface args) (show-device client iface))
        (list-devices client :terse (clingon:getopt cmd :terse)
                             :json (clingon:getopt cmd :json)))))

(defun device-connect/handler (cmd)
  (let ((client (ensure-client))
        (iface (require-arg cmd "nm device connect <iface>")))
    (with-cli-errors
      (let ((ac (nm:activate-and-wait nil :device iface :client client :timeout 30)))
        (format t "connected ~A (~(~A~))~%" iface (nm:ac-state ac))))))

(defcmd device-connect
  :name "connect"
  :description "activate the best available connection on a device"
  :usage "<iface>"
  :handler #'device-connect/handler)

(defun device-disconnect/handler (cmd)
  (let ((client (ensure-client))
        (iface (require-arg cmd "nm device disconnect <iface>")))
    (with-cli-errors
      (nm:disconnect-device iface client)
      (format t "disconnected ~A~%" iface))))

(defcmd device-disconnect
  :name "disconnect"
  :description "disconnect a device"
  :usage "<iface>"
  :handler #'device-disconnect/handler)

(defcmd device
  :name "device"
  :description "list devices / show one (subcommands: connect, disconnect)"
  :aliases '("dev" "d")
  :usage "[IFACE ...]"
  :options (list (clingon:make-option
                  :flag :description "terse, colon-separated output"
                  :short-name #\t :long-name "terse" :key :terse)
                 (clingon:make-option
                  :flag :description "JSON output" :short-name #\j
                  :long-name "json" :key :json))
  :handler #'device/handler
  :sub-commands (list (device-connect/command) (device-disconnect/command)))

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
        (ssid (require-arg cmd "nm wifi connect SSID [--password PSK | --eap METHOD --identity ID --eap-password PW] [--ifname DEV] [--hidden]")))
    (with-cli-errors
      (let ((ac (nm:connect-wifi ssid
                                 :psk (clingon:getopt cmd :password)
                                 :eap (clingon:getopt cmd :eap)
                                 :identity (clingon:getopt cmd :identity)
                                 :eap-password (clingon:getopt cmd :eap-password)
                                 :device (clingon:getopt cmd :ifname)
                                 :hidden (clingon:getopt cmd :hidden)
                                 :client client)))
        (format t "connecting to ~A ... ~(~A~)~%" ssid (nm:ac-state ac))))))

(defcmd wifi-connect
  :name "connect"
  :description "connect to a Wi-Fi network (personal or enterprise)"
  :usage "SSID"
  :options (list (clingon:make-option
                  :string :description "WPA-PSK passphrase"
                  :short-name #\p :long-name "password" :key :password)
                 (clingon:make-option
                  :string :description "enterprise EAP method, e.g. peap, ttls"
                  :long-name "eap" :key :eap)
                 (clingon:make-option
                  :string :description "enterprise identity (username)"
                  :long-name "identity" :key :identity)
                 (clingon:make-option
                  :string :description "enterprise password"
                  :long-name "eap-password" :key :eap-password)
                 (clingon:make-option
                  :string :description "Wi-Fi interface to use"
                  :short-name #\i :long-name "ifname" :key :ifname)
                 (clingon:make-option
                  :flag :description "SSID is hidden (non-broadcast)"
                  :long-name "hidden" :key :hidden))
  :handler #'wifi-connect/handler)

(defun wifi-rescan/handler (cmd)
  (let* ((client (ensure-client))
         (dev (wifi-device client (clingon:getopt cmd :ifname))))
    (with-cli-errors
      (nm:request-scan dev)
      (format t "scan requested on ~A~%" (nm:device-interface dev)))))

(defcmd wifi-rescan
  :name "rescan"
  :description "request a Wi-Fi scan (results appear in 'wifi' shortly after)"
  :options (list (clingon:make-option
                  :string :description "Wi-Fi interface to scan"
                  :short-name #\i :long-name "ifname" :key :ifname))
  :handler #'wifi-rescan/handler)

(defcmd wifi
  :name "wifi"
  :description "list visible Wi-Fi access points (subcommands: connect, rescan)"
  :aliases '("w")
  :options (list (clingon:make-option
                  :string
                  :description "Wi-Fi interface to use (default: first found)"
                  :short-name #\i
                  :long-name "ifname"
                  :key :ifname))
  :handler #'wifi/handler
  :sub-commands (list (wifi-connect/command) (wifi-rescan/command)))

;;; ---------------------------------------------------------------------------
;;; connection

(defun connection/handler (cmd)
  (let ((client (ensure-client))
        (terse (clingon:getopt cmd :terse))
        (json (clingon:getopt cmd :json)))
    (cond
      (json
       (json (jarr (mapcar (lambda (ac)
                             (jobj (list (cons "name" (nm:ac-id ac))
                                         (cons "uuid" (nm:ac-uuid ac))
                                         (cons "type" (nm:ac-type ac))
                                         (cons "state" (kw (nm:ac-state ac)))
                                         (cons "default" (jbool (nm:ac-default-p ac))))))
                           (nm:active-connections client)))))
      (t
       (unless terse
         (format t "~34A ~16A ~10A ~A~%" "NAME" "TYPE" "STATE" "DEFAULT"))
       (dolist (ac (nm:active-connections client))
         (if terse
             (format t "~A:~A:~(~A~):~:[no~;yes~]~%"
                     (nm:ac-id ac) (nm:ac-type ac) (nm:ac-state ac) (nm:ac-default-p ac))
             (format t "~34A ~16A ~10A ~:[no~;yes~]~%"
                     (nm:ac-id ac) (nm:ac-type ac) (kw (nm:ac-state ac))
                     (nm:ac-default-p ac))))))))

(defun con-profiles/handler (cmd)
  (let ((client (ensure-client))
        (terse (clingon:getopt cmd :terse))
        (json (clingon:getopt cmd :json)))
    (cond
      (json
       (json (jarr (mapcar (lambda (p)
                             (jobj (list (cons "name" (nm:connection-id p))
                                         (cons "uuid" (nm:connection-uuid p))
                                         (cons "type" (nm:connection-type p))
                                         (cons "autoconnect" (jbool (nm:connection-autoconnect-p p))))))
                           (nm:connections client)))))
      (t
       (unless terse
         (format t "~34A ~38A ~16A ~A~%" "NAME" "UUID" "TYPE" "AUTOCONNECT"))
       (dolist (p (nm:connections client))
         (if terse
             (format t "~A:~A:~A:~:[no~;yes~]~%"
                     (nm:connection-id p) (nm:connection-uuid p)
                     (nm:connection-type p) (nm:connection-autoconnect-p p))
             (format t "~34A ~38A ~16A ~:[no~;yes~]~%"
                     (nm:connection-id p) (nm:connection-uuid p)
                     (nm:connection-type p) (nm:connection-autoconnect-p p))))))))

(defcmd con-profiles
  :name "profiles"
  :description "list saved connection profiles"
  :aliases '("list")
  :options (list (clingon:make-option
                  :flag :short-name #\t :long-name "terse" :key :terse
                  :description "terse output")
                 (clingon:make-option
                  :flag :short-name #\j :long-name "json" :key :json
                  :description "JSON output"))
  :handler #'con-profiles/handler)

(defun con-show/handler (cmd)
  (let* ((client (ensure-client))
         (name (require-arg cmd "nm connection show <id|uuid>"))
         (p (find-profile name client)))
    (unless p
      (format *error-output* "error: no such profile: ~A~%" name)
      (clingon:exit 1))
    (format t "~24A ~A~%" "connection.id:" (nm:connection-id p))
    (format t "~24A ~A~%" "connection.uuid:" (nm:connection-uuid p))
    (format t "~24A ~A~%" "connection.type:" (nm:connection-type p))
    (when (nm:connection-interface p)
      (format t "~24A ~A~%" "connection.interface:" (nm:connection-interface p)))
    (format t "~24A ~:[no~;yes~]~%" "connection.autoconnect:"
            (nm:connection-autoconnect-p p))
    (format t "~24A ~A~%" "dbus.path:" (nm:connection-path p))))

(defcmd con-show
  :name "show"
  :description "show a saved connection profile by id or uuid"
  :usage "<id|uuid>"
  :handler #'con-show/handler)

(defun con-add/handler (cmd)
  (let ((client (ensure-client))
        (type (or (clingon:getopt cmd :type)
                  (progn (format *error-output* "usage: nm connection add --type TYPE [options]~%")
                         (clingon:exit 1))))
        (name (clingon:getopt cmd :con-name))
        (ifname (clingon:getopt cmd :ifname)))
    (with-cli-errors
      (let ((conn
              (cond
                ((member type '("wifi" "802-11-wireless") :test #'string-equal)
                 (nm:make-wifi-connection
                  (or (clingon:getopt cmd :ssid)
                      (error "--ssid is required for a wifi connection"))
                  :psk (clingon:getopt cmd :password)
                  :eap (clingon:getopt cmd :eap)
                  :identity (clingon:getopt cmd :identity)
                  :eap-password (clingon:getopt cmd :eap-password)
                  :interface ifname))
                ((string-equal type "vlan")
                 (nm:make-vlan-connection
                  (or (clingon:getopt cmd :parent) (error "--parent is required for vlan"))
                  (parse-integer (or (clingon:getopt cmd :vlan-id)
                                     (error "--vlan-id is required for vlan")))
                  :id name))
                ((string-equal type "bridge")
                 (nm:make-bridge-connection (or ifname name (error "--ifname required"))))
                ((string-equal type "bond")
                 (nm:make-bond-connection (or ifname name (error "--ifname required"))
                                          :mode (or (clingon:getopt cmd :mode) "balance-rr")))
                (t                      ; ethernet / dummy / other scalar type
                 (let ((c (nm:make-connection :id (or name ifname type)
                                              :type type :interface ifname)))
                   (let ((addr (clingon:getopt cmd :address)))
                     (nm:add-ip4-setting c :method (or (clingon:getopt cmd :method)
                                                       (if addr "manual" "auto"))
                                           :addresses (when addr (list addr))
                                           :gateway (clingon:getopt cmd :gateway)
                                           :dns (when (clingon:getopt cmd :dns)
                                                  (list (clingon:getopt cmd :dns)))))
                   (nm:add-ip6-setting c :method "auto")
                   c)))))
        (let ((ac (clingon:getopt cmd :autoconnect)))
          (when ac
            (setf (nm:setting-property (nm:connection-setting conn) 'autoconnect)
                  (parse-bool ac))))
        (let ((prof (nm:add-connection conn :client client)))
          (format t "added ~A (~A)~%" (nm:connection-id prof) (nm:connection-uuid prof)))))))

(defcmd con-add
  :name "add"
  :description "add a saved connection profile (--type ethernet|wifi|vlan|bridge|bond|dummy)"
  :options (list (clingon:make-option :string :long-name "type" :key :type
                                      :description "connection type (required)")
                 (clingon:make-option :string :long-name "con-name" :key :con-name
                                      :description "profile name")
                 (clingon:make-option :string :long-name "ifname" :key :ifname
                                      :description "bound interface name")
                 (clingon:make-option :string :long-name "autoconnect" :key :autoconnect
                                      :description "yes/no")
                 (clingon:make-option :string :long-name "ssid" :key :ssid
                                      :description "Wi-Fi SSID")
                 (clingon:make-option :string :long-name "password" :key :password
                                      :description "Wi-Fi WPA-PSK passphrase")
                 (clingon:make-option :string :long-name "eap" :key :eap
                                      :description "enterprise EAP method")
                 (clingon:make-option :string :long-name "identity" :key :identity
                                      :description "enterprise identity")
                 (clingon:make-option :string :long-name "eap-password" :key :eap-password
                                      :description "enterprise password")
                 (clingon:make-option :string :long-name "parent" :key :parent
                                      :description "VLAN parent interface")
                 (clingon:make-option :string :long-name "vlan-id" :key :vlan-id
                                      :description "VLAN id")
                 (clingon:make-option :string :long-name "mode" :key :mode
                                      :description "bond mode")
                 (clingon:make-option :string :long-name "method" :key :method
                                      :description "ipv4 method (auto/manual/disabled)")
                 (clingon:make-option :string :long-name "address" :key :address
                                      :description "static IPv4 ADDR/PREFIX")
                 (clingon:make-option :string :long-name "gateway" :key :gateway
                                      :description "IPv4 gateway")
                 (clingon:make-option :string :long-name "dns" :key :dns
                                      :description "IPv4 DNS server"))
  :handler #'con-add/handler)

(defun con-modify/handler (cmd)
  (let* ((client (ensure-client))
         (args (clingon:command-arguments cmd))
         (name (first args)) (key (second args)) (value (third args)))
    (unless (and name key value)
      (format *error-output* "usage: nm connection modify <id> <setting.property> <value>~%")
      (clingon:exit 1))
    (with-cli-errors
      (let ((p (find-profile name client))
            (dot (position #\. key)))
        (unless p
          (format *error-output* "error: no such profile: ~A~%" name) (clingon:exit 1))
        (unless dot
          (format *error-output* "error: property must be SETTING.PROPERTY (e.g. ipv4.method)~%")
          (clingon:exit 1))
        (let* ((prefix (subseq key 0 dot))
               (prop (subseq key (1+ dot)))
               (setting (connection-setting-object p prefix)))
          (unless setting
            (format *error-output* "error: profile has no '~A' setting~%" prefix)
            (clingon:exit 1))
          (setf (gir:property setting prop) (coerce-setting-value value))
          (nm:update-connection p)
          (format t "modified ~A: ~A = ~A~%" (nm:connection-id p) key value))))))

(defcmd con-modify
  :name "modify"
  :description "set a property on a saved profile: modify <id> <setting.prop> <value>"
  :usage "<id|uuid> <setting.property> <value>"
  :handler #'con-modify/handler)

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
  :description "list active connections (subcommands: profiles, show, add, modify, up, down, delete)"
  :aliases '("con" "c")
  :options (list (clingon:make-option
                  :flag :description "terse, colon-separated output"
                  :short-name #\t :long-name "terse" :key :terse)
                 (clingon:make-option
                  :flag :description "JSON output" :short-name #\j
                  :long-name "json" :key :json))
  :handler #'connection/handler
  :sub-commands (list (con-profiles/command) (con-show/command)
                      (con-add/command) (con-modify/command)
                      (con-up/command) (con-down/command) (con-delete/command)))

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

(defun stamp ()
  "Current local time as HH:MM:SS."
  (multiple-value-bind (s m h) (decode-universal-time (get-universal-time))
    (format nil "~2,'0D:~2,'0D:~2,'0D" h m s)))

(defun emit (fmt &rest args)
  (format t "~A " (stamp))
  (apply #'format t fmt args)
  (terpri)
  (force-output))

(defun watch-device-state (device)
  (let ((iface (nm:device-interface device)))
    (nm:on-state-changed
     (lambda (new old reason)
       (declare (ignore old))
       (emit "= ~A ~(~A~) (~(~A~))" iface new reason))
     device)))

(defun monitor/handler (cmd)
  (declare (ignore cmd))
  (let ((client (ensure-client)))
    (nm:on-device-added
     (lambda (d)
       (emit "+ device ~A (~(~A~))" (nm:device-interface d) (nm:device-type d))
       (watch-device-state d)))          ; also follow the new device's state
    (nm:on-device-removed
     (lambda (d) (emit "- device ~A" (nm:device-interface d))))
    (nm:on-connectivity-changed
     (lambda (state) (emit "~~ connectivity ~(~A~)" state)))
    (dolist (d (nm:devices client)) (watch-device-state d))
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
  ;; Stop the shared event loop on the way out so a parked loop thread can't
  ;; delay process shutdown.
  (unwind-protect (clingon:run (toplevel))
    (ignore-errors (nm:stop-event-loop))))