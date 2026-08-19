# CMP 170HX P2P: two working approaches

This project tracks more than one way to obtain real GPU-to-GPU traffic on CMP 170HX. The goal is not to declare one implementation universally correct, but to preserve reproducible paths, their requirements, and measured results.

> **Important:** do not mix the two protocol choices blindly. The mailbox/default path and the BAR1 path intentionally select different NVIDIA P2P mechanisms.

## Quick comparison

| Item | Path A — DEFAULT / mailbox path (this project) | Path B — static BAR1 path (`bayley/cmpunlocker`) |
|---|---|---|
| Tested GPU | 2× CMP 170HX 64 GB | CMP 170HX, 4-GPU and later 8-GPU systems |
| Driver base | nvidia-open 610.43.03 | nvidia-open 610.43.03 / 610.43.02 |
| P2P protocol choice | `NV_REG_STR_RM_PCIEP2P_TYPE_DEFAULT` | `NV_REG_STR_RM_PCIEP2P_TYPE_BAR1` |
| Large BAR1 required | No on our tested system | Yes — 64 GB BAR1 per GPU |
| Patched host kernel required | No for our tested path | Yes for normal-boot 64 GB BAR1 on the documented Bayley setup |
| IOMMU | Fully disabled on our working bare-metal test | Bayley documents its own IOMMU/host setup; verify on your platform |
| ACS | Redirect disabled on relevant root ports | Important for performance; Bayley measured a same-switch gain after disabling redirects |
| Measured one-way | **6.46 / 6.69 GB/s** at Gen2 x16 | **~1.68 GB/s** at Gen2 x4 |
| Measured bidirectional | **12.90–13.18 GB/s** | topology/test dependent |
| GPU latency | **~1.59–1.65 µs** | see upstream measurements |
| Complexity | Lower if IOMMU-off bare metal is acceptable | Higher: large BAR1, kernel/MMIO sizing, BAR1-specific driver patches |

The bandwidth values are not directly comparable because the link widths differ: our cards are physically modified to Gen2 x16, while the published Bayley result quoted above is Gen2 x4.

---

# Path A — DEFAULT / mailbox path

This is the path developed and measured in this repository.

## Base work

We started from the combined P2P modification in:

- <https://github.com/aikitoria/open-gpu-kernel-modules/tree/610.43.03-p2p>
- P2P commit used for the experiment: `9fb65044`

The base modification forced BAR1 P2P globally. On our GA100/CMP system this produced an invalid mailbox state in a path that still attempted mailbox setup:

```text
mailbox=0xffffffffffffffff
baseMask=0xfff
Assertion failed: ((base & RM_PAGE_MASK) == 0)
```

We changed the CMP path back to the NVIDIA default protocol selection:

```c
pKernelBif->pcieP2PType = NV_REG_STR_RM_PCIEP2P_TYPE_DEFAULT;
```

The project patch is:

- [`../patches/p2p-cmp170-mailbox-fix.patch`](../patches/p2p-cmp170-mailbox-fix.patch)

After the fix our instrumentation reported:

```text
mailbox=0x0
baseMask=0x0
```

The assertion disappeared.

## IOMMU was decisive

With the mailbox fixed but Linux IOMMU active, the CUDA sample still measured only about:

```text
0.47–0.49 GB/s P2P enabled
```

On our bare-metal system, fully disabling IOMMU with:

```text
intel_iommu=off iommu=off
```

changed the same P2P test to:

```text
GPU0 -> GPU1: 6.46 GB/s
GPU1 -> GPU0: 6.69 GB/s
Bidirectional: 12.90–13.18 GB/s
GPU latency: 1.59–1.65 us
```

This is the strongest evidence for this path: real bandwidth changed by more than an order of magnitude while the cards and PCIe topology remained the same.

### Advantages

- No 64 GB BAR1 was required on our tested machine.
- No custom host-kernel BAR sizing patch was required.
- Very good throughput on Gen2 x16.
- Simple success criterion with NVIDIA's `p2pBandwidthLatencyTest`.

### Trade-offs

- We currently require IOMMU fully off on the tested bare-metal host. This affects DMA isolation, virtualization and device passthrough.
- It is validated on one dual-CMP host so far.
- Other CPU/root-complex topologies may behave differently.

---

# Path B — static BAR1 P2P (`bayley/cmpunlocker`)

Upstream:

- <https://github.com/bayley/cmpunlocker>

Bayley's implementation explicitly avoids the normal mailbox/proprietary P2P data path. It maps peer framebuffer memory through the remote GPU's BAR1 bus address and rewrites peer PTEs to system coherent/non-coherent apertures.

## Driver pieces

The current upstream patch set contains the important P2P pieces:

```text
driver/patches/0011-p2p-bar1.patch
driver/patches/0013-skip-mailbox-peer-preinit.patch
driver/patches/0015-bar1p2p-readcap-override.patch
```

### `0011-p2p-bar1.patch`

Key ideas include:

- force/enable BAR1 P2P HAL implementations for the relevant path;
- select BAR1 P2P for CMP device IDs;
- add the `_PCIE_BAR1` branch to the GP100-and-later bus path;
- rewrite peer PTE aperture from `GMMU_APERTURE_PEER` to `SYS_COH` / `SYS_NONCOH` when BAR1 P2P is used;
- point the mapping at the peer BAR1 bus address.

### `0013-skip-mailbox-peer-preinit.patch`

NVIDIA's GM107-era initialization can pre-register mailbox peer IDs before a P2P request. A non-zero mailbox `peerNumberMask` prevents BAR1 P2P from being accepted because RM permits only one PCIe P2P protocol at a time.

This patch skips mailbox peer pre-registration when BAR1 is intentionally selected.

### `0015-bar1p2p-readcap-override.patch`

On the documented Xeon E5 v4 + PLX host, NVIDIA topology discovery failed to recognise the common downstream switch and denied the BAR1-P2P read capability. This patch restores the read cap for CMP device IDs.

Treat this as topology-sensitive. Re-test on a different host instead of assuming that a forced capability is universally valid.

## 64 GB BAR1 and host kernel patches

The Bayley approach requires a large static BAR1. Their repository contains:

```text
kernel-patches/0001-pci-size-bridge-window-for-child-alignment.patch
kernel-patches/0002-pci-quirk-cmp170hx-rebar-early.patch
```

These address two different boot-time problems:

1. correctly budget large/aligned child BARs when sizing PCI bridge windows;
2. expose/program CMP 170HX BAR1 to 64 GB early enough that PCI enumeration allocates sufficient space.

For many GPUs, MMIO space becomes a major platform requirement. Their eight-GPU configuration documents a large BIOS MMIO-high window and `pci=hpmmioprefsize=2T`.

Typical BAR1-specific module settings documented upstream include:

```text
RMForceStaticBar1=1
RMPcieP2PType=1
```

After changing NVIDIA module options, rebuild the initramfs before rebooting.

## Published measurements

Bayley's README reports approximately:

```text
1.68 GB/s each way at PCIe Gen2 x4
```

on a four-GPU mesh, with later testing across eight GPUs on two PCIe switches on the same CPU root complex. The project also stresses verifying real transfers rather than trusting `cudaDeviceCanAccessPeer()` alone.

The same upstream work reports ACS as a performance issue: on one switch, disabling request/completion redirect increased same-switch traffic from roughly 1.20 GB/s to 1.68 GB/s.

### Advantages

- Does not depend on the normal CMP mailbox peer aperture for data movement.
- Demonstrated on larger multi-GPU topologies than our current dual-GPU test.
- Provides a path for hosts where mailbox/default P2P remains unusable.

### Trade-offs

- Much larger host-MMIO requirements.
- 64 GB BAR1 per GPU.
- Patched host kernel on the documented implementation.
- More topology-specific capability overrides and ACS considerations.

---

# Which path should I try?

For a beginner with two CMP 170HX cards:

1. First get the normal memory/compute unlock and PCIe Gen2 stable.
2. Verify actual link width/speed with `lspci -vv`.
3. If you have a simple bare-metal dual-GPU host and can accept IOMMU being disabled, the DEFAULT/mailbox path in this repository is the simpler first experiment.
4. If you need a many-GPU topology, large BAR1 for other reasons, or the mailbox path does not move data correctly on your platform, study Bayley's BAR1 implementation.
5. Do not apply both protocol-selection patches at the same time and hope RM chooses correctly. Pick one path, test it, record results, then change one variable at a time.

# Verification rule

For either approach, this is **not sufficient**:

```text
Device=0 CAN Access Peer Device=1
```

Use real data transfer tests. At minimum run NVIDIA's `p2pBandwidthLatencyTest`; for new/unusual PTE rewrites, an alias-proof peer copy test is even better.

Record:

- `nvidia-smi topo -m`
- `nvidia-smi topo -p2p r/w/p`
- `lspci -vv` link status and ACS state
- BAR1 size
- IOMMU state
- complete P2P bandwidth/latency output
- kernel and NVIDIA driver versions

That makes results comparable instead of anecdotal.
