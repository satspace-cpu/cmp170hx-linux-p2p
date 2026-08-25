#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mapfile -t SUPPORTED_VERSIONS < <(grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' "${SCRIPT_DIR}/VERSION")
DEFAULT_VERSION="${SUPPORTED_VERSIONS[0]:-}"
VERSION="${CMPUNLOCKER_DRIVER_VERSION:-${DEFAULT_VERSION}}"
PATCH_DIR="${SCRIPT_DIR}/patches"
CMPSRC_DIR="${SCRIPT_DIR}/src"
BUILD_ROOT="${CMPUNLOCKER_BUILD_DIR:-${SCRIPT_DIR}/.build}"
SRC_NAME="open-gpu-kernel-modules-${VERSION}"
SRC_DIR="${BUILD_ROOT}/${SRC_NAME}"
TARBALL="${BUILD_ROOT}/${SRC_NAME}.tar.gz"
TARBALL_URL="https://github.com/NVIDIA/open-gpu-kernel-modules/archive/refs/tags/${VERSION}.tar.gz"
#
# CMPUNLOCKER_KVER lets the kernel-update hooks build for a kernel that is not
# the running one: dnf/apt unpack the new modules tree before the reboot, so
# the patched driver is already in place the first time that kernel boots.
#
KVER="${CMPUNLOCKER_KVER:-$(uname -r)}"
KRUNNING="$(uname -r)"
KSRC="/lib/modules/${KVER}/build"
INSTALL_MOD_DIR="/lib/modules/${KVER}/updates/cmpunlocker"

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
else
    RED=""; GREEN=""; YELLOW=""; CYAN=""; NC=""
fi

info() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[ OK ]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[FAIL]${NC}  $*" >&2; }
die()  { err "$*"; exit 1; }

VERBOSE="${CMPUNLOCKER_VERBOSE:-0}"

#
# Progress is written straight to the terminal, never to stdout, so it stays
# out of the install log no matter how the caller redirects us.
#
TTY_OUT=""
{ : > /dev/tty; } 2>/dev/null && TTY_OUT=/dev/tty

tty_progress() { [[ -n "${TTY_OUT}" ]] && printf '\r\033[K%s' "$*" > "${TTY_OUT}"; return 0; }
tty_clear()    { [[ -n "${TTY_OUT}" ]] && printf '\r\033[K' > "${TTY_OUT}"; return 0; }

progress_bar() {
    local cur="$1" tot="$2" w="${3:-24}" filled i out=""
    (( tot > 0 )) || tot=1
    filled=$(( cur * w / tot ))
    (( filled > w )) && filled=${w}
    for ((i = 0; i < w; i++)); do
        if (( i < filled )); then out+="█"; else out+="░"; fi
    done
    printf '%s %3d%%' "${out}" $(( cur * 100 / tot ))
}

#
# On failure the quiet output is useless on its own, so surface the compiler
# errors and the tail of the captured log before giving up.
#
dump_failure() {
    local log="$1" label="$2"
    echo ""
    err "${label} failed."
    if [[ -s "${log}" ]]; then
        if grep -qE 'error:|[Ee]rror [0-9]|FAILED|fatal error|undefined reference|No rule to make' "${log}"; then
            echo ""
            echo "--- errors ---"
            grep -nE 'error:|[Ee]rror [0-9]|FAILED|fatal error|undefined reference|No rule to make' "${log}" | head -25
        fi
        echo ""
        echo "--- last 40 lines ---"
        tail -40 "${log}"
        echo ""
        err "Full output: ${log}"
    fi
}

version_supported() {
    local v="$1"
    local s
    for s in "${SUPPORTED_VERSIONS[@]}"; do
        [[ "${v}" == "${s}" ]] && return 0
    done
    return 1
}

[[ "${EUID}" -eq 0 ]] || die "Run as root: sudo ${SCRIPT_DIR}/build.sh"
[[ -n "${VERSION}" ]] || die "No driver version set (driver/VERSION empty and CMPUNLOCKER_DRIVER_VERSION unset)"
version_supported "${VERSION}" || die "Unsupported driver version '${VERSION}' (supported: ${SUPPORTED_VERSIONS[*]})"
[[ -d "${PATCH_DIR}" ]] || die "Missing patches directory: ${PATCH_DIR}"
[[ -d "${CMPSRC_DIR}" ]] || die "Missing sources directory: ${CMPSRC_DIR}"
[[ -d "${KSRC}" ]] || die "Kernel headers not found at ${KSRC}. Install linux-headers-${KVER} (or kernel-devel)."
info "Building against open-gpu-kernel-modules ${VERSION}"

mkdir -p "${BUILD_ROOT}"

if [[ ! -f "${TARBALL}" ]]; then
    info "Downloading open-gpu-kernel-modules ${VERSION}..."
    curl -L --fail -o "${TARBALL}.partial" "${TARBALL_URL}"
    mv "${TARBALL}.partial" "${TARBALL}"
    ok "Downloaded ${TARBALL}"
else
    ok "Using cached tarball ${TARBALL}"
fi

info "Extracting sources..."
rm -rf "${SRC_DIR}"
tar -xzf "${TARBALL}" -C "${BUILD_ROOT}"
if [[ ! -d "${SRC_DIR}" ]]; then
    extracted="$(find "${BUILD_ROOT}" -maxdepth 1 -type d -name "${SRC_NAME}*" | head -1)"
    [[ -n "${extracted}" ]] || die "Extracted source tree not found"
    mv "${extracted}" "${SRC_DIR}"
fi
ok "Sources ready: ${SRC_DIR}"

MCLK_NDIV="${CMPUNLOCKER_MCLK_NDIV:-}"
if [[ -n "${MCLK_NDIV}" ]]; then
    if ! [[ "${MCLK_NDIV}" =~ ^[0-9]+$ ]] || [[ "${MCLK_NDIV}" -lt 30 || "${MCLK_NDIV}" -gt 80 ]]; then
        die "CMPUNLOCKER_MCLK_NDIV must be an integer between 30 and 80 (got: '${MCLK_NDIV}')"
    fi
fi

MCLK_TIMINGS="${CMPUNLOCKER_MCLK_TIMINGS:-}"
if [[ -n "${MCLK_TIMINGS}" ]]; then
    if ! [[ "${MCLK_TIMINGS}" =~ ^[+-]?[0-9]+$ ]] || \
       [[ "${MCLK_TIMINGS}" -lt -50 || "${MCLK_TIMINGS}" -gt 50 ]]; then
        die "CMPUNLOCKER_MCLK_TIMINGS must be an integer between -50 and 50 (got: '${MCLK_TIMINGS}')"
    fi
    # Strip a leading + so the generated #define is valid C.
    MCLK_TIMINGS="${MCLK_TIMINGS#+}"
    [[ "${MCLK_TIMINGS}" -eq 0 ]] && MCLK_TIMINGS=""
fi

ENABLE_P2P="${CMPUNLOCKER_ENABLE_P2P:-}"

#
# The unlock itself lives in driver/src/cmpunlock.c and is dropped into the
# tree as a new source file. The patches below only add the hook calls that
# reach it, which is why they are a few lines each.
#
info "Installing cmpunlock sources..."
CMP_SRC_DST="${SRC_DIR}/src/nvidia/src/kernel/gpu/cmpunlock"
CMP_INC_DST="${SRC_DIR}/src/nvidia/inc/kernel/gpu/cmpunlock"
mkdir -p "${CMP_SRC_DST}" "${CMP_INC_DST}"
install -m 0644 "${CMPSRC_DIR}/cmpunlock.c" "${CMP_SRC_DST}/cmpunlock.c"
install -m 0644 "${CMPSRC_DIR}/cmpunlock.h" "${CMP_INC_DST}/cmpunlock.h"

if [[ -n "${MCLK_NDIV}" || -n "${MCLK_TIMINGS}" || -n "${ENABLE_P2P}" ]]; then
    {
        echo "/* Generated by driver/build.sh. Do not edit. */"
        echo "#ifndef CMPUNLOCK_CONFIG_H"
        echo "#define CMPUNLOCK_CONFIG_H"
        [[ -n "${MCLK_NDIV}" ]]    && echo "#define CMPUNLOCK_MCLK_NDIV ${MCLK_NDIV}"
        [[ -n "${MCLK_TIMINGS}" ]] && echo "#define CMPUNLOCK_MCLK_TIMINGS (${MCLK_TIMINGS})"
        [[ -n "${ENABLE_P2P}" ]]   && echo "#define CMPUNLOCK_ENABLE_P2P 1"
        echo "#endif"
    } > "${CMP_INC_DST}/cmpunlock_config.h"

    if [[ -n "${MCLK_NDIV}" ]]; then
        ok "MCLK NDIV set to ${MCLK_NDIV} ($((MCLK_NDIV * 27)) MHz)"
    else
        info "No --mclk-ndiv: HBM overclock compiled out"
    fi
    if [[ -n "${MCLK_TIMINGS}" ]]; then
        if [[ "${MCLK_TIMINGS}" -lt 0 ]]; then
            ok "DRAM timings tightened by ${MCLK_TIMINGS#-}%"
        else
            ok "DRAM timings loosened by ${MCLK_TIMINGS}%"
        fi
    fi
    if [[ -n "${ENABLE_P2P}" ]]; then
        ok "GPU-to-GPU P2P forced on"
    fi
else
    install -m 0644 "${CMPSRC_DIR}/cmpunlock_config.h" "${CMP_INC_DST}/cmpunlock_config.h"
    info "No --mclk-ndiv / --mclk-timings / --p2p: all optional features compiled out"
fi

# Appending is safe because the source tree is re-extracted on every run.
echo 'SRCS += src/kernel/gpu/cmpunlock/cmpunlock.c' >> "${SRC_DIR}/src/nvidia/srcs.mk"
ok "cmpunlock sources installed"

info "Applying hook patches..."
cd "${SRC_DIR}"
shopt -s nullglob
patches=("${PATCH_DIR}"/*.patch)
[[ ${#patches[@]} -gt 0 ]] || die "No patches found in ${PATCH_DIR}"
PATCH_LOG="${BUILD_ROOT}/patch.log"
: > "${PATCH_LOG}"
for p in "${patches[@]}"; do
    if ! patch -p1 --forward < "${p}" >> "${PATCH_LOG}" 2>&1; then
        dump_failure "${PATCH_LOG}" "Patch $(basename "${p}")"
        exit 1
    fi
done
ok "Applied ${#patches[@]} hook patches"

mkdir -p "${INSTALL_MOD_DIR}"

cd "${SRC_DIR}"
find . -name "*.sh" -exec chmod +x {} + 2>/dev/null || true
rm -rf src/nvidia/_out src/nvidia-modeset/_out kernel-open/conftest 2>/dev/null || true
make clean >/dev/null 2>&1 || true
JOBS="$(nproc)"
MAKE_LOG="${BUILD_ROOT}/make.log"
OBJCOUNT_FILE="${BUILD_ROOT}/.objcount"

#
# The kernel build prints a line per file - thousands of them. Capture that to
# a log and show a bar instead, using the previous build's file count as the
# scale. The first build on a machine has nothing to scale against, so it just
# counts up.
#
build_modules() {
    if [[ "${VERBOSE}" == "1" ]]; then
        make -j"${JOBS}" modules SYSSRC="${KSRC}"
        return $?
    fi

    local expected=0 pid rc n start
    [[ -r "${OBJCOUNT_FILE}" ]] && expected="$(cat "${OBJCOUNT_FILE}" 2>/dev/null || echo 0)"
    [[ "${expected}" =~ ^[0-9]+$ ]] || expected=0

    start="${SECONDS}"
    make -j"${JOBS}" modules SYSSRC="${KSRC}" > "${MAKE_LOG}" 2>&1 &
    pid=$!

    while kill -0 "${pid}" 2>/dev/null; do
        n="$(grep -cE '^\s*(CC|LD|AR|CONFTEST)' "${MAKE_LOG}" 2>/dev/null || true)"
        [[ "${n}" =~ ^[0-9]+$ ]] || n=0
        if (( expected > 0 )); then
            tty_progress "  $(progress_bar "${n}" "${expected}")  ${n}/${expected} files  $((SECONDS - start))s"
        else
            tty_progress "  compiling... ${n} files  $((SECONDS - start))s"
        fi
        sleep 0.4
    done

    wait "${pid}"; rc=$?
    tty_clear

    n="$(grep -cE '^\s*(CC|LD|AR|CONFTEST)' "${MAKE_LOG}" 2>/dev/null || true)"
    [[ "${n}" =~ ^[0-9]+$ ]] || n=0
    if (( rc == 0 )); then
        echo "${n}" > "${OBJCOUNT_FILE}"
        ok "Built ${n} files in $((SECONDS - start))s for kernel ${KVER}"
    fi
    return "${rc}"
}

info "Building modules for kernel ${KVER} (${JOBS} jobs)..."
if ! build_modules; then
    dump_failure "${MAKE_LOG}" "Module build"
    exit 1
fi

exit 0

info "Installing modules to ${INSTALL_MOD_DIR}..."
mkdir -p "${INSTALL_MOD_DIR}"

mapfile -t KO_FILES < <(find "${SRC_DIR}" -type f \( \
    -name 'nvidia.ko' -o -name 'nvidia-modeset.ko' -o -name 'nvidia-uvm.ko' \
    -o -name 'nvidia-drm.ko' -o -name 'nvidia-peermem.ko' \) \
    ! -path '*/conftest/*' | sort -u)
[[ ${#KO_FILES[@]} -gt 0 ]] || die "No built nvidia*.ko found"

INSTALLED=()
for ko in "${KO_FILES[@]}"; do
    base="$(basename "${ko}")"
    install -m 0644 "${ko}" "${INSTALL_MOD_DIR}/${base}"
    INSTALLED+=("${base%.ko}")
done
ok "Installed ${#INSTALLED[@]} modules: ${INSTALLED[*]}"

# Claim depmod priority *before* indexing. install-persist.sh installs this
# same file, but only at a later install step, and build.sh also runs on its
# own (persist/rebuild.sh calls it directly on kernel updates). Installing it
# here means the verification below is meaningful in both paths. Same path and
# contents upstream uses, so remove.sh already cleans it up and the later
# install-persist.sh run is a no-op.
DEPMOD_CONF_SRC="${SCRIPT_DIR}/../persist/depmod-cmpunlocker.conf"
if [[ -f "${DEPMOD_CONF_SRC}" ]]; then
    mkdir -p /etc/depmod.d
    install -m 0644 "${DEPMOD_CONF_SRC}" /etc/depmod.d/cmpunlocker.conf
    ok "Installed /etc/depmod.d/cmpunlocker.conf"
else
    warn "Missing ${DEPMOD_CONF_SRC} — depmod priority not claimed"
fi

depmod -a "${KVER}"
sync   # flush modules.dep to disk — important if VM is hard-killed before reboot

# Verify depmod actually resolves nvidia to our build. Do not use
# `modprobe -n -v` for this: it prints nothing when the module is already
# loaded, which makes the check silently pass while the stock driver is still
# what would load. `modinfo -n` answers from the module index either way.
# Fall back to modules.dep, matching field 1 only — a greedy regex over the
# whole line would happily match nvidia.ko in another module's dependency list.
resolved_ko="$(modinfo -k "${KVER}" -n nvidia 2>/dev/null || true)"
if [[ -z "${resolved_ko}" ]]; then
    resolved_ko="$(awk -F: '$1 ~ /(^|\/)nvidia\.ko(\.[a-z]+)?$/ {print $1; exit}' \
        "/lib/modules/${KVER}/modules.dep" 2>/dev/null || true)"
fi
if [[ "${resolved_ko}" == *"updates/cmpunlocker/"* ]]; then
    ok "depmod resolves nvidia to ${resolved_ko}"
else
    die "depmod resolved nvidia to '${resolved_ko:-<nothing>}', not updates/cmpunlocker/. The stock driver would load instead of the patched one."
fi

INITRAMFS_LOG="${BUILD_ROOT}/initramfs.log"

# Runs for a minute or so and is noisy; capture it and only speak up on failure.
run_quiet() {
    local label="$1"; shift
    if [[ "${VERBOSE}" == "1" ]]; then
        "$@" && return 0
        dump_failure /dev/null "${label}"
        return 1
    fi
    tty_progress "  ${label}..."
    if "$@" > "${INITRAMFS_LOG}" 2>&1; then
        tty_clear
        return 0
    fi
    tty_clear
    dump_failure "${INITRAMFS_LOG}" "${label}"
    return 1
}

rebuild_initramfs() {
    if command -v update-initramfs &>/dev/null; then
        run_quiet "Rebuilding initramfs (update-initramfs)" \
            update-initramfs -u -k "${KVER}" || return 1
    elif command -v dracut &>/dev/null; then
        run_quiet "Rebuilding initramfs (dracut)" \
            dracut --force --kver "${KVER}" || return 1
    elif command -v mkinitcpio &>/dev/null; then
        run_quiet "Rebuilding initramfs (mkinitcpio)" mkinitcpio -P || return 1
    else
        warn "No initramfs tool found — rebuild manually before rebooting"
        return 1
    fi
    ok "initramfs rebuilt"
}

rebuild_initramfs || true

#
# Building for a kernel that is not running (kernel-update hook): the modules
# are in place for the next boot and there is nothing to swap in now. Trying to
# would unload the driver the current kernel is using and load nothing back.
#
if [[ "${KVER}" != "${KRUNNING}" ]]; then
    echo ""
    ok "Built and installed for kernel ${KVER} (running: ${KRUNNING})"
    info "Takes effect when ${KVER} boots"
    echo ""
    exit 0
fi

resolved="$(modprobe -n -v nvidia 2>/dev/null | awk '/insmod/ {print $2; exit}' || true)"
if [[ -n "${resolved}" ]]; then
    info "modprobe will load: ${resolved}"
    if [[ "${resolved}" != *"/updates/cmpunlocker/"* ]]; then
        warn "Resolved nvidia.ko is not under updates/cmpunlocker/"
    fi
fi
# Tearing nvidia_drm out from under a running display server kills the
# X/Wayland session. The unlock only takes effect from a cold power-on anyway,
# so the live reload buys nothing here — skip it whenever a graphical session
# is active.
display_server_running() {
    pgrep -x Xorg        >/dev/null 2>&1 && return 0
    pgrep -x gnome-shell >/dev/null 2>&1 && return 0
    pgrep -x sddm        >/dev/null 2>&1 && return 0
    pgrep -x gdm3        >/dev/null 2>&1 && return 0
    systemctl is-active --quiet graphical.target 2>/dev/null && return 0
    return 1
}

reload_ok=0
if [[ -z "${CMPUNLOCKER_FORCE_RELOAD:-}" ]] && display_server_running; then
    warn "Graphical session detected — skipping the live module reload."
    info "Unloading nvidia_drm here would kill your desktop session, and the"
    info "unlock requires a cold power-on regardless. Modules are installed."
    info "(Override with CMPUNLOCKER_FORCE_RELOAD=1 from a text console.)"
else
loads_before="$(dmesg 2>/dev/null | grep -c 'loading NVIDIA UNIX' || true)"
info "Attempting to unload NVIDIA modules..."
systemctl stop nvidia-persistenced 2>/dev/null || true
systemctl stop nvidia-fabricmanager 2>/dev/null || true
if lsmod | grep -q '^nvidia'; then
    for mod in nvidia_drm nvidia_uvm nvidia_modeset nvidia; do
        modprobe -r "${mod}" 2>/dev/null || true
    done
    sleep 1
fi

if ! lsmod | grep -q '^nvidia '; then
    if modprobe nvidia && modprobe nvidia-modeset; then
        modprobe nvidia-uvm 2>/dev/null || true
        modprobe nvidia-drm 2>/dev/null || true
        reload_ok=1
        ok "Patched NVIDIA modules loaded"
        #
        # srcversion cannot answer this: it hashes the kernel-open sources,
        # and cmpunlock.c arrives as part of the prebuilt nv-kernel.o blob, so
        # it stays identical no matter what the unlock does. Count the module's
        # own load banner instead - if it did not go up, nothing was reloaded
        # and the driver in memory is still the previous build.
        #
        loads_after="$(dmesg 2>/dev/null | grep -c 'loading NVIDIA UNIX' || true)"
        if [[ "${loads_after}" == "${loads_before}" ]]; then
            warn "nvidia did not actually reload — the running driver is still the old build"
            reload_ok=0
        fi
    else
        warn "modprobe failed"
    fi
else
    warn "Could not unload nvidia modules"
fi
fi
echo ""
if [[ "${reload_ok}" -eq 1 ]]; then
    ok "Build and install finished. Verify with: nvidia-smi"
    info "If memory shows stock size, do cold reboot."
else
    warn "Modules installed but running driver is still stock."
    info "Perform cold reboot: shutdown -h now"
fi
echo ""
