#!/bin/bash
#
# cmpunlocker - Debian/Ubuntu/HiveOS kernel removal hook.
#
# Installed as /etc/kernel/postrm.d/cmpunlocker. Drops the patched modules for
# a kernel that is being removed so /lib/modules does not grow without bound.
#
set -uo pipefail

KVER="${1:-}"
[[ -n "${KVER}" ]] || exit 0

rm -rf "/lib/modules/${KVER}/updates/cmpunlocker"
rm -f  "/var/lib/cmpunlocker/state/failed-${KVER}"

exit 0
