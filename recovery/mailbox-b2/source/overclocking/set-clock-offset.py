#!/usr/bin/env python3
"""Set the GPC core clock offset on every NVIDIA GPU.

Runtime only — nothing persists across a reboot.

  sudo ./set-clock-offset.py 150      +150 MHz on every GPU
  sudo ./set-clock-offset.py -100     back every GPU off by 100 MHz
  sudo ./set-clock-offset.py 0        reset
  sudo ./set-clock-offset.py -50 -g 1 second GPU only

A negative offset is the quickest way to find out whether an instability is in
the core rather than the memory: if errors under load disappear at -100, no
amount of memory-timing work will help. See README.md.
"""

import argparse
import os
import sys
from ctypes import c_int

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _nvml  # noqa: E402

p = argparse.ArgumentParser(
    description="Set the GPC core clock offset on all NVIDIA GPUs",
    formatter_class=argparse.RawDescriptionHelpFormatter,
    epilog=__doc__.split("\n", 2)[2],
)
p.add_argument("offset", type=int, help="clock offset in MHz, may be negative")
p.add_argument("-g", "--gpu", type=int, default=None, help="GPU index (default: all)")
args = p.parse_args()

nvml = _nvml.load()

failed = False
for h, label in _nvml.devices(nvml, args.gpu):
    if h is None:
        print(f"{label}: cannot get handle")
        failed = True
        continue

    rc = nvml.nvmlDeviceSetGpcClkVfOffset(h, c_int(args.offset))
    if rc != 0:
        print(f"{label}: clock offset failed: {_nvml.errstr(nvml, rc)}")
        failed = True
    else:
        print(f"{label}: clock offset {args.offset:+d} MHz")

nvml.nvmlShutdown()
sys.exit(1 if failed else 0)
