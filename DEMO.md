# nm — a tour

`nm` is a Common Lisp binding to **libnm** (NetworkManager), with a small
`nmcli`-like command-line tool (`nm-cli`) built on top of it.

Everything below is **real output**, captured by running on a Raspberry Pi 4
(aarch64 Debian, NetworkManager **1.52.1**). The library talks to NetworkManager
through GObject Introspection, dropping to raw CFFI / GDBus only where libnm's
client API has gaps (the async layer, boxed properties, and device statistics).

---

## Part 1 — The library

Load it and connect to the daemon:

```lisp
(asdf:load-system :nm)
(nm:make-client)            ; connects over D-Bus, caches as nm:*client*
```

The session below is in the `nm` package (so `version` means `nm:version`).

### Status

```lisp
nm> (version)
"1.52.1"

nm> (state)
:connected-global

nm> (connectivity)
:full

nm> (metered)
:guess-no

nm> (list (networking-enabled-p) (wireless-enabled-p) (wwan-enabled-p))
(t t t)

nm> (permission :enable-disable-network)
:yes
```

Enums come back as keywords; flags as keyword lists.

### Devices

```lisp
nm> (mapcar #'device-interface (devices))
("lo" "eth0" "wlan0" "p2p-dev-wlan0" "tailscale0")

nm> (let ((w (find-device "wlan0")))
      (list (device-type w) (device-state w) (device-driver w)
            (device-hw-address w) (device-mtu w)))
(:wifi :activated "brcmfmac" "DC:A6:32:D4:F4:69" 1500)

nm> (device-speed (find-device "eth0"))
1000

nm> (device-capabilities (find-device "wlan0"))
(:nm-supported :carrier-detect :is-software :sriov)
```

### IP configuration

```lisp
nm> (device-ip4-addresses (find-device "wlan0"))
(("192.168.50.151" . 24))

nm> (device-ip4-gateway (find-device "wlan0"))
"192.168.50.1"

nm> (device-ip4-nameservers (find-device "wlan0"))
("192.168.50.1")

nm> (device-ip4-routes (find-device "wlan0"))
((:dest "192.168.50.0" :prefix 24 :next-hop nil :metric 600)
 (:dest "0.0.0.0" :prefix 0 :next-hop "192.168.50.1" :metric 600))

nm> (device-ip6-addresses (find-device "wlan0"))
(("fe80::dea6:32ff:fed4:f469" . 64))
```

### DHCP lease

```lisp
nm> (subseq (device-dhcp4-options (find-device "wlan0")) 0 5)
(("dhcp_client_identifier" . "01:dc:a6:32:d4:f4:69")
 ("requested_domain_name_servers" . "1") ("requested_domain_name" . "1")
 ("requested_ntp_servers" . "1") ("dhcp_lease_time" . "86400"))
```

### Wi-Fi

Access points, with decoded security:

```lisp
nm> (loop for ap in (access-points (find-device "wlan0"))
          collect (list (ap-ssid ap) (ap-strength ap) (ap-frequency ap)
                        (ap-security ap)))
(("Example_5GHz" 57 5500 (:wpa2)))
```

### Active connections

```lisp
nm> (loop for ac in (active-connections)
          collect (list (ac-id ac) (ac-type ac) (ac-state ac) (ac-default-p ac)
                        (mapcar #'device-interface (ac-devices ac))))
(("lo" "loopback" :activated nil ("lo"))
 ("tailscale0" "tun" :activated nil ("tailscale0"))
 ("netplan-wlan0-Example_5GHz" "802-11-wireless" :activated t ("wlan0")))
```

### Saved profiles

```lisp
nm> (loop for p in (connections)
          collect (list (connection-id p) (connection-type p)
                        (connection-autoconnect-p p)))
(("netplan-eth0" "802-3-ethernet" t)
 ("netplan-wlan0-Example_5GHz" "802-11-wireless" t) ("lo" "loopback" nil)
 ("tailscale0" "tun" nil))
```

### Statistics (via GDBus)

libnm doesn't expose device statistics, so these go over the
`Device.Statistics` D-Bus interface directly. Enabling the counters sets a
refresh rate, which needs root:

```lisp
nm> (device-statistics (find-device "wlan0") :interval-ms 300)
(:tx 171038560 :rx 287931231)
```

(The raw D-Bus *reads* below work unprivileged; only the statistics *set*
requires root.)

### Raw D-Bus

For any NM feature libnm omits, typed property access marshals GVariants
to/from Lisp (scalars, arrays, and `a{sv}` dicts):

```lisp
nm> (dbus-get-property (device-path (find-device "wlan0"))
                       "org.freedesktop.NetworkManager.Device" "Mtu")
1500

nm> (length (dbus-get-all (device-path (find-device "wlan0"))
                          "org.freedesktop.NetworkManager.Device"))
32
```

### Build, activate, modify and delete a profile

The management half: construct an `NMConnection` from settings, add it, drive
activation to completion (blocking on the active connection's state signal),
edit it, and remove it — here on a throwaway `dummy` device:

```lisp
nm> (defparameter *prof*
      (let ((c (make-connection :id "clnm-demo" :type "dummy"
                                :interface "clnmdemo0" :autoconnect nil)))
        (add-ip4-setting c :method "manual" :addresses '("10.0.0.5/24")
                           :gateway "10.0.0.1"
                           :routes (list (list :dest "10.9.0.0" :prefix 16
                                               :next-hop "10.0.0.1"))
                           :dns '("1.1.1.1"))
        (add-ip6-setting c :method "ignore")
        (add-connection c)))

nm> (list (connection-id *prof*) (connection-uuid *prof*))
("clnm-demo" "9eb3634f-a846-4456-8fcc-ea48f0c6077f")

nm> (defparameter *ac* (activate-and-wait *prof* :timeout 10))
nm> (ac-state *ac*)
:activated

nm> (deactivate *ac*)
t

nm> (setf (setting-property (connection-setting *prof*) 'autoconnect) t)
nm> (update-connection *prof*)
t

nm> (delete-connection *prof*)
t
```

### Asynchronous events

Under the hood there is one shared GLib main loop on a background thread.
Signal handlers fire on that thread, and the blocking façades
(`activate-and-wait`, `add-and-activate`, …) ride on the same loop — so
monitoring and operations run concurrently, no extra plumbing.

This example makes the asynchrony visible: we subscribe to device events, start
the loop, then activate a dummy connection on the *main* thread. Watch the
callbacks fire on the loop thread *while* `add-and-activate` is still in flight —
it returns at `:activating`, and the remaining state transitions arrive
afterwards, asynchronously:

```lisp
;; callbacks here run on the event-loop thread
(nm:on-device-added
 (lambda (d)
   (format t "  [event] + device ~A~%" (nm:device-interface d))
   (nm:on-state-changed
    (lambda (new old reason)
      (declare (ignore old reason))
      (format t "  [event]   ~A -> ~(~A~)~%" (nm:device-interface d) new))
    d)))

(nm:start-event-loop)                       ; GLib main loop on a background thread

(let ((c (nm:make-connection :id "clnm-async" :type "dummy"
                             :interface "clnmasync0" :autoconnect nil)))
  (nm:add-ip4-setting c :method "disabled")
  (nm:add-ip6-setting c :method "ignore")
  (let ((ac (nm:add-and-activate c)))       ; main thread; returns once started
    (format t "main thread: returned -- state = ~(~A~)~%" (nm:ac-state ac))
    (sleep 1)                               ; events keep arriving meanwhile
    (format t "main thread: final state = ~(~A~)~%" (nm:ac-state ac))))
```

Output (the `[event]` lines come from the loop thread, interleaved with the
main thread's two lines):

```text
  [event] + device clnmasync0
  [event]   clnmasync0 -> unavailable
  [event]   clnmasync0 -> disconnected
  [event]   clnmasync0 -> prepare
  [event]   clnmasync0 -> config
  [event]   clnmasync0 -> ip-config
  [event]   clnmasync0 -> ip-check
main thread: returned -- state = activating
  [event]   clnmasync0 -> secondaries
  [event]   clnmasync0 -> activated
main thread: final state = activated
```

`activate-and-wait` is just this pattern packaged up: it blocks on the
`state-changed` signal until the connection reaches `:activated` (or fails).

---

## Part 2 — The `nm-cli` tool

Build a standalone executable:

```sh
ocicl install
sbcl --eval "(asdf:make :nm/cli)" --quit   # produces ./nm-cli
```

```console
$ nm-cli --help
NAME:
  nm - a small nmcli-like tool built on the nm libnm binding

COMMANDS:
  general, g, status  show overall NetworkManager status (subcommand: permissions)
  device, dev, d      list devices / show one (subcommands: connect, disconnect)
  wifi, w             list visible Wi-Fi access points (subcommands: connect, rescan)
  connection, con, c  list active connections (subcommands: profiles, show, add, modify, up,
                      down, delete)
  networking          show or set global networking: networking [on|off]
  radio               show or set radios: radio [wifi|wwan] [on|off]
  monitor, mon        watch NetworkManager events until interrupted
```

### Status

```console
$ nm-cli general
VERSION        1.52.1
STATE          connected-global
CONNECTIVITY   full
METERED        guess-no
NETWORKING     enabled
WIFI           enabled
WWAN           enabled

$ nm-cli general -j
{"version":"1.52.1","state":"connected-global","connectivity":"full","metered":"guess-no","networking":true,"wifi":true,"wwan":true}

$ nm-cli general permissions
enable-disable-network               yes
enable-disable-wifi                  yes
enable-disable-wwan                  yes
network-control                      yes
wifi-share-protected                 yes
wifi-share-open                      yes
settings-modify-system               yes
settings-modify-own                  yes
reload                               yes
```

### Devices

```console
$ nm-cli device
DEVICE           TYPE       STATE          CONNECTION
lo               loopback   activated      lo
eth0             ethernet   unavailable    --
wlan0            wifi       activated      netplan-wlan0-Example_5GHz
p2p-dev-wlan0    wifi-p2p   disconnected   --
tailscale0       tun        activated      tailscale0

$ nm-cli device --json
[{"device":"lo","type":"loopback","state":"activated","connection":"lo"},{"device":"eth0",...},{"device":"wlan0","type":"wifi","state":"activated","connection":"netplan-wlan0-Example_5GHz"},...]
```

Detail for one interface — addresses, routes, DNS, capabilities, speed, and
the full DHCP lease:

```console
$ nm-cli device wlan0
GENERAL.DEVICE:        wlan0
GENERAL.TYPE:          wifi
GENERAL.HWADDR:        DC:A6:32:D4:F4:69
GENERAL.STATE:         activated
GENERAL.DRIVER:        brcmfmac
GENERAL.MTU:           1500
GENERAL.CONNECTION:    netplan-wlan0-Example_5GHz
IP4.ADDRESS[1]:        192.168.50.151/24
IP4.GATEWAY:           192.168.50.1
IP4.DNS[1]:            192.168.50.1
IP6.ADDRESS[1]:        fe80::dea6:32ff:fed4:f469/64
IP4.ROUTE[1]:          192.168.50.0/24 metric 600
IP4.ROUTE[2]:          0.0.0.0/0 via 192.168.50.1 metric 600
IP6.ROUTE[1]:          fe80::/64 metric 256
CAPABILITIES:          nm-supported, carrier-detect, is-software, sriov
DHCP4.OPTION[1]:       host_name = rpi4
DHCP4.OPTION[2]:       ip_address = 192.168.50.151
DHCP4.OPTION[10]:      routers = 192.168.50.1
DHCP4.OPTION[11]:      dhcp_lease_time = 86400
DHCP4.OPTION[25]:      subnet_mask = 255.255.255.0
...                    (28 options)
```

### Wi-Fi

```console
$ nm-cli wifi
   SSID                             MODE     SECURITY       SIGNAL FREQ
*  Example_5GHz                     infra    wpa2             59%   5500 MHz

$ sudo nm-cli wifi rescan
scan requested on wlan0
```

Connecting (personal or enterprise):

```sh
sudo nm-cli wifi connect MySSID --password hunter2
sudo nm-cli wifi connect Corp --eap peap --identity alice --eap-password pw
```

### Connections

```console
$ nm-cli connection
NAME                               TYPE             STATE      DEFAULT
lo                                 loopback         activated  no
tailscale0                         tun              activated  no
netplan-wlan0-Example_5GHz         802-11-wireless  activated  yes

$ nm-cli connection profiles
NAME                               UUID                                   TYPE             AUTOCONNECT
netplan-eth0                       75a1216a-9d1a-30cd-8aca-ace5526ec021   802-3-ethernet   yes
netplan-wlan0-Example_5GHz         26804860-5331-32d2-b600-b82e1b07ec55   802-11-wireless  yes
lo                                 8c0e7442-5c59-4b44-89ea-d430906bb0f4   loopback         no
tailscale0                         8b5864ae-4c7c-448a-a206-976bbfd57210   tun              no
```

Create, inspect, edit and delete a profile:

```console
$ sudo nm-cli connection add --type dummy --con-name demo-eth --ifname demo0 \
       --method manual --address 10.0.0.5/24 --gateway 10.0.0.1 --dns 1.1.1.1
added demo-eth (0d92aefa-260d-4e32-8f8e-76dede42a32e)

$ sudo nm-cli connection show demo-eth
connection.id:           demo-eth
connection.uuid:         0d92aefa-260d-4e32-8f8e-76dede42a32e
connection.type:         dummy
connection.interface:    demo0
connection.autoconnect:  yes
dbus.path:               /org/freedesktop/NetworkManager/Settings/37

$ sudo nm-cli connection modify demo-eth connection.autoconnect no
modified demo-eth: connection.autoconnect = no

$ sudo nm-cli connection delete demo-eth
deleted demo-eth
```

`connection up|down <id>` activate/deactivate (waiting until settled), and
`connection add --type vlan|bridge|bond|wifi|ethernet` builds those types too.

### Toggles

```console
$ nm-cli networking
networking enabled

$ nm-cli radio
wifi enabled
wwan enabled
```

`sudo nm-cli networking off` / `radio wifi off` set them.

### Monitor

Stream live, timestamped events. Here a dummy device is added and removed
externally while `monitor` runs — note it follows the new device's full state
progression:

```console
$ sudo nm-cli monitor
monitoring NetworkManager events (Ctrl-C to stop) ...
11:34:36 + device demomon0 (dummy)
11:34:36 = demomon0 unavailable (now-managed)
11:34:36 = demomon0 disconnected (none)
11:34:36 = demomon0 prepare (none)
11:34:36 = demomon0 config (none)
11:34:36 = demomon0 ip-config (none)
11:34:36 = demomon0 ip-check (none)
11:34:36 = demomon0 secondaries (none)
11:34:36 = demomon0 activated (none)
11:34:38 = demomon0 deactivating (connection-removed)
11:34:38 = demomon0 disconnected (connection-removed)
11:34:38 - device demomon0
11:34:38 = demomon0 disconnected (unmanaged-link-not-init)
11:34:38 = demomon0 unmanaged (user-requested)
```

### Extras

- `-t`/`--terse` (colon-separated) and `-j`/`--json` on `general`, `device`,
  `connection`.
- Shell completions are built in: `nm-cli --bash-completions` /
  `nm-cli --zsh-completions`.

---

*All examples were run live against NetworkManager 1.52.1 on a Raspberry Pi 4.
Every mutating example operates on throwaway `dummy` devices and cleans up
after itself.*
