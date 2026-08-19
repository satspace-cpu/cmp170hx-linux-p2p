---
name: P2P reproduction report
about: Report working or broken CMP 170HX P2P results
title: "[Reproduction] "
labels: ""
assignees: ""
---

## Hardware

- CMP 170HX count:
- VRAM reported per GPU:
- Motherboard/platform:
- CPU:
- PCIe topology:

## Software

- Linux distribution:
- Kernel:
- NVIDIA driver/KMD:
- CUDA:
- Patch/source version:

## IOMMU / ACS

- IOMMU enabled or disabled:
- Kernel command line:
- ACS changes, if any:

## PCIe link state

Paste `LnkCap` / `LnkSta` for each GPU.

```text

```

## P2P topology

Paste:

```bash
nvidia-smi topo -p2p r
nvidia-smi topo -p2p w
nvidia-smi topo -p2p p
```

```text

```

## p2pBandwidthLatencyTest

Paste the complete output, including P2P-disabled and P2P-enabled matrices.

```text

```

## Notes

Anything unusual about the system, driver build, or observed application behavior.
