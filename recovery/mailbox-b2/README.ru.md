# CMP 170HX Mailbox P2P — рабочая B2-сборка

Проверенная конфигурация: 2× CMP 170HX, NVIDIA 610.43.03, ядро
`7.0.12-cmp170bar1test`, 64 ГБ VRAM и BAR1 на каждой карте, PCIe Gen2 x16,
IOMMU off и ACS redirect disabled.

## Результат

- P2P one-way: 6.69–6.70 GB/s
- P2P bidirectional: 13.37–13.40 GB/s
- GPU latency: 1.54–1.62 us
- HBM: userspace NDIV 70 / 1890 MHz, stock timings

## Что оказалось рабочим

Старая patch-stack сборка `aikitoria 452cec62..9fb65044` под новым ядром
включала P2P, но теряла Gen2, большой BAR1 и FBPA unlock. Рабочий B2 использует
целостную Bayley-базу для memory/Gen2/BAR1/FBPA, но меняет выбор P2P-протокола:

```c
pKernelBif->p2pOverride = bCmp170hx ? 0x11 : BIF_P2P_NOT_OVERRIDEN;
pKernelBif->pcieP2PType = NV_REG_STR_RM_PCIEP2P_TYPE_DEFAULT;
```

`CMPUNLOCK_ENABLE_P2P` также включён. Параметры
`RMForceStaticBar1=1;RMPcieP2PType=1`, необходимые Bayley BAR1 P2P, для Mailbox
не используются.

## Состав исходников

Каталог `source/` — полный использованный cmpunlocker tree без временного
`.build`. NVIDIA open modules 610.43.03 загружаются сборщиком по официальному
тегу. Дополнительный патч находится в:

```text
source/driver/patches/0012-mailbox-default.patch
```

Сборщик в recovery-копии останавливается после создания `.ko` и ничего не
устанавливает автоматически.

## Сборка

```bash
cd recovery/mailbox-b2/source
sudo env \
  CMPUNLOCKER_DRIVER_VERSION=610.43.03 \
  CMPUNLOCKER_ENABLE_P2P=1 \
  CMPUNLOCKER_MCLK_NDIV= \
  CMPUNLOCKER_MCLK_TIMINGS= \
  ./driver/build.sh
```

Результат:

```text
source/driver/.build/open-gpu-kernel-modules-610.43.03/kernel-open/nvidia*.ko
```

Перед установкой обязательно проверить `version`, `vermagic` и сохранить все
пять текущих модулей вместе с initrd.

## Переключение BAR1 → Mailbox

1. Сохранить текущие `nvidia*.ko` и `/boot/initrd.img-$(uname -r)`.
2. Удалить `/etc/modprobe.d/cmp170-bayley-p2p.conf`, если он задаёт
   `RMPcieP2PType=1`.
3. Установить одновременно все пять новых модулей.
4. Выполнить `depmod` и `update-initramfs`.
5. Перезагрузить сервер.

Готовый скрипт: `install-built-mailbox.sh --yes`. Он сам создаёт backup и не
перезагружает сервер.

## Проверка после загрузки

```bash
nvidia-smi --query-gpu=index,memory.total,persistence_mode,power.limit,pcie.link.gen.current,pcie.link.width.current --format=csv
nvidia-smi -q -d MEMORY | grep -A3 'BAR1 Memory Usage'
sudo 170tune preflight
nvidia-smi topo -p2p r
nvidia-smi topo -p2p w
./p2pBandwidthLatencyTest
```

Ожидается: 65536 MiB VRAM/BAR1, Gen2 x16, NDIV 70, FBPA masks open и P2P OK.

## Готовые аварийные snapshots на HDD

```text
A Bayley BAR1: A-bayley-current/
B2 Mailbox:    B2-working-mailbox/
```

Каждый содержит пять модулей, initrd, modinfo, SHA256 и контрольную диагностику.

