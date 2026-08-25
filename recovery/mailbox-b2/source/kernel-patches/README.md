# Kernel patches

Two patches against the host kernel. They are **not** required for the memory /
SM / PCIe Gen2 unlock — that all works on a stock kernel. They exist to make
**BAR1 P2P** usable, and to make the large BAR1 come up on a normal boot instead
of needing a `kexec` trick.

Built and tested against `linux-source-7.0.0` (Ubuntu 26.04, release
`7.0.12-cmp`) on a Supermicro SYS-4028GR-TRT2. Originally brought up with four
CMP 170HX behind a single PLX switch, since scaled to **eight** across two
switches on the same CPU root complex — neither patch needed changing.

## 0001 — `pbus_size_mem()`: size bridge windows for child alignment padding

`pbus_size_mem()` accumulates a bridge window's size with

```c
size += max(r_size, align);
```

which is correct only when a child's size is a multiple of its alignment. Every
child has to *start* at an aligned address, so a child whose size is not a
multiple of its alignment leaves a gap before the next one, and that gap is never
budgeted. The window then comes out too small to place all the children even
though the arithmetic says it fits.

With four GPUs each needing a 64GB BAR1 (64GB alignment) plus a 32MB BAR3, each
downstream port window is 64GB+32MB and must begin on a 64GB boundary, so it
really occupies 128GB:

```
before:  root port window 256GB + 128MB   (exactly the sum of the children)
         BAR1 @ 0x21000000000, 0x23000000000   (128GB apart)
         two GPUs got no BAR1 at all, silently

after:   root port window 512GB
         BAR1 @ 0x20000000000 / 0x22000000000 / 0x24000000000 / 0x26000000000
```

With eight GPUs the same arithmetic repeats per root port — 512GB behind each of
the two switches, 1TB of prefetchable space in total:

```
00:02.0  BAR1 @ 0x20000000000 0x22000000000 0x24000000000 0x26000000000
00:03.0  BAR1 @ 0x28000000000 0x2a000000000 0x2c000000000 0x2e000000000
```

That needs `pci=hpmmioprefsize=2T` and a BIOS MMIO-high window to match. The
failure mode without patch 0001 is silent — enumeration reports success and some
GPUs simply have no Region 1 — so check all of them, not just the first:

```bash
for d in $(lspci -D -d 10de: -n | awk '{print $1}'); do
    echo "$d $(sudo lspci -vv -s $d | grep -c 'Region 1')"
done
```

`ALIGN(r_size, align)` budgets the padding. It is identical to `max()` whenever
`r_size <= align`, which covers every ordinary device BAR (size == alignment), so
only the mis-sized bridge windows change.

This is a generic bug, not a CMP one — it just needs unusually large,
unusually aligned BARs to become visible.

## 0002 — `pci_fixup_early` quirk: program BAR1 REBAR to 64GB before enumeration

The card ships with BAR1 fused to 64MB. Two CYA registers unlock the Resizable
BAR capability to advertise up to 64GB, but doing that from the driver at probe
time is too late: enumeration has already sized every bridge window for a 64MB
BAR1, so `pci_resize_resource()` has nowhere to put the larger BAR and steps back
down.

`pci_fixup_early` runs in `pci_setup_device()` **before** `pci_read_bases()`, so
doing the unlock there makes enumeration see a 64GB BAR1 directly. Two details
matter:

- `dev->resource[]` is not populated that early, so BAR0 is read straight from
  config space.
- Memory decode is not necessarily enabled yet. With it off, every MMIO read
  returns `0xffffffff` and every write is silently discarded — the quirk appears
  to succeed while doing nothing. It is enabled for the duration and restored
  afterwards, and all-ones is treated as "window not responding", leaving the BAR
  at its stock size rather than programming it blind.

Needs 0001 as well, or the parent window is under-sized and only some GPUs get a
BAR.

## Building

```bash
sudo apt install linux-source-7.0.0 bison flex libssl-dev libelf-dev dwarves gawk
tar -xf /usr/src/linux-source-7.0.0/linux-source-7.0.0.tar.bz2 -C ~/
cd ~/linux-source-7.0.0
patch -p1 < /path/to/kernel-patches/0001-*.patch
patch -p1 < /path/to/kernel-patches/0002-*.patch

cp /boot/config-"$(uname -r)" .config
scripts/config --set-str LOCALVERSION "-cmp"      # installs alongside the stock kernel
scripts/config --disable LOCALVERSION_AUTO
scripts/config --disable MODULE_SIG_ALL
scripts/config --set-str SYSTEM_TRUSTED_KEYS ""
scripts/config --set-str SYSTEM_REVOCATION_KEYS ""
scripts/config --disable DEBUG_INFO
scripts/config --enable  DEBUG_INFO_NONE
make olddefconfig
make -j"$(nproc)"

sudo make modules_install
sudo cp arch/x86/boot/bzImage /boot/vmlinuz-"$(make -s kernelrelease)"
sudo update-initramfs -c -k "$(make -s kernelrelease)"
sudo update-grub
```

`LOCALVERSION=-cmp` keeps the stock kernel installed and in the GRUB menu, which
is worth doing — if the patched kernel misbehaves you pick the stock entry and
you are back to a working machine with 64MB BARs and no P2P.

`make bindeb-pkg` does not work here: the generated `debian/control` wants
`debhelper-compat (= 12)` and current releases ship debhelper 13.

**Pin your kernel packages afterwards.** A distro kernel upgrade arrives without
these patches and silently drops both P2P and the large BARs:

```bash
sudo apt-mark hold linux-image-generic-hwe-26.04 linux-headers-generic-hwe-26.04 \
                   linux-image-"$(uname -r)" linux-headers-"$(uname -r)"
```

## Verifying

```bash
sudo dmesg | grep 'CMP 170HX'
#  CMP 170HX: BAR1 REBAR programmed to 64GB before enumeration (cap 0x1ffc00 ctrl 0x1001)
#  cap/ctrl of 0xffffffff means the register window was not reachable

sudo lspci -vv -s 0c:00.0 | grep 'Region 1'
#  Region 1: Memory at ... [size=64G]
```
