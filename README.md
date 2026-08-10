# pins-image

Image-Build für die **PINS x64 Appliance**: ein flashbares Ubuntu-Server-24.04-LTS-Raw-Image
(amd64, headless) mit PINS, INDI (indi-full), PHD2 (Xvfb), ASTAP + D50 und astrometry.net.

Vorbild: [DanWBR/NINA.Polaris](https://github.com/DanWBR/NINA.Polaris) (`packaging/img/`) —
Ubuntu-Autoinstall in QEMU/OVMF erzeugt ein rohes `.img` (GPT, ESP + ext4-Root, UEFI).

## Status

Aufbauphase. Aktuell enthalten:

- `provision/install-pins-linux.sh` — das Provisioning-Rezept: macht aus einem frischen
  Ubuntu Server 24.04 eine PINS-Appliance. Dokumentierter Hand-Installer **und** Skript-Kern
  des späteren Image-Builds. Details: [`provision/README.md`](provision/README.md).
- `provision/overlay/` — alles, was zusätzlich ins Dateisystem gehört: First-Boot-Units
  (Root-FS vergrößern, SSH-Hostkeys erzeugen), Erstlogin-Wizard, Hotspot-Timer-Drop-in,
  `pins-install-to-disk` (USB → interne SSD).
- `pins-archive-keyring.gpg` — öffentlicher GPG-Schlüssel des PINS-x64-apt-Repos
  (Flat-Repo aus den GitHub-Release-Assets von
  [NeutraleNull/pins-x64](https://github.com/NeutraleNull/pins-x64)).
  Fingerprint: `D1C76CE6281D2DB3E814B1C8B99C955E609B4889`

Der Image-Build selbst (`build-img.sh`, Autoinstall-Seed, Payload-ISO) folgt.
Er läuft lokal (kein CI-Workflow); Ergebnisse werden separat veröffentlicht.

## Lizenz

AGPL-3.0, siehe [`LICENSE`](LICENSE). Teile sind von
[DanWBR/NINA.Polaris](https://github.com/DanWBR/NINA.Polaris) abgeleitet — Herkunft je Datei in
[`NOTICE.md`](NOTICE.md).

## apt-Quelle (Client-Konfiguration)

```bash
sudo install -m 0644 pins-archive-keyring.gpg /usr/share/keyrings/pins-archive-keyring.gpg
sudo tee /etc/apt/sources.list.d/pins.sources <<'SRC'
Types: deb
URIs: https://github.com/NeutraleNull/pins-x64/releases/latest/download
Suites: ./
Signed-By: /usr/share/keyrings/pins-archive-keyring.gpg
SRC
sudo apt-get update
```
