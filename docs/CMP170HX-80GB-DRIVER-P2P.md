# CMP 170HX 80 GiB: NVIDIA 610.57.04 driver, P2P and HBM sensors

> 🇷🇺 **Buy modified CMP 170HX cards in Russia:** [Avito listing](https://www.avito.ru/voronezh/tovary_dlya_kompyutera/nvidia_cmp170_hx_x16_anlok_80_gb_110_sm_gen4_8492880790)
>
> 🛠️ **CMP 170HX modification service in Russia:** [Avito service listing](https://www.avito.ru/voronezh/nastolnye_kompyutery/nvidia_cmp_170hx_anlok_80_gig_gen4_sm_do_128_8437550194)

[Русская версия](CMP170HX-80GB-DRIVER-P2P.ru.md)

This guide documents a configuration **verified on a real server** for CMP 170HX `10de:20c2` cards hardware-unlocked with GA100VFI to 80 GiB. It is not intended for ordinary 8 GiB cards software-unlocked to 64 GiB.

The design deliberately separates responsibilities:

- A dedicated NVIDIA Open Kernel Modules `610.57.04` build owns the 80 GiB geometry and CUDA operation.
- A minimal companion module based on `gpu-unlock 3.0.0-beta` enables P2P permissions and exports HBM temperatures, but **does not change memory geometry, BAR1, PCIe policy, ECC, InfoROM or clocks**.

> Do not install the standard `8gb` profile over a hardware-unlocked 80 GiB card: the public cmpunlocker profile targets 64 GiB. Do not enable Static BAR1 for this setup either. A 64 GiB BAR1 combined with an 80 GiB framebuffer caused the driver and `nvidia-smi` to hang on our host.

## Verified result

Tested host:

- Ubuntu, kernel `7.0.0-42-generic`;
- NVIDIA Open Kernel Modules `610.57.04`;
- 2× hardware-unlocked CMP 170HX `10de:20c2`, each reporting `81920 MiB`;
- PCIe Gen2 x16;
- bidirectional P2P;
- HBM stack sensors A–E and `Hottest`;
- no new NVIDIA Xid or PCIe AER after testing.

Measured P2P result:

```text
nvidia-smi topo -p2p r/w: OK both ways
cudaMemcpyPeer:           PASS both ways
SM remote read:           PASS both ways
SM remote write:          PASS both ways
One-way bandwidth:        5.28–5.30 GB/s
Bidirectional bandwidth:  10.27 GB/s
GPU latency:              1.80–1.81 us
```

## 1. Prerequisites and backup

You need a hardware-unlocked card, KVM or physical recovery access, Secure Boot disabled, matching kernel headers, and the NVIDIA `610.57.04` userspace stack already installed.

Back up all five NVIDIA modules, initramfs and configuration before changing anything:

```bash
KVER="$(uname -r)"
BACKUP="$HOME/cmp170-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP/modules" "$BACKUP/config"

for m in nvidia nvidia-modeset nvidia-drm nvidia-uvm nvidia-peermem; do
    p="$(modinfo -n "$m" 2>/dev/null || true)"
    [ -n "$p" ] && cp -a "$p" "$BACKUP/modules/"
done

cp -a /etc/default/grub "$BACKUP/config/" 2>/dev/null || true
cp -a /etc/modprobe.d "$BACKUP/config/" 2>/dev/null || true
cp -a "/boot/initrd.img-$KVER" "$BACKUP/" 2>/dev/null || true
uname -a > "$BACKUP/uname.txt"
nvidia-smi -q > "$BACKUP/nvidia-smi-q.txt"
lspci -nnvv > "$BACKUP/lspci-nnvv.txt"
```

## 2. How `20c2-hw80` differs from the standard `8gb` profile

Our hardware-unlocked `20c2` profile uses:

```text
FBPA CFG1:       0x02779000
MMU/LMR:         0x0000028B
GSP FB length:   0x0000001400000000  (80 GiB)
PCI device ID:   10de:20c2
```

The standard 64 GiB `20c2/8gb` profile uses LMR `0x0000020B` and FB length `0x0000001000000000`. CFG1 remains unchanged because the hardware unlock changes the accessible total, not the size of one FBPA.

A separate profile must keep all of these consistent:

1. CFG1/LMR programmed through SEC2/GSP;
2. `GspStaticConfigInfo.fb_length` and the final FB region;
3. WPR/GSP reserved regions;
4. heap and PMA ranges;
5. absence of 32-bit overflow and overlapping ranges;
6. removal of Static BAR1 and other 64 GiB assumptions.

Changing only the number displayed by `nvidia-smi` is not a memory unlock.

## 3. Build the main 610.57.04 driver

Use a separate cmpunlocker source tree so the working 64 GiB profile remains untouched. The verified tree provided dedicated `20c2-hw80`, `local-only`, `preserve` and build-only policies:

```bash
cd /path/to/cmpunlocker-61057-20c2-hw80

sudo env \
  CMPUNLOCKER_CARD_PROFILE=20c2-hw80 \
  CMPUNLOCKER_IO_POLICY=local-only \
  CMPUNLOCKER_PCIE_POLICY=preserve \
  CMPUNLOCKER_DRIVER_VERSION=610.57.04 \
  CMPUNLOCKER_BUILD_ONLY=1 \
  ./driver/build.sh
```

These extra profiles and variables belong to the prepared `20c2-hw80` tree;
they may not exist in stock upstream cmpunlocker. Check with
`grep -R "20c2-hw80\|CMPUNLOCKER_IO_POLICY" driver common` before building. If
there is no match, do not substitute the `8gb` profile: that restores 64 GiB
assumptions.

`local-only` keeps Static BAR1 and separate P2P patches out of the main NVIDIA module. `preserve` keeps PCIe experiments out of the first 80 GiB boot.

Verify that all five modules were built:

```bash
find driver -type f \( \
  -name 'nvidia.ko' -o -name 'nvidia-modeset.ko' -o \
  -name 'nvidia-drm.ko' -o -name 'nvidia-uvm.ko' -o \
  -name 'nvidia-peermem.ko' \) -print
```

Install them under `/lib/modules/$(uname -r)/updates/cmpunlocker/`, then run:

```bash
sudo depmod -a
sudo update-initramfs -u -k "$(uname -r)"
sudo reboot
```

If the host actually generates initramfs with dracut, also run:

```bash
sudo dracut --force --kver "$(uname -r)"
```

Verify after boot:

```bash
modinfo -n nvidia
modinfo -F version nvidia
nvidia-smi --query-gpu=pci.bus_id,name,memory.total,uuid,serial --format=csv
dmesg -T | grep -iE 'SEC2_DEBUG|NVRM|Xid|AER' | tail -200
```

`81920 MiB` is expected, but it is only the first check.

## 4. Mandatory 80 GiB validation

Before enabling P2P, test one card in isolation:

1. allocate CUDA memory beyond 64 GiB;
2. write different patterns below and above the 40/64/72/79 GiB boundaries;
3. read back and compare;
4. check for aliasing — writing a high address must not change a low address;
5. perform a full-range HBM read/write test;
6. check for Xid/AER after the test.

If the card merely reports `81920 MiB` but the upper range aliases, corrupts data or cannot be allocated, the profile is not working.

## 5. P2P without Static BAR1

The 80 GiB P2P companion is based on `gpu-unlock 3.0.0-beta` at exact upstream commit `50c30a31f92f37d590bc0047c841cb42c22654c4` and this minimal patch:

- [`gpu-unlock-3.0.0-beta-20c2-hw80-p2p.patch`](../patches/gpu-unlock-3.0.0-beta-20c2-hw80-p2p.patch)

The patch creates a separate `GA100 CMP 170HX hw80 P2P companion` family. For `20c2`, it opens only the protected permissions required for P2P. It intentionally omits the stock 64 GiB `cmp170hx_8gb_geometry`, BAR1 resize, PCIe relink, ECC and ROM overrides.

Build it as follows:

```bash
git clone --branch 3.0.0-beta https://github.com/Zagitta/gpu-unlock.git
cd gpu-unlock
git checkout 50c30a31f92f37d590bc0047c841cb42c22654c4
git apply --check --unidiff-zero /path/to/cmp170hx-linux-p2p/patches/gpu-unlock-3.0.0-beta-20c2-hw80-p2p.patch
git apply --unidiff-zero /path/to/cmp170hx-linux-p2p/patches/gpu-unlock-3.0.0-beta-20c2-hw80-p2p.patch

make assets
make -C kernel/gpu_unlock -j"$(nproc)"
```

Upstream gpu-unlock uses the `610.43.03` package only as the source of signed
firmware assets for its companion module. The primary NVIDIA driver on the
verified host remained `610.57.04`.

Install firmware, overrides and the integration for the initramfs generator actually used by the host. Our verified server used dracut:

```bash
sudo make ASSETS="$HOME/.cache/gpu-unlock/assets" \
  install-firmware install-overrides install-dracut

sudo install -D -m 0644 kernel/gpu_unlock/gpu_unlock.ko \
  "/lib/modules/$(uname -r)/updates/gpu-unlock-monitor/gpu_unlock.ko"
sudo depmod -a
```

Use `install-initramfs-tools` instead of `install-dracut` on an initramfs-tools host.

## 6. Boot parameters and target selection

Find each card's PCI address:

```bash
nvidia-smi --query-gpu=pci.bus_id,uuid,serial --format=csv
```

Append the following to the existing `GRUB_CMDLINE_LINUX_DEFAULT` value:

```text
gpu_unlock.targets=0000:81:00.0,0000:82:00.0 gpu_unlock.hbm_governor=0 gpu_unlock.resume=0
```

Replace the BDFs with your own. Moving a card to another slot requires updating this target list.

`hbm_governor=0` leaves HBM clock control to `170tune`. `resume=0` disables the unverified re-unlock-after-suspend path. Temperature sensors remain available.

Apply the boot configuration:

```bash
sudo update-grub
sudo update-initramfs -u -k "$(uname -r)"
# If dracut generates the initramfs:
sudo dracut --force --kver "$(uname -r)"
sudo reboot
```

Do not add:

```text
RMForceStaticBar1=1;RMPcieP2PType=1
```

Those keys belong to the separate verified [64 GiB Static BAR1](STATIC-BAR1-P2P.md) configuration, not the 80 GiB profile.

## 7. Verify P2P and HBM temperatures

Check that the companion ran early enough:

```bash
cat /proc/cmdline
lsmod | grep gpu_unlock
dmesg -T | grep -i gpu_unlock
```

Then inspect P2P capability:

```bash
nvidia-smi topo -m
nvidia-smi topo -p2p r
nvidia-smi topo -p2p w
```

`OK` is necessary but not sufficient. Run a content test that validates `cudaMemcpyPeer`, SM remote read and SM remote write in both directions. Only after those checks pass should `p2pBandwidthLatencyTest` be treated as meaningful.

Check the kernel log after the test:

```bash
dmesg -T | grep -iE 'NVRM|Xid|AER|pcie.*error' | tail -200
```

Install the included HBM sensor helper:

```bash
sudo install -m 0755 scripts/cmp-hbm-temp.sh /usr/local/bin/cmp-hbm-temp
cmp-hbm-temp
```

`Hottest` is the maximum of the real HBM stack sensors, not a separate physical sensor.

## 8. Rollback

If `nvidia-smi` hangs, an Xid appears, or the upper memory aliases/corrupts data:

1. boot through KVM or recovery;
2. remove `gpu_unlock.targets=...` from the kernel command line;
3. restore the five saved NVIDIA modules;
4. remove or replace `gpu_unlock.ko`;
5. run `depmod`, rebuild GRUB/initramfs and reboot.

Do not respond to a hang by adding more register writes, Static BAR1, VBIOS flashing or InfoROM changes.

## Important limits

- This was verified on specific hardware-unlocked `10de:20c2` cards. It does not turn a normal 64 GiB card into an 80 GiB card.
- P2P depends on PCIe topology, root complex, ACS and IOMMU. Validate every directed pair.
- The secure permission path in `gpu-unlock 3.0` is not the historical Mailbox B2 path from this repository. The old path produced a false-positive benchmark; the new path passed content validation.
- Do not enable ECC/InfoROM merely to obtain P2P.
- Both out-of-tree modules must be rebuilt after a kernel update.
- `gpu-unlock 3.0.0-beta` is beta software. Pin the exact commit and preserve a working rollback.

## Sources

- [cmpunlocker](https://github.com/amoghmunikote/cmpunlocker)
- [gpu-unlock 3.0.0-beta](https://github.com/Zagitta/gpu-unlock/tree/3.0.0-beta)
- [Verified Static BAR1 for 64 GiB](STATIC-BAR1-P2P.md)
- [HBM page diagnosis and retirement](HBM-PAGE-RETIREMENT.md)
