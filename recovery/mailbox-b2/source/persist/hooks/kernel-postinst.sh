#!/bin/bash
#
# cmpunlocker - Debian/Ubuntu/HiveOS kernel hook.
#
# Installed as /etc/kernel/postinst.d/cmpunlocker.
#
# Called as:  <kernel-version> <kernel-image-path>
#
# On Debian the headers package is sometimes unpacked after the image, so the
# build here can legitimately fail with "headers not installed yet".
# rebuild.sh records that and cmpunlocker-rebuild.service retries at boot.
#
set -uo pipefail

KVER="${1:-}"

[[ -n "${KVER}" ]] || exit 0
[[ -x /usr/lib/cmpunlocker/rebuild.sh ]] || exit 0

echo "cmpunlocker: building patched NVIDIA modules for ${KVER}..."
/usr/lib/cmpunlocker/rebuild.sh "${KVER}"

exit 0
