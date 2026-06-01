;;; package.lisp
;;;
;;; SPDX-License-Identifier: MIT
;;;
;;; Copyright (C) 2026 Your Name

(defpackage #:nm
  (:use #:cl)
  (:documentation "Common Lisp bindings to libnm (NetworkManager) via
GObject Introspection.")
  (:export
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
   #:devices
   #:find-device
   #:active-connections
   #:primary-connection

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
   #:device-ip4-addresses
   #:device-ip4-gateway
   #:device-ip4-nameservers

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

   ;; active connections
   #:ac-id
   #:ac-uuid
   #:ac-type
   #:ac-state
   #:ac-default-p
   #:ac-default6-p

   ;; reporting
   #:summary
   #:print-summary
   #:main))

(in-package #:nm)