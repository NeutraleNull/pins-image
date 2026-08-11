#!/bin/bash
# Derived from NINA.Polaris scripts/install-polaris-linux.sh (AGPL-3.0).
# Upstream: https://github.com/DanWBR/NINA.Polaris
# Changes: structure and text blocks only (FAILED/banner/note_fail/apt_recover,
#          fetch(), payload-ISO pattern, install_deb(), brltty section);
#          everything else is new. See NOTICE.md for the full provenance table.
# =============================================================================
# PINS x64 - Linux provisioning
# =============================================================================
# Turns a fresh Ubuntu Server 24.04 (noble, amd64, headless) into a PINS
# appliance, and is the SAME recipe the bare-metal image is built from: the
# image build embeds this file into the autoinstall late-command. One recipe, so
# the documented hand installation and the shipped image cannot drift apart.
#
#   sudo ./install-pins-linux.sh
#
# What it installs around the PINS package itself:
#
#   - NetworkManager as the netplan renderer (pinsdaemon's Wi-Fi handling
#     requires it; Ubuntu Server ships systemd-networkd)
#   - INDI (indi-full) and PHD2 from their PPAs, astrometry.net + tycho2
#   - ASTAP (GUI + CLI) and the D50 star database
#   - the PINS stack from our signed apt repository: pins, the plugins,
#     pinsdaemon
#   - first-boot units (grow root, generate SSH host keys) from
#     provision/overlay
#
# There is no first-login wizard and no forced password change (E14): the
# default credentials pins/pins stay valid, changing the password is voluntary
# (`passwd`), and the device is configured through the Touch'N'Stars app.
#
# Modes (PINS_SETUP_MODE, or --appliance / --addon):
#
#   appliance (default)  A machine dedicated to PINS. Also sets the hostname,
#                        switches to NetworkManager, masks suspend and
#                        ModemManager, and shadows gpsd's hotplug rules.
#   addon                Someone's existing machine. Installs the software;
#                        only intervention: masks brltty, ships the
#                        ModemManager ignore rule and disables the daemon's
#                        automatic Wi-Fi fallback.
#
# Knobs, all overridable from the environment:
#   PINS_SETUP_MODE        appliance | addon              (appliance)
#   PINS_USER              device user                    (pins)
#                          (only affects account creation; phd2.service and
#                          the pins deb hardcode pins)
#   TARGET_HOSTNAME        hostname AND /etc/pins/rig-name (pins)
#   PINS_HOTSPOT_SSID      SSID of the fallback AP        (pinspot)
#   PINS_HOTSPOT_SECURITY  wpa-psk (only value supported) (wpa-psk)
#   PINS_HOTSPOT_PASSWORD  8-63 chars, empty = daemon default (empty)
#   PINS_REPO_OWNER        GitHub owner of pins-x64       (NeutraleNull)
#   PINS_APT_URI           apt source URI                 (<owner>/pins-x64 releases)
#   PINS_IMAGE_REPO        overlay fallback download      (NeutraleNull/pins-image)
#   PINS_OVERLAY_REF       branch/tag/SHA for the overlay fallback (main)
#   PINS_ENABLE_PHD2       0 = opt out of phd2 + xvfb     (1)
#   PINS_SKIP_SANITIZE     1 = skip section 9             (0, auto 1 on a live system)
#
# Robustness rules, each of them learned the hard way:
#   * NOT 'set -e'. An optional component must not destroy an hour-long image
#     build. Failures are collected and summarised; apt state is repaired after
#     every failure so one bad package cannot cascade. Only a missing 'pins'
#     package fails the whole run.
#   * Runs inside a chroot during the image build: 'systemctl enable' and
#     masking work (they are file operations), 'start'/'restart'/'daemon-reload'
#     are silently ignored. Nothing here may depend on a service actually
#     starting, and every mask is backed by an explicit /dev/null symlink -
#     a mask hidden behind an "is systemd running?" guard is lost in a chroot.
#   * Downloads force IPv4: QEMU's slirp networking black-holes IPv6 to GitHub,
#     Fastly and SourceForge, which looks like a connect timeout.
#   * Large downloads go to /var/tmp, never to /tmp - that is a RAM tmpfs on
#     small machines.
#   * Idempotent by construction: running it twice in a row must be clean.
#   * astrometry-data-2mass is deliberately avoided: it downloads at dpkg
#     configure time and an interrupted fetch leaves dpkg unrecoverable. tycho2
#     ships its data inside the package.
# =============================================================================
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive

# ---------------------------------------------------------------------------
# Knobs
# ---------------------------------------------------------------------------
PINS_SETUP_MODE="${PINS_SETUP_MODE:-appliance}"
PINS_USER="${PINS_USER:-pins}"
TARGET_HOSTNAME="${TARGET_HOSTNAME:-pins}"
PINS_HOTSPOT_SSID="${PINS_HOTSPOT_SSID:-pinspot}"
PINS_HOTSPOT_SECURITY="${PINS_HOTSPOT_SECURITY:-wpa-psk}"
PINS_HOTSPOT_PASSWORD="${PINS_HOTSPOT_PASSWORD:-}"
PINS_REPO_OWNER="${PINS_REPO_OWNER:-NeutraleNull}"
PINS_APT_URI="${PINS_APT_URI:-https://github.com/${PINS_REPO_OWNER}/pins-x64/releases/latest/download}"
PINS_IMAGE_REPO="${PINS_IMAGE_REPO:-NeutraleNull/pins-image}"
PINS_OVERLAY_REF="${PINS_OVERLAY_REF:-main}"
PINS_ENABLE_PHD2="${PINS_ENABLE_PHD2:-1}"
# Remember whether the caller SET this, not just what it says: on a live system
# the default flips to 1 (see below), and only an explicit assignment may
# override that. Without the distinction the sanitising could never be
# exercised outside a chroot, not even in a disposable test VM.
PINS_SANITIZE_EXPLICIT=0
[ -n "${PINS_SKIP_SANITIZE+x}" ] && PINS_SANITIZE_EXPLICIT=1
PINS_SKIP_SANITIZE="${PINS_SKIP_SANITIZE:-0}"

for arg in "$@"; do
    case "$arg" in
        --appliance) PINS_SETUP_MODE=appliance ;;
        --addon)     PINS_SETUP_MODE=addon ;;
        -h|--help)   sed -n '2,76p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "unknown option: $arg (try --help)" >&2; exit 2 ;;
    esac
done
case "$PINS_SETUP_MODE" in
    appliance|addon) ;;
    *) echo "PINS_SETUP_MODE must be 'appliance' or 'addon'" >&2; exit 2 ;;
esac

if [ "$(id -u)" -ne 0 ]; then
    echo "This installer needs root: re-run with sudo." >&2
    exit 1
fi

DEB_ARCH="$(dpkg --print-architecture 2>/dev/null || echo unknown)"
if [ "$DEB_ARCH" != "amd64" ]; then
    echo "PINS x64 is an amd64 build; this machine reports '$DEB_ARCH'." >&2
    exit 2
fi

# Only wpa-psk is implemented by the wifi-connect.sh that ships with pinsdaemon
# (it sets wifi-sec.key-mgmt unconditionally). The knob exists so the image
# build can carry the intent; an open AP would need a daemon patch first.
if [ "$PINS_HOTSPOT_SECURITY" != "wpa-psk" ]; then
    echo "[WARN] PINS_HOTSPOT_SECURITY='$PINS_HOTSPOT_SECURITY' is not supported by the" >&2
    echo "       shipped wifi-connect.sh - falling back to wpa-psk." >&2
    PINS_HOTSPOT_SECURITY=wpa-psk
fi
if [ -n "$PINS_HOTSPOT_PASSWORD" ] &&
   { [ "${#PINS_HOTSPOT_PASSWORD}" -lt 8 ] || [ "${#PINS_HOTSPOT_PASSWORD}" -gt 63 ]; }; then
    echo "[WARN] PINS_HOTSPOT_PASSWORD must be 8-63 characters (WPA2) - ignoring it," >&2
    echo "       the daemon default applies instead." >&2
    PINS_HOTSPOT_PASSWORD=""
fi

# "Is there a running systemd?" - i.e. are we on a live machine or in the image
# build's chroot? Emptying the machine-id and deleting the SSH host keys of a
# running system would be destructive, so section 9 turns itself off there.
LIVE_SYSTEM=0
[ -d /run/systemd/system ] && LIVE_SYSTEM=1
if [ "$LIVE_SYSTEM" = "1" ] && [ "$PINS_SANITIZE_EXPLICIT" = "0" ]; then
    PINS_SKIP_SANITIZE=1
    echo "[INFO] Running on a live system - skipping the image sanitising (section 9)."
    echo "       Set PINS_SKIP_SANITIZE=0 explicitly if you really mean to sanitise this host."
fi

SCRIPT_DIR=""
if [ -n "${0:-}" ] && [ -d "$(dirname "$0")" ]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
FAILED=()
CRITICAL=()
banner()    { printf '\n\033[36m==> %s\033[0m\n' "$*"; }
note_fail() { FAILED+=("$1"); printf '\033[31m[FAIL]\033[0m %s\n' "$1"; }
note_crit() { CRITICAL+=("$1"); printf '\033[31m[CRIT]\033[0m %s\n' "$1"; }
apt_recover() { dpkg --configure -a >/dev/null 2>&1 || true
                apt-get -f install -y >/dev/null 2>&1 || true; }

# fetch URL OUT - IPv4 forced, five attempts, result must be non-empty.
fetch() {
    local url="$1" out="$2" i
    for i in 1 2 3 4 5; do
        if wget -4 --tries=2 --timeout=90 --retry-connrefused -O "$out" "$url" && [ -s "$out" ]; then
            return 0
        fi
        echo "  retry $i/5 for $url"; sleep 5
    done
    return 1
}

apt_try() { apt-get install -y "$@" || { note_fail "apt install $*"; apt_recover; }; }

# Work area for downloads. NOT below /tmp: that is a RAM-backed tmpfs on the
# machines this targets, and the D50 star database alone is 827 MiB.
WORKDIR=/var/tmp/pins-provision
install -d -m 0755 "$WORKDIR"

# A .deb that unpacked but failed its postinst leaves dpkg at "iF" while
# apt-get still exits 0. Every critical package is verified explicitly.
deb_installed_ok() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q '^install ok installed$'; }

in_list() {
    local needle="$1"; shift
    local x
    for x in "$@"; do [ "$x" = "$needle" ] && return 0; done
    return 1
}

# ---------------------------------------------------------------------------
# Optional payload (debs pre-fetched on the build host, attached as an ISO)
# ---------------------------------------------------------------------------
PAYLOAD=""
for d in /dev/sr0 /dev/sr1 /dev/sr2 /dev/sr3 /dev/vdb /dev/vdc; do
    [ -b "$d" ] || continue
    if blkid "$d" 2>/dev/null | grep -q 'LABEL="PINS"'; then
        mkdir -p /mnt/payload
        if mount -o ro "$d" /mnt/payload 2>/dev/null; then PAYLOAD=/mnt/payload; break; fi
    fi
done
[ -n "$PAYLOAD" ] && echo "Using local payload at $PAYLOAD ($(ls "$PAYLOAD"))" \
                  || echo "No local payload found - everything will be downloaded."

# install_deb PAYLOADNAME URL DESC - payload first, download second.
install_deb() {
    local name="$1" url="$2" desc="$3" f
    if [ -n "$PAYLOAD" ] && [ -s "$PAYLOAD/$name" ]; then
        f="$PAYLOAD/$name"
    else
        f="$WORKDIR/$name"
        fetch "$url" "$f" || { note_fail "download $desc"; return 1; }
    fi
    apt-get install -y "$f" || { note_fail "install $desc"; apt_recover; return 1; }
    return 0
}

echo "PINS provisioning: mode=$PINS_SETUP_MODE user=$PINS_USER hostname=$TARGET_HOSTNAME arch=$DEB_ARCH"

# ---------------------------------------------------------------------------
# 1. Base tools
# ---------------------------------------------------------------------------
banner "Base tools"
apt-get update || note_fail "apt update (base)"
apt_try software-properties-common wget ca-certificates curl gnupg unzip \
        cloud-guest-utils gdisk rsync dosfstools parted grub-efi-amd64-bin

# ---------------------------------------------------------------------------
# 1b. Serial-port protection (runs in BOTH modes)
# ---------------------------------------------------------------------------
# Astronomy gear hangs off USB-serial bridges (CH340, CP210x, FTDI, PL2303),
# and three stock daemons fight the operator for exactly those ports: brltty,
# ModemManager and gpsd. Everything here is chroot-safe - file operations plus
# best-effort systemctl (enable/mask are file operations too).
banner "Serial-port protection"

# brltty. The braille daemon claims the CH340 USB-serial bridge (1a86:7523)
# that focusers, mounts and filter wheels use, and takes the port away about a
# tenth of a second after the kernel created it. The operator simply sees no
# serial port. BOTH halves are needed: masking only the udev rule is not enough
# because a running daemon still finds the device through libusb.
#
# The shadow file is written unconditionally: Ubuntu Server never preinstalls
# brltty, so a "only if the package rule exists" guard would never fire there,
# while desktops (the --addon case) are exactly where brltty is real. An inert
# comment file costs nothing and protects against a later installation.
#
# The symlink half deliberately sits OUTSIDE any "is systemd running?" guard -
# in the image build's chroot there is no /run/systemd/system, and that is
# exactly how the upstream project lost this mask in its first attempt.
install -d -m 0755 /etc/udev/rules.d
cat > /etc/udev/rules.d/85-brltty.rules <<'EOF'
# Installed by PINS. brltty claims the USB-serial bridges astronomy gear uses
# (CH340, 1a86:7523 above all) and takes the port away right after the kernel
# creates it. Same filename under /etc shadows the one in /usr/lib entirely.
EOF
for unit in brltty-udev.service brltty.service; do
    systemctl mask "$unit" >/dev/null 2>&1 || true
    [ -e "/etc/systemd/system/$unit" ] || ln -sf /dev/null "/etc/systemd/system/$unit"
done

# ModemManager, appliance only. It arrives as a Recommends of network-manager
# and probes ttyUSB/ttyACM ports on hotplug - the CH340-based OnStep mount is
# the practical victim. The mask also covers a LATER installation: apt and
# deb-systemd-helper respect an existing mask, the package still installs fine.
# In --addon mode ModemManager may be driving a real WWAN modem, so there it
# only gets the ignore rule below.
if [ "$PINS_SETUP_MODE" = appliance ]; then
    systemctl mask ModemManager.service >/dev/null 2>&1 || true
    [ -e /etc/systemd/system/ModemManager.service ] \
        || ln -sf /dev/null /etc/systemd/system/ModemManager.service
fi

# Both modes: keep ModemManager away from the astro-typical USB-serial bridges
# even where the daemon itself must stay usable. Prefix 77- so the rule is
# evaluated before ModemManager's own 80-mm-*.rules.
cat > /etc/udev/rules.d/77-pins-serial-ignore.rules <<'EOF'
# Installed by PINS. Keep ModemManager away from the USB-serial bridges
# astronomy gear uses, even where ModemManager itself must stay usable.
ACTION!="add|change", GOTO="pins_mm_ignore_end"
SUBSYSTEM!="usb", GOTO="pins_mm_ignore_end"
ATTRS{idVendor}=="1a86", ATTRS{idProduct}=="7523", ENV{ID_MM_DEVICE_IGNORE}="1"
ATTRS{idVendor}=="10c4", ATTRS{idProduct}=="ea60", ENV{ID_MM_DEVICE_IGNORE}="1"
ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6001", ENV{ID_MM_DEVICE_IGNORE}="1"
ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6015", ENV{ID_MM_DEVICE_IGNORE}="1"
ATTRS{idVendor}=="067b", ATTRS{idProduct}=="2303", ENV{ID_MM_DEVICE_IGNORE}="1"
LABEL="pins_mm_ignore_end"
EOF
chmod 0644 /etc/udev/rules.d/77-pins-serial-ignore.rules /etc/udev/rules.d/85-brltty.rules

# gpsd, appliance only (indi-full -> indi-gpsd -> gpsd). Its hotplug rules
# grab FTDI/PL2303/CP210x for `gpsdctl add`. Shadowed unconditionally, same
# filename trick as brltty; gpsd itself stays installed and a manually
# configured GPS in /etc/default/gpsd (DEVICES=...) keeps working - only the
# automatic port grabbing goes away. 60-gpsd.rules is the packaged filename on
# noble (verified: dpkg -L gpsd -> /usr/lib/udev/rules.d/60-gpsd.rules); the
# shadow only works when the name matches exactly.
if [ "$PINS_SETUP_MODE" = appliance ]; then
    cat > /etc/udev/rules.d/60-gpsd.rules <<'EOF'
# Installed by PINS. gpsd's hotplug rules grab FTDI/PL2303/CP210x for gpsdctl;
# a manually configured GPS in /etc/default/gpsd keeps working.
EOF
    chmod 0644 /etc/udev/rules.d/60-gpsd.rules
fi

# ---------------------------------------------------------------------------
# 2. Local configuration (no network needed, so it comes first)
# ---------------------------------------------------------------------------
if [ "$PINS_SETUP_MODE" = appliance ]; then

banner "User, home directories, hostname, suspend, journal"

# 2a. user + groups. The image build's autoinstall creates the user; a hand
# installation may not have one yet.
if ! id "$PINS_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$PINS_USER" || note_fail "useradd $PINS_USER"
fi
for grp in sudo dialout video plugdev; do
    getent group "$grp" >/dev/null 2>&1 && usermod -aG "$grp" "$PINS_USER"
done

# 2b. home directories. .NET's Environment.GetFolderPath(LocalApplicationData)
# returns an EMPTY string when ~/.local/share does not exist; PINS then resolves
# its certificate/profile/log paths relative to /opt/pins and crash-loops. The
# pins postinst creates these too - deliberately duplicated, because a hand
# installation in a different order would otherwise leave a gap.
PHOME="$(getent passwd "$PINS_USER" | cut -d: -f6)"; PHOME="${PHOME:-/home/$PINS_USER}"
install -d -o "$PINS_USER" -g "$PINS_USER" \
    "$PHOME/.local" "$PHOME/.local/share" \
    "$PHOME/.local/share/NINA" "$PHOME/.local/share/NINA/Plugins" \
    "$PHOME/.local/share/NINA/Plugins/3.0.0" "$PHOME/.config" \
    || note_fail "home directories for $PINS_USER"

# 2c. hostname + rig name. This MUST happen before the pinsdaemon package is
# installed: its postinst calls `pins-rig-name --ensure`, and with neither
# $PINS_RIG_ID nor /etc/pins/rig-name present that invents `pins-<5 hex of the
# machine-id>` and renames the host to it. A QA image really did end up as
# "pins-7f87f", which breaks the promised pins.local.
install -d -m 0755 /etc/pins
printf '%s\n' "$TARGET_HOSTNAME" > /etc/pins/rig-name
chmod 0644 /etc/pins/rig-name
hostnamectl set-hostname "$TARGET_HOSTNAME" >/dev/null 2>&1 || true
# Written unconditionally, not only as a fallback: hostnamectl is a no-op in a
# chroot (no bus) and systemd-hostnamed can refuse the write for reasons of its
# own, and the static name is what the next boot reads.
printf '%s\n' "$TARGET_HOSTNAME" > /etc/hostname
chmod 0644 /etc/hostname
# The RUNNING name has to match too. The pinsdaemon postinst compares `hostname`
# with the rig name and calls hostnamectl on a mismatch - under `set -e`, so a
# refused hostnamectl leaves the package at "iF" and sysupdate-api unenabled.
# In a chroot this touches the build environment's UTS name rather than the
# target's; harmless, and cheaper than a failed image build.
if [ "$(hostname 2>/dev/null)" != "$TARGET_HOSTNAME" ]; then
    hostname "$TARGET_HOSTNAME" 2>/dev/null || note_fail "set running hostname"
fi
if grep -q '^127\.0\.1\.1[[:space:]]' /etc/hosts 2>/dev/null; then
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1 ${TARGET_HOSTNAME}/" /etc/hosts
else
    printf '127.0.1.1 %s\n' "$TARGET_HOSTNAME" >> /etc/hosts
fi

# 2d. no suspend. A telescope rig that falls asleep mid-sequence is worthless.
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target \
    >/dev/null 2>&1 || note_fail "mask sleep targets"
for u in sleep.target suspend.target hibernate.target hybrid-sleep.target; do
    [ -e "/etc/systemd/system/$u" ] || ln -sf /dev/null "/etc/systemd/system/$u"
done
install -d -m 0755 /etc/systemd/logind.conf.d
cat >/etc/systemd/logind.conf.d/90-pins-nosleep.conf <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchDocked=ignore
HandleLidSwitchExternalPower=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
IdleAction=ignore
EOF

# 2e. persistent journal - without it every reboot erases the evidence of the
# night that just failed. Prefix 80- on purpose: the pinsdaemon package ships
# the same setting as 90-, and the package keeps the last word.
install -d -m 0755 /etc/systemd/journald.conf.d
printf '[Journal]\nStorage=persistent\n' > /etc/systemd/journald.conf.d/80-pins-persistent.conf
install -d -m 2755 /var/log/journal

# 2f. shutdown/reboot for the device user - the Touch-N-Stars plugin offers
# those buttons. Every sudoers file this script writes is validated and removed
# again if it does not parse: a broken file in sudoers.d disables sudo entirely.
cat > /etc/sudoers.d/pins-power <<EOF
${PINS_USER} ALL=(root) NOPASSWD: /usr/sbin/shutdown, /sbin/shutdown, /usr/sbin/reboot, /sbin/reboot, /usr/bin/systemctl poweroff, /usr/bin/systemctl reboot
EOF
chmod 0440 /etc/sudoers.d/pins-power
visudo -cf /etc/sudoers.d/pins-power >/dev/null \
    || { rm -f /etc/sudoers.d/pins-power; note_fail "sudoers pins-power"; }

# 2g. overlay. Three sources, in order of trust: the payload ISO, the git
# checkout this script is part of, the published repository tarball.
banner "Overlay"
OVERLAY_SRC=""
if [ -n "$PAYLOAD" ] && [ -s "$PAYLOAD/overlay.tar.gz" ]; then
    OVERLAY_SRC="tar:$PAYLOAD/overlay.tar.gz"
elif [ -n "$SCRIPT_DIR" ] && [ -d "$SCRIPT_DIR/overlay" ]; then
    OVERLAY_SRC="dir:$SCRIPT_DIR/overlay"
# archive/<ref> on purpose, not archive/refs/heads/<ref>: the latter only
# resolves branches, while this form takes a branch, a tag or a commit SHA -
# that is what makes PINS_OVERLAY_REF a real pinning knob (default: main,
# consistent with a script that is itself fetched from main).
elif fetch "https://github.com/${PINS_IMAGE_REPO}/archive/${PINS_OVERLAY_REF}.tar.gz" \
           "$WORKDIR/pins-image.tar.gz"; then
    OVERLAY_SRC="repo:$WORKDIR/pins-image.tar.gz"
fi

# Every source is staged first, made root-owned there, and only then rolled out
# with tar. NEVER `cp -a` straight onto /: cp -a stamps the SOURCE ownership on
# directories that already exist, so a repository checked out by an ordinary user
# turns /etc, /usr and - fatally - /etc/sudoers.d into uid-1000 property. sudo
# then refuses to run at all ("/etc/sudoers.d is owned by uid 1000, should be 0")
# and systemd-hostnamed refuses to write /etc/hostname, which takes the
# pinsdaemon postinst down with it. Measured, not hypothetical.
#   --no-same-owner    everything lands as root:root
#   --no-overwrite-dir existing directories keep their own metadata
STAGE="$WORKDIR/overlay-stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
OVERLAY_OK=0
case "$OVERLAY_SRC" in
    tar:*)
        echo "overlay from payload tarball"
        tar -C "$STAGE" -xzf "${OVERLAY_SRC#tar:}" && OVERLAY_OK=1
        ;;
    dir:*)
        echo "overlay from ${OVERLAY_SRC#dir:}"
        cp -a "${OVERLAY_SRC#dir:}"/. "$STAGE"/ && OVERLAY_OK=1
        ;;
    repo:*)
        echo "overlay from the ${PINS_IMAGE_REPO} tarball"
        rm -rf "$WORKDIR/imgrepo"; mkdir -p "$WORKDIR/imgrepo"
        if tar -C "$WORKDIR/imgrepo" -xzf "${OVERLAY_SRC#repo:}"; then
            OSRC="$(find "$WORKDIR/imgrepo" -maxdepth 4 -type d -path '*/provision/overlay' | head -1)"
            [ -n "$OSRC" ] && cp -a "$OSRC"/. "$STAGE"/ && OVERLAY_OK=1
        fi
        ;;
esac

if [ "$OVERLAY_OK" = "1" ]; then
    chown -R root:root "$STAGE"
    ( cd "$STAGE" && tar -cf - . ) | tar -C / --no-same-owner --no-overwrite-dir -xf - \
        || OVERLAY_OK=0
fi
rm -rf "$STAGE"

if [ "$OVERLAY_OK" = "1" ]; then
    # tar and cp both honour the umask of whatever produced the source, and git
    # cannot record 0440 at all, so the modes are re-applied here rather than
    # trusted.
    chmod 0755 /usr/local/sbin/pins-install-to-disk \
               /usr/local/lib/pins/pins-growroot.sh /usr/local/lib/pins/pins-sshkeys.sh 2>/dev/null
    chmod 0644 /usr/share/keyrings/pins-archive-keyring.gpg 2>/dev/null
    chown -R root:root /etc/pins /usr/local/lib/pins 2>/dev/null
else
    # Not fatal: the software should still install so the marker says something
    # useful. But without the overlay there are no first-boot units.
    note_crit "overlay"
fi

fi  # end appliance-only section 2

# ---------------------------------------------------------------------------
# 3. NetworkManager instead of systemd-networkd
# ---------------------------------------------------------------------------
# Ubuntu Server renders netplan to systemd-networkd. pinsdaemon and the whole
# Wi-Fi mechanism (wifi-connect.sh, pins-wifi-profile.py, the watchdog) speak
# nmcli and nothing else.
if [ "$PINS_SETUP_MODE" = appliance ]; then
banner "NetworkManager"
if [ "$LIVE_SYSTEM" = "1" ]; then
    echo "[WARN] Switching this machine from systemd-networkd to NetworkManager."
    echo "       On a live system the current SSH session may drop. Reboot afterwards."
fi
apt_try network-manager wireless-tools rfkill iw

install -d -m 0755 /etc/cloud/cloud.cfg.d
printf 'network: {config: disabled}\n' > /etc/cloud/cloud.cfg.d/99-disable-network-config.cfg
rm -f /etc/netplan/50-cloud-init.yaml
install -d -m 0755 /etc/netplan
cat > /etc/netplan/01-network-manager-all.yaml <<'EOF'
network:
  version: 2
  renderer: NetworkManager
EOF
chmod 0600 /etc/netplan/*.yaml 2>/dev/null || true
systemctl disable systemd-networkd.service systemd-networkd-wait-online.service >/dev/null 2>&1 || true
systemctl enable NetworkManager.service >/dev/null 2>&1 || note_fail "enable NetworkManager"
netplan generate 2>/dev/null || true      # best effort; in a chroot it is a no-op
fi

# ---------------------------------------------------------------------------
# 4. PPAs and the astronomy stack
# ---------------------------------------------------------------------------
banner "PPAs (INDI + PHD2)"
add-apt-repository -y ppa:mutlaqja/ppa || note_fail "ppa mutlaqja"
add-apt-repository -y ppa:pch/phd2     || note_fail "ppa pch/phd2"
apt-get update || note_fail "apt update (ppa)"

banner "INDI + PHD2 + astrometry + services"
apt_try indi-full phd2 xvfb astrometry.net astrometry-data-tycho2 \
        openssh-server avahi-daemon libnss-mdns
# gsc only exists in the mutlaqja PPA, not in the Ubuntu archive, and it is only
# needed by the INDI CCD simulator. Separate call so a miss cannot drag the
# mandatory packages down with it.
apt_try gsc || true
systemctl enable ssh >/dev/null 2>&1 || note_fail "enable ssh"
systemctl enable avahi-daemon >/dev/null 2>&1 || note_fail "enable avahi"

# ---------------------------------------------------------------------------
# 5. Our apt repository
# ---------------------------------------------------------------------------
banner "PINS apt repository"
KEYRING=/usr/share/keyrings/pins-archive-keyring.gpg
if [ ! -s "$KEYRING" ]; then
    # Normally the overlay already put it there; this is the fallback for an
    # --addon run or a missing overlay.
    if fetch "https://raw.githubusercontent.com/${PINS_IMAGE_REPO}/main/pins-archive-keyring.gpg" \
             "$WORKDIR/keyring.gpg"; then
        install -m 0644 -o root -g root "$WORKDIR/keyring.gpg" "$KEYRING" || note_crit "apt keyring"
    else
        note_crit "apt keyring"
    fi
fi
chmod 0644 "$KEYRING" 2>/dev/null

# Flat repository built from the GitHub release assets. No [trusted=yes]: the
# signature is the point, and the negative test (tampered InRelease -> BAD
# signature) is part of the QA.
install -d -m 0755 /etc/apt/sources.list.d
cat > /etc/apt/sources.list.d/pins.sources <<EOF
Types: deb
URIs: ${PINS_APT_URI}
Suites: ./
Signed-By: ${KEYRING}
EOF
chmod 0644 /etc/apt/sources.list.d/pins.sources
apt-get update || note_fail "apt update (pins repo)"

# ---------------------------------------------------------------------------
# 6. The PINS stack
# ---------------------------------------------------------------------------
banner "PINS stack"
REL="https://github.com/${PINS_REPO_OWNER}/pins-x64/releases/latest/download"

if install_deb "pins_amd64.deb" "$REL/pins_amd64.deb" "pins"; then
    deb_installed_ok pins || note_crit "pins"
else
    note_crit "pins"
fi

for p in ninaapi touch-n-stars joko livestack polaralignment; do
    install_deb "pins-plugin-${p}_amd64.deb" "$REL/pins-plugin-${p}_amd64.deb" "plugin $p" || true
done

# --addon: this is someone's existing machine, and the daemon must not raise a
# fallback hotspot on it (its startup hook does exactly that whenever no
# wifi_config.json exists). Written BEFORE the package so that already the
# first daemon start reads it - the postinst does daemon-reload + restart.
# The Touch-N-Stars network UI (wifi-connect.sh via API) keeps working.
if [ "$PINS_SETUP_MODE" = addon ]; then
    install -d -m 0755 /etc/systemd/system/sysupdate-api.service.d
    cat > /etc/systemd/system/sysupdate-api.service.d/10-pins-addon.conf <<'EOF'
# PINS --addon: this is someone's existing machine. The daemon must not
# raise a fallback hotspot on it; Wi-Fi stays under the owner's control.
# The Touch-N-Stars network UI (wifi-connect.sh via API) keeps working.
[Service]
Environment=STARTUP_WIFI_AUTOMANAGE_ENABLED=false
EOF
fi

install_deb "pinsdaemon_amd64.deb" "$REL/pinsdaemon_amd64.deb" "pinsdaemon" || true
if ! deb_installed_ok pinsdaemon; then
    # Its postinst builds a Python venv and runs pip; without PyPI access that
    # leaves the package at "iF" (installed, failed-config) and sysupdate-api
    # never gets enabled. One retry, then it is recorded as critical.
    dpkg --configure -a >/dev/null 2>&1 || true
    deb_installed_ok pinsdaemon || note_crit "pinsdaemon"
fi

# --addon: the pinsdaemon postinst enables the watchdog timer on every install
# and upgrade, so a plain disable would not survive the next update. Mask it
# (pinsdaemon >= 1.0.9 tolerates the mask in its postinst - `|| true` there;
# on older versions an upgrade would fail on the masked unit).
if [ "$PINS_SETUP_MODE" = addon ]; then
    systemctl disable --now pins-wifi-watchdog.timer >/dev/null 2>&1 || true
    systemctl mask pins-wifi-watchdog.timer >/dev/null 2>&1 || true
    [ -e /etc/systemd/system/pins-wifi-watchdog.timer ] \
        || ln -sf /dev/null /etc/systemd/system/pins-wifi-watchdog.timer
fi

systemctl enable pins.service              >/dev/null 2>&1 || note_fail "enable pins"
systemctl enable sysupdate-api.service     >/dev/null 2>&1 || note_fail "enable sysupdate-api"

if [ "$PINS_SETUP_MODE" = appliance ]; then

systemctl enable pins-wifi-watchdog.timer  >/dev/null 2>&1 || note_fail "enable wifi watchdog timer"

# --- pinsdaemon Wi-Fi configuration (AP7) ---------------------------------
# Written AFTER the package, and handed back to the daemon's user: the API
# rewrites both files at runtime (hotspot_config.py opens them "w").
if [ -d /opt/pinsdaemon/app ]; then
    # Shipped state: hotspot on, until the app configures a station.
    # desired_mode=hotspot makes the watchdog raise the AP on its first
    # run instead of waiting for three failed gateway checks; pins-wifi-
    # profile.py resets it to "auto" as soon as a station connection succeeds.
    cat > /opt/pinsdaemon/app/wifi_config.json <<'EOF'
{
    "ssid": null,
    "auto_connect": false,
    "band": null,
    "desired_mode": "hotspot",
    "client_profile_uuid": null
}
EOF
    # SSID of the fallback AP. Decoupled from the rig name on purpose: the host
    # is "pins", the AP is "pinspot". An empty password means the daemon default
    # applies (documented in the flashing instructions). "security" is recorded
    # for the image build's benefit; the shipped wifi-connect.sh always uses
    # WPA2 and ignores the key.
    #
    # client_interface/hotspot_interface are deliberately absent: on x64 the
    # adapter name is device-specific and must be resolved at runtime.
    cat > /opt/pinsdaemon/app/hotspot_config.json <<EOF
{
    "ssid": "${PINS_HOTSPOT_SSID}",
    "security": "${PINS_HOTSPOT_SECURITY}",
    "password": "${PINS_HOTSPOT_PASSWORD}",
    "band": "2.4GHz",
    "channel": null
}
EOF
    # 0600: hotspot_config.json carries the AP password, and nobody but the
    # daemon (owner) and root-run scripts ever reads either file.
    chmod 0600 /opt/pinsdaemon/app/wifi_config.json /opt/pinsdaemon/app/hotspot_config.json
    chown sysupdate-api:sysupdate-api /opt/pinsdaemon/app/wifi_config.json \
                                      /opt/pinsdaemon/app/hotspot_config.json 2>/dev/null || true
else
    note_fail "pinsdaemon wifi configuration (/opt/pinsdaemon/app missing)"
fi

# The pinsdaemon postinst runs pins-rig-name --ensure. Since 1.0.8 it honours
# /etc/pins/rig-name, but do not trust ordering alone (QA B-1/B-3): verify, and
# repair loudly if anything renamed the host behind our back.
if [ "$(head -n1 /etc/pins/rig-name 2>/dev/null)" != "$TARGET_HOSTNAME" ] \
   || [ "$(head -n1 /etc/hostname 2>/dev/null)" != "$TARGET_HOSTNAME" ]; then
    printf '%s\n' "$TARGET_HOSTNAME" > /etc/pins/rig-name
    printf '%s\n' "$TARGET_HOSTNAME" > /etc/hostname
    hostname "$TARGET_HOSTNAME" 2>/dev/null || true
    sed -i "s/^127\.0\.1\.1.*/127.0.1.1 ${TARGET_HOSTNAME}/" /etc/hosts
    note_fail "hostname drifted after pinsdaemon install (repaired)"
fi

fi  # end appliance-only Wi-Fi defaults

# ---------------------------------------------------------------------------
# 7. ASTAP + D50 star database
# ---------------------------------------------------------------------------
banner "ASTAP (GUI + CLI + D50)"
# All three URLs verified 2026-08-10 (302 -> mirror -> 200):
#   astap_amd64.deb 7,245,920 B | CLI zip 323,216 B | d50 866,752,764 B
SF="https://downloads.sourceforge.net/project/astap-program"
install_deb "astap_amd64.deb" "${SF}/linux_installer/astap_amd64.deb" "astap GUI" || true

CLI_ZIP=""
if [ -n "$PAYLOAD" ] && [ -s "$PAYLOAD/astap_cli.zip" ]; then
    CLI_ZIP="$PAYLOAD/astap_cli.zip"
elif fetch "${SF}/linux_installer/astap_command-line_version_Linux_amd64.zip" "$WORKDIR/astap_cli.zip"; then
    CLI_ZIP="$WORKDIR/astap_cli.zip"
else
    note_fail "download astap_cli"
fi
if [ -n "$CLI_ZIP" ]; then
    rm -rf "$WORKDIR/astapcli" && mkdir -p "$WORKDIR/astapcli"
    if unzip -o "$CLI_ZIP" -d "$WORKDIR/astapcli" >/dev/null; then
        BIN="$(find "$WORKDIR/astapcli" -type f -name 'astap_cli' | head -1)"
        if [ -n "$BIN" ]; then
            install -m 0755 "$BIN" /usr/local/bin/astap_cli || note_fail "astap_cli binary"
        else
            note_fail "astap_cli binary"
        fi
    else
        note_fail "unzip astap_cli"
    fi
fi

install_deb "d50_star_database.deb" "${SF}/star_databases/d50_star_database.deb" "astap d50" || true

# ---------------------------------------------------------------------------
# 8. First-boot units
# ---------------------------------------------------------------------------
if [ "$PINS_SETUP_MODE" = appliance ]; then
banner "First boot units"
systemctl enable pins-growroot.service >/dev/null 2>&1 || note_fail "enable growroot"
systemctl enable pins-sshkeys.service  >/dev/null 2>&1 || note_fail "enable sshkeys"
# Seed PHD2 profile (O5). With a virgin ~/.phd2, PHD2 parks ALL JSON-RPC
# handling on port 4400 behind its first-profile dialog - the app can never
# reach it (measured during the s0e PHD2 investigation). The placeholders only
# need to be something other than "None"; the real equipment is set later by
# the app over RPC. Never overwrite an existing file: a re-run must not
# destroy a real user profile.
if [ ! -f "$PHOME/.phd2/PHDGuidingV2" ]; then
    install -d -m 0755 -o "$PINS_USER" -g "$PINS_USER" "$PHOME/.phd2"
    cat > "$PHOME/.phd2/PHDGuidingV2" <<'EOF'
currentProfile=1
[profile/1]
name=pins
[profile/1/camera]
LastMenuChoice=Simulator
[profile/1/scope]
LastMenuChoice=On-camera
EOF
    chmod 0644 "$PHOME/.phd2/PHDGuidingV2"
    chown "$PINS_USER:$PINS_USER" "$PHOME/.phd2/PHDGuidingV2"
fi

# phd2 + xvfb are enabled by default (O5 revision): the seed profile above
# removes the old blocker (an unconfigured PHD2 was useless), and ~150-250 MB
# of RAM for the pair is an accepted cost. PINS_ENABLE_PHD2=0 opts out; xvfb
# follows phd2 because it only exists to give phd2 a display.
if [ "$PINS_ENABLE_PHD2" = "1" ]; then
    systemctl enable xvfb.service >/dev/null 2>&1 || note_fail "enable xvfb"
    systemctl enable phd2.service >/dev/null 2>&1 || note_fail "enable phd2"
fi

install -d -m 0755 /var/lib/pins
rm -f /var/lib/pins/growroot.done          # a flashed image must grow on first boot
fi

# ---------------------------------------------------------------------------
# 9. Cleanup and image sanitising
# ---------------------------------------------------------------------------
[ -n "$PAYLOAD" ] && { umount /mnt/payload 2>/dev/null || true; }

if [ "$PINS_SETUP_MODE" = appliance ] && [ "$PINS_SKIP_SANITIZE" != "1" ]; then
banner "Cleanup + sanitise"
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf "$WORKDIR"

# Every device flashed from this image must mint its own identity on first boot.
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id && ln -s /etc/machine-id /var/lib/dbus/machine-id
rm -f /etc/ssh/ssh_host_*                  # pins-sshkeys.service regenerates them
rm -rf /var/lib/cloud/instances/* /var/log/installer
rm -rf /var/lib/NetworkManager/*.lease /var/lib/NetworkManager/seen-bssids \
       /var/lib/NetworkManager/timestamps 2>/dev/null || true
rm -rf /opt/pinsdaemon/logs/* 2>/dev/null || true
find /var/log -type f -exec truncate -s 0 {} +
rm -f /root/provision.sh /root/.bash_history "${PHOME:-/home/$PINS_USER}/.bash_history" 2>/dev/null || true

# Zero the free space so the image compresses. Best effort by definition: this
# is expected to end with "no space left on device".
dd if=/dev/zero of=/zerofill bs=1M 2>/dev/null || true
rm -f /zerofill; sync
else
apt-get clean || true
fi

# /etc/pins/rig-name is part of the shipped state - it is never removed here.

# ---------------------------------------------------------------------------
# Marker + summary
# ---------------------------------------------------------------------------
join_csv() { local IFS=','; printf '%s' "$*"; }
CRIT_CSV="$(join_csv ${CRITICAL[@]+"${CRITICAL[@]}"})"
FAIL_CSV="$(join_csv ${FAILED[@]+"${FAILED[@]}"})"
STATUS=ok
[ -n "$CRIT_CSV" ] && STATUS=failed

# The image build reads this file after the autoinstall and may refuse to
# publish an image whose CRITICAL list is not empty.
if [ -d /boot/efi ]; then
    MARKER=/boot/efi/pins-provision-ok
else
    install -d -m 0755 /var/lib/pins
    MARKER=/var/lib/pins/provision-report
fi
cat > "$MARKER" <<EOF
PINS_PROVISION_STATUS=${STATUS}
PINS_PROVISION_MODE=${PINS_SETUP_MODE}
PINS_PROVISION_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
CRITICAL=${CRIT_CSV}
FAILED=${FAIL_CSV}
EOF
chmod 0644 "$MARKER" 2>/dev/null || true
# Flushed on purpose: the image build powers the VM off right after this script
# returns, and an unflushed write to the FAT ESP is simply gone. Measured - a
# hard power-off left the previous run's marker in place.
sync

echo
echo "============================================================================="
if [ "${#FAILED[@]}" -eq 0 ] && [ "${#CRITICAL[@]}" -eq 0 ]; then
    echo "==> PINS provisioning finished cleanly."
else
    echo "==> PINS provisioning finished with $(( ${#FAILED[@]} + ${#CRITICAL[@]} )) non-fatal issue(s):"
    for f in ${CRITICAL[@]+"${CRITICAL[@]}"}; do echo "      - CRITICAL: $f"; done
    for f in ${FAILED[@]+"${FAILED[@]}"};   do echo "      - $f"; done
    echo "    Re-run this script on the booted system to retry them."
fi
echo "    Report: $MARKER"
echo "============================================================================="

# Only a missing PINS package is fatal. pinsdaemon is recorded as critical but
# left to the image build to judge.
if in_list pins ${CRITICAL[@]+"${CRITICAL[@]}"}; then
    exit 1
fi
exit 0
