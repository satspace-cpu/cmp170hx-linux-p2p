#!/bin/bash
#
# cmpunlocker - Arch pacman hook trigger.
#
# Installed to /usr/lib/cmpunlocker/pacman-trigger.sh. pacman feeds the matched
# target paths on stdin (usr/lib/modules/<ver>/vmlinuz), one per line.
#
# A kernel that was removed in the same transaction leaves its path on stdin
# too, so each version is checked for existence rather than assumed present.
#
set -uo pipefail

[[ -x /usr/lib/cmpunlocker/rebuild.sh ]] || exit 0

while read -r target; do
    kver="${target#usr/lib/modules/}"
    kver="${kver%/vmlinuz}"
    [[ -n "${kver}" ]] || continue

    if [[ -d "/usr/lib/modules/${kver}" ]]; then
        echo "cmpunlocker: building patched NVIDIA modules for ${kver}..."
        /usr/lib/cmpunlocker/rebuild.sh "${kver}"
    else
        #
        # Kernel removed: drop its patched modules so /usr/lib/modules does not
        # accumulate trees for kernels that can no longer boot.
        #
        rm -rf "/usr/lib/modules/${kver}/updates/cmpunlocker"
        rm -f  "/var/lib/cmpunlocker/state/failed-${kver}"
    fi
done

exit 0
