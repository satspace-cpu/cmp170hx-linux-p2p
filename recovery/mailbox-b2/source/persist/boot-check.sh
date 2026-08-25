#!/bin/bash
#
# cmpunlocker - boot-time safety net.
#
# Installed to /usr/lib/cmpunlocker/boot-check.sh, run by
# cmpunlocker-rebuild.service before multi-user.target.
#
# The kernel-update hooks are the normal path and they run before the reboot,
# so in the common case this exits in milliseconds. It exists for the cases the
# hooks cannot cover: a hand-built kernel, a restored snapshot, a distro whose
# hook directory is not one of the three supported ones, or a hook that failed
# because the headers were not unpacked yet.
#
set -uo pipefail

KVER="$(uname -r)"
MODULE="/lib/modules/${KVER}/updates/cmpunlocker/nvidia.ko"
STATE_DIR="/var/lib/cmpunlocker/state"
ATTEMPTS="${STATE_DIR}/boot-attempts-${KVER}"
MAX_ATTEMPTS=3

log() { echo "cmpunlocker: $*"; }

# Fast path: patched modules already present for this kernel. No boot delay.
if [[ -f "${MODULE}" ]]; then
    exit 0
fi

mkdir -p "${STATE_DIR}" 2>/dev/null || true

#
# A build that fails for a permanent reason (unsupported driver version, no
# compiler) would otherwise add its full runtime to every single boot, forever.
# After MAX_ATTEMPTS stop blocking and leave it to the operator.
#
count=0
[[ -r "${ATTEMPTS}" ]] && count="$(cat "${ATTEMPTS}" 2>/dev/null || echo 0)"
[[ "${count}" =~ ^[0-9]+$ ]] || count=0

if (( count >= MAX_ATTEMPTS )); then
    log "patched modules missing for ${KVER} and ${count} rebuilds already failed"
    log "not blocking boot again — fix the cause and run: sudo /usr/lib/cmpunlocker/rebuild.sh"
    log "log: /var/log/cmpunlocker/rebuild-${KVER}.log"
    exit 0
fi

echo "$((count + 1))" > "${ATTEMPTS}"

log "patched modules missing for ${KVER} — rebuilding before boot continues"
log "this takes a few minutes; the GPU would otherwise come up unpatched"

/usr/lib/cmpunlocker/rebuild.sh "${KVER}"

if [[ ! -f "${MODULE}" ]]; then
    log "rebuild did not produce ${MODULE}"
    log "booting on the stock driver — see /var/log/cmpunlocker/rebuild-${KVER}.log"
    exit 0
fi

rm -f "${ATTEMPTS}"

#
# The modules exist now, but udev may already have autoloaded the stock driver
# during early boot. Nothing has opened /dev/nvidia* this early (no X, no
# persistenced yet), so swapping it out here avoids a second reboot.
#
if lsmod | grep -q '^nvidia'; then
    log "swapping the stock driver out for the patched one"
    for mod in nvidia_drm nvidia_uvm nvidia_modeset nvidia; do
        modprobe -r "${mod}" 2>/dev/null || true
    done
    sleep 1
fi

if modprobe nvidia 2>/dev/null; then
    modprobe nvidia-modeset 2>/dev/null || true
    modprobe nvidia-uvm 2>/dev/null || true
    modprobe nvidia-drm 2>/dev/null || true
    log "patched modules loaded for ${KVER}"
else
    log "patched modules built but not loaded — reboot to apply"
fi

exit 0
