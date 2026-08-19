# CMP 170HX Linux Guide: 64 GB Unlock → 170tune → PCIe x16 → P2P

[Русская версия](README.ru.md) · [Physical x4→x16 mod](docs/PCIE-X16-HARDWARE-MOD.md) · [Русская инструкция x4→x16](docs/PCIE-X16-HARDWARE-MOD.ru.md) · [Benchmarks](docs/BENCHMARKS.md) · [Troubleshooting](docs/TROUBLESHOOTING.md)

A beginner-friendly end-to-end guide for NVIDIA CMP 170HX owners.

**Recommended path:**

**stock CMP 170HX → memory/compute unlock → 170tune validation → physical PCIe x4→x16 hardware mod → PCIe Gen2 software unlock → working CUDA P2P → multi-GPU LLM testing**

> **Measured on our 2× CMP 170HX 64 GB system:** ~6.46–6.69 GB/s one-way P2P, ~12.90–13.18 GB/s bidirectional, ~1.59–1.65 µs GPU-to-GPU latency over PCIe Gen2 x16.

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

Our tested P2P path builds on the experimental `aikitoria/open-gpu-kernel-modules` P2P changes plus our CMP/GA100 mailbox correction:

- https://github.com/aikitoria/open-gpu-kernel-modules/tree/610.43.03-p2p
- [Mailbox fix](patches/p2p-cmp170-mailbox-fix.patch)
- [P2P installation](docs/INSTALL.md)
- [How the P2P fix works](docs/P2P-EXPLAINED.md)

Alternative BAR1-based P2P work is also documented:

- [P2P alternative paths](docs/P2P-ALTERNATIVE-PATHS.md)
- [Русский — альтернативные P2P пути](docs/P2P-ALTERNATIVE-PATHS.ru.md)

Our final CUDA test on Gen2 x16:

```text
GPU0 -> GPU1: 6.46 GB/s
GPU1 -> GPU0: 6.69 GB/s
Bidirectional: 12.90–13.18 GB/s
GPU latency: 1.59–1.65 us
```

Full results: [docs/BENCHMARKS.md](docs/BENCHMARKS.md)

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
- [P2P installation and verification](docs/INSTALL.md)
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
