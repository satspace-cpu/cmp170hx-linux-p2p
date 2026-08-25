#!/usr/bin/env python3
"""Set the board power limit on every NVIDIA GPU.

Runtime only — nothing persists across a reboot.

  sudo ./set-power-limit.py 300       300 W on every GPU
  sudo ./set-power-limit.py 250 -g 1  second GPU only
  sudo ./set-power-limit.py --show    current limit and allowed range
  sudo ./set-power-limit.py --max     raise every GPU to its maximum

The board enforces its own min/max; a value outside that range is rejected per
GPU rather than clamped, so --show tells you what is actually allowed.
"""

import argparse
import os
import sys
from ctypes import byref, c_uint

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import _nvml  # noqa: E402

p = argparse.ArgumentParser(
    description="Set the board power limit on all NVIDIA GPUs",
    formatter_class=argparse.RawDescriptionHelpFormatter,
    epilog=__doc__.split("\n", 2)[2],
)
p.add_argument("watts", type=int, nargs="?", help="power limit in watts")
p.add_argument("-g", "--gpu", type=int, default=None, help="GPU index (default: all)")
p.add_argument("--show", action="store_true", help="report current limit and range, change nothing")
p.add_argument("--max", action="store_true", help="set each GPU to its own maximum")
args = p.parse_args()

if args.show and args.max:
    sys.exit("error: --show and --max are mutually exclusive")
if not args.show and not args.max and args.watts is None:
    sys.exit("error: give a wattage, or --show / --max")
if args.watts is not None and args.max:
    sys.exit("error: give a wattage or --max, not both")
if args.watts is not None and args.watts <= 0:
    sys.exit("error: wattage must be positive")

nvml = _nvml.load()


def limits(h):
    """(current, min, max) in watts, or None where NVML would not say."""
    cur = c_uint()
    lo = c_uint()
    hi = c_uint()
    c = nvml.nvmlDeviceGetPowerManagementLimit(h, byref(cur)) == 0
    r = nvml.nvmlDeviceGetPowerManagementLimitConstraints(h, byref(lo), byref(hi)) == 0
    return (cur.value // 1000 if c else None,
            lo.value // 1000 if r else None,
            hi.value // 1000 if r else None)


failed = False
for h, label in _nvml.devices(nvml, args.gpu):
    if h is None:
        print(f"{label}: cannot get handle")
        failed = True
        continue

    cur, lo, hi = limits(h)
    rng = f"{lo}-{hi} W" if lo is not None else "range unknown"

    if args.show:
        print(f"{label}: {cur if cur is not None else '?'} W   (allowed {rng})")
        continue

    target = hi if args.max else args.watts
    if target is None:
        print(f"{label}: cannot read maximum, skipped")
        failed = True
        continue

    if lo is not None and not (lo <= target <= hi):
        print(f"{label}: {target} W is outside the allowed {rng}, skipped")
        failed = True
        continue

    rc = nvml.nvmlDeviceSetPowerManagementLimit(h, c_uint(target * 1000))
    if rc != 0:
        print(f"{label}: power limit failed: {_nvml.errstr(nvml, rc)}   (allowed {rng})")
        failed = True
    else:
        print(f"{label}: power limit {target} W"
              + (f" (was {cur} W)" if cur is not None and cur != target else ""))

nvml.nvmlShutdown()
sys.exit(1 if failed else 0)
