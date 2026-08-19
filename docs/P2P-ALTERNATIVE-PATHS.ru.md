# CMP 170HX P2P: два рабочих подхода

В сообществе сейчас есть как минимум два реально измеренных способа получить GPU↔GPU обмен на CMP 170HX. Мы сохраняем оба пути, потому что они используют разные механизмы драйвера и могут по-разному вести себя на разных платформах.

> **Важно:** не смешивайте эти два режима вслепую. Наш путь возвращает обычный/default PCIe P2P protocol, а вариант Bayley, наоборот, намеренно форсирует BAR1 P2P.

## Короткое сравнение

| Параметр | Путь A — DEFAULT / mailbox (наш) | Путь B — static BAR1 (`bayley/cmpunlocker`) |
|---|---|---|
| Проверенная конфигурация | 2× CMP 170HX 64 ГБ | 4 карты, позднее 8 карт |
| Драйвер | nvidia-open 610.43.03 | 610.43.03 / 610.43.02 |
| Выбор P2P | `NV_REG_STR_RM_PCIEP2P_TYPE_DEFAULT` | `NV_REG_STR_RM_PCIEP2P_TYPE_BAR1` |
| Нужен BAR1 64 ГБ | Нет на нашей системе | Да |
| Нужен патч ядра Linux | Нет на нашей системе | Да для normal-boot 64 ГБ BAR1 в опубликованной схеме |
| IOMMU | Полностью выключен на нашем рабочем bare-metal тесте | Зависит от схемы/хоста, проверять отдельно |
| ACS | Redirect отключён на нужных root-port | Тоже важен для производительности |
| Скорость в одну сторону | **6.46 / 6.69 GB/s** при Gen2 x16 | **~1.68 GB/s** при Gen2 x4 |
| Bidirectional | **12.90–13.18 GB/s** | зависит от теста/топологии |
| GPU latency | **~1.59–1.65 мкс** | см. upstream тесты |

Цифры нельзя сравнивать напрямую как эффективность реализации: у нас физический x16, а опубликованный Bayley результат получен на x4.

---

# Путь A — DEFAULT / mailbox

Это путь, который мы довели до рабочего состояния в этом репозитории.

База:

- <https://github.com/aikitoria/open-gpu-kernel-modules/tree/610.43.03-p2p>
- использованный P2P commit: `9fb65044`

Исходный P2P diff форсировал BAR1. На нашей GA100/CMP системе часть GA100 path при этом продолжала обращаться к mailbox, который оставался неинициализированным:

```text
mailbox=0xffffffffffffffff
baseMask=0xfff
Assertion failed: ((base & RM_PAGE_MASK) == 0)
```

Наш fix возвращает:

```c
pKernelBif->pcieP2PType = NV_REG_STR_RM_PCIEP2P_TYPE_DEFAULT;
```

Патч:

- [`../patches/p2p-cmp170-mailbox-fix.patch`](../patches/p2p-cmp170-mailbox-fix.patch)

После него debug показал:

```text
mailbox=0x0
baseMask=0x0
```

Assert исчез.

## Главный второй фактор — IOMMU

Даже с исправленным mailbox при активном IOMMU у нас было только:

```text
~0.47–0.49 GB/s
```

После полного отключения IOMMU:

```text
intel_iommu=off iommu=off
```

тот же CUDA-тест дал:

```text
GPU0 -> GPU1: 6.46 GB/s
GPU1 -> GPU0: 6.69 GB/s
Bidirectional: 12.90–13.18 GB/s
GPU latency: 1.59–1.65 us
```

То есть это не просто «CUDA показала OK», а реальный скачок bandwidth больше чем на порядок.

### Плюсы

- На нашей системе не нужен BAR1 64 ГБ.
- Не понадобилось специальное ядро Linux ради BAR sizing.
- Отличная скорость при Gen2 x16.
- Проще диагностировать NVIDIA `p2pBandwidthLatencyTest`.

### Минусы

- На нашем bare-metal хосте IOMMU пришлось выключить полностью.
- Пока подтверждено только на одной dual-CMP системе.
- Другой CPU/root-complex может вести себя иначе.

---

# Путь B — BAR1 P2P от `bayley/cmpunlocker`

Upstream:

- <https://github.com/bayley/cmpunlocker>

Этот вариант специально обходит обычный mailbox/proprietary peer aperture. Peer framebuffer отображается через BAR1 другой карты, а peer PTE переписываются на system coherent/non-coherent aperture с BAR1 bus address.

## Основные патчи драйвера

```text
driver/patches/0011-p2p-bar1.patch
driver/patches/0013-skip-mailbox-peer-preinit.patch
driver/patches/0015-bar1p2p-readcap-override.patch
```

### `0011-p2p-bar1.patch`

Основные идеи:

- включение BAR1 P2P HAL;
- выбор BAR1 P2P для CMP device IDs;
- ветка `_PCIE_BAR1` в GP100-and-later bus path;
- переписывание `GMMU_APERTURE_PEER` в `SYS_COH` / `SYS_NONCOH`;
- адресация через BAR1 bus address удалённой карты.

### `0013-skip-mailbox-peer-preinit.patch`

NVIDIA init заранее создаёт mailbox peer ID. Из-за ненулевого `peerNumberMask` BAR1 P2P отклоняется: RM не хочет одновременно использовать два PCIe P2P protocol.

Патч пропускает эту предварительную mailbox-регистрацию, когда выбран BAR1 P2P.

### `0015-bar1p2p-readcap-override.patch`

На Xeon E5 v4 + PLX драйвер не распознал общий downstream switch и снял read capability. Патч возвращает её для CMP.

Это топологически чувствительное место. На новой плате нужно заново проверять реальные peer reads/writes, а не считать capability универсальной.

## BAR1 64 ГБ и патчи ядра

В Bayley варианте нужен большой static BAR1. Для этого upstream содержит:

```text
kernel-patches/0001-pci-size-bridge-window-for-child-alignment.patch
kernel-patches/0002-pci-quirk-cmp170hx-rebar-early.patch
```

Первый исправляет расчёт больших bridge windows, второй программирует BAR1 64 ГБ достаточно рано — ещё до обычной PCI enumeration.

При большом числе карт резко растут требования к MMIO address space. Для 8-карточной опубликованной системы используются большой BIOS MMIO-high window и `pci=hpmmioprefsize=2T`.

Типичные параметры BAR1-path:

```text
RMForceStaticBar1=1
RMPcieP2PType=1
```

После изменения NVIDIA module options нужен `update-initramfs -u`.

## Опубликованные результаты

Bayley сообщает примерно:

```text
1.68 GB/s в каждую сторону при PCIe Gen2 x4
```

на 4-карточной mesh-конфигурации; позже этот подход был проверен на 8 GPU через два PCIe switch на одном CPU root complex.

Также у них показано влияние ACS: на одном switch после отключения Req/Cmplt redirect скорость внутри switch выросла примерно с 1.20 до 1.68 GB/s.

### Плюсы

- Обходит обычный CMP mailbox peer aperture.
- Проверен на более крупных multi-GPU системах.
- Хорошая альтернатива, если mailbox/default path на конкретном хосте не работает.

### Минусы

- Требует огромного MMIO пространства.
- Нужен BAR1 64 ГБ на каждую карту.
- В опубликованном варианте нужен patched Linux kernel.
- Больше зависимостей от topology/ACS/capability override.

---

# Что пробовать новичку

1. Сначала стабильная разлочка памяти/compute.
2. Потом рабочий Gen2 и проверка `LnkSta`.
3. Если это простой bare-metal хост с двумя картами и отключение IOMMU приемлемо — наш DEFAULT/mailbox path проще как первый вариант.
4. Если карт много, нужен large BAR1 или mailbox path не едет — изучайте Bayley BAR1 P2P.
5. Не накладывайте оба protocol-selection подхода одновременно. Один эксперимент — одно изменение.

## Главное правило проверки

Вот это ещё не результат:

```text
Device=0 CAN Access Peer Device=1
```

Обязательно проверяйте **реальное движение данных**. Минимум — NVIDIA `p2pBandwidthLatencyTest`; для необычных PTE/BAR1 схем желательно ещё alias-proof copy test.

Для сравнимых отчётов сохраняйте:

- `nvidia-smi topo -m`
- `nvidia-smi topo -p2p r/w/p`
- `lspci -vv`
- размер BAR1
- состояние IOMMU
- ACS
- полный bandwidth/latency output
- версию ядра и драйвера.
