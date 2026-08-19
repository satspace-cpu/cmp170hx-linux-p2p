# CMP 170HX Linux: полный путь от разлочки до 170tune и рабочего CUDA P2P

[English](README.md) · [Тесты](docs/BENCHMARKS.md) · [Решение проблем](docs/TROUBLESHOOTING.md)

Это пошаговая инструкция для человека, который только купил NVIDIA CMP 170HX и хочет пройти весь путь без необходимости разбираться в исходниках драйвера с нуля.

Мы документируем именно тот путь, который проверили на нашей системе:

**стоковая CMP 170HX → разлочка памяти/вычислений → проверка и тюнинг через 170tune → PCIe Gen2 x16 → рабочий CUDA P2P → тесты multi-GPU LLM**

> **Наш результат на 2× CMP 170HX по 64 ГБ:** ~6.46–6.69 GB/s в одну сторону, ~12.90–13.18 GB/s bidirectional и ~1.59–1.65 мкс GPU-to-GPU latency через PCIe Gen2 x16.

---

## С чего начать

Работа с CMP 170HX экспериментальная. Здесь меняются модули ядра NVIDIA, параметры загрузки Linux и, при желании, частоты/напряжение/память. Желательно иметь SSH/удалённый доступ или физический доступ к машине и менять **по одному параметру за раз**.

Репозиторий не распространяет проприетарные бинарники NVIDIA. Здесь только документация, небольшие патчи и скрипты вокруг открытых проектов сообщества.

### Три этапа

1. **Разлочить карту** через `cmpunlocker` — вернуть вычислительную производительность и полную геометрию HBM. Для распространённой 8 ГБ версии мы получили **64 ГБ видимой HBM2e**.
2. **Проверить и настроить через 170tune** — необязательный, но очень полезный этап. Главная ценность 170tune не в разгоне, а в проверке на тихую порчу данных.
3. **Включить и проверить P2P** — применить P2P-модификацию, наш CMP/GA100 mailbox fix, отключить IOMMU на bare metal и проверить реальную скорость CUDA P2P.

Не начинайте с P2P на стоковой 8 ГБ карте. Сначала добейтесь стабильной разлочки.

---

# Этап 1 — Разлочка CMP 170HX

## Основные проекты

- **cmpunlocker (оригинальный проект):** https://github.com/amoghmunikote/cmpunlocker
- **Подробная документация по CMP 170HX:** https://github.com/Consensus-Protocol/cmp170hx

Текущий `cmpunlocker` рассчитан на Linux x86-64, NVIDIA Open Kernel Modules ветки 610.43.0x, совпадающие headers ядра и отключённый Secure Boot. После установки нужен холодный перезапуск питания.

### Что получается после разлочки

| Исходная карта | Профиль | Ожидаемая видимая память |
|---|---|---:|
| CMP 170HX 8 ГБ (`10de:20c2`) | `8gb` | **64 ГБ** |
| CMP 170HX 10 ГБ (`10de:2082`) | `10gb` | **40 ГБ** |

Это не прошивка VBIOS. Разлочка выполняется через пропатченные NVIDIA Open GPU Kernel Modules.

## 1. Подготовить Linux

Для Debian/Ubuntu:

```bash
sudo apt update
sudo apt install -y git curl patch build-essential python3 linux-headers-$(uname -r)
```

Проверить Secure Boot:

```bash
mokutil --sb-state 2>/dev/null || true
```

Проверить ядро и драйвер:

```bash
uname -r
nvidia-smi
modinfo -F version nvidia
```

На нашей рабочей конфигурации мы зафиксировали **NVIDIA Open Kernel Modules 610.43.03**.

## 2. Скачать cmpunlocker

```bash
git clone https://github.com/amoghmunikote/cmpunlocker.git
cd cmpunlocker
```

Перед установкой полезно прочитать README автора:

```bash
less README.md
```

## 3. Установить разлочку

Для 8 ГБ карты → 64 ГБ:

```bash
sudo ./install.sh --profile=8gb
```

Для 10 ГБ карты → 40 ГБ:

```bash
sudo ./install.sh --profile=10gb
```

Если версия cmpunlocker корректно определяет вашу карту автоматически:

```bash
sudo ./install.sh
```

## 4. Сделать холодный перезапуск

```bash
sudo shutdown -h now
```

Полностью отключите питание, подождите несколько секунд и включите компьютер снова.

## 5. Проверить результат

```bash
nvidia-smi
nvidia-smi --query-gpu=index,name,memory.total,pci.bus_id --format=csv
```

Наши 8 ГБ карты после разлочки показывают:

```text
NVIDIA CMP 170HX, 65536 MiB
```

Если память осталась стоковой — **не переходите дальше**, сначала разберитесь с разлочкой.

Подробнее: [docs/UNLOCK.md](docs/UNLOCK.md)

---

# Этап 2 — 170tune: тюнинг и проверка стабильности

## Оригинальный проект

- **170tune:** https://github.com/cachenetics/170tune
- **Подробный tuning guide:** https://github.com/cachenetics/170tune/blob/main/docs/tuning-guide.md

`170tune` не выполняет саму разлочку памяти. Это инструмент для настройки и проверки CMP 170HX после разлочки: SM clock/voltage, HBM clock, timings, сохранение профилей и восстановление.

### Почему он важен

У CMP 170HX опасный режим нестабильности — **тихая порча данных**. Карта может не упасть, не показать Xid, успешно закончить benchmark, но вернуть неправильные данные. Поэтому принцип 170tune правильный: «benchmark закончился» ещё не означает «настройка стабильна».

## 1. Добавить `iomem=relaxed`

170tune использует доступ к BAR0 из userspace и требует `iomem=relaxed`.

Открываем GRUB:

```bash
sudo nano /etc/default/grub
```

Добавляем `iomem=relaxed` в существующую строку `GRUB_CMDLINE_LINUX_DEFAULT`, например:

```text
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash iomem=relaxed"
```

Позже для P2P у нас в этой же строке будут `intel_iommu=off iommu=off`. Все параметры должны оставаться внутри одной пары кавычек.

Применяем:

```bash
sudo update-grub
sudo reboot
```

Проверяем:

```bash
cat /proc/cmdline
```

## 2. Установить 170tune

```bash
git clone https://github.com/cachenetics/170tune.git
cd 170tune
sudo ./install.sh
```

## 3. Сначала preflight

```bash
sudo 170tune preflight
```

Не начинайте разгон, пока не понимаете все предупреждения preflight.

## 4. Сохранить стоковые значения карты

На стоковых настройках:

```bash
sudo 170tune snapshot-stock
```

Это создаёт базовую точку возврата именно для вашей карты.

## 5. Не копировать чужой разгон вслепую

У 170tune есть хорошие референсные профили, но разные экземпляры CMP и HBM ведут себя по-разному.

Полезный ориентир из upstream:

- для serving: **NDIV 70**, stock timings, `REFRESH 24`, активное охлаждение с контролем температуры HBM;
- более высокие значения могут хорошо выглядеть в synthetic benchmark, но давать corruption/crash под реальной нагрузкой.

Это **не готовая настройка для каждой карты**. Перед сохранением профиля используйте `gate`, `hbm-gate` и реальную нагрузку.

### Что подтверждено у нас

На нашей системе:

- 2× CMP 170HX 8 ГБ успешно разлочены до **64 ГБ каждая**;
- обе карты работают на **PCIe Gen2 x16** после отдельной аппаратной переделки линий x16;
- на наших картах удалось использовать **power limit 300 W**, но мы не объявляем это универсальной безопасной настройкой;
- для LLM важнее стабильность и отсутствие corruption, чем максимальный synthetic score.

Мы специально **не публикуем один «магический безопасный OC» для всех CMP 170HX**.

Подробнее: [docs/170TUNE.md](docs/170TUNE.md)

---

# Этап 3 — Настоящий CUDA P2P между CMP 170HX

Этот этап нужен владельцам двух и более карт для прямого GPU↔GPU обмена, например для `llama.cpp` tensor split.

## Базовая P2P-разработка

Наша работа основана на экспериментальном P2P-коде:

- **aikitoria/open-gpu-kernel-modules, ветка 610.43.03-p2p:** https://github.com/aikitoria/open-gpu-kernel-modules/tree/610.43.03-p2p

В тестах мы использовали базовую комбинированную P2P-модификацию на основе commit `9fb65044`.

Сверху мы добавили исправление конкретно для CMP/GA100:

- [patches/p2p-cmp170-mailbox-fix.patch](patches/p2p-cmp170-mailbox-fix.patch)

## Что было сломано

Базовая P2P-модификация форсировала:

```c
pKernelBif->pcieP2PType = NV_REG_STR_RM_PCIEP2P_TYPE_BAR1;
```

На нашей GA100/CMP 170HX это отключало обычное выделение mailbox, хотя другой участок GA100 P2P-path продолжал mailbox использовать.

В диагностическом драйвере мы получили:

```text
mailbox=0xffffffffffffffff
baseMask=0xfff
Assertion failed: ((base & RM_PAGE_MASK) == 0)
```

Наш fix возвращает:

```c
pKernelBif->pcieP2PType = NV_REG_STR_RM_PCIEP2P_TYPE_DEFAULT;
```

После этого:

```text
mailbox=0x0
baseMask=0x0
```

assert исчез.

## Второй тормоз — IOMMU

После mailbox fix P2P всё ещё давал только:

```text
~0.47–0.49 GB/s
```

Пока IOMMU оставался активным.

На bare-metal системе мы полностью отключили IOMMU:

```text
intel_iommu=off iommu=off
```

Наша итоговая строка GRUB также сохраняет `iomem=relaxed` для 170tune и наши board-specific ACS-параметры:

```text
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash iomem=relaxed intel_iommu=off iommu=off pci=disable_acs_redir=0000:80:02.0 pci=disable_acs_redir=0000:80:03.0"
```

**Не копируйте `80:02.0` и `80:03.0`!** Это адреса root-port именно нашей платы.

Отключение IOMMU влияет на DMA isolation, виртуализацию и PCI passthrough. Это осознанный компромисс для bare-metal P2P-системы.

## Проверить ACS на своей плате

Топология:

```bash
lspci -t
```

ACS конкретного root-port:

```bash
sudo lspci -vv -s <ROOT_PORT> | grep -E 'ACSCap|ACSCtl'
```

В нашей рабочей конфигурации redirect-биты на нужных root-port отключены.

## Проверить P2P

```bash
nvidia-smi topo -p2p r
nvidia-smi topo -p2p w
nvidia-smi topo -p2p p
```

Между картами должно быть `OK`.

Но **`OK` ещё не доказывает, что P2P быстрый**. У нас CUDA уже показывала доступ, когда реальная скорость была ужасной.

Поэтому обязательно запускайте NVIDIA `p2pBandwidthLatencyTest`.

### Наш итоговый результат

```text
Unidirectional P2P Enabled:
GPU0 -> GPU1: 6.46 GB/s
GPU1 -> GPU0: 6.69 GB/s

Bidirectional P2P Enabled:
12.90–13.18 GB/s

GPU latency:
1.59–1.65 us
```

А сломанный P2P на той же системе давал:

```text
0.29–0.49 GB/s
```

### Таблица до/после

| Показатель | P2P выключен | P2P сломан | P2P работает |
|---|---:|---:|---:|
| 0→1 | ~5.88 GB/s | ~0.29–0.47 GB/s | **6.46 GB/s** |
| 1→0 | ~5.94 GB/s | ~0.29–0.49 GB/s | **6.69 GB/s** |
| Bidirectional | ~8.1–8.3 GB/s | ~0.5–0.9 GB/s | **12.90–13.18 GB/s** |
| GPU latency | десятки мкс без peer path | ~1.6–1.9 мкс | **~1.6 мкс** |

Все замеры: [docs/BENCHMARKS.md](docs/BENCHMARKS.md)

---

# Что получилось в LLM

Изначальная цель проекта — multi-GPU local LLM.

После окончательного P2P fix при `llama.cpp` tensor split загрузка обеих CMP стала **заметно ровнее**, исчезла прежняя «пила» по GPU utilization. Первые замеры reasoning-generation на тестируемой модели были примерно **48–62 ток/с**. Скорость зависит от модели, кванта, контекста и split mode, поэтому доказательством самого P2P мы считаем CUDA bandwidth/latency, а LLM-бенчмарки будем добавлять отдельно.

---

# Порядок действий для новичка

1. Поставить Linux и совместимый NVIDIA Open Kernel Driver.
2. Проверить карту в стоке.
3. Установить `cmpunlocker`.
4. Сделать cold power-cycle.
5. Проверить 64/40 ГБ памяти.
6. Установить `170tune`, выполнить `preflight` и `snapshot-stock`.
7. Любой разгон проверять на **своей карте**, а не копировать слепо.
8. Проверить ширину/скорость PCIe через `lspci -vv`.
9. Только потом добавлять P2P-модификацию и наш mailbox fix.
10. Если система bare-metal и это допустимо — отключить IOMMU.
11. Проверить ACS и PCIe topology.
12. Проверить `nvidia-smi topo -p2p`.
13. Обязательно запустить `p2pBandwidthLatencyTest`.
14. После этого уже мерить реальную задачу: `llama.cpp`, vLLM, CUDA и т. п.

---

# Полезные файлы

- [Разлочка](docs/UNLOCK.md)
- [170tune](docs/170TUNE.md)
- [Установка/проверка P2P](docs/INSTALL.md)
- [Как мы нашли и исправили P2P bug](docs/P2P-EXPLAINED.md)
- [Все тесты](docs/BENCHMARKS.md)
- [Troubleshooting](docs/TROUBLESHOOTING.md)
- [Наш mailbox patch](patches/p2p-cmp170-mailbox-fix.patch)
- [Patch notes](patches/README.md)
- [Raw успешного P2P-теста](results/dual-cmp170hx-610.43.03.txt)

Проверка системы без изменений:

```bash
bash scripts/check-p2p.sh
```

Сбор отчёта для issue:

```bash
bash scripts/collect-debug-info.sh
```

---

## Статус проекта

Полная цепочка пока подтверждена на **одной системе с двумя CMP 170HX**. Нам нужны результаты других владельцев карт.

Если у вас получилось повторить — создайте Issue и приложите модель платы, ядро, драйвер, `lspci` topology и полный вывод `p2pBandwidthLatencyTest`.

## Благодарности

Обязательно ставьте звёзды и благодарите оригинальных авторов:

- https://github.com/amoghmunikote/cmpunlocker
- https://github.com/Consensus-Protocol/cmp170hx
- https://github.com/cachenetics/170tune
- https://github.com/aikitoria/open-gpu-kernel-modules/tree/610.43.03-p2p
- NVIDIA CUDA Samples

## Лицензия

Наша документация и наши скрипты распространяются под [MIT License](LICENSE). Исходники NVIDIA и Open GPU Kernel Modules остаются под лицензиями соответствующих upstream-проектов.
