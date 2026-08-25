# Shared bits for the timing scripts. Sourced, never run directly.
# The caller sets HERE to its own directory before sourcing.

TOOL="${HERE}/fbpa_regs"
REPO="$(cd "${HERE}/../.." && pwd)"
BENCH="${REPO}/benchmark/nvidia_bench"

# GPU index from `fbpa_regs list`; override with GPU=1 in the environment.
GPU="${GPU:-0}"
REGS=("${TOOL}" -g "${GPU}")

die() { echo "error: $*" >&2; exit 1; }

# Build the tool on first use so nobody has to remember a compile step.
build_tool() {
    [[ -x "${TOOL}" && "${TOOL}" -nt "${HERE}/fbpa_regs.c" ]] && return 0
    command -v gcc >/dev/null || die "gcc not found, cannot build fbpa_regs"
    gcc -O2 -o "${TOOL}" "${HERE}/fbpa_regs.c" || die "failed to build fbpa_regs"
}

need_root() {
    [[ "${EUID}" -eq 0 ]] || die "run as root (BAR0 access)"
}

# Per-GPU baseline snapshot. Everything scales from this rather than from the
# current register values, so re-running a scale cannot compound.
baseline_file() {
    local bdf
    bdf="$("${TOOL}" list 2>/dev/null | awk -v g="${GPU}" '$1 == g {print $2}')"
    [[ -n "${bdf}" ]] || die "GPU index ${GPU} not found (try: ${TOOL##*/} list)"
    echo "${HERE}/baseline-${bdf}.txt"
}

# Prints only the path on stdout; notices go to stderr so it stays substitutable.
ensure_baseline() {
    local f
    f="$(baseline_file)" || exit 1
    if [[ ! -f "${f}" ]]; then
        "${REGS[@]}" save "${f}" >/dev/null 2>&1 || die "could not snapshot baseline"
        echo "baseline saved: ${f##*/}" >&2
    fi
    echo "${f}"
}

# Timings that mean "wait longer before the next command" - safe to scale.
# CL and WL are excluded: they say when to sample data and must match what is
# trained into the HBM stacks. tCCD is excluded: it is the only timing that
# binds streaming bandwidth and already sits at the hardware floor.
SCALABLE=(RC RFC RAS RP RD_RCD WR_RCD WR FAW RRD)
