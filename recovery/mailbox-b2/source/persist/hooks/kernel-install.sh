#!/bin/bash
#
# cmpunlocker - systemd kernel-install hook (Fedora, RHEL, openSUSE, any distro
# using /etc/kernel/install.d).
#
# Installed as /etc/kernel/install.d/95-cmpunlocker.install.
#
# kernel-install calls this as:  <command> <kernel-version> [entry-dir] [image]
# Numbered 95 so it runs after 50-depmod.install and 50-dracut.install have
# populated the new module tree.
#
set -uo pipefail

COMMAND="${1:-}"
KVER="${2:-}"

[[ -n "${KVER}" ]] || exit 0

case "${COMMAND}" in
    add)
        [[ -x /usr/lib/cmpunlocker/rebuild.sh ]] || exit 0
        echo "cmpunlocker: building patched NVIDIA modules for ${KVER}..."
        /usr/lib/cmpunlocker/rebuild.sh "${KVER}"
        ;;
    remove)
        #
        # The kernel is going away, so its patched modules are dead weight.
        # Leaving them behind makes /lib/modules grow without bound.
        #
        rm -rf "/lib/modules/${KVER}/updates/cmpunlocker"
        rm -f  "/var/lib/cmpunlocker/state/failed-${KVER}"
        ;;
esac

exit 0
