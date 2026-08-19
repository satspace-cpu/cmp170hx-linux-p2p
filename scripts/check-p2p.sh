#!/usr/bin/env bash
set -u

say() { printf '%s\n' "$*"; }
section() { printf '\n==== %s ====\n' "$*"; }

section "System"
uname -a
printf 'cmdline: '
cat /proc/cmdline

section "NVIDIA driver and GPUs"
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=index,name,memory.total,pci.bus_id,driver_version --format=csv
else
    say "nvidia-smi not found"
fi

section "PCIe topology"
if command -v lspci >/dev/null 2>&1; then
    lspci -t
else
    say "lspci not found (install pciutils)"
fi

section "PCIe link state for NVIDIA devices"
if command -v lspci >/dev/null 2>&1; then
    while read -r bdf; do
        [ -n "$bdf" ] || continue
        say "-- $bdf --"
        lspci -vv -s "$bdf" 2>/dev/null | grep -E 'LnkCap:|LnkSta:' || true
    done < <(lspci -Dnnd 10de: 2>/dev/null | awk '{print $1}')
fi

section "IOMMU"
if grep -qE '(^| )intel_iommu=off( |$)' /proc/cmdline && grep -qE '(^| )iommu=off( |$)' /proc/cmdline; then
    say "Kernel command line: IOMMU explicitly disabled"
else
    say "Kernel command line: IOMMU is NOT explicitly disabled"
fi

if [ -d /sys/kernel/iommu_groups ]; then
    groups=$(find /sys/kernel/iommu_groups -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
    say "Visible IOMMU groups: $groups"
else
    say "No /sys/kernel/iommu_groups directory"
fi

section "NVIDIA P2P topology"
if command -v nvidia-smi >/dev/null 2>&1; then
    say "-- read --"
    nvidia-smi topo -p2p r 2>&1 || true
    say "-- write --"
    nvidia-smi topo -p2p w 2>&1 || true
    say "-- PCIe atomics --"
    nvidia-smi topo -p2p p 2>&1 || true
fi

section "ACS controls"
if command -v lspci >/dev/null 2>&1; then
    while read -r bdf; do
        out=$(lspci -vv -s "$bdf" 2>/dev/null | grep -E 'ACSCap:|ACSCtl:' || true)
        if [ -n "$out" ]; then
            say "-- $bdf --"
            printf '%s\n' "$out"
        fi
    done < <(lspci -D 2>/dev/null | awk '{print $1}')
fi

section "BAR1"
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi -q 2>/dev/null | grep -i -A4 -B2 'BAR1 Memory Usage' || true
fi

section "Next step"
say "Run NVIDIA p2pBandwidthLatencyTest and compare P2P Enabled vs Disabled bandwidth."
say "Healthy tested CMP 170HX Gen2 x16 result: ~6.4-6.7 GB/s one-way, ~13 GB/s bidirectional, ~1.6 us GPU latency."
say "This script is read-only and does not change GRUB, ACS, IOMMU or driver settings."
