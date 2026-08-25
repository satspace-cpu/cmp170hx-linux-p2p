# CMP 170HX (GA100) — HBM2 Memory Timings, decoded

> Live extract from the running card, decoded against the NVIDIA GA100 hardware
> reference manual. Regenerated after the vBIOS change.

| | |
|---|---|
| **GPU** | NVIDIA CMP 170HX (GA100, `10de:20c2` rev a1) @ `03:00.0` |
| **vBIOS** | `92.00.6D.00.0A` |
| **Memory** | 8× HBM2, 65536 MiB reported |
| **Mem clock at capture** | 1728 MHz (P0 — the only supported mem pstate) |
| **tCK (clock period)** | 1 / 1728 MHz = **0.5787 ns** |
| **Driver** | 595.71.05 |
| **Captured** |`gpu_reg_tool dump-fbpa` (BAR0 MMIO) |
| **Raw register file** | [`../cmp170hx_8_hbm2_timings.txt`](../cmp170hx_8_hbm2_timings.txt) |
| **Decode source** | `dev_fbpa.h` (integdev_gpu_drv, ampere/ga100) |

---

## 0. vBIOS change — what actually moved

The whole FBPA/DRAM-timing register block reads **byte-for-byte identical** to the
previous dump. The **only** register that changed value is the dynamic refresh /
status register:

| Register | Old vBIOS | New vBIOS | Meaning |
|---|---|---|---|
| `0x009A0210` | `0x80006060` | `0x80001818` | live refresh-counter / REFCTRL status — changes every read, **not** a programmed timing |

**Conclusion:** the new vBIOS ships the *same* P0 HBM2 timing table as the old one.
The numbers below are the current, live, effective timings on this card.

---

## 1. Key DRAM timings (the ones you care about)

Cycle→ns uses **tCK = 0.5787 ns** (1728 MHz). Sanity check: tRP = 24 cyc →
13.9 ns ≈ JEDEC HBM2 14 ns, and tRFC = 657 cyc → 380 ns ≈ HBM2 all-bank refresh —
so the clock basis is correct.

| Timing | What it is | Source reg.field | Cycles (dec) | ≈ ns |
|---|---|---|---:|---:|
| **tRC** | Row cycle time (ACT→ACT same bank) | `CONFIG0.RC` | 67 | 38.8 |
| **tRAS** | Row active time (ACT→PRE) | `CONFIG0.RAS` | 43 | 24.9 |
| **tRP** | Row precharge (PRE→ACT) | `CONFIG0.RP` | 24 | 13.9 |
| **tRCD_rd** | RAS→CAS delay, reads (ACT→RD) | `CONFIG1.RD_RCD` | 27 | 15.6 |
| **tRCD_wr** | RAS→CAS delay, writes (ACT→WR) | `CONFIG1.WR_RCD` | 18 | 10.4 |
| **tRFC** | Refresh cycle, all-bank (effective) *(= CONFIG0.RFC 145 │ CONFIG10.RFC_MSB 1<<9)* | `TIMING0_GEN.RFC` | 657 | 380.2 |
| **tRFCsb** | Refresh cycle, single-bank | `TIMING22.RFCSBA` | 292 | 169.0 |
| **CL** | CAS read latency (RD→data) | `CONFIG1.CL` | 37 | 21.4 |
| **WL** | Write latency (WR→data) | `CONFIG1.WL` | 10 | 5.8 |
| **tWR** | Write recovery (data→PRE) | `CONFIG2.WR` | 25 | 14.5 |
| **tRRD_s** | ACT→ACT diff bank, short (diff bank-group) | `CONFIG4.RRD` | 5 | 2.9 |
| **tRRD_l** | ACT→ACT diff bank, long (same bank-group) | `CONFIG11.RRDL` | 5 | 2.9 |
| **tFAW** | Four-activate window | `CONFIG3.FAW` | 22 | 12.7 |
| **tCCD_s** | CAS→CAS, short (diff bank-group) | `CONFIG3.CCDS` | 2 | 1.2 |
| **tCCD_l** | CAS→CAS, long (same bank-group) | `CONFIG3.CCDL` | 4 | 2.3 |
| **tR2W** | Read→Write bus turnaround (effective) | `TIMING1_GEN.R2W` | 37 | 21.4 |
| **tW2R** | Write→Read bus turnaround (effective) | `TIMING1_GEN.W2R` | 20 | 11.6 |
| **tR2P** | Read→Precharge (effective) | `TIMING1_GEN.R2P` | 10 | 5.8 |
| **tW2P** | Write→Precharge (effective) | `TIMING1_GEN.W2P` | 36 | 20.8 |
| **tCKE** | Clock-enable min pulse | `TIMING12.CKE` | 11 | 6.4 |
| **tZQCAL** | ZQ calibration (long) *(≈1 µs)* | `TIMING25.ZQCAL` | 1000 | 578.7 |
| **tLOCKPLL** | PLL relock window | `TIMING12.LOCKPLL` | 3000 | 1736.1 |

Other periodic/interval settings (not per-command latencies):

| Setting | Source | Value (dec) | ≈ time |
|---|---|---:|---:|
| ZQCS auto-cal interval | `CONFIG7.ZQCS_INTERVAL` | 12800000 cyc | 7.41 ms |
| ZQCS short | `TIMING14.ZQCS` | 63 | 36.5 ns |
| ZQCL long | `TIMING14.ZQCL` | 100 | 57.9 ns |
| Single-bank tRFC (RFCSBR) | `TIMING22.RFCSBR` | 12 | 6.9 ns |

---

## 1a. Mapping to primary / secondary / tertiary / quaternary

NVIDIA does not physically split the registers into those tiers — every value is a
field inside `CONFIG*`/`TIMING*`. But mapped onto the usual DRAM-OC hierarchy, the
**tertiary and quaternary timings already live in the registers decoded below** — they
are just packed byte-fields, not extra register banks. So: yes, this is all of them.

**Primary**

| Timing | Source field | Cyc |
|---|---|---:|
| CL | `CONFIG1.CL` | 37 |
| tRCD (rd) | `CONFIG1.RD_RCD` | 27 |
| tRCD (wr) | `CONFIG1.WR_RCD` | 18 |
| tRP | `CONFIG0.RP` | 24 |
| tRAS | `CONFIG0.RAS` | 43 |

**Secondary**

| Timing | Source field | Cyc |
|---|---|---:|
| tRC | `CONFIG0.RC` | 67 |
| tRFC | `TIMING0_GEN.RFC` | 657 |
| tRFCsb | `TIMING22.RFCSBA` | 292 |
| tWR | `CONFIG2.WR` | 25 |
| WL/tCWL | `CONFIG1.WL` | 10 |
| tFAW | `CONFIG3.FAW` | 22 |
| tRRD | `CONFIG4.RRD` | 5 |
| tRTP (rd→pre) | `TIMING1_GEN.R2P` | 10 |
| tWTP (wr→pre) | `TIMING1_GEN.W2P` | 36 |
| tCKE | `TIMING12.CKE` | 11 |
| tREFI | `CONFIG4.REFRESH` | 6 |

**Tertiary — bank-group / turnaround matrix**

| Timing | Source field | Cyc |
|---|---|---:|
| tCCD_L | `CONFIG3.CCDL` | 4 |
| tCCD_S | `CONFIG3.CCDS` | 2 |
| tRRD_L | `CONFIG11.RRDL` | 5 |
| tR2W (rd→wr bus) | `TIMING1_GEN.R2W` | 37 |
| tW2R (wr→rd bus) | `TIMING1_GEN.W2R` | 20 |
| tWTR (W2R_BUS) | `CONFIG2.W2R_BUS` | 8 |
| R2W_BUS | `CONFIG2.R2W_BUS` | 8 |
| tCCD_R (rank) | `TIMING23.CCDR` | 3 |
| WR_CCD_L | `TIMING23.WR_CCDL` | 0 |
| WR_CCD_S | `TIMING23.WR_CCDS` | 0 |
| CCDMW (masked wr) | `CONFIG11.CCDMW` | 0 |
| RD rank-sel delay | `CONFIG11.RD_RANK_SEL_DELAY` | 0 |
| WR rank-sel delay | `CONFIG11.WR_RANK_SEL_DELAY` | 0 |
| CDLR | `CONFIG2.CDLR` | 9 |

**Quaternary — PHY data-path, power-down, self-refresh, ZQ**

| Timing | Source field | Cyc |
|---|---|---:|
| QUSE | `TIMING3.QUSE` | 11 |
| QRST | `TIMING3.QRST` | 10 |
| QSAFE | `TIMING3.QSAFE` | 17 |
| RDV (read data valid) | `TIMING3.RDV` | 60 |
| WDV (write data valid) | `TIMING2.WDV` | 5 |
| RPRE/WPRE | `CONFIG2.RPRE` | 1 |
| ODT/ODTLEN | `TIMING8.ODT` | 0 |
| QPOP_OFFSET | `CONFIG1.QPOP_OFFSET` | 14 |
| WCK2MRS | `TIMING10.WCK2MRS` | 4 |
| MRD | `TIMING10.MRD` | 22 |
| REFTR | `TIMING10.REFTR` | 10 |
| power-down entry PDEN2PDEX | `CONFIG3.PDEN2PDEX` | 11 |
| PDEX2WR | `TIMING4.PDEX2WR` | 7 |
| PDEX2RD | `TIMING4.PDEX2RD` | 7 |
| ACT2PDEN | `TIMING5.ACT2PDEN` | 12 |
| PCHG2PDEN | `TIMING5.PCHG2PDEN` | 10 |
| self-refresh exit ASR2NRD | `TIMING13.ASR2NRD` | 255 |
| ASREX2CLK | `TIMING13.ASREX2CLK` | 14 |
| ZQCS | `TIMING14.ZQCS` | 63 |
| ZQCL | `TIMING14.ZQCL` | 100 |
| ZQCAL | `TIMING25.ZQCAL` | 1000 |

> Caveat for the PHY/data-path fields (QUSE/QRST/QSAFE/RDV/…): the value above is the
> *programmed base* in the `TIMING2..5` register. The controller applies `CONFIG5/6/8/9`
> offsets to produce the **effective** value in the `_GEN` twin — e.g. QUSE base = 11 but effective `TIMING3_GEN.QUSE` = 42. Read §3.2 (`_GEN`) for what the hardware actually uses.

---

## 2. How to read these registers — CONFIG vs TIMING vs _GEN

The FBPA has **three** overlapping copies of the core timings. Which one is live is
selected by one bit:

- **`CONFIG0.USE_TIMING_REGS` (bit 31) = 0** → **FALSE** on this card.
  This means the hardware takes its primary timings (tRC/tRFC/tRAS/tRP/CL/WL/tRCD/…)
  from the **`CONFIG0..CONFIG12`** registers (`0x290`–`0x2F4`, plus `0x015C`, `0x3E4`).
- The **`TIMING0..TIMING9`** registers (`0x220`–`0x244`) hold the *other* (legacy)
  copy. On this card they carry leftover DDR3-style defaults (e.g. TIMING0 RC=12,
  RAS=8 — physically impossible for HBM2), confirming they are **inactive**.
- **`TIMING10`+ (`0x248`+)** hold HBM-specific extended parameters that have no
  CONFIG twin, so those **are** live regardless of the select bit.
- **`TIMINGn_GEN`** (`0x2B0`–`0x2C8`, read-only) are the **effective** timings the
  controller actually generated after resolving CONFIG + high-bit extensions. They are
  the ground truth. Example: `TIMING0_GEN.RFC` = 657 = `CONFIG0.RFC`(145) OR'd with
  `CONFIG10.RFC_MSB`(1) shifted left 9. That is why the key table above pulls tRFC and
  the bus-turnaround values (tR2W/tW2R) from the `_GEN` registers.

Register numbering note: the previous version of the raw file labelled `0x290`+ as
"DRAM_TRAINING0..". That was wrong — per `dev_fbpa.h` those addresses are
`CONFIG0..CONFIG10` and the read-only `TIMINGn_GEN` snapshots. The raw file is now
relabelled to match the hardware manual.

---

## 3. Full field-level decode

Every field below is decoded straight from the live value with the bit ranges from
`dev_fbpa.h`. Decimal is the raw field value; it equals a cycle count for the latency
timings (multiply by 0.5787 ns for time).

### 3.1 CONFIG registers — ACTIVE primary timings

**CONFIG0** — `0x009A0290` = `0x18569143`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| RC | 7:0 | 0x43 | 67 |
| RFC | 16:8 | 0x91 | 145 |
| RAS | 23:17 | 0x2B | 43 |
| RP | 30:24 | 0x18 | 24 |
| USE_TIMING_REGS | 31:31 | 0x0 | 0 |

**CONFIG1** — `0x009A0294` = `0x3926C525`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| CL | 6:0 | 0x25 | 37 |
| WL | 13:7 | 0xA | 10 |
| RD_RCD | 19:14 | 0x1B | 27 |
| WR_RCD | 25:20 | 0x12 | 18 |
| QPOP_OFFSET | 31:26 | 0xE | 14 |

**CONFIG2** — `0x009A0298` = `0x88190911`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| RPRE | 3:0 | 0x1 | 1 |
| WPRE | 7:4 | 0x1 | 1 |
| CDLR | 14:8 | 0x9 | 9 |
| WR | 22:16 | 0x19 | 25 |
| W2R_BUS | 27:24 | 0x8 | 8 |
| R2W_BUS | 31:28 | 0x8 | 8 |

**CONFIG3** — `0x009A029C` = `0x24002D6B`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| PDEX | 4:0 | 0xB | 11 |
| PDEN2PDEX | 8:5 | 0xB | 11 |
| FAW | 16:9 | 0x16 | 22 |
| AOND | 23:17 | 0x0 | 0 |
| CCDL | 27:24 | 0x4 | 4 |
| CCDS | 31:28 | 0x2 | 2 |

**CONFIG4** — `0x009A02A0` = `0xC4028033`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| REFRESH_LO | 2:0 | 0x3 | 3 |
| REFRESH | 14:3 | 0x6 | 6 |
| RRD | 20:15 | 0x5 | 5 |
| IDLE_DELAY | 26:21 | 0x20 | 32 |
| CMD2MCIDLE_DRAMC | 31:27 | 0x18 | 24 |

**CONFIG5** — `0x009A02A4` = `0xA6B3A002`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| ADR_MIN | 2:0 | 0x2 | 2 |
| WRCRC | 10:4 | 0x0 | 0 |
| QSAFE_OFFSET | 17:12 | 0x3A | 58 |
| INTRP_MSB | 19:18 | 0x0 | 0 |
| RDRET_OFFSET | 23:20 | 0xB | 11 |
| WRRET_OFFSET | 27:24 | 0x6 | 6 |
| INTRP | 31:28 | 0xA | 10 |

**CONFIG6** — `0x009A02A8` = `0x11008000`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| RDFLUSH_OFFSET | 6:0 | 0x0 | 0 |
| WRFLUSH_OFFSET | 14:8 | 0x0 | 0 |
| CMD2MCIDLE_DRAMC_EXT | 15:15 | 0x1 | 1 |
| WDAT_LATENCY | 20:16 | 0x0 | 0 |
| PPD | 27:24 | 0x1 | 1 |
| SDDR4_RDV_OFFSET | 29:28 | 0x1 | 1 |
| CMD_ADJUST | 31:30 | 0x0 | 0 |

**CONFIG7** — `0x009A02AC` = `0x00C35000`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| ZQCS_INTERVAL | 31:0 | 0xC35000 | 12800000 |

**CONFIG8** — `0x009A02CC` = `0x0C023900`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| ATR_OFFSET | 6:0 | 0x0 | 0 |
| ATR_PADDING | 11:8 | 0x9 | 9 |
| ODT_PADDING | 15:12 | 0x3 | 3 |
| WCK2PH | 23:16 | 0x2 | 2 |
| MRSTWCK | 30:24 | 0xC | 12 |

**CONFIG9** — `0x009A02E8` = `0x12400389`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| QUSE_OFFSET | 6:0 | 0x9 | 9 |
| QUSE_DDLL_SETTLE | 11:7 | 0x7 | 7 |
| REXT_OFFSET | 15:12 | 0x0 | 0 |
| DLCELL_SETTLE | 23:16 | 0x40 | 64 |
| QRST_OFFSET | 27:24 | 0x2 | 2 |
| MPRR | 31:28 | 0x1 | 1 |

**CONFIG10** — `0x009A02F4` = `0x00000011`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| RFC_MSB | 1:0 | 0x1 | 1 |
| IDLE_DELAY_MSB | 4:4 | 0x1 | 1 |
| PDEN2PDEX_MSB | 6:5 | 0x0 | 0 |
| RD_RCD_MSB | 8:8 | 0x0 | 0 |
| WR_RCD_MSB | 11:11 | 0x0 | 0 |
| IDLE_DELAY_HI | 16:14 | 0x0 | 0 |
| CMD2MCIDLE_DRAMC_HI | 18:18 | 0x0 | 0 |
| RDRET_OFFSET_MSB | 21:21 | 0x0 | 0 |

**CONFIG11** — `0x009A03E4` = `0x00000005`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| RRDL | 5:0 | 0x5 | 5 |
| CCDMW | 12:7 | 0x0 | 0 |
| WPOST | 15:15 | 0x0 | 0 |
| LPDDR4_RDV_OFFSET | 18:16 | 0x0 | 0 |
| WEXT_OFFSET | 22:19 | 0x0 | 0 |
| RPRE_TOGGLE | 23:23 | 0x0 | 0 |
| RD_RANK_SEL_DELAY | 27:24 | 0x0 | 0 |
| WR_RANK_SEL_DELAY | 31:28 | 0x0 | 0 |

**CONFIG12** — `0x009A015C` = `0x00000000`  (reads 0 / filtered)

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| BLDIV | 3:0 | 0x0 | 0 |
| ADR_TERM | 4:4 | 0x0 | 0 |
| ADRTR_FIFO_MARGIN | 7:5 | 0x0 | 0 |

### 3.2 TIMINGn_GEN — read-only EFFECTIVE timings, full set (ground truth)

These mirror TIMING/CONFIG after the controller resolves them, incl. the tertiary/quaternary values. Present on this die: GEN 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 15, 16, 17, 18, 19, 20, 22, 24.

**TIMING0_GEN** — `0x009A02B0` = `0x2B291043`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| RC | 8:0 | 0x43 | 67 |
| RFC | 22:12 | 0x291 | 657 |
| RAS | 31:24 | 0x2B | 43 |

**TIMING1_GEN** — `0x009A02B4` = `0x240A1425`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| R2W | 7:0 | 0x25 | 37 |
| W2R | 14:8 | 0x14 | 20 |
| R2P | 20:16 | 0xA | 10 |
| W2P | 30:24 | 0x24 | 36 |

**TIMING2_GEN** — `0x009A02B8` = `0x0905121B`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| RD_RCD | 7:0 | 0x1B | 27 |
| WR_RCD | 15:8 | 0x12 | 18 |
| RRD | 22:16 | 0x5 | 5 |
| WDV | 28:24 | 0x9 | 9 |

**TIMING3_GEN** — `0x009A02BC` = `0x003B242A`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| QUSE | 7:0 | 0x2A | 42 |
| QRST | 15:8 | 0x24 | 36 |
| QSAFE | 23:16 | 0x3B | 59 |
| RDV | 31:24 | 0x0 | 0 |

**TIMING4_GEN** — `0x009A02C0` = `0x016B0B0B`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| PDEX2WR | 5:0 | 0xB | 11 |
| PDEX2RD | 13:8 | 0xB | 11 |
| PDEN2PDEX | 19:16 | 0xB | 11 |
| FAW | 28:20 | 0x16 | 22 |
| PDEN2PDEX_MSB | 30:29 | 0x0 | 0 |

**TIMING5_GEN** — `0x009A02C4` = `0x489B2718`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| PCHG2PDEN | 7:0 | 0x18 | 24 |
| RW2PDEN | 15:8 | 0x27 | 39 |
| ACT2PDEN | 22:16 | 0x1B | 27 |
| AR2PDEN | 31:23 | 0x91 | 145 |

**TIMING6_GEN** — `0x009A02C8` = `0x29380101`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| PPD | 4:0 | 0x1 | 1 |
| BUS_W2R | 15:8 | 0x1 | 1 |
| CMD2MCIDLE_DRAMC | 21:16 | 0x38 | 56 |
| CMD2MCIDLE_FBIO | 30:24 | 0x29 | 41 |

**TIMING7_GEN** — `0x009A02D0` = `0x0B240202`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| REXT | 3:0 | 0x2 | 2 |
| WEXT | 11:8 | 0x2 | 2 |
| ATR | 23:16 | 0x24 | 36 |
| ATRLEN | 28:24 | 0xB | 11 |

**TIMING8_GEN** — `0x009A02D4` = `0x11330501`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| ODT | 7:0 | 0x1 | 1 |
| ODTLEN | 11:8 | 0x5 | 5 |
| QPOP_OFFSET | 23:16 | 0x33 | 51 |
| RPRE | 27:24 | 0x1 | 1 |
| WPRE | 31:28 | 0x1 | 1 |

**TIMING9_GEN** — `0x009A02D8` = `0x180E1024`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| CCDL | 3:0 | 0x4 | 4 |
| CCDS | 7:4 | 0x2 | 2 |
| QPOP_OFFSET_ADR | 15:8 | 0x10 | 16 |
| QPOP_OFFSET_WCK | 23:16 | 0xE | 14 |
| QPOP_OFFSET_WREDC | 31:24 | 0x18 | 24 |

**TIMING15_GEN** — `0x009A02DC` = `0x01001232`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| RDRET | 6:0 | 0x32 | 50 |
| WRRET | 15:8 | 0x12 | 18 |
| RDINTRP | 22:16 | 0x0 | 0 |
| WRINTRP | 30:24 | 0x1 | 1 |

**TIMING16_GEN** — `0x009A02E0` = `0x00180C27`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| RDFLUSH | 7:0 | 0x27 | 39 |
| WRFLUSH | 15:8 | 0xC | 12 |
| RP | 23:16 | 0x18 | 24 |
| WCK_QRST | 26:24 | 0x0 | 0 |

**TIMING17_GEN** — `0x009A02E4` = `0x0A000033`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| RDRET_PRE | 7:0 | 0x33 | 51 |
| WCK2RDWCK | 23:16 | 0x0 | 0 |
| MRS2RDWCK | 31:24 | 0xA | 10 |

**TIMING18_GEN** — `0x009A02EC` = `0x08000200`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| WRCRCFLUSH | 7:0 | 0x0 | 0 |
| REXT | 15:8 | 0x2 | 2 |
| QUSE_SETTLE | 20:16 | 0x0 | 0 |
| DLCELL_SETTLE | 29:21 | 0x40 | 64 |

**TIMING19_GEN** — `0x009A02F0` = `0x0006A0E2`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| QRST_OFFSET | 4:0 | 0x2 | 2 |
| QRST_FLUSH | 9:5 | 0x7 | 7 |
| MPRR | 16:10 | 0x28 | 40 |
| REFSB_SUBP0 | 17:17 | 0x1 | 1 |
| REFSB_SUBP1 | 18:18 | 0x1 | 1 |

**TIMING20_GEN** — `0x009A0288` = `0x00001232`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| RD_REFRESH | 7:0 | 0x32 | 50 |
| WR_REFRESH | 15:8 | 0x12 | 18 |

**TIMING22_GEN** — `0x009A03F8` = `0x00003124`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| RFCSBA | 9:0 | 0x124 | 292 |
| RFCSBR | 17:10 | 0xC | 12 |
| RFCSBA_MSB | 21:20 | 0x0 | 0 |

**TIMING24_GEN** — `0x009A03E8` = `0x28000005`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| RRDL | 6:0 | 0x5 | 5 |
| CCDMW | 14:8 | 0x0 | 0 |
| LPDDR4_RDV_OFFSET | 18:15 | 0x0 | 0 |
| ABPA | 25:20 | 0x0 | 0 |
| XS_OFFSET | 31:26 | 0xA | 10 |

### 3.3 TIMING registers — legacy copy (0–9 inactive) + HBM extended (10+)

**TIMING0** — `0x009A0220` = `0x0801900C`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| RC | 8:0 | 0xC | 12 |
| RFC | 22:12 | 0x19 | 25 |
| RAS | 31:24 | 0x8 | 8 |

**TIMING1** — `0x009A0224` = `0x120A0D12`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| R2W | 7:0 | 0x12 | 18 |
| W2R | 14:8 | 0xD | 13 |
| R2P | 20:16 | 0xA | 10 |
| W2P | 30:24 | 0x12 | 18 |

**TIMING2** — `0x009A0228` = `0x0508080C`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| RD_RCD | 7:0 | 0xC | 12 |
| WR_RCD | 15:8 | 0x8 | 8 |
| RRD | 22:16 | 0x8 | 8 |
| WDV | 28:24 | 0x5 | 5 |

**TIMING3** — `0x009A022C` = `0x3C110A0B`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| QUSE | 7:0 | 0xB | 11 |
| QRST | 15:8 | 0xA | 10 |
| QSAFE | 23:16 | 0x11 | 17 |
| RDV | 31:24 | 0x3C | 60 |

**TIMING4** — `0x009A0230` = `0x02800707`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| PDEX2WR | 5:0 | 0x7 | 7 |
| PDEX2RD | 13:8 | 0x7 | 7 |
| PDEN2PDEX | 19:16 | 0x0 | 0 |
| FAW | 28:20 | 0x28 | 40 |
| PDEN2PDEX_MSB | 30:29 | 0x0 | 0 |

**TIMING5** — `0x009A0234` = `0x168C0D0A`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| PCHG2PDEN | 7:0 | 0xA | 10 |
| RW2PDEN | 15:8 | 0xD | 13 |
| ACT2PDEN | 22:16 | 0xC | 12 |
| AR2PDEN | 31:23 | 0x2D | 45 |

**TIMING6** — `0x009A0238` = `0x46080101`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| PPD | 4:0 | 0x1 | 1 |
| BUS_W2R | 15:8 | 0x1 | 1 |
| CMD2MCIDLE_DRAMC | 21:16 | 0x8 | 8 |
| CMD2MCIDLE_FBIO | 31:24 | 0x46 | 70 |

**TIMING7** — `0x009A023C` = `0x07000202`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| REXT | 3:0 | 0x2 | 2 |
| WEXT | 11:8 | 0x2 | 2 |
| ATR | 23:16 | 0x0 | 0 |
| ATRLEN | 28:24 | 0x7 | 7 |

**TIMING8** — `0x009A0240` = `0x110B0700`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| ODT | 7:0 | 0x0 | 0 |
| ODTLEN | 11:8 | 0x7 | 7 |
| QPOP_OFFSET | 23:16 | 0xB | 11 |
| RPRE | 27:24 | 0x1 | 1 |
| WPRE | 31:28 | 0x1 | 1 |

**TIMING9** — `0x009A0244` = `0x0A0A0A00`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| CCDL | 3:0 | 0x0 | 0 |
| CCDS | 7:4 | 0x0 | 0 |
| QPOP_OFFSET_ADR | 15:8 | 0xA | 10 |
| QPOP_OFFSET_WCK | 23:16 | 0xA | 10 |
| QPOP_OFFSET_WREDC | 31:24 | 0xA | 10 |

**TIMING10** — `0x009A0248` = `0x0A2C7444`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| WCK2MRS | 3:0 | 0x4 | 4 |
| WCK2TR | 7:4 | 0x4 | 4 |
| LTLTR | 11:8 | 0x4 | 4 |
| LTL7TR | 16:12 | 0x7 | 7 |
| MRD | 22:17 | 0x16 | 22 |
| WCK2MRS_MSB2 | 23:23 | 0x0 | 0 |
| REFTR | 29:24 | 0xA | 10 |
| WCK2TR_MSB | 30:30 | 0x0 | 0 |
| WCK2MRS_MSB | 31:31 | 0x0 | 0 |

**TIMING11** — `0x009A024C` = `0x03053DF3`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| ADZ | 4:0 | 0x13 | 19 |
| WTR_RCD | 9:5 | 0xF | 15 |
| LTR_RCD | 14:10 | 0xF | 15 |
| LTRTR | 20:16 | 0x5 | 5 |
| KO | 30:24 | 0x3 | 3 |

**TIMING12** — `0x009A0250` = `0x0BB800B1`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| RDCRC | 3:0 | 0x1 | 1 |
| CKE | 9:4 | 0xB | 11 |
| LOCKPLL | 29:16 | 0xBB8 | 3000 |

**TIMING13** — `0x009A0254` = `0x02BAFF4E`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| ASREX2CLK | 4:0 | 0xE | 14 |
| ASREX2CLK_MSB | 5:5 | 0x0 | 0 |
| ASR2NRD_MSB | 6:6 | 0x1 | 1 |
| ASR2ASREX_MSB | 7:7 | 0x0 | 0 |
| ASR2NRD | 15:8 | 0xFF | 255 |
| ASR2ASREX | 31:16 | 0x2BA | 698 |

**TIMING14** — `0x009A0258` = `0x0000643F`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| ZQCS | 6:0 | 0x3F | 63 |
| ZQCL | 17:8 | 0x64 | 100 |

**TIMING15** — `0x009A025C` = `0x08080F0F`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| RDRET | 6:0 | 0xF | 15 |
| WRRET | 15:8 | 0xF | 15 |
| RDINTRP | 22:16 | 0x8 | 8 |
| WRINTRP | 30:24 | 0x8 | 8 |

**TIMING16** — `0x009A0260` = `0x00001F1F`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| RDFLUSH | 7:0 | 0x1F | 31 |
| WRFLUSH | 15:8 | 0x1F | 31 |
| RP | 23:16 | 0x0 | 0 |
| WCK_QRST | 27:24 | 0x0 | 0 |

**TIMING17** — `0x009A0264` = `0x00000000`  (reads 0 / filtered)

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| RDRET_PRE | 7:0 | 0x0 | 0 |
| WCK2RDWCK | 23:16 | 0x0 | 0 |
| MRS2RDWCK | 31:24 | 0x0 | 0 |

**TIMING18** — `0x009A0268` = `0x03FF1F1F`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| WRCRCFLUSH | 7:0 | 0x1F | 31 |
| REXT | 15:8 | 0x1F | 31 |
| QUSE_SETTLE | 20:16 | 0x1F | 31 |
| DLCELL_SETTLE | 29:21 | 0x1F | 31 |

**TIMING19** — `0x009A026C` = `0x00007FE2`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| QRST_OFFSET | 4:0 | 0x2 | 2 |
| QRST_FLUSH | 9:5 | 0x1F | 31 |
| MPRR | 16:10 | 0x1F | 31 |

**TIMING20** — `0x009A028C` = `0x00001F1F`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| RD_REFRESH | 7:0 | 0x1F | 31 |
| WR_REFRESH | 15:8 | 0x1F | 31 |

**TIMING21** — `0x009A0390` = `0x00C0052D`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| REFSB | 0:0 | 0x1 | 1 |
| REFSB_FORCE_FULL | 1:1 | 0x0 | 0 |
| REFSB_DUAL_REQUEST | 2:2 | 0x1 | 1 |
| REFSB_DELAYED_THRESHOLD | 5:3 | 0x5 | 5 |
| REFSB_FULL_REF_PERIOD | 19:8 | 0x5 | 5 |
| REFSB_DISPATCH_PERIOD | 31:22 | 0x3 | 3 |

**TIMING22** — `0x009A0394` = `0x00003124`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| RFCSBA | 9:0 | 0x124 | 292 |
| RFCSBR | 17:10 | 0xC | 12 |
| RFCSBA_MSB | 21:20 | 0x0 | 0 |

**TIMING23** — `0x009A039C` = `0x00000003`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| CCDR | 3:0 | 0x3 | 3 |
| RD_RANK_SEL_DELAY | 10:4 | 0x0 | 0 |
| WR_RANK_SEL_DELAY | 17:11 | 0x0 | 0 |
| WR_CCDL | 27:24 | 0x0 | 0 |
| WR_CCDS | 31:28 | 0x0 | 0 |

**TIMING24** — `0x009A03E0` = `0x28000008`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| RRDL | 6:0 | 0x8 | 8 |
| CCDMW | 14:8 | 0x0 | 0 |
| LPDDR4_RDV_OFFSET | 18:15 | 0x0 | 0 |
| ABPA | 25:20 | 0x0 | 0 |
| XS_OFFSET | 31:26 | 0xA | 10 |

**TIMING25** — `0x009A03EC` = `0x400803E8`

| Field | Bits | Hex | Dec |
|---|---|---:|---:|
| ZQCAL | 11:0 | 0x3E8 | 1000 |
| MRRW | 21:13 | 0x40 | 64 |
| MRRWL | 30:22 | 0x100 | 256 |

### 3.4 Other timing-bearing register families (not field-decoded here)

Beyond the command-timing block above, the FBPA carries a few more groups that also
hold timing/latency values. They are captured as raw values in the `.txt`; decode them
on request.

| Group | Addr range | Live sample | What it is |
|---|---|---|---|
| **MRS / mode registers** | `0x009A0300`–`0x3FC` | `MR0..MR15` writes | the DRAM-side mode registers — the HBM stack's *own* CL/WR/drive/refresh config, sent over the bus. Complements the controller-side timings. |
| **ASR (auto self-refresh)** | `0x009A02F8` / `0x2FC` | `0x0A000080` / `0x00000002` | self-refresh wakeup + entry timing (`ASR_WAKEUP`, `DRAM_ASR`). |
| **Training timing** | `0x009A0970`, `0x09C8`, `0x2050` | `0x006E0600`, `0x0000000A` | PHY/DLL training windows (`TRAINING_TIMING`, `_TIMING2`, `_TIMING3`). Not per-command latencies. |
| **REFMPLL / DRAMPLL** | `0x009A0E20`+ | PLL cfg | memory-clock PLL coefficients — set the tCK the above cycle counts are measured in. |

These are *fixed* by the memory type/training, not knobs you would tune for latency the
way the primary–quaternary set is.

### 3.5 MRS — HBM2 mode registers (the DRAM stack's own view)

Each `GENERIC_MRSn` register is a *command*: `[31:30]SUBP · [29:28]CH · [25:20]BA=MR#`
`· [19:18]RANK · [16:0]ADR=MR payload`. The payload is what the HBM die stores. Two
values cross-check the controller side: **MR3 RAS = CONFIG0.RAS**, **MR1 WR = CONFIG2.WR**.

| MR | Reg | Value | Payload | Decoded (NVIDIA HBM fields) |
|---|---|---|---:|---|
| MR0 | `0x009A0300` | `0x00000003` | 0x0003 | RDBI=1, WDBI=1 (data-bus inversion rd/wr) |
| MR1 | `0x009A0330` | `0x00100099` | 0x0099 | **WR=25**, DRV=4 (write-recovery, drive strength) |
| MR2 | `0x009A0334` | `0x00200019` | 0x0019 | WL_code=1, RL_code=3 (DRAM latency codes, not raw cyc) |
| MR3 | `0x009A0338` | `0x003000EB` | 0x00EB | **RAS=43**, [7:6]=3 |
| MR4 | `0x009A033C` | `0x00400030` | 0x0030 | ECC/parity/vendor misc |
| MR5 | `0x009A0340` | `0x00500000` | 0x0000 | default (payload 0) |
| MR6 | `0x009A0344` | `0x00600000` | 0x0000 | default (payload 0) |
| MR7 | `0x009A0348` | `0x00700000` | 0x0000 | default (payload 0) |
| MR8 | `0x009A0354` | `0x00800000` | 0x0000 | default (payload 0) |
| MR9 | `0x009A0358` | `0x00900000` | 0x0000 | default (payload 0) |
| MR14 | `0x009A035C` | `0x00E00000` | 0x0000 | default (payload 0) |
| MR15 | `0x009A034C` | `0x00F00000` | 0x0000 | default (payload 0) |

`MR5..MR15` carry payload 0 on this card (defaults). Note MR2's RL/WL are *encoded
codes* the die maps to real latency per its datasheet — that is why they read 3/1, not
the controller's CL=37/WL=10.

---

## 4. When these timings apply in boot — and how to change them

### The apply moment: VBIOS devinit (POST), before the driver

1. Power-on → PCIe link up.
2. **VBIOS devinit tables** run on the PMU/devinit engine at high privilege. This is
   where the FBPA `CONFIG/TIMING` registers are written from the VBIOS memory-tuning
   tables, `MRS` commands are issued to the HBM stacks, HBM **training** runs
   (address / WCK / read / write), DLLs calibrate, and the controller computes the
   effective `_GEN` values.
3. Normal operation. **This card exposes a single mem pstate (1728 MHz)** → the timings
   are **never re-derived at runtime**; there is no mclk-switch to reprogram them.
4. OS driver loads → it *reads* these; it does not reprogram the base timings.

So the timings are latched **once, at POST**, long before the driver — and then frozen.

### Why a runtime host poke does not work

- **Write-locked.** `NV_PFB_FBPA_MEM_PRIV_LEVEL_MASK` (`0x009A0168`) = `0xFFFFFFCF` → WRITE_PROTECTION `[7:4]` = `0xC` = only privilege **levels 2–3**
  may write. A BAR0 write from the CPU (level 0) is silently dropped —
  `gpu_reg_tool write 0x009A0290 …` will **not** stick.
- Even from a privileged writer, a live controller needs a **self-refresh wrapper**:
  `SELF_REF`=ENABLED → reprogram `CONFIG/TIMING` (+ re-issue `MRS` for DRAM-side
  values) → optionally retrain → exit self-refresh. Poking a running controller
  without that either no-ops or corrupts memory.
- Anything set at runtime is **lost on reboot**.

### The practical options

| Method | Applies at | Survives reboot | Needs |
|---|---|---|---|
| **Edit VBIOS memory-timing tables + reflash** (realistic path) | next POST/devinit | yes | nvflash, VBIOS timing edit, recovery plan |
| **Privileged Falcon at runtime** | immediately | no | code at priv level ≥2 (PMU/GSP/SEC2 — the GSP-bypass chain), self-refresh+retrain wrapper |
| Host BAR0 write | — | — | blocked by PLM — does not work |

**Bottom line:** change the values in the **VBIOS timing tables and reflash** so devinit
applies (and trains) them at the next boot. A runtime change is only possible from a
level-2 Falcon and would be wiped on reboot anyway. Toggling `USE_TIMING_REGS`
(CONFIG vs TIMING source) does not help — both copies sit behind the same PLM lock.

---

## 4a. Bandwidth ceiling & the disabled stacks

### The ceiling is set by width × clock — timings only affect efficiency

```
active FBPAs = 16 of 24            (CSTATUS: 8 read 0xBADF = floorswept)
bus width    = 16 × 256 bit        = 4096 bit
data rate    = 2 × 1728 MHz        = 3.456 Gbps/pin (HBM2e, DDR)
─────────────────────────────────────────────────────────────
theoretical peak = 3.456 × 4096/8  = 1769 GB/s   ← hard ceiling
```

Measured (`mem_bench`, 1 GB): read **1617** (91% of peak), write 1394 (79%),
copy 1514, triad 1585, DMA D2D 1593 GB/s. Read is already ~91% of the wall.

**Timings cannot cross 1769 GB/s** — they only recover part of the ~9% gap (refresh
`tRFC`/`tREFI` is the biggest lever; row `tRC`/`tRP`/`tRAS` help random access; write
turnaround helps copy/triad). Realistic tuned ceiling ≈ **1680–1720 GB/s read**.
**2 TB/s is above the physical wall at 4096-bit — unreachable by timings.**

### The only route to 2 TB/s is a wider bus — and part of it may be recoverable

Reading this card's floorsweep fuses:

| Fuse | Addr | Value | FBPAs |
|---|---|---|---|
| `FUSE_OPT_FBPA_DISABLE` | `0x00820368` | `0x00C0330C` | {2,3, 8,9, 12,13, 22,23} off (8) |
| `FUSE_OPT_FBPA_DEFECTIVE` | `0x008205D0` | `0x00C03000` | {12,13, 22,23} bad silicon (4) |
| **DISABLE − DEFECTIVE** | | | **{2,3, 8,9} — off but NOT defective (4)** |

So 4 FBPAs (1024-bit) are disabled for SKU segmentation, not because they're broken.
If they could be brought back: 16→20 FBPA = **5120-bit** → 3.456 × 5120/8 =
**2211 GB/s** theoretical → ~2010 GB/s at 91% → **2 TB/s becomes physically possible.**

### Why it is still a long shot

| Lock | Value | Effect |
|---|---|---|
| `FUSE_EN_SW_OVERRIDE` | `0x00820040` = `0x0` | the CTRL_OPT SW-override path is **fuse-disabled** — `CTRL_OPT_FBPA` writes are ignored |
| `FUSE_DIS_SW_OVR` | `0x00820084` = `0x1` | likely **latches** EN_SW_OVERRIDE off, so even an HS Falcon can't enable the override |
| `FUSE_MEM_LOCKED` / `FUSE_FBPA_MEM_WR_SEC` | `0x1` | memory config write-locked |

This is the same wall that defeated the compute unlock. Even if the override took,
re-enabling an FBPA is a **devinit-time** operation (FB re-init with the new mask +
full HBM training on the recovered channels + MMU/CFG1 remap), not a runtime poke.

### The cheap, decisive experiment (via the SEC2/HS chain)

The HBM **IEEE1500** test port is host-readable here (`I1500_INSTR 0x009A3CB4`=0x0F,
`I1500_DATA 0x009A3CBC`=live, not `0xBADF`), so the port is not fully locked. Plan:

1. **Probe** channels {2,3,8,9} over per-FBPA IEEE1500 (`0x00900000 + fbpa*0x4000 +
   0x3CB4`): drive `WIR` = DEVICE_ID / run `MBIST`. If a die answers → the stack is
   physically present and (per DEFECTIVE=0) good → recovery is worth pursuing.
2. **Write-probe** the floorsweep override (HS): try clearing {2,3,8,9} in the FS path.
   If `EN_SW_OVERRIDE`=0 + `DIS_SW_OVR`=1 truly lock it → blocked, hard stop.
3. If it takes → patch devinit to init with 20 FBPA + retrain → measure.

**Odds:** the non-defective 4 FBPAs are real and make 2 TB/s *physically* possible; the
`DIS_SW_OVR=1` override lock is the make-or-break, and the prior (from the compute
unlock) is that it holds. Probing (step 1) is cheap and non-destructive; actual
re-enable (steps 2–3) is a research project gated by that fuse.

---

## 5. Re-extracting after a future vBIOS flash

```bash
# dumps the whole FBPA + NV_PFB block from BAR0 (needs root)
cd /home/aboba/nvidia-unlock/chain-a-v2
sudo ./gpu_reg_tool dump-fbpa /tmp/fbpa_new.txt
# single register:
sudo ./gpu_reg_tool read 0x009A0290
```

The tool mmaps `/sys/bus/pci/devices/0000:03:00.0/resource0`; if the card ever moves
bus address, update `SYSFS_BAR0` in `gpu_reg_tool.c`.

## 6. Sources

- **Register map & bitfields:** `....../dev_fbpa.h`
- **Live values:** `gpu_reg_tool dump-fbpa` (BAR0 MMIO)
- **Cross-reference:** envytools `rnndb/memory/gf100_pbfb.xml` (older layout; offsets
  differ from GA100 — GA100 timings start at `0x220`, Fermi at `0x290`)
- **Card context:** `timings/fuse-reference-table.md`
