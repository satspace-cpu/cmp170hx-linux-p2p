# Исходники и режим сборки Static BAR1

[English version](README.md) · [Проверенный результат](../../docs/STATIC-BAR1-P2P.ru.md)

Этот каталог хранит воспроизводимую схему **Static BAR1**. Он намеренно отделён
от `../mailbox-b2/`: Mailbox B2 — только исторический артефакт и не должен
использоваться как P2P transport.

## Откуда берутся исходники

| Компонент | Точный источник |
|---|---|
| Static BAR1 и серия патчей | [bayley/cmpunlocker, commit `2a1a46389c36c2bf8a2d451855bdf34d5b4e616b`](https://github.com/bayley/cmpunlocker/commit/2a1a46389c36c2bf8a2d451855bdf34d5b4e616b) |
| Исходники драйвера | [NVIDIA Open GPU Kernel Modules `610.57.04`](https://github.com/NVIDIA/open-gpu-kernel-modules/tree/610.57.04) |
| Сохранённые CMP unlock hooks, исходники и патчи | [`../mailbox-b2/source/`](../mailbox-b2/source/) |
| Реальные тесты Static BAR1 | [`../../docs/STATIC-BAR1-P2P.ru.md`](../../docs/STATIC-BAR1-P2P.ru.md) |

Полное дерево NVIDIA Open GPU Kernel Modules загружается с официального тега
при сборке. Репозиторий не зеркалирует многогигабайтный upstream-tarball.
Полный локальный исходник CMP-разлочки уже сохранён по указанному пути:
`src/cmpunlock.c`, `src/cmpunlock.h`, `build.sh`, BAR1-патчи и kernel-патчи.

## Режим Static BAR1

Режим определяется всеми условиями сразу:

```text
CMPUNLOCKER_ENABLE_P2P=1
накладываются: 0011-p2p-bar1.patch
накладываются: 0013-skip-mailbox-peer-preinit.patch
накладываются: 0015-bar1p2p-readcap-override.patch
НЕ накладывается: 0012-mailbox-default.patch
параметры модуля: RMForceStaticBar1=1;RMPcieP2PType=1
```

`0012-mailbox-default.patch` намеренно исключён: он возвращает
`pcieP2PType` к default/mailbox protocol и отменяет Static BAR1-выбор из
`0011`.

## Только сборка

Обёртка создаёт отдельную копию сохранённых исходников, удаляет только
mailbox-selection патч, добавляет известную версию 610.57.04 и запускает
штатный `build.sh`. Она **не устанавливает** модули и не перезагружает сервер.

```bash
git clone https://github.com/satspace-cpu/cmp170hx-linux-p2p.git
cd cmp170hx-linux-p2p

sudo env \
  CMPUNLOCKER_DRIVER_VERSION=610.57.04 \
  CMPUNLOCKER_KVER="$(uname -r)" \
  ./recovery/static-bar1/build-static-bar1.sh
```

В конце будет выведен путь к результату. До установки проверьте `vermagic`:

```bash
modinfo recovery/static-bar1/work/.build/open-gpu-kernel-modules-610.57.04/kernel-open/nvidia.ko \
  | grep -E 'version|vermagic'
```

## Конфигурация модуля

Установите `modprobe-static-bar1.conf` как единственный авторитетный файл
`options nvidia`. При объединении сохраните работающие Gen2-параметры именно
вашего хоста; не создавайте конкурирующие `NVreg_RegistryDwords` в разных
файлах.

```bash
sudo install -m 0644 recovery/static-bar1/modprobe-static-bar1.conf \
  /etc/modprobe.d/cmp-static-bar1.conf
```

`RMPcieLinkSpeed=0x5` и `NVreg_EnablePCIeGen3=1` взяты с проверенного Gen2
хоста; их нельзя считать универсальными.

## Установка и проверка

1. Сохраните пять текущих `nvidia*.ko`, initramfs и конфигурацию модуля.
2. Скопируйте пять `.ko` из результата сборки в активный module directory.
3. Выполните `depmod -a`, пересоберите initramfs и перезагрузитесь.
4. Ограничьте CUDA заведомо нужной парой, например:

   ```bash
   CUDA_VISIBLE_DEVICES=1,2 ./p2pBandwidthLatencyTest
   ```

5. Требуйте content-check вместе с CUDA sample. Ожидаемые результаты и сырые
   логи находятся в указанном выше проверенном отчёте.

Никогда не считайте P2P рабочим только по `nvidia-smi topo`.
