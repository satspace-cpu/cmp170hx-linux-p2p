# CMP 170HX: проверка полного MMA / Tensor Core unlock

Эта страница дополняет основную инструкцию и отвечает на отдельный важный вопрос: **действительно ли снято вычислительное ограничение Tensor Cores, или карта только показывает увеличенный объём HBM?**

Разлочка памяти и разлочка вычислительной части — не одно и то же. CMP 170HX может показывать 64 ГБ HBM, но при неполном compute unlock всё ещё оставаться искусственно ограниченной на уровне `mma.sync`.

## Что именно ограничено

На штатной/неполностью разлоченной CMP 170HX наблюдается искусственно высокая задержка Tensor Core MMA-инструкций. Практический диагностический ориентир:

```text
MMA latency около 256 cycles  -> throttle остаётся
MMA latency около 24–27 cycles -> полный compute unlock работает
```

Это ограничение особенно сильно бьёт по matrix-heavy задачам: LLM prefill/prompt processing, GEMM, BF16/FP16/TF32 Tensor Core workloads.

После полного compute unlock CMP 170HX с 70 SM выходит примерно на нормальную для своей конфигурации GA100 производительность Tensor Cores, а не остаётся на уровне нескольких TFLOPS.

## Быстрая проверка через Tensor throughput

Для первичной проверки можно использовать CUDA benchmark, который отдельно измеряет Tensor Core throughput.

На нашей системе после полного unlock получено:

| Тест | GPU0 | GPU1 |
|---|---:|---:|
| TF32 Tensor | 99.82 TFLOPS | 98.06 TFLOPS |
| BF16 Tensor | 201.55 TFLOPS | 198.00 TFLOPS |
| INT8 Tensor | 409.77 TOPS | 403.00 TOPS |

Если BF16 Tensor остаётся в районе нескольких TFLOPS, это сильный признак того, что MMA/Tensor throttle не снят.

## Прямая проверка `mma.sync` по тактам

Для instruction-level проверки удобно использовать проект:

- https://github.com/arabel1a/gpu-micro-bench

Он генерирует Ampere `mma.sync` microbenchmarks и измеряет single-chain latency и throughput для F16, BF16, TF32, INT8 и FP64.

### 1. Скачать benchmark

```bash
git clone https://github.com/arabel1a/gpu-micro-bench.git
cd gpu-micro-bench
```

### 2. Сгенерировать и собрать Tensor benchmark

Если CUDA Toolkit уже установлен, но `nvcc` не находится в `PATH`, добавьте каталог вашего Toolkit. На нашей системе использовался CUDA 13.1:

```bash
PATH=/usr/local/cuda-13.1/bin:$PATH python3 gen_tensor.py
```

Готовый бинарник:

```text
bin/tensor_bench
```

Если генератор после успешной компиляции ругается только на отсутствие `cuobjdump`, сам `tensor_bench` уже может быть собран. Для полной SASS-проверки добавьте в `PATH` каталог, где находится `cuobjdump`.

### 3. Проверить GPU0

```bash
~/gpu-micro-bench/bin/tensor_bench 0 10000 1000 20
```

### 4. Проверить GPU1

```bash
~/gpu-micro-bench/bin/tensor_bench 1 10000 1000 20
```

Аргументы в нашем тесте:

```text
GPU index = 0 или 1
n_iters   = 10000
n_warmup  = 1000
n_reps    = 20
```

## Какие строки смотреть

Нужны результаты с суффиксом `_lat`, например:

```text
mma_m16n8k16_f16f16f32,lat
mma_m16n8k16_bf16bf16f32,lat
mma_m16n8k8_tf32tf32f32,lat
```

На нашей системе:

```text
GPU0:
F16  MMA latency  ~26.0 cycles
BF16 MMA latency  ~26.0 cycles
TF32 MMA latency  ~26.0 cycles
INT8 MMA latency  ~26.8 cycles

GPU1:
F16  MMA latency  ~26.5 cycles
BF16 MMA latency  ~26.5 cycles
TF32 MMA latency  ~26.5 cycles
INT8 MMA latency  ~27.3 cycles
```

Это прямое подтверждение того, что обе карты работают в полностью разблокированном MMA/Tensor режиме, а не в состоянии с задержкой около 256 тактов.

## Почему одного `nvidia-smi` недостаточно

`nvidia-smi` может подтвердить объём HBM, PCIe link, power limit и другие свойства, но не показывает фактическую latency `mma.sync`.

Поэтому для полного чек-листа полезно независимо проверить:

```text
VRAM             -> 64 ГБ
BAR1             -> 64 ГБ
PCIe             -> Gen2 x16
HBM bandwidth    -> реальный bandwidth benchmark
Tensor throughput-> ~200 TFLOPS BF16 на нашей конфигурации
MMA latency      -> ~24–27 cycles
```

## Как это влияет на llama.cpp

Compute/MMA unlock особенно заметен на prompt processing (`pp` / prefill), где матричных операций значительно больше, чем в single-stream autoregressive decode.

Для чистого A/B теста используйте одну и ту же модель и одинаковые параметры `llama-bench`.

### Одна CMP

```bash
CUDA_VISIBLE_DEVICES=0 \
/path/to/llama-bench \
-m /path/to/model.gguf \
-p 512 \
-n 128 \
-ngl 99
```

### Две CMP, layer split 50/50

```bash
CUDA_VISIBLE_DEVICES=0,1 \
/path/to/llama-bench \
-m /path/to/model.gguf \
-p 512 \
-n 128 \
-ngl 99 \
-sm layer \
-ts 50/50
```

Важно: в `llama-bench` tensor split для двух GPU задаётся как `50/50`. Запись `50,50` означает два отдельных значения benchmark-параметра и даст два набора прогонов.

На нашей Qwen 3.8 27B BF16 (50.89 GiB):

```text
1x CMP 170HX:
pp512 = 1141.23 t/s
tg128 =   24.72 t/s

2x CMP 170HX, 50/50:
pp512 = 1842.04 t/s
tg128 =   26.97 t/s
```

На этой конкретной модели вторая карта дала примерно **+61% к pp512** и около **+9% к tg128**. Это хороший пример того, почему полный MMA unlock особенно важен для prefill.

## Связь с другими видами разлочки

Эти механизмы решают разные задачи:

- **64 ГБ HBM** — увеличивает доступную ёмкость памяти;
- **HBM tuning / 170tune** — позволяет управлять частотой и таймингами памяти и проверять стабильность;
- **64 ГБ BAR1** — увеличивает PCIe BAR1 aperture;
- **PCIe x16 hardware mod** — возвращает физическую ширину линка;
- **PCIe Gen2 unlock** — поднимает скорость линка с Gen1 до Gen2;
- **CUDA P2P** — позволяет GPU обмениваться данными напрямую;
- **MMA/Tensor unlock** — снимает искусственное ограничение скорости Tensor Core инструкций.

Поэтому «карта показывает 64 ГБ» ещё не означает «карта полностью раскрыта по compute».

## Наш подтверждённый результат

Для двух CMP 170HX на нашей тестовой системе подтверждено:

```text
VRAM:             65536 MiB на карту
BAR1:             64.0 GiB на карту
PCIe:             Gen2 x16
HBM NDIV 70:      реальный прирост bandwidth относительно NDIV 64
BF16 Tensor:      ~198–202 TFLOPS на карту
MMA latency:      ~26.0–26.5 cycles
```

Это состояние мы считаем подтверждённым полным compute/MMA unlock для наших карт.

## Важно

Результаты относятся к нашей конкретной системе, драйверу, ядру и экземплярам CMP 170HX. Не считайте чужие частоты или power limit автоматически безопасными для своей карты. После любых HBM/SM изменений проверяйте стабильность отдельно.