#!/bin/bash
#
# cmpunlocker - pin the NVIDIA packages to the version the unlock supports.
#
# Installed to /usr/lib/cmpunlocker/pin-packages.sh.
#
# Usage: pin-packages.sh pin|unpin|status
#
# Why this exists: the patched modules are built from the open-gpu-kernel-modules
# tarball matching the *installed* driver, and driver/VERSION lists the versions
# the unlock has been validated against. If the package manager moves the driver
# to an unsupported version, the next kernel-update rebuild fails and the machine
# falls back to the stock driver - the exact rollback this is meant to prevent.
#
# Everything here is reversible: remove.sh calls "unpin".
#
set -uo pipefail

ACTION="${1:-status}"
MARK_BEGIN="# BEGIN cmpunlocker"
MARK_END="# END cmpunlocker"

info() { echo "cmpunlocker: $*"; }

#
# Blanket-match on the name rather than a curated list: the package split
# differs per distro and per driver flavour (akmod-nvidia-open, nvidia-utils,
# xorg-x11-drv-nvidia-cuda, nvidia-dkms-610, libnvidia-*, ...). Everything
# carrying the driver version has "nvidia" in the name.
#
# Except the GPU firmware packages: those are subpackages of linux-firmware and
# have nothing to do with the driver version — the GSP firmware the unlock needs
# ships inside the NVIDIA driver package itself. Holding them back would block
# linux-firmware updates and can wedge the whole upgrade transaction on a
# dependency conflict.
#
EXCLUDE_RE='^nvidia-gpu-firmware|^firmware-nvidia|^nvidia-firmware'

filter() { grep -i nvidia | grep -Ev "${EXCLUDE_RE}" | sort -u; }

rpm_pkgs()  { rpm -qa --qf '%{NAME}\n' 2>/dev/null | filter; }
dpkg_pkgs() { dpkg-query -W -f='${Package}\n' 2>/dev/null | filter; }
pac_pkgs()  { pacman -Qq 2>/dev/null | filter; }

# ---------------------------------------------------------------- dnf / rpm --
#
# "dnf versionlock --help" is not a usable probe: dnf5 accepts the subcommand
# name whether or not the plugin is actually there. Running an real query is,
# and -C keeps it off the network so a rig with no route to the mirrors still
# gets a straight answer.
#
dnf_versionlock_available() {
    command -v dnf &>/dev/null || return 1
    dnf -C versionlock list &>/dev/null || dnf versionlock list &>/dev/null
}

dnf_locked_count() {
    { dnf -C versionlock list 2>/dev/null || dnf versionlock list 2>/dev/null; } \
        | grep -ci nvidia || true
}

pin_dnf() {
    local pkgs before after
    pkgs="$(rpm_pkgs)"
    [[ -n "${pkgs}" ]] || { info "no nvidia packages installed — nothing to pin"; return 0; }

    if ! dnf_versionlock_available; then
        info "cannot pin: the dnf versionlock plugin is not available"
        info "  install it with:  sudo dnf install python3-dnf-plugin-versionlock"
        info "  (dnf5:            sudo dnf install dnf5-plugin-versionlock)"
        info "  then re-run:      sudo /usr/lib/cmpunlocker/pin-packages.sh pin"
        return 1
    fi

    before="$(dnf_locked_count)"
    # shellcheck disable=SC2086
    dnf -C versionlock add ${pkgs} >/dev/null 2>&1 || \
    # shellcheck disable=SC2086
    dnf versionlock add ${pkgs} >/dev/null 2>&1 || true
    after="$(dnf_locked_count)"

    #
    # Verify rather than trust the exit code: dnf can fail to reach the mirrors
    # and still return 0, which would have this claim a pin that does not exist.
    #
    if (( after > before )) || { (( before > 0 )) && (( after > 0 )); }; then
        info "pinned ${after} nvidia package(s) with dnf versionlock"
        return 0
    fi

    info "FAILED to pin: dnf versionlock has no nvidia entries after the attempt"
    info "  most likely the repo metadata could not be refreshed (no network)"
    info "  retry with:  sudo /usr/lib/cmpunlocker/pin-packages.sh pin"
    return 1
}

unpin_dnf() {
    dnf_versionlock_available || return 0
    local pkgs
    pkgs="$(rpm_pkgs)"
    [[ -n "${pkgs}" ]] || return 0
    # shellcheck disable=SC2086
    dnf -C versionlock delete ${pkgs} >/dev/null 2>&1 || \
    # shellcheck disable=SC2086
    dnf versionlock delete ${pkgs} >/dev/null 2>&1 || true
    info "removed dnf versionlock entries for nvidia packages"
}

status_dnf() {
    dnf_versionlock_available || { echo "  dnf versionlock plugin not available"; return 0; }
    local out
    out="$({ dnf -C versionlock list 2>/dev/null || dnf versionlock list 2>/dev/null; } | grep -i nvidia)"
    [[ -n "${out}" ]] && echo "${out}" | sed 's/^/  /' || echo "  (none)"
}

# --------------------------------------------------------------- apt / dpkg --
pin_apt() {
    local pkgs held
    pkgs="$(dpkg_pkgs)"
    [[ -n "${pkgs}" ]] || { info "no nvidia packages installed — nothing to pin"; return 0; }
    # shellcheck disable=SC2086
    apt-mark hold ${pkgs} >/dev/null 2>&1 || true

    held="$(apt-mark showhold 2>/dev/null | grep -ci nvidia || true)"
    if (( held > 0 )); then
        info "held ${held} nvidia package(s) with apt-mark"
        return 0
    fi
    info "FAILED to pin: apt-mark shows no nvidia holds after the attempt"
    return 1
}

unpin_apt() {
    local pkgs
    pkgs="$(apt-mark showhold 2>/dev/null | grep -i nvidia || true)"
    [[ -n "${pkgs}" ]] || return 0
    # shellcheck disable=SC2086
    apt-mark unhold ${pkgs} >/dev/null 2>&1 || true
    info "released apt-mark holds on nvidia packages"
}

status_apt() {
    apt-mark showhold 2>/dev/null | grep -i nvidia | sed 's/^/  /' || echo "  (none)"
}

# -------------------------------------------------------------------- pacman --
#
# IgnorePkg only takes effect inside the [options] section, so the entry is
# inserted directly after it rather than appended to the end of the file.
#
pin_pacman() {
    local conf="/etc/pacman.conf" pkgs line
    pkgs="$(pac_pkgs | tr '\n' ' ')"
    pkgs="${pkgs% }"
    [[ -n "${pkgs}" ]] || { info "no nvidia packages installed — nothing to pin"; return 0; }

    if grep -q "${MARK_BEGIN}" "${conf}" 2>/dev/null; then
        unpin_pacman
    fi

    cp -a "${conf}" "${conf}.cmpunlocker.bak"
    line="IgnorePkg = ${pkgs}"
    awk -v b="${MARK_BEGIN}" -v e="${MARK_END}" -v l="${line}" '
        { print }
        /^\[options\]/ && !done { print b; print l; print e; done = 1 }
    ' "${conf}" > "${conf}.tmp" && mv "${conf}.tmp" "${conf}"

    #
    # An [options] section that awk never matched leaves the file unchanged,
    # and IgnorePkg outside that section is silently ignored by pacman.
    #
    if grep -q "${MARK_BEGIN}" "${conf}" 2>/dev/null; then
        info "added IgnorePkg for nvidia packages to ${conf} (backup: ${conf}.cmpunlocker.bak)"
        return 0
    fi
    info "FAILED to pin: no [options] section found in ${conf}"
    return 1
}

unpin_pacman() {
    local conf="/etc/pacman.conf"
    grep -q "${MARK_BEGIN}" "${conf}" 2>/dev/null || return 0
    sed -i "/${MARK_BEGIN}/,/${MARK_END}/d" "${conf}"
    info "removed IgnorePkg entry from ${conf}"
}

status_pacman() {
    grep -A1 "${MARK_BEGIN}" /etc/pacman.conf 2>/dev/null | grep IgnorePkg | sed 's/^/  /' || echo "  (none)"
}

# ------------------------------------------------------------------ dispatch --
detect() {
    if   command -v dnf     &>/dev/null && command -v rpm  &>/dev/null; then echo dnf
    elif command -v apt-mark &>/dev/null && command -v dpkg &>/dev/null; then echo apt
    elif command -v pacman  &>/dev/null;                                 then echo pacman
    else echo unknown
    fi
}

PM="$(detect)"

case "${ACTION}" in
    pin)
        [[ "${EUID}" -eq 0 ]] || { echo "must run as root" >&2; exit 1; }
        rc=0
        case "${PM}" in
            dnf)    pin_dnf    || rc=1 ;;
            apt)    pin_apt    || rc=1 ;;
            pacman) pin_pacman || rc=1 ;;
            *)      info "unknown package manager — pin the nvidia packages manually"; rc=1 ;;
        esac
        exit "${rc}"
        ;;
    unpin)
        [[ "${EUID}" -eq 0 ]] || { echo "must run as root" >&2; exit 1; }
        case "${PM}" in
            dnf)    unpin_dnf ;;
            apt)    unpin_apt ;;
            pacman) unpin_pacman ;;
            *)      : ;;
        esac
        ;;
    status)
        echo "package manager: ${PM}"
        echo "pinned nvidia packages:"
        case "${PM}" in
            dnf)    status_dnf ;;
            apt)    status_apt ;;
            pacman) status_pacman ;;
            *)      echo "  (unknown package manager)" ;;
        esac
        ;;
    *)
        echo "usage: $0 pin|unpin|status" >&2
        exit 1
        ;;
esac

exit 0
