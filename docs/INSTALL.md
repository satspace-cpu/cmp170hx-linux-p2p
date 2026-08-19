# Installation and verification

This guide documents the tested procedure for the CMP 170HX P2P mailbox fix.

## Scope

Tested on:

- 2× NVIDIA CMP 170HX, 64 GB each
- NVIDIA Open GPU Kernel Modules 610.43.03
- Linux kernel 7.0.0-29-generic
- CUDA 13.3
- PCIe Gen2 x16 per GPU

This repository does **not** redistribute NVIDIA binaries. Apply the patch to the matching NVIDIA open kernel module source tree or to an existing CMP unlock build system.

## 1. Start from a known-good CMP driver tree

Before adding this P2P fix, confirm that your CMP 170HX cards already work correctly with your existing unlock setup.

Recommended checks:

```bash
nvidia-smi
nvidia-smi --query-gpu=index,name,memory.total,pci.bus_id --format=csv
```

For a 64 GB unlock, each card should report about 65536 MiB.

## 2. Apply the mailbox fix

The patch is:

```text
patches/p2p-cmp170-mailbox-fix.patch
```

From the root of the NVIDIA open-gpu-kernel-modules source tree:

```bash
patch -p1 < /path/to/p2p-cmp170-mailbox-fix.patch
```

The patch changes the default PCIe P2P type from forced BAR1 mode back to the normal driver default so the GA100/CMP mailbox path can allocate and program the write mailbox correctly.

## 3. Build the kernel modules

Typical build command:

```bash
make modules -j$(nproc)
```

Verify the result:

```bash
modinfo kernel-open/nvidia.ko | grep -E '^(version|srcversion|vermagic):'
```

The `vermagic` must match the running kernel.

## 4. Install the modules

The exact installation path depends on your existing CMP unlock setup. In the tested system the modules were installed under:

```text
/lib/modules/$(uname -r)/updates/cmpunlocker/
```

Example:

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

Make a backup of your current working modules before replacing them.

## 5. Disable IOMMU for the P2P test

On the tested bare-metal Linux system, P2P bandwidth remained extremely low until IOMMU was fully disabled.

Edit `/etc/default/grub` and add:

```text
intel_iommu=off iommu=off
```

Example:

```text
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash intel_iommu=off iommu=off"
```

The test system also disabled ACS redirect on the two GPU root ports:

```text
pci=disable_acs_redir=0000:80:02.0
pci=disable_acs_redir=0000:80:03.0
```

Do **not** copy those PCI addresses blindly. They are specific to the tested motherboard topology.

Apply GRUB and reboot:

```bash
sudo update-grub
sudo reboot
```

After reboot:

```bash
cat /proc/cmdline
```

Confirm that `intel_iommu=off iommu=off` is present.

> Disabling IOMMU affects DMA isolation, virtualization and PCI passthrough. Only use this configuration if that trade-off is acceptable for your system.

## 6. Verify PCIe link width and speed

Find the GPU BDFs:

```bash
nvidia-smi --query-gpu=index,pci.bus_id --format=csv
```

Then check each GPU:

```bash
sudo lspci -vv -s 82:00.0 | grep -E 'LnkCap:|LnkSta:'
sudo lspci -vv -s 83:00.0 | grep -E 'LnkCap:|LnkSta:'
```

The tested cards reported:

```text
LnkCap: Speed 5GT/s, Width x16
LnkSta: Speed 5GT/s, Width x16
```

## 7. Verify P2P capability

```bash
nvidia-smi topo -p2p r
nvidia-smi topo -p2p w
nvidia-smi topo -p2p p
```

A working capability matrix should show `OK` between the GPUs.

This alone is not enough. Always test actual bandwidth.

## 8. Run the CUDA P2P bandwidth test

Build NVIDIA CUDA Samples and run `p2pBandwidthLatencyTest`.

Example path on the tested machine:

```bash
cd ~/cuda-samples/Samples/5_Domain_Specific/p2pBandwidthLatencyTest
```

Depending on CUDA Samples version, the directory may instead be under `cpp/5_Domain_Specific`.

Run:

```bash
./p2pBandwidthLatencyTest
```

Expected healthy range on the tested Gen2 x16 system:

```text
Unidirectional P2P enabled: ~6.4–6.7 GB/s
Bidirectional P2P enabled: ~12.9–13.2 GB/s
GPU latency: ~1.6 us
```

## 9. Quick diagnosis

Run the repository helper:

```bash
bash scripts/check-p2p.sh
```

It performs read-only checks for driver version, GPU inventory, PCIe link state, IOMMU state, P2P topology and ACS status.

## Rollback

If the modified driver fails to boot or initialize correctly, restore your backed-up kernel modules, then run:

```bash
sudo depmod -a
sudo update-initramfs -u -k "$(uname -r)"
sudo reboot
```
