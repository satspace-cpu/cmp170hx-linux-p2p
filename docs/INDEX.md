# CMP 170HX documentation index

This repository is intended to be a practical map for CMP 170HX owners, from a newly purchased card to an unlocked and validated multi-GPU system.

## Beginner path

1. **Unlock memory and compute** — [`UNLOCK.md`](UNLOCK.md)
2. **PCIe x4 → x16 hardware modification** — [`PCIE-X16-HARDWARE-MOD.md`](PCIE-X16-HARDWARE-MOD.md) / [Русский](PCIE-X16-HARDWARE-MOD.ru.md)
3. **Tune and validate with 170tune** — [`170TUNE.md`](170TUNE.md)
4. **Install and verify the tested P2P path** — [`INSTALL.md`](INSTALL.md)
5. **Understand the mailbox/default P2P fix** — [`P2P-EXPLAINED.md`](P2P-EXPLAINED.md)
6. **Compare alternative P2P implementations** — [`P2P-ALTERNATIVE-PATHS.md`](P2P-ALTERNATIVE-PATHS.md) / [Русский](P2P-ALTERNATIVE-PATHS.ru.md)
7. **See measured results** — [`BENCHMARKS.md`](BENCHMARKS.md)
8. **Troubleshoot** — [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md)

## Frontier / research

- **PCIe Gen3 / Gen4 status and research directions** — [`PCIE-GEN3-STATUS.md`](PCIE-GEN3-STATUS.md) / [Русский](PCIE-GEN3-STATUS.ru.md)

Current public status: Gen2 is working; Gen3 reverse engineering is active but we have not found a reproducible public CMP 170HX capture with an actually trained `LnkSta: Speed 8GT/s` as of 2026-08-19.

## P2P implementations tracked here

### DEFAULT / mailbox path

Validated in this repository on 2× CMP 170HX at Gen2 x16:

```text
6.46–6.69 GB/s one-way
12.90–13.18 GB/s bidirectional
~1.6 us GPU latency
```

### Static BAR1 path

Alternative implementation maintained in:

- <https://github.com/bayley/cmpunlocker>

It uses a large static BAR1, BAR1-specific driver patches and host-kernel BAR/MMIO patches. Published upstream results include about 1.68 GB/s each way at Gen2 x4 and larger multi-GPU topologies.

See [`P2P-ALTERNATIVE-PATHS.md`](P2P-ALTERNATIVE-PATHS.md) before choosing a protocol path.

## Upstream projects worth following

- <https://github.com/amoghmunikote/cmpunlocker>
- <https://github.com/bayley/cmpunlocker>
- <https://github.com/Consensus-Protocol/cmp170hx>
- <https://github.com/cachenetics/170tune>
- <https://github.com/aikitoria/open-gpu-kernel-modules>

The goal of this repository is to preserve links, known-good procedures, contradictory results, and real measurements without pretending that every experimental method is universally reproducible.
