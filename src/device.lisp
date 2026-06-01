;;; device.lisp
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Your Name
;;;
;;; Accessors for NMDevice (and the NMDeviceWifi subclass), NMIPConfig,
;;; NMAccessPoint and NMActiveConnection.  All read-only.

(in-package #:nm)

;;; ---------------------------------------------------------------------------
;;; NMDevice

(defun device-interface (device)
  "The kernel interface name of DEVICE, e.g. \"eth0\" or \"wlan0\"."
  (gir:invoke (device 'get-iface)))

(defun device-type (device)
  "The device type as a keyword, e.g. :ETHERNET, :WIFI, :BT, :WIREGUARD."
  (enum->keyword "DeviceType" (gir:invoke (device 'get-device-type))))

(defun device-state (device)
  "The device state as a keyword, e.g. :ACTIVATED, :DISCONNECTED, :UNAVAILABLE."
  (enum->keyword "DeviceState" (gir:invoke (device 'get-state))))

(defun device-state-reason (device)
  "The reason keyword for the device's current state."
  (enum->keyword "DeviceStateReason" (gir:invoke (device 'get-state-reason))))

(defun device-driver (device)
  (gir:invoke (device 'get-driver)))

(defun device-driver-version (device)
  (gir:invoke (device 'get-driver-version)))

(defun device-hw-address (device)
  "The hardware (MAC) address of DEVICE as a string, or NIL."
  (gir:invoke (device 'get-hw-address)))

(defun device-mtu (device)
  (gir:invoke (device 'get-mtu)))

(defun device-managed-p (device)
  (gir:invoke (device 'get-managed)))

(defun device-real-p (device)
  "True when DEVICE is a real device rather than a placeholder for a
not-yet-instantiated virtual device."
  (gir:invoke (device 'is-real)))

(defun device-available-p (device)
  "True when DEVICE is available to be activated."
  (gir:invoke (device 'is-available)))

(defun device-active-connection (device)
  "The NMActiveConnection currently on DEVICE, or NIL."
  (let ((ac (gir:invoke (device 'get-active-connection))))
    (unless (null-object-p ac) ac)))

;;; IPv4 configuration -------------------------------------------------------

;;; The IPv4 and IPv6 configs are both NMIPConfig instances, so a single
;;; set of unpackers serves both families.

(defun ip-config-addresses (cfg)
  "List of (ADDRESS . PREFIX) conses for NMIPConfig CFG, or NIL."
  (when cfg
    (loop for addr in (ptr-array-structs (gir:invoke (cfg 'get-addresses))
                                         "IPAddress")
          collect (cons (gir:invoke (addr 'get-address))
                        (gir:invoke (addr 'get-prefix))))))

(defun ip-config-gateway (cfg)
  (when cfg (gir:invoke (cfg 'get-gateway))))

(defun ip-config-nameservers (cfg)
  (when cfg (coerce (gir:invoke (cfg 'get-nameservers)) 'list)))

(defun ip-config-domains (cfg)
  (when cfg (coerce (gir:invoke (cfg 'get-domains)) 'list)))

(defun device-ip4-config (device)
  "The NMIPConfig for DEVICE's IPv4 configuration, or NIL."
  (let ((cfg (gir:invoke (device 'get-ip4-config))))
    (unless (null-object-p cfg) cfg)))

(defun device-ip6-config (device)
  "The NMIPConfig for DEVICE's IPv6 configuration, or NIL."
  (let ((cfg (gir:invoke (device 'get-ip6-config))))
    (unless (null-object-p cfg) cfg)))

(defun device-ip4-addresses (device)
  "List of (ADDRESS . PREFIX) conses for DEVICE's current IPv4 config,
e.g. ((\"192.168.1.42\" . 24)).  Empty when the device has no IPv4 config."
  (ip-config-addresses (device-ip4-config device)))

(defun device-ip4-gateway (device)
  "The IPv4 gateway string for DEVICE, or NIL."
  (ip-config-gateway (device-ip4-config device)))

(defun device-ip4-nameservers (device)
  "List of IPv4 nameserver address strings for DEVICE."
  (ip-config-nameservers (device-ip4-config device)))

(defun device-ip6-addresses (device)
  "List of (ADDRESS . PREFIX) conses for DEVICE's current IPv6 config."
  (ip-config-addresses (device-ip6-config device)))

(defun device-ip6-gateway (device)
  "The IPv6 gateway string for DEVICE, or NIL."
  (ip-config-gateway (device-ip6-config device)))

(defun device-ip6-nameservers (device)
  "List of IPv6 nameserver address strings for DEVICE."
  (ip-config-nameservers (device-ip6-config device)))

;;; ---------------------------------------------------------------------------
;;; Wi-Fi: NMDeviceWifi / NMAccessPoint

(defun wifi-device-p (device)
  "True when DEVICE is a Wi-Fi device."
  (eq (device-type device) :wifi))

(defun access-points (device)
  "List of NMAccessPoint objects currently visible to the Wi-Fi DEVICE.
The list reflects the most recent scan; call REQUEST-SCAN to refresh it."
  (ptr-array-objects (gir:invoke (device 'get-access-points))))

(defun active-access-point (device)
  "The access point the Wi-Fi DEVICE is associated with, or NIL."
  (let ((ap (gir:invoke (device 'get-active-access-point))))
    (unless (null-object-p ap) ap)))

(defun request-scan (device)
  "Ask the Wi-Fi DEVICE to (re)scan for access points.

This only requests a scan; results arrive asynchronously and become
visible via ACCESS-POINTS once the daemon has updated.  Returns T on a
successful request."
  (gir:invoke (device 'request-scan) nil))

(defun ap-ssid (ap)
  "The SSID of access point AP decoded to a string (best effort), or NIL
for a hidden network."
  (octets->string (gbytes->octets (gir:invoke (ap 'get-ssid)))))

(defun ap-bssid (ap)
  "The BSSID (MAC address) of access point AP as a string."
  (gir:invoke (ap 'get-bssid)))

(defun ap-strength (ap)
  "Signal strength of AP as a percentage 0-100."
  (gir:invoke (ap 'get-strength)))

(defun ap-frequency (ap)
  "Frequency of AP in MHz."
  (gir:invoke (ap 'get-frequency)))

(defun ap-max-bitrate (ap)
  "Maximum bitrate of AP in kbit/s."
  (gir:invoke (ap 'get-max-bitrate)))

(defun ap-mode (ap)
  "The 802.11 mode of AP as a keyword, e.g. :INFRA, :ADHOC, :AP, :MESH."
  (enum->keyword "80211Mode" (gir:invoke (ap 'get-mode))))

(defun ap-flags (ap)
  "General capability flags of AP as a list of keywords (e.g. :PRIVACY, :WPS)."
  (flags->keywords "80211ApFlags" (gir:invoke (ap 'get-flags))))

(defun ap-wpa-flags (ap)
  "WPA (legacy/RSN-independent) security flags of AP as a list of keywords."
  (flags->keywords "80211ApSecurityFlags" (gir:invoke (ap 'get-wpa-flags))))

(defun ap-rsn-flags (ap)
  "RSN (WPA2/WPA3) security flags of AP as a list of keywords."
  (flags->keywords "80211ApSecurityFlags" (gir:invoke (ap 'get-rsn-flags))))

(defun ap-security (ap)
  "A high-level summary of AP's security as a list of protocol keywords,
drawn from :OPEN :WEP :WPA :WPA2 :WPA3 :ENTERPRISE :OWE.

This mirrors how nmcli classifies access points: it inspects the AP's
privacy bit together with its WPA and RSN flag sets."
  (let* ((flags (ap-flags ap))
         (wpa (ap-wpa-flags ap))
         (rsn (ap-rsn-flags ap))
         (result '()))
    (flet ((either (k) (or (member k wpa) (member k rsn))))
      (when (and (null wpa) (null rsn))
        (push (if (member :privacy flags) :wep :open) result))
      (when wpa (push :wpa result))
      (when rsn (push (if (member :key-mgmt-sae rsn) :wpa3 :wpa2) result))
      (when (either :key-mgmt-802-1x) (push :enterprise result))
      (when (or (either :key-mgmt-owe) (either :key-mgmt-owe-tm))
        (push :owe result)))
    (nreverse result)))

;;; ---------------------------------------------------------------------------
;;; NMActiveConnection

(defun ac-id (ac)
  "Human-readable id of the active connection AC."
  (gir:invoke (ac 'get-id)))

(defun ac-uuid (ac)
  (gir:invoke (ac 'get-uuid)))

(defun ac-type (ac)
  "Connection type string, e.g. \"802-11-wireless\" or \"802-3-ethernet\"."
  (gir:invoke (ac 'get-connection-type)))

(defun ac-state (ac)
  "State of the active connection as a keyword, e.g. :ACTIVATED, :ACTIVATING."
  (enum->keyword "ActiveConnectionState" (gir:invoke (ac 'get-state))))

(defun ac-default-p (ac)
  "True when AC carries the default IPv4 route."
  (gir:invoke (ac 'get-default)))

(defun ac-default6-p (ac)
  "True when AC carries the default IPv6 route."
  (gir:invoke (ac 'get-default6)))