#!/usr/bin/env bash
set -euo pipefail

found=0

for hwmon in /sys/class/hwmon/hwmon*; do
    [[ -r "${hwmon}/name" ]] || continue
    [[ "$(<"${hwmon}/name")" == "vram" ]] || continue
    found=1

    device="unknown"
    if [[ -L "${hwmon}/device" ]]; then
        device="$(basename "$(readlink -f "${hwmon}/device")")"
    fi

    printf '%s\n' "${device}:"
    for input in "${hwmon}"/temp*_input; do
        [[ -r "${input}" ]] || continue
        stem="${input%_input}"
        if [[ -r "${stem}_label" ]]; then
            label="$(<"${stem}_label")"
        else
            label="$(basename "${stem}")"
        fi
        millideg="$(<"${input}")"
        awk -v label="${label}" -v value="${millideg}" \
            'BEGIN { printf "  %-12s %.1f C\n", label ":", value / 1000 }'
    done
done

if [[ "${found}" -eq 0 ]]; then
    printf '%s\n' "No gpu-unlock VRAM hwmon sensors found." >&2
    exit 1
fi
