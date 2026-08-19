# Benchmarks

All numbers below are from the same dual-CMP 170HX system unless otherwise noted.

## Hardware and software

```text
GPU0: NVIDIA CMP 170HX 64 GB
GPU1: NVIDIA CMP 170HX 64 GB
PCIe: Gen2 x16 per GPU
Driver: 610.43.03
CUDA UMD: 13.3
Kernel: 7.0.0-29-generic
```

## Summary table

| Stage | P2P state | 0→1 GB/s | 1→0 GB/s | Bidirectional 0→1 | Bidirectional 1→0 | GPU latency 0→1 | GPU latency 1→0 |
|---|---|---:|---:|---:|---:|---:|---:|
| Early test | Disabled | 5.87 | 5.97 | 8.15 | 8.38 | 21.57 µs | 23.20 µs |
| Early test | Enabled, broken | 0.29 | 0.29 | 0.55 | 0.53 | 1.78 µs | 1.90 µs |
| Mailbox fixed, IOMMU active | Disabled | 5.89 | 5.98 | 8.13 | 8.41 | 62.59 µs | 19.97 µs |
| Mailbox fixed, IOMMU active | Enabled | 0.47 | 0.49 | 0.89 | 0.89 | 1.62 µs | 1.94 µs |
| Final config, IOMMU off | Disabled | 5.88 | 5.94 | 8.06 | 8.32 | 62.67 µs | 17.57 µs |
| Final config, IOMMU off | **Enabled** | **6.46** | **6.69** | **12.90** | **13.18** | **1.65 µs** | **1.59 µs** |

## Final working result

```text
Unidirectional P2P=Enabled Bandwidth (P2P Writes) Matrix (GB/s)
   D\D     0      1
     0 1671.12   6.46
     1   6.69 1718.92

Bidirectional P2P=Enabled Bandwidth Matrix (GB/s)
   D\D     0      1
     0 1703.93  12.90
     1  13.18 1747.76

P2P=Enabled Latency (P2P Writes) Matrix (us)
   GPU     0      1
     0   2.51   1.65
     1   1.59   2.37
```

## Before vs after

Using the final P2P-disabled and P2P-enabled measurements:

| Metric | P2P disabled | Working P2P | Change |
|---|---:|---:|---:|
| 0→1 bandwidth | 5.88 GB/s | 6.46 GB/s | +9.9% |
| 1→0 bandwidth | 5.94 GB/s | 6.69 GB/s | +12.6% |
| Bidirectional 0→1 | 8.06 GB/s | 12.90 GB/s | +60.0% |
| Bidirectional 1→0 | 8.32 GB/s | 13.18 GB/s | +58.4% |
| GPU latency 0→1 | 62.67 µs | 1.65 µs | ~38× lower |
| GPU latency 1→0 | 17.57 µs | 1.59 µs | ~11× lower |

P2P-disabled latency varied considerably between runs, so bandwidth is the more reproducible comparison.

## Important observation

The most misleading state was the early broken P2P setup:

```text
CAN Access Peer: YES
P2P latency: ~1.8 us
P2P bandwidth: ~0.29 GB/s
```

That combination proves why capability and latency alone are not enough to validate P2P. Always check throughput.

## LLM observation

After the final P2P fix, tensor-split inference showed noticeably smoother utilization across both GPUs, with much less oscillation in load. LLM token-per-second measurements are workload-dependent and should be collected separately from the CUDA transport benchmark.
