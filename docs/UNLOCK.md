# CMP 170HX unlock guide

This page covers **Stage 1 only**: getting a stock CMP 170HX to the community-unlocked memory/compute state before tuning or P2P work.

## Upstream sources

- Original unlock project: https://github.com/amoghmunikote/cmpunlocker
- Detailed CMP 170HX procedures/reference: https://github.com/Consensus-Protocol/cmp170hx

Always prefer the upstream README if commands or supported versions change.

## Tested baseline in this project

Our documented dual-card system uses:

- CMP 170HX 8 GB cards (`10de:20c2`)
- NVIDIA Open Kernel Modules 610.43.03
- Linux x86-64
- unlock profile `8gb`
- resulting visible memory: **65536 MiB per card**

## 1. Install prerequisites

Debian/Ubuntu example:

```bash
sudo apt update
sudo apt install -y git curl patch build-essential python3 linux-headers-$(uname -r)
```

Verify:

```bash
uname -r
nvidia-smi
modinfo -F version nvidia
```

Patched unsigned modules generally require Secure Boot to be disabled:

```bash
mokutil --sb-state 2>/dev/null || true
```

## 2. Clone upstream cmpunlocker

```bash
git clone https://github.com/amoghmunikote/cmpunlocker.git
cd cmpunlocker
```

Before running anything as root, read the upstream instructions:

```bash
less README.md
```

## 3. Install the appropriate profile

Common 8 GB card → 64 GB:

```bash
sudo ./install.sh --profile=8gb
```

10 GB card → 40 GB:

```bash
sudo ./install.sh --profile=10gb
```

Current upstream also supports automatic profile selection in supported cases:

```bash
sudo ./install.sh
```

## 4. Cold power cycle

After driver-level initialization changes, do a real shutdown:

```bash
sudo shutdown -h now
```

Remove power for a few seconds before booting again.

## 5. Verify memory and module state

```bash
nvidia-smi
nvidia-smi --query-gpu=index,name,memory.total,pci.bus_id --format=csv
modinfo -n nvidia
modinfo -F version nvidia
```

For our 8 GB cards the expected result is:

```text
65536 MiB
```

## 6. Stop if the unlock is not clean

Do not continue to 170tune or P2P if any of the following are true:

- card still reports stock VRAM;
- NVIDIA module fails to load;
- repeated Xid errors appear immediately after boot;
- card disappears from `nvidia-smi`;
- driver version/source does not match the patched build you intended to use.

Fix the base unlock first. P2P adds another layer and makes debugging much harder if the foundation is not stable.

## What we verified

On the test machine documented by this repository:

```text
GPU0: NVIDIA CMP 170HX, 65536 MiB
GPU1: NVIDIA CMP 170HX, 65536 MiB
```

Both cards were then used for the later Gen2 x16 and P2P experiments.

## About the PCIe x16 hardware modification

Our cards were physically modified so all PCIe x16 lanes are present, then negotiated **Gen2 x16**. This is a separate hardware modification and is **not** required just to perform the memory unlock.

We intentionally do not present a universal soldering procedure in this repository yet because board revisions and component layouts can differ. Verify your exact PCB before attempting hardware work.
