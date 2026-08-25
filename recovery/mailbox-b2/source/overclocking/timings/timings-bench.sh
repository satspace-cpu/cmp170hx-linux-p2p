#!/bin/bash
#
# Average N benchmark runs, so an effect smaller than the run-to-run noise
# can be told apart from it.
#
#   timings-bench.sh          3 runs
#   timings-bench.sh 5        5 runs
#
# Prints: read_mean read_sd copy_mean copy_sd   (GB/s)
#
# Note: the benchmark's "Memory Latency" figure does not move with timings at
# all - it is dominated by page walks. Tune against these bandwidth numbers.
#
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "${HERE}/_common.sh"

[[ -x "${BENCH}" ]] || die "benchmark not found at ${BENCH} (see benchmark/README or build it)"
N="${1:-3}"

for ((i = 0; i < N; i++)); do
    "${BENCH}" 2>/dev/null | awk '
        /Global Read Bandwidth/ { r=$4 }
        /Global Copy Bandwidth/ { c=$4 }
        END { print r, c }'
done | awk '
{ r[NR]=$1; c[NR]=$2; sr+=$1; sc+=$2 }
END {
    n=NR
    if (n == 0) { print "no benchmark output"; exit 1 }
    mr=sr/n; mc=sc/n
    for (i=1; i<=n; i++) { vr+=(r[i]-mr)^2; vc+=(c[i]-mc)^2 }
    printf "read %.1f +/- %.1f   copy %.1f +/- %.1f  GB/s  (%d runs)\n",
           mr, (n>1?sqrt(vr/(n-1)):0), mc, (n>1?sqrt(vc/(n-1)):0), n
}'
