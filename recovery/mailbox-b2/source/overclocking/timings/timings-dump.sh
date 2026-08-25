#!/bin/bash
#
# Snapshot the DRAM timings.
#
#   timings-dump.sh                 print the decoded table
#   timings-dump.sh out.txt         also write a restorable snapshot
#   GPU=1 timings-dump.sh           second card
#
# The written file is restorable with: timings-restore.sh out.txt
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/_common.sh"

need_root
build_tool

"${REGS[@]}" dump

if [[ $# -ge 1 ]]; then
    "${REGS[@]}" save "$1"
    echo "restore with: ${0##*/} -> timings-restore.sh $1"
fi
