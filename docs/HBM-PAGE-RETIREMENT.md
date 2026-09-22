# CMP 170HX HBM single-bit errors: physical-page diagnosis and software retirement

This document describes a real CMP 170HX / GA100 case in which one repeatable
single-bit error was isolated to one physical PMA page and removed from future
allocations by a small, device-specific NVIDIA Open Kernel Module patch.

The procedure is experimental. It is useful when the card exposes more memory
after `cmpunlocker`, but the NVIDIA stack reports `ECC: N/A`, `Retired Pages:
N/A`, and `Remapped Rows: N/A`. It is not a substitute for replacing a failing
card, and the final module must be kept together with a known-good rollback.

## Result in the reference case

The affected device was:

```text
GPU1, PCI 0000:83:00.0, GA100 / CMP 170HX
Driver: 610.57.04
Kernel: 7.0.12-cmp170bar1test
Visible memory: 65536 MiB
```

The observed test error was a one-bit `INITIAL_READ` error at:

```text
0xABA44677C..=0xABA44677F
```

The address above is an offset inside the current Vulkan test buffer. It is
not a physical HBM address.

The driver-side mapping trace identified the only physical discontinuity:

```text
logical=0xF0000  previous physical=0x129F0000  next physical=0x12C00000
```

Therefore, for the failing offset:

```text
physical = 0x12C00000 + (0xABA44677C - 0xF0000)
         = 0xACCF5677C
```

PMA uses a 64 KiB page frame, so the retired page base is:

```text
0xACCF50000  (64 KiB)
```

The bit was at offset `0x677C` inside that page. The final five-minute
`memtest_vulkan` run passed, and the test continued past 1,800 iterations
without an error. Before retirement, the same signature appeared repeatedly
around iterations 8–47.

Only one 64 KiB page was removed from a 64 GiB allocation: one part in
1,048,576, or about 0.000095%. `nvidia-smi` still reports 65536 MiB because
the difference is below its displayed precision.

## Why the error address must not be used directly

The exact `memtest_vulkan` v0.5.0 source shows that:

- the test binds a Vulkan buffer and reports a byte offset within that buffer;
- `ELEMENT_SIZE` is 4 bytes;
- the printed range is calculated as `buf_offset + idx * 4` through the last
  byte of the affected 32-bit word;
- `INITIAL_READ` is a read after the window was initially written;
- the program does not query a physical framebuffer address with
  `vkGetBufferDeviceAddress` or an NVIDIA physical-page API.

The same logical offset can move when another allocation is made first. In the
reference case the error moved when 8 GiB and 16 GiB were reserved before the
test. That proves relocation of the allocation, not movement of a physical HBM
defect. It is also why an error address such as `0xABA44677C` cannot be put
directly into a driver blacklist.

## 1. Capture a read-only baseline

Do this before changing the driver. Record the target GPU by PCI BDF, not only
by an index, because CUDA and Vulkan device numbering can differ.

```bash
uname -a
cat /proc/cmdline
nvidia-smi -L
nvidia-smi --query-gpu=index,pci.bus_id,name,memory.total,memory.used,temperature.memory,power.limit --format=csv
nvidia-smi -q -i 1
lspci -vv -s 83:00.0
nvidia-smi topo -m
modinfo nvidia
modinfo nvidia | grep -iE 'ecc|retir|black|remap|memory|page'
lsmod | grep nvidia
sudo dmesg | grep -iE 'NVRM|Xid|ECC|retir|blacklist|remap' | tail -100
```

Also save the exact active module and a rollback copy. Do not overwrite the
only copy of a working `cmpunlocker` module.

```bash
KVER=$(uname -r)
mkdir -p ~/cmp170-rollback
sudo cp -a /lib/modules/$KVER/updates/cmpunlocker/nvidia.ko ~/cmp170-rollback/
sha256sum /lib/modules/$KVER/updates/cmpunlocker/nvidia.ko \
  | tee ~/cmp170-rollback/nvidia.ko.sha256
```

The reference module was preserved with SHA-256:

```text
efce1c41578025c0d3f99adba763a5f4cd3b3b0285e5219f8f9dc225cb19d9ba
```

## 2. Establish a repeatable error

First test without `gpu-burn` or a compute workload reserving memory. This
keeps heat and concurrent activity out of the diagnosis. Stop the program
with Ctrl+C after collecting several identical errors, or let the normal
five-minute test finish.

```bash
cd ~
./memtest_vulkan 1
```

Record all of the following, not just the address:

- GPU number and PCI BDF selected by the program;
- mode (`INITIAL_READ` or another mode);
- inclusive error range;
- bit statistics and iteration number;
- HBM temperature and power limit;
- whether the error moves after a reservation.

An allocator-only reservation can be made with a small CUDA Runtime helper
that calls `cudaSetDevice(1)`, `cudaMalloc(8ULL << 30)`, and then sleeps. The
helper must free the allocation on exit. A reservation changing the reported
test offset is evidence about placement; it is not a repair and it does not
prove that the reserved range contains the bad page.

## 3. Confirm that the stack cannot retire the page by itself

On this CMP stack the following were all unavailable:

```text
ECC: N/A
Retired Pages: N/A
Remapped Rows: N/A
```

There were no matching Xid or ECC events for the `memtest_vulkan` corruption.
In the 610.57.04 source, the GA100 blacklist reader first requires page
retirement support. With the GSP client used by this CMP configuration,
`gpuCheckPageRetirementSupport_HAL()` returns false, so the normal RM/GSP
retirement path is not usable.

`NVreg_GpuBlacklist` is unrelated: it excludes an entire GPU by UUID. It does
not blacklist a page of HBM. Do not use it for this purpose.

The public controls also expose queries for offlined pages, not a supported
user command to set an arbitrary local HBM page. The physical-page controls
that are visible to user space concern system memory, not this local PMA
managed framebuffer.

## 4. Add a temporary physical mapping trace

Use the exact 610.57.04 source and the same CMP/P2P patch set that produced the
working module. Do not mix an unrelated NVIDIA branch with the loaded module.

The relevant source relationship is:

```text
pmaAllocatePages() returns physical PMA page addresses
        ↓
memdescFillPages() stores pPages[i] in the memory descriptor PTE array
        ↓
the Vulkan allocation sees those entries in logical order
```

In `src/nvidia/src/kernel/gpu/mem_mgr/mem_desc.c`, add a temporary diagnostic
inside `memdescFillPages()` before the dynamic-granularity early return. For
large fills, count discontinuities and print the logical start, physical first
page, physical last page, page size, and each discontinuity:

```c
if (((NvU64)pageCount * pageSize) >= (256ULL * 1024ULL * 1024ULL))
{
    NvU32 discontinuities = 0;

    for (i = 1; i < pageCount; i++)
    {
        if (pPages[i] != (pPages[i - 1] + pageSize))
        {
            discontinuities++;
            NV_PRINTF(LEVEL_ERROR,
                      "HBM_DIAG break md=%p logical=0x%llx prev=0x%llx next=0x%llx\n",
                      pMemDesc, ((NvU64)(pageIndex + i) * pageSize),
                      pPages[i - 1], pPages[i]);
        }
    }

    NV_PRINTF(LEVEL_ERROR,
              "HBM_DIAG map md=%p logical=0x%llx count=0x%x page=0x%llx first=0x%llx last=0x%llx breaks=0x%x\n",
              pMemDesc, ((NvU64)pageIndex * pageSize), pageCount,
              pageSize, pPages[0], pPages[pageCount - 1], discontinuities);
}
```

The trace is read-only. It must not write BAR registers, touch VBIOS, change
HBM timings, or change allocator policy. Clear the kernel log immediately
before the controlled test if necessary, then correlate the test's logical
offset with the `HBM_DIAG` mapping.

The 64 KiB mapping should be preferred for the arithmetic. A second 4 KiB
descriptor may appear for the same allocation; it is a representation detail,
not a different physical fault.

## 5. Build and install the diagnostic module safely

Build against the running kernel headers and preserve the active module before
installation. The exact command depends on the source tree's existing build
wrapper; the upstream open-module tree supports:

```bash
make clean
make -j"$(nproc)" modules SYSSRC="/lib/modules/$(uname -r)/build"
```

Before installing, check that the new module has the expected NVIDIA version
and that the diagnostic string is present:

```bash
modinfo kernel-open/nvidia.ko | grep -E '^(version|srcversion):'
strings kernel-open/nvidia.ko | grep HBM_DIAG
```

Install only after the rollback copy exists. If the system uses an initramfs,
the on-disk module is not enough: the boot image may contain an older copy.

```bash
KVER=$(uname -r)
sudo install -m 0644 kernel-open/nvidia.ko \
  /lib/modules/$KVER/updates/cmpunlocker/nvidia.ko
sudo depmod -a "$KVER"
sudo update-initramfs -u -k "$KVER"
```

Verify the initramfs contains the new diagnostic string before rebooting. Keep
KVM or a physical console available, because a kernel module mistake can make
a headless server unreachable. Reboot, wait for the slow KVM startup, and
repeat the controlled test.

## 6. Add one device-specific static blacklist entry

After the physical page is known, the 610.57.04 GA100 blacklist reader can be
extended to return one synthetic offlined-page entry for the affected device.
In `mem_mgr_ga100.c`, put the case-specific block at the start of
`memmgrGetBlackListPages_GA100()`:

```c
/* CMP170 GPU1 (0000:83:00.0): case-specific 64 KiB HBM retirement. */
if (gpuGetBus(pGpu) == 0x83)
{
    if (*pCount < 1)
        return NV_ERR_BUFFER_TOO_SMALL;

    pBlAddrs[0].address = 0x0000000ACCF50000ULL;
    pBlAddrs[0].type = NV2080_CTRL_FB_OFFLINED_PAGES_SOURCE_DPR_DBE;
    *pCount = 1;
    NV_PRINTF(LEVEL_ERROR,
              "HBM_BLACKLIST GPU bus 0x83 physical 0xACCF50000 (64 KiB) enabled\n");
    return NV_OK;
}
```

This is not a universal patch. Change both the PCI selector and the physical
page for another card. A physical address taken from `memtest_vulkan` without
the mapping trace is invalid. If the machine has multiple GPUs on the same
bus, match the complete domain/bus/device/function identity instead of only
the bus number.

Rebuild from the same source and repeat the module and initramfs checks. After
reboot, the kernel log must contain the expected line:

```text
HBM_BLACKLIST GPU bus 0x83 physical 0xACCF50000 (64 KiB) enabled
```

That line confirms that the target device selected the entry during boot. The
important functional check is the allocation test: PMA must not return the
page to a new client.

## 7. Validation and acceptance criteria

Run the standard test with no `gpu-burn` reservation:

```bash
cd ~
./memtest_vulkan 1
```

Accept the workaround only when all of these are true:

- the five-minute test reports `PASS`;
- the previous fixed signature does not reappear;
- the test continues through at least the iteration range where it previously
  failed;
- GPU0 and the other CMP cards still enumerate and pass their control test;
- `nvidia-smi` shows the expected full memory geometry and no new Xid;
- memory returns to its idle level after the test exits.

In the reference run, the test printed `Standard 5-minute test PASSed!`, had
passed more than 1,800 iterations, and had no copy of the previous one-bit
signature. The card reached about 67 °C during testing. The module remained
610.57.04 and the visible memory remained 65536 MiB.

This workaround does not repair the HBM cell or the hardware row. It only
prevents this one PMA page from being allocated. Continue to monitor long
workloads: a new error at another physical page requires a new diagnosis, and
multiple failures are a reason to replace or quarantine the card.

## Rollback

If the patched driver fails to load, the GPU disappears, or a new Xid appears,
restore the exact saved module and rebuild the initramfs:

```bash
KVER=$(uname -r)
sudo install -m 0644 ~/cmp170-rollback/nvidia.ko \
  /lib/modules/$KVER/updates/cmpunlocker/nvidia.ko
sudo depmod -a "$KVER"
sudo update-initramfs -u -k "$KVER"
sudo reboot
```

Do not remove the `cmpunlocker` directory, install a generic NVIDIA package,
or use `NVreg_ExcludedGpus` as a page-retirement mechanism. Keep the known-good
module, source tree, patch set, kernel command line, and module hashes together.

## What this procedure does not do

- It does not flash the VBIOS.
- It does not write BAR0/BAR1 or undocumented hardware registers.
- It does not claim that a Vulkan buffer address is a physical HBM address.
- It does not enable ECC or hardware row remapping where the GSP/CMP stack says
  they are unsupported.
- It does not guarantee that every CMP 170HX, motherboard, kernel, or driver
  version will use the same physical address or tolerate the same patch.

## Related projects

- [`memtest_vulkan` v0.5.0](https://github.com/GpuZelenograd/memtest_vulkan/releases/tag/v0.5.0)
- [`cmpunlocker`](https://github.com/amoghmunikote/cmpunlocker)
- [`170tune`](https://github.com/cachenetics/170tune)
- [NVIDIA Open GPU Kernel Modules](https://github.com/NVIDIA/open-gpu-kernel-modules)
