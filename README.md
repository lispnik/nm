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

Dependencies are managed with [ocicl](https://github.com/ocicl/ocicl);
run `ocicl install` in this directory to fetch `cl-gobject-introspection`.

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
  wifi, w             list visible Wi-Fi access points
  connection, con, c  list active connections

$ ./nm-cli device
DEVICE           TYPE       STATE          CONNECTION
eth0             ethernet   unavailable    --
wlan0            wifi       activated      MyNetwork

$ ./nm-cli device wlan0          # detailed view of one interface
$ ./nm-cli wifi                  # list access points (--ifname to pick a device)
$ ./nm-cli connection            # active connections
```

Without building an executable you can also run it via
`(asdf:load-system :nm/cli)` then `(nm.cli:main)`.

## API overview

- **Client:** `make-client`, `version`, `connectivity`, `check-connectivity`,
  `networking-enabled-p`, `wireless-enabled-p`, `devices`, `find-device`,
  `active-connections`, `primary-connection`
- **Devices:** `device-interface`, `device-type`, `device-state`,
  `device-driver`, `device-hw-address`, `device-mtu`, `device-managed-p`,
  `device-active-connection`, `device-ip4-addresses`, `device-ip4-gateway`,
  `device-ip4-nameservers`
- **Wi-Fi:** `wifi-device-p`, `access-points`, `active-access-point`,
  `request-scan`, `ap-ssid`, `ap-bssid`, `ap-strength`, `ap-frequency`,
  `ap-max-bitrate`, `ap-mode`
- **Active connections:** `ac-id`, `ac-uuid`, `ac-type`, `ac-state`,
  `ac-default-p`

## License

`nm` is distributed under the terms of the MIT license.