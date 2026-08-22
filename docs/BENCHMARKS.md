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

## MMA / Tensor Core unlock verification

A 64 GB memory unlock alone does not prove that the CMP compute throttle is gone. We therefore verified the Tensor Core path independently using both throughput measurements and direct `mma.sync` latency microbenchmarks.

Direct test guide:

- [English — MMA/Tensor unlock verification](MMA-UNLOCK.md)
- [Русский — проверка полного MMA/Tensor unlock](MMA-UNLOCK.ru.md)

### Tensor throughput

| Compute test | GPU0 | GPU1 |
|---|---:|---:|
| TF32 Tensor | 99.82 TFLOPS | 98.06 TFLOPS |
| BF16 Tensor | 201.55 TFLOPS | 198.00 TFLOPS |
| INT8 Tensor | 409.77 TOPS | 403.00 TOPS |

### Direct MMA latency

Measured with `arabel1a/gpu-micro-bench` using:

```bash
~/gpu-micro-bench/bin/tensor_bench 0 10000 1000 20
~/gpu-micro-bench/bin/tensor_bench 1 10000 1000 20
```

| MMA latency test | GPU0 | GPU1 |
|---|---:|---:|
| F16 `mma.sync` | 26.0 cycles | 26.5 cycles |
| BF16 `mma.sync` | 26.0 cycles | 26.5 cycles |
| TF32 `mma.sync` | 26.0 cycles | 26.5 cycles |
| INT8 `mma.sync` | 26.8 cycles | 27.3 cycles |

A throttled CMP 170HX is expected to be around the ~256-cycle regime; our ~26-cycle results directly confirm the full MMA/Tensor compute unlock on both cards.

## HBM clock A/B

We also verified that userspace HBM tuning changes real bandwidth rather than merely changing the NDIV register.

| HBM setting | Global read | Global triad | cudaMemcpy D2D |
|---|---:|---:|---:|
| NDIV 64 / 1728 MHz | 1669.19 GB/s | 1605.24 GB/s | 1584.58 GB/s |
| NDIV 70 / 1890 MHz | 1818.99 GB/s | 1767.93 GB/s | 1756.65 GB/s |

The NDIV 70 run therefore produced roughly a 9–11% real memory-bandwidth increase over stock on this card.

## llama.cpp compute / multi-GPU A/B

Using the same Qwen 3.8 27B BF16 model (50.89 GiB) and the same `llama-bench` build:

```text
1x CMP 170HX:
pp512 = 1141.23 t/s
tg128 =   24.72 t/s

2x CMP 170HX, layer split 50/50:
pp512 = 1842.04 t/s
tg128 =   26.97 t/s
```

The second CMP improved prompt processing by about 61% and single-stream token generation by about 9% on this workload. For `llama-bench`, the correct two-GPU tensor-split syntax is `-ts 50/50`; `50,50` requests two separate benchmark parameter values.

## P2P summary table

| Stage | P2P state | 0→1 GB/s | 1→0 GB/s | Bidirectional 0→1 | Bidirectional 1→0 | GPU latency 0→1 | GPU latency 1→0 |
|---|---|---:|---:|---:|---:|---:|---:|
| Early test | Disabled | 5.87 | 5.97 | 8.15 | 8.38 | 21.57 µs | 23.20 µs |
| Early test | Enabled, broken | 0.29 | 0.29 | 0.55 | 0.53 | 1.78 µs | 1.90 µs |
| Mailbox fixed, IOMMU active | Disabled | 5.89 | 5.98 | 8.13 | 8.41 | 62.59 µs | 19.97 µs |
| Mailbox fixed, IOMMU active | Enabled | 0.47 | 0.49 | 0.89 | 0.89 | 1.62 µs | 1.94 µs |
| Final config, IOMMU off | Disabled | 5.88 | 5.94 | 8.06 | 8.32 | 62.67 µs | 17.57 µs |
| Final config, IOMMU off | **Enabled** | **6.46** | **6.69** | **12.90** | **13.18** | **1.65 µs** | **1.59 µs** |

## Final working P2P result

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

## P2P before vs after

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

After the final P2P fix, tensor-split inference showed noticeably smoother utilization across both GPUs, with much less oscillation in load. LLM token-per-second measurements remain workload-dependent, so CUDA transport benchmarks and LLM throughput should be treated as complementary measurements rather than interchangeable proof.