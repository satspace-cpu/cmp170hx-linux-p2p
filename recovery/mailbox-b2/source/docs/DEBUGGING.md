# Debugging

---

## Show debug logs

`sudo dmesg | grep CMPUNLOCK`

---

## "nvidia-smi: command not found"

Re-run `sudo ./install.sh` and cold reboot.

---

## nvidia-smi shows 8192 or 10240 MiB (not 65536 or 40960)

Check that all PLMs show `0xffffffff`:

```bash
sudo dmesg | grep CMPUNLOCK
```


## Running the benchmark for unlock verification

```bash
./benchmark/nvidia_bench          # default: GPU #0, auto-sized iterations
./benchmark/nvidia_bench 1        # test GPU #1
./benchmark/nvidia_bench 0 50     # GPU #0, 50 iterations per test
./benchmark/nvidia_bench --csv    # machine-readable output
```

A pre-built x86-64 binary is included. On aarch64, see the README for the build command.

