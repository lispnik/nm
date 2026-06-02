;;; connection.lisp

;;; The add/update/delete operations that push these to the daemon are async and
;;; live in async.lisp.

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

(defun make-connection (&key id type uuid (autoconnect :unset) interface
                             master slave-type)
  "Build and return a new in-memory NMSimpleConnection carrying an
NMSettingConnection.

TYPE is the connection type string (e.g. \"802-3-ethernet\", \"dummy\").
A UUID is generated when not supplied.  AUTOCONNECT is only set when given a
boolean (otherwise NetworkManager's default applies).  MASTER (a controller
interface or UUID) plus SLAVE-TYPE (e.g. \"bridge\", \"bond\") make this a port
of a controller.  The result is not yet saved -- pass it to ADD-CONNECTION."
  (let ((conn (gir:invoke ((namespace) "SimpleConnection" 'new)))
        (s-con (make-setting "SettingConnection")))
    (when id (setf (gir:property s-con 'id) id))
    (when type (setf (gir:property s-con 'type) type))
    (setf (gir:property s-con 'uuid) (or uuid (generate-uuid)))
    (when interface (setf (gir:property s-con 'interface-name) interface))
    (when master (setf (gir:property s-con 'master) master))
    (when slave-type (setf (gir:property s-con 'slave-type) slave-type))
    (unless (eq autoconnect :unset)
      (setf (gir:property s-con 'autoconnect) (and autoconnect t)))
    (add-setting conn s-con)
    conn))

(defun add-ip-address (setting family addr/prefix)
  "Parse the \"ADDR/PREFIX\" string and add it to an NMSettingIPConfig SETTING.
FAMILY is 2 for IPv4 (AF_INET) or 10 for IPv6 (AF_INET6)."
  (let* ((slash (position #\/ addr/prefix))
         (addr (if slash (subseq addr/prefix 0 slash) addr/prefix))
         (prefix (if slash (parse-integer addr/prefix :start (1+ slash))
                     (if (= family 2) 32 128))))
    (gir:invoke (setting 'add-address)
                (gir:invoke ((namespace) "IPAddress" 'new) family addr prefix))))

(defun add-ip-route (setting family route)
  "Add ROUTE -- a plist (:DEST d :PREFIX p :NEXT-HOP nh [:METRIC m]) -- to an
NMSettingIPConfig SETTING.  NEXT-HOP is required (on-link routes aren't
supported here); METRIC defaults to -1 (unset)."
  (gir:invoke (setting 'add-route)
              (gir:invoke ((namespace) "IPRoute" 'new)
                          family (getf route :dest) (getf route :prefix)
                          (getf route :next-hop) (or (getf route :metric) -1))))

(defun %populate-ip-setting (setting family method addresses gateway routes dns dns-search)
  (setf (gir:property setting 'method) method)
  (dolist (a addresses) (add-ip-address setting family a))
  (when gateway (setf (gir:property setting 'gateway) gateway))
  (dolist (r routes) (add-ip-route setting family r))
  (dolist (d dns) (gir:invoke (setting 'add-dns) d))
  (dolist (d dns-search) (gir:invoke (setting 'add-dns-search) d))
  setting)

(defun add-ip4-setting (connection &key (method "auto") addresses gateway
                                        routes dns dns-search)
  "Attach an NMSettingIP4Config to CONNECTION.

METHOD is \"auto\", \"manual\", \"disabled\", \"link-local\" or \"shared\".
ADDRESSES is a list of \"ADDR/PREFIX\" strings (use METHOD \"manual\");
GATEWAY an address string; ROUTES a list of (:DEST :PREFIX :NEXT-HOP [:METRIC])
plists; DNS a list of nameserver strings; DNS-SEARCH a list of search domains."
  (add-setting connection
               (%populate-ip-setting (make-setting "SettingIP4Config")
                                     2 method addresses gateway routes dns dns-search)))

(defun add-ip6-setting (connection &key (method "auto") addresses gateway
                                        routes dns dns-search)
  "Attach an NMSettingIP6Config to CONNECTION.

METHOD is \"auto\", \"manual\", \"disabled\", \"ignore\" or \"link-local\".
ADDRESSES/GATEWAY/ROUTES/DNS/DNS-SEARCH are as for ADD-IP4-SETTING."
  (add-setting connection
               (%populate-ip-setting (make-setting "SettingIP6Config")
                                     10 method addresses gateway routes dns dns-search)))

;;; The SSID is a GBytes property, which gir:property cannot set, so it goes
;;; through SET-BOXED-PROPERTY (see gvalue.lisp).

(defun setting-set-ssid (setting ssid)
  "Set the SSID (a string) on an NMSettingWireless SETTING.  The SSID is
encoded as UTF-8 octets wrapped in a GBytes."
  (let* ((octets (coerce (string->octets ssid) 'list))
         (bytes (gir:invoke ((glib-namespace) "Bytes" 'new) octets)))
    (set-boxed-property setting "ssid" (%g-bytes-get-type) (gir::this-of bytes))))

(defun make-wifi-connection (ssid &key psk hidden interface (key-mgmt "wpa-psk")
                                       eap identity eap-password
                                       (phase2-auth "mschapv2"))
  "Build (but do not activate) a Wi-Fi NMConnection for SSID.

Personal: pass PSK with KEY-MGMT \"wpa-psk\" (WPA/WPA2) or \"sae\" (WPA3).
Enterprise: pass EAP (e.g. \"peap\", \"ttls\") with IDENTITY and EAP-PASSWORD;
this uses key-mgmt \"wpa-eap\" and an 802.1x setting with PHASE2-AUTH.
HIDDEN marks the SSID as non-broadcast.  IPv4/IPv6 default to automatic.
Pass the result to ADD-AND-ACTIVATE (or use CONNECT-WIFI)."
  (let ((conn (make-connection :id ssid :type "802-11-wireless"
                               :interface interface))
        (s-wifi (make-setting "SettingWireless")))
    (setting-set-ssid s-wifi ssid)
    (when hidden (setf (gir:property s-wifi 'hidden) t))
    (add-setting conn s-wifi)
    (cond
      (eap
       (let ((s-sec (make-setting "SettingWirelessSecurity"))
             (s-8021x (make-setting "Setting8021x")))
         (setf (gir:property s-sec 'key-mgmt) "wpa-eap")
         (add-setting conn s-sec)
         (gir:invoke (s-8021x 'add-eap-method) eap)
         (when identity (setf (gir:property s-8021x 'identity) identity))
         (when eap-password (setf (gir:property s-8021x 'password) eap-password))
         (when phase2-auth (setf (gir:property s-8021x 'phase2-auth) phase2-auth))
         (add-setting conn s-8021x)))
      (psk
       (let ((s-sec (make-setting "SettingWirelessSecurity")))
         (setf (gir:property s-sec 'key-mgmt) key-mgmt)
         (setf (gir:property s-sec 'psk) psk)
         (add-setting conn s-sec))))
    (add-ip4-setting conn :method "auto")
    (add-ip6-setting conn :method "auto")
    conn))

;;; Other connection types: VLAN, bridge, bond, VPN

(defun make-vlan-connection (parent vlan-id &key id (method "auto"))
  "Build a VLAN NMConnection with VLAN-ID on PARENT (an interface name or
connection UUID).  Interface defaults to PARENT.VLAN-ID."
  (let* ((iface (format nil "~A.~A" parent vlan-id))
         (conn (make-connection :id (or id iface) :type "vlan" :interface iface))
         (s (make-setting "SettingVlan")))
    (setf (gir:property s 'parent) parent)
    (setf (gir:property s 'id) vlan-id)
    (add-setting conn s)
    (add-ip4-setting conn :method method)
    (add-ip6-setting conn :method "auto")
    conn))

(defun make-bridge-connection (interface &key id)
  "Build a bridge controller NMConnection named INTERFACE.  Add port
connections with MAKE-CONNECTION :master INTERFACE :slave-type \"bridge\"."
  (let ((conn (make-connection :id (or id interface) :type "bridge"
                               :interface interface)))
    (add-setting conn (make-setting "SettingBridge"))
    (add-ip4-setting conn :method "auto")
    (add-ip6-setting conn :method "auto")
    conn))

(defun make-bond-connection (interface &key id (mode "balance-rr"))
  "Build a bond controller NMConnection named INTERFACE with bonding MODE.
Add port connections with MAKE-CONNECTION :master INTERFACE :slave-type \"bond\"."
  (let ((conn (make-connection :id (or id interface) :type "bond"
                               :interface interface))
        (s (make-setting "SettingBond")))
    (gir:invoke (s 'add-option) "mode" mode)
    (add-setting conn s)
    (add-ip4-setting conn :method "auto")
    (add-ip6-setting conn :method "auto")
    conn))

(defun make-vpn-connection (service-type &key id data)
  "Build a VPN NMConnection for SERVICE-TYPE (e.g.
\"org.freedesktop.NetworkManager.openvpn\").  DATA is an alist of (KEY . VALUE)
string data items for the VPN plugin."
  (let ((conn (make-connection :id (or id service-type) :type "vpn"))
        (s (make-setting "SettingVpn")))
    (setf (gir:property s 'service-type) service-type)
    (loop for (k . v) in data do (gir:invoke (s 'add-data-item) k v))
    (add-setting conn s)
    conn))
