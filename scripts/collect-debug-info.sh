#!/usr/bin/env bash
set -u

OUT="${1:-cmp170hx-p2p-debug.txt}"

{
    echo "CMP 170HX P2P debug report"
    echo "Generated: $(date -Is 2>/dev/null || date)"
    echo

    echo "==== uname ===="
    uname -a
    echo

    echo "==== cmdline ===="
    cat /proc/cmdline
    echo

    echo "==== nvidia-smi ===="
    nvidia-smi 2>&1 || true
    echo

    echo "==== GPU inventory ===="
    nvidia-smi --query-gpu=index,name,memory.total,pci.bus_id,driver_version --format=csv 2>&1 || true
    echo

    echo "==== topology ===="
    nvidia-smi topo -m 2>&1 || true
    echo

    echo "==== P2P read ===="
    nvidia-smi topo -p2p r 2>&1 || true
    echo

    echo "==== P2P write ===="
    nvidia-smi topo -p2p w 2>&1 || true
    echo

    echo "==== P2P PCIe atomics ===="
    nvidia-smi topo -p2p p 2>&1 || true
    echo

    echo "==== lspci tree ===="
    lspci -t 2>&1 || true
    echo

    echo "==== NVIDIA PCIe link state ===="
    if command -v lspci >/dev/null 2>&1; then
        while read -r bdf; do
            [ -n "$bdf" ] || continue
            echo "-- $bdf --"
            lspci -vv -s "$bdf" 2>/dev/null | grep -E 'LnkCap:|LnkSta:|Region 0:|Region 1:|Resizable BAR|BAR [013]:' || true
        done < <(lspci -Dnnd 10de: 2>/dev/null | awk '{print $1}')
    fi
    echo

    echo "==== IOMMU groups ===="
    if [ -d /sys/kernel/iommu_groups ]; then
        find /sys/kernel/iommu_groups -maxdepth 1 -mindepth 1 -type d 2>/dev/null | sort -V
    fi
    echo

    echo "==== BAR1 usage ===="
    nvidia-smi -q 2>/dev/null | grep -i -A4 -B2 'BAR1 Memory Usage' || true
    echo

    echo "==== recent NVIDIA kernel messages ===="
    if command -v sudo >/dev/null 2>&1; then
        sudo dmesg 2>/dev/null | grep -Ei 'NVRM|NVIDIA|CMPP2PDBG|nvAssert|IOMMU|DMAR' | tail -200 || true
    else
        dmesg 2>/dev/null | grep -Ei 'NVRM|NVIDIA|CMPP2PDBG|nvAssert|IOMMU|DMAR' | tail -200 || true
    fi
} > "$OUT"

printf 'Saved: %s\n' "$OUT"
printf 'Review the file before posting it publicly; system logs may contain host-specific details.\n'
