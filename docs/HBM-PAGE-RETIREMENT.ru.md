# Однобитные ошибки HBM на CMP 170HX: поиск физической страницы и программное исключение

Эта статья описывает реальный случай с CMP 170HX / GA100, когда повторяемая
однобитная ошибка была привязана к одной физической странице PMA, после чего
страница была исключена из новых выделений небольшим патчем NVIDIA Open Kernel
Module.

Метод экспериментальный. Он полезен, когда после `cmpunlocker` карта показывает
расширенный объём памяти, но драйвер сообщает `ECC: N/A`, `Retired Pages: N/A` и
`Remapped Rows: N/A`. Это не ремонт карты и не замена аппаратного ремонта. Перед
работой обязательно сохраните рабочий модуль и обеспечьте доступ через KVM или
физическую консоль.

## Результат на эталонной системе

Проблемное устройство:

```text
GPU1, PCI 0000:83:00.0, GA100 / CMP 170HX
Драйвер: 610.57.04
Ядро: 7.0.12-cmp170bar1test
Видимая память: 65536 MiB
```

Повторяемая ошибка `INITIAL_READ`:

```text
0xABA44765C..=0xABA44765F
```

Этот адрес — смещение внутри текущего Vulkan-буфера теста, а не физический
адрес HBM.

Трассировка драйвера показала единственный разрыв физической непрерывности:

```text
logical=0xF0000  previous physical=0x129F0000  next physical=0x12C00000
```

Перевод адреса ошибки:

```text
physical = 0x12C00000 + (0xABA44765C - 0xF0000)
         = 0xACCF5765C
```

PMA использует страницу размером 64 КиБ, поэтому базовый адрес исключённой
страницы:

```text
0xACCF50000  (64 КиБ)
```

Ошибка находилась внутри неё на смещении `0x765C`. После исключения страницы
пятиминутный `memtest_vulkan` завершился с `PASS`; тест успел пройти более 1 800
итераций без ошибки. До исключения та же ошибка появлялась примерно на
итерациях 8–47.

Из 64 ГиБ удалена одна страница 64 КиБ: одна часть из 1 048 576, или примерно
0,000095%. Поэтому `nvidia-smi` по-прежнему показывает 65536 MiB — потеря меньше
его отображаемой точности.

## Почему адрес из memtest нельзя сразу вставлять в blacklist

Исходник `memtest_vulkan` v0.5.0 показывает, что программа:

- работает с Vulkan-буфером и печатает байтовое смещение внутри этого буфера;
- использует `ELEMENT_SIZE = 4` байта;
- печатает диапазон от `buf_offset + idx * 4` до последнего байта ошибочного
  32-битного слова;
- помечает `INITIAL_READ` как чтение после первоначальной записи окна;
- не получает физический адрес framebuffer через `vkGetBufferDeviceAddress` или
  специальный API NVIDIA.

Это подтверждается экспериментом: если сначала занять 8 или 16 ГиБ, адрес
ошибки меняется. Меняется расположение тестового выделения, а не физическое
место дефекта. Поэтому адрес вроде `0xABA44765C` нельзя напрямую использовать
как адрес страницы HBM.

## 1. Сначала сохранить read-only baseline

Определяйте карту по PCI BDF, а не только по номеру GPU: нумерация CUDA и Vulkan
может отличаться.

```bash
uname -a
cat /proc/cmdline
nvidia-smi -L
nvidia-smi --query-gpu=index,pci.bus_id,name,memory.total,memory.used,temperature.memory,power.limit --format=csv
nvidia-smi -q -i 1
lspci -vv -s 83:00.0
nvidia-smi topo -m
modinfo nvidia
modinfo nvidia | grep -iE 'ecc|retir|black|remap|memory|page'
lsmod | grep nvidia
sudo dmesg | grep -iE 'NVRM|Xid|ECC|retir|blacklist|remap' | tail -100
```

Сохраните рабочий модуль до установки любой новой версии:

```bash
KVER=$(uname -r)
mkdir -p ~/cmp170-rollback
sudo cp -a /lib/modules/$KVER/updates/cmpunlocker/nvidia.ko ~/cmp170-rollback/
sha256sum /lib/modules/$KVER/updates/cmpunlocker/nvidia.ko \
  | tee ~/cmp170-rollback/nvidia.ko.sha256
```

Хеш исходного модуля в нашем случае:

```text
efce1c41578025c0d3f99adba763a5f4cd3b3b0285e5219f8f9dc225cb19d9ba
```

## 2. Зафиксировать повторяемую ошибку

Сначала проверяйте без `gpu-burn` и без параллельной вычислительной нагрузки,
чтобы не смешивать дефект с нагревом и конкурирующими выделениями:

```bash
cd ~
./memtest_vulkan 1
```

Записывайте не только адрес, но и:

- номер GPU и PCI BDF;
- режим (`INITIAL_READ` или другой);
- диапазон ошибки, включая оба конца;
- статистику битов и номер итерации;
- температуру HBM и power limit;
- меняется ли адрес после предварительного выделения.

Для проверки влияния аллокатора можно отдельным небольшим CUDA Runtime
процессом выполнить `cudaSetDevice(1)`, `cudaMalloc(8ULL << 30)` и ожидание.
При завершении процесс обязан освободить память. Изменение адреса теста доказывает
изменение размещения, но не является ремонтом и не доказывает, что занятый
диапазон содержит плохую страницу.

## 3. Проверить, что штатный retirement недоступен

На этой CMP-конфигурации:

```text
ECC: N/A
Retired Pages: N/A
Remapped Rows: N/A
```

В журнале также не было Xid/ECC-события, соответствующего порче данных
`memtest_vulkan`. В исходнике 610.57.04 функция GA100 чтения blacklist сначала
требует включённую поддержку page retirement. Для используемого GSP-клиента
`gpuCheckPageRetirementSupport_HAL()` возвращает false, поэтому обычный путь
RM/GSP не работает.

`NVreg_GpuBlacklist` к этой задаче отношения не имеет: он исключает целый GPU по
UUID, а не страницу HBM. Не используйте его для retirement памяти.

Доступные пользовательские controls позволяют получать список offlined pages,
но не дают поддерживаемой команды для назначения произвольной локальной HBM
страницы. Controls для физических страниц, видимые из userspace, относятся к
системной памяти, а не к локальной PMA-памяти GPU.

## 4. Добавить временную трассировку физического отображения

Используйте точный исходник 610.57.04 и тот же набор CMP/P2P-патчей, на котором
собран рабочий модуль. Не смешивайте другую ветку NVIDIA с текущим модулем.

Связь уровней такая:

```text
pmaAllocatePages() возвращает физические адреса страниц PMA
        ↓
memdescFillPages() записывает pPages[i] в PTE-массив дескриптора
        ↓
Vulkan-выделение видит эти записи в логическом порядке
```

В `src/nvidia/src/kernel/gpu/mem_mgr/mem_desc.c` добавьте временный read-only
лог в `memdescFillPages()` до раннего выхода dynamic-granularity. Для больших
выделений посчитайте разрывы и напечатайте начало логического диапазона, первый
и последний физический адрес, размер страницы и каждый разрыв:

```c
if (((NvU64)pageCount * pageSize) >= (256ULL * 1024ULL * 1024ULL))
{
    NvU32 discontinuities = 0;

    for (i = 1; i < pageCount; i++)
    {
        if (pPages[i] != (pPages[i - 1] + pageSize))
        {
            discontinuities++;
            NV_PRINTF(LEVEL_ERROR,
                      "HBM_DIAG break md=%p logical=0x%llx prev=0x%llx next=0x%llx\n",
                      pMemDesc, ((NvU64)(pageIndex + i) * pageSize),
                      pPages[i - 1], pPages[i]);
        }
    }

    NV_PRINTF(LEVEL_ERROR,
              "HBM_DIAG map md=%p logical=0x%llx count=0x%x page=0x%llx first=0x%llx last=0x%llx breaks=0x%x\n",
              pMemDesc, ((NvU64)pageIndex * pageSize), pageCount,
              pageSize, pPages[0], pPages[pageCount - 1], discontinuities);
}
```

Трасса ничего не меняет в аллокаторе и не должна писать BAR-регистры, VBIOS или
частоты HBM. Перед контролируемым тестом можно очистить kernel log, затем
сопоставить логическое смещение ошибки с записями `HBM_DIAG`.

Для расчёта используйте отображение 64 КиБ. Дополнительный дескриптор с
страницами 4 КиБ может описывать то же выделение; это особенность представления,
а не второй физический дефект.

## 5. Безопасно собрать диагностический модуль

Собирайте против headers текущего ядра. Сначала сохраните рабочий модуль:

```bash
make clean
make -j"$(nproc)" modules SYSSRC="/lib/modules/$(uname -r)/build"
```

Перед установкой проверьте версию и строку диагностики:

```bash
modinfo kernel-open/nvidia.ko | grep -E '^(version|srcversion):'
strings kernel-open/nvidia.ko | grep HBM_DIAG
```

Установка только после создания rollback-копии:

```bash
KVER=$(uname -r)
sudo install -m 0644 kernel-open/nvidia.ko \
  /lib/modules/$KVER/updates/cmpunlocker/nvidia.ko
sudo depmod -a "$KVER"
sudo update-initramfs -u -k "$KVER"
```

Важно: при загрузке система может брать модуль из initramfs, поэтому замены файла
в `/lib/modules` недостаточно. Проверьте, что в initramfs есть строка `HBM_DIAG`,
после чего перезагрузите сервер. KVM или физическая консоль обязательны: ошибка
модуля может сделать headless-сервер недоступным по SSH.

## 6. Добавить статический blacklist только для одной карты

Когда физическая страница известна, в GA100-функцию чтения blacklist версии
610.57.04 можно добавить один synthetic offlined-page entry. Вставьте
case-specific блок в начало `memmgrGetBlackListPages_GA100()` в файле
`mem_mgr_ga100.c`:

```c
/* CMP170 GPU1 (0000:83:00.0): case-specific 64 KiB HBM retirement. */
if (gpuGetBus(pGpu) == 0x83)
{
    if (*pCount < 1)
        return NV_ERR_BUFFER_TOO_SMALL;

    pBlAddrs[0].address = 0x0000000ACCF50000ULL;
    pBlAddrs[0].type = NV2080_CTRL_FB_OFFLINED_PAGES_SOURCE_DPR_DBE;
    *pCount = 1;
    NV_PRINTF(LEVEL_ERROR,
              "HBM_BLACKLIST GPU bus 0x83 physical 0xACCF50000 (64 KiB) enabled\n");
    return NV_OK;
}
```

Это не универсальный патч. Для другой карты нужно изменить PCI-селектор и
физический адрес. Адрес из `memtest_vulkan` без mapping trace недействителен.
Если на одной PCI-шине несколько устройств, сопоставляйте полный domain/bus/
device/function, а не только номер шины.

После сборки и обновления initramfs перезагрузитесь. В журнале должна появиться
строка:

```text
HBM_BLACKLIST GPU bus 0x83 physical 0xACCF50000 (64 KiB) enabled
```

Она подтверждает, что GPU1 приняла запись на старте. Главная функциональная
проверка — тест выделения: PMA не должен вернуть эту страницу новому клиенту.

## 7. Проверка результата

```bash
cd ~
./memtest_vulkan 1
```

Патч можно считать подтверждённым, если:

- стандартный пятиминутный тест печатает `PASS`;
- прежняя фиксированная ошибка не появляется;
- тест проходит диапазон итераций, на котором раньше падал;
- GPU0 и остальные CMP по-прежнему видны и проходят контроль;
- `nvidia-smi` показывает ожидаемую геометрию памяти и нет нового Xid;
- после завершения теста память возвращается к idle-уровню.

В эталонном прогоне появилась строка `Standard 5-minute test PASSed!`, было
пройдено более 1 800 итераций без прежней ошибки. Температура GPU1 во время
теста достигла примерно 67 °C. Версия драйвера осталась 610.57.04, а видимая
память — 65536 MiB.

Патч не ремонтирует ячейку HBM и не выполняет hardware row remapping. Он только
не даёт аллокатору выдавать одну страницу. Новая ошибка на другой физической
странице потребует нового mapping trace; несколько дефектов — основание для
замены или изоляции карты.

## Откат

Если драйвер не загрузился, GPU исчезла или появился новый Xid, восстановите
сохранённый модуль и initramfs:

```bash
KVER=$(uname -r)
sudo install -m 0644 ~/cmp170-rollback/nvidia.ko \
  /lib/modules/$KVER/updates/cmpunlocker/nvidia.ko
sudo depmod -a "$KVER"
sudo update-initramfs -u -k "$KVER"
sudo reboot
```

Не удаляйте каталог `cmpunlocker`, не ставьте поверх него generic NVIDIA package
и не используйте `NVreg_ExcludedGpus` для исключения страницы. Вместе с модулем
храните исходник, патчи, kernel command line и хеши.

## Что эта процедура не делает

- Не прошивает VBIOS.
- Не пишет BAR0/BAR1 и неизвестные аппаратные регистры.
- Не считает адрес Vulkan-буфера физическим адресом HBM.
- Не включает ECC или hardware row remapping там, где GSP/CMP сообщает о
  неподдерживаемом режиме.
- Не гарантирует одинаковый адрес или результат на другой карте, материнской
  плате, версии ядра или драйвера.

## Связанные проекты

- [`memtest_vulkan` v0.5.0](https://github.com/GpuZelenograd/memtest_vulkan/releases/tag/v0.5.0)
- [`cmpunlocker`](https://github.com/amoghmunikote/cmpunlocker)
- [`170tune`](https://github.com/cachenetics/170tune)
- [NVIDIA Open GPU Kernel Modules](https://github.com/NVIDIA/open-gpu-kernel-modules)
