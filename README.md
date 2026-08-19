# CMP 170HX Linux P2P

Experimental Linux patch and documentation for enabling **working CUDA Peer-to-Peer (P2P)** communication between NVIDIA CMP 170HX GPUs.

> **Measured on 2× CMP 170HX 64 GB:** ~6.5–6.7 GB/s one-way, ~13 GB/s bidirectional, ~1.6 µs GPU-to-GPU latency over PCIe Gen2 x16.

## Why this project exists

On the tested system CUDA reported that peer access was available, yet actual P2P bandwidth was catastrophically slow:

```text
Device=0 CAN Access Peer Device=1
Device=1 CAN Access Peer Device=0

P2P Enabled bandwidth: ~0.29–0.49 GB/s
```

After fixing the CMP/GA100 mailbox path and fully disabling IOMMU, the same test reached:

```text
GPU0 -> GPU1: 6.46 GB/s
GPU1 -> GPU0: 6.69 GB/s
Bidirectional: 12.90–13.18 GB/s
GPU latency: 1.59–1.65 us
```

The key lesson is simple: **`CAN Access Peer = YES` does not prove that the P2P data path is healthy. Always benchmark it.**

## Tested configuration

| Component | Tested value |
|---|---|
| GPUs | 2× NVIDIA CMP 170HX, 64 GB each |
| NVIDIA KMD | 610.43.03 |
| CUDA UMD | 13.3 |
| Linux kernel | 7.0.0-29-generic |
| PCIe | Gen2 x16 per GPU |
| IOMMU | Disabled |
| ACS redirect | Disabled for both GPU root ports |

## Quick navigation

- [Installation and verification](docs/INSTALL.md)
- [How the P2P failure and fix work](docs/P2P-EXPLAINED.md)
- [Benchmarks](docs/BENCHMARKS.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Mailbox patch](patches/p2p-cmp170-mailbox-fix.patch)
- [Patch notes](patches/README.md)
- [Contribution / reproduction guide](CONTRIBUTING.md)
- [Raw successful benchmark](results/dual-cmp170hx-610.43.03.txt)

## The CMP mailbox fix

The broader P2P modification being tested forced:

```c
pKernelBif->pcieP2PType = NV_REG_STR_RM_PCIEP2P_TYPE_BAR1;
```

On the tested GA100-based CMP 170HX system, that left the normal PCIe write-mailbox address invalid:

```text
mailbox=0xffffffffffffffff
baseMask=0xfff
```

and triggered:

```text
Assertion failed: ((base & RM_PAGE_MASK) == 0)
```

The working change is:

```c
pKernelBif->pcieP2PType = NV_REG_STR_RM_PCIEP2P_TYPE_DEFAULT;
```

After this change:

```text
mailbox=0x0
baseMask=0x0
```

The ready-to-apply patch is in [`patches/p2p-cmp170-mailbox-fix.patch`](patches/p2p-cmp170-mailbox-fix.patch).

## IOMMU was the second bottleneck

Fixing the mailbox removed the assertion, but P2P bandwidth was still only ~0.47–0.49 GB/s while Linux IOMMU remained active.

On the tested bare-metal system, the final working kernel command line included:

```text
intel_iommu=off iommu=off
```

After rebooting with IOMMU fully disabled, P2P bandwidth jumped to ~6.5–6.7 GB/s per direction.

> Disabling IOMMU affects DMA isolation, virtualization and PCI passthrough. Read [INSTALL.md](docs/INSTALL.md) before changing your system.

## Before / after

| Metric | P2P disabled | Broken P2P | Working P2P |
|---|---:|---:|---:|
| 0→1 bandwidth | ~5.88 GB/s | ~0.29–0.47 GB/s | **6.46 GB/s** |
| 1→0 bandwidth | ~5.94 GB/s | ~0.29–0.49 GB/s | **6.69 GB/s** |
| Bidirectional | ~8.1–8.3 GB/s | ~0.5–0.9 GB/s | **12.90–13.18 GB/s** |
| GPU P2P latency | tens of µs without peer path | ~1.6–1.9 µs | **~1.6 µs** |

For the full measurement history, see [BENCHMARKS.md](docs/BENCHMARKS.md).

## Verify your own system

Run the read-only helper:

```bash
bash scripts/check-p2p.sh
```

For a shareable diagnostic report:

```bash
bash scripts/collect-debug-info.sh
```

Then run NVIDIA's `p2pBandwidthLatencyTest`. A healthy result on the tested Gen2 x16 setup is approximately:

```text
Unidirectional P2P enabled: 6.4–6.7 GB/s
Bidirectional P2P enabled: 12.9–13.2 GB/s
GPU latency: ~1.6 us
```

## AI / LLM relevance

Working peer transport is useful for multi-GPU workloads such as:

- `llama.cpp` tensor split
- multi-GPU local LLM inference
- CUDA peer transfers
- tensor-parallel workloads

In the first practical tensor-split tests after the final P2P fix, utilization across both CMP GPUs became noticeably smoother and stopped showing the previous oscillating pattern. Application token/s gains are workload-dependent and should be benchmarked separately from the CUDA transport test.

## Experimental status

This result has currently been validated on **one dual-CMP 170HX system**. Other driver versions, kernels, motherboards and PCIe topologies may behave differently.

If you reproduce the result, please open a GitHub issue using the reproduction template and include your full `p2pBandwidthLatencyTest` output. More independent systems are needed before this can be considered broadly validated.

## License

Project-authored scripts and documentation are released under the [MIT License](LICENSE). NVIDIA source code and NVIDIA Open GPU Kernel Modules remain under their respective upstream licenses; this repository does not redistribute NVIDIA proprietary binaries.
