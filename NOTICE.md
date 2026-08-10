# NOTICE

`pins-image` as a whole is licensed under the **GNU Affero General Public License,
version 3** (see [`LICENSE`](LICENSE)).

## Portions derived from NINA.Polaris

Portions of this repository are derived from **NINA.Polaris**
(<https://github.com/DanWBR/NINA.Polaris>), licensed AGPL-3.0.
Copyright (C) the NINA.Polaris authors.

Upstream reference: branch `master`, retrieved 2026-08-10 from
`raw.githubusercontent.com/DanWBR/NINA.Polaris/master/`.

| File in this repository | Upstream source file | Nature of the change |
|---|---|---|
| `provision/install-pins-linux.sh` | `scripts/install-polaris-linux.sh` | Structure and text blocks only: error collection (`FAILED`/`banner`/`note_fail`/`apt_recover`), `fetch()`, the payload-ISO pattern, `install_deb()`, the brltty section. Everything else (PINS apt repo, pinsdaemon configuration, overlay rollout, first-boot units, sanitising, provision marker) is new. Downloads moved out of `/tmp` into `/var/tmp/pins-provision`. |
| `provision/overlay/usr/local/lib/pins/pins-growroot.sh` | `packaging/deb/opt/polaris/bin/polaris-growroot.sh` | Renamed polaris -> pins, marker moved to `/var/lib/pins/growroot.done`, dropped the legacy pre-deb marker paragraph. |
| `provision/overlay/usr/local/lib/pins/pins-sshkeys.sh` | `packaging/deb/opt/polaris/bin/polaris-sshkeys.sh` | Renamed polaris -> pins only. |
| `provision/overlay/usr/local/sbin/pins-install-to-disk` | `packaging/img/polaris-install-to-disk.sh` | Renamed polaris -> pins (partition labels, GRUB bootloader id, growroot marker), target mount moved from `/tmp` to `/mnt`, closing text points at the PINS URLs. |
| `provision/overlay/etc/systemd/system/pins-growroot.service` | `packaging/deb/lib/systemd/system/polaris-growroot.service` | Renamed polaris -> pins, `ExecStart` path adjusted, `Before=pins.service`. |
| `provision/overlay/etc/systemd/system/pins-sshkeys.service` | `packaging/deb/lib/systemd/system/polaris-sshkeys.service` | Renamed polaris -> pins, `ExecStart` path adjusted. Upstream's ordering-cycle comment kept verbatim in substance because the hazard is identical. |

Each derived file carries a header naming its upstream source, as required by
AGPL-3.0 section 5(a).

## Other components

- `pins-archive-keyring.gpg` (and its copy under
  `provision/overlay/usr/share/keyrings/`) is the public OpenPGP key of the PINS
  x64 apt repository, fingerprint `D1C76CE6281D2DB3E814B1C8B99C955E609B4889`.
  A public key is not a work of authorship in the copyright sense; it is shipped
  so that `apt` can verify the release signatures.
- The software this repository *installs* (PINS/N.I.N.A., pinsdaemon, INDI,
  PHD2, astrometry.net, ASTAP, the ASTAP star databases) is **not** part of this
  repository and keeps its own licence. Nothing here redistributes it; the
  provisioning script downloads it from the respective upstream sources at
  install time.
