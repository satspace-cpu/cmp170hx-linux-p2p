#!/bin/bash
#
# Set DRAM timings: individual fields, or a percentage scale.
#
#   timings-set.sh RAS 45                one field
#   timings-set.sh RAS 45 RP 28          several at once
#   timings-set.sh --scale 20            loosen the safe set by 20%
#   timings-set.sh --scale -10           tighten it by 10%
#   timings-set.sh --stock               back to the baseline snapshot
#   GPU=1 timings-set.sh --scale 20      second card
#
# --scale always computes from the baseline snapshot taken the first time this
# script runs, so applying it twice does not compound.
#
# Scaled by --scale: tRC tRFC tRAS tRP tRCD tWR tFAW tRRD.
# Never scaled: CL and WL (they must match what is trained into the HBM
# stacks) and tCCD (the only timing that binds bandwidth, already at its floor).
#
# Tightening can corrupt data silently or wedge the memory controller, and
# writing the old value back does not recover it - only a reboot does.
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/_common.sh"

usage() { sed -n '2,/^set -e/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit "${1:-0}"; }
[[ $# -eq 0 || "${1:-}" == "-h" || "${1:-}" == "--help" ]] && usage

need_root
build_tool

case "$1" in
--stock)
    base="$(baseline_file)"
    [[ -f "${base}" ]] || die "no baseline snapshot yet — nothing to restore"
    "${REGS[@]}" load "${base}"
    "${REGS[@]}" dump | sed -n '/^FIELD/,$p'
    ;;

--scale)
    [[ $# -eq 2 ]] || die "--scale takes one percentage, e.g. --scale 20"
    pct="$2"
    [[ "${pct}" =~ ^-?[0-9]+$ ]] || die "percentage must be an integer (got '${pct}')"
    (( pct >= -50 && pct <= 50 )) || die "percentage must be between -50 and 50"

    base="$(ensure_baseline)"

    (( pct < 0 )) && echo "tightening by ${pct#-}% — validate with gpu-burn before trusting it"

    # Always start from the baseline so repeated runs are idempotent.
    "${REGS[@]}" load "${base}" >/dev/null 2>&1

    for f in "${SCALABLE[@]}"; do
        stock="$("${REGS[@]}" get "${f}")" || continue
        target=$(( stock + (stock * pct) / 100 ))
        (( target < 1 )) && target=1
        if (( target == stock )); then
            printf '%-8s %4d unchanged\n' "${f}" "${stock}"
            continue
        fi
        printf '%-8s %4d -> %-4d ' "${f}" "${stock}" "${target}"
        "${REGS[@]}" set "${f}" "${target}" >/dev/null 2>&1 && echo "ok" || echo "FAILED"
    done
    ;;

-*)
    die "unknown option '$1' (see --help)"
    ;;

*)
    (( $# % 2 == 0 )) || die "fields come in NAME VALUE pairs"
    ensure_baseline >/dev/null
    while [[ $# -ge 2 ]]; do
        "${REGS[@]}" set "$1" "$2"
        shift 2
    done
    ;;
esac
