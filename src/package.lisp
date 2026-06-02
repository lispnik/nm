;;; package.lisp
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Matthew Kennedy

(defpackage #:nm
  (:use #:cl)
  (:documentation "Common Lisp bindings to libnm (NetworkManager) via
GObject Introspection.")
  (:export
   ;; conditions
   #:nm-error
   #:nm-error-message
   #:nm-error-cause

   ;; setup
   #:ensure-loaded
   #:namespace
   #:make-client
   #:*client*
   #:client

   ;; client-level queries
   #:version
   #:networking-enabled-p
   #:wireless-enabled-p
   #:wwan-enabled-p
   #:connectivity
   #:check-connectivity
   #:check-connectivity-async
   #:nm-running-p
   #:state
   #:metered
   #:permission

   ;; control toggles (v2 phase 1)
   #:set-networking-enabled
   #:set-wireless-enabled
   #:set-wwan-enabled

   ;; activation (v2 phase 2)
   #:activate
   #:deactivate
   #:disconnect-device

   ;; connection construction + management (v2 phase 3)
   #:make-connection
   #:make-setting
   #:setting-property
   #:add-setting
   #:add-ip4-setting
   #:add-ip6-setting
   #:add-ip-address
   #:add-ip-route
   #:make-vlan-connection
   #:make-bridge-connection
   #:make-bond-connection
   #:make-vpn-connection
   #:connection-setting
   #:generate-uuid
   #:add-connection
   #:update-connection
   #:delete-connection

   ;; wi-fi connect (v2 phase 4)
   #:set-boxed-property
   #:setting-set-ssid
   #:make-wifi-connection
   #:add-and-activate
   #:connect-wifi

   ;; monitoring + event loop (v2 phase 5)
   #:start-event-loop
   #:stop-event-loop
   #:event-loop-running-p
   #:on-device-added
   #:on-device-removed
   #:on-state-changed
   #:on-connectivity-changed
   #:watch-property
   #:disconnect-handler
   #:activate-and-wait
   #:devices
   #:find-device
   #:active-connections
   #:primary-connection

   ;; saved connection profiles
   #:connections
   #:find-connection
   #:connection-id
   #:connection-uuid
   #:connection-type
   #:connection-interface
   #:connection-path
   #:connection-autoconnect-p

   ;; devices
   #:device-interface
   #:device-type
   #:device-state
   #:device-state-reason
   #:device-driver
   #:device-driver-version
   #:device-hw-address
   #:device-mtu
   #:device-managed-p
   #:device-real-p
   #:device-active-connection
   #:device-available-p
   #:device-ip4-config
   #:device-ip4-addresses
   #:device-ip4-gateway
   #:device-ip4-nameservers
   #:device-ip6-config
   #:device-ip6-addresses
   #:device-ip6-gateway
   #:device-ip6-nameservers
   #:device-ip4-routes
   #:device-ip6-routes
   #:device-ip4-domains
   #:device-ip6-domains
   #:device-speed
   #:device-capabilities
   #:device-ports
   #:device-vlan-id
   #:device-vlan-parent
   #:device-dhcp4-config
   #:device-dhcp6-config
   #:device-dhcp4-options
   #:device-dhcp6-options
   #:dhcp-options
   #:device-path
   #:enable-statistics
   #:device-tx-bytes
   #:device-rx-bytes
   #:device-statistics

   ;; raw D-Bus property access (for NM features libnm omits)
   #:dbus-get-property
   #:dbus-set-property
   #:dbus-get-all
   #:dbus-call
   #:system-bus

   ;; ip config
   #:ip-config-addresses
   #:ip-config-gateway
   #:ip-config-nameservers
   #:ip-config-domains
   #:ip-config-routes

   ;; wi-fi
   #:wifi-device-p
   #:access-points
   #:active-access-point
   #:request-scan
   #:ap-ssid
   #:ap-bssid
   #:ap-strength
   #:ap-frequency
   #:ap-max-bitrate
   #:ap-mode
   #:ap-flags
   #:ap-wpa-flags
   #:ap-rsn-flags
   #:ap-security

   ;; active connections
   #:ac-id
   #:ac-uuid
   #:ac-type
   #:ac-state
   #:ac-default-p
   #:ac-default6-p
   #:ac-devices
   #:ac-connection
   #:ac-vpn-p
   #:ac-vpn-state
   #:ac-vpn-banner

   ;; reporting
   #:summary
   #:print-summary
   #:main))

(in-package #:nm)