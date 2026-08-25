#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mapfile -t SUPPORTED_VERSIONS < <(grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' "${SCRIPT_DIR}/driver/VERSION")
SUPPORTED_VERSIONS_CSV="$(IFS=', '; echo "${SUPPORTED_VERSIONS[*]}")"
LOG_DIR="${SCRIPT_DIR}/logs"
mkdir -p "${LOG_DIR}"
LOG_FILE="${LOG_DIR}/install_$(date +%Y%m%d_%H%M%S).log"

CONFIGURE_IOMMU=1
MCLK_NDIV=""
MCLK_TIMINGS=""
ENABLE_P2P=""
INSTALL_PERSIST=1
PIN_PACKAGES=1
VERBOSE=0
for arg in "$@"; do
    case "${arg}" in
        --no-iommu) CONFIGURE_IOMMU=0 ;;
        --mclk-ndiv=*) MCLK_NDIV="${arg#*=}" ;;
        --mclk-timings=*) MCLK_TIMINGS="${arg#*=}" ;;
        --p2p) ENABLE_P2P=1 ;;
        --no-persist) INSTALL_PERSIST=0 ;;
        --no-pin) PIN_PACKAGES=0 ;;
        -v|--verbose) VERBOSE=1 ;;
        -h|--help)
            cat <<'EOF'
Usage: sudo ./install.sh [--mclk-ndiv=N] [--mclk-timings=N] [--p2p]
                         [--no-iommu] [--no-persist] [--no-pin] [-v]

  --no-iommu      Do not add iommu=pt to the kernel command line. IOMMU
                  passthrough is enabled by default — it has negligible overhead
                  and is required for VM passthrough. Use this flag only if your
                  system has BIOS/firmware IOMMU bugs.
  -v, --verbose   Show the full build output instead of a progress bar. The
                  build log is kept either way, and is printed automatically
                  if something fails.
  --p2p           Force GPU-to-GPU P2P on. GSP reports it as unsupported on a
                  CMP; this overrides that. Off by default because the override
                  only makes the driver *advertise* P2P — where the host cannot
                  actually carry it, transfers time out instead of falling back
                  to staging through system memory. Enable it, then verify with
                  a real peer-to-peer transfer before relying on it.
  --mclk-ndiv=N   HBM memory clock: set PLL multiplier (30-80), N * 27 MHz.
                  Works on any VBIOS, on both 0x20C2 and 0x2082. Stock is 64 on
                  8GB 300W, 54 on 8GB 250W, 45 on 10GB. Without this flag the
                  overclock is not applied at all.
  --mclk-timings=N
                  Scale DRAM timings by N percent, -50 to +50. Positive loosens,
                  negative tightens (--mclk-timings=-10). Applied before the
                  clock is raised. Timings are cycle counts, so a higher clock
                  tightens them in real time; loosening gives that margin back
                  and can make an otherwise unstable --mclk-ndiv hold.
                  Tightening is the risky direction: too small a value corrupts
                  data silently or wedges the memory controller.
                  Scaled: tRC tRFC tRAS tRP tRCD tWR tFAW tRRD.
                  Never touched: CL, WL, tCCD.
  --no-persist    Do not survive kernel updates. By default the installer wires
                  the patched modules into the kernel-update path, so a new
                  kernel gets them rebuilt automatically instead of booting on
                  the stock driver (8GB) or falling back to nouveau. Use this
                  only if you manage module rebuilds yourself.
  --no-pin        Do not pin the NVIDIA packages. By default they are held at
                  the currently installed version, because a driver upgrade to
                  a version cmpunlocker does not support makes every later
                  rebuild fail and drops the card back to stock. With this flag
                  the packages upgrade freely and you take that risk on.

Surviving kernel updates (on by default):
  A kernel update rebuilds the patched modules through a package-manager hook
  (/etc/kernel/install.d, /etc/kernel/postinst.d, or a pacman hook) before you
  reboot. cmpunlocker-rebuild.service is the safety net for anything the hook
  misses — it holds boot until the modules exist rather than letting the card
  come up unpatched. Check state with:

    systemctl status cmpunlocker-rebuild
    sudo /usr/lib/cmpunlocker/pin-packages.sh status
    cat /var/log/cmpunlocker/rebuild-$(uname -r).log

Memory geometry is selected automatically from PCI device ID:
  10de:20c2 → 8GB card → 64GB unlock
  10de:2082 → 10GB card → 40GB unlock

Multi-GPU and mixed 8GB+10GB systems are supported.
EOF
            exit 0
            ;;
        *)
            echo "Unknown argument: ${arg}" >&2
            echo "Try: sudo ./install.sh --help" >&2
            exit 1
            ;;
    esac
done

#
# Decide on colour before stdout becomes a pipe into tee - checking -t 1 after
# the redirect below always says "not a terminal" and silently kills colour.
#
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
    DIM='\033[2m'; NC='\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; CYAN=""; DIM=""; NC=""
fi

# Progress goes straight to the terminal, so it never reaches the log.
TTY_OUT=""
{ : > /dev/tty; } 2>/dev/null && TTY_OUT=/dev/tty

# Colour is for the terminal; the log gets it stripped so it stays greppable.
exec > >(tee >(sed -u 's/\x1b\[[0-9;]*[mK]//g' >> "${LOG_FILE}")) 2>&1

info() { echo -e "${CYAN}==>${NC} $*"; }
ok()   { echo -e "${GREEN}✓${NC} $*"; }
warn() { echo -e "${YELLOW}!${NC} $*"; }
err()  { echo -e "${RED}✗${NC} $*" >&2; }
die()  { err "$*"; exit 1; }

STEP_TOTAL=6
STEP_NOW=0

progress_bar() {
    local cur="$1" tot="$2" w="${3:-20}" filled i out=""
    (( tot > 0 )) || tot=1
    filled=$(( cur * w / tot ))
    (( filled > w )) && filled=${w}
    for ((i = 0; i < w; i++)); do
        if (( i < filled )); then out+="█"; else out+="░"; fi
    done
    printf '%s %3d%%' "${out}" $(( cur * 100 / tot ))
}

step() {
    STEP_NOW=$((STEP_NOW + 1))
    echo ""
    echo -e "${CYAN}[${STEP_NOW}/${STEP_TOTAL}]${NC} ${DIM}$(progress_bar "${STEP_NOW}" "${STEP_TOTAL}")${NC}  ${CYAN}$*${NC}"
}

#
# Anything that falls over without its own message still has to say where it
# happened and where to look, rather than just exiting on set -e.
#
on_error() {
    local rc=$? line="$1"
    [[ -n "${TTY_OUT}" ]] && printf '\r\033[K' > "${TTY_OUT}"
    echo ""
    err "Install failed at ${0##*/} line ${line} (exit ${rc})"
    err "Full log: ${LOG_FILE}"
    exit "${rc}"
}
trap 'on_error ${LINENO}' ERR

#
# Ask a yes/no question. Reads from the terminal rather than stdin, because
# stdout is piped through tee and the script may be run from a pipe.
# Returns non-zero when the answer is no or when there is nobody to ask.
#
confirm() {
    local reply="" prompt
    prompt="$(echo -e "${YELLOW}?${NC} $* [y/N] ")"
    #
    # -r is not enough: /dev/tty exists but fails to open when there is no
    # controlling terminal, so probe it by actually opening it.
    #
    if { : < /dev/tty; } 2>/dev/null; then
        read -r -p "${prompt}" reply < /dev/tty || return 1
    elif [[ -t 0 ]]; then
        read -r -p "${prompt}" reply || return 1
    else
        warn "Not running interactively — cannot ask, assuming no"
        return 1
    fi
    [[ "${reply}" =~ ^[Yy]([Ee][Ss])?$ ]]
}

normalize_bus_id() {
    local raw="$1"
    raw="$(echo "${raw}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')"
    if [[ "${raw}" =~ ^([0-9a-f]+):([0-9a-f]{2}):([0-9a-f]{2})\.([0-9a-f])$ ]]; then
        printf '%04x:%s:%s.%s\n' "$((16#${BASH_REMATCH[1]}))" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}"
    elif [[ "${raw}" =~ ^[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f]$ ]]; then
        echo "0000:${raw}"
    else
        echo "${raw}"
    fi
}

profile_from_devid() {
    case "$1" in
        20c2) echo "8gb" ;;
        2082) echo "10gb" ;;
        *) echo "unsupported" ;;
    esac
}

expected_mib_for_profile() {
    case "$1" in
        8gb) echo "65536" ;;
        10gb) echo "40960" ;;
        *) echo "" ;;
    esac
}

smi_memory_for_bus() {
    local want="$1"
    local line bus mem
    [[ -n "${SMI_MEM_CACHE:-}" ]] || return 0
    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        bus="$(normalize_bus_id "$(echo "${line}" | cut -d, -f1)")"
        mem="$(echo "${line}" | cut -d, -f2 | tr -d '[:space:]')"
        if [[ "${bus}" == "${want}" ]]; then
            echo "${mem}"
            return 0
        fi
    done <<< "${SMI_MEM_CACHE}"
}

echo ""
echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║               cmpunlocker              ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
echo ""

step "Verifying root privileges"
[[ "${EUID}" -eq 0 ]] || die "Run as root: sudo ./install.sh"
ok "Running as root"

step "Detecting CMP 170HX GPU(s)"
mapfile -t PCI_LINES < <(lspci -nn 2>/dev/null | grep -iE '10de:20b0|10de:20c2|10de:2082' || true)
ALLOW_NO_GPU=0
if [[ ${#PCI_LINES[@]} -eq 0 ]]; then
    warn "No CMP 170HX found on the PCI bus (10de:20b0 / 10de:20c2 / 10de:2082)"
    echo ""
    echo "  The card may be out of the machine, or an unstable overclock may have"
    echo "  left it unable to initialise. Building without it is how you install a"
    echo "  corrected driver before putting it back."
    echo ""
    echo "  The unlock reads its geometry from the device ID at runtime, so the"
    echo "  modules built here work on either variant once a card is present."
    echo ""
    confirm "Continue without a GPU?" || die "Aborted — no GPU detected"
    ALLOW_NO_GPU=1
    echo ""
fi

SMI_MEM_CACHE=""
if command -v nvidia-smi &>/dev/null; then
    SMI_MEM_CACHE="$(nvidia-smi --query-gpu=pci.bus_id,memory.total --format=csv,noheader,nounits 2>/dev/null || true)"
fi

GPU_COUNT=0
COUNT_8GB=0
COUNT_10GB=0

for PCI_LINE in "${PCI_LINES[@]}"; do
    PCI="$(echo "${PCI_LINE}" | awk '{print $1}')"
    PCI_FULL="$(normalize_bus_id "${PCI}")"
    DEVID="$(echo "${PCI_LINE}" | grep -oE '10de:[0-9a-fA-F]{4}' | head -1 | cut -d: -f2 | tr '[:upper:]' '[:lower:]')"
    PROF="$(profile_from_devid "${DEVID}")"
    CUR_MEM="$(smi_memory_for_bus "${PCI_FULL}" || true)"
    [[ -n "${CUR_MEM}" ]] || CUR_MEM="?"

    if [[ "${PROF}" == "unsupported" ]]; then
        warn "GPU ${PCI_FULL} (10de:${DEVID}) — not a supported device ID; skipping"
        continue
    fi

    EXP="$(expected_mib_for_profile "${PROF}")"
    GPU_COUNT=$((GPU_COUNT + 1))

    if [[ "${PROF}" == "8gb" ]]; then
        COUNT_8GB=$((COUNT_8GB + 1))
    else
        COUNT_10GB=$((COUNT_10GB + 1))
    fi

    if [[ "${CUR_MEM}" != "?" ]]; then
        ok "GPU ${PCI_FULL} (10de:${DEVID}) → ${PROF} (current ${CUR_MEM} MiB, expect ~${EXP} MiB unlocked)"
    else
        ok "GPU ${PCI_FULL} (10de:${DEVID}) → ${PROF} (expect ~${EXP} MiB unlocked)"
    fi
done

if [[ "${GPU_COUNT}" -eq 0 ]]; then
    if (( ALLOW_NO_GPU == 0 )); then
        warn "No unlockable CMP 170HX found (need 10de:20c2 and/or 10de:2082)"
        echo ""
        confirm "Continue anyway?" || die "Aborted — no unlockable GPU detected"
        ALLOW_NO_GPU=1
        echo ""
    fi
    warn "Building with no GPU to check against"
else
    info "Found ${GPU_COUNT} unlockable GPU(s): ${COUNT_8GB}x 8gb, ${COUNT_10GB}x 10gb"
fi

if [[ -n "${MCLK_NDIV}" ]]; then
    if ! [[ "${MCLK_NDIV}" =~ ^[0-9]+$ ]] || [[ "${MCLK_NDIV}" -lt 30 || "${MCLK_NDIV}" -gt 80 ]]; then
        die "--mclk-ndiv must be between 30 and 80 (got: ${MCLK_NDIV})"
    fi
    ok "MCLK set: NDIV=${MCLK_NDIV} ($((MCLK_NDIV * 27)) MHz) on every unlockable card"
    if (( GPU_COUNT == 0 )); then
        warn "No card present to check this against — NDIV ${MCLK_NDIV} is being"
        warn "compiled in blind. Stock is 64 on 8gb 300W, 54 on 8gb 250W, 45 on 10gb."
    elif (( COUNT_8GB > 0 && COUNT_10GB > 0 )); then
        warn "Mixed inventory: the multiplier is compiled in once and applies to both"
        warn "variants, but stock differs (8gb 54/64 vs 10gb 45). NDIV ${MCLK_NDIV} is"
        warn "$((MCLK_NDIV * 27)) MHz on all of them — verify each card in dmesg."
    elif (( COUNT_10GB > 0 )); then
        info "Stock for 10gb is NDIV 45 (1215 MHz)"
    else
        info "Stock for 8gb is NDIV 54 (1458 MHz, 250W VBIOS) or 64 (1728 MHz, 300W VBIOS)"
    fi
else
    info "MCLK overclock disabled (use --mclk-ndiv=N to enable)"
fi
export CMPUNLOCKER_MCLK_NDIV="${MCLK_NDIV}"

if [[ -n "${MCLK_TIMINGS}" ]]; then
    if ! [[ "${MCLK_TIMINGS}" =~ ^[+-]?[0-9]+$ ]] || \
       [[ "${MCLK_TIMINGS}" -lt -50 || "${MCLK_TIMINGS}" -gt 50 ]]; then
        die "--mclk-timings must be between -50 and 50 (got: ${MCLK_TIMINGS})"
    fi
    if [[ "${MCLK_TIMINGS}" -lt 0 ]]; then
        ok "DRAM timings tightened by ${MCLK_TIMINGS#-}% (tRC/tRFC/tRAS/tRP/tRCD/tWR/tFAW/tRRD)"
        warn "Tightening can corrupt data silently or wedge the memory controller."
        warn "Validate with a long gpu-burn run before trusting it — see overclocking/"
    elif [[ "${MCLK_TIMINGS}" -eq 0 ]]; then
        info "--mclk-timings=0 is a no-op; timings left at stock"
    else
        ok "DRAM timings loosened by ${MCLK_TIMINGS#+}% (tRC/tRFC/tRAS/tRP/tRCD/tWR/tFAW/tRRD)"
    fi
    info "CL, WL and tCCD are left at stock on purpose — see overclocking/timings/"
else
    info "DRAM timings left at stock (use --mclk-timings=N to scale)"
fi
export CMPUNLOCKER_MCLK_TIMINGS="${MCLK_TIMINGS}"

if [[ -n "${ENABLE_P2P}" ]]; then
    ok "GPU-to-GPU P2P forced on"
    warn "This only makes the driver advertise P2P. If the host cannot actually"
    warn "carry it, transfers time out rather than falling back to system memory."
    warn "Verify with a real peer-to-peer copy before relying on it."
else
    info "P2P left as GSP reports it (use --p2p to force it on)"
fi
export CMPUNLOCKER_ENABLE_P2P="${ENABLE_P2P}"

step "Verifying nvidia-open (${SUPPORTED_VERSIONS_CSV})"
[[ ${#SUPPORTED_VERSIONS[@]} -gt 0 ]] || die "No supported versions listed in driver/VERSION"
if [[ -d /sys/firmware/efi ]] && command -v mokutil &>/dev/null; then
    if mokutil --sb-state 2>/dev/null | grep -qi 'SecureBoot enabled'; then
        die "Secure Boot is enabled. Disable it before installing unsigned patched modules."
    fi
fi

version_supported() {
    local v="$1"
    local s
    for s in "${SUPPORTED_VERSIONS[@]}"; do
        [[ "${v}" == "${s}" ]] && return 0
    done
    return 1
}

detected=""
if [[ -r /proc/driver/nvidia/version ]]; then
    detected="$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' /proc/driver/nvidia/version | head -1 || true)"
fi
if [[ -z "${detected}" ]] && command -v nvidia-smi &>/dev/null; then
    #
    # nvidia-smi prints its "couldn't communicate with the driver" error on
    # stdout and not stderr, so match the version shape rather than taking
    # whatever came back.
    #
    detected="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null \
        | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)"
fi
if [[ -z "${detected}" ]]; then
    for cand in "${SUPPORTED_VERSIONS[@]}"; do
        if [[ -d "/lib/firmware/nvidia/${cand}" ]]; then
            detected="${cand}"
            break
        fi
    done
    if [[ -z "${detected}" ]]; then
        fw="$(ls -d /lib/firmware/nvidia/*/ 2>/dev/null | sed 's|.*/nvidia/||;s|/||' | sort -rV | head -1 || true)"
        detected="${fw}"
    fi
fi

[[ -n "${detected}" ]] || die "Could not detect an installed NVIDIA driver. Install nvidia-open ${SUPPORTED_VERSIONS_CSV} first."
version_supported "${detected}" || die "Installed driver is ${detected}, but cmpunlocker requires one of: ${SUPPORTED_VERSIONS_CSV}."
ok "NVIDIA driver ${detected} is supported"

[[ -d "/lib/modules/$(uname -r)/build" ]] || die "Kernel headers missing for $(uname -r). Install linux-headers-$(uname -r) or kernel-devel."
ok "Kernel headers present for $(uname -r)"

step "Building and installing patched modules"
chmod +x "${SCRIPT_DIR}/driver/build.sh"
CMPUNLOCKER_DRIVER_VERSION="${detected}" \
CMPUNLOCKER_MCLK_NDIV="${MCLK_NDIV}" \
CMPUNLOCKER_MCLK_TIMINGS="${MCLK_TIMINGS}" \
CMPUNLOCKER_ENABLE_P2P="${ENABLE_P2P}" \
CMPUNLOCKER_VERBOSE="${VERBOSE}" \
    "${SCRIPT_DIR}/driver/build.sh" || {
    #
    # build.sh has already printed the compiler errors and the tail of its own
    # log, so do not bury that under another wall of text.
    #
    echo ""
    err "Driver build failed — see the output above"
    err "Install log: ${LOG_FILE}"
    err "Retry with -v to watch the full build"
    exit 1
}
ok "Patched modules installed"

step "Surviving kernel updates"
PERSIST_STATUS="skipped"
if (( INSTALL_PERSIST == 0 )); then
    info "Persistence not requested (--no-persist)"
    warn "A kernel update will boot on the stock driver (8GB) until you re-run this installer"
elif [[ ! -x "${SCRIPT_DIR}/persist/install-persist.sh" ]]; then
    warn "persist/install-persist.sh missing — kernel updates will not be survived"
else
    #
    # The persistence layer is deliberately not fatal: the patched modules for
    # the running kernel are already installed and working at this point, and
    # failing the whole install over the automation would be a worse outcome.
    #
    if CMPUNLOCKER_DRIVER_VERSION="${detected}" \
       CMPUNLOCKER_MCLK_NDIV="${MCLK_NDIV}" \
       CMPUNLOCKER_MCLK_TIMINGS="${MCLK_TIMINGS}" \
       CMPUNLOCKER_ENABLE_P2P="${ENABLE_P2P}" \
       CMPUNLOCKER_PIN_PACKAGES="${PIN_PACKAGES}" \
           "${SCRIPT_DIR}/persist/install-persist.sh"; then
        PERSIST_STATUS="installed"
    else
        PERSIST_STATUS="failed"
        warn "Could not install kernel-update persistence — see the log"
        warn "The patched modules for $(uname -r) are installed and working regardless"
    fi
fi

step "Configuring kernel command line"
CMDLINE_STATUS="skipped"
CMDLINE_ADD=""
CMDLINE_STRIP_PATS=()

iommu_params_for_cpu() {
    local vendor=""
    vendor="$(awk -F': ' '/^vendor_id/{print $2; exit}' /proc/cpuinfo 2>/dev/null || true)"
    case "${vendor}" in
        GenuineIntel) echo "intel_iommu=on iommu=pt" ;;
        AuthenticAMD) echo "amd_iommu=on iommu=pt" ;;
        *) echo "" ;;
    esac
}

# BAR1 resize: always add PCIe params for large BAR support.
# Without these the kernel cannot allocate a 64 GB MMIO window and the
# resize silently falls back to 64 MB.
CMDLINE_ADD="pci=realloc pci=hpmmioprefsize=2T"
CMDLINE_STRIP_PATS+=("pci=realloc" "pci=hpmmioprefsize=*")
info "BAR1 resize: pci=realloc pci=hpmmioprefsize=2T"

# IOMMU: add if requested
if (( CONFIGURE_IOMMU )); then
    IOMMU_PARAMS="$(iommu_params_for_cpu)"
    if [[ -n "${IOMMU_PARAMS}" ]]; then
        CMDLINE_ADD="${IOMMU_PARAMS} ${CMDLINE_ADD}"
        CMDLINE_STRIP_PATS+=("intel_iommu=*" "amd_iommu=*" "iommu=*")
        info "IOMMU: ${IOMMU_PARAMS}"
    else
        warn "Unrecognized CPU vendor — cannot pick IOMMU kernel parameters"
    fi
else
    info "IOMMU: skipped (--no-iommu)"
fi

cmdline_merge() {
    local current="$1"
    local token pat skip out=()
    for token in ${current}; do
        skip=0
        # CMDLINE_STRIP_PATS is a bash array of glob patterns; we iterate
        # instead of using case…|… because | inside a variable is literal.
        for pat in "${CMDLINE_STRIP_PATS[@]}"; do
            # shellcheck disable=SC2254
            case "${token}" in ${pat}) skip=1; break ;; esac
        done
        (( skip )) || out+=("${token}")
    done
    for token in ${CMDLINE_ADD}; do
        out+=("${token}")
    done
    echo "${out[*]}"
}

configure_cmdline_grub() {
    local grub_file="/etc/default/grub"
    local key="GRUB_CMDLINE_LINUX_DEFAULT"
    local current merged

    grep -q "^${key}=" "${grub_file}" || key="GRUB_CMDLINE_LINUX"
    if grep -q "^${key}=" "${grub_file}"; then
        current="$(sed -n "s/^${key}=\"\(.*\)\"$/\1/p" "${grub_file}" | head -1)"
    else
        current=""
    fi
    merged="$(cmdline_merge "${current}")"

    if [[ "${current}" == "${merged}" ]]; then
        ok "GRUB already has ${CMDLINE_ADD} (${key})"
        CMDLINE_STATUS="already-set"
        return 0
    fi

    cp -a "${grub_file}" "${grub_file}.cmpunlocker.bak"
    if grep -q "^${key}=" "${grub_file}"; then
        local escaped="${merged//\//\\/}"
        sed -i "s/^${key}=.*/${key}=\"${escaped}\"/" "${grub_file}"
    else
        printf '%s="%s"\n' "${key}" "${merged}" >> "${grub_file}"
    fi
    ok "Set ${key}=\"${merged}\" (backup: ${grub_file}.cmpunlocker.bak)"

    local regen_ok=1
    if command -v update-grub &>/dev/null; then
        update-grub || regen_ok=0
    elif command -v grub2-mkconfig &>/dev/null; then
        #
        # On Fedora/RHEL /boot/efi/EFI/*/grub.cfg is a stub that chainloads
        # /boot/grub2/grub.cfg, and grub2-mkconfig refuses to overwrite it.
        # Prefer the real config; the EFI path is only it on older layouts.
        #
        local cfg=""
        if [[ -f /boot/grub2/grub.cfg ]]; then
            cfg="/boot/grub2/grub.cfg"
        else
            cfg="$(ls /boot/efi/EFI/*/grub.cfg 2>/dev/null | head -1 || true)"
        fi
        if [[ -n "${cfg}" ]]; then
            grub2-mkconfig -o "${cfg}" || regen_ok=0
        else
            regen_ok=0
        fi
    elif command -v grub-mkconfig &>/dev/null; then
        grub-mkconfig -o /boot/grub/grub.cfg || regen_ok=0
    else
        warn "No grub config generator found — regenerate grub.cfg manually"
        CMDLINE_STATUS="needs-grub-regen"
        return 0
    fi

    if (( regen_ok == 0 )); then
        warn "Could not regenerate grub.cfg — ${grub_file} is staged but inactive"
        warn "Regenerate it yourself, or restore ${grub_file}.cmpunlocker.bak"
        CMDLINE_STATUS="needs-grub-regen"
        return 0
    fi
    ok "Regenerated GRUB config"

    #
    # BLS entries carry their own cmdline, and regenerating grub.cfg does not
    # rewrite the ones that already exist — only new kernels would pick the
    # parameters up. grubby patches the existing entries.
    #
    if [[ -d /boot/loader/entries ]] && command -v grubby &>/dev/null; then
        if grubby --update-kernel=ALL --args="${CMDLINE_ADD}"; then
            ok "Updated existing boot entries via grubby"
        else
            warn "grubby could not update existing boot entries — only new kernels get ${CMDLINE_ADD}"
            CMDLINE_STATUS="needs-grub-regen"
            return 0
        fi
    fi
    CMDLINE_STATUS="configured"
}

configure_cmdline_kernel() {
    local file="/etc/kernel/cmdline"
    local current merged
    current="$(tr -d '\n' < "${file}")"
    merged="$(cmdline_merge "${current}")"

    if [[ "${current}" == "${merged}" ]]; then
        ok "${file} already has ${CMDLINE_ADD}"
        CMDLINE_STATUS="already-set"
        return 0
    fi

    cp -a "${file}" "${file}.cmpunlocker.bak"
    printf '%s\n' "${merged}" > "${file}"
    ok "Set ${file} to \"${merged}\" (backup: ${file}.cmpunlocker.bak)"

    if command -v kernel-install &>/dev/null && [[ -d /boot/loader/entries ]]; then
        for kdir in /lib/modules/*/; do
            kver="$(basename "${kdir}")"
            [[ -f "${kdir}/vmlinuz" ]] || continue
            kernel-install add "${kver}" "${kdir}/vmlinuz" 2>/dev/null || true
        done
        ok "Refreshed systemd-boot entries"
        CMDLINE_STATUS="configured"
    else
        warn "Update your boot entries so ${file} takes effect"
        CMDLINE_STATUS="needs-boot-refresh"
    fi
}

if [[ -f /etc/default/grub ]]; then
    info "Target: ${CMDLINE_ADD} (GRUB)"
    configure_cmdline_grub
elif [[ -f /etc/kernel/cmdline ]]; then
    info "Target: ${CMDLINE_ADD} (systemd-boot)"
    configure_cmdline_kernel
else
    warn "No /etc/default/grub or /etc/kernel/cmdline found"
    warn "Add these to your kernel command line manually: ${CMDLINE_ADD}"
    CMDLINE_STATUS="manual"
fi

if (( CONFIGURE_IOMMU )); then
    if grep -qw iommu=pt /proc/cmdline 2>/dev/null && [[ -d /sys/class/iommu ]] && [[ -n "$(ls -A /sys/class/iommu 2>/dev/null)" ]]; then
        ok "IOMMU is already active in passthrough mode on the running kernel"
    elif [[ "${CMDLINE_STATUS}" != "skipped" ]]; then
        info "IOMMU passthrough takes effect after the next reboot"
        warn "IOMMU must also be enabled in BIOS/UEFI (VT-d / AMD-Vi / SVM)"
    fi
fi

if grep -qw pci=realloc /proc/cmdline 2>/dev/null; then
    ok "pci=realloc is already active on the running kernel"
else
    info "BAR1 resize parameters take effect after the next reboot"
fi

echo ""
echo -e "${CYAN}╔════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║               cmpunlocker              ║${NC}"
echo -e "${CYAN}╚════════════════════════════════════════╝${NC}"
echo ""
if (( GPU_COUNT > 0 )); then
    echo "Installed for ${GPU_COUNT} GPU(s): ${COUNT_8GB}x 8gb, ${COUNT_10GB}x 10gb"
else
    echo "Installed with no GPU present — put the card back, then cold boot"
fi
if [[ -n "${MCLK_NDIV}" ]]; then
    echo "MCLK: NDIV=${MCLK_NDIV} ($((MCLK_NDIV * 27)) MHz)"
fi
if [[ -n "${MCLK_TIMINGS}" ]]; then
    echo "DRAM timings: ${MCLK_TIMINGS}% (verify: sudo dmesg | grep TIMING_SCALE)"
fi
if [[ -n "${ENABLE_P2P}" ]]; then
    echo "P2P: forced on (verify with a real peer-to-peer copy)"
fi
case "${PERSIST_STATUS}" in
    installed)
        PIN_RESULT="$(cat /var/lib/cmpunlocker/state/pin-status 2>/dev/null || echo unknown)"
        case "${PIN_RESULT}" in
            ok)      echo "Kernel updates: modules rebuilt automatically, NVIDIA packages pinned" ;;
            failed)  echo "Kernel updates: modules rebuilt automatically"
                     echo "                NVIDIA packages NOT pinned — see the warning above" ;;
            *)       echo "Kernel updates: modules rebuilt automatically, packages not pinned" ;;
        esac
        ;;
    failed)  echo "Kernel updates: NOT survived (persistence install failed)" ;;
    skipped) echo "Kernel updates: NOT survived (--no-persist)" ;;
esac
echo ""
echo "Next:"
echo -e "  1. Cold reboot: ${CYAN}sudo shutdown -h now${NC}  (then power on)"
echo -e "  2. Benchmark: ${CYAN}./benchmark/nvidia_bench${NC}"
echo -e "  3. Unlock logs: ${CYAN}sudo dmesg | grep CMPUNLOCK${NC}"
echo -e "  4. Verify cmdline: ${CYAN}cat /proc/cmdline${NC}  (pci=realloc should be present)"
echo -e "  5. Verify BAR1: ${CYAN}sudo dmesg | grep 'CMP BAR1'${NC}"
echo ""
echo "Log: ${LOG_FILE}"
echo ""
