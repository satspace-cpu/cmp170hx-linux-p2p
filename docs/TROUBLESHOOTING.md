# Troubleshooting

Use this page when CUDA reports peer access but performance is poor, or when the patched driver does not behave as expected.

## 1. CUDA says peer access is available, but P2P is slower than non-P2P

Typical broken result:

```text
P2P Disabled: ~5.9 GB/s
P2P Enabled:  ~0.3–0.5 GB/s
```

Check the following in order.

### Confirm the mailbox fix is present

The source should contain:

```c
pKernelBif->pcieP2PType = NV_REG_STR_RM_PCIEP2P_TYPE_DEFAULT;
```

not a forced BAR1 default.

### Check IOMMU

```bash
cat /proc/cmdline
find /sys/kernel/iommu_groups -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head
```

On the tested bare-metal system, healthy P2P required:

```text
intel_iommu=off iommu=off
```

and no active IOMMU groups.

## 2. `nvidia-smi topo -p2p` shows GNS, NS, TNS or DR

Run:

```bash
nvidia-smi topo -p2p r
nvidia-smi topo -p2p w
nvidia-smi topo -p2p p
```

Common meanings:

- `GNS`: GPU not supported by the current driver path
- `TNS`: topology not supported
- `NS`: not supported
- `DR`: disabled by registry/driver setting
- `OK`: capability path available

`OK` is necessary but not sufficient. Run the bandwidth test afterwards.

## 3. PCIe link is not x16 or is running at the wrong speed

```bash
sudo lspci -vv -s <GPU_BDF> | grep -E 'LnkCap:|LnkSta:'
```

Tested CMP 170HX result:

```text
LnkCap: Speed 5GT/s, Width x16
LnkSta: Speed 5GT/s, Width x16
```

If `LnkSta` shows a narrower width, fix the hardware/link issue before judging P2P performance.

## 4. ACS redirects are still active

Find the root port above each GPU with `lspci -t`, then inspect ACS:

```bash
sudo lspci -vv -s <ROOT_PORT_BDF> | grep -E 'ACSCap|ACSCtl'
```

On the tested system, both GPU root ports were configured so request/completion redirects were not active.

The exact ports are motherboard-specific.

## 5. Assertion around `base & RM_PAGE_MASK`

A broken mailbox path may produce:

```text
Assertion failed: ((base & RM_PAGE_MASK) == 0)
```

If you add the optional debug instrumentation and see:

```text
mailbox=0xffffffffffffffff
baseMask=0xfff
```

then the mailbox was not allocated correctly.

After the mailbox fix, the tested system reported:

```text
mailbox=0x0
baseMask=0x0
```

## 6. Driver module loads, but memory unlock is lost

This repository only contains the P2P-specific fix. If you use a larger CMP unlock project, make sure the P2P patch is applied on top of the same source tree and build process that provides your memory unlock.

Do not replace a working unlock driver with a plain upstream NVIDIA build by accident.

## 7. Module version or kernel mismatch

Check:

```bash
uname -r
modinfo kernel-open/nvidia.ko | grep -E '^(version|vermagic):'
```

The module `vermagic` must match the running kernel.

## 8. Secure Boot blocks the module

If `modprobe nvidia` fails after rebuilding a custom module, inspect:

```bash
sudo dmesg | tail -100
```

Secure Boot may require signing the custom module or disabling Secure Boot, depending on the distribution and system policy.

## 9. P2P works synthetically but an LLM workload does not speed up

That can be normal. `p2pBandwidthLatencyTest` measures transport capability; application speed depends on:

- tensor split strategy
- model architecture
- batch size
- context size
- synchronization frequency
- kernel scheduling
- how much data actually crosses GPUs

First validate transport with the CUDA sample, then benchmark the exact same model/settings before and after.

## 10. What to include in a GitHub issue

Please include:

```bash
uname -a
cat /proc/cmdline
nvidia-smi
nvidia-smi topo -m
nvidia-smi topo -p2p r
nvidia-smi topo -p2p w
nvidia-smi topo -p2p p
lspci -t
```

Also include the full `p2pBandwidthLatencyTest` output and the `LnkCap/LnkSta` lines for each GPU.
