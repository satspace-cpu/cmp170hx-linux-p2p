#!/bin/bash
#
# Write a saved timing snapshot back to the card.
#
#   timings-restore.sh out.txt      a file from timings-dump.sh
#   timings-restore.sh              the baseline taken on first use
#   GPU=1 timings-restore.sh        second card
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/_common.sh"

need_root
build_tool

if [[ $# -ge 1 ]]; then
    file="$1"
    [[ -f "${file}" ]] || die "no such snapshot: ${file}"
else
    file="$(baseline_file)"
    [[ -f "${file}" ]] || die "no baseline snapshot yet — pass a file, or run timings-set.sh first"
fi

"${REGS[@]}" load "${file}"
"${REGS[@]}" dump | sed -n '/^FIELD/,$p'
