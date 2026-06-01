# nm

Common Lisp bindings to **libnm** (NetworkManager) for Linux, built on
[GObject Introspection](https://gitlab.gnome.org/GNOME/gobject-introspection)
via [`cl-gobject-introspection`](https://github.com/andy128k/cl-gobject-introspection).

The `NM-1.0` typelib is bound dynamically at runtime, so the binding tracks
whatever version of libnm is installed. This first version exposes a
**read-only** view of NetworkManager: devices, their state and IP
configuration, active connections, Wi-Fi access points, and connectivity.
It uses only synchronous calls, so no GLib main loop is required.

## Requirements

- SBCL
- Linux with **NetworkManager** running
- `libnm` and its introspection data (`gobject-introspection` plus the
  `NM-1.0.typelib`, usually shipped by the `libnm`/`NetworkManager`
  packages or a `gir1.2-nm-1.0` package)

Dependencies are managed with [ocicl](https://github.com/ocicl/ocicl).

> Note: the code *compiles* on any platform with gobject-introspection,
> but the API only *runs* on a host where NetworkManager is present.

## Usage

```lisp
(asdf:load-system :nm)

(nm:make-client)            ; connect to NetworkManager, cache as nm:*client*

(nm:version)                ; => "1.46.0"
(nm:connectivity)           ; => :FULL

(dolist (d (nm:devices))
  (format t "~a ~a ~a~%"
          (nm:device-interface d)
          (nm:device-type d)        ; :ETHERNET, :WIFI, ...
          (nm:device-state d)))     ; :ACTIVATED, :DISCONNECTED, ...

;; Wi-Fi access points visible to a wireless device
(let ((wlan (nm:find-device "wlan0")))
  (dolist (ap (nm:access-points wlan))
    (format t "~a  ~d%~%" (nm:ap-ssid ap) (nm:ap-strength ap))))
```

A ready-made overview is available:

```sh
sbcl --eval "(asdf:load-system :nm)" \
     --eval "(nm:main)" \
     --quit
```

`nm:main` prints a snapshot of all devices, their addresses, and nearby
Wi-Fi networks. `nm:summary` returns the same information as a plist.

## Command-line tool

The `nm/cli` system is a small, `nmcli`-like front end built with
[clingon](https://github.com/dnaeon/clingon) that exercises the binding.
Build a standalone executable with:

```sh
ocicl install
sbcl --eval "(asdf:make :nm/cli)" --quit   # produces ./nm-cli
```

```console
$ ./nm-cli --help
COMMANDS:
  general, g, status  show overall NetworkManager status
  device, dev, d      list network devices, or show one by interface name
  wifi, w             list visible Wi-Fi access points (subcommand: connect)
  connection, con, c  list active connections (subcommands: up, down, delete)
  networking          show or set global networking: networking [on|off]
  radio               show or set radios: radio [wifi|wwan] [on|off]
  monitor, mon        watch NetworkManager events until interrupted
```

Read-only:

```console
$ ./nm-cli device                # device table
$ ./nm-cli device wlan0          # detailed view of one interface
$ ./nm-cli wifi                  # list access points (--ifname to pick a device)
$ ./nm-cli connection            # active connections
```

Mutating / monitoring (these need root/PolicyKit):

```console
$ sudo ./nm-cli networking on            # or: off
$ sudo ./nm-cli radio wifi off           # radio wwan on, etc.
$ sudo ./nm-cli wifi connect MySSID --password hunter2
$ sudo ./nm-cli connection up   <id|uuid>   # activate (waits until activated)
$ sudo ./nm-cli connection down <id|uuid>   # deactivate
$ sudo ./nm-cli connection delete <id|uuid> # delete a saved profile
$ sudo ./nm-cli monitor                  # stream device/state/connectivity events
```

Without building an executable you can also run it via
`(asdf:load-system :nm/cli)` then `(nm.cli:main)`.

## API overview

- **Client:** `make-client`, `version`, `connectivity`, `check-connectivity`,
  `networking-enabled-p`, `wireless-enabled-p`, `devices`, `find-device`,
  `active-connections`, `primary-connection`
- **Devices:** `device-interface`, `device-type`, `device-state`,
  `device-driver`, `device-hw-address`, `device-mtu`, `device-managed-p`,
  `device-active-connection`
- **IP config (v4 & v6):** `device-ip4-addresses` / `device-ip6-addresses`,
  `device-ip4-gateway` / `device-ip6-gateway`,
  `device-ip4-nameservers` / `device-ip6-nameservers`; or work with an
  `NMIPConfig` directly via `device-ip4-config`/`device-ip6-config` and
  `ip-config-addresses`, `ip-config-gateway`, `ip-config-nameservers`,
  `ip-config-domains`
- **Wi-Fi:** `wifi-device-p`, `access-points`, `active-access-point`,
  `request-scan`, `ap-ssid`, `ap-bssid`, `ap-strength`, `ap-frequency`,
  `ap-max-bitrate`, `ap-mode`; security via `ap-security` (a summary list
  like `(:wpa2)`) plus the raw `ap-flags`, `ap-wpa-flags`, `ap-rsn-flags`
- **Active connections:** `ac-id`, `ac-uuid`, `ac-type`, `ac-state`,
  `ac-default-p`
- **Saved profiles:** `connections`, `find-connection`, `connection-id`,
  `connection-uuid`, `connection-type`, `connection-interface`,
  `connection-path`, `connection-autoconnect-p`
- **Errors:** failures signal `nm-error` (`nm-error-message`, `nm-error-cause`)
- **Control toggles (v2):** `set-networking-enabled`, `set-wireless-enabled`,
  `set-wwan-enabled`; `check-connectivity-async` (active re-check via the
  async core).
- **Activation (v2):** `activate` (a saved profile on a device; returns the
  resulting `NMActiveConnection`) and `deactivate`. Note `activate` returns
  once activation has *started* (the active connection may still be
  `:activating`); waiting for `:activated` needs event monitoring (a later
  phase).
- **Profiles (v2):** build with `make-connection` + `make-setting` /
  `add-setting` / `add-ip4-setting` / `add-ip6-setting` (scalar properties via
  `setting-property`), then `add-connection`; edit a saved profile's settings
  and `update-connection` to commit; `delete-connection` to remove. `generate-uuid`
  mints a UUID.
- **Wi-Fi connect (v2):** `connect-wifi` (`ssid` + optional `psk`, builds and
  activates a WPA-PSK profile); the generic `add-and-activate`; and the
  building blocks `make-wifi-connection`, `setting-set-ssid`, and
  `set-boxed-property` (sets boxed/`GBytes` GObject properties that
  `setting-property` cannot).
- **Monitoring (v2):** `start-event-loop` / `stop-event-loop` run a background
  GLib loop so signal handlers fire; subscribe with `on-device-added`,
  `on-device-removed`, `on-state-changed`, `on-connectivity-changed`, or the
  generic `watch-property` (`disconnect-handler` to remove). `activate-and-wait`
  activates and blocks until the connection reaches `:activated` (or fails).
- These mutate system state and typically require root/PolicyKit
  authorization — unprivileged calls signal `nm-error` (e.g. "Not authorized").

> **Object lifetime:** returned objects are `(transfer none)` snapshots owned
> by the `NMClient` cache. They are valid only while that client is alive and
> unchanged — read what you need promptly rather than stashing them.

## Tests

`nm/test` is a smoke test that asserts shape/type invariants against a live
NetworkManager (Linux only):

```sh
sbcl --eval "(asdf:load-system :nm/test)" --eval "(nm.test:run)" --quit
```

## License

`nm` is distributed under the terms of the MIT license.
