# Installation

## Requirements

- NVIDIA CMP 170HX (8GB or 10GB)
- Linux (x86-64 or aarch64)
- Kernel headers matching the running kernel (linux-headers-$(uname -r) / kernel-devel)
- **nvidia-open 610.43.0x already installed** (libs + firmware)
- Root access (sudo privileges)
- Secure Boot disabled
- Network access on first install (downloads matching stock open-gpu-kernel-modules sources)

## Install

```bash
sudo ./install.sh
```

To set the HBM memory clock (multiplier x 27 MHz, any VBIOS, both card variants):

```bash
sudo ./install.sh --mclk-ndiv=70   # 1890 MHz
```

See the README for the full NDIV table and the recovery path if a value turns out unstable.

Then perform a cold reboot (full power off, then boot).

## Verify

After reboot, run the built-in benchmark:

```bash
./benchmark/nvidia_bench
```

This measures memory bandwidth, tensor core throughput, PCIe speed and reports hardware features. An unlocked 8GB card should show ~64 GiB total memory; a 10GB card should show ~40 GiB.

A pre-built x86-64 binary is included. On aarch64, see the README for the build command.

## Uninstall

```bash
sudo ./remove.sh --yes
```

Then perform a cold reboot (full power off, then boot).
