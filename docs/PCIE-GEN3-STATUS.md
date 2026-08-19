# CMP 170HX PCIe Gen3 / Gen4 research status

> **Status: UNSOLVED / research only.** As of the public sources checked on 2026-08-19, we found no reproducible CMP 170HX capture with `LnkSta: Speed 8GT/s` (Gen3) or `16GT/s` (Gen4). Capability advertisement is not the same as a trained link.

This page collects the public Gen3/Gen4 work in one place so new experiments do not repeat already-disproved ideas.

Primary reference:

- <https://github.com/Consensus-Protocol/cmp170hx/blob/main/docs/frontier/pcie-gen3-gen4.md>

Also useful:

- <https://github.com/Consensus-Protocol/cmp170hx/blob/main/docs/unlock/pcie-gen2.md>
- <https://github.com/Consensus-Protocol/cmp170hx>

---

## Status at a glance

| Generation | Signalling rate | CMP 170HX status |
|---|---:|---|
| Gen1 | 2.5 GT/s | Stock |
| Gen2 | 5.0 GT/s | **Working in software** |
| Gen3 | 8.0 GT/s | **Unsolved** — advertisement has been demonstrated, actual 8 GT/s training has not |
| Gen4 | 16.0 GT/s | **Unsolved** |

PCIe **generation** and **width** are independent. The 24-capacitor hardware modification can restore x16 width, but it does not unlock Gen3. Our cards currently demonstrate Gen2 x16.

---

# What has already been achieved for Gen3

The community has managed to make the endpoint advertise a Gen3-capable state in experiments. Reported examples include a Gen3-looking `LnkCap` and a target link speed of 8 GT/s.

However, the decisive register remained at a lower trained speed:

```text
LnkSta: not 8GT/s
```

That distinction matters. A successful Gen3 unlock must show an **actual trained link**, not merely changed capability/configuration registers.

The public research archive describes an experiment where the Gen3 target was accepted while the link remained at 2.5 GT/s. Gen3 PHY equalization was also not observed completing.

---

# Why the Gen2 trick does not simply extend to Gen3

The working Gen2 unlock opens privilege masks and changes several PCIe/XP3G controls, including the effective Gen2 disable/config path, then forces a retrain from the upstream port.

A critical finding is that the Gen2 unlock succeeds **even though the attempted write to the fuse-sense register does not actually clear the fuse reflection**. The useful Gen2 levers are elsewhere in the PCIe/XP3G control path.

For Gen3 the public evidence points to an additional independent restriction.

## Known fuse fingerprint

Public research identifies these CMP 170HX values:

```text
FUSE_PCIE_GEN23_DIS  0x0082057c = 0x00000001
FUSE_PCIE_GEN3_DIS   0x00820580 = 0x00000001
FUSE_PCIE_MAGIC_D    0x00820520 = 0x16680000
```

The dedicated Gen3-disable reflection is particularly interesting. In comparison A100/other Ampere parts from the research set do not show the same disabled state.

But directly writing these fuse reflections is not a demonstrated solution. The analogous Gen23 write already fails on silicon while Gen2 still works through other controls.

### Practical conclusion

Do not assume this will unlock Gen3:

```text
write FUSE_PCIE_GEN3_DIS = 0
```

It is a useful probe, but not a proven lever.

---

# DevInit is the other important layer

The research also found PCIe-relevant differences between CMP 170HX and A100 inside the DevInit configuration data.

The public analysis identifies:

- a CMP PCIe configuration table inside the DevInit Falcon image;
- different bytes compared with A100;
- a suppress flag that skips a higher-generation PCIe programming block;
- write-only/XVE-side registers associated with the higher-speed initialization sequence.

This is why current research increasingly points beyond a simple runtime config-space write. The working hypothesis in the community archive is that a useful Gen3 route may require changing what GSP-RM/DevInit consumes or emulating the result of that initialization sequence.

That is a much harder problem than Gen2 because DevInit/GSP execution is protected and timing-sensitive.

---

# Current research avenues

These are **research directions, not instructions known to work**.

## 1. Compare A100 vs CMP PCIe initialization live

Capture the same registers on an A100 and a CMP 170HX at several points:

```text
cold boot
pre-GSP
post-DevInit
post-GSP-RM
before retrain
after retrain
```

The goal is to identify which writable/shadow state differs after A100 successfully enables Gen3/Gen4 capability.

## 2. Follow the consumer of the Gen3 fuse, not only the fuse itself

The fuse-sense register may be immutable, but some downstream logic must consume that value. The more promising target may be:

- a shadow register;
- a DevInit branch/condition;
- a GSP-RM policy decision;
- a PHY override that is programmed from the fuse result.

This is the same conceptual lesson learned from Gen2: the immutable fuse reflection was not the final operational lever.

## 3. Investigate the Gen3 equalization path

Gen3 requires equalization that Gen2 does not. A useful diagnostic build should log:

- target speed;
- supported-speed vector;
- LTSSM state;
- Gen3 equalization phase/status bits;
- PHY/XP3G rate and override state;
- AER counters before/after retrain.

If the link attempts Gen3 and falls back, that is a very different failure from never entering equalization at all.

## 4. DevInit/GSP-RM patching or in-memory substitution

The public archive's strongest closing hypothesis is that Gen3 needs a GSP-RM/DevInit-level modification.

A safer research direction is to understand or modify the relevant in-memory data before it is consumed rather than immediately flashing SPI contents. A persistent flash modification should be a last resort and requires a recovery strategy.

## 5. Re-use the known-good Gen2 instrumentation

Do not start from zero. The Gen2 patch already logs and opens much of the XP3G/XVE privilege state. Extend that instrumentation with Gen3-specific reads first, before adding writes.

---

# What counts as a real Gen3 success?

A screenshot of `LnkCap: Speed 8GT/s` is **not enough**.

A convincing report should include all of the following:

```bash
sudo lspci -vv -s <GPU_BDF> | grep -E 'LnkCap:|LnkSta:|LnkCtl2:|LnkSta2:'
```

and show:

```text
LnkSta: Speed 8GT/s
```

Then also provide:

1. repeated cold boots that still train Gen3;
2. sustained host↔GPU bandwidth consistent with the faster link;
3. GPU↔GPU P2P bandwidth if multiple cards are present;
4. AER counters/errors during a long transfer test;
5. exact motherboard/root-port topology;
6. NVIDIA driver and kernel versions;
7. the complete patch/commit used.

For a physically x16-modified card, a successful Gen3 x16 result would be especially valuable, but do not infer Gen3 from bandwidth alone — record `LnkSta` explicitly.

---

# Safety

Researching this area can involve low-level PCIe state, GSP/DevInit, and potentially flash contents.

Recommended rules:

- keep a known-good driver/kernel entry in GRUB;
- make exact backups before modifying anything persistent;
- prefer runtime/in-memory experiments before SPI flashing;
- change one register family at a time;
- capture AER and dmesg continuously;
- never call a capability-advertisement experiment a Gen3 unlock unless `LnkSta` actually trains to 8 GT/s.

---

# Research status as of 2026-08-19

We searched the current public GitHub/web material again on 2026-08-19. We found active documentation and detailed Gen3 investigation, but **no newer public reproducible result proving a CMP 170HX trained at PCIe Gen3**.

So the useful news is:

- there **are** substantial Gen3 reverse-engineering notes;
- the suspected lock layers are much better understood than before;
- capability advertisement has been reached;
- **the actual 8 GT/s link remains an open problem in the public record we found**.

If someone has a newer branch, log or screenshot with `LnkSta: Speed 8GT/s`, please open an issue in this repository. That is exactly the evidence we want to preserve and reproduce.
