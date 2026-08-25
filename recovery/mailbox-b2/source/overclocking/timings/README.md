# Memory Timings

The unlock opens the `FBPA_MEM` PLM gate (`0x009a0168`), which makes the HBM2e
timing registers writable from the host. These tools drive them at runtime.

**Read [FINDINGS.md](FINDINGS.md) first** — it has measured results, including
which value hard-hangs the card and why gpu-burn errors are usually *not* a
memory problem at all.

---

## Tools

|                      |                                                                                          |
|----------------------|------------------------------------------------------------------------------------------|
| `timings-dump.sh`    | show current timings, optionally save a restorable snapshot                              |
| `timings-set.sh`     | change individual fields, or scale the safe set by a percentage                          |
| `timings-restore.sh` | write a snapshot back                                                                    |
| `timings-probe.sh`   | find which timings actually bind performance, without risking a hang                     |
| `timings-bench.sh`   | averaged bandwidth, so small effects can be told from noise                              |
| `fbpa_regs.c`        | the primitive the scripts drive — `list`/`dump`/`get`/`set`/`save`/`load`/`read`/`write` |

The scripts build `fbpa_regs` on first use, so there is no separate compile
step. All of them need root (BAR0 access) and take `GPU=N` for the card index
from `fbpa_regs list`.

```bash
sudo ./timings-dump.sh                 # what am I running?
sudo ./timings-dump.sh before.txt      # ... and save it

sudo ./timings-set.sh RAS 45           # one field
sudo ./timings-set.sh RAS 45 RP 28     # several
sudo ./timings-set.sh --scale 20       # loosen the safe set 20%
sudo ./timings-set.sh --scale -10      # tighten it 10%
sudo ./timings-set.sh --stock          # undo everything

GPU=1 sudo ./timings-dump.sh           # second card
```

Changes are **live and immediate** — no reboot, no retrain. They are also
**volatile**: a reboot restores the VBIOS table, which is the escape hatch when
something goes wrong.

The first run snapshots the card's stock values to `baseline-<bdf>.txt`.
`--scale` always computes from that snapshot, so running it twice does not
compound, and `--stock` always has something to go back to.

For a setting that survives reboot, use the driver flag instead:
`sudo ./install.sh --mclk-timings=20`.

---

## What gets scaled, and what never does

`--scale` touches only timings that mean *"wait longer before issuing the next
command"* — those can be raised freely, because giving DRAM more time can never
violate spec:

> `tRC` `tRFC` `tRAS` `tRP` `tRCD_rd` `tRCD_wr` `tWR` `tFAW` `tRRD`

Two groups are deliberately excluded:

- **`CL` / `WL`** — these say *when to sample data*, and have to match the mode
  registers trained into the HBM stacks. Raising them here desynchronises the
  read pointer rather than adding margin.
- **`tCCD_S` / `tCCD_L`** — the only timings that bind streaming bandwidth
  (loosening them 4 cycles costs ~60% of it), and both already sit at the
  hardware floor. `CCDL=3` hangs the card outright.

You can still set those by name with `timings-set.sh CL 38` if you know what
you are doing. The scale just will not touch them for you.

---

## How to tell a change actually took

`TIMINGn_GEN` are read-only registers holding what the memory controller
actually generated. `set` checks them for you:

```
$ sudo ./timings-set.sh RAS 45
CONFIG0.RAS: 43 -> 45   _GEN 43 -> 45 (controller picked it up)
```

If `_GEN` does not follow, the write reached the register but not the
controller, and nothing changed in reality. Not every field has a mirror —
those print `-` in the dump and can only be confirmed by measuring.

---

## Register map

`CONFIG0.USE_TIMING_REGS` is **0** on this card, so the `CONFIG*` registers are
the live set. The `TIMING0..TIMING9` block at `0x220`+ is an inactive legacy
copy holding DDR3-era defaults — ignore it.

### Writable

| Register | Address | Fields (bits) |
|---|---|---|
| CONFIG0 | `0x009A0290` | RC 7:0 · RFC 16:8 · RAS 23:17 · RP 30:24 · USE_TIMING_REGS 31 |
| CONFIG1 | `0x009A0294` | CL 6:0 · WL 13:7 · RD_RCD 19:14 · WR_RCD 25:20 · QPOP_OFFSET 31:26 |
| CONFIG2 | `0x009A0298` | RPRE 3:0 · WPRE 7:4 · CDLR 14:8 · WR 22:16 · W2R_BUS 27:24 · R2W_BUS 31:28 |
| CONFIG3 | `0x009A029C` | PDEX 4:0 · PDEN2PDEX 8:5 · FAW 16:9 · AOND 23:17 · CCDL 27:24 · CCDS 31:28 |
| CONFIG4 | `0x009A02A0` | REFRESH_LO 2:0 · REFRESH 14:3 · RRD 20:15 · IDLE_DELAY 26:21 |
| CONFIG10 | `0x009A02F4` | RFC_MSB 1:0 · IDLE_DELAY_MSB 4 · RD_RCD_MSB 8 · WR_RCD_MSB 11 |

Three fields are split across two registers, with their high bits in CONFIG10:
`tRFC` (9 bits + 2), `tRCD_rd` (6 + 1), `tRCD_wr` (6 + 1). `fbpa_regs` joins
them, so `get RFC` returns the real 657 rather than the low 145.

### Read-only — what the controller generated

| Register | Address | Fields (bits) |
|---|---|---|
| TIMING0_GEN | `0x009A02B0` | RC 8:0 · RFC 22:12 · RAS 31:24 |
| TIMING1_GEN | `0x009A02B4` | R2W 7:0 · W2R 14:8 · R2P 20:16 · W2P 30:24 |
| TIMING2_GEN | `0x009A02B8` | RD_RCD 7:0 · WR_RCD 15:8 · RRD 22:16 · WDV 28:24 |

Full field-level decode of the whole block: [`reference/`](reference/).

---

## Cycles, not nanoseconds

Every value is a **cycle count**, so what it buys depends on the memory clock:

```
ns = cycles × (1000 / mem_clock_MHz)
```

At the VBIOS-stock 1728 MHz a cycle is 0.579 ns; at 1971 MHz (`--mclk-ndiv=73`)
it is 0.507 ns. **Raising the memory clock silently tightens every timing:**

| | cycles | ns @1728 | ns @1971 |
|---|---:|---:|---:|
| tRC | 67 | 38.8 | 34.0 |
| tRAS | 43 | 24.9 | 21.8 |
| tRP | 24 | 13.9 | 12.2 |
| tRCD | 27 | 15.6 | 13.7 |

That is why there is little room to tighten on an already-overclocked card, and
why loosening is worth trying when a high NDIV will not hold.

---

## Method

1. **Rule out the core clock first.** Errors under load are usually not a memory
   problem — on the test card they were entirely core. One command answers it:
   `sudo ../set-clock-offset.py -100`. See [FINDINGS.md](FINDINGS.md) §7.
2. **Snapshot before you start.** `sudo ./timings-dump.sh before.txt`.
3. **Probe by loosening, not tightening.** `timings-probe.sh` maps out what
   actually binds with no risk of a hang, because more time is always legal.
   Only then is it worth tightening whatever showed sensitivity.
4. **Measure with repeats.** Noise is about ±1 GB/s read and ±3 GB/s copy, so
   anything smaller needs averaging: `./timings-bench.sh 5`.
5. **Ignore the latency number.** The benchmark's "Memory Latency" does not move
   with timings at all — it is dominated by page walks. Tune against bandwidth.
6. **Validate correctness, not speed.** Bandwidth proves nothing; a too-tight
   timing returns wrong data without crashing. Every candidate must pass
   [gpu-burn](https://github.com/wilicc/gpu-burn) with zero errors:
   `./gpu_burn -d 300`.

---

## Recovery

A too-tight timing wedges the memory controller:

```
NVRM: krcWatchdog_IMPL: RC watchdog: GPU is probably locked!
NVRM: ... Reset required [NV_ERR_RESET_REQUIRED] (0x00000062)
```

Writing the old value back does **not** help — the controller has already
faulted, and `nvidia-smi -r` answers `Not Supported` on this card.

**The only recovery is a reboot**, and nothing here is persistent, so the card
always comes back on the VBIOS table.

If a *driver* flag (`--mclk-timings`) left the card unable to initialise,
reinstall without it — `install.sh` will offer to build with no GPU present.
