# HandBrake: устройство и сравнение с Video Editor

Дата исследования: **17 августа 2026 года**.

Этот документ фиксирует результаты изучения HandBrake, чтобы не повторять полный анализ. Он описывает состояние исходников на указанную дату, архитектуру обоих приложений, различия, полезные идеи и лицензионные ограничения.

## Краткий вывод

HandBrake и наш Video Editor используют FFmpeg-экосистему, но являются продуктами разного масштаба и назначения.

- **HandBrake** — зрелый кроссплатформенный транскодер. Его главная задача — прочитать почти любой источник и создать новый совместимый файл с управлением кодеками, качеством, фильтрами, дорожками, субтитрами, главами, HDR и очередью.
- **Video Editor** — небольшое нативное macOS-приложение для трех понятных операций: сжатия, вырезания и склейки. Оно сознательно скрывает большинство параметров и оптимизировано под Apple Silicon и VideoToolbox.
- HandBrake не является полноценным монтажным редактором. Его очередь обрабатывает несколько независимых заданий, но не склеивает их в один фильм. Наши вырезание без перекодирования и склейка — важные отличия.
- Главное архитектурное отличие: HandBrake встраивает собственное C-ядро `libhb`, а наше приложение запускает внешний `ffmpeg` через оболочку `video_engine`.

Практический вывод: **не нужно превращать наш проект в уменьшенную копию HandBrake**. Ценность нашего приложения — быстрый и простой сценарий. У HandBrake стоит заимствовать идеи устройства заданий, очереди, пресетов, журналирования и обработки дорожек, но не его сложность целиком.

## Где находится исследовательская копия

Официальный репозиторий скачан сюда:

```text
reference/HandBrake/
```

Источник:

```text
https://github.com/HandBrake/HandBrake.git
```

Состояние изученной копии:

```text
ветка:  master
commit: d43e68f2323e5d096fee88d381a06721a4ef4d5c
дата:   2026-08-16
тема:   MacGui: add an upper bound to the activity log number of lines
тип:    shallow clone (--depth 1)
размер: около 47 МБ
```

Копия исключена из родительского Git через `.gitignore`, поэтому вложенный репозиторий и его десятки тысяч файлов не попадут случайно в коммит нашего проекта.

Обновление копии в будущем:

```bash
git -C reference/HandBrake pull --ff-only
```

После обновления нужно записать новый commit и дату в этот раздел и проверить журнал изменений HandBrake. Полный повторный разбор нужен только после крупных архитектурных изменений.

## Как устроен наш Video Editor

### Компоненты

```text
Пользователь
    ↓
Swift/AppKit GUI
VideoEditorMac/Sources/main.swift
    ↓ Process + текстовые аргументы
zsh-движок
VideoEditorMac/Resources/video_engine
    ↓
ffprobe — анализ источника
ffmpeg  — обрезка, фильтры, кодирование, склейка, контейнер
    ↓
MP4 или фрагмент исходного контейнера
```

Основные файлы:

- `VideoEditorMac/Sources/main.swift` — весь интерфейс, состояние окна, предпросмотр, таймлайн, выбор профиля, запуск процесса и разбор прогресса; около 2052 строк.
- `VideoEditorMac/Resources/video_engine` — CLI-движок на zsh, формирующий команды FFmpeg; около 1794 строк.
- `VideoEditorMac/build_app.sh` — ручная сборка `.app` через `swiftc`, упаковка ресурсов и ad-hoc подпись.
- `VideoEditorMac/Info.plist` — метаданные и минимальная версия macOS.

### Поток выполнения

1. GUI выбирает режим `compress`, `cut` или `join`.
2. Swift вызывает `ffprobe` для разрешения, FPS, битрейта, кодека, pixel format, HDR-признаков и длительности.
3. GUI ограничивает набор доступных профилей, чтобы не увеличивать разрешение и не запускать опасное SDR-преобразование HDR/10-bit источника.
4. При запуске Swift создает `Process` и передает аргументы внутреннему `video_engine`.
5. Движок формирует команду FFmpeg, пишет незавершенный результат во временный файл и получает машинный прогресс через именованный канал `-progress`.
6. GUI читает строки состояния, показывает процент, ETA, скорость, размер, CPU и RAM.
7. После успешного завершения временный файл атомарно перемещается на выбранный путь; при отмене или ошибке удаляется.

### Реализация трех операций

#### Сжатие

- Видео кодируется в H.264 или HEVC.
- При доступности используется `h264_videotoolbox` или `hevc_videotoolbox`.
- CPU fallback — `libx264` или `libx265`.
- Управление качеством преимущественно основано на целевом среднем битрейте профиля, `maxrate` и `bufsize`.
- AAC копируется, первая другая аудиодорожка перекодируется в AAC.
- Используются первая видеодорожка и первая аудиодорожка; субтитры и data streams удаляются.
- Метаданные и главы для результата сжатия удаляются.
- MP4 получает `faststart`.

#### Вырезание

- Выполняется `-c copy`, то есть без декодирования и повторного кодирования.
- Сохраняются все отображенные через `-map 0` потоки и метаданные.
- Это быстро и не ухудшает качество.
- Ограничение: начало фрагмента может фактически привязаться к ближайшему ключевому кадру.

#### Склейка

- Swift формирует временный TSV-манифест с путем и границами каждого клипа.
- Движок нормализует клипы к общему разрешению, частоте и формату.
- Для клипов без звука добавляется тишина.
- FFmpeg `concat` filter объединяет подготовленные видео- и аудиопотоки.
- Итог всегда перекодируется в единый MP4, потому что исходники могут отличаться.

### Сильные стороны нашей реализации

- Очень маленький и понятный код по сравнению с HandBrake.
- Нативный интерфейс без сторонних Swift-зависимостей.
- Три сценария находятся в одном окне и не требуют знания параметров кодеков.
- Быстрое вырезание без потери качества.
- Склейка разнородных роликов — сценарий, которого нет в HandBrake как основной функции.
- Полезная телеметрия: прогноз размера, текущий размер, CPU, RAM, скорость записи и безопасная отмена.

### Текущие ограничения нашей реализации

- Только macOS, только Apple Silicon, готовая сборка только `arm64`.
- Требуется отдельно установленный Homebrew FFmpeg/ffprobe.
- GUI и логика сильно сконцентрированы в двух больших файлах.
- Нет постоянной очереди заданий и восстановления после перезапуска.
- Нет пользовательских пресетов, импорта/экспорта и версионирования схемы пресета.
- Нет выбора нескольких аудиодорожек, языковых правил, mixdown и audio passthrough mask.
- Нет поддержки субтитров и глав в режиме сжатия.
- Нет MKV/WebM на выходе сжатия и склейки.
- Нет AV1, VP9, 10/12-bit encode и полноценного HDR/tone mapping workflow.
- Нет deinterlace/decomb, denoise, detelecine, colorspace, crop/pad и других пользовательских фильтров.
- Нет quality-based encoding (CRF/RF) как основного режима; фиксированный битрейт менее стабильно дает одинаковое визуальное качество на разных видео.
- Нет отдельного изолированного worker-процесса с устойчивой моделью состояния. Запущен дочерний FFmpeg, но нет очереди и восстановления job state.
- В корне нашего проекта на момент исследования не найден отдельный файл лицензии. Его стоит добавить до публичного распространения исходников.

## Как устроен HandBrake

### Общая архитектура

```text
macOS GUI (Objective-C/AppKit)
Windows GUI (C#/WPF)       ┐
Linux GUI (GTK)            ├─ формируют Job/Preset
HandBrakeCLI               ┘
             ↓
платформенный binding / HandBrakeKit
             ↓
libhb — собственное C-ядро HandBrake
             ↓
reader → decoder → sync → filters → encoder → muxer
             ↓
FFmpeg libraries + x264/x265 + SVT-AV1 + системные hardware APIs
```

HandBrake не просто запускает `ffmpeg` как отдельную команду. Он собирает и встраивает библиотеки, а собственное ядро `libhb` управляет чтением, декодированием, синхронизацией, фильтрами, кодированием, субтитрами и muxing.

В изученной копии только `libhb` и macOS C/Objective-C/Swift-код содержат примерно **151 тысячу строк**, а macOS-часть — около **245 исходных файлов**. Это на два порядка сложнее нашей кодовой базы.

### Главные слои

#### 1. Платформенные GUI

- `macosx/` — AppKit/Objective-C приложение, Xcode project, локализации и HandBrakeKit.
- `win/CS/` — Windows GUI на C#/WPF.
- `gtk/` — Linux/Unix GUI на GTK.
- `test/` — исходники HandBrakeCLI.

GUI реализованы отдельно, но используют одну модель настроек и одно `libhb`.

#### 2. Модель задания

На macOS центральный объект — `HBJob` в `macosx/HBJob.h` и `HBJob.m`. Он связывает:

- источник и destination;
- контейнер;
- диапазон/главы;
- видеокодек и параметры качества;
- геометрию изображения;
- фильтры;
- несколько аудиодорожек;
- субтитры;
- главы и метаданные;
- аппаратное декодирование.

Это важная идея: интерфейс не собирает командную строку напрямую. Сначала создается полноценный сериализуемый объект задания.

#### 3. Objective-C-обертка над ядром

`macosx/HBCore.h` и `HBCore.m` адаптируют C API к приложению:

- `hb_init` / `hb_close` — жизненный цикл;
- `hb_scan` — асинхронное сканирование источника;
- `hb_add` + `hb_start` — запуск задания;
- `hb_get_state` — получение состояния и прогресса;
- `hb_pause`, `hb_resume`, `hb_stop` — управление;
- conversion preview frames в `CVPixelBuffer` и `CGImage`.

Состояния явно типизированы: idle, scanning, scan done, working, paused, work done, muxing и searching.

#### 4. `libhb`

`libhb/` — основная ценность и сложность HandBrake. Ключевые точки:

- `libhb/handbrake/handbrake.h` — публичный C API и основные структуры.
- `libhb/scan.c` — анализ файлов, DVD/Blu-ray titles и потоков.
- `libhb/work.c` — создание pipeline задания.
- `libhb/stream.c` — чтение и анализ медиапотоков через FFmpeg/libav.
- `libhb/common.c` — реестр контейнеров, кодеков и возможностей.
- `libhb/encx264.c`, `encx265.c`, `encsvtav1.c` и другие — адаптеры кодировщиков.

Pipeline в `work.c` строится из независимых work objects и FIFO-буферов. Reader, decoders, sync, filters, encoders и muxer работают в параллельных потоках. Это позволяет разным этапам обработки выполняться одновременно и дает ядру точный контроль над состоянием.

#### 5. Пресеты

В `preset/preset_builtin.json` находится около **115 встроенных пресетов**. Пресет — не просто разрешение и битрейт. Он может задавать:

- контейнер и совместимость;
- codec, RF/bitrate, preset/tune/profile/level;
- frame rate policy;
- scaling/cropping/padding;
- фильтры;
- правила выбора аудиодорожек и fallback encoder;
- правила выбора и burn-in субтитров;
- chapters, metadata и web optimization.

Есть пользовательские пресеты, default preset, импорт/экспорт JSON и миграция старых схем.

#### 6. Очередь и изоляция процессов

`macosx/HBQueue.m` хранит задания, их состояния и результат. Очередь сериализуется на диск, умеет pause/resume/cancel и продолжение следующих заданий.

На macOS encode workers запускаются через XPC:

- `HBRemoteCore` — клиент XPC;
- `HBQueueWorker` — управление worker;
- `HandBrakeXPCService` — изолированный процесс кодирования;
- в текущем проекте объявлены четыре XPC service name для параллельных jobs.

Падение кодировщика поэтому не обязано уронить главное окно, а очередь может централизованно обработать ошибку. Это значительно надежнее монолитного GUI.

### Возможности HandBrake, которых у нас нет

- Windows, macOS и Linux из общей кодовой базы ядра.
- DVD/Blu-ray titles и chapters (без обхода DRM).
- MP4/M4V, MKV и WebM output workflows.
- H.264, H.265/HEVC, AV1, VP9 и 8/10/12-bit варианты в зависимости от платформы.
- Apple VideoToolbox, Intel QSV, NVIDIA NVENC, AMD VCN/VCE, VAAPI и Media Foundation.
- Constant Quality (RF/CRF), average bitrate и 2-pass режимы.
- Полный crop/scale/pad, anamorphic и aspect-ratio control.
- Deinterlace/decomb, detelecine, denoise, sharpen, deband, colorspace и subtitle rendering filters.
- Несколько аудиодорожек, mixdown, sample rate, DRC, gain, passthrough и fallback rules.
- Embedded/external subtitles, forced/foreign audio scan, soft subtitles и burn-in.
- Chapters и metadata passthrough.
- Live Preview с коротким пробным encode.
- Пакетная постоянная очередь и несколько worker-процессов.
- Пользовательские JSON-пресеты и автоматический выбор по языкам.
- Activity Log, диагностические данные и зрелая обработка ошибок.

### Что есть у нас, но не является сильной стороной HandBrake

- Наглядная склейка нескольких разных роликов в один файл.
- Индивидуальная визуальная обрезка каждого клипа перед склейкой.
- Быстрое вырезание `stream copy` без потери качества.
- Очень простой интерфейс из трех режимов без десятков параметров.
- Явный прогноз итогового размера и показ CPU/RAM прямо в основном окне.

HandBrake поддерживает point-to-point encode, то есть может перекодировать выбранный диапазон одного title. Это не то же самое, что наша быстрая обрезка `-c copy`. HandBrake также умеет положить много источников в очередь, но очередь создает много отдельных результатов и не является монтажной склейкой.

## Таблица ключевых различий

| Область | Video Editor | HandBrake |
| --- | --- | --- |
| Основная цель | Сжать, вырезать, склеить | Универсально транскодировать |
| Платформы | macOS Apple Silicon | macOS, Windows, Linux |
| GUI | Swift/AppKit, один большой source | Отдельные зрелые GUI; macOS преимущественно Objective-C/AppKit |
| Движок | zsh + внешний FFmpeg CLI | Встроенное C-ядро `libhb` + библиотеки кодеков |
| Анализ | Отдельный `ffprobe` | Собственный scan layer поверх FFmpeg и disc libraries |
| Модель задания | Массив аргументов процесса | Типизированный сериализуемый `HBJob` |
| Pipeline | Один дочерний FFmpeg | Многопоточный reader/decoder/filter/encoder/muxer pipeline |
| Сжатие | H.264/HEVC, bitrate profiles | Много кодеков, RF/ABR/2-pass и расширенные настройки |
| Аппаратное ускорение | Apple VideoToolbox | VideoToolbox, QSV, NVENC, AMD, VAAPI, MF |
| Вырезание | Stream copy или encode выбранного диапазона | Point-to-point encode |
| Склейка | Есть, с нормализацией клипов | Нет как монтажной операции |
| Аудио | Первая дорожка; copy AAC или encode AAC | Несколько дорожек, codecs, passthrough, mixdown, language rules |
| Субтитры | Нет в сжатии/склейке | Полная модель soft/burned/forced subtitles |
| HDR | Защитный запрет опасного SDR encode | HDR10/HDR10+/Dolby Vision workflows и metadata |
| Фильтры | Scale/pad для основных сценариев | Большая управляемая цепочка фильтров |
| Presets | 9 встроенных Swift-профилей | Около 115 встроенных + пользовательские JSON |
| Queue | Одно активное задание | Постоянная очередь, pause/resume, несколько workers |
| Изоляция | Дочерний FFmpeg | XPC workers на macOS |
| Зависимости | Homebrew FFmpeg нужен пользователю | Зависимости собираются и поставляются с приложением |
| Размер/сложность | Около 3,8 тыс. строк GUI+engine | Примерно 151 тыс. строк только `libhb`+macOS source |
| Лицензия | Не зафиксирована отдельным файлом | GNU GPL v2 |

## Что разумно перенять в наш проект

Ниже идеи расположены по отношению пользы к сложности.

### Приоритет 1 — сделать без превращения проекта в HandBrake

1. **Выделить типизированный `VideoJob`.** Убрать сбор аргументов из контроллера окна. Job должен хранить operation, sources, ranges, profile, output и acceleration policy.
2. **Разделить GUI-файл.** Вынести модели, timeline, media probe, process runner и контроллеры трех режимов в отдельные Swift-файлы.
3. **Сделать версионируемые JSON-пресеты.** Оставить простые названия, но хранить preset schema отдельно от GUI.
4. **Добавить activity log.** Сохранять фактическую команду, версию FFmpeg, параметры источника, stderr и итоговый status в файл диагностики.
5. **Добавить отдельный `ProcessRunner` со state machine.** Состояния: idle, probing, ready, running, cancelling, succeeded, failed.
6. **Добавить файл лицензии нашего проекта** и зафиксировать лицензии используемых компонентов.

### Приоритет 2 — заметное расширение продукта

1. Очередь заданий с сохранением в JSON и восстановлением после запуска.
2. Выбор аудиодорожек и стратегия `copy if compatible / AAC fallback`.
3. Сохранение chapters и metadata по явной настройке.
4. Режим Constant Quality для H.264/HEVC наряду с текущими предсказуемыми bitrate profiles.
5. Правильный 10-bit/HDR encode и tone mapping вместо полного запрета.
6. MKV output для случаев, где MP4 ограничивает дорожки или субтитры.
7. Короткий encode preview текущего профиля, а не только воспроизведение исходника.

### Приоритет 3 — только при появлении реального спроса

1. Полноценная система видеофильтров.
2. Субтитры с language rules и burn-in.
3. Несколько параллельных workers.
4. Собственная поставка FFmpeg вместо зависимости от Homebrew.
5. Intel Mac или другие платформы.
6. Переход на встроенные libav libraries или собственное C-ядро.

Последний пункт особенно дорогой. Для нашего масштаба внешний FFmpeg CLI — нормальный инженерный выбор: он радикально упрощает разработку, обновления и отладку.

## Что не стоит копировать

- Огромное количество настроек в основном интерфейсе.
- Собственное медиаядро только ради архитектурной похожести.
- DVD/Blu-ray code, если пользователи работают с обычными файлами.
- Несколько платформ до появления подтвержденной потребности.
- Прямые фрагменты GPL-кода без принятия лицензионных последствий.

## Лицензия и использование кода

HandBrake распространяется по **GNU GPL v2**. Изучать его, запускать и использовать архитектурные идеи можно. Но прямое копирование или включение кода HandBrake в распространяемый продукт может потребовать распространения производной работы на условиях GPL v2 с доступным исходным кодом.

Поэтому безопасная стратегия для нашего проекта:

- изучать подходы и структуры;
- реализовывать нужные идеи самостоятельно;
- не копировать код, ресурсы и пресеты механически;
- отдельно проверить совместимость лицензий перед линковкой с `libhb` или распространением его модификации.

Это техническое резюме, а не юридическая консультация.

## Карта исходников HandBrake для будущего изучения

Начинать следует с этих файлов, а не читать репозиторий подряд:

| Вопрос | Файл/каталог |
| --- | --- |
| Публичное C API | `reference/HandBrake/libhb/handbrake/handbrake.h` |
| Scan источника | `reference/HandBrake/libhb/scan.c` |
| Pipeline encode | `reference/HandBrake/libhb/work.c` |
| Чтение потоков | `reference/HandBrake/libhb/stream.c` |
| Реестр кодеков | `reference/HandBrake/libhb/common.c` |
| FFmpeg video encoder adapter | `reference/HandBrake/libhb/encavcodec.c` |
| x264/x265/SVT-AV1 | `reference/HandBrake/libhb/encx264.c`, `encx265.c`, `encsvtav1.c` |
| Mac core wrapper | `reference/HandBrake/macosx/HBCore.h`, `HBCore.m` |
| Модель задания | `reference/HandBrake/macosx/HBJob.h`, `HBJob.m` |
| Модель диапазона | `reference/HandBrake/macosx/HBRange.h`, `HBRange.m` |
| Очередь | `reference/HandBrake/macosx/HBQueue.h`, `HBQueue.m` |
| Worker и XPC | `reference/HandBrake/macosx/HBQueueWorker.m`, `HBRemoteCore.m`, `HandBrakeXPCService/` |
| Preview | `reference/HandBrake/macosx/HBPreviewGenerator.m` |
| Preset manager | `reference/HandBrake/macosx/HBPresetsManager.m` |
| Встроенные пресеты | `reference/HandBrake/preset/preset_builtin.json` |
| Система сборки | `reference/HandBrake/configure`, `make/`, `contrib/` |
| macOS Xcode project | `reference/HandBrake/macosx/HandBrake.xcodeproj` |

## Внешние источники

- [Официальный GitHub HandBrake](https://github.com/HandBrake/HandBrake)
- [Официальная документация](https://handbrake.fr/docs/en/latest/)
- [Сборка HandBrake для macOS](https://handbrake.fr/docs/en/latest/developer/build-mac.html)
- [Официальные пресеты](https://handbrake.fr/docs/en/latest/technical/official-presets.html)
- [Apple VideoToolbox в HandBrake](https://handbrake.fr/docs/en/latest/technical/video-videotoolbox.html)
- [Constant Quality и Average Bitrate](https://handbrake.fr/docs/en/latest/technical/video-cq-vs-abr.html)
- [Субтитры](https://handbrake.fr/docs/en/latest/advanced/subtitles.html)
- [Audio quality и passthrough](https://handbrake.fr/docs/en/latest/technical/audio-quality.html)
- [CLI reference](https://handbrake.fr/docs/en/latest/cli/command-line-reference.html)
- [Лицензия GPL v2 в локальной копии](../reference/HandBrake/COPYING)

## Быстрый чек-лист перед следующим сравнением

1. Выполнить `git -C reference/HandBrake pull --ff-only`.
2. Сравнить новый commit с `d43e68f`.
3. Просмотреть изменения в `libhb`, `macosx`, `preset` и release notes.
4. Обновить таблицу только для реально изменившихся возможностей.
5. Не перечитывать весь проект, если архитектурные слои остались прежними.
