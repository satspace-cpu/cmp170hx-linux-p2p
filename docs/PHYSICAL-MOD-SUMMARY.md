# CMP 170HX physical PCIe x4 → x16 modification

This page summarizes the hardware modification used on our two cards. For the detailed procedure, see [PCIE-X16-HARDWARE-MOD.md](PCIE-X16-HARDWARE-MOD.md) and [the Russian version](PCIE-X16-HARDWARE-MOD.ru.md).

## What is changed

The stock CMP 170HX leaves the AC-coupling capacitors for PCIe lanes 4–15 unpopulated. Restoring those missing parts allows the link to negotiate x16 width when the host slot/root port also provides x16 lanes.

## Parts

- **24 × 0402 capacitors**
- **0.22 µF / 220 nF**
- **X7R**
- **16 V** used successfully on our cards
- confirmed part: **Samsung CL05B224KO5NNNC**

The exact part we used:

https://www.chipdip.ru/product/0.22mkf-x7r-16v-10-0402-cl05b224ko5nnnc-kondensator-samsung-9000681245

Why 24 parts:

```text
12 missing PCIe lanes × 2 AC-coupling capacitors per lane = 24 capacitors
```

## Where they go

Populate the 24 empty 0402 capacitor footprints in the PCIe differential lane routing between the gold edge connector and the GPU for lanes 4–15. On the A100-derived reference design, the relevant capacitor designators are roughly in the **C1100–C1350** range on the `IO: PCIe CONNECTOR` section.

Do not solder by C-number alone; board revisions exist. Cross-check every footprint against a known-good reference/photo.

Upstream references:

- https://github.com/amoghmunikote/170th-Street/blob/master/modifications/pcie-capacitor-mod.md
- https://github.com/Consensus-Protocol/cmp170hx/blob/main/docs/hardware/board-and-variants.md

## Soldering recommendations

- work under microscope/strong magnification;
- use fine ESD tweezers and a fine temperature-controlled iron;
- use good gel flux;
- refresh/wick the factory lead-free solder if needed;
- use very short dwell time on each pad;
- inspect for bridges, tombstoning, shifted components and lifted pads;
- clean with IPA and inspect again before power-on.

A controlled bottom preheater can help on the large multilayer PCB, but it is **not mandatory**. Our two cards were successfully soldered without preheating. Avoid uncontrolled whole-board heating because PCB warping and internal-layer damage are much worse than a difficult 0402 joint.

The capacitors are ceramic and **non-polarized**.

## Verification

After reassembly:

```bash
nvidia-smi --query-gpu=index,pci.bus_id --format=csv
sudo lspci -vv -s <GPU_BDF> | grep -E 'LnkCap:|LnkSta:'
```

A successful full hardware modification should show:

```text
Width x16
```

On our cards, after the separate Gen2 software work:

```text
LnkSta: Speed 5GT/s, Width x16
```

Remember:

- **Width x16** = hardware capacitor modification succeeded.
- **Speed 5GT/s** = separate Gen2 software modification succeeded.

## Photo note

We still want to add a high-resolution annotated photo with all 24 locations marked individually. Once a clean photo of our known-working card is available, it should be added to the detailed hardware-mod pages and linked from here.
