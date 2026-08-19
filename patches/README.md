# Patches

## `p2p-cmp170-mailbox-fix.patch`

This is the CMP 170HX-specific fix discovered during testing of NVIDIA Open GPU Kernel Modules 610.43.03.

It changes:

```c
pKernelBif->pcieP2PType = NV_REG_STR_RM_PCIEP2P_TYPE_BAR1;
```

to:

```c
pKernelBif->pcieP2PType = NV_REG_STR_RM_PCIEP2P_TYPE_DEFAULT;
```

On the tested GA100-based CMP 170HX system, forcing BAR1 caused the normal PCIe mailbox setup to be skipped while the GM200/GA100 mailbox path was still used later. The resulting write-mailbox address stayed invalid (`0xffffffffffffffff`).

After this patch, the mailbox was allocated correctly and the page-alignment assertion disappeared.

## Apply

From the root of the matching NVIDIA open kernel module source tree:

```bash
patch -p1 < /path/to/p2p-cmp170-mailbox-fix.patch
```

## Tested order

In the tested CMP unlock tree, the relevant tail of the patch order was:

```text
pcie-gen2.patch
pcie-gen2-probe-retrain.patch
pcie-gen2-early-watcher.patch
p2p-bar1-610.patch
p2p-cmp170-mailbox-fix.patch
name-string.patch
```

The mailbox fix is intentionally applied **after** the broader P2P patch because that P2P patch is what forces BAR1 mode.

## Debug patch

A temporary local debug patch was used during development to print mailbox, base address and alignment values. It is not required for normal operation and is intentionally not included as a required production patch.

## Compatibility

Validated with NVIDIA 610.43.03 only. Patch offsets or surrounding code may differ in other releases. Always dry-run against a clean source tree first:

```bash
patch --dry-run -p1 < p2p-cmp170-mailbox-fix.patch
```
