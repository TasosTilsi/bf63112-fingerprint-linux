#!/usr/bin/env bash
#
# One-shot installer for the Betterlife BF63112 SPI fingerprint sensor on
# Debian/Ubuntu-family Linux.
#
# This is a THIN WRAPPER around dedbin/libfprint-bf63112. It does not fork or
# patch the driver except for one narrowly scoped, revertible distro-identity
# check. Credit and license for the driver belong to that project.
#
# The proprietary Blestech matcher is never redistributed here. This script
# downloads the OEM package from Microsoft Update Catalog and verifies a pinned
# SHA-256 before using it.
#
# License: LGPL-2.1-or-later (matches upstream). See COPYING and NOTICE.
set -Eeuo pipefail

readonly PROG="$(basename -- "$0")"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# --- pinned facts -----------------------------------------------------------
readonly UPSTREAM_REPO="https://github.com/dedbin/libfprint-bf63112"
readonly UPSTREAM_PIN="2e6bcf04950e02e25099f4257d042c4617cef6f6"
readonly CATALOG_URL="https://catalog.s.download.windowsupdate.com/c/msdownload/update/driver/drvs/2025/02/f3287103-8212-45b3-9a66-39baf8b19bde_8bc033e59c360fbc0b7d790217e44348ede0593b.cab"
readonly MATCHER_SHA256="9f85fbdb17794d33ec021dcbcacf90733e0a055f80dd77cea6e305c96678fdeb"
readonly MATCHER_SIZE="2121392"
readonly SENSOR_ID="0x5f83"

readonly WORK_DIR="${BF63112_WORK_DIR:-$HOME/.local/share/bf63112-setup}"
readonly UPSTREAM_DIR="$WORK_DIR/upstream"
readonly MATCHER_DIR="$WORK_DIR/matcher"
readonly MATCHER_DLL="$MATCHER_DIR/extracted/BetterlifeEngineAdapter.dll"
readonly SPI_DEV="/sys/bus/spi/devices/spi-BF63112:00"
readonly SPI_NAME="spi-BF63112:00"

# --- flags ------------------------------------------------------------------
WITH_LOGIN=ask
WITH_SUDO=ask
ASSUME_YES=0
MODE=install

# --- output -----------------------------------------------------------------
say()  { printf '\n==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
die()  { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
$PROG - install the Betterlife BF63112 fingerprint sensor on Linux

Usage: $PROG [options]

  (no option)     install, then ask before touching any PAM file
  --with-login    also enable fingerprint at the graphical login screen
  --with-sudo     also enable fingerprint for sudo
  --no-pam        never touch PAM, even if asked
  --rollback      remove the system integration and restore PAM backups
  --yes           assume yes for package installation and prompts
  -h, --help      show this help

Everything that is not PAM related is installed under /opt/bf63112 plus a
fprintd drop-in, a udev rule and a modprobe config. Reversible with --rollback.

The proprietary matcher is downloaded from Microsoft Update Catalog and
checked against a pinned SHA-256. It is never bundled.
EOF
}

while (($#)); do
    case "$1" in
        --with-login) WITH_LOGIN=yes ;;
        --with-sudo)  WITH_SUDO=yes ;;
        --no-pam)     WITH_LOGIN=no; WITH_SUDO=no ;;
        --rollback)   MODE=rollback ;;
        --yes|-y)     ASSUME_YES=1 ;;
        -h|--help)    usage; exit 0 ;;
        *)            die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

confirm() {
    ((ASSUME_YES == 1)) && return 0
    local reply
    read -r -p "$1 [y/N] " reply
    [[ "$reply" == [yY] ]]
}

require() {
    command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

# --- step 1: preconditions --------------------------------------------------
step_preconditions() {
    say "Checking the environment"
    ((EUID != 0)) || die "run this as your normal user, not with sudo"
    [[ "$(dpkg --print-architecture)" == amd64 ]] || die "only amd64 is supported"
    command -v apt >/dev/null 2>&1 || die "this installer targets apt-based distros"

    info "distro: $(. /etc/os-release && printf '%s %s' "$ID" "$VERSION_ID")"
    info "kernel: $(uname -r)"

    [[ -d /sys/bus/spi/devices ]] || die "no SPI bus present"
    if [[ ! -d "$SPI_DEV" ]]; then
        die "sensor SPI device $SPI_NAME not found.
This installer only handles the Betterlife BF63112 exposed as ACPI BF63112.
Check with:  ls /sys/bus/spi/devices/"
    fi
    info "sensor: $SPI_NAME found"
}

# --- step 2: packages -------------------------------------------------------
step_packages() {
    say "Installing required packages"
    info "this needs your sudo password"
    sudo apt-get update
    sudo apt-get install -y \
        build-essential meson ninja-build pkg-config \
        libglib2.0-dev libgusb-dev libgudev-1.0-dev libudev-dev \
        wine wine64 wine64-tools libwine-dev bubblewrap \
        fprintd libpam-fprintd python3 python3-spidev \
        curl cabextract git
}

# --- step 3: sensor identity ------------------------------------------------
spidev_bind() {
    sudo modprobe spidev bufsiz=16384
    printf 'spidev\n' | sudo tee "$SPI_DEV/driver_override" >/dev/null
    printf '%s\n' "$SPI_NAME" | sudo tee /sys/bus/spi/drivers/spidev/bind >/dev/null
}

spidev_unbind() {
    # Clear the override FIRST: it is the only thing holding the bind, since
    # spidev's modalias never matches this device's ACPI modalias by itself.
    printf '' | sudo tee "$SPI_DEV/driver_override" >/dev/null 2>&1 || true
    printf '%s\n' "$SPI_NAME" | sudo tee /sys/bus/spi/drivers/spidev/unbind >/dev/null 2>&1 || true
}

step_probe() {
    say "Reading the sensor ID (read-only over SPI)"
    spidev_bind
    local out
    out="$(sudo python3 "$SCRIPT_DIR/probe-id.py" 2>&1)" || { spidev_unbind; die "could not read the sensor ID"; }
    printf '%s\n' "$out" | sed 's/^/    /'
    spidev_unbind

    printf '%s\n' "$out" | grep -q "Sensor ID $SENSOR_ID" ||
        die "unexpected sensor ID. Supported: $SENSOR_ID only."
    info "sensor ID matches, good to continue"
}

# --- step 4: proprietary matcher -------------------------------------------
step_matcher() {
    say "Obtaining the OEM matcher (not bundled, downloaded from Microsoft)"
    mkdir -p "$MATCHER_DIR"

    if [[ -f "$MATCHER_DLL" ]] &&
       [[ "$(sha256sum "$MATCHER_DLL" | cut -d' ' -f1)" == "$MATCHER_SHA256" ]]; then
        info "already present locally and verified"
        return 0
    fi

    local cab="$MATCHER_DIR/blestech.cab"
    info "downloading the Blestech driver package"
    curl -fsSL --retry 3 -o "$cab" "$CATALOG_URL" ||
        die "download failed. The catalog link may have moved.
Find 'BLESTECH - Biometric' for ACPI\\\\BF63112 on
https://www.catalog.update.microsoft.com/Search.aspx?q=ACPI%5CBF63112
and place the .cab at: $cab"

    cabextract -q -d "$MATCHER_DIR/extracted" "$cab" >/dev/null ||
        die "could not extract $cab"
    [[ -f "$MATCHER_DLL" ]] || die "package did not contain BetterlifeEngineAdapter.dll"

    local size sha
    size="$(stat -c '%s' "$MATCHER_DLL")"
    sha="$(sha256sum "$MATCHER_DLL" | cut -d' ' -f1)"
    [[ "$size" == "$MATCHER_SIZE" ]] && [[ "$sha" == "$MATCHER_SHA256" ]] ||
        die "matcher does not match the pinned build.
  expected size $MATCHER_SIZE, got $size
  expected sha  $MATCHER_SHA256
  got      sha  $sha
Refusing to use an unidentified matcher in an authentication path."
    info "matcher verified: $size bytes, sha256 matches"
}

# --- step 5: upstream checkout --------------------------------------------
step_upstream() {
    say "Fetching the driver source at a pinned commit"
    if [[ -d "$UPSTREAM_DIR/.git" ]]; then
        info "reusing $UPSTREAM_DIR"
        git -C "$UPSTREAM_DIR" fetch -q origin || warn "fetch failed, using existing checkout"
        git -C "$UPSTREAM_DIR" checkout -q "$UPSTREAM_PIN" ||
            die "cannot check out pinned commit $UPSTREAM_PIN"
    else
        git clone -q "$UPSTREAM_REPO" "$UPSTREAM_DIR" ||
            die "could not clone $UPSTREAM_REPO"
        git -C "$UPSTREAM_DIR" checkout -q "$UPSTREAM_PIN" ||
            die "cannot check out pinned commit $UPSTREAM_PIN"
    fi
    info "at $(git -C "$UPSTREAM_DIR" rev-parse --short HEAD)"
}

# --- step 6: distro identity check ----------------------------------------
# Upstream hard-requires ID=ubuntu VERSION_ID=24.04. That is a testedness gate,
# not a capability gate. We relax only that one predicate, on derivatives, and
# keep a backup. Everything else upstream validates stays enforced.
step_distro_gate() {
    local installer="$UPSTREAM_DIR/tools/bf63112/install-system.sh"
    [[ -f "$installer" ]] || die "upstream installer not found: $installer"

    local id ver
    id="$(sed -nE 's/^ID="?([^" ]+)"?$/\1/p' /etc/os-release | head -1)"
    ver="$(sed -nE 's/^VERSION_ID="?([^" ]+)"?$/\1/p' /etc/os-release | head -1)"

    if [[ "$id" == ubuntu && "$ver" == 24.04 ]]; then
        info "running on tested Ubuntu 24.04, no change needed"
        return 0
    fi

    say "This is $id $ver, not the tested Ubuntu 24.04"
    info "relaxing only the distro-identity predicate, keeping every real check"
    if [[ ! -f "$installer.upstream" ]]; then
        cp "$installer" "$installer.upstream"
    fi
    python3 - "$installer" <<'PY'
import sys
p = sys.argv[1]
t = open(p, encoding="utf-8").read()
old = '[[ "$os_id" == ubuntu && "$os_version" == 24.04 ]] ||'
new = '[[ -n "$os_id" && -n "$os_version" ]] ||'
if old in t:
    open(p, "w", encoding="utf-8").write(t.replace(old, new, 1))
elif new in t:
    pass
else:
    sys.exit("could not find the distro-identity predicate to relax")
PY
    info "patched; original kept at $installer.upstream"
    info "NOTE: an upstream update will restore the original check"
}

# --- step 7: import matcher -----------------------------------------------
step_import() {
    say "Importing the matcher into the private build area"
    "$UPSTREAM_DIR/tools/bf63112/import-vendor-dll.sh" "$MATCHER_DLL"
}

# --- step 8: fprint state directory ---------------------------------------
step_fprint_dir() {
    local dir=/var/lib/fprint
    [[ -d "$dir" ]] || return 0
    local mode
    mode="$(sudo stat -Lc '%a' "$dir")"
    if [[ "$mode" == 700 ]]; then
        info "$dir already 0700"
        return 0
    fi
    say "Tightening $dir from $mode to 700"
    info "fprintd.service uses StateDirectory=fprint with StateDirectoryMode=0700,"
    info "and runs as root, so 0700 is the intended mode for biometric data."
    sudo chmod 700 "$dir"
}

# --- step 9: install ------------------------------------------------------
step_install() {
    say "Installing the system integration (this asks for sudo again)"
    "$UPSTREAM_DIR/tools/bf63112/install-system.sh" --install
}

# --- step 10: functional test --------------------------------------------
step_test() {
    say "Testing through fprintd"
    require fprintd-list

    local enrolled
    enrolled="$(timeout 30 fprintd-list "$USER" 2>/dev/null | grep -c '^ - #' || true)"
    info "enrolled fingers before this run: $enrolled"

    if ! timeout 30 fprintd-list "$USER" 2>/dev/null | grep -q 'right-index-finger'; then
        say "Enrolling your RIGHT INDEX finger"
        info "8 touches, about one second each, lift fully between them"
        info "you have 45 seconds per touch before it times out"
        fprintd-enroll -f right-index-finger || die "enrollment failed"
    else
        info "right index already enrolled, skipping enrollment"
    fi

    say "Verifying the enrolled finger"
    info "place the RIGHT INDEX finger"
    if fprintd-verify -f right-index-finger; then
        info "right index matched"
    else
        die "the enrolled finger did not match; sensor or matcher problem"
    fi

    local count
    count="$(timeout 30 fprintd-list "$USER" 2>/dev/null | grep -c '^ - #' || true)"
    if [[ "$count" == 1 ]]; then
        say "Checking that a DIFFERENT finger is rejected"
        info "place the LEFT INDEX finger (it must NOT match)"
        if fprintd-verify; then
            die "a different finger was ACCEPTED. This matcher is not safe for authentication.
Do not enable PAM. Report this at $UPSTREAM_REPO"
        else
            info "different finger correctly rejected"
        fi
    else
        warn "more than one finger enrolled, skipping the wrong-finger check"
        warn "to test it: fprintd-delete $USER, re-enroll one finger, then fprintd-verify with another"
    fi
    info "test passed"
}

# --- step 11: PAM ---------------------------------------------------------
pam_insert() {
    local file="$1" line="$2"
    if sudo grep -qF "$line" "$file"; then
        info "already present in $file"
        return 0
    fi
    sudo cp "$file" "$file.bak.$(date +%Y%m%dT%H%M%S)"
    sudo sed -i "0,/^@include common-auth/{s|^@include common-auth|$line\n@include common-auth|}" "$file"
    if ! sudo grep -qF "$line" "$file"; then
        die "failed to add the PAM line to $file. Restore from the .bak file beside it."
    fi
    info "added to $file; backup kept next to it"
}

step_pam() {
    local want_login="$WITH_LOGIN" want_sudo="$WITH_SUDO"

    if [[ "$want_sudo" == ask ]]; then
        confirm "Enable fingerprint for sudo (password still works)" && want_sudo=yes || want_sudo=no
    fi
    if [[ "$want_login" == ask ]]; then
        if [[ -f /etc/pam.d/lightdm ]]; then
            confirm "Enable fingerprint at the login screen (LightDM)" && want_login=yes || want_login=no
        else
            warn "no /etc/pam.d/lightdm, skipping login integration"
            want_login=no
        fi
    fi

    if [[ "$want_sudo" == yes ]]; then
        say "Wiring fingerprint into sudo"
        pam_insert /etc/pam.d/sudo "auth sufficient pam_fprintd.so max-tries=1 timeout=10"
        info "undo with: sudo cp /etc/pam.d/sudo.bak.<timestamp> /etc/pam.d/sudo"
    fi
    if [[ "$want_login" == yes ]]; then
        say "Wiring fingerprint into the login screen"
        pam_insert /etc/pam.d/lightdm "auth sufficient pam_fprintd.so max-tries=1 timeout=10"
        info "undo with: sudo cp /etc/pam.d/lightdm.bak.<timestamp> /etc/pam.d/lightdm"
        info "keep a root TTY (Ctrl+Alt+F3) until you have logged in once"
    fi

    if [[ "$want_sudo" == no && "$want_login" == no ]]; then
        info "PAM untouched; fingerprint works only via fprintd-verify"
    fi
}

# --- rollback ------------------------------------------------------------
step_rollback() {
    say "Rolling back"

    local f
    for f in /etc/pam.d/sudo /etc/pam.d/lightdm; do
        local newest
        newest="$(ls -1t "$f".bak.* 2>/dev/null | head -1 || true)"
        if [[ -n "$newest" ]]; then
            sudo cp "$newest" "$f" && info "restored $f from $newest"
        fi
    done

    if [[ -f "$UPSTREAM_DIR/tools/bf63112/rollback-system.sh" ]]; then
        "$UPSTREAM_DIR/tools/bf63112/rollback-system.sh" --rollback
    else
        warn "upstream checkout not found, skipping system rollback"
    fi

    if [[ -f "$UPSTREAM_DIR/tools/bf63112/install-system.sh.upstream" ]]; then
        info "note: pinned source at $UPSTREAM_DIR was patched; re-clone to reset it"
    fi
    say "Rollback finished. Your enrolled prints are kept in /var/lib/fprint."
}

# --- main ----------------------------------------------------------------
case "$MODE" in
    rollback) step_rollback ;;
    install)
        step_preconditions
        step_packages
        step_probe
        step_matcher
        step_upstream
        step_distro_gate
        step_import
        step_fprint_dir
        step_install
        step_test
        step_pam
        say "Done"
        info "fingerprint login state: $WITH_LOGIN | sudo: $WITH_SUDO"
        info "after a fprintd/libfprint/wine upgrade, re-run this script"
        ;;
esac
