# CMP 170HX PCIe x4 → x16 hardware capacitor mod

[← Main guide](../README.md) · [Русская версия](PCIE-X16-HARDWARE-MOD.ru.md)

> **Hardware modification.** This requires soldering 0402 SMD parts on a multilayer GPU PCB. A mistake can permanently damage the card. Practice on scrap hardware first if you are not comfortable with 0402 rework.

## What this mod fixes

The CMP 170HX has a full mechanical x16 edge connector and the PCB routes all 16 PCIe lanes, but the factory board leaves the AC-coupling capacitors for **lanes 4–15** unpopulated. Stock lane width therefore negotiates as x4.

Restoring those missing coupling capacitors restores the physical lane width:

- stock: x4
- populate 12 missing capacitors / six additional lanes: potentially x8
- populate all 24 missing capacitors / twelve additional lanes: x16

This is **independent of PCIe generation**. The capacitor mod changes width; the separate software work changes Gen1 → Gen2.

## Parts

For a complete x16 modification you need:

| Item | Specification |
|---|---|
| Quantity | **24 capacitors** (buy 30–40; 0402 parts are easy to lose) |
| Package | **0402 / 1005 metric** |
| Capacitance | **0.22 µF / 220 nF** |
| Dielectric | **X7R** |
| Voltage | **16 V** used successfully; ≥6.3 V is sufficient according to the A100-derived reference design |
| Confirmed part | **Samsung CL05B224KO5NNNC** |

### Part used on our cards

We used **Samsung CL05B224KO5NNNC — 0.22 µF, X7R, 16 V, 0402**.

Russian retail listing used for our build:

https://www.chipdip.ru/product/0.22mkf-x7r-16v-10-0402-cl05b224ko5nnnc-kondensator-samsung-9000681245

The same Samsung part is independently listed as a confirmed-working part by community CMP 170HX hardware-mod documentation.

## Where to solder

The CMP 170HX PCB is derived from the NVIDIA A100 40 GB PCIe PG100/PG101 board family. The missing parts are the **24 empty 0402 AC-coupling capacitor footprints on the PCIe lane routing for lanes 4–15**, between the PCIe edge connector and the GPU.

The A100 reference schematic identifies the relevant capacitor designators roughly in the **C1100–C1350** range on the `IO: PCIe CONNECTOR` page.

**Do not solder from the C-number range alone.** Board revisions exist and a wrong 0402 footprint can damage the card. Identify the empty differential-lane capacitor footprints visually and cross-check against the board/schematic before soldering.

### Photo annotation

A high-resolution annotated photograph of our own known-working card will be added here. It will mark all 24 positions individually. Until that image is present, use the upstream photographic/reference material and verify every footprint before soldering.

Useful upstream references:

- https://github.com/amoghmunikote/170th-Street/blob/master/modifications/pcie-capacitor-mod.md
- https://github.com/Consensus-Protocol/cmp170hx/blob/main/docs/hardware/board-and-variants.md

## Recommended tools

- microscope or strong magnification
- fine ESD-safe tweezers
- fine-tip temperature-controlled soldering iron
- good gel flux
- solder wick
- leaded 60/40 solder for easier hand rework, where legally permitted
- IPA and lint-free swabs for cleanup
- multimeter for checking suspicious bridges/shorts before power-on

Hot air can be used by an experienced technician, but it is not required for this modification.

## About preheating

A bottom preheater **can make work on a large multilayer PCB easier when used correctly**, but it is not mandatory. Our two successful cards were soldered **without board preheating**.

Community reports also document successful hand soldering with a fine iron around 380 °C, flux and leaded solder without preheating.

Do **not** aggressively heat the whole card with an uncontrolled hot plate, oven, IR stove or excessive hot air. Large multilayer PCBs can warp; overheating can damage internal traces, packages and nearby components. Controlled mild preheat in experienced hands is one thing; cooking the entire PCB is not.

## Suggested procedure

1. Power down the machine and remove the card.
2. Photograph the untouched capacitor area at high resolution before starting.
3. Identify all 24 missing lane-coupling footprints and compare them with a known-good reference.
4. Work under magnification.
5. Add gel flux to a small group of pads.
6. If necessary, wick/refresh the factory lead-free solder and add a very small amount of fresh solder.
7. Place each 0402 capacitor squarely across its two pads.
8. Solder with the shortest practical dwell time. Avoid repeatedly heating the same area.
9. Inspect every joint for bridges, tombstoned parts and shifted capacitors.
10. Clean the area and inspect it again under magnification.
11. Before powering the card, check any suspicious neighboring pads with a multimeter.
12. Install the card and verify negotiated width with `lspci`.

These ceramic capacitors are **non-polarized**; orientation does not matter electrically.

## Verification

Find the card BDF:

```bash
nvidia-smi --query-gpu=index,pci.bus_id --format=csv
```

Then check the real link state, for example:

```bash
sudo lspci -vv -s 82:00.0 | grep -E 'LnkCap:|LnkSta:'
```

A successful x16 hardware modification should report `Width x16` in `LnkSta` when the motherboard slot/root port also provides x16 lanes.

Our final cards, after the separate Gen2 software work, report approximately:

```text
LnkSta: Speed 5GT/s, Width x16
```

Remember:

- **Width x16** proves the hardware lane-width mod.
- **Speed 5GT/s** proves the separate Gen2 work.
- One does not imply the other.

## If you only get x8 or x4

Do not immediately assume the software patch failed. Check:

- all 24 capacitors are present;
- no capacitor is tombstoned or shifted;
- no pad/joint is open;
- no solder bridge exists;
- the motherboard slot is actually wired for x16;
- bifurcation/slot sharing is not reducing width;
- risers/adapters are not limiting the link.

A partial or bad lane restoration can cause PCIe to negotiate down to x8/x4/x1.

## Why x16 matters for our P2P work

The x16 hardware mod and Gen2 software work give the peer path enough PCIe bandwidth for the P2P driver work documented in this repository. On our dual-card system the final CUDA P2P test reached:

```text
GPU0 -> GPU1: 6.46 GB/s
GPU1 -> GPU0: 6.69 GB/s
Bidirectional: 12.90–13.18 GB/s
GPU-to-GPU latency: 1.59–1.65 us
```

See [BENCHMARKS.md](BENCHMARKS.md) for the full before/after history.

## Credits

The physical lane-width modification was discovered and documented by the CMP 170HX community. This page combines upstream hardware information with the exact component and successful x16 result from our own two-card build. Please credit the upstream projects linked above when reproducing their work.
