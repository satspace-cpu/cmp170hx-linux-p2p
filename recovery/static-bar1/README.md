# Static BAR1 recovery source and build mode

[Русская версия](README.ru.md) · [Verified result](../../docs/STATIC-BAR1-P2P.md)

This directory preserves the reproducible **Static BAR1** mode. It is separate
from `../mailbox-b2/`, which is historical only and must not be used as a P2P
transport.

## Source provenance

| Component | Exact source |
|---|---|
| Static BAR1 design and patch series | [bayley/cmpunlocker commit `2a1a46389c36c2bf8a2d451855bdf34d5b4e616b`](https://github.com/bayley/cmpunlocker/commit/2a1a46389c36c2bf8a2d451855bdf34d5b4e616b) |
| Upstream driver sources | [NVIDIA Open GPU Kernel Modules `610.57.04`](https://github.com/NVIDIA/open-gpu-kernel-modules/tree/610.57.04) |
| Preserved CMP unlock source, hooks and all patch files | [`../mailbox-b2/source/`](../mailbox-b2/source/) |
| Static BAR1 test evidence | [`../../docs/STATIC-BAR1-P2P.md`](../../docs/STATIC-BAR1-P2P.md) |

NVIDIA's full Open GPU Kernel Module tree is fetched from its official tag at
build time; this repository deliberately does not mirror NVIDIA's multi-gigabyte
upstream tarball. The complete local CMP unlock source is preserved under the
path above, including `src/cmpunlock.c`, `src/cmpunlock.h`, `build.sh`, the
BAR1 patches and kernel patches.

## Static BAR1 mode

The mode is defined by all of these conditions:

```text
CMPUNLOCKER_ENABLE_P2P=1
apply: 0011-p2p-bar1.patch
apply: 0013-skip-mailbox-peer-preinit.patch
apply: 0015-bar1p2p-readcap-override.patch
do not apply: 0012-mailbox-default.patch
module options: RMForceStaticBar1=1;RMPcieP2PType=1
```

`0012-mailbox-default.patch` is deliberately excluded because it changes
`pcieP2PType` back to NVIDIA's default/mailbox protocol and defeats the Static
BAR1 selection made by `0011`.

## Build only

The wrapper makes a private copy of the preserved source, removes only the
mailbox-selection patch, adds the known 610.57.04 version entry, and invokes
the source's normal build script. It does not install modules or reboot the
machine.

```bash
git clone https://github.com/satspace-cpu/cmp170hx-linux-p2p.git
cd cmp170hx-linux-p2p

sudo env \
  CMPUNLOCKER_DRIVER_VERSION=610.57.04 \
  CMPUNLOCKER_KVER="$(uname -r)" \
  ./recovery/static-bar1/build-static-bar1.sh
```

The output tree is printed at the end. Confirm its `vermagic` before
installation:

```bash
modinfo recovery/static-bar1/work/.build/open-gpu-kernel-modules-610.57.04/kernel-open/nvidia.ko \
  | grep -E 'version|vermagic'
```

## Module configuration

Install `modprobe-static-bar1.conf` as the one authoritative `options nvidia`
file for this setup. Preserve the host's existing Gen2 settings when merging
the `NVreg_RegistryDwords` string; do not create competing definitions.

```bash
sudo install -m 0644 recovery/static-bar1/modprobe-static-bar1.conf \
  /etc/modprobe.d/cmp-static-bar1.conf
```

The included `RMPcieLinkSpeed=0x5` / `NVreg_EnablePCIeGen3=1` are only from the
validated host's Gen2 unlock. Remove them if your host uses another proven
link configuration.

## Installation and verification

1. Back up all five current `nvidia*.ko` modules, the initramfs and existing
   module configuration.
2. Copy the five modules from the build output to the active module directory.
3. Run `depmod -a` and rebuild initramfs.
4. Reboot.
5. Restrict testing to a known target pair, for example:

   ```bash
   CUDA_VISIBLE_DEVICES=1,2 ./p2pBandwidthLatencyTest
   ```

6. Require a content check as well as the CUDA sample. The canonical expected
   results and raw logs are in the linked verified-result document.

Never promote a P2P pair to production from `nvidia-smi topo` alone.
