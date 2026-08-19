# 170tune guide for CMP 170HX

This page covers **Stage 2**: installing `170tune`, preparing Linux, recording stock state, and validating tuning changes safely.

## Upstream project

- Repository: https://github.com/cachenetics/170tune
- Detailed tuning guide: https://github.com/cachenetics/170tune/blob/main/docs/tuning-guide.md

`170tune` is separate from `cmpunlocker`. First unlock the card and verify the correct memory geometry. Then use `170tune` for tuning/qualification.

## Why qualification matters

CMP 170HX can fail silently at unstable settings. A benchmark can finish without a crash or Xid while returning incorrect data. Upstream 170tune is designed around proving correctness, not merely proving that a kernel completed.

## Requirements

The upstream tool documents these important requirements:

- CMP 170HX with the community unlock applied;
- NVIDIA driver loaded;
- root/bash/`nvidia-smi`;
- `iomem=relaxed` in the kernel command line for userspace BAR0 mapping;
- NVML;
- CUDA toolkit for the strongest validation helpers.

## 1. Add `iomem=relaxed`

Edit:

```bash
sudo nano /etc/default/grub
```

Add the parameter to your existing line, for example:

```text
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash iomem=relaxed"
```

If your system later uses the P2P configuration from this repository, keep `iomem=relaxed` and add the P2P-related parameters to the **same** quoted line.

Apply:

```bash
sudo update-grub
sudo reboot
```

Verify:

```bash
cat /proc/cmdline
```

## 2. Clone and install

```bash
git clone https://github.com/cachenetics/170tune.git
cd 170tune
sudo ./install.sh
```

For future upgrades:

```bash
git pull
sudo ./install.sh
```

## 3. Run preflight

```bash
sudo 170tune preflight
```

Read every warning. The point of preflight is to prevent tuning on top of an unexpected driver/memory state.

## 4. Save the stock baseline

With the card at stock tuning settings:

```bash
sudo 170tune snapshot-stock
```

This creates a per-card revert baseline.

## 5. Learn the controls before changing them

Useful upstream commands include:

```bash
170tune explain
170tune explain-hbm
170tune status
170tune mclk-status
```

For SM tuning:

```bash
170tune try <offset> <clock> [seconds]
170tune gate <offset> <clock> [n] [--workload <cmd>]
```

For HBM:

```bash
170tune mclk-try <NDIV>
170tune mclk-gate <NDIV> [n]
170tune hbm-gate --ndiv N [--timings "FIELD VALUE ..."] [--sweeps N] [--workload "COMMAND"]
```

## Upstream reference profile — not a universal guarantee

The current 170tune documentation reports the following on its reference card:

- serving-oriented HBM ceiling: **NDIV 70**;
- stock timings;
- `REFRESH 24`;
- active fan control based on HBM temperature;
- higher NDIV values may work for synthetic memory tests but are not considered serving-safe on that reference card.

Do **not** persist those settings just because they worked upstream. Gate them on your own card and under your actual workload.

## Our recommendation for LLM systems

For local LLM inference we recommend this order:

1. establish stock/unlocked correctness;
2. run the real inference workload at stock tuning;
3. change one tuning dimension at a time;
4. use `gate`/`hbm-gate`;
5. include your real inference command as a workload soak;
6. watch HBM temperature as carefully as GPU core temperature;
7. persist only a profile that passes both synthetic validation and real serving.

## Our tested machine

On the system used for this repository we verified:

- 2× CMP 170HX, each unlocked from 8 GB to 64 GB;
- PCIe Gen2 x16 on both cards after a separate hardware lane modification;
- 300 W power limit can be enabled on our cards;
- later, working P2P made two-GPU tensor-split utilization noticeably smoother.

The **300 W value is a result from our hardware, not a universal recommendation**. Cooling, PSU capability, card condition and workload all matter.

## Recovery mindset

Keep this command in mind:

```bash
170tune reset
```

And read upstream recovery/persistence documentation before enabling boot-time profiles. A machine that always boots stock and applies a validated profile afterward is much easier to recover remotely than one that bakes aggressive values into low-level initialization.

## Interaction with P2P settings

For the working P2P setup documented here, our final kernel command line contains both:

```text
iomem=relaxed
intel_iommu=off iommu=off
```

These solve different problems:

- `iomem=relaxed` enables userspace BAR0 access used by 170tune;
- disabling IOMMU was required for healthy bare-metal CUDA P2P bandwidth on our dual-CMP system.

See the main README and `docs/INSTALL.md` before applying the P2P settings.
