# CMP 170HX Linux Guide: 64 GB Unlock → 170tune → PCIe x16 → P2P

[Русская версия](README.ru.md) · [Physical x4→x16 mod](docs/PCIE-X16-HARDWARE-MOD.md) · [Русская инструкция x4→x16](docs/PCIE-X16-HARDWARE-MOD.ru.md) · [Benchmarks](docs/BENCHMARKS.md) · [Troubleshooting](docs/TROUBLESHOOTING.md)

A beginner-friendly end-to-end guide for NVIDIA CMP 170HX owners.

**Recommended path:**

**stock CMP 170HX → memory/compute unlock → 170tune validation → physical PCIe x4→x16 hardware mod → PCIe Gen2 software unlock → working CUDA P2P → multi-GPU LLM testing**

> **Current verified P2P result:** Static BAR1 on GPU1 `82:00.0` ↔ GPU2 `83:00.0` achieved **5.30 GB/s one-way**, **10.27 GB/s bidirectional** and **1.69–1.71 µs** over PCIe Gen2 x16. CUDA peer copies plus direct SM remote reads and writes all passed. [Full English report](docs/STATIC-BAR1-P2P.md) · [Русский отчёт](docs/STATIC-BAR1-P2P.ru.md)

---

## Read this first

CMP 170HX modding is experimental. This guide includes patched NVIDIA kernel modules, Linux boot parameters, tuning and an optional hardware soldering modification. Keep physical/remote recovery access and change one thing at a time.

---

# Stage 1 — Unlock CMP 170HX

Use the community unlock work first:

- https://github.com/amoghmunikote/cmpunlocker
- https://github.com/Consensus-Protocol/cmp170hx

The common 8 GB CMP 170HX can expose **64 GB HBM2e** after the tested unlock procedure.

Detailed beginner guide: [docs/UNLOCK.md](docs/UNLOCK.md)

---

# Stage 2 — Tune and validate with 170tune

Project:

- https://github.com/cachenetics/170tune

Use `170tune` to qualify HBM/clock changes and detect silent corruption before persistence.

Detailed guide: [docs/170TUNE.md](docs/170TUNE.md)

---

# Stage 3 — Physical PCIe x4 → x16 hardware modification

**This is a real separate step and must be done before expecting x16 bandwidth.**

The CMP 170HX PCB routes all 16 PCIe lanes, but the factory board leaves the coupling capacitors for lanes 4–15 unpopulated. To restore x16, populate **24 missing 0402 AC-coupling capacitors**.

Parts successfully used on our cards:

```text
Samsung CL05B224KO5NNNC
0.22 µF / 220 nF
X7R
16 V
0402
Quantity for x16: 24 pieces
```

ChipDip listing used for our build:

https://www.chipdip.ru/product/0.22mkf-x7r-16v-10-0402-cl05b224ko5nnnc-kondensator-samsung-9000681245

Recommended equipment: microscope/magnification, fine tweezers, good gel flux, fine temperature-controlled iron, solder wick and a multimeter. A controlled bottom preheater can make the job easier, but it is not mandatory; our successful cards were soldered without one. Avoid uncontrolled whole-board heating.

After soldering, verify the real negotiated width:

```bash
sudo lspci -vv -s <GPU_BDF> | grep -E 'LnkCap:|LnkSta:'
```

Successful hardware result:

```text
Width x16
```

With the separate Gen2 software work, our cards report approximately:

```text
LnkSta: Speed 5GT/s, Width x16
```

**Full physical-mod instructions:**

- [English — complete PCIe x4 → x16 soldering guide](docs/PCIE-X16-HARDWARE-MOD.md)
- [Русский — полная инструкция по физической переделке x4 → x16](docs/PCIE-X16-HARDWARE-MOD.ru.md)

These pages include the parts list, soldering workflow, preheating advice, diagnostics and upstream references.

---

# Stage 4 — PCIe Gen2 software unlock

The capacitor modification changes **link width**. Gen1 → Gen2 is a separate software change.

Current public research has Gen2 working. Gen3 remains an open research problem.

- [Gen3 status / research](docs/PCIE-GEN3-STATUS.md)
- [Русский статус Gen3](docs/PCIE-GEN3-STATUS.ru.md)

---

# Stage 5 — Enable and verify CUDA P2P

The current verified path is **Static BAR1**. It maps the remote GPU framebuffer
through the remote GPU's 64 GiB BAR1 window; it does not use the old mailbox
data path. On the current Gen2 x16 host it produced:

```text
GPU1 -> GPU2: 5.30 GB/s
GPU2 -> GPU1: 5.30 GB/s
Bidirectional: 10.27 GB/s
GPU latency: 1.69–1.71 us
```

The result is verified by both CUDA sample output and a separate content test:
`cuMemcpyPeer`, SM remote reads and SM remote writes passed in both directions.
Read the complete procedure, topology limits, chart and raw output in
[Static BAR1 P2P](docs/STATIC-BAR1-P2P.md).

> **Mailbox B2 correction:** previously published 6.69–6.70 GB/s Mailbox B2
> figures were a false positive. Later content testing found that peer VRAM was
> not modified and NCCL could hang. Do not use the mailbox path as evidence of
> real P2P; it is retained only as a historical recovery artifact.

Full results: [docs/BENCHMARKS.md](docs/BENCHMARKS.md)

---

# Stage 6 — Diagnose and exclude a physical HBM page

If `memtest_vulkan` reports a repeatable single-bit error while ECC and page
retirement are unavailable, use the physical-page mapping and software
blacklist procedure documented here:

- [English — HBM page diagnosis and retirement](docs/HBM-PAGE-RETIREMENT.md)
- [Русский — поиск и исключение страницы HBM](docs/HBM-PAGE-RETIREMENT.ru.md)

---

# Recommended order for a brand-new card

1. Install Linux and the supported NVIDIA Open Kernel Module version.
2. Verify the card is visible and stable at stock settings.
3. Unlock memory/compute with `cmpunlocker`.
4. Cold power-cycle and verify 64 GB / 40 GB geometry.
5. Install `170tune`, run preflight and validate stability.
6. **Perform the physical PCIe x4 → x16 capacitor modification if x16 is wanted.**
7. Verify `LnkSta` reports `Width x16`.
8. Apply/verify the PCIe Gen2 software unlock and confirm `Speed 5GT/s`.
9. Add the selected P2P path.
10. Verify IOMMU/ACS/topology for that P2P method.
11. Run `nvidia-smi topo -p2p`.
12. Run `p2pBandwidthLatencyTest` and judge P2P by actual bandwidth.
13. Benchmark the real LLM/CUDA workload.

---

# Project navigation

- [Unlock guide](docs/UNLOCK.md)
- [170tune guide](docs/170TUNE.md)
- **[PCIe x4 → x16 physical soldering guide](docs/PCIE-X16-HARDWARE-MOD.md)**
- **[Русская инструкция x4 → x16](docs/PCIE-X16-HARDWARE-MOD.ru.md)**
- [PCIe Gen3 research/status](docs/PCIE-GEN3-STATUS.md)
- [Verified Static BAR1 P2P](docs/STATIC-BAR1-P2P.md)
- [Проверенный Static BAR1 P2P](docs/STATIC-BAR1-P2P.ru.md)
- [HBM page diagnosis / retirement](docs/HBM-PAGE-RETIREMENT.md) · [Русский](docs/HBM-PAGE-RETIREMENT.ru.md)
- [P2P alternative paths](docs/P2P-ALTERNATIVE-PATHS.md)
- [How the P2P failure and fix work](docs/P2P-EXPLAINED.md)
- [Benchmarks](docs/BENCHMARKS.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Mailbox patch](patches/p2p-cmp170-mailbox-fix.patch)
- [Contribution / reproduction guide](CONTRIBUTING.md)
- [Raw successful P2P benchmark](results/dual-cmp170hx-610.43.03.txt)
- [Русская версия](README.ru.md)

---

## Experimental status

The complete result has currently been validated on one dual-CMP 170HX system. Other driver versions, kernels, motherboards, card revisions and PCIe topologies may behave differently.
