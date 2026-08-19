# CMP 170HX Linux P2P

Experimental Linux patches and setup notes for enabling working CUDA Peer-to-Peer communication between NVIDIA CMP 170HX GPUs.

## Status

Tested successfully on a dual-CMP 170HX system with NVIDIA Open GPU Kernel Modules 610.43.03.

### Tested configuration

- 2× NVIDIA CMP 170HX, 64 GB each
- NVIDIA driver / KMD: 610.43.03
- CUDA UMD: 13.3
- Linux kernel: 7.0.0-29-generic
- PCIe: Gen2 x16 per GPU
- IOMMU: disabled
- ACS redirect: disabled for both GPU root ports

## Measured result

Before the final fixes, CUDA reported peer access as available, but P2P bandwidth was broken:

```text
Device=0 CAN Access Peer Device=1
Device=1 CAN Access Peer Device=0

P2P Enabled bandwidth: ~0.29–0.49 GB/s
Bidirectional: ~0.5–0.9 GB/s
```

After the mailbox fix and fully disabling IOMMU:

```text
GPU0 -> GPU1: 6.46 GB/s
GPU1 -> GPU0: 6.69 GB/s

Bidirectional:
GPU0 <-> GPU1: 12.90–13.18 GB/s

GPU latency:
~1.59–1.65 us
```

For comparison, with P2P disabled on the same system:

```text
GPU0 -> GPU1: ~5.88 GB/s
GPU1 -> GPU0: ~5.94 GB/s
Bidirectional: ~8.1–8.3 GB/s
```

This corresponds to roughly +10–13% unidirectional bandwidth and +58–60% bidirectional bandwidth, while GPU-to-GPU latency drops dramatically.

## Important finding

`cudaDeviceCanAccessPeer()` returning true is **not sufficient proof** that P2P is working correctly.

Our broken configuration already reported:

```text
Device=0 CAN Access Peer Device=1
Device=1 CAN Access Peer Device=0
```

and even showed low P2P latency, while actual bandwidth was only ~0.29–0.49 GB/s.

Always verify peer bandwidth with `p2pBandwidthLatencyTest`.

## Root causes found

Two separate issues were identified on the tested CMP 170HX setup:

1. The P2P patch forced `NV_REG_STR_RM_PCIEP2P_TYPE_BAR1`, but the GA100/CMP mailbox path expects the normal PCIe mailbox setup. This left `writeMailboxBar1Addr` at the invalid value `0xffffffffffffffff`.
2. Even after fixing the mailbox allocation, Linux IOMMU remained active and reduced peer bandwidth to ~0.5 GB/s. Fully disabling IOMMU restored normal PCIe P2P performance.

Debug output before the mailbox fix:

```text
mailbox=0xffffffffffffffff
baseMask=0xfff
```

After the mailbox fix:

```text
mailbox=0x0
baseMask=0x0
```

## Mailbox fix

File:

```text
src/nvidia/src/kernel/gpu/bif/kernel_bif.c
```

Change:

```c
pKernelBif->pcieP2PType = NV_REG_STR_RM_PCIEP2P_TYPE_BAR1;
```

to:

```c
pKernelBif->pcieP2PType = NV_REG_STR_RM_PCIEP2P_TYPE_DEFAULT;
```

A ready-to-apply patch is included in `patches/p2p-cmp170-mailbox-fix.patch`.

## IOMMU requirement

On the tested bare-metal Linux system, P2P bandwidth only became healthy after fully disabling IOMMU.

Example GRUB configuration:

```text
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash intel_iommu=off iommu=off"
```

If you also need to disable ACS redirect for specific GPU root ports, keep those parameters as well, for example:

```text
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash intel_iommu=off iommu=off pci=disable_acs_redir=0000:80:02.0 pci=disable_acs_redir=0000:80:03.0"
```

**Do not copy those PCI addresses blindly.** They are motherboard/topology-specific.

Then run:

```bash
sudo update-grub
sudo reboot
```

Verify after reboot:

```bash
cat /proc/cmdline
```

and confirm that `intel_iommu=off iommu=off` is present.

Disabling IOMMU has system-wide consequences for DMA isolation, virtualization and passthrough. Use this only if the trade-off is acceptable for your machine.

## Verify P2P

Build and run NVIDIA's CUDA sample:

```text
cuda-samples/Samples/5_Domain_Specific/p2pBandwidthLatencyTest
```

Expected capability result:

```text
Device=0 CAN Access Peer Device=1
Device=1 CAN Access Peer Device=0
```

But also verify actual P2P-enabled bandwidth. On the tested dual-CMP Gen2 x16 system, a healthy result is around:

```text
Unidirectional: 6.4–6.7 GB/s
Bidirectional: 12.9–13.2 GB/s
Latency: ~1.6 us
```

## Patch order used in the tested driver tree

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

Optional debug patch:

```text
p2p-bar1-610.patch
p2p-cmp170-mailbox-fix.patch
p2p-cmp170-debug.patch
name-string.patch
```

The debug patch is not required for normal use.

## AI / LLM relevance

Working P2P is particularly useful for multi-GPU workloads such as:

- llama.cpp tensor split
- multi-GPU local LLM inference
- CUDA peer transfers
- tensor-parallel workloads

In the first practical tests after fixing P2P, GPU utilization during tensor-split inference became noticeably smoother and stopped showing the previous oscillating behavior.

## Experimental status

This result has been reproduced on one tested system with two CMP 170HX cards. Other driver versions, kernels, motherboards and PCIe topologies may behave differently.

Please open an issue with your hardware, kernel, driver, topology and `p2pBandwidthLatencyTest` results if you reproduce it.
