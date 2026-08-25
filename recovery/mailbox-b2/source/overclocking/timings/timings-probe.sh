#!/bin/bash
#
# Find which timings actually bind performance on this card.
#
# Each field is loosened on its own, bandwidth is measured, then the field is
# put back. Loosening only ever grants the DRAM more time, so this maps the
# card out with no risk of a hang - unlike tightening, which is how you find
# the floor the hard way.
#
#   timings-probe.sh          probe every field
#   timings-probe.sh RP WR     probe just these
#   GPU=1 timings-probe.sh     second card
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/_common.sh"

need_root
build_tool
[[ -x "${BENCH}" ]] || die "benchmark not found at ${BENCH}"

# field:multiplier - how far to loosen each one for the probe
PROBES=(
    RC:1.8 RFC:1.2 RAS:1.6 RP:1.6 RD_RCD:1.6 WR_RCD:1.7
    WR:1.8 FAW:2.0 RRD:2.0 W2R_BUS:1.7 R2W_BUS:1.7 CCDL:2.5 CCDS:3.0
)

measure() {
    "${BENCH}" 2>/dev/null | awk '
        /Global Read Bandwidth/ { r=$4 }
        /Global Copy Bandwidth/ { c=$4 }
        END { printf "%.0f %.0f", r, c }'
}

ensure_baseline >/dev/null
read -r BR BC < <(measure)
printf 'baseline   read %s  copy %s GB/s\n\n' "${BR}" "${BC}"
printf '%-8s %-12s %6s %6s   %s\n' FIELD CHANGE READ COPY 'DELTA read/copy'

for entry in "${PROBES[@]}"; do
    f="${entry%%:*}"
    mult="${entry##*:}"

    # Only probe what the caller asked for, if they asked.
    if [[ $# -gt 0 ]]; then
        want=0
        for a in "$@"; do [[ "${a^^}" == "${f}" ]] && want=1; done
        (( want )) || continue
    fi

    stock="$("${REGS[@]}" get "${f}" 2>/dev/null)" || continue
    loose="$(awk -v s="${stock}" -v m="${mult}" 'BEGIN{printf "%d", s*m}')"
    (( loose <= stock )) && loose=$(( stock + 1 ))

    "${REGS[@]}" set "${f}" "${loose}" >/dev/null 2>&1 || { echo "${f}: set failed"; continue; }
    read -r R C < <(measure)
    "${REGS[@]}" set "${f}" "${stock}" >/dev/null 2>&1

    printf '%-8s %-12s %6s %6s   %+d / %+d\n' \
        "${f}" "${stock}->${loose}" "${R}" "${C}" "$((R - BR))" "$((C - BC))"
done

echo
echo "restored:"
"${REGS[@]}" dump | sed -n '/^FIELD/,$p'
