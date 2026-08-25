# Overclocking

Four independent knobs:

|                              | What                              | How                                 | Persists                |
|------------------------------|-----------------------------------|-------------------------------------|-------------------------|
| **Core clock**               | GPC clock offset                  | `set-clock-offset.py` at runtime    | no, re-run after reboot |
| **Power limit**              | board power cap                   | `set-power-limit.py` at runtime     | no, re-run after reboot |
| **Memory clock**             | HBM2e FBPA PLL multiplier         | compiled into the driver at install | yes, until reinstall    |
| **Memory timings**           | HBM2e FBPA timing registers       | `timings/timings-set.sh` at runtime | no, reset by VBIOS      |

Each section below is collapsed — click to open.

---

<details>
<summary><b>Core Clock &amp; Power Limit</b> — GPC offset and board power cap, applied at runtime</summary>

Two scripts, both through NVML, both applying to every GPU unless `-g N` picks one. Runtime only — nothing is compiled in, and the settings are gone after a reboot.

```bash
sudo ./set-clock-offset.py 150       # +150 MHz core on every GPU
sudo ./set-clock-offset.py -100      # back every GPU off by 100 MHz
sudo ./set-clock-offset.py 0         # reset

sudo ./set-power-limit.py --show     # current limit and allowed range
sudo ./set-power-limit.py 300        # 300 W on every GPU
sudo ./set-power-limit.py --max      # each GPU to its own maximum
```

The board enforces its own min/max, so a wattage outside the range is reported
and skipped rather than silently clamped.

Negative offsets are allowed and are the quickest way to tame a card that is unstable. Each GPU is set independently — a failure on one is printed with its NVML return code and the rest still get applied, and the script exits non-zero if anything failed.

### Dialing it in properly

`set-clock-offset.py` just applies a number you picked. To actually find the right one, use [**170tune**](https://github.com/cachenetics/170tune) — a tuning harness built specifically for the 170HX on an unlocked driver.

It sweeps the VF offset and clock ceiling automatically and gates every candidate through a full-VRAM pattern sweep plus bit-exact GEMM checks, so it separates "did not crash" from "did not silently corrupt" — the failure mode that matters on an undervolted card. It then soaks the point at temperature and can validate it against **your** workload before persisting it, which is the part hand-tuning never gets right: a dense GEMM is one steady instruction mix, while real inference alternates prefill bursts, memory-bound decode and graph replay, and shakes out settings a synthetic burn never touches.

Faster and far more precise than stepping offsets by hand. Needs the patched driver, CUDA and root; it does not touch the memory clock — that stays on `--mclk-ndiv`.

</details>

---

<details>
<summary><b>Memory Clock (NDIV)</b> — HBM PLL multiplier, compiled into the driver</summary>

The HBM clock is a PLL multiplier of a 27 MHz reference:

```
clock = NDIV × 27 MHz
```

Set it at install time. The value is compiled into the modules, so changing it means re-running `install.sh` and cold rebooting:

```bash
sudo ./install.sh --mclk-ndiv=70    # 1890 MHz
```

Valid range is **30–80** (810–2160 MHz). Without the flag the overclock is compiled out entirely — the card runs at whatever the VBIOS programmed.

Works on any VBIOS and both variants: the stock NDIV is read out of the PLL rather than assumed, and the write preserves the MDIV/PDIV the VBIOS set.

### Stock values

| Card            | VBIOS | NDIV | Clock    |
|-----------------|-------|------|----------|
| 10GB (`0x2082`) | any   | 45   | 1215 MHz |
| 8GB (`0x20C2`)  | 250 W | 54   | 1458 MHz |
| 8GB (`0x20C2`)  | 300 W | 64   | 1728 MHz |

### What usually holds

| NDIV  | Clock    | Notes                |
|-------|----------|----------------------|
| 60    | 1620 MHz | ~60% of 10GB cards   |
| 70    | 1890 MHz | ~60% of 8GB cards    |
| 73    | 1971 MHz | lucky 8GB cards only |

### NDIV → MHz

| N  | MHz  | N  | MHz  | N  | MHz  | N  | MHz  |
|----|------|----|------|----|------|----|------|
| 45 | 1215 | 54 | 1458 | 63 | 1701 | 72 | 1944 |
| 46 | 1242 | 55 | 1485 | 64 | 1728 | 73 | 1971 |
| 47 | 1269 | 56 | 1512 | 65 | 1755 | 74 | 1998 |
| 48 | 1296 | 57 | 1539 | 66 | 1782 | 75 | 2025 |
| 49 | 1323 | 58 | 1566 | 67 | 1809 | 76 | 2052 |
| 50 | 1350 | 59 | 1593 | 68 | 1836 | 77 | 2079 |
| 51 | 1377 | 60 | 1620 | 69 | 1863 | 78 | 2106 |
| 52 | 1404 | 61 | 1647 | 70 | 1890 | 79 | 2133 |
| 53 | 1431 | 62 | 1674 | 71 | 1917 | 80 | 2160 |

### Finding a stable value

Go up in steps of 2–3 from stock. After every step, three checks in this order:

```bash
sudo dmesg | grep HBMPLL_OC     # 1. did the PLL actually lock?
nvtop                           # 2. did bandwidth actually go up?
./benchmark/nvidia_bench        # 2. did bandwidth actually go up?
gpu_burn -d 300                 # 3. is it stable?  <- the real test
```

**Step 3 is the one that decides.** The benchmark only measures throughput — it does not check that the numbers coming back are right, so an unstable clock sails through it. [gpu-burn](https://github.com/wilicc/gpu-burn) runs matrix multiplications and verifies every result against a reference, which is what actually catches memory that is fast but wrong:

```bash
git clone https://github.com/wilicc/gpu-burn
cd gpu-burn && make
./gpu_burn -d 300        # doubles, 300s = 5 minutes
```

Any non-zero error count, or a GPU reported as `FAULTY`, means the memory is unstable. Go back one step and re-test; do not keep a value that produced even a single error!

Stop and go back one step if you see any of these:

| dmesg                            | Meaning                                                      |
|----------------------------------|--------------------------------------------------------------|
| `N/12 FBPAs failed to lock`      | clock too high for the PLL                                   |
| `no active FBPAs found`          | the PLL registers did not read back — unlock problem, not OC |
| `aborted, PLM=... (bit4 closed)` | the PLL gate never opened — unlock problem, not OC           |

Bandwidth that stays flat or drops while the clock goes up is also a fail, even though nothing crashed — the memory controller is retrying behind your back.

**Downclocking is a real use.** A card that is unstable at stock often becomes solid a few steps below it — `--mclk-ndiv=50` on a 10GB card, `--mclk-ndiv=60` on an 8GB one.

### If it does not boot

The clock is applied during driver init, so a bad value shows up as a hang, a wedged GPU or corrupt results — not a dead card. Reinstall from a working state:

```bash
sudo ./install.sh --mclk-ndiv=64    # step back down
# or drop the overclock entirely:
sudo ./install.sh
```

Cold reboot (full power off) after any of these.

In a mixed 8GB + 10GB system the multiplier is compiled in once and lands on **every** card, and stock differs per variant — pick a value that is safe for the weakest one. (**in progress**)

</details>

---

<details>
<summary><b>Memory Timings</b> — HBM2e FBPA timing registers, live and writable</summary>

The clock decides how often the memory bus ticks; the timings decide how many of those ticks are spent waiting. The unlock opens the `FBPA_MEM` PLM gate (`0x009a0168`), which makes the whole HBM2e timing block writable from the host.

Full guide, register map and tools: **[`timings/`](timings/)** · measured results: **[`timings/FINDINGS.md`](timings/FINDINGS.md)**

### The persistent way — `--mclk-timings`

```bash
sudo ./install.sh --mclk-ndiv=76 --mclk-timings=20   # negative tightens
```

Loosens `tRC` `tRFC` `tRAS` `tRP` `tRCD` `tWR` `tFAW` `tRRD` by 20% **before** the clock is raised, so the memory comes up on the loosened table rather than landing on the stock one first. Applied again after GSP boots, since GSP reprograms the timing table during its own memory init. Verify with `sudo dmesg | grep TIMING_SCALE`.

`CL`/`WL` and `tCCD` are never touched — see below for why.

### The runtime way — `fbpa_regs`

```bash
cd timings

sudo ./timings-dump.sh             # current timings, in cycles
sudo ./timings-set.sh RAS 45       # change one field, live
sudo ./timings-set.sh --scale 20   # loosen the safe set by 20%
sudo ./timings-set.sh --stock      # undo everything
```

The scripts build the tool on first use and snapshot your stock values, so
`--stock` always has somewhere to go back to.

Changes take effect **immediately** on running traffic — no reboot, no retrain. They are **volatile**: a reboot restores the VBIOS table.

### What we measured

Loosening each timing one at a time and watching bandwidth (baseline 1903 read / 1742 copy GB/s at NDIV 73):

| Field | Loosened | Read | Δ |
|---|---|---:|---|
| **CCDS** | 2→6 | 652 | **−66%** |
| **CCDL** | 4→10 | 802 | **−58%** |
| RD_RCD | 27→45 | 1890 | −0.8% |
| RP | 24→40 | 1895 | −0.4% |
| everything else | | | noise |

**Column-to-column delay is the whole game** for streaming bandwidth, and both tCCD values are already at their floor. `tRC` has so much slack that +53 cycles cost nothing. So on a card that is already at a high NDIV there is essentially nothing to gain by tightening.

### Timings are in cycles, not nanoseconds

`ns = cycles × (1000 / mem_clock_MHz)`. Raising `--mclk-ndiv` therefore **silently tightens every timing** — at 1971 MHz the stock table is ~14% tighter in real time than the 1728 MHz it was written for.

That points at the useful direction: if a high NDIV is unstable, *loosening* a timing or two may be what makes it hold. That is more promising than tightening, and it is safe to try — giving DRAM more time can never violate spec.

### Rule out the core clock first

Memory errors in gpu-burn are not proof of a memory problem. On the test card at NDIV 73, `gpu_burn -d 90` failed consistently on **stock** timings — and loosening every row timing by 20% changed nothing, while dropping the **core** clock by 100 MHz fixed it outright:

```bash
sudo ./set-clock-offset.py -100     # one command, answers the question
```

If that clears the errors, the memory was never the problem and no amount of timing work will help. Details in [`timings/FINDINGS.md`](timings/FINDINGS.md).

### Before you start

- **Probe by loosening.** `timings-probe.sh` maps out what actually binds, with zero risk of a hang.
- **Ignore the latency number** in the benchmark — it does not move with timings at all. Tune against Global Read / Copy bandwidth.
- **Bandwidth proves nothing about correctness.** Validate with `gpu_burn -d 300`, zero errors.
- **A too-tight timing hangs the card, and writing the old value back does not recover it.** `nvidia-smi -r` is `Not Supported` here — recovery is a reboot. `CCDL=3` is a known instant hang.

</details>

---

## Safety

Memory overclocking can corrupt results **silently**. A clean benchmark run proves nothing about correctness. Never trust a new NDIV until it has survived a long [gpu-burn](https://github.com/wilicc/gpu-burn) run with zero errors.

Nothing here is flashed to the card. Everything is undone by reinstalling.
