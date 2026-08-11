# provision — PINS x64 provisioning

`install-pins-linux.sh` turns a fresh **Ubuntu Server 24.04 LTS (noble, amd64,
headless)** into a PINS appliance. It is the single recipe behind both the
documented hand installation and the image build, so the two cannot drift apart.

## Hand installation

```bash
sudo apt-get install -y git
git clone https://github.com/NeutraleNull/pins-image.git
cd pins-image
sudo ./provision/install-pins-linux.sh
sudo reboot
```

Expect roughly 3–5 GB of downloads (`indi-full` alone pulls 136 packages, the
ASTAP D50 star database is 827 MiB) and a good half hour on a fast line.

**Warning:** the script switches the machine from `systemd-networkd` to
NetworkManager. On a machine you are logged into over the network, the SSH
session can drop when NetworkManager takes over after the reboot. Run it on the
console, or over a wired connection you can re-establish.

After the reboot the device is reachable over SSH as `pins`/`pins`; changing
the password is optional (`passwd`). Wi-Fi is configured through the
Touch-N-Stars app.

## What it configures

| Area | Result |
|---|---|
| Hostname | `pins`, and `/etc/pins/rig-name` is written **before** pinsdaemon is installed so its postinst cannot rename the host to `pins-<hex>` |
| Network | NetworkManager as the netplan renderer, `systemd-networkd` disabled |
| Wi-Fi | fallback hotspot `pinspot` (WPA2), shipped as `desired_mode=hotspot`, watchdog first run 20 s after boot |
| Astronomy | `indi-full`, PHD2 (+Xvfb, both disabled by default), astrometry.net + tycho2, ASTAP GUI/CLI + D50 |
| PINS | `pins`, the five plugins and `pinsdaemon` from the signed apt repository |
| First boot | root filesystem grows to the disk, SSH host keys are generated |
| First login | plain shell; default credentials stay until changed by the user |
| Hardware | suspend masked, brltty masked (it steals the CH340 serial bridge), persistent journal |

## Knobs

All settings are environment variables; the image build sets them as a preamble.

| Variable | Default | Effect |
|---|---|---|
| `PINS_SETUP_MODE` | `appliance` | `appliance` or `addon` (`addon` skips sections 2, 3, 8 and 9 — prepared, not tested) |
| `PINS_USER` | `pins` | device user |
| `TARGET_HOSTNAME` | `pins` | hostname **and** `/etc/pins/rig-name` |
| `PINS_HOTSPOT_SSID` | `pinspot` | SSID of the fallback AP |
| `PINS_HOTSPOT_SECURITY` | `wpa-psk` | only `wpa-psk` is supported by the shipped `wifi-connect.sh` |
| `PINS_HOTSPOT_PASSWORD` | *(empty)* | 8–63 characters; empty means the daemon default from the flashing instructions |
| `PINS_REPO_OWNER` | `NeutraleNull` | GitHub owner of `pins-x64` |
| `PINS_APT_URI` | `https://github.com/<owner>/pins-x64/releases/latest/download` | apt source |
| `PINS_IMAGE_REPO` | `NeutraleNull/pins-image` | fallback download of the overlay |
| `PINS_ENABLE_PHD2` | `0` | `1` enables `phd2.service` and `xvfb.service` |
| `PINS_SKIP_SANITIZE` | `0` | `1` skips section 9; set automatically on a live system |

## Exit codes and the report file

* `0` — done. Non-fatal problems are listed in the closing summary and can be
  fixed by simply running the script again.
* `1` — the `pins` package is not installed. That is the only fatal case.
* `2` — bad arguments, wrong architecture.

Either way the script writes a machine-readable report, at
`/boot/efi/pins-provision-ok` when an ESP is mounted and at
`/var/lib/pins/provision-report` otherwise:

```
PINS_PROVISION_STATUS=ok        # "failed" when CRITICAL is not empty
PINS_PROVISION_MODE=appliance
PINS_PROVISION_DATE=2026-08-10T18:00:00Z
CRITICAL=                       # pins and/or pinsdaemon, when not installed cleanly
FAILED=                         # comma separated list of non-fatal problems
```

## overlay/

Everything under `overlay/` is copied to `/` verbatim (payload tarball → git
checkout → repository tarball, in that order), after which the script re-applies
the file modes git cannot record:

| Path | Mode |
|---|---|
| `/usr/local/sbin/pins-install-to-disk` | 0755 |
| `/usr/local/lib/pins/pins-growroot.sh`, `pins-sshkeys.sh` | 0755 |
| `/usr/share/keyrings/pins-archive-keyring.gpg` | 0644 |

## Re-running

The script is idempotent — a second run is expected to end with exit code 0 and
no new failures. That is also how a partly failed run is repaired: fix the
network, run it again.

## Not part of this directory

The image build itself (`build-img.sh`, the autoinstall seed, the payload ISO)
lives elsewhere in this repository and consumes this script by embedding it.
