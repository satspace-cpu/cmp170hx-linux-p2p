# CMP 170HX Linux Guide: 64 GB Unlock → 170tune → Working CUDA P2P

[Русская версия](README.ru.md) · [Benchmarks](docs/BENCHMARKS.md) · [Troubleshooting](docs/TROUBLESHOOTING.md)

A beginner-friendly, end-to-end Linux guide for NVIDIA CMP 170HX owners.

This project documents the path we actually used on a dual-card system:

**stock CMP 170HX → memory/compute unlock → tuning/validation with 170tune → PCIe Gen2 x16 → working CUDA P2P → multi-GPU LLM testing**

> **Measured on 2× CMP 170HX unlocked to 64 GB each:** ~6.46–6.69 GB/s one-way P2P, ~12.90–13.18 GB/s bidirectional, ~1.59–1.65 µs GPU-to-GPU latency over PCIe Gen2 x16.

---

## Read this first

CMP 170HX modding is experimental. You are replacing NVIDIA kernel modules, changing kernel boot parameters, and potentially tuning clocks/voltage/memory. Keep remote access or physical access to the machine, keep backups, and change **one thing at a time**.

This repository does **not** redistribute NVIDIA proprietary driver binaries. It documents and supplies small project-authored patches/scripts around upstream open-source work.

### The three stages

1. **Unlock the card** with `cmpunlocker` — restores full compute throughput and memory geometry. On the common 8 GB card, the tested result is **64 GB visible HBM2e**.
2. **Tune and validate** with `170tune` — optional, but strongly recommended if you want performance/power tuning. The important part is validation: CMP 170HX can silently corrupt data at unstable settings without crashing.
3. **Enable and verify P2P** — apply the P2P stack, our CMP/GA100 mailbox fix, disable IOMMU on bare metal, then verify bandwidth with NVIDIA's CUDA sample.

Do not start with P2P on a stock 8 GB card. Get the unlock stable first.

---

# Stage 1 — Unlock CMP 170HX

## Upstream projects

The unlock is the work of the CMP 170HX community. Start with the original project:

- **cmpunlocker (original):** https://github.com/amoghmunikote/cmpunlocker
- **Detailed install/procedure documentation:** https://github.com/Consensus-Protocol/cmp170hx

The current `cmpunlocker` README describes Linux x86-64, `nvidia-open 610.43.0x`, matching kernel headers, Secure Boot disabled, and a cold reboot after installation.

### What the unlock changes

For the common device profiles supported by current `cmpunlocker`:

| Original card | Unlock profile | Expected visible VRAM |
|---|---|---:|
| CMP 170HX 8 GB (`10de:20c2`) | `8gb` | **64 GB** |
| CMP 170HX 10 GB (`10de:2082`) | `10gb` | **40 GB** |

The unlock is applied through patched NVIDIA Open GPU Kernel Modules. It is not a VBIOS flash.

## 1. Prepare Linux

Debian/Ubuntu example:

```bash
sudo apt update
sudo apt install -y git curl patch build-essential python3 linux-headers-$(uname -r)
```

Check Secure Boot. Patched unsigned modules normally require it to be disabled:

```bash
mokutil --sb-state 2>/dev/null || true
```

Check the running kernel and NVIDIA driver:

```bash
uname -r
nvidia-smi
modinfo -F version nvidia
```

For the configuration documented here, we standardized on **NVIDIA Open Kernel Modules 610.43.03**.

## 2. Clone cmpunlocker

```bash
git clone https://github.com/amoghmunikote/cmpunlocker.git
cd cmpunlocker
```

Read the upstream README before installing:

```bash
less README.md
```

## 3. Install the unlock

For an 8 GB CMP 170HX that should expose 64 GB:

```bash
sudo ./install.sh --profile=8gb
```

For a 10 GB card:

```bash
sudo ./install.sh --profile=10gb
```

If your checkout auto-detects the profile and you trust the detection, upstream also supports:

```bash
sudo ./install.sh
```

## 4. Cold reboot

A normal warm reboot may not be enough after low-level card initialization changes. Shut the machine down completely:

```bash
sudo shutdown -h now
```

Power it off, wait a few seconds, then power it back on.

## 5. Verify the unlock

```bash
nvidia-smi
nvidia-smi --query-gpu=index,name,memory.total,pci.bus_id --format=csv
```

Our 8 GB cards report:

```text
NVIDIA CMP 170HX, 65536 MiB
```

If you still see the stock memory size, stop here and fix the unlock before continuing.

Full beginner notes: [docs/UNLOCK.md](docs/UNLOCK.md)

---

# Stage 2 — Tune and validate with 170tune

## Upstream project

- **170tune:** https://github.com/cachenetics/170tune
- **Tuning guide:** https://github.com/cachenetics/170tune/blob/main/docs/tuning-guide.md

`170tune` is not the memory unlock itself. It is a **tuning, qualification and recovery harness** for CMP 170HX after the unlock. It can work with SM clock/voltage, HBM clock and timings, and—most importantly—validate settings for silent corruption.

### Why we recommend it

The dangerous failure mode on CMP 170HX is not always a crash. An unstable point can complete a benchmark, show no Xid, and still return incorrect data. The 170tune project explicitly treats a completed benchmark as insufficient proof of stability.

## 1. Add `iomem=relaxed`

170tune uses BAR0 register access from userspace and documents `iomem=relaxed` as a requirement.

Edit GRUB:

```bash
sudo nano /etc/default/grub
```

Add `iomem=relaxed` to your existing `GRUB_CMDLINE_LINUX_DEFAULT`. Example:

```text
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash iomem=relaxed"
```

Later, for our P2P configuration, the same line also contains `intel_iommu=off iommu=off`. Keep all required parameters in the same quoted string.

Apply and reboot:

```bash
sudo update-grub
sudo reboot
```

Verify:

```bash
cat /proc/cmdline
```

## 2. Install 170tune

```bash
git clone https://github.com/cachenetics/170tune.git
cd 170tune
sudo ./install.sh
```

## 3. Run preflight first

```bash
sudo 170tune preflight
```

Do not tune until preflight is clean enough to explain every warning.

## 4. Record the stock state

With the card at stock tuning values:

```bash
sudo 170tune snapshot-stock
```

This gives 170tune a per-card revert baseline.

## 5. Do not copy someone else's OC blindly

The upstream project publishes reference-card results, but silicon, cooling and HBM behavior vary by card.

A useful upstream reference is:

- serving-oriented HBM: **NDIV 70**, stock timings, `REFRESH 24`, with HBM-temperature-aware cooling;
- higher synthetic-only settings may benchmark faster but can corrupt or crash under real inference load.

Treat those numbers as a starting point, **not a guaranteed profile**.

Use the project's qualification commands (`gate`, `hbm-gate`, workload soak) on your own card before persistence.

### Our tested system

On our machine we verified:

- 2× CMP 170HX unlocked from 8 GB to **64 GB each**;
- both links operating at **PCIe Gen2 x16** after the separate physical x16 hardware modification;
- a **300 W power limit** can be applied on our cards, but this is not presented here as a universal safe tuning recommendation;
- for AI inference, stable settings matter more than a synthetic peak.

We intentionally do **not** publish one universal overclock as “safe for every CMP 170HX”.

Detailed 170tune notes: [docs/170TUNE.md](docs/170TUNE.md)

---

# Stage 3 — Enable real CUDA P2P

This stage is for systems with two or more CMP 170HX cards where you want low-latency GPU-to-GPU transfers for multi-GPU CUDA workloads such as `llama.cpp` tensor split.

## The base P2P work

Our work builds on the experimental P2P modifications in:

- **aikitoria/open-gpu-kernel-modules — 610.43.03-p2p branch:** https://github.com/aikitoria/open-gpu-kernel-modules/tree/610.43.03-p2p

The important P2P commit we tested is based on the combined P2P modification at commit `9fb65044` on that branch.

This repository adds a CMP/GA100-specific mailbox correction on top of that P2P work:

- [patches/p2p-cmp170-mailbox-fix.patch](patches/p2p-cmp170-mailbox-fix.patch)

## Why the extra CMP mailbox fix is needed

The broader P2P modification forced:

```c
pKernelBif->pcieP2PType = NV_REG_STR_RM_PCIEP2P_TYPE_BAR1;
```

On our GA100-based CMP 170HX system, that disabled the normal mailbox allocation path while another part of the GA100 P2P path still tried to use the mailbox.

Our diagnostic build showed:

```text
mailbox=0xffffffffffffffff
baseMask=0xfff
Assertion failed: ((base & RM_PAGE_MASK) == 0)
```

The CMP fix changes the default back to:

```c
pKernelBif->pcieP2PType = NV_REG_STR_RM_PCIEP2P_TYPE_DEFAULT;
```

After the fix:

```text
mailbox=0x0
baseMask=0x0
```

The assertion disappeared.

## IOMMU was the second bottleneck

Even with a valid mailbox, our P2P bandwidth was still only:

```text
~0.47–0.49 GB/s
```

while Linux IOMMU was active.

On bare metal we then disabled IOMMU completely:

```text
intel_iommu=off iommu=off
```

Our final GRUB line also retains `iomem=relaxed` for 170tune and board-specific ACS parameters. Example from **our** machine:

```text
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash iomem=relaxed intel_iommu=off iommu=off pci=disable_acs_redir=0000:80:02.0 pci=disable_acs_redir=0000:80:03.0"
```

**Do not copy `80:02.0` / `80:03.0` blindly.** Those are specific to our motherboard topology.

Disabling IOMMU affects DMA isolation, virtualization and PCI passthrough. Understand that trade-off before using this configuration.

## Verify ACS on your own topology

Find the upstream bridge/root port for each GPU:

```bash
lspci -t
```

Inspect ACS:

```bash
sudo lspci -vv -s <ROOT_PORT> | grep -E 'ACSCap|ACSCtl'
```

For our working setup, redirect controls on the relevant root ports are disabled.

## Verify CUDA P2P

First:

```bash
nvidia-smi topo -p2p r
nvidia-smi topo -p2p w
nvidia-smi topo -p2p p
```

A working capability matrix should show `OK` between the two GPUs.

But **`OK` is not enough**. We learned this the hard way: CUDA can report peer access while the actual data path is catastrophically slow.

Run NVIDIA's CUDA sample `p2pBandwidthLatencyTest`.

Our final result:

```text
Unidirectional P2P Enabled:
GPU0 -> GPU1: 6.46 GB/s
GPU1 -> GPU0: 6.69 GB/s

Bidirectional P2P Enabled:
12.90–13.18 GB/s

GPU latency:
1.59–1.65 us
```

For comparison, broken P2P on the same machine was only:

```text
0.29–0.49 GB/s
```

## Before / after

| Metric | P2P disabled | Broken P2P | Working P2P |
|---|---:|---:|---:|
| 0→1 bandwidth | ~5.88 GB/s | ~0.29–0.47 GB/s | **6.46 GB/s** |
| 1→0 bandwidth | ~5.94 GB/s | ~0.29–0.49 GB/s | **6.69 GB/s** |
| Bidirectional | ~8.1–8.3 GB/s | ~0.5–0.9 GB/s | **12.90–13.18 GB/s** |
| GPU P2P latency | tens of µs without peer path | ~1.6–1.9 µs | **~1.6 µs** |

Full history: [docs/BENCHMARKS.md](docs/BENCHMARKS.md)

---

# AI / LLM result so far

Our main reason for doing this work is multi-GPU local LLM inference.

After the final P2P fix, `llama.cpp` tensor-split runs on the two CMP cards showed **much smoother and more even GPU utilization**, without the previous oscillating load pattern. Early reasoning-generation measurements were roughly **48–62 tokens/s** on the tested model/configuration; application throughput varies strongly with model, quantization, context, split mode and prompt, so CUDA transport numbers should remain the primary P2P proof.

We will keep adding reproducible LLM tests instead of claiming one universal token/s number.

---

# Useful scripts in this repository

Read-only quick check:

```bash
bash scripts/check-p2p.sh
```

Collect a report suitable for a GitHub issue:

```bash
bash scripts/collect-debug-info.sh
```

---

# Recommended order for a brand-new card

1. Install Linux and the supported NVIDIA Open Kernel Module version.
2. Verify the card is visible and stable at stock settings.
3. Clone and install `cmpunlocker`.
4. Cold power-cycle and verify 64 GB/40 GB geometry.
5. Install `170tune`, run `preflight`, and snapshot stock state.
6. Qualify any tuning changes on **your own card**; do not blindly copy an OC profile.
7. Confirm PCIe link width/speed with `lspci -vv`.
8. Only then add the P2P modification and this CMP mailbox fix.
9. Disable IOMMU if this is an acceptable bare-metal configuration for your machine.
10. Verify ACS/topology.
11. Run `nvidia-smi topo -p2p`.
12. Run `p2pBandwidthLatencyTest` and judge P2P by **actual bandwidth**, not only by `CAN Access Peer`.
13. Finally benchmark your real workload (`llama.cpp`, vLLM, CUDA application, etc.).

---

# Project navigation

- [Unlock guide](docs/UNLOCK.md)
- [170tune guide](docs/170TUNE.md)
- [P2P installation and verification](docs/INSTALL.md)
- [How the P2P failure and fix work](docs/P2P-EXPLAINED.md)
- [Benchmarks](docs/BENCHMARKS.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Mailbox patch](patches/p2p-cmp170-mailbox-fix.patch)
- [Patch notes](patches/README.md)
- [Contribution / reproduction guide](CONTRIBUTING.md)
- [Raw successful P2P benchmark](results/dual-cmp170hx-610.43.03.txt)
- [Русская версия](README.ru.md)

---

## Experimental status

The complete result has currently been validated on **one dual-CMP 170HX system**. Other driver versions, kernels, motherboards, card revisions and PCIe topologies may behave differently.

If you reproduce it, please open an issue and include your hardware, kernel, driver, `lspci` topology and complete `p2pBandwidthLatencyTest` output.

## Credits

This project stands on upstream community work. Please star and credit the original projects:

- https://github.com/amoghmunikote/cmpunlocker — memory/compute unlock and foundational CMP work
- https://github.com/Consensus-Protocol/cmp170hx — extensive CMP 170HX technical/procedure documentation
- https://github.com/cachenetics/170tune — tuning, validation, recovery and silent-corruption testing
- https://github.com/aikitoria/open-gpu-kernel-modules/tree/610.43.03-p2p — experimental NVIDIA Open Kernel Module P2P work used as the base for our P2P experiment
- NVIDIA CUDA Samples — `p2pBandwidthLatencyTest`

## License

Project-authored scripts and documentation are released under the [MIT License](LICENSE). NVIDIA source code and NVIDIA Open GPU Kernel Modules remain under their respective upstream licenses; this repository does not redistribute NVIDIA proprietary binaries.
