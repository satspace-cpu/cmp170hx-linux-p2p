/*
 * cmpunlock - NVIDIA CMP 170HX (GA100) unlock logic.
 *
 * Every behavioural change lives in cmpunlock.c. The stock driver sources are
 * patched only with the small hook calls declared below, so moving to a new
 * nvidia-open release means re-checking a handful of one-line insertions
 * instead of re-merging several hundred lines of diff.
 *
 * On any GPU that is not a CMP 170HX every hook is a no-op, so the patched
 * modules stay safe to run on a mixed system.
 */

#ifndef CMPUNLOCK_H
#define CMPUNLOCK_H

#include "core/core.h"
#include "gpu/gpu.h"
#include "gpu/gsp/kernel_gsp.h"

/* PCI device IDs of the two CMP 170HX variants (upper half of PCIDeviceID). */
#define CMPUNLOCK_DEVID_8GB  0x20C2U
#define CMPUNLOCK_DEVID_10GB 0x2082U

/*
 * NV_TRUE if this GPU is a CMP 170HX. Every other entry point calls this
 * first, so hooks can be placed unconditionally.
 */
NvBool cmpUnlockIsTarget(OBJGPU *pGpu);

/*
 * Size of the GSP signature buffer. On a CMP the buffer doubles as the SEC2
 * Booter payload and has to be large enough for it; elsewhere the stock size
 * is returned unchanged.
 *
 * Hook: _kgspCreateSignatureMemdesc(), memdescCreate() size argument.
 */
NvU64 cmpUnlockSignatureSize(OBJGPU *pGpu, NvU64 stockSize);

/*
 * Fill the freshly allocated signature buffer. Stashes the stock signature so
 * it can be restored later (see cmpUnlockPreBoot) and writes the Booter
 * payload in its place.
 *
 * Returns NV_TRUE when it took ownership of the buffer, NV_FALSE when the
 * caller should perform its normal copy.
 *
 * Hook: _kgspCreateSignatureMemdesc(), replacing the portMemCopy().
 */
NvBool cmpUnlockFillSignature(OBJGPU *pGpu, KernelGsp *pKernelGsp,
                              NvU8 *pSignatureVa, NvU64 signatureVaSize,
                              const void *pStockSignature, NvU64 stockSignatureSize);

/*
 * The unlock itself. Runs in the window after kgspPrepareForBootstrap_HAL()
 * and before GSP is released: opens the PLM gates through the SEC2 Booter,
 * writes the SM/memory/PCIe configuration, retrains the link at Gen2, then
 * restores the stock signature so GSP boots normally.
 *
 * Hook: _kgspBootGspRm(), after kgspPrepareForBootstrap_HAL().
 */
NV_STATUS cmpUnlockPreBoot(OBJGPU *pGpu, KernelGsp *pKernelGsp, GSP_FIRMWARE *pGspFw);

/*
 * Widen the framebuffer geometry GSP reported back to the unlocked size.
 *
 * Hook: kgspInitRm_IMPL(), after the static config info is fetched.
 */
void cmpUnlockFixStaticInfo(OBJGPU *pGpu, KernelGsp *pKernelGsp);

/*
 * Runs right after Booter Load, while the PLM gates are still open. Reports
 * what the unlock actually took effect as, then performs the first half of
 * the HBM PLL overclock (a per-FBPA PLL cycle).
 *
 * Hook: kgspBootstrap_TU102(), after Booter Load succeeds.
 */
void cmpUnlockPostBooterLoad(OBJGPU *pGpu, KernelGsp *pKernelGsp);

/*
 * Second half of the HBM PLL overclock: a multicast COEFF write once GSP is
 * up. Like the first half, a no-op unless the build defines
 * CMPUNLOCK_MCLK_NDIV.
 *
 * Hook: kgspInitRm_IMPL(), after kgspStartLogPolling().
 */
void cmpUnlockMclkPostGsp(OBJGPU *pGpu, KernelGsp *pKernelGsp);

/*
 * Hand the memory above the stock 8GB limit to PMA. Has to run late, once the
 * heap and PMA are fully initialised.
 *
 * Hook: RmInitNvDevice() in osinit.c, after the GPU finishes initialising.
 */
NV_STATUS cmpUnlockLateExtendPma(OBJGPU *pGpu);

/*
 * Force PCIe P2P caps to OK. GSP firmware reports NOT_SUPPORTED for CMP
 * cards, but the GA100 mailbox P2P hardware works fine. This overrides the
 * GSP response so cudaDeviceEnablePeerAccess() succeeds.
 *
 * Hook: _gpuInitPcieP2PCapability() in gpu.c, after the GSP RPC.
 */
void cmpUnlockForceP2PCaps(OBJGPU *pGpu);

#endif /* CMPUNLOCK_H */
