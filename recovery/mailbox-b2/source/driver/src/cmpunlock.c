/*
 * cmpunlock - NVIDIA CMP 170HX (GA100) unlock logic.
 *
 * The card ships with its SM throughput, framebuffer geometry and PCIe link
 * speed clamped by PLM (priv level mask) gates that reject writes from the
 * host. The SEC2 Booter, however, is trusted enough to write them, and there
 * is a window during GSP bootstrap where its payload buffer can be pointed at
 * an arbitrary register/value pair. cmpUnlockPreBoot() walks that window once
 * per gate, then writes the real configuration and puts the stock signature
 * back so GSP boots as usual.
 *
 * See cmpunlock.h for where each entry point is hooked into the stock driver.
 */

#include "gpu/cmpunlock/cmpunlock.h"
#include "gpu/cmpunlock/cmpunlock_config.h"

#include "gpu/mem_mgr/mem_mgr.h"
#include "gpu/mem_mgr/heap.h"
#include "gpu/mem_mgr/phys_mem_allocator/phys_mem_allocator.h"
#include "gpu/bus/kern_bus.h"
#include "platform/chipset/chipset.h"
#include "core/system.h"
#include "os/os.h"

/* -------------------------------------------------------------------------
 * Register map
 * ------------------------------------------------------------------------- */

/* WPR2 window, saved and restored around every Booter invocation. */
#define CMP_REG_WPR2_LO             0x001fa824U
#define CMP_REG_WPR2_HI             0x001fa828U

/* SM speed select and memory geometry. */
#define CMP_REG_SM_SPEED_0          0x0082381cU
#define CMP_REG_SM_SPEED_1          0x00823820U
#define CMP_REG_FBPA_CFG1           0x009a0204U
#define CMP_REG_MMU_LMR             0x00100ce0U

/* PCIe Gen2: XP LTSSM directed speed change. */
#define CMP_REG_XP_CFG0             0x0008c040U
#define CMP_REG_XP_LCTRL2           0x0008c1c0U
#define CMP_REG_XP_CYA0             0x0008c2c0U
#define CMP_REG_XVE_LINK_CTRL_STAT  0x00088088U

/* HBM PLL / FBPA. */
#define CMP_REG_FBPA_PLL_PLM        0x00903c7cU
#define CMP_REG_FBPA_PLL_CFG        0x00903c90U
#define CMP_REG_FBPA_PLL_COEFF      0x00903c98U
#define CMP_REG_FBPA_PLL_COEFF_MC   0x0098bc98U  /* multicast COEFF */
#define CMP_REG_PRI_FENCE           0x001211fcU
#define CMP_REG_FBIO_BROADCAST      0x009a0590U
#define CMP_REG_HBM_SELF_REFRESH    0x009a031cU
#define CMP_REG_DDLL_CAL            0x009a11dcU
#define CMP_REG_DDLL_CAL_STATUS_0   0x009a0674U
#define CMP_REG_DDLL_CAL_STATUS_1   0x009a0678U

#define CMP_FBPA_COUNT              12U
#define CMP_FBPA_STRIDE             0x4000U
#define CMP_FBPA_BASE               0x900000U
#define CMP_FBPA_PLL_CFG_OFFSET     0x3c90U
#define CMP_FBPA_PLL_COEFF_OFFSET   0x3c98U

/*
 * HBM2e DRAM timings (FBPA broadcast aperture). Gated by the FBPA_MEM PLM,
 * which _cmpOpenPlmGates() opens, so these are only writable after the unlock.
 *
 * CONFIG0.USE_TIMING_REGS is 0 on this card, which makes the CONFIG registers
 * the live set; the TIMINGn_GEN registers are a read-only mirror of what the
 * memory controller actually generated from them.
 */
#define CMP_REG_FBPA_CONFIG0        0x009a0290U
#define CMP_REG_FBPA_CONFIG1        0x009a0294U
#define CMP_REG_FBPA_CONFIG2        0x009a0298U
#define CMP_REG_FBPA_CONFIG3        0x009a029cU
#define CMP_REG_FBPA_CONFIG4        0x009a02a0U
#define CMP_REG_FBPA_CONFIG10       0x009a02f4U
#define CMP_REG_FBPA_TIMING0_GEN    0x009a02b0U

/* Booter payload geometry. */
#define CMP_SIGNATURE_SIZE          0x0000f800ULL
#define CMP_PAYLOAD_FILL_DWORD      0x000004a7U
/*
 * Optional override for the Booter payload.
 *
 * This used to read /lib/firmware/nvidia/ga100/gsp/dmem.bin, which belongs to
 * the distro's GPU firmware package (nvidia-gpu-firmware on Fedora, part of
 * linux-firmware). That directory already collects per-driver blobs on every
 * firmware release, so a future update dropping a dmem.bin there would have
 * been picked up in preference to the built-in payload and quietly broken the
 * unlock - with no way to prevent it short of holding back linux-firmware,
 * which is not something worth doing to a system.
 *
 * The path now lives in cmpunlocker's own directory, where nothing else
 * writes. Absent - which is the normal case - the payload is generated below.
 */
#define CMP_DMEM_PATH               "/var/lib/cmpunlocker/dmem.bin"

/* Unlocked framebuffer sizes. */
#define CMP_FB_BYTES_8GB            0x0000001000000000ULL  /* 64GB */
#define CMP_FB_BYTES_10GB           0x0000000A00000000ULL  /* 40GB */
#define CMP_FB_BYTES_STOCK          0x0000000200000000ULL  /*  8GB */

/* A PRI read that comes back as 0xBAD?????? is an error, not data. */
#define CMP_IS_PRI_ERROR(v)         (((v) & 0xFFF00000U) == 0xBAD00000U)

/* -------------------------------------------------------------------------
 * Stock signature cache
 *
 * The signature buffer is repurposed as the Booter payload, so the real
 * signature has to be kept aside until the unlock is done. There is no room
 * for it in KernelGsp without patching a generated header, so it is parked in
 * a small table here instead. Entries are only touched during GSP init, which
 * runs under the API lock.
 * ------------------------------------------------------------------------- */

#define CMP_MAX_GPUS 32

static struct
{
    OBJGPU *pGpu;
    NvU8   *pData;
    NvU64   size;
} cmpStockSignature[CMP_MAX_GPUS];

static void
_cmpStockSignatureSet(OBJGPU *pGpu, NvU8 *pData, NvU64 size)
{
    NvU32 i, free = CMP_MAX_GPUS;

    for (i = 0; i < CMP_MAX_GPUS; i++)
    {
        if (cmpStockSignature[i].pGpu == pGpu)
        {
            /* Re-init of the same GPU: drop the previous copy first. */
            portMemFree(cmpStockSignature[i].pData);
            cmpStockSignature[i].pData = pData;
            cmpStockSignature[i].size  = size;
            return;
        }
        if (free == CMP_MAX_GPUS && cmpStockSignature[i].pGpu == NULL)
            free = i;
    }

    if (free == CMP_MAX_GPUS)
    {
        NV_PRINTF(LEVEL_ERROR, "CMPUNLOCK: stock signature table full\n");
        portMemFree(pData);
        return;
    }

    cmpStockSignature[free].pGpu = pGpu;
    cmpStockSignature[free].pData = pData;
    cmpStockSignature[free].size = size;
}

static NvU8 *
_cmpStockSignatureGet(OBJGPU *pGpu, NvU64 *pSize)
{
    NvU32 i;

    for (i = 0; i < CMP_MAX_GPUS; i++)
    {
        if (cmpStockSignature[i].pGpu == pGpu)
        {
            *pSize = cmpStockSignature[i].size;
            return cmpStockSignature[i].pData;
        }
    }

    *pSize = 0;
    return NULL;
}

/* -------------------------------------------------------------------------
 * Target detection
 * ------------------------------------------------------------------------- */

NvBool
cmpUnlockIsTarget(OBJGPU *pGpu)
{
    NvU32 devId;

    if (pGpu == NULL)
        return NV_FALSE;

    devId = pGpu->idInfo.PCIDeviceID >> 16;

    return (devId == CMPUNLOCK_DEVID_8GB || devId == CMPUNLOCK_DEVID_10GB);
}

/*
 * Escape hatch.
 *
 * The optional features are compiled in, so a value that wedges the GPU during
 * driver init leaves a machine that cannot boot far enough to reinstall - the
 * only way out would be pulling the card. This gives a way to skip all of them
 * from the boot loader instead:
 *
 *   nvidia.NVreg_RegistryDwords=cmpSafe=1
 *
 * The base unlock (memory geometry, SM, PCIe) still runs; only the tunables
 * that can be set to a bad value are skipped.
 */
static NvBool
cmpUnlockSafeMode(OBJGPU *pGpu)
{
    NvU32 data = 0;

    if (osReadRegistryDword(pGpu, "cmpSafe", &data) == NV_OK && data != 0)
    {
        NV_PRINTF(LEVEL_ERROR,
                  "CMPUNLOCK: cmpSafe=1 - skipping MCLK overclock and timing scaling\n");
        return NV_TRUE;
    }
    return NV_FALSE;
}

/*
 * Opt-in, because forcing the caps is not the same as P2P working.
 *
 * GSP reports P2P as unsupported on a CMP. Overriding that makes the driver
 * advertise it, and on a host where the path actually carries traffic it does
 * work. Where it does not - the wrong PCIe topology, ACS in the way, no IOMMU
 * passthrough - the override is worse than the restriction: everything claims
 * P2P is available, then transfers time out instead of quietly falling back to
 * staging through system memory.
 *
 * So this stays behind --p2p and off by default. Compiled out entirely when
 * the flag is absent; the hook in gpu.c then costs nothing.
 */
void
cmpUnlockForceP2PCaps(OBJGPU *pGpu)
{
#ifdef CMPUNLOCK_ENABLE_P2P
    if (!cmpUnlockIsTarget(pGpu))
        return;

    pGpu->pcieP2PReadCaps  = 0;
    pGpu->pcieP2PWriteCaps = 0;

    NV_PRINTF(LEVEL_ERROR, "CMPUNLOCK: PCIe P2P caps forced to OK (--p2p)\n");
#else
    (void)pGpu;
#endif
}

static NvU64
_cmpUnlockedFbBytes(OBJGPU *pGpu)
{
    return ((pGpu->idInfo.PCIDeviceID >> 16) == CMPUNLOCK_DEVID_8GB)
             ? CMP_FB_BYTES_8GB
             : CMP_FB_BYTES_10GB;
}

/* -------------------------------------------------------------------------
 * SEC2 Booter payload
 * ------------------------------------------------------------------------- */

static void
_cmpPutU32(NvU8 *pBuffer, NvU32 offset, NvU32 value)
{
    pBuffer[offset + 0] = (NvU8)(value >>  0);
    pBuffer[offset + 1] = (NvU8)(value >>  8);
    pBuffer[offset + 2] = (NvU8)(value >> 16);
    pBuffer[offset + 3] = (NvU8)(value >> 24);
}

/*
 * Build the Booter payload that makes SEC2 perform a single 32-bit write of
 * writeValue to writeAddr. The constants are the DMEM image the Booter walks;
 * only the address and value slots vary between calls.
 */
static void
_cmpFillPayload(NvU8 *pSignatureVa, NvU64 signatureSize,
                NvU32 writeAddr, NvU32 writeValue)
{
    NvU64 i;

    for (i = 0; i + sizeof(NvU32) <= signatureSize; i += sizeof(NvU32))
        _cmpPutU32(pSignatureVa, (NvU32)i, CMP_PAYLOAD_FILL_DWORD);

    _cmpPutU32(pSignatureVa, 0x1100, 0x00000007U);
    _cmpPutU32(pSignatureVa, 0x5b40, 0xc0deca7eU);

    _cmpPutU32(pSignatureVa, 0xf754, writeValue);
    _cmpPutU32(pSignatureVa, 0xf758, 0xc0deca7eU);
    _cmpPutU32(pSignatureVa, 0xf75c, 0x00000cbdU);
    _cmpPutU32(pSignatureVa, 0xf76c, writeAddr);
    _cmpPutU32(pSignatureVa, 0xf774, 0x00001fbdU);
    _cmpPutU32(pSignatureVa, 0xf780, 0x00000000U);
    _cmpPutU32(pSignatureVa, 0xf788, 0x000010aaU);
    _cmpPutU32(pSignatureVa, 0xf78c, 0x0000815aU);
    _cmpPutU32(pSignatureVa, 0xf790, 0x00008e18U);
    _cmpPutU32(pSignatureVa, 0xf794, 0xc0deca7eU);
    _cmpPutU32(pSignatureVa, 0xf798, 0x0000815aU);
    _cmpPutU32(pSignatureVa, 0xf79c, 0x00000000U);
    _cmpPutU32(pSignatureVa, 0xf7a0, 0xc0deca7eU);
    _cmpPutU32(pSignatureVa, 0xf7a4, 0x00001fbdU);
    _cmpPutU32(pSignatureVa, 0xf7b0, 0x0000ffbcU);
    _cmpPutU32(pSignatureVa, 0xf7b8, 0x0000582dU);
    _cmpPutU32(pSignatureVa, 0xf7c4, 0xc0deca7eU);
    _cmpPutU32(pSignatureVa, 0xf7c8, 0x00000cbdU);
    _cmpPutU32(pSignatureVa, 0xf7d8, 0x00000003U);
    _cmpPutU32(pSignatureVa, 0xf7e0, 0x00001fbdU);
    _cmpPutU32(pSignatureVa, 0xf7f4, 0x00000ccbU);
    _cmpPutU32(pSignatureVa, 0xf7f8, 0x00007f2fU);
}

/* Rewrite the payload in place for the next register write. */
static NV_STATUS
_cmpRefillPayload(OBJGPU *pGpu, KernelGsp *pKernelGsp,
                  NvU32 writeAddr, NvU32 writeValue)
{
    NvU8 *pSignatureVa;

    if (pKernelGsp->pSignatureMemdesc == NULL)
        return NV_ERR_INVALID_STATE;

    pSignatureVa = memdescMapInternal(pGpu, pKernelGsp->pSignatureMemdesc, TRANSFER_FLAGS_NONE);
    if (pSignatureVa == NULL)
        return NV_ERR_INSUFFICIENT_RESOURCES;

    _cmpFillPayload(pSignatureVa, memdescGetSize(pKernelGsp->pSignatureMemdesc),
                    writeAddr, writeValue);

    memdescUnmapInternal(pGpu, pKernelGsp->pSignatureMemdesc, 0);
    memdescFlushCpuCaches(pGpu, pKernelGsp->pSignatureMemdesc);

    if (pKernelGsp->pWprMeta != NULL)
    {
        pKernelGsp->pWprMeta->sysmemAddrOfSignature =
            memdescGetPhysAddr(pKernelGsp->pSignatureMemdesc, AT_GPU, 0);
        pKernelGsp->pWprMeta->sizeOfSignature =
            memdescGetSize(pKernelGsp->pSignatureMemdesc);
    }

    if (pKernelGsp->pWprMetaDescriptor != NULL)
        memdescFlushCpuCaches(pGpu, pKernelGsp->pWprMetaDescriptor);

    return NV_OK;
}

NvU64
cmpUnlockSignatureSize(OBJGPU *pGpu, NvU64 stockSize)
{
    return cmpUnlockIsTarget(pGpu) ? CMP_SIGNATURE_SIZE : stockSize;
}

NvBool
cmpUnlockFillSignature(OBJGPU *pGpu, KernelGsp *pKernelGsp,
                       NvU8 *pSignatureVa, NvU64 signatureVaSize,
                       const void *pStockSignature, NvU64 stockSignatureSize)
{
    NV_STATUS dmemStatus;

    if (!cmpUnlockIsTarget(pGpu))
        return NV_FALSE;

    if (pStockSignature != NULL && stockSignatureSize > 0)
    {
        NvU8 *pCopy = portMemAllocNonPaged(stockSignatureSize);
        if (pCopy != NULL)
        {
            portMemCopy(pCopy, stockSignatureSize, pStockSignature, stockSignatureSize);
            _cmpStockSignatureSet(pGpu, pCopy, stockSignatureSize);
            NV_PRINTF(LEVEL_ERROR, "CMPUNLOCK: saved stock signature (%llu bytes)\n",
                      (unsigned long long)stockSignatureSize);
        }
    }

    /*
     * Prefer the DMEM image on disk when it is present; the built-in payload
     * is the same thing generated from scratch.
     */
    dmemStatus = os_open_and_read_file(CMP_DMEM_PATH, pSignatureVa, signatureVaSize);
    if (dmemStatus == NV_OK)
    {
        NV_PRINTF(LEVEL_ERROR, "CMPUNLOCK: loaded %llu bytes from %s\n",
                  (unsigned long long)signatureVaSize, CMP_DMEM_PATH);
    }
    else
    {
        NV_PRINTF(LEVEL_ERROR, "CMPUNLOCK: %s not found (0x%x), using built-in payload\n",
                  CMP_DMEM_PATH, dmemStatus);
        _cmpFillPayload(pSignatureVa, signatureVaSize, 0x009a0148U, 0xffffffffU);
    }

    memdescFlushCpuCaches(pGpu, pKernelGsp->pSignatureMemdesc);

    return NV_TRUE;
}

/*
 * Swap the Booter payload back out for the real signature, so the GSP boot
 * that follows sees exactly what the stock driver would have handed it.
 */
static NV_STATUS
_cmpRebuildStockSignature(OBJGPU *pGpu, KernelGsp *pKernelGsp)
{
    NV_STATUS status = NV_OK;
    NvU8 *pSignatureVa = NULL;
    NvU8 *pStockData;
    NvU64 stockSize;
    NvU64 sigSize;
    NvU64 flags = MEMDESC_FLAGS_NONE;

    pStockData = _cmpStockSignatureGet(pGpu, &stockSize);
    if (pStockData == NULL || stockSize == 0)
        return NV_ERR_INVALID_STATE;

    if (pKernelGsp->pSignatureMemdesc != NULL)
    {
        memdescFree(pKernelGsp->pSignatureMemdesc);
        memdescDestroy(pKernelGsp->pSignatureMemdesc);
        pKernelGsp->pSignatureMemdesc = NULL;
    }

    sigSize = NV_ALIGN_UP(stockSize, 256);
    flags |= MEMDESC_FLAGS_ALLOC_IN_UNPROTECTED_MEMORY;

    NV_CHECK_OK_OR_RETURN(LEVEL_ERROR,
        memdescCreate(&pKernelGsp->pSignatureMemdesc, pGpu,
            sigSize, 256,
            NV_TRUE, ADDR_SYSMEM, NV_MEMORY_CACHED, flags));

    memdescTagAlloc(status,
        NV_FB_ALLOC_RM_INTERNAL_OWNER_UNNAMED_TAG_16, pKernelGsp->pSignatureMemdesc);
    NV_CHECK_OK_OR_GOTO(status, LEVEL_ERROR, status, rebuild_fail_create);

    pSignatureVa = memdescMapInternal(pGpu, pKernelGsp->pSignatureMemdesc, TRANSFER_FLAGS_NONE);
    NV_CHECK_OK_OR_GOTO(status, LEVEL_ERROR,
        (pSignatureVa != NULL) ? NV_OK : NV_ERR_INSUFFICIENT_RESOURCES,
        rebuild_fail_alloc);

    portMemCopy(pSignatureVa, memdescGetSize(pKernelGsp->pSignatureMemdesc),
                pStockData, stockSize);

    memdescUnmapInternal(pGpu, pKernelGsp->pSignatureMemdesc, 0);

    if (pKernelGsp->pWprMeta != NULL)
    {
        pKernelGsp->pWprMeta->sysmemAddrOfSignature =
            memdescGetPhysAddr(pKernelGsp->pSignatureMemdesc, AT_GPU, 0);
        pKernelGsp->pWprMeta->sizeOfSignature =
            memdescGetSize(pKernelGsp->pSignatureMemdesc);
    }

    if (pKernelGsp->pWprMetaDescriptor != NULL)
        memdescFlushCpuCaches(pGpu, pKernelGsp->pWprMetaDescriptor);

    return NV_OK;

rebuild_fail_alloc:
    memdescFree(pKernelGsp->pSignatureMemdesc);

rebuild_fail_create:
    memdescDestroy(pKernelGsp->pSignatureMemdesc);
    pKernelGsp->pSignatureMemdesc = NULL;

    return status;
}

/* -------------------------------------------------------------------------
 * PLM gates
 * ------------------------------------------------------------------------- */

/*
 * Each entry is one SEC2 Booter round trip: point the payload at addr, run
 * Booter Load, confirm the register reads back as value.
 *
 * Only the bits set in mask are compared. Several of these registers have
 * reserved or hardwired bits that never read back as written, so a full
 * equality check would report a gate as failed even when it opened.
 *
 * The PCIe entries have to sit in this table rather than in a second pass of
 * their own - by the time the first loop finishes, the Booter is no longer in
 * a state where further payloads take effect.
 */
static const struct
{
    NvU32       addr;
    NvU32       value;
    NvU32       mask;
    const char *name;
} cmpPlmTable[] = {
    { 0x001fa7ccU, 0xfffff0ffU, 0xffffffffU, "WPR_CFG"      },
    { 0x009a0148U, 0xffffffffU, 0xffffffffU, "FBPA"         },
    { 0x009a0168U, 0xffffffffU, 0x000000ffU, "FBPA_MEM"     },
    { 0x001fa7c4U, 0xffffffffU, 0xffffffffU, "WPR"          },
    { 0x00823804U, 0xffffffffU, 0xffffffffU, "FEAT"         },
    { 0x00088ff4U, 0xffffffffU, 0xffffffffU, "XVE"          },
    { 0x00088ab4U, 0xffffffffU, 0xffffffffU, "XVE_B"        },
    { 0x00088ff8U, 0xffffffffU, 0xffffffffU, "XVE_C"        },
    { 0x00823b00U, 0xffffffffU, 0xffffffffU, "FEAT2"        },
    { 0x008200fcU, 0xffffffffU, 0xffffffffU, "OPT_PLM"      },
    { 0x009a3c7cU, 0xffffffffU, 0xffffffffU, "FBPA_PLL0"    },
    { 0x009a3c80U, 0xffffffffU, 0xffffffffU, "FBPA_PLL1"    },
    { 0x009a3c84U, 0xffffffffU, 0xffffffffU, "FBPA_PLL2"    },
    { 0x00088fe8U, 0xffffffffU, 0xffffffffU, "XVE_PLM"      },
    { 0x00088fecU, 0xffffffffU, 0xffffffffU, "XVE_CYA_PLM"  },
    { 0x0008872cU, 0x0000000aU, 0x0000000fU, "XVE_FUSE_OVR" },
    { 0x0008841cU, 0x4034ad00U, 0x4000a800U, "XVE_CYA_SPD"  },
    { 0x000880a8U, 0x00000002U, 0x0000000fU, "XVE_TARGET"   },
};

static void
_cmpOpenPlmGates(OBJGPU *pGpu, KernelGsp *pKernelGsp, NvU32 wpr2Lo, NvU32 wpr2Hi)
{
    NvU32 idx, attempt;

    for (idx = 0; idx < NV_ARRAY_ELEMENTS(cmpPlmTable); idx++)
    {
        NvBool opened = NV_FALSE;

        for (attempt = 0; attempt < 2 && !opened; attempt++)
        {
            NV_STATUS status;
            NvU32 regVal;

            /* Booter Load clobbers the WPR2 window; put it back each round. */
            GPU_REG_WR32(pGpu, CMP_REG_WPR2_LO, wpr2Lo);
            GPU_REG_WR32(pGpu, CMP_REG_WPR2_HI, wpr2Hi);

            status = _cmpRefillPayload(pGpu, pKernelGsp,
                                       cmpPlmTable[idx].addr, cmpPlmTable[idx].value);
            if (status != NV_OK)
                continue;

            status = kgspExecuteBooterLoad_HAL(pGpu, pKernelGsp,
                memdescGetPhysAddr(pKernelGsp->pWprMetaDescriptor, AT_GPU, 0));

            regVal = GPU_REG_RD32(pGpu, cmpPlmTable[idx].addr);
            NV_PRINTF(LEVEL_ERROR,
                      "CMPUNLOCK: PLM[%u] %s(0x%x) attempt=%u status=0x%x reg=0x%08x\n",
                      idx, cmpPlmTable[idx].name, cmpPlmTable[idx].addr,
                      attempt, status, regVal);

            if ((regVal & cmpPlmTable[idx].mask) ==
                (cmpPlmTable[idx].value & cmpPlmTable[idx].mask))
                opened = NV_TRUE;
        }

        if (!opened)
            NV_PRINTF(LEVEL_ERROR, "CMPUNLOCK: FAILED to open %s after 2 attempts\n",
                      cmpPlmTable[idx].name);
    }
}

/* -------------------------------------------------------------------------
 * PCIe Gen2
 * ------------------------------------------------------------------------- */

/*
 * Ask the link to retrain at Gen2. The PLM gates guarding the XP registers
 * were opened by _cmpOpenPlmGates(), so these writes stick.
 */
static void
_cmpRetrainGen2(OBJGPU *pGpu)
{
    NvU32 xpCfg0   = GPU_REG_RD32(pGpu, CMP_REG_XP_CFG0);
    NvU32 xpLctrl2 = GPU_REG_RD32(pGpu, CMP_REG_XP_LCTRL2);
    NvU32 xpCya0   = GPU_REG_RD32(pGpu, CMP_REG_XP_CYA0);
    NvU32 cfg0Now, cfg0After, linkCtrlStat;
    NvU32 i;

    NV_PRINTF(LEVEL_ERROR, "CMPUNLOCK: PCIe pre: CFG0=0x%08x LCTRL2=0x%08x CYA0=0x%08x\n",
              xpCfg0, xpLctrl2, xpCya0);

    /* Clear the CYA bits that pin the link to Gen1, then select Gen2. */
    GPU_REG_WR32(pGpu, CMP_REG_XP_CYA0,   xpCya0 & ~0x00802005U);
    GPU_REG_WR32(pGpu, CMP_REG_XP_CFG0,   (xpCfg0   & ~0xC0000U) | 0x80000U);
    GPU_REG_WR32(pGpu, CMP_REG_XP_LCTRL2, (xpLctrl2 & ~0xF0000U) | 0x20000U);

    /* The root port has to agree on the target speed or it will refuse. */
    {
        OBJCL *pCl = SYS_GET_CL(SYS_GET_INSTANCE());
        PORTDATA *pUpPort = &pGpu->gpuClData.upstreamPort;

        if (pCl != NULL && pUpPort->addr.valid)
        {
            NvU32 lnkCtl2Off = pUpPort->PCIECapPtr + 0x30U;
            NvU16 rpLnkCtl2 = clPcieReadWord(pCl,
                pUpPort->addr.domain, pUpPort->addr.bus,
                pUpPort->addr.device, pUpPort->addr.func, lnkCtl2Off);
            NvU16 rpLnkCtl2New = (rpLnkCtl2 & ~0xFU) | 0x2U;

            clPcieWriteWord(pCl,
                pUpPort->addr.domain, pUpPort->addr.bus,
                pUpPort->addr.device, pUpPort->addr.func,
                lnkCtl2Off, rpLnkCtl2New);

            NV_PRINTF(LEVEL_ERROR,
                      "CMPUNLOCK: PCIe root port LnkCtl2 @ 0x%x: 0x%04x -> 0x%04x\n",
                      lnkCtl2Off, rpLnkCtl2, rpLnkCtl2New);
        }
        else
        {
            NV_PRINTF(LEVEL_ERROR,
                      "CMPUNLOCK: PCIe upstream port not valid, cannot set root target\n");
        }
    }

    /* Trigger the directed speed change and wait for the LTSSM to settle. */
    cfg0Now = GPU_REG_RD32(pGpu, CMP_REG_XP_CFG0);
    GPU_REG_WR32(pGpu, CMP_REG_XP_CFG0, (cfg0Now & ~0xFU) | 0x1U);

    for (i = 0; i < 50; i++)
    {
        osDelay(10);
        if ((GPU_REG_RD32(pGpu, CMP_REG_XP_CFG0) & 0x10U) == 0)
            break;
    }

    cfg0After = GPU_REG_RD32(pGpu, CMP_REG_XP_CFG0);
    GPU_REG_WR32(pGpu, CMP_REG_XP_CFG0, cfg0After & ~0xFU);

    linkCtrlStat = GPU_REG_RD32(pGpu, CMP_REG_XVE_LINK_CTRL_STAT);
    NV_PRINTF(LEVEL_ERROR,
              "CMPUNLOCK: PCIe retrain done (polls=%u): LinkCtrlStat=0x%08x speed=%u width=x%u\n",
              i, linkCtrlStat,
              (linkCtrlStat >> 16) & 0xFU,
              (linkCtrlStat >> 20) & 0x3FU);
}

/* -------------------------------------------------------------------------
 * The unlock
 * ------------------------------------------------------------------------- */

NV_STATUS
cmpUnlockPreBoot(OBJGPU *pGpu, KernelGsp *pKernelGsp, GSP_FIRMWARE *pGspFw)
{
    NvU32 devId = pGpu->idInfo.PCIDeviceID >> 16;
    NvU32 wpr2Lo, wpr2Hi;
    NvU32 cfg1Value, lmrValue;
    NV_STATUS status;

    if (!cmpUnlockIsTarget(pGpu))
        return NV_OK;

    wpr2Lo = GPU_REG_RD32(pGpu, CMP_REG_WPR2_LO);
    wpr2Hi = GPU_REG_RD32(pGpu, CMP_REG_WPR2_HI);
    NV_PRINTF(LEVEL_ERROR, "CMPUNLOCK: saved WPR2 lo=0x%08x hi=0x%08x\n", wpr2Lo, wpr2Hi);

    _cmpOpenPlmGates(pGpu, pKernelGsp, wpr2Lo, wpr2Hi);

    GPU_REG_WR32(pGpu, CMP_REG_WPR2_LO, wpr2Lo);
    GPU_REG_WR32(pGpu, CMP_REG_WPR2_HI, wpr2Hi);

    NV_PRINTF(LEVEL_ERROR,
              "CMPUNLOCK: PLMs: FEAT=0x%08x FBPA=0x%08x FBPA_MEM=0x%08x "
              "WPR=0x%08x WPR_CFG=0x%08x\n",
              GPU_REG_RD32(pGpu, 0x00823804U),
              GPU_REG_RD32(pGpu, 0x009a0148U),
              GPU_REG_RD32(pGpu, 0x009a0168U),
              GPU_REG_RD32(pGpu, 0x001fa7c4U),
              GPU_REG_RD32(pGpu, 0x001fa7ccU));

    /* With the gates open, write the real configuration. */
    if (devId == CMPUNLOCK_DEVID_8GB)
    {
        cfg1Value = 0x02779000U;
        lmrValue  = 0x0000020BU;
    }
    else
    {
        cfg1Value = 0x02669000U;
        lmrValue  = 0x0000028AU;
    }

    GPU_REG_WR32(pGpu, CMP_REG_SM_SPEED_0, 0x88888888U);
    GPU_REG_WR32(pGpu, CMP_REG_SM_SPEED_1, 0x00000008U);
    GPU_REG_WR32(pGpu, CMP_REG_FBPA_CFG1,  cfg1Value);
    GPU_REG_WR32(pGpu, CMP_REG_MMU_LMR,    lmrValue);

    NV_PRINTF(LEVEL_ERROR,
              "CMPUNLOCK: POST-WRITE SS0=0x%08x SS1=0x%08x CFG1=0x%08x LMR=0x%08x (devId=0x%x)\n",
              GPU_REG_RD32(pGpu, CMP_REG_SM_SPEED_0),
              GPU_REG_RD32(pGpu, CMP_REG_SM_SPEED_1),
              GPU_REG_RD32(pGpu, CMP_REG_FBPA_CFG1),
              GPU_REG_RD32(pGpu, CMP_REG_MMU_LMR),
              devId);

    _cmpRetrainGen2(pGpu);

    /* Put the real signature back before GSP boots. */
    status = _cmpRebuildStockSignature(pGpu, pKernelGsp);
    if (status != NV_OK)
    {
        NV_PRINTF(LEVEL_ERROR, "CMPUNLOCK: rebuild stock signature failed: 0x%x\n", status);
        return status;
    }

    /* FB size changed under us, so the WPR layout has to be recomputed. */
    NV_CHECK_OK_OR_RETURN(LEVEL_ERROR, kgspPopulateWprMeta_HAL(pGpu, pKernelGsp, pGspFw));

    NV_PRINTF(LEVEL_ERROR,
              "CMPUNLOCK: WPR meta updated fbSize=0x%016llx wprStart=0x%016llx "
              "wprEnd=0x%016llx heapOffset=0x%016llx heapSize=0x%016llx\n",
              pKernelGsp->pWprMeta->fbSize,
              pKernelGsp->pWprMeta->gspFwWprStart,
              pKernelGsp->pWprMeta->gspFwWprEnd,
              pKernelGsp->pWprMeta->gspFwHeapOffset,
              pKernelGsp->pWprMeta->gspFwHeapSize);

    return NV_OK;
}

/* -------------------------------------------------------------------------
 * Static config info
 * ------------------------------------------------------------------------- */

void
cmpUnlockFixStaticInfo(OBJGPU *pGpu, KernelGsp *pKernelGsp)
{
    GspStaticConfigInfo *pGSCI;
    NV2080_CTRL_CMD_FB_GET_FB_REGION_INFO_PARAMS *pFbRegionInfoParams;
    NV2080_CTRL_CMD_FB_GET_FB_REGION_FB_REGION_INFO *pLastRegion;
    NvU64 targetFbBytes, highLimit;
    NvU32 numRegions;

    if (!cmpUnlockIsTarget(pGpu))
        return;

    pGSCI = &pKernelGsp->gspStaticInfo;
    pFbRegionInfoParams = &pGSCI->fbRegionInfoParams;
    targetFbBytes = _cmpUnlockedFbBytes(pGpu);
    numRegions = pFbRegionInfoParams->numFBRegions;

    NV_PRINTF(LEVEL_ERROR, "CMPUNLOCK: static-info BEFORE: fb_length=0x%llx numRegions=%u\n",
              pGSCI->fb_length, numRegions);

    pGSCI->fb_length = targetFbBytes;

    if (numRegions == 0 || numRegions > NV2080_CTRL_CMD_FB_GET_FB_REGION_INFO_MAX_ENTRIES)
        return;

    pLastRegion = &pFbRegionInfoParams->fbRegion[numRegions - 1];
    highLimit = targetFbBytes - 1;

    NV_PRINTF(LEVEL_ERROR,
              "CMPUNLOCK: last region[%u] base=0x%llx limit=0x%llx reserved=0x%llx\n",
              numRegions - 1, pLastRegion->base, pLastRegion->limit, pLastRegion->reserved);

    if (pLastRegion->limit < highLimit)
    {
        pLastRegion->limit = highLimit;
        pLastRegion->reserved = pLastRegion->limit - pLastRegion->base + 1;
        pLastRegion->supportCompressed = NV_TRUE;
        pLastRegion->supportISO = NV_TRUE;
        pLastRegion->performance = 20;
    }

    NV_PRINTF(LEVEL_ERROR, "CMPUNLOCK: static-info AFTER: fb_length=0x%llx last_limit=0x%llx\n",
              pGSCI->fb_length, pLastRegion->limit);
}

/* -------------------------------------------------------------------------
 * DRAM timing scaling
 *
 * Compiled out unless the build sets CMPUNLOCK_MCLK_TIMINGS (--mclk-timings=N).
 * N is a signed percentage: positive loosens, negative tightens.
 *
 * The timing registers hold cycle counts, not absolute time, so raising the
 * memory clock silently tightens every one of them: at 1971 MHz a cycle is
 * 0.507 ns against the 0.579 ns of the 1728 MHz the VBIOS table was written
 * for. Scaling the counts back up restores the real-time margin the DRAM
 * expects, which is what lets a higher NDIV hold.
 *
 * Only "wait longer before issuing the next command" timings are touched:
 *
 *  - CL and WL are excluded on purpose. They say when to sample data and have
 *    to match the mode registers trained into the HBM stacks, so raising them
 *    here would desynchronise the read pointer instead of adding margin.
 *  - tCCD_S/tCCD_L are excluded too. They are the only timings that bind
 *    streaming bandwidth (loosening them by 4 cycles costs ~60% of it) and
 *    they already sit at the hardware floor.
 *
 * Several fields have a high-bit extension in CONFIG10; those are carried so
 * a large percentage cannot silently wrap the field. Tightening is clamped at
 * 1 cycle, since a zero would be nonsense rather than merely aggressive.
 *
 * Tightening is the dangerous direction: too small a value corrupts data
 * silently or wedges the memory controller, and writing the old value back
 * does not recover it.
 * ------------------------------------------------------------------------- */

#ifdef CMPUNLOCK_MCLK_TIMINGS

static const struct
{
    NvU32       reg;
    NvU8        lo;        /* field position within reg               */
    NvU8        width;     /* field width within reg                  */
    NvU8        msbLo;     /* extension position in CONFIG10          */
    NvU8        msbWidth;  /* extension width, 0 when there is none   */
    const char *name;
} cmpTimingRelaxTable[] = {
    { CMP_REG_FBPA_CONFIG0,  0, 8,  0, 0, "tRC"     },
    { CMP_REG_FBPA_CONFIG0,  8, 9,  0, 2, "tRFC"    },
    { CMP_REG_FBPA_CONFIG0, 17, 7,  0, 0, "tRAS"    },
    { CMP_REG_FBPA_CONFIG0, 24, 7,  0, 0, "tRP"     },
    { CMP_REG_FBPA_CONFIG1, 14, 6,  8, 1, "tRCD_rd" },
    { CMP_REG_FBPA_CONFIG1, 20, 6, 11, 1, "tRCD_wr" },
    { CMP_REG_FBPA_CONFIG2, 16, 7,  0, 0, "tWR"     },
    { CMP_REG_FBPA_CONFIG3,  9, 8,  0, 0, "tFAW"    },
    { CMP_REG_FBPA_CONFIG4, 15, 6,  0, 0, "tRRD"    },
};

/*
 * Stock timings, captured the first time the pass runs on a given GPU.
 *
 * Every pass scales from these rather than from whatever is in the register,
 * so running twice cannot compound (a naive re-scale would give 1.2 * 1.2).
 * Keying on pGpu also means a driver re-init that skipped the power cycle
 * still scales from the real stock values.
 */
static struct
{
    OBJGPU *pGpu;
    NvU32   field[NV_ARRAY_ELEMENTS(cmpTimingRelaxTable)];
} cmpTimingStock[CMP_MAX_GPUS];

static NvU32 *
_cmpTimingStockSlot(OBJGPU *pGpu, NvBool *pCaptured)
{
    NvU32 i, free = CMP_MAX_GPUS;

    for (i = 0; i < CMP_MAX_GPUS; i++)
    {
        if (cmpTimingStock[i].pGpu == pGpu)
        {
            *pCaptured = NV_TRUE;
            return cmpTimingStock[i].field;
        }
        if (free == CMP_MAX_GPUS && cmpTimingStock[i].pGpu == NULL)
            free = i;
    }

    if (free == CMP_MAX_GPUS)
        return NULL;

    cmpTimingStock[free].pGpu = pGpu;
    *pCaptured = NV_FALSE;
    return cmpTimingStock[free].field;
}

static NvU32
_cmpFieldMax(NvU8 width)
{
    return (width >= 32) ? 0xFFFFFFFFU : ((1U << width) - 1U);
}

static void
_cmpScaleTimings(OBJGPU *pGpu, const char *phase)
{
    const NvS32 pct = CMPUNLOCK_MCLK_TIMINGS;
    NvU32 cfg10, cfg10New;
    NvU32 *pStock;
    NvBool captured = NV_FALSE;
    NvU32 i;

    cfg10 = GPU_REG_RD32(pGpu, CMP_REG_FBPA_CONFIG10);
    if (CMP_IS_PRI_ERROR(cfg10))
    {
        NV_PRINTF(LEVEL_ERROR,
                  "TIMING_SCALE: %s aborted, CONFIG10 reads 0x%08x\n", phase, cfg10);
        return;
    }
    cfg10New = cfg10;

    pStock = _cmpTimingStockSlot(pGpu, &captured);
    if (pStock == NULL)
    {
        NV_PRINTF(LEVEL_ERROR, "TIMING_SCALE: %s aborted, stock table full\n", phase);
        return;
    }

    NV_PRINTF(LEVEL_ERROR, "TIMING_SCALE: %s, %+d%% (CONFIG0=0x%08x CONFIG10=0x%08x)\n",
              phase, pct, GPU_REG_RD32(pGpu, CMP_REG_FBPA_CONFIG0), cfg10);

    for (i = 0; i < NV_ARRAY_ELEMENTS(cmpTimingRelaxTable); i++)
    {
        NvU32 regVal   = GPU_REG_RD32(pGpu, cmpTimingRelaxTable[i].reg);
        NvU8  width    = cmpTimingRelaxTable[i].width;
        NvU8  lo       = cmpTimingRelaxTable[i].lo;
        NvU8  msbWidth = cmpTimingRelaxTable[i].msbWidth;
        NvU8  msbLo    = cmpTimingRelaxTable[i].msbLo;
        NvU32 fieldMax = _cmpFieldMax(width);
        NvU32 total, totalMax, old, neu;

        if (CMP_IS_PRI_ERROR(regVal))
        {
            NV_PRINTF(LEVEL_ERROR, "TIMING_SCALE:   %s skipped, reg 0x%08x reads 0x%08x\n",
                      cmpTimingRelaxTable[i].name, cmpTimingRelaxTable[i].reg, regVal);
            continue;
        }

        old = (regVal >> lo) & fieldMax;
        if (msbWidth != 0)
            old |= ((cfg10 >> msbLo) & _cmpFieldMax(msbWidth)) << width;

        /* First pass on this GPU sees the untouched VBIOS table. */
        if (!captured)
            pStock[i] = old;

        totalMax = _cmpFieldMax((NvU8)(width + msbWidth));

        /*
         * Signed scale; every value here is far below the overflow point.
         * Clamped to [1, field max] - a zero-cycle timing is not a valid
         * "very tight", it is a broken register.
         */
        {
            NvS32 target = (NvS32)pStock[i] + (((NvS32)pStock[i] * pct) / 100);

            if (target < 1)
                target = 1;
            neu = ((NvU32)target > totalMax) ? totalMax : (NvU32)target;
        }
        if (neu == old)
            continue;

        regVal = (regVal & ~(fieldMax << lo)) | ((neu & fieldMax) << lo);
        GPU_REG_WR32(pGpu, cmpTimingRelaxTable[i].reg, regVal);

        if (msbWidth != 0)
        {
            NvU32 msbMask = _cmpFieldMax(msbWidth);
            cfg10New = (cfg10New & ~(msbMask << msbLo)) |
                       (((neu >> width) & msbMask) << msbLo);
        }

        total = (GPU_REG_RD32(pGpu, cmpTimingRelaxTable[i].reg) >> lo) & fieldMax;
        NV_PRINTF(LEVEL_ERROR, "TIMING_SCALE:   %-7s %4u -> %-4u %s\n",
                  cmpTimingRelaxTable[i].name, old, neu,
                  (total == (neu & fieldMax)) ? "" : "<< READBACK MISMATCH");
    }

    if (cfg10New != cfg10)
    {
        GPU_REG_WR32(pGpu, CMP_REG_FBPA_CONFIG10, cfg10New);
        NV_PRINTF(LEVEL_ERROR, "TIMING_SCALE:   CONFIG10 0x%08x -> 0x%08x\n",
                  cfg10, GPU_REG_RD32(pGpu, CMP_REG_FBPA_CONFIG10));
    }

    /* TIMING0_GEN is the controller's own view - proof the writes took. */
    NV_PRINTF(LEVEL_ERROR, "TIMING_SCALE: %s done, TIMING0_GEN=0x%08x\n",
              phase, GPU_REG_RD32(pGpu, CMP_REG_FBPA_TIMING0_GEN));
}

#endif /* CMPUNLOCK_MCLK_TIMINGS */

/* -------------------------------------------------------------------------
 * HBM PLL overclock
 *
 * Both halves are compiled out unless the build sets CMPUNLOCK_MCLK_NDIV
 * (driver/build.sh passes -DCMPUNLOCK_MCLK_NDIV=N for --mclk-ndiv=N).
 *
 * The sequence is VBIOS-agnostic: the stock NDIV is read out of the PLL
 * rather than assumed, and every COEFF write is a read-modify-write that
 * keeps the MDIV/PDIV the VBIOS programmed.
 * ------------------------------------------------------------------------- */

void
cmpUnlockPostBooterLoad(OBJGPU *pGpu, KernelGsp *pKernelGsp)
{
    if (!cmpUnlockIsTarget(pGpu))
        return;

    /*
     * Booter Load is the last thing that can silently undo the unlock, so
     * report what the gated registers actually ended up holding. Worth having
     * in safe mode too - that is when you are diagnosing something.
     */
    NV_PRINTF(LEVEL_ERROR,
              "CMPUNLOCK: post-BooterLoad verify PLM=0x%08x SS0=0x%08x SS1=0x%08x "
              "CFG1=0x%08x LMR=0x%08x\n",
              GPU_REG_RD32(pGpu, 0x00823804U),
              GPU_REG_RD32(pGpu, CMP_REG_SM_SPEED_0),
              GPU_REG_RD32(pGpu, CMP_REG_SM_SPEED_1),
              GPU_REG_RD32(pGpu, CMP_REG_FBPA_CFG1),
              GPU_REG_RD32(pGpu, CMP_REG_MMU_LMR));

    if (cmpUnlockSafeMode(pGpu))
        return;

#ifdef CMPUNLOCK_MCLK_TIMINGS
    /* Must precede the PLL cycle below: the clock has to come up on the
       loosened timings, not land on the stock ones and then be widened. */
    _cmpScaleTimings(pGpu, "pre-PLL");
#endif

#ifdef CMPUNLOCK_MCLK_NDIV
    {
    const NvU32 newNdiv = CMPUNLOCK_MCLK_NDIV;
    NvU32 fbpaIdx, pollIdx;
    NvU32 fbpaCount = 0, failCount = 0;
    NvU32 plm0, fbio0, curNdiv;
    NvU32 ddll0, calSt0 = 0, calSt1 = 0;

    plm0 = GPU_REG_RD32(pGpu, CMP_REG_FBPA_PLL_PLM);
    curNdiv = (GPU_REG_RD32(pGpu, CMP_REG_FBPA_PLL_COEFF) >> 8) & 0xFFU;

    if ((plm0 & 0x10U) == 0)
    {
        NV_PRINTF(LEVEL_ERROR, "HBMPLL_OC: aborted, PLM=0x%08x (bit4 closed)\n", plm0);
        return;
    }

    NV_PRINTF(LEVEL_ERROR,
              "HBMPLL_OC: start NDIV %u->%u (%u->%u MHz) devid=0x%04x vbios=%s PLM=0x%08x\n",
              curNdiv, newNdiv, 27 * curNdiv, 27 * newNdiv,
              pGpu->idInfo.PCIDeviceID >> 16, pKernelGsp->vbiosVersionStr, plm0);

    /* 1. Assert MEMCLK_CHANGE_ALERT (FBIO broadcast bit 31) */
    fbio0 = GPU_REG_RD32(pGpu, CMP_REG_FBIO_BROADCAST);
    GPU_REG_WR32(pGpu, CMP_REG_FBIO_BROADCAST, fbio0 | 0x80000000U);

    /* 2. Enter HBM self-refresh */
    GPU_REG_WR32(pGpu, CMP_REG_HBM_SELF_REFRESH, 0x00000001U);
    osDelay(5);

    /* 3. PLL cycle on each active FBPA */
    for (fbpaIdx = 0; fbpaIdx < CMP_FBPA_COUNT; fbpaIdx++)
    {
        NvU32 base      = CMP_FBPA_BASE + fbpaIdx * CMP_FBPA_STRIDE;
        NvU32 cfgAddr   = base + CMP_FBPA_PLL_CFG_OFFSET;
        NvU32 coeffAddr = base + CMP_FBPA_PLL_COEFF_OFFSET;
        NvU32 origCfg   = GPU_REG_RD32(pGpu, cfgAddr);
        NvU32 origCoeff = GPU_REG_RD32(pGpu, coeffAddr);
        NvU32 newCoeff, lockCfg = 0;

        if (origCfg == 0 || origCoeff == 0 || CMP_IS_PRI_ERROR(origCfg))
            continue;

        fbpaCount++;

        GPU_REG_WR32(pGpu, cfgAddr, origCfg & ~0x09U);
        osDelay(2);

        newCoeff = (origCoeff & ~0xFF00U) | ((newNdiv & 0xFFU) << 8);
        GPU_REG_WR32(pGpu, coeffAddr, newCoeff);

        GPU_REG_WR32(pGpu, cfgAddr, (origCfg | 0x09U) & ~0x20U);

        for (pollIdx = 0; pollIdx < 200; pollIdx++)
        {
            osDelay(1);
            lockCfg = GPU_REG_RD32(pGpu, cfgAddr);
            if (lockCfg & 0x20U)
                break;
        }

        if (!(lockCfg & 0x20U))
        {
            NV_PRINTF(LEVEL_ERROR, "HBMPLL_OC: FBPA%u PLL lock timeout\n", fbpaIdx);
            failCount++;
            continue;
        }

        GPU_REG_WR32(pGpu, cfgAddr, lockCfg & ~0x1000U);
    }

    /* 4. Exit self-refresh */
    GPU_REG_WR32(pGpu, CMP_REG_HBM_SELF_REFRESH, 0x00000000U);
    osDelay(10);

    /* 5. DDLL calibration */
    ddll0 = GPU_REG_RD32(pGpu, CMP_REG_DDLL_CAL);
    GPU_REG_WR32(pGpu, CMP_REG_DDLL_CAL, ddll0 | 0x40U);
    osDelay(10);
    for (pollIdx = 0; pollIdx < 100; pollIdx++)
    {
        osDelay(1);
        calSt0 = GPU_REG_RD32(pGpu, CMP_REG_DDLL_CAL_STATUS_0);
        calSt1 = GPU_REG_RD32(pGpu, CMP_REG_DDLL_CAL_STATUS_1);
    }
    GPU_REG_WR32(pGpu, CMP_REG_DDLL_CAL, ddll0 & ~0x40U);
    NV_PRINTF(LEVEL_ERROR, "HBMPLL_OC: DDLL cal status 0x%08x 0x%08x\n", calSt0, calSt1);

    /* 6. Clear MEMCLK_CHANGE_ALERT */
    GPU_REG_WR32(pGpu, CMP_REG_FBIO_BROADCAST,
                 GPU_REG_RD32(pGpu, CMP_REG_FBIO_BROADCAST) & ~0x80000000U);

    if (fbpaCount == 0)
        NV_PRINTF(LEVEL_ERROR, "HBMPLL_OC: no active FBPAs found\n");
    else if (failCount > 0)
        NV_PRINTF(LEVEL_ERROR, "HBMPLL_OC: %u/%u FBPAs failed to lock\n",
                  failCount, fbpaCount);
    else
        NV_PRINTF(LEVEL_ERROR, "HBMPLL_OC: done, %u FBPAs at NDIV=%u (%u MHz)\n",
                  fbpaCount, newNdiv, 27 * newNdiv);
    }
#else
    (void)pKernelGsp;
#endif
}

void
cmpUnlockMclkPostGsp(OBJGPU *pGpu, KernelGsp *pKernelGsp)
{
#if defined(CMPUNLOCK_MCLK_TIMINGS) || defined(CMPUNLOCK_MCLK_NDIV)
    if (!cmpUnlockIsTarget(pGpu))
        return;
    if (cmpUnlockSafeMode(pGpu))
        return;
#endif

#ifdef CMPUNLOCK_MCLK_TIMINGS
    /*
     * Second pass, as insurance against GSP reprogramming the timing table
     * during its own memory init. Measured on 610.43.03 / VBIOS 92.00.6D.00.0A
     * it does not - the pre-PLL values survive - so this normally finds every
     * field already at target and writes nothing. It scales from the captured
     * stock values, so it cannot compound the relax if it does run.
     */
    _cmpScaleTimings(pGpu, "post-GSP");
#endif

#ifdef CMPUNLOCK_MCLK_NDIV
    {
    const NvU32 newNdiv = CMPUNLOCK_MCLK_NDIV;
    NvU32 coeffPre, plmPre, newCoeff, cfg = 0;
    NvU32 i;

    coeffPre = GPU_REG_RD32(pGpu, CMP_REG_FBPA_PLL_COEFF);
    plmPre   = GPU_REG_RD32(pGpu, CMP_REG_FBPA_PLL_PLM);

    /* Fall back to the 300W layout if the read came back as a PRI error. */
    if (coeffPre == 0 || CMP_IS_PRI_ERROR(coeffPre))
        newCoeff = (1U << 16) | (newNdiv << 8) | 1U;
    else
        newCoeff = (coeffPre & ~0xFF00U) | ((newNdiv & 0xFFU) << 8);

    NV_PRINTF(LEVEL_ERROR,
              "HBMPLL_OC: post-GSP PRE: COEFF=0x%08x(NDIV=%u) PLM=0x%08x "
              "devid=0x%04x vbios=%s newCOEFF=0x%08x\n",
              coeffPre, (coeffPre >> 8) & 0xFFU, plmPre,
              pGpu->idInfo.PCIDeviceID >> 16, pKernelGsp->vbiosVersionStr, newCoeff);

    GPU_REG_WR32(pGpu, CMP_REG_FBPA_PLL_COEFF_MC, newCoeff);
    GPU_REG_WR32(pGpu, CMP_REG_PRI_FENCE, 0x0U);
    for (i = 0; i < 500; i++)
        (void)GPU_REG_RD32(pGpu, CMP_REG_FBPA_PLL_CFG);

    for (i = 0; i < 200000; i++)
    {
        cfg = GPU_REG_RD32(pGpu, CMP_REG_FBPA_PLL_CFG);
        if (cfg & 0x20U)
            break;
    }

    NV_PRINTF(LEVEL_ERROR,
              "HBMPLL_OC: post-GSP POST: COEFF=0x%08x(NDIV=%u) CFG=0x%08x lock=%u iter=%u\n",
              GPU_REG_RD32(pGpu, CMP_REG_FBPA_PLL_COEFF),
              (GPU_REG_RD32(pGpu, CMP_REG_FBPA_PLL_COEFF) >> 8) & 0xFFU,
              cfg, (cfg >> 5) & 1U, i);
    }
#endif

    (void)pGpu;
    (void)pKernelGsp;
}

/* -------------------------------------------------------------------------
 * Late PMA extension
 *
 * GSP hands back a heap sized for the stock 8GB. The memory above that is
 * present but sitting in a reserved FB region, so it is carved out and
 * registered with PMA once everything else has finished initialising.
 *
 * DISABLED (local change, not upstream). The candidate search below picks the
 * highest reserved FB region and publishes all of it to the page allocator.
 * On these cards that region is 6 (base=0xff7300000 limit=0xfffffffff), and
 * that span contains both the write-protected region (wprStart=0xff7400000,
 * wprEnd=0xffff00000) and the GSP heap (heapOffset=0xff7500000,
 * heapSize=0x6e00000). Publishing it hands user-allocatable pages out of
 * memory the hardware refuses copy-engine writes to, which surfaces as:
 *
 *   Xid 31 "MMU Fault: ENGINE CE2 HUBCLIENT_HSCE2 ...
 *           FAULT_INFO_TYPE_REGION_VIOLATION ACCESS_TYPE_VIRT_WRITE"
 *
 * ~11s into a vLLM weight load, reproducible on all 4 cards and on both the
 * amoghmunikote and asm64-hooligan unlock implementations.
 *
 * Cost of skipping: the extension only grew PMA from 0xfd8f50000 to
 * 0xfe1c50000, i.e. ~141 MB out of 63.5 GiB (0.22%). The bulk of the unlock
 * does not come from here.
 *
 * The body is left intact rather than deleted so the region dump can be
 * re-enabled by flipping the return below when revisiting this.
 * ------------------------------------------------------------------------- */

NV_STATUS
cmpUnlockLateExtendPma(OBJGPU *pGpu)
{
    MemoryManager *pMemoryManager;
    Heap *pHeap;
    PMA *pPma;
    PMA_REGION_DESCRIPTOR pmaRegion = {0};
    PMA_REGION_DESCRIPTOR *pFirstPmaRegionDesc = NULL;
    FB_REGION_DESCRIPTOR *pCandidate = NULL;
    NvU32 numPmaRegions = 0;
    NvU32 candidateIdx = MAX_FB_REGIONS;
    NvU64 pmaFreeBefore = 0, pmaTotalBefore = 0;
    NvU64 pmaFreeAfter = 0, pmaTotalAfter = 0;
    NvU64 heapFree = 0, heapTotal = 0;
    NvU32 i;
    NV_STATUS status;

    if (!cmpUnlockIsTarget(pGpu))
        return NV_OK;

    /*
     * Skip the extension entirely; see the block comment above. The repeated
     * cmpUnlockIsTarget() test is deliberate: it has external linkage, so the
     * compiler cannot fold it away and the remainder of the function stays
     * reachable, avoiding unreachable-code and unused-variable warnings.
     *
     * Ruled out as a P2P factor on 2026-08-06: with this skip disabled, peer
     * reads and writes failed identically, so it is not what breaks P2P.
     */
    if (cmpUnlockIsTarget(pGpu))
    {
        NV_PRINTF(LEVEL_ERROR,
                  "CMPUNLOCK_PMA: extension SKIPPED (region overlaps WPR + GSP heap)\n");
        return NV_OK;
    }

    pMemoryManager = GPU_GET_MEMORY_MANAGER(pGpu);
    if (pMemoryManager == NULL)
        return NV_ERR_INVALID_ARGUMENT;

    pHeap = pMemoryManager->pHeap;
    if (pHeap == NULL || pHeap->pPmaObject == NULL || !memmgrIsPmaInitialized(pMemoryManager))
    {
        NV_PRINTF(LEVEL_ERROR, "CMPUNLOCK_PMA: no PMA, skipped heap=%p init=%u\n",
                  pHeap, pHeap ? memmgrIsPmaInitialized(pMemoryManager) : 0);
        return NV_OK;
    }

    pPma = pHeap->pPmaObject;
    heapGetFree(pHeap, &heapFree);
    heapGetSize(pHeap, &heapTotal);
    pmaGetFreeMemory(pPma, &pmaFreeBefore);
    pmaGetTotalMemory(pPma, &pmaTotalBefore);

    for (i = 0; i < pMemoryManager->Ram.numFBRegions; i++)
    {
        FB_REGION_DESCRIPTOR *pRegion = &pMemoryManager->Ram.fbRegion[i];
        NV_PRINTF(LEVEL_ERROR,
                  "CMPUNLOCK_PMA: region[%u] base=0x%llx limit=0x%llx "
                  "rsvd=%u rsvdSize=0x%llx intHeap=%u\n",
                  i, pRegion->base, pRegion->limit,
                  pRegion->bRsvdRegion, pRegion->rsvdSize, pRegion->bInternalHeap);
    }

    status = pmaGetRegionInfo(pPma, &numPmaRegions, &pFirstPmaRegionDesc);
    if (status != NV_OK)
    {
        NV_PRINTF(LEVEL_ERROR, "CMPUNLOCK_PMA: pmaGetRegionInfo failed 0x%x\n", status);
        return status;
    }

    NV_PRINTF(LEVEL_ERROR,
              "CMPUNLOCK_PMA: numFBRegions=%u numPmaRegions=%u stockFb=0x%llx "
              "pma_total=0x%llx pma_free=0x%llx heap_total=0x%llx heap_free=0x%llx\n",
              pMemoryManager->Ram.numFBRegions, numPmaRegions,
              CMP_FB_BYTES_STOCK, pmaTotalBefore, pmaFreeBefore, heapTotal, heapFree);

    /* Find the highest reserved region that reaches past the stock limit. */
    for (i = 0; i < pMemoryManager->Ram.numFBRegions; i++)
    {
        FB_REGION_DESCRIPTOR *pRegion = &pMemoryManager->Ram.fbRegion[i];
        if (pRegion->bRsvdRegion && !pRegion->bInternalHeap &&
            pRegion->limit >= CMP_FB_BYTES_STOCK && pRegion->base <= pRegion->limit &&
            (pCandidate == NULL || pRegion->limit > pCandidate->limit))
        {
            pCandidate = pRegion;
            candidateIdx = i;
        }
    }

    if (pCandidate == NULL)
    {
        NV_PRINTF(LEVEL_ERROR,
                  "CMPUNLOCK_PMA: no high reserved region found "
                  "(looking for bRsvdRegion && limit>=0x%llx)\n", CMP_FB_BYTES_STOCK);
        return NV_OK;
    }

    pmaRegion.base = NV_MAX(pCandidate->base, CMP_FB_BYTES_STOCK);
    pmaRegion.limit = pCandidate->limit;
    pmaRegion.performance = pCandidate->performance;
    pmaRegion.bSupportCompressed = NV_TRUE;
    pmaRegion.bSupportISO = pCandidate->bSupportISO;
    pmaRegion.bProtected = pCandidate->bProtected;

    if (pmaRegion.base > pmaRegion.limit)
    {
        NV_PRINTF(LEVEL_ERROR, "CMPUNLOCK_PMA: empty range base=0x%llx > limit=0x%llx\n",
                  pmaRegion.base, pmaRegion.limit);
        return NV_OK;
    }

    if (pmaIsPmaManaged(pPma, pmaRegion.base, pmaRegion.limit))
    {
        NV_PRINTF(LEVEL_ERROR, "CMPUNLOCK_PMA: already managed base=0x%llx limit=0x%llx\n",
                  pmaRegion.base, pmaRegion.limit);
        return NV_OK;
    }

    NV_PRINTF(LEVEL_ERROR,
              "CMPUNLOCK_PMA: registering candidate=%u base=0x%llx limit=0x%llx "
              "cand_base=0x%llx cand_limit=0x%llx pma_region_id=%u\n",
              candidateIdx, pmaRegion.base, pmaRegion.limit,
              pCandidate->base, pCandidate->limit, numPmaRegions);

    /* Splitting the candidate needs a spare FB region slot. */
    if (pCandidate->base < CMP_FB_BYTES_STOCK &&
        pMemoryManager->Ram.numFBRegions >= MAX_FB_REGIONS)
    {
        NV_PRINTF(LEVEL_ERROR,
                  "CMPUNLOCK_PMA: no FB region slot for split, numRegions=%u max=%u\n",
                  pMemoryManager->Ram.numFBRegions, MAX_FB_REGIONS);
        return NV_ERR_INSUFFICIENT_RESOURCES;
    }

    status = pmaRegisterRegion(pPma, numPmaRegions, NV_FALSE, &pmaRegion, 0, NULL);

    if (status == NV_OK)
    {
        if (pCandidate->base < CMP_FB_BYTES_STOCK)
        {
            /* Straddles the stock limit: keep the low half reserved, publish the high half. */
            FB_REGION_DESCRIPTOR publicRegion = *pCandidate;
            publicRegion.base = CMP_FB_BYTES_STOCK;
            publicRegion.limit = pCandidate->limit;
            publicRegion.rsvdSize = 0;
            publicRegion.bRsvdRegion = NV_FALSE;
            publicRegion.bInternalHeap = NV_FALSE;
            publicRegion.bSupportCompressed = NV_FALSE;

            pCandidate->limit = CMP_FB_BYTES_STOCK - 1;
            pCandidate->rsvdSize = NV_MIN(pCandidate->rsvdSize,
                                          pCandidate->limit - pCandidate->base + 1);

            pMemoryManager->Ram.fbRegion[pMemoryManager->Ram.numFBRegions] = publicRegion;
            pMemoryManager->Ram.numFBRegions++;
        }
        else
        {
            /* Entirely above the stock limit: publish it as-is. */
            pCandidate->bRsvdRegion = NV_FALSE;
            pCandidate->rsvdSize = 0;
            pCandidate->bInternalHeap = NV_FALSE;
            pCandidate->bSupportCompressed = NV_FALSE;
        }
        memmgrRegenerateFbRegionPriority(pGpu, pMemoryManager);
    }

    pmaGetFreeMemory(pPma, &pmaFreeAfter);
    pmaGetTotalMemory(pPma, &pmaTotalAfter);

    NV_PRINTF(LEVEL_ERROR,
              "CMPUNLOCK_PMA: status=0x%x pma_total 0x%llx->0x%llx pma_free 0x%llx->0x%llx\n",
              status, pmaTotalBefore, pmaTotalAfter, pmaFreeBefore, pmaFreeAfter);

    return status;
}
