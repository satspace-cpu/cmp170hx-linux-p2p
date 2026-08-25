"""Shared NVML plumbing for the overclocking scripts. Sourced, not run."""

import os
import sys
from ctypes import (CDLL, byref, c_int, c_uint, c_void_p, create_string_buffer,
                    string_at)


def errstr(nvml, rc):
    """NVML error as text, so a failure says what went wrong."""
    try:
        s = nvml.nvmlErrorString(c_int(rc))
        return f"{string_at(s).decode(errors='replace')} (rc={rc})" if s else f"rc={rc}"
    except Exception:
        return f"rc={rc}"


def load():
    """Root check, load NVML, init. Exits with a readable message on failure."""
    if os.geteuid() != 0:
        sys.exit("error: run as root")
    try:
        nvml = CDLL("libnvidia-ml.so.1")
    except OSError as e:
        sys.exit(f"error: cannot load NVML ({e}) — is the NVIDIA driver installed?")
    nvml.nvmlErrorString.restype = c_void_p
    rc = nvml.nvmlInit_v2()
    if rc != 0:
        sys.exit(f"error: nvmlInit failed: {errstr(nvml, rc)}")
    return nvml


def devices(nvml, only=None):
    """Yield (handle, label) for every GPU, or just the one `only` selects."""
    count = c_uint()
    nvml.nvmlDeviceGetCount_v2(byref(count))
    if count.value == 0:
        nvml.nvmlShutdown()
        sys.exit("error: no NVIDIA GPUs found")

    if only is not None:
        if not 0 <= only < count.value:
            nvml.nvmlShutdown()
            sys.exit(f"error: GPU {only} out of range ({count.value} present)")
        indices = [only]
    else:
        indices = range(count.value)

    for i in indices:
        h = c_void_p()
        if nvml.nvmlDeviceGetHandleByIndex_v2(i, byref(h)) != 0:
            yield None, f"GPU {i}"
            continue
        name = create_string_buffer(96)
        label = f"GPU {i}"
        if nvml.nvmlDeviceGetName(h, name, c_uint(96)) == 0:
            label = f"GPU {i} ({name.value.decode(errors='replace')})"
        yield h, label
