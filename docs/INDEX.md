# CMP 170HX documentation index

This repository is intended to be a practical map for CMP 170HX owners, from a newly purchased card to an unlocked and validated multi-GPU system.

## Beginner path

1. **Unlock memory and compute** — [`UNLOCK.md`](UNLOCK.md)
2. **PCIe x4 → x16 hardware modification** — [`PCIE-X16-HARDWARE-MOD.md`](PCIE-X16-HARDWARE-MOD.md) / [Русский](PCIE-X16-HARDWARE-MOD.ru.md)
3. **Tune and validate with 170tune** — [`170TUNE.md`](170TUNE.md)
4. **Install and verify Static BAR1 P2P** — [`STATIC-BAR1-P2P.md`](STATIC-BAR1-P2P.md) / [Русский](STATIC-BAR1-P2P.ru.md)
5. **See the measured NUMA/root-complex impact on Static BAR1 P2P** — [`STATIC-BAR1-P2P.md#three-gpu-numa-root-complex`](STATIC-BAR1-P2P.md#three-gpu-numa-root-complex) / [Русский](STATIC-BAR1-P2P.ru.md#three-gpu-numa-root-complex)
6. **Diagnose and exclude a physical HBM page** — [`HBM-PAGE-RETIREMENT.md`](HBM-PAGE-RETIREMENT.md) / [Русский](HBM-PAGE-RETIREMENT.ru.md)
7. **Understand the historical mailbox investigation** — [`P2P-EXPLAINED.md`](P2P-EXPLAINED.md)
8. **Compare P2P implementations and limits** — [`P2P-ALTERNATIVE-PATHS.md`](P2P-ALTERNATIVE-PATHS.md) / [Русский](P2P-ALTERNATIVE-PATHS.ru.md)
9. **See measured results** — [`BENCHMARKS.md`](BENCHMARKS.md)
10. **Troubleshoot** — [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md)

## Frontier / research

- **PCIe Gen3 / Gen4 status and research directions** — [`PCIE-GEN3-STATUS.md`](PCIE-GEN3-STATUS.md) / [Русский](PCIE-GEN3-STATUS.ru.md)

Current public status: Gen2 is working; Gen3 reverse engineering is active but we have not found a reproducible public CMP 170HX capture with an actually trained `LnkSta: Speed 8GT/s` as of 2026-08-19.

## P2P implementations tracked here

### Static BAR1 path — currently verified

Verified on this repository's GPU1↔GPU2 Gen2 x16 pair with a content check:

```text
5.30 GB/s each way
10.27 GB/s bidirectional
1.69–1.71 us GPU latency
```

See [`STATIC-BAR1-P2P.md`](STATIC-BAR1-P2P.md) for raw output and limits.

### Mailbox/default path — historical, invalidated

Alternative implementation maintained in:

- <https://github.com/bayley/cmpunlocker>

The old Mailbox B2 result is retained for investigation/recovery only. It is
not evidence of working P2P: later content tests showed peer VRAM was not
updated. The practical path is Static BAR1 above.

See [`P2P-ALTERNATIVE-PATHS.md`](P2P-ALTERNATIVE-PATHS.md) before choosing a protocol path.

## Upstream projects worth following

- <https://github.com/amoghmunikote/cmpunlocker>
- <https://github.com/bayley/cmpunlocker>
- <https://github.com/Consensus-Protocol/cmp170hx>
- <https://github.com/cachenetics/170tune>
- <https://github.com/aikitoria/open-gpu-kernel-modules>

The goal of this repository is to preserve links, known-good procedures, contradictory results, and real measurements without pretending that every experimental method is universally reproducible.
