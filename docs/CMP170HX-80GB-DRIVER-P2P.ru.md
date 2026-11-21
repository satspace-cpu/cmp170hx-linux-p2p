# CMP 170HX 80 ГиБ: отдельный драйвер NVIDIA 610.57.04, P2P и датчики HBM

[English version](CMP170HX-80GB-DRIVER-P2P.md)

Эта инструкция описывает **проверенную на реальном сервере** конфигурацию для CMP 170HX `10de:20c2`, аппаратно разблокированных методом GA100VFI до 80 ГиБ. Она не предназначена для обычных карт 8 ГБ, программно разлоченных до 64 ГиБ.

Главный принцип: функции разделены между двумя модулями.

- Отдельная сборка NVIDIA Open Kernel Modules `610.57.04` задаёт геометрию 80 ГиБ и управляет CUDA.
- Минимальный companion-модуль на основе `gpu-unlock 3.0.0-beta` открывает P2P и экспортирует температуры HBM, но **не меняет геометрию памяти, BAR1, PCIe, ECC, InfoROM или частоты**.

> Не устанавливайте стандартный профиль `8gb` поверх аппаратной 80-ГиБ карты: в публичном `cmpunlocker` он рассчитан на 64 ГиБ. Также не включайте для этой конфигурации Static BAR1: 64-ГиБ BAR1 при 80-ГиБ framebuffer на нашем стенде приводил к зависанию драйвера и `nvidia-smi`.

## Что проверено

Стенд, на котором получен результат:

- Ubuntu, ядро `7.0.0-42-generic`;
- NVIDIA Open Kernel Modules `610.57.04`;
- 2× CMP 170HX `10de:20c2`, аппаратно разблокированные до `81920 MiB`;
- PCIe Gen2 x16;
- P2P в обе стороны;
- HBM stack sensors A–E и показатель `Hottest`;
- без новых NVIDIA Xid и PCIe AER после тестов.

Проверенные результаты P2P:

```text
nvidia-smi topo -p2p r/w: OK в обе стороны
cudaMemcpyPeer:           PASS в обе стороны
SM remote read:           PASS в обе стороны
SM remote write:          PASS в обе стороны
Одно направление:         5.28–5.30 GB/s
Два направления:          10.27 GB/s
GPU latency:              1.80–1.81 us
```

## 1. Обязательные условия и резервная копия

Нужны аппаратно разблокированная карта, KVM/физический доступ, отключённый Secure Boot, headers текущего ядра и уже установленный userspace NVIDIA `610.57.04`.

Перед изменениями сохраните все пять модулей NVIDIA, initramfs и настройки:

```bash
KVER="$(uname -r)"
BACKUP="$HOME/cmp170-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP/modules" "$BACKUP/config"

for m in nvidia nvidia-modeset nvidia-drm nvidia-uvm nvidia-peermem; do
    p="$(modinfo -n "$m" 2>/dev/null || true)"
    [ -n "$p" ] && cp -a "$p" "$BACKUP/modules/"
done

cp -a /etc/default/grub "$BACKUP/config/" 2>/dev/null || true
cp -a /etc/modprobe.d "$BACKUP/config/" 2>/dev/null || true
cp -a "/boot/initrd.img-$KVER" "$BACKUP/" 2>/dev/null || true
uname -a > "$BACKUP/uname.txt"
nvidia-smi -q > "$BACKUP/nvidia-smi-q.txt"
lspci -nnvv > "$BACKUP/lspci-nnvv.txt"
```

## 2. Чем профиль `20c2-hw80` отличается от обычного `8gb`

Для аппаратно разблокированной `20c2` на нашем стенде использованы:

```text
FBPA CFG1:       0x02779000
MMU/LMR:         0x0000028B
GSP FB length:   0x0000001400000000  (80 GiB)
PCI device ID:   10de:20c2
```

У обычного 64-ГиБ профиля `20c2/8gb` LMR равен `0x0000020B`, а FB length — `0x0000001000000000`. CFG1 остаётся прежним: аппаратный unlock меняет доступный объём, а не размер одного FBPA.

В отдельном профиле должны быть согласованы одновременно:

1. значения CFG1/LMR, записываемые через SEC2/GSP;
2. `GspStaticConfigInfo.fb_length` и последний FB region;
3. WPR/GSP reserved regions;
4. диапазоны heap/PMA;
5. отсутствие 32-битного переполнения и наложения регионов;
6. запрет Static BAR1 и других 64-ГиБ предположений.

Нельзя считать изменение одного числа в `nvidia-smi` достаточной разблокировкой.

## 3. Сборка основного драйвера 610.57.04

Используйте отдельную копию исходников `cmpunlocker`, чтобы не менять рабочий 64-ГиБ профиль. В проверенной ветке сборочный скрипт поддерживал отдельные политики `20c2-hw80`, `local-only`, `preserve` и режим build-only:

```bash
cd /path/to/cmpunlocker-61057-20c2-hw80

sudo env \
  CMPUNLOCKER_CARD_PROFILE=20c2-hw80 \
  CMPUNLOCKER_IO_POLICY=local-only \
  CMPUNLOCKER_PCIE_POLICY=preserve \
  CMPUNLOCKER_DRIVER_VERSION=610.57.04 \
  CMPUNLOCKER_BUILD_ONLY=1 \
  ./driver/build.sh
```

Эти дополнительные профили и переменные относятся к подготовленной ветке
`20c2-hw80`; в обычном upstream `cmpunlocker` их может не быть. Перед сборкой
проверьте `grep -R "20c2-hw80\|CMPUNLOCKER_IO_POLICY" driver common`. Если
совпадений нет, не подставляйте профиль `8gb`: он вернёт 64-ГиБ предположения.

`local-only` означает: не добавлять Static BAR1 и отдельные P2P-патчи в основной NVIDIA-модуль. `preserve` означает: не смешивать эксперимент PCIe с первым запуском 80 ГиБ.

Перед установкой проверьте, что собраны все пять файлов:

```bash
find driver -type f \( \
  -name 'nvidia.ko' -o -name 'nvidia-modeset.ko' -o \
  -name 'nvidia-drm.ko' -o -name 'nvidia-uvm.ko' -o \
  -name 'nvidia-peermem.ko' \) -print
```

Скопируйте их в отдельный каталог `/lib/modules/$(uname -r)/updates/cmpunlocker/`, затем выполните:

```bash
sudo depmod -a
sudo update-initramfs -u -k "$(uname -r)"
sudo reboot
```

Если система фактически создаёт initramfs через dracut, используйте также:

```bash
sudo dracut --force --kver "$(uname -r)"
```

После загрузки:

```bash
modinfo -n nvidia
modinfo -F version nvidia
nvidia-smi --query-gpu=pci.bus_id,name,memory.total,uuid,serial --format=csv
dmesg -T | grep -iE 'SEC2_DEBUG|NVRM|Xid|AER' | tail -200
```

Ожидается `81920 MiB`, но это только первая проверка.

## 4. Обязательная проверка всех 80 ГиБ

До P2P проверьте одну карту отдельно:

1. выделение CUDA-памяти выше 64 ГиБ;
2. запись разных шаблонов ниже и выше границ 40/64/72/79 ГиБ;
3. обратное чтение и сравнение;
4. отсутствие aliasing — запись в верхний адрес не должна менять нижний;
5. полный тест чтения/записи HBM;
6. отсутствие Xid/AER после теста.

Если карта только показывает `81920 MiB`, но верхняя память алиасится, портит данные или недоступна allocator-у, профиль нельзя считать рабочим.

## 5. P2P без Static BAR1

Для 80 ГиБ использован `gpu-unlock 3.0.0-beta` на точном upstream commit `50c30a31f92f37d590bc0047c841cb42c22654c4` и минимальный патч из этого репозитория:

- [`gpu-unlock-3.0.0-beta-20c2-hw80-p2p.patch`](../patches/gpu-unlock-3.0.0-beta-20c2-hw80-p2p.patch)

Патч создаёт отдельное семейство `GA100 CMP 170HX hw80 P2P companion`. Для `20c2` оно открывает только необходимые защищённые разрешения P2P. Оно намеренно не применяет стандартную 64-ГиБ геометрию `cmp170hx_8gb_geometry`, BAR1 resize, PCIe relink, ECC или ROM overrides.

Сборка:

```bash
git clone --branch 3.0.0-beta https://github.com/Zagitta/gpu-unlock.git
cd gpu-unlock
git checkout 50c30a31f92f37d590bc0047c841cb42c22654c4
git apply --check --unidiff-zero /path/to/cmp170hx-linux-p2p/patches/gpu-unlock-3.0.0-beta-20c2-hw80-p2p.patch
git apply --unidiff-zero /path/to/cmp170hx-linux-p2p/patches/gpu-unlock-3.0.0-beta-20c2-hw80-p2p.patch

make assets
make -C kernel/gpu_unlock -j"$(nproc)"
```

В upstream `gpu-unlock` номер `610.43.03` относится к пакету, из которого
извлекаются подписанные firmware assets companion-модуля. Основной NVIDIA
драйвер на проверенном стенде оставался `610.57.04`.

Установите firmware, overrides и интеграцию именно вашего генератора initramfs. На проверенном сервере использовался dracut:

```bash
sudo make ASSETS="$HOME/.cache/gpu-unlock/assets" \
  install-firmware install-overrides install-dracut

sudo install -D -m 0644 kernel/gpu_unlock/gpu_unlock.ko \
  "/lib/modules/$(uname -r)/updates/gpu-unlock-monitor/gpu_unlock.ko"
sudo depmod -a
```

Для `initramfs-tools` вместо `install-dracut` используйте `install-initramfs-tools`.

## 6. Параметры загрузки и выбор карт

Узнайте PCI-адреса:

```bash
nvidia-smi --query-gpu=pci.bus_id,uuid,serial --format=csv
```

Добавьте в существующую строку `GRUB_CMDLINE_LINUX_DEFAULT`:

```text
gpu_unlock.targets=0000:81:00.0,0000:82:00.0 gpu_unlock.hbm_governor=0 gpu_unlock.resume=0
```

Замените BDF на адреса своих карт. После перестановки карты в другой слот этот список нужно изменить.

`hbm_governor=0` оставляет управление частотой HBM программе `170tune`. `resume=0` отключает непроверенный повторный unlock после сна. Датчики температур при этом продолжают работать.

Примените загрузочную конфигурацию:

```bash
sudo update-grub
sudo update-initramfs -u -k "$(uname -r)"
# Если initramfs создаёт dracut:
sudo dracut --force --kver "$(uname -r)"
sudo reboot
```

Не добавляйте:

```text
RMForceStaticBar1=1;RMPcieP2PType=1
```

Эти ключи относятся к отдельной проверенной 64-ГиБ схеме [Static BAR1](STATIC-BAR1-P2P.ru.md), а не к 80-ГиБ профилю.

## 7. Проверка P2P и температур

Сначала проверьте раннюю загрузку companion-модуля:

```bash
cat /proc/cmdline
lsmod | grep gpu_unlock
dmesg -T | grep -i gpu_unlock
```

Затем:

```bash
nvidia-smi topo -m
nvidia-smi topo -p2p r
nvidia-smi topo -p2p w
```

`OK` — необходимое, но недостаточное условие. Обязательно запустите тест, который сравнивает содержимое после `cudaMemcpyPeer`, SM remote read и SM remote write в обе стороны. Только затем измеряйте `p2pBandwidthLatencyTest`.

После теста:

```bash
dmesg -T | grep -iE 'NVRM|Xid|AER|pcie.*error' | tail -200
```

Температуры HBM:

```bash
sudo install -m 0755 scripts/cmp-hbm-temp.sh /usr/local/bin/cmp-hbm-temp
cmp-hbm-temp
```

`Hottest` — это максимум среди реальных датчиков стеков HBM, а не отдельный физический датчик.

## 8. Откат

При зависании `nvidia-smi`, Xid, aliasing или ошибке верхней памяти:

1. загрузитесь через KVM/recovery;
2. удалите `gpu_unlock.targets=...` из параметров ядра;
3. восстановите сохранённые пять модулей NVIDIA;
4. удалите или замените `gpu_unlock.ko`;
5. выполните `depmod`, пересоберите GRUB/initramfs и перезагрузитесь.

Не пытайтесь лечить зависание дополнительными регистрами, Static BAR1, прошивкой VBIOS или записью InfoROM.

## Важные ограничения

- Метод проверен на конкретных аппаратно разблокированных `10de:20c2`; он не превращает обычную 64-ГиБ карту в 80-ГиБ.
- P2P зависит от PCIe topology, root complex, ACS/IOMMU и должен проверяться для каждой направленной пары.
- Новый secure mailbox/permission path в `gpu-unlock 3.0` не следует путать со старым Mailbox B2 из истории этого проекта. Старый путь дал ложноположительный benchmark; новый прошёл проверку содержимого.
- Не включайте ECC/InfoROM только ради P2P.
- После обновления ядра оба внешних модуля нужно пересобрать.
- `gpu-unlock 3.0.0-beta` — beta-код; сохраняйте точный commit и рабочий rollback.

## Источники

- [cmpunlocker](https://github.com/amoghmunikote/cmpunlocker)
- [gpu-unlock 3.0.0-beta](https://github.com/Zagitta/gpu-unlock/tree/3.0.0-beta)
- [Проверенный Static BAR1 для 64 ГиБ](STATIC-BAR1-P2P.ru.md)
- [Диагностика и исключение дефектной страницы HBM](HBM-PAGE-RETIREMENT.ru.md)
