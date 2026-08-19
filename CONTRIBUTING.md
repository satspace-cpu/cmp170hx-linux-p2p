# Contributing

Reproductions are especially valuable because the current working result has been validated on one dual-CMP 170HX system.

## What to report

Please include:

- number of CMP 170HX cards
- reported VRAM size
- NVIDIA driver/KMD version
- CUDA version
- Linux distribution and kernel
- motherboard / platform if known
- PCIe link speed and width for each GPU
- whether IOMMU is enabled or disabled
- ACS status if modified
- `nvidia-smi topo -p2p r/w/p` output
- complete `p2pBandwidthLatencyTest` output

You can collect most of this with:

```bash
bash scripts/collect-debug-info.sh
```

Review the generated file before posting it publicly.

## Good benchmark practice

When comparing results:

1. Use the same driver, kernel and CUDA sample build.
2. Stop heavy GPU workloads first.
3. Record both P2P-disabled and P2P-enabled matrices.
4. Record latency and bandwidth, not only `CAN Access Peer`.
5. Run the test more than once if results are noisy.

## Patches

Keep fixes small and explain the failure mode they address. When adding a patch, document:

- source driver version
- target file/function
- expected before/after behavior
- whether it changes only capability reporting or the actual data path

## Safety

Do not submit secrets, access tokens, private SSH keys or full logs containing credentials. Hardware IDs and PCI addresses are normally useful, but review logs before posting.
