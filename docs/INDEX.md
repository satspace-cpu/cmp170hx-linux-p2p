# CMP 170HX documentation index

> 🇷🇺 **Buy modified CMP 170HX cards in Russia:** [Avito listing](https://www.avito.ru/voronezh/tovary_dlya_kompyutera/nvidia_cmp170_hx_x16_anlok_80_gb_110_sm_gen4_8492880790)
>
> 🛠️ **CMP 170HX modification service in Russia:** [Avito service listing](https://www.avito.ru/voronezh/nastolnye_kompyutery/nvidia_cmp_170hx_anlok_80_gig_gen4_sm_do_128_8437550194)

This repository is intended to be a practical map for CMP 170HX owners, from a newly purchased card to an unlocked and validated multi-GPU system.

## Beginner path

1. **Unlock memory and compute** — [`UNLOCK.md`](UNLOCK.md)
2. **PCIe x4 → x16 hardware modification** — [`PCIE-X16-HARDWARE-MOD.md`](PCIE-X16-HARDWARE-MOD.md) / [Русский](PCIE-X16-HARDWARE-MOD.ru.md)
3. **Tune and validate with 170tune** — [`170TUNE.md`](170TUNE.md)
4. **Hardware-unlocked 80 GiB cards: build the driver and enable P2P safely** — [`CMP170HX-80GB-DRIVER-P2P.md`](CMP170HX-80GB-DRIVER-P2P.md) / [Русский](CMP170HX-80GB-DRIVER-P2P.ru.md)
5. **64 GiB cards: install and verify Static BAR1 P2P** — [`STATIC-BAR1-P2P.md`](STATIC-BAR1-P2P.md) / [Русский](STATIC-BAR1-P2P.ru.md)
6. **See the measured NUMA/root-complex impact on Static BAR1 P2P** — [`STATIC-BAR1-P2P.md#three-gpu-numa-root-complex`](STATIC-BAR1-P2P.md#three-gpu-numa-root-complex) / [Русский](STATIC-BAR1-P2P.ru.md#three-gpu-numa-root-complex)
7. **Diagnose and exclude a physical HBM page** — [`HBM-PAGE-RETIREMENT.md`](HBM-PAGE-RETIREMENT.md) / [Русский](HBM-PAGE-RETIREMENT.ru.md)
8. **Understand the historical mailbox investigation** — [`P2P-EXPLAINED.md`](P2P-EXPLAINED.md)
9. **Compare P2P implementations and limits** — [`P2P-ALTERNATIVE-PATHS.md`](P2P-ALTERNATIVE-PATHS.md) / [Русский](P2P-ALTERNATIVE-PATHS.ru.md)
10. **See measured results** — [`BENCHMARKS.md`](BENCHMARKS.md)
11. **Troubleshoot** — [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md)

## Frontier / research

- **Current PCIe Gen3 / Gen4 report and project measurements** — [`PCIE-GEN4-2026-11-22.md`](PCIE-GEN4-2026-11-22.md) / [Русский](PCIE-GEN4-2026-11-22.ru.md)
- **Historical August 2026 research snapshot** — [`PCIE-GEN3-STATUS.md`](PCIE-GEN3-STATUS.md) / [Русский](PCIE-GEN3-STATUS.ru.md)

Current project status: Gen4 x16 (16 GT/s) is reproduced on four hardware-unlocked 80 GiB CMP 170HX cards. Pinned H2D is 24.17–24.38 GiB/s; all 12 directed P2P pairs work, with 46.84–48.50 GB/s bidirectional bandwidth. The enabled boot service restored all four Gen4 links and 47.18–49.11 GB/s P2P after reboot.

## P2P implementations tracked here

### Hardware-unlocked 80 GiB path — verified companion design

The 80 GiB configuration uses a dedicated `20c2-hw80` NVIDIA driver profile
plus a minimal `gpu-unlock 3.0.0-beta` companion. It does not resize BAR1 and
must not be mixed with the 64 GiB Static BAR1 module options. Peer copy, direct
SM remote read and direct SM remote write passed in both directions.

See [`CMP170HX-80GB-DRIVER-P2P.md`](CMP170HX-80GB-DRIVER-P2P.md) / [Русский](CMP170HX-80GB-DRIVER-P2P.ru.md).

### Static BAR1 path — verified for 64 GiB

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
updated. For 64 GiB cards, the practical path is Static BAR1 above; use the
separate companion guide for hardware-unlocked 80 GiB cards.

See [`P2P-ALTERNATIVE-PATHS.md`](P2P-ALTERNATIVE-PATHS.md) before choosing a protocol path.

## Upstream projects worth following

- <https://github.com/amoghmunikote/cmpunlocker>
- <https://github.com/bayley/cmpunlocker>
- <https://github.com/Consensus-Protocol/cmp170hx>
- <https://github.com/cachenetics/170tune>
- <https://github.com/aikitoria/open-gpu-kernel-modules>

The goal of this repository is to preserve links, known-good procedures, contradictory results, and real measurements without pretending that every experimental method is universally reproducible.
