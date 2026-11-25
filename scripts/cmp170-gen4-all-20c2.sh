#!/usr/bin/env bash
# One Gen3 -> runtime E1 -> Gen4 attempt per detected 10de:20c2 card.
# Requires the validated 20c2 helper tools installed in /usr/local/sbin.
set -uo pipefail

for _ in $(seq 1 60); do
    nvidia-smi -L >/dev/null 2>&1 && break
    sleep 1
done

rc=0
found=0
for dev in /sys/bus/pci/devices/0000:*:00.0; do
    [[ -r "$dev/vendor" && -r "$dev/device" ]] || continue
    [[ $(<"$dev/vendor") == 0x10de && $(<"$dev/device") == 0x20c2 ]] || continue
    bdf=$(basename "$dev")
    found=1
    /usr/local/sbin/cmp-gen3-20c2 "$bdf" || { rc=1; continue; }
    /usr/bin/python3 -I /usr/local/sbin/cmp-gen4-e1-20c2 "$bdf" --apply || { rc=1; continue; }
    /usr/local/sbin/cmp-gen4-20c2 "$bdf" || rc=1
done

(( found == 1 )) || exit 1
exit "$rc"
