#!/usr/bin/env bash
set -euo pipefail

[[ ${EUID} -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }
[[ ${1:-} == --yes ]] || { echo "Usage: sudo $0 --yes" >&2; exit 2; }

kver=$(uname -r)
[[ $kver == 7.0.12-cmp170bar1test ]] || { echo "Unexpected kernel: $kver" >&2; exit 1; }

root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
src="$root/source/driver/.build/open-gpu-kernel-modules-610.43.03/kernel-open"
dst="/lib/modules/$kver/updates/cmpunlocker"
stamp=$(date +%Y%m%d-%H%M%S)
backup="/home/server/cmp170-work/rollback-before-mailbox-$stamp"

for name in nvidia nvidia-modeset nvidia-drm nvidia-uvm nvidia-peermem; do
    [[ -f "$src/$name.ko" ]] || { echo "Missing $src/$name.ko" >&2; exit 1; }
    modinfo "$src/$name.ko" | grep -q "vermagic:.*$kver" || {
        echo "vermagic mismatch: $name.ko" >&2; exit 1;
    }
done

mkdir -p "$backup/modules"
cp -a "$dst"/nvidia*.ko "$backup/modules/"
cp -a "/boot/initrd.img-$kver" "$backup/"
cp -a /etc/modprobe.d/cmp170-bayley-p2p.conf "$backup/" 2>/dev/null || true
sha256sum "$backup"/modules/nvidia*.ko > "$backup/module-sha256.txt"

rm -f /etc/modprobe.d/cmp170-bayley-p2p.conf
for name in nvidia nvidia-modeset nvidia-drm nvidia-uvm nvidia-peermem; do
    install -m 0644 "$src/$name.ko" "$dst/$name.ko"
done
depmod "$kver"
update-initramfs -u -k "$kver"

echo "Mailbox modules installed. Backup: $backup"
echo "Reboot, then follow MAILBOX-B2-RECOVERY.ru.md validation steps."

