#!/usr/bin/env bash
set -euo pipefail

[[ ${EUID} -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }
snapshot=${1:?Usage: sudo rollback-snapshot.sh /path/to/snapshot}
kver=$(uname -r)
dst="/lib/modules/$kver/updates/cmpunlocker"

for name in nvidia nvidia-modeset nvidia-drm nvidia-uvm nvidia-peermem; do
    [[ -f "$snapshot/modules/$name.ko" ]] || { echo "Missing $name.ko" >&2; exit 1; }
    install -m 0644 "$snapshot/modules/$name.ko" "$dst/$name.ko"
done

if [[ -f "$snapshot/cmp170-bayley-p2p.conf" ]]; then
    install -m 0644 "$snapshot/cmp170-bayley-p2p.conf" /etc/modprobe.d/
elif [[ -f "$snapshot/config/cmp170-bayley-p2p.conf" ]]; then
    install -m 0644 "$snapshot/config/cmp170-bayley-p2p.conf" /etc/modprobe.d/
else
    rm -f /etc/modprobe.d/cmp170-bayley-p2p.conf
fi

depmod "$kver"
cp -a "$snapshot/initrd.img-$kver" "/boot/initrd.img-$kver"
echo "Snapshot restored. Reboot required."
