# Contributing

Thanks for your interest in cmpunlocker. Read [ARCHITECTURE.md](ARCHITECTURE.md) first — it explains how the unlock works and where each piece lives.

---

## Where To Make Changes

Almost everything belongs in **`driver/src/cmpunlock.c`**. The patches in `driver/patches/` only contain the hook calls that reach it, and they should stay that way — logic in a patch is much harder to carry to the next nvidia-open release.

| You want to | Edit |
|---|---|
| Change unlock behaviour | `driver/src/cmpunlock.c` |
| Add a new hook | `cmpunlock.h` (declaration) + `cmpunlock.c` (body) + a new patch with the call |
| Change build options | `driver/build.sh` |
| Change install/removal flow | `install.sh` / `remove.sh` |
| Support a new driver version | `driver/VERSION` (newest first), then re-verify every patch applies |

Every entry point must start with `cmpUnlockIsTarget(pGpu)` and return early on non-CMP GPUs. The patched modules are expected to run unchanged on mixed systems.

---

## Build & Test Loop

```bash
sudo ./install.sh              # re-extracts stock sources, applies patches, builds, installs
sudo shutdown -h now           # cold reboot — see below
```

After power-on:

```bash
sudo dmesg | grep CMPUNLOCK    # unlock trace
nvidia-smi                     # geometry
./benchmark/nvidia_bench       # memory bandwidth, SMs, PCIe speed, tensor cores
```

`driver/.build/` is regenerated on every run and is gitignored, so there is nothing to clean between iterations — just re-run `install.sh`.

**A cold reboot means a full power off, not `reboot`.** Some of the unlocked state survives a warm reset, which makes results misleading: a change can look like it works because the previous boot already put the card in that state. When in doubt, `./remove.sh --yes`, power cycle, and start from stock.

---

## Patches

- Unified diff, `-p1`, applied in filename order by `build.sh`.
- Must apply **without fuzz**. Verify against an extracted tree before submitting:
  ```bash
  cd driver/.build/open-gpu-kernel-modules-<version>
  patch -p1 --dry-run --verbose < ../../patches/00XX-your.patch
  ```
  Any `Hunk #N succeeded ... with fuzz` means the context is wrong — fix the context lines, do not rely on `patch` guessing.
- Keep them minimal: an `#include` and a call. If a hunk is growing, move the body into `cmpunlock.c`.
- Name them `NNNN-short-description.patch`, continuing the existing numbering.

---

## Code Style

`cmpunlock.c` follows the surrounding nvidia-open RM code:

- RM types (`NvU32`, `NvU64`, `NvBool`, `NV_STATUS`), not kernel types.
- `GPU_REG_RD32` / `GPU_REG_WR32` for register access, `NV_PRINTF(LEVEL_ERROR, "CMPUNLOCK: ...")` for logging.
- Public functions prefixed `cmpUnlock`, file-local ones `_cmp`, declared `static`.
- 4-space indent, no tabs, brace on its own line.
- Named `#define`s for register addresses at the top of the file rather than bare constants inline.
- Comment *why*, not *what* — the register writes are not self-explanatory, so say what the sequence is doing and why it has to happen there.

Shell scripts use `set -euo pipefail`, quoted variables and explicit error handling.

---

## Hardware Changes

Register writes on a card this locked can hang the GPU or the host, and a bad memory clock can corrupt data silently. If you are adding or changing register sequences:

- Prefer read-modify-write over blind writes, and read back to confirm the write landed.
- Log enough that a failure is diagnosable from `dmesg` alone.
- Anything risky should be opt-in behind a build flag, the way `--mclk-ndiv` is.

---

## Submitting

1. Fork and branch:
   ```bash
   git checkout -b my-change
   ```
2. Make the change and test it on real hardware.
3. Commit with a clear message describing what changed and why.
4. Push and open a PR filling in [the template](../.github/pull_request_template.md) — summary, changes, and **testing with proof**.

Report the hardware your change actually depends on:

| PR touches | Report example                                                            |
|---|---------------------------------------------------------------------------|
| Docs only | Nothing — leave the hardware section empty                                |
| `install.sh` / `remove.sh` / `build.sh` | Distro, kernel, driver version                                            |
| `cmpunlock.c` / patches | Card variant (`0x20C2` / `0x2082`), VBIOS, distro, kernel, driver version |
| Memory clock, PCIe, P2P | The above, plus GPU count and host/slot topology                          |

Anything that changes driver behaviour must be tested on real hardware, with proof (`dmesg`, `nvidia-smi`, benchmark output).
