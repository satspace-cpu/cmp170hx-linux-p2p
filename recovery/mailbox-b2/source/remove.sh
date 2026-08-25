#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; CYAN=""; NC=""
fi

info() { echo -e "${CYAN}==>${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
die()  { echo -e "${RED}✗${NC} $*" >&2; exit 1; }

echo ""
echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║               cmpunlocker              ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
echo ""

CONFIRMED=0
RELOAD_DRIVER=0
for arg in "$@"; do
    case "${arg}" in
        --yes|-y) CONFIRMED=1 ;;
        --reload) RELOAD_DRIVER=1 ;;
    esac
done

if (( CONFIRMED == 0 )); then
    warn "This removes cmpunlocker patched kernel modules:"
    echo "  - Removes /lib/modules/*/updates/cmpunlocker/"
    echo "  - Rebuilds initramfs"
    echo "  - Restores the pre-install kernel command line (reverts IOMMU changes)"
    echo "  - Removes the kernel-update hooks and the boot-time rebuild service"
    echo "  - Releases the NVIDIA package version pin"
    echo "  - Unmasks nvidia-fallback.service and unblocks nouveau"
    echo ""
    echo "  The driver already in memory is left alone — reboot to finish."
    echo "  Logs under /var/log/cmpunlocker/ are kept."
    echo ""
    echo "Run: sudo ./remove.sh --yes"
    echo ""
    echo "  --reload  also swap the running driver for the stock one now,"
    echo "            instead of at the next boot. On a CMP this can hang the"
    echo "            machine, so it is off by default — see README."
    exit 1
fi

[[ "${EUID}" -eq 0 ]] || die "Run as root: sudo ./remove.sh --yes"

LOG_DIR="${SCRIPT_DIR}/logs"
if ! mkdir -p "${LOG_DIR}" 2>/dev/null || [[ ! -w "${LOG_DIR}" ]]; then
    LOG_DIR="/tmp"
fi
LOG_FILE="${LOG_DIR}/remove_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "${LOG_FILE}") 2>&1

info "Reverting IOMMU kernel parameters..."
iommu_restored=0
for cfg in /etc/default/grub /etc/kernel/cmdline; do
    if [[ -f "${cfg}.cmpunlocker.bak" ]]; then
        mv -f "${cfg}.cmpunlocker.bak" "${cfg}"
        ok "Restored ${cfg} from pre-install backup"
        iommu_restored=1
    fi
done
if (( iommu_restored )); then
    if command -v update-grub &>/dev/null; then
        update-grub 2>/dev/null || true
    elif command -v grub2-mkconfig &>/dev/null; then
        grub2-mkconfig -o /boot/grub2/grub.cfg 2>/dev/null || true
    elif command -v grub-mkconfig &>/dev/null; then
        grub-mkconfig -o /boot/grub/grub.cfg 2>/dev/null || true
    fi
    ok "Reverted IOMMU kernel parameters (effective after reboot)"
else
    info "No IOMMU config backup found — kernel command line left as-is"
fi

info "Removing kernel-update persistence..."

#
# Unpin first: the helper that knows how to undo the hold lives in the
# directory removed a few lines further down.
#
if [[ -x /usr/lib/cmpunlocker/pin-packages.sh ]]; then
    /usr/lib/cmpunlocker/pin-packages.sh unpin || true
fi

if command -v systemctl &>/dev/null; then
    systemctl disable --now cmpunlocker-rebuild.service 2>/dev/null || true
    #
    # Unmask rather than enable: nvidia-fallback is the distro's unit and
    # whatever state it was in before the install is the distro's business.
    #
    systemctl unmask nvidia-fallback.service 2>/dev/null || true
fi

rm -f /etc/systemd/system/cmpunlocker-rebuild.service
rm -f /etc/kernel/install.d/95-cmpunlocker.install
rm -f /etc/kernel/postinst.d/cmpunlocker
rm -f /etc/kernel/postrm.d/cmpunlocker
rm -f /etc/pacman.d/hooks/95-cmpunlocker.hook
rm -f /etc/depmod.d/cmpunlocker.conf
rm -f /etc/modprobe.d/cmpunlocker.conf
rm -rf /usr/lib/cmpunlocker
rm -rf /var/lib/cmpunlocker
rm -rf /etc/cmpunlocker

if [[ -f /etc/pacman.conf.cmpunlocker.bak ]]; then
    mv -f /etc/pacman.conf.cmpunlocker.bak /etc/pacman.conf
    ok "Restored /etc/pacman.conf from pre-install backup"
fi

command -v systemctl &>/dev/null && systemctl daemon-reload 2>/dev/null || true
ok "Kernel hooks, boot service and package pins removed"

info "Removing patched modules..."
mod_removed=0
kernels_touched=()
shopt -s nullglob
for mod_dir in /lib/modules/*/updates/cmpunlocker; do
    if [[ -d "${mod_dir}" ]]; then
        kernel="$(basename "$(dirname "$(dirname "${mod_dir}")")")"
        rm -rf "${mod_dir}"
        depmod -a "${kernel}" 2>/dev/null || true
        #
        # depmod's output sits in the page cache until something flushes it.
        # A power cut or hard reset before that leaves a zero-length
        # modules.dep, and then nothing resolves on the next boot - not the
        # NIC driver, not storage. Cheap insurance against an unbootable box.
        #
        sync
        ok "Removed patched modules for kernel ${kernel}"
        mod_removed=$((mod_removed + 1))
        kernels_touched+=("${kernel}")
    fi
done
[[ "${mod_removed}" -gt 0 ]] || warn "No patched kernel modules found"

if [[ ${#kernels_touched[@]} -gt 0 ]]; then
    info "Rebuilding initramfs..."
    for kernel in "${kernels_touched[@]}"; do
        if command -v update-initramfs &>/dev/null; then
            update-initramfs -u -k "${kernel}" 2>/dev/null || true
        elif command -v dracut &>/dev/null; then
            dracut --force --kver "${kernel}" 2>/dev/null || true
        fi
    done
    if command -v mkinitcpio &>/dev/null && ! command -v update-initramfs &>/dev/null && ! command -v dracut &>/dev/null; then
        mkinitcpio -P 2>/dev/null || true
    fi
    ok "initramfs rebuilt"
fi

#
# Swapping the running driver is opt-in, because loading the stock one on a
# CMP 170HX can wedge the machine: the card has no usable display engine, and
# nvidia-drm binding to it hangs in a way that leaves the kernel answering
# pings while userspace stops making progress. Nothing needs the swap either -
# the files are already gone, so the next boot comes up on the stock driver by
# itself, and a reboot is the documented last step of an uninstall anyway.
#
if (( RELOAD_DRIVER == 0 )); then
    if lsmod | grep -q '^nvidia'; then
        info "Leaving the running driver in place"
        echo "  The patched modules are removed from disk, but the copy already in"
        echo "  memory keeps running until you reboot. That is the safe order."
        echo "  ./remove.sh --yes --reload swaps it now instead, at the risk of"
        echo "  hanging the machine on a CMP."
    fi
else
    info "Swapping the running driver for the stock one (--reload)..."
    warn "This can hang on a CMP 170HX. Reboot instead if it does not return."

    for svc in gdm3 sddm lightdm display-manager; do
        systemctl stop "${svc}" 2>/dev/null || true
    done
    systemctl stop nvidia-persistenced 2>/dev/null || true
    killall -9 Xorg Xwayland nvidia-persistenced 2>/dev/null || true
    sleep 1

    #
    # No rmmod -f fallback: forcing a module out from under a driver that is
    # still referenced is documented as able to take the kernel down with it,
    # which is a poor trade when a reboot finishes the job cleanly.
    #
    for mod in nvidia_drm nvidia_uvm nvidia_modeset nvidia; do
        timeout 30 modprobe -r "${mod}" 2>/dev/null || true
    done
    sleep 1

    if lsmod | grep -q '^nvidia'; then
        warn "Some NVIDIA modules are still in use — reboot to finish cleanup"
    elif timeout 60 modprobe nvidia 2>/dev/null; then
        timeout 30 modprobe nvidia-modeset 2>/dev/null || true
        timeout 30 modprobe nvidia-uvm 2>/dev/null || true
        timeout 30 modprobe nvidia-drm 2>/dev/null || \
            warn "nvidia-drm did not load — harmless on a headless card"
        ok "Stock NVIDIA driver loaded"
    else
        warn "Stock driver did not load — reboot to finish cleanup"
    fi

    for svc in gdm3 sddm lightdm display-manager; do
        if systemctl is-enabled --quiet "${svc}" 2>/dev/null; then
            systemctl start "${svc}" 2>/dev/null || true
            break
        fi
    done
fi

echo ""
ok "cmpunlocker removed"
echo "Log saved to: ${LOG_FILE}"
echo ""
echo "Reboot to finish — the card comes back up on the stock driver:"
echo -e "  ${CYAN}sudo reboot${NC}"
echo ""
