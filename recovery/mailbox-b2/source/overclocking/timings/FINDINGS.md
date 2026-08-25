# Memory timings — live tuning results

Card: CMP 170HX `10de:20c2` @ `03:00.0`, driver 610.43.03 (cmpunlocker),
running `--mclk-ndiv=73` → **1971 MHz** (tCK = 0.507 ns).

---

## 1. The control path works

`FBPA_MEM` PLM (`0x009a0168`) opens on the first Booter round trip:

```
CMPUNLOCK: PLM[2] FBPA_MEM(0x9a0168) attempt=0 status=0xffff reg=0xffffffff
CMPUNLOCK: PLMs: ... FBPA_MEM=0xffffffff ...
```

With that gate open, `CONFIG0..CONFIG3` (`0x009A0290`–`0x009A029C`) are writable
from the host over BAR0 — no driver code needed, `fbpa_regs` mmaps the aperture.

`CONFIG0.USE_TIMING_REGS` = 0, so the CONFIG registers are the live set. Writes
are picked up **immediately on running traffic** — no retrain, no self-refresh
cycle, no reboot. Two independent confirmations:

- The read-only `TIMINGn_GEN` mirrors follow the write (`RAS 43→45` → `_GEN 45`).
- Bandwidth actually moves: `tRC 67→255` dropped reads 1903 → 1493 GB/s (−21%).

Everything is volatile — a reboot restores the VBIOS table.

## 2. Do not trust the latency metric

`nvidia_bench` "Memory Latency" reads **315.7 ns regardless of timings** — it did
not move by 0.1 ns even at `tRC=255`, which cost 400 GB/s. That number is
dominated by TLB/page-walk, not DRAM.

**Tune against Global Read / Copy bandwidth.** Latency is blind here.

## 3. What actually binds — loosening probe

Each field loosened alone, bandwidth measured, then restored. Baseline
1905 read / 1744 copy GB/s.

| Field | Change | Read | Copy | Δ read / copy |
|---|---|---:|---:|---|
| **CCDS** | 2→6 | 652 | 628 | **−1253 / −1116** |
| **CCDL** | 4→10 | 802 | 755 | **−1103 / −989** |
| RD_RCD | 27→45 | 1890 | 1730 | −15 / −14 |
| RP | 24→40 | 1895 | 1698 | −10 / −46 |
| WR | 25→45 | 1904 | 1696 | −1 / −48 |
| R2W_BUS | 8→14 | 1903 | 1723 | −2 / −21 |
| FAW | 22→45 | 1900 | 1736 | −5 / −8 |
| RC | 67→120 | 1903 | 1740 | −2 / −4 |
| RAS | 43→70 | 1903 | 1742 | −2 / −2 |
| WR_RCD | 18→32 | 1903 | 1747 | −2 / +3 |
| W2R_BUS | 8→14 | 1903 | 1748 | −2 / +4 |

**Column-to-column delay is the whole game** for streaming bandwidth. Everything
else is at or near noise. `tRC` has so much slack that +53 cycles cost nothing —
tightening it is pointless.

Copy-only sensitivity (`WR`, `RP`, `R2W_BUS`) is the write/turnaround path.

## 4. tCCD_L = 4 is the floor — 3 hangs the card

`CCDL 4→3` locked the GPU immediately:

```
NVRM: krcWatchdog_IMPL: RC watchdog: GPU is probably locked!
NVRM: ... Reset required [NV_ERR_RESET_REQUIRED] (0x00000062)
```

Restoring `CCDL=4` does **not** recover — the controller has already faulted.
`nvidia-smi -r` reports `Not Supported` on this card, so **recovery is a reboot**.

`CCDS=2` is almost certainly the burst-length floor and was not probed downward.

## 5. Stock reference point

Stock timings at NDIV 73 (1971 MHz), after a clean reboot:

```
$ ./gpu_burn -d 60
100.0%  proc'd: 666 (13880 Gflop/s)   errors: 0   temps: 58 C
Tested 1 GPUs:  GPU 0: OK
```

Bandwidth over 5 runs: **read 1903.3 ± 0.9**, **copy 1742.3 ± 3.0** GB/s.

That standard deviation is the noise floor for any timing experiment on this
card — an effect smaller than ~2 GB/s read or ~6 GB/s copy cannot be
distinguished from run-to-run variation without averaging.

## 6. Why there is little headroom here

The registers hold **cycles**, not nanoseconds, and this card runs at 1971 MHz
instead of the 1728 MHz the VBIOS table was written for. The stock cycle counts
are therefore already ~14% tighter in real time:

| | cycles | ns @1728 | ns @1971 |
|---|---:|---:|---:|
| tRC | 67 | 38.8 | 34.0 |
| tRAS | 43 | 24.9 | 21.8 |
| tRP | 24 | 13.9 | 12.2 |
| tRCD | 27 | 15.6 | 13.7 |

Raising `--mclk-ndiv` silently tightens every timing. That is likely a real part
of why high NDIV values fail on some cards — not only the PLL, but the timing
table going sub-spec in absolute time.

**Corollary worth testing:** on a card that fails at a high NDIV, *loosening*
timings by a cycle or two may make that clock stable. That is the more promising
direction here than tightening.

The offset is runtime-only and resets on reboot. For a persistent setting see
  [170tune](https://github.com/cachenetics/170tune), which sweeps the VF curve
  properly instead of guessing a flat offset.

## 7. Where the payoff is — and is not

Measured sensitivity per cycle, against a noise floor of ±0.9 read / ±3.0 copy:

| Field  | GB/s per cycle | Gain from −1 cycle       |
|--------|----------------|--------------------------|
| RD_RCD | ~0.8 read      | +0.04% — **below noise** |
| RP     | ~2.9 copy      | +0.17% — at noise        |
| WR     | ~2.4 copy      | +0.14% — at noise        |

Tightening the non-tCCD timings is not worth the hang risk on this card: the
gain does not clear the measurement noise, and both tCCD values are already at
their floor. **Bandwidth here is clock-bound, not timing-bound.**

Directions that are actually worth pursuing:

- **Loosen to stabilise a higher NDIV.** Clock scales bandwidth linearly and the
  probe showed timings contribute almost nothing, so NDIV 76+ with `RD_RCD`/`RP`/
  `RAS` raised a cycle or two is the promising experiment. Loosening is safe.
- **Re-probe at stock clock (NDIV 64)** where the ns margin is larger —
  tightening may have room there that it does not have at 1971 MHz.
- Any candidate must pass `gpu_burn -d` with **zero** errors before it counts.
  Bandwidth alone proves nothing about correctness.

## Tools

- `fbpa_regs.c` — mmap BAR0, `list`/`dump`/`get`/`set`/`save`/`load`/`read`/`write`
- `timings-set.sh` — fields by name, or `--scale N` / `--stock`
- `timings-dump.sh`, `timings-restore.sh` — snapshot and put back
- `timings-probe.sh` — loosen each field in turn, measure, restore
- `timings-bench.sh` — average N benchmark runs, report mean and SD
