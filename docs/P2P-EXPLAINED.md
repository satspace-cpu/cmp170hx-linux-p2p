# How the CMP 170HX P2P fix works

This document explains the failure mode observed on the tested dual-CMP 170HX system and why the final configuration restored normal PCIe peer bandwidth.

## Symptom 1: peer access reported as available, but bandwidth was broken

CUDA reported:

```text
Device=0 CAN Access Peer Device=1
Device=1 CAN Access Peer Device=0
```

and `nvidia-smi topo -p2p` reported `OK`, yet enabling P2P produced only about 0.29 GB/s per direction.

This is the first important lesson: **P2P capability reporting is not the same thing as a healthy P2P data path.**

## Symptom 2: invalid mailbox address

Debug instrumentation was added around `kbusSetupMailboxAccess_GM200()`.

The broken driver printed:

```text
mailbox=0xffffffffffffffff
baseMask=0xfff
```

`0xffffffffffffffff` is the driver's invalid mailbox address value. That caused the mailbox physical base calculation to effectively become `fbPhys - 1`, which then failed the page-alignment assertion in `kbusSetupPeerBarAccess_IMPL()`.

The resulting assertion was:

```text
Assertion failed: ((base & RM_PAGE_MASK) == 0)
```

## Why the mailbox was never allocated

The P2P modification being tested forced:

```c
pKernelBif->pcieP2PType = NV_REG_STR_RM_PCIEP2P_TYPE_BAR1;
```

On the GA100/CMP path, this prevented the normal PCIe mailbox setup from being used while later code still entered the GM200/GA100 mailbox programming path.

The working change was:

```c
pKernelBif->pcieP2PType = NV_REG_STR_RM_PCIEP2P_TYPE_DEFAULT;
```

After that change, debug output became:

```text
mailbox=0x0
baseMask=0x0
```

The alignment assertion disappeared and P2P bandwidth improved from ~0.29 GB/s to ~0.47–0.49 GB/s.

That was progress, but still far below the available PCIe bandwidth.

## Symptom 3: IOMMU was still throttling the P2P path

The system still had active IOMMU groups even though the driver-side mailbox path was now healthy.

With IOMMU active, measured P2P bandwidth remained approximately:

```text
GPU0 -> GPU1: 0.47 GB/s
GPU1 -> GPU0: 0.49 GB/s
Bidirectional: ~0.89 GB/s
```

After adding:

```text
intel_iommu=off iommu=off
```

to the kernel command line and rebooting, the same CUDA test produced:

```text
GPU0 -> GPU1: 6.46 GB/s
GPU1 -> GPU0: 6.69 GB/s
Bidirectional: 12.90–13.18 GB/s
GPU latency: ~1.59–1.65 us
```

## Final working path

The tested system's successful sequence is therefore:

```text
P2P capability unlock
    -> normal GA100/CMP PCIe mailbox path
    -> valid BAR1 mailbox allocation
    -> IOMMU disabled on bare metal
    -> direct PCIe P2P bandwidth restored
```

## ACS note

The test system also disabled ACS redirect on the two GPU root ports. ACS can force peer traffic upstream rather than allowing the shortest peer path.

The exact PCI BDFs are system-specific. Determine your own topology before changing ACS behavior.

## Why the final bandwidth numbers make sense

Each CMP 170HX was linked at PCIe Gen2 x16:

```text
Speed 5GT/s, Width x16
```

A practical ~6.5–6.7 GB/s one-way peer bandwidth is consistent with a healthy Gen2 x16 link after protocol overhead. Roughly 13 GB/s bidirectional aggregate traffic is likewise plausible when both directions are active simultaneously.

## What this fix does not prove

This result does not yet prove that every CMP 170HX, motherboard or driver version will behave identically. It has been validated on one dual-GPU system.

Please report reproductions with:

- GPU count and model
- driver version
- kernel version
- CUDA version
- `lspci -vv` link status
- IOMMU state
- `nvidia-smi topo -p2p` output
- full `p2pBandwidthLatencyTest` output
