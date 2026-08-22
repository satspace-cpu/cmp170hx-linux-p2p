# CMP 170HX: verifying the full MMA / Tensor Core unlock

This page complements the main guide and answers a separate question: **is the Tensor Core compute throttle actually gone, or does the card merely expose more HBM?**

Memory unlock and compute unlock are different things. A CMP 170HX can expose 64 GB HBM while still retaining an artificial `mma.sync` throttle if the compute unlock is incomplete.

## What is being throttled

On a stock or incompletely unlocked CMP 170HX, Tensor Core MMA instructions show abnormally high latency. A useful diagnostic rule of thumb is:

```text
MMA latency around 256 cycles  -> throttle still present
MMA latency around 24–27 cycles -> full compute unlock active
```

This matters most for matrix-heavy workloads such as LLM prefill/prompt processing, GEMM, and BF16/FP16/TF32 Tensor Core work.

After the full compute unlock, a 70-SM CMP 170HX reaches roughly the normal GA100 Tensor Core performance for its enabled SM count instead of remaining at only a few TFLOPS.

## Quick check with Tensor throughput

A CUDA benchmark that measures Tensor Core throughput is a useful first check.

Measured on our system after the full unlock:

| Test | GPU0 | GPU1 |
|---|---:|---:|
| TF32 Tensor | 99.82 TFLOPS | 98.06 TFLOPS |
| BF16 Tensor | 201.55 TFLOPS | 198.00 TFLOPS |
| INT8 Tensor | 409.77 TOPS | 403.00 TOPS |

If BF16 Tensor remains in the single-digit TFLOPS range, that is a strong indication that the MMA/Tensor throttle is still active.

## Direct `mma.sync` latency measurement

For an instruction-level check, use:

- https://github.com/arabel1a/gpu-micro-bench

It generates Ampere `mma.sync` microbenchmarks and measures single-chain latency and throughput for F16, BF16, TF32, INT8, and FP64.

### 1. Clone the benchmark

```bash
git clone https://github.com/arabel1a/gpu-micro-bench.git
cd gpu-micro-bench
```

### 2. Generate and build the Tensor benchmark

If CUDA Toolkit is installed but `nvcc` is not in `PATH`, add the Toolkit bin directory. Our system used CUDA 13.1:

```bash
PATH=/usr/local/cuda-13.1/bin:$PATH python3 gen_tensor.py
```

The resulting binary is:

```text
bin/tensor_bench
```

If compilation succeeds and the generator later complains only that `cuobjdump` is missing, `tensor_bench` may already be usable. Add the directory containing `cuobjdump` to `PATH` for the full SASS verification pass.

### 3. Test GPU0

```bash
~/gpu-micro-bench/bin/tensor_bench 0 10000 1000 20
```

### 4. Test GPU1

```bash
~/gpu-micro-bench/bin/tensor_bench 1 10000 1000 20
```

The arguments used in our test were:

```text
GPU index = 0 or 1
n_iters   = 10000
n_warmup  = 1000
n_reps    = 20
```

## Which lines matter

Look at entries with the `_lat` suffix, for example:

```text
mma_m16n8k16_f16f16f32,lat
mma_m16n8k16_bf16bf16f32,lat
mma_m16n8k8_tf32tf32f32,lat
```

Measured on our system:

```text
GPU0:
F16  MMA latency  ~26.0 cycles
BF16 MMA latency  ~26.0 cycles
TF32 MMA latency  ~26.0 cycles
INT8 MMA latency  ~26.8 cycles

GPU1:
F16  MMA latency  ~26.5 cycles
BF16 MMA latency  ~26.5 cycles
TF32 MMA latency  ~26.5 cycles
INT8 MMA latency  ~27.3 cycles
```

This directly confirms that both cards are operating in the fully unlocked MMA/Tensor regime rather than the roughly 256-cycle throttled state.

## Why `nvidia-smi` is not enough

`nvidia-smi` can confirm HBM capacity, PCIe link information, power limits and other properties, but it does not expose actual `mma.sync` latency.

A useful full checklist is therefore:

```text
VRAM              -> 64 GB
BAR1              -> 64 GB
PCIe              -> Gen2 x16
HBM bandwidth     -> real bandwidth benchmark
Tensor throughput -> ~200 TFLOPS BF16 on our configuration
MMA latency       -> ~24–27 cycles
```

## Impact on llama.cpp

Compute/MMA unlock is especially visible in prompt processing (`pp` / prefill), where matrix operations dominate more heavily than in single-stream autoregressive decode.

For a clean A/B comparison, use the same model and identical `llama-bench` parameters.

### One CMP

```bash
CUDA_VISIBLE_DEVICES=0 \
/path/to/llama-bench \
-m /path/to/model.gguf \
-p 512 \
-n 128 \
-ngl 99
```

### Two CMPs, 50/50 layer split

```bash
CUDA_VISIBLE_DEVICES=0,1 \
/path/to/llama-bench \
-m /path/to/model.gguf \
-p 512 \
-n 128 \
-ngl 99 \
-sm layer \
-ts 50/50
```

Important: for `llama-bench`, a two-GPU tensor split is written as `50/50`. Writing `50,50` requests two benchmark parameter values and produces two benchmark sets.

On our Qwen 3.8 27B BF16 model (50.89 GiB):

```text
1x CMP 170HX:
pp512 = 1141.23 t/s
tg128 =   24.72 t/s

2x CMP 170HX, 50/50:
pp512 = 1842.04 t/s
tg128 =   26.97 t/s
```

On this specific workload the second card improved `pp512` by about **61%** and `tg128` by about **9%**. This is a good example of why the MMA unlock matters especially for prefill.

## Relationship to the other unlocks

These mechanisms solve different problems:

- **64 GB HBM** increases usable memory capacity;
- **HBM tuning / 170tune** controls memory clock/timings and validates stability;
- **64 GB BAR1** enlarges the PCIe BAR1 aperture;
- **PCIe x16 hardware mod** restores physical link width;
- **PCIe Gen2 unlock** raises the negotiated link from Gen1 to Gen2;
- **CUDA P2P** enables direct GPU-to-GPU access;
- **MMA/Tensor unlock** removes the artificial Tensor Core instruction-rate throttle.

A card reporting 64 GB therefore does not by itself prove that compute is fully unlocked.

## Confirmed result on our system

For our two CMP 170HX cards we have confirmed:

```text
VRAM:             65536 MiB per card
BAR1:             64.0 GiB per card
PCIe:             Gen2 x16
HBM NDIV 70:      real bandwidth increase versus NDIV 64
BF16 Tensor:      ~198–202 TFLOPS per card
MMA latency:      ~26.0–26.5 cycles
```

We consider this a confirmed full compute/MMA unlock for our cards.

## Important

These measurements apply to our specific cards, driver, kernel and platform. Do not assume another card's clocks or power limit are safe on yours. Validate HBM/SM changes independently and test for silent corruption before persisting them.