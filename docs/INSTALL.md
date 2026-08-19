# P2P installation and verification

This guide covers **Stage 3** of the project: adding working CUDA P2P to an already-unlocked CMP 170HX driver tree.

If your card is still stock, start with [UNLOCK.md](UNLOCK.md). If you want tuning/validation first, read [170TUNE.md](170TUNE.md).

## Tested configuration

- 2× NVIDIA CMP 170HX, 64 GB each
- NVIDIA Open GPU Kernel Modules 610.43.03
- Linux kernel 7.0.0-29-generic
- CUDA 13.3
- PCIe Gen2 x16 per GPU
- IOMMU disabled
- ACS redirect disabled on the two relevant upstream ports

This repository does **not** redistribute NVIDIA proprietary binaries.

---

## 1. Start from a known-good unlock

Before P2P work, verify:

```bash
nvidia-smi
nvidia-smi --query-gpu=index,name,memory.total,pci.bus_id --format=csv
```

For our 8 GB cards:

```text
NVIDIA CMP 170HX, 65536 MiB
```

Also check the running module:

```bash
modinfo -n nvidia
modinfo -F version nvidia
```

Do not continue if the unlock itself is unstable.

---

## 2. Understand the two P2P layers

The working setup has **two separate pieces**:

### A. Base experimental P2P modification

Source used in our experiment:

https://github.com/aikitoria/open-gpu-kernel-modules/tree/610.43.03-p2p

The combined P2P change we used is based on commit:

```text
9fb65044  Combined P2P mod based on the one by geohot, 5090 support by nimlgen, NVLink support by valdemardi
```

### B. CMP/GA100 mailbox fix from this repository

```text
patches/p2p-cmp170-mailbox-fix.patch
```

The base P2P modification alone made CUDA report peer access, but on our CMP/GA100 path the mailbox address remained invalid and bandwidth was broken. The mailbox fix is therefore applied **after** the base P2P modification.

---

## 3. Generate the base P2P patch for 610.43.03

We generated a standalone patch from the upstream P2P branch by diffing the stock 610.43.03 commit against the combined P2P commit.

Example:

```bash
cd /tmp

git clone -b 610.43.03-p2p \
  https://github.com/aikitoria/open-gpu-kernel-modules.git \
  ogkm-610-p2p

cd ogkm-610-p2p

git log --oneline --decorate -15
```

On the branch used for our test, stock 610.43.03 is commit `452cec62` and the combined P2P change is `9fb65044`.

Generate the patch:

```bash
git diff 452cec62 9fb65044 > /tmp/p2p-bar1-610.patch
```

Inspect it before use:

```bash
ls -lh /tmp/p2p-bar1-610.patch
head -40 /tmp/p2p-bar1-610.patch
```

> Commit IDs are pinned here because that is exactly what we tested. If upstream history changes, compare the current branch carefully instead of blindly substituting hashes.

---

## 4. Add the base P2P patch to your cmpunlocker build

The test system used a working `cmpunlocker` tree and added the P2P patch to its driver patch stack.

Example checkout:

```bash
git clone https://github.com/amoghmunikote/cmpunlocker.git
cd cmpunlocker
```

Copy the generated patch:

```bash
cp /tmp/p2p-bar1-610.patch driver/patches/
```

Copy this repository's CMP mailbox patch as well:

```bash
cp /path/to/cmp170hx-linux-p2p/patches/p2p-cmp170-mailbox-fix.patch \
   driver/patches/
```

If you are developing/debugging, the optional debug instrumentation patch may be placed after it. Normal users do not need the debug patch.

### Patch order used on our system

Our working order was:

```text
sec2-postbl-plm-ss-cfg.patch
booter-verify.patch
late-pma.patch
bar0-pramin-clamp.patch
ce-scrub-workarounds.patch
persistent-sw-state.patch
pcie-gen2.patch
pcie-gen2-probe-retrain.patch
pcie-gen2-early-watcher.patch
p2p-bar1-610.patch
p2p-cmp170-mailbox-fix.patch
name-string.patch
```

For a debug build:

```text
p2p-bar1-610.patch
p2p-cmp170-mailbox-fix.patch
p2p-cmp170-debug.patch
name-string.patch
```

If your current cmpunlocker revision has a different patch list, **do not overwrite it blindly**. Keep the existing unlock patches in their upstream order and place the P2P base + mailbox fix late in the stack, after PCIe/Gen2 work and before cosmetic name-string changes.

---

## 5. Dry-run the patches before building

A clean dry-run is strongly recommended.

Download/extract the exact NVIDIA Open GPU Kernel Modules source matching the driver version and apply the existing cmpunlocker patches in order, then:

```bash
patch --dry-run -p1 < /path/to/p2p-bar1-610.patch
patch --dry-run -p1 < /path/to/p2p-cmp170-mailbox-fix.patch
```

There should be no failed hunks and no `.rej` files.

---

## 6. Build the patched modules

If you use cmpunlocker's own build system, use its normal install/build command after adding the patches.

For a manually prepared Open GPU Kernel Modules tree:

```bash
make modules -j$(nproc)
```

Verify the result:

```bash
modinfo kernel-open/nvidia.ko | grep -E '^(version|srcversion|vermagic):'
```

The `vermagic` must match the running kernel.

---

## 7. Back up the working modules before replacement

Find the currently active module paths:

```bash
modinfo -n nvidia
modinfo -n nvidia_uvm
modinfo -n nvidia_modeset
modinfo -n nvidia_drm
modinfo -n nvidia_peermem
```

On our system they live under:

```text
/lib/modules/$(uname -r)/updates/cmpunlocker/
```

Backup example:

```bash
sudo mkdir -p /root/nvidia-backup-before-p2p
sudo sh -c 'cp -av /lib/modules/$(uname -r)/updates/cmpunlocker/nvidia*.ko /root/nvidia-backup-before-p2p/'
```

Also record hashes:

```bash
sudo sh -c 'sha256sum /root/nvidia-backup-before-p2p/nvidia*.ko'
```

---

## 8. Install the rebuilt modules

Example for our layout:

```bash
sudo cp -av \
  kernel-open/nvidia.ko \
  kernel-open/nvidia-uvm.ko \
  kernel-open/nvidia-modeset.ko \
  kernel-open/nvidia-drm.ko \
  kernel-open/nvidia-peermem.ko \
  /lib/modules/$(uname -r)/updates/cmpunlocker/

sudo depmod -a
sudo update-initramfs -u -k "$(uname -r)"
```

Reboot after installation.

---

## 9. Kernel command line: 170tune + IOMMU + ACS

### 170tune requirement

If you use 170tune, keep:

```text
iomem=relaxed
```

### P2P requirement on our bare-metal system

Healthy P2P bandwidth required:

```text
intel_iommu=off iommu=off
```

Our machine also disabled ACS redirect on the two relevant upstream ports:

```text
pci=disable_acs_redir=0000:80:02.0
pci=disable_acs_redir=0000:80:03.0
```

Final example from **our** machine:

```text
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash iomem=relaxed intel_iommu=off iommu=off pci=disable_acs_redir=0000:80:02.0 pci=disable_acs_redir=0000:80:03.0"
```

**Never copy those PCI addresses blindly.** Use `lspci -t` to identify your own topology.

Apply:

```bash
sudo update-grub
sudo reboot
```

Verify:

```bash
cat /proc/cmdline
```

> Disabling IOMMU affects DMA isolation, virtualization and PCI passthrough. Use it only if the trade-off is acceptable on your bare-metal system.

---

## 10. Verify that IOMMU is really out of the data path

Check groups:

```bash
find /sys/kernel/iommu_groups/ -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head
```

On our final working configuration this returned no groups.

Also inspect boot messages with appropriate privilege:

```bash
sudo dmesg | grep -Ei 'DMAR|IOMMU' | head -100
```

---

## 11. Verify PCIe width and speed

Find GPU BDFs:

```bash
nvidia-smi --query-gpu=index,pci.bus_id --format=csv
```

Then:

```bash
sudo lspci -vv -s 82:00.0 | grep -E 'LnkCap:|LnkSta:'
sudo lspci -vv -s 83:00.0 | grep -E 'LnkCap:|LnkSta:'
```

Our cards report:

```text
LnkCap: Speed 5GT/s, Width x16
LnkSta: Speed 5GT/s, Width x16
```

Your BDFs will differ.

---

## 12. Verify P2P capability

```bash
nvidia-smi topo -p2p r
nvidia-smi topo -p2p w
nvidia-smi topo -p2p p
```

Between our two GPUs:

```text
OK
```

But **do not stop here**. `OK` only tells you that the driver exposes peer capability.

---

## 13. Verify actual bandwidth and latency

Build NVIDIA CUDA Samples and run `p2pBandwidthLatencyTest`.

Depending on CUDA Samples revision, it may be under:

```text
Samples/5_Domain_Specific/p2pBandwidthLatencyTest
```

or:

```text
cpp/5_Domain_Specific/p2pBandwidthLatencyTest
```

Run:

```bash
./p2pBandwidthLatencyTest
```

Our healthy Gen2 x16 result:

```text
Unidirectional P2P enabled: 6.46 / 6.69 GB/s
Bidirectional P2P enabled: 12.90 / 13.18 GB/s
GPU latency: 1.59–1.65 us
```

Broken states we observed:

```text
P2P capability visible, but bandwidth only 0.29–0.49 GB/s
```

That is why bandwidth is the final proof.

---

## 14. Quick repository diagnostics

Read-only checker:

```bash
bash scripts/check-p2p.sh
```

Shareable report:

```bash
bash scripts/collect-debug-info.sh
```

---

## Rollback

If the modified driver fails, restore the backup modules, then:

```bash
sudo depmod -a
sudo update-initramfs -u -k "$(uname -r)"
sudo reboot
```

If the failure happens before you can reach the normal graphical session, use a console/SSH/recovery environment and restore the module files from `/root/nvidia-backup-before-p2p/`.
