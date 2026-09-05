#!/usr/bin/env zsh
set -euo pipefail

# Extract the first audio track from a video. In auto mode the stream is copied
# into a compatible audio container, so there is no quality loss.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REQUESTED_FILE=""
REQUESTED_OUTPUT=""
OUTPUT_FORMAT="auto"
OVERWRITE=0
TMP_FILES=()

cleanup() {
  local file
  for file in "${TMP_FILES[@]:-}"; do
    [[ -n "$file" && -e "$file" ]] && rm -f "$file"
  done
}
trap cleanup EXIT

usage() {
  cat <<'EOF'
Использование:
  ./extract_audio_from_video.sh -f "video.mp4"

Опции:
  -f, --file FILE       Видео, из которого нужно извлечь звук
  -o, --output FILE     Имя готового аудиофайла
  --format FORMAT       auto, m4a, mp3, wav или flac (по умолчанию: auto)
  --overwrite           Перезаписать готовый файл
  -h, --help            Показать справку

Примеры:
  ./extract_audio_from_video.sh -f "video.mp4"
  ./extract_audio_from_video.sh -f "video.mp4" --format mp3
  ./extract_audio_from_video.sh -f "video.mp4" -o "отдельный звук.m4a"

Режим auto копирует исходную аудиодорожку без перекодирования и без потери
качества. Для AAC получается M4A, который нормально открывается в macOS.
EOF
}

need_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Ошибка: не найден $1."
    echo "Установить можно так: brew install ffmpeg"
    exit 1
  fi
}

format_time() {
  local total="${1:-0}"
  total="${total%.*}"
  [[ "$total" =~ '^[0-9]+$' ]] || total=0

  printf "%02d:%02d:%02d" \
    $((total / 3600)) \
    $(((total % 3600) / 60)) \
    $((total % 60))
}

duration_seconds() {
  local input="$1"
  local raw seconds

  raw="$(
    ffprobe -v error \
      -show_entries format=duration \
      -of default=noprint_wrappers=1:nokey=1 \
      "$input" 2>/dev/null || true
  )"

  if [[ -z "$raw" || "$raw" == "N/A" ]]; then
    echo 0
    return
  fi

  if seconds="$(printf "%.0f" "$raw" 2>/dev/null)"; then
    echo "$seconds"
  else
    echo 0
  fi
}

probe_audio_codec() {
  ffprobe -v error \
    -select_streams "a:0" \
    -show_entries stream=codec_name \
    -of default=noprint_wrappers=1:nokey=1 \
    "$1" 2>/dev/null | sed -n '1p'
}

resolve_input() {
  local raw="$1"

  if [[ -f "$raw" ]]; then
    echo "$raw"
  elif [[ -f "$SCRIPT_DIR/$raw" ]]; then
    echo "$SCRIPT_DIR/$raw"
  else
    echo "$raw"
  fi
}

unique_output_path() {
  local candidate="$1"

  if [[ "$OVERWRITE" == "1" || ( ! -e "$candidate" && ! -L "$candidate" ) ]]; then
    echo "$candidate"
    return
  fi

  local dir base ext n
  dir="$(dirname "$candidate")"
  base="$(basename "$candidate")"

  if [[ "$base" == *.* ]]; then
    ext=".${base##*.}"
    base="${base%.*}"
  else
    ext=""
  fi

  n=1
  while [[ -e "$dir/$base-$n$ext" ]]; do
    n=$((n + 1))
  done

  echo "$dir/$base-$n$ext"
}

print_progress_line() {
  local started="$1"
  local duration="$2"
  local media_pos="$3"
  local now elapsed percent eta eta_text

  now="$(date +%s)"
  elapsed=$((now - started))

  if (( duration > 0 && media_pos > 0 )); then
    (( media_pos > duration )) && media_pos="$duration"
    percent=$((media_pos * 100 / duration))
    eta=$((elapsed * (duration - media_pos) / media_pos))
    eta_text="$(format_time "$eta")"
  else
    percent=0
    eta_text="--:--:--"
  fi

  printf "\rПрошло: %s | Аудио: %s / %s | %3d%% | Осталось: %s" \
    "$(format_time "$elapsed")" \
    "$(format_time "$media_pos")" \
    "$(format_time "$duration")" \
    "$percent" \
    "$eta_text"
}

while (( $# > 0 )); do
  case "$1" in
    -f|--file)
      (( $# >= 2 )) || { echo "Ошибка: после $1 нужно имя файла."; exit 1; }
      REQUESTED_FILE="$2"
      shift 2
      ;;
    -o|--output)
      (( $# >= 2 )) || { echo "Ошибка: после $1 нужно имя файла."; exit 1; }
      REQUESTED_OUTPUT="$2"
      shift 2
      ;;
    --format)
      (( $# >= 2 )) || { echo "Ошибка: после --format нужен формат."; exit 1; }
      OUTPUT_FORMAT="${2:l}"
      shift 2
      ;;
    --overwrite)
      OVERWRITE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Ошибка: неизвестный параметр: $1"
      usage
      exit 1
      ;;
  esac
done

if [[ -z "$REQUESTED_FILE" ]]; then
  echo "Ошибка: укажите видео через -f."
  usage
  exit 1
fi

case "$OUTPUT_FORMAT" in
  auto|m4a|mp3|wav|flac) ;;
  *)
    echo "Ошибка: формат должен быть auto, m4a, mp3, wav или flac."
    exit 1
    ;;
esac

need_tool ffmpeg
need_tool ffprobe

INPUT="$(resolve_input "$REQUESTED_FILE")"
if [[ ! -f "$INPUT" ]]; then
  echo "Ошибка: файл не найден: $REQUESTED_FILE"
  exit 1
fi

AUDIO_CODEC="$(probe_audio_codec "$INPUT")"
if [[ -z "$AUDIO_CODEC" ]]; then
  echo "Ошибка: в файле нет аудиодорожки: $INPUT"
  exit 1
fi

EFFECTIVE_FORMAT="$OUTPUT_FORMAT"
if [[ "$EFFECTIVE_FORMAT" == "auto" ]]; then
  case "$AUDIO_CODEC" in
    aac|alac) EFFECTIVE_FORMAT="m4a" ;;
    mp3) EFFECTIVE_FORMAT="mp3" ;;
    flac) EFFECTIVE_FORMAT="flac" ;;
    opus) EFFECTIVE_FORMAT="opus" ;;
    vorbis) EFFECTIVE_FORMAT="ogg" ;;
    pcm_*) EFFECTIVE_FORMAT="wav" ;;
    ac3) EFFECTIVE_FORMAT="ac3" ;;
    eac3) EFFECTIVE_FORMAT="eac3" ;;
    dts) EFFECTIVE_FORMAT="dts" ;;
    *) EFFECTIVE_FORMAT="mka" ;;
  esac
fi

INPUT_DIR="$(cd "$(dirname "$INPUT")" && pwd)"
INPUT_NAME="$(basename "$INPUT")"
INPUT_STEM="${INPUT_NAME%.*}"

if [[ -n "$REQUESTED_OUTPUT" ]]; then
  if [[ "$REQUESTED_OUTPUT" == */* ]]; then
    OUTPUT="$REQUESTED_OUTPUT"
  else
    OUTPUT="$INPUT_DIR/$REQUESTED_OUTPUT"
  fi
else
  OUTPUT="$INPUT_DIR/$INPUT_STEM.audio.$EFFECTIVE_FORMAT"
fi
if [[ "${OUTPUT:e:l}" != "$EFFECTIVE_FORMAT" ]]; then
  echo "Ошибка: расширение результата должно быть .$EFFECTIVE_FORMAT; для конвертации укажите --format" >&2
  exit 1
fi
OUTPUT="$(unique_output_path "$OUTPUT")"

OUTPUT_DIR="$(dirname "$OUTPUT")"
if [[ ! -d "$OUTPUT_DIR" ]]; then
  echo "Ошибка: папка результата не существует: $OUTPUT_DIR"
  exit 1
fi

TEMP_OUTPUT="${OUTPUT%.*}.tmp.$$.$EFFECTIVE_FORMAT"
ERROR_LOG="$(mktemp -t extract-audio.XXXXXX)"
TMP_FILES+=("$TEMP_OUTPUT" "$ERROR_LOG")

FFMPEG_ARGS=(-map "0:a:0" -vn -map_metadata 0)
MODE_TEXT=""

case "$OUTPUT_FORMAT" in
  auto)
    FFMPEG_ARGS+=(-c:a copy)
    MODE_TEXT="копирование исходной дорожки без потери качества"
    ;;
  m4a)
    if [[ "$AUDIO_CODEC" == "aac" || "$AUDIO_CODEC" == "alac" ]]; then
      FFMPEG_ARGS+=(-c:a copy)
      MODE_TEXT="M4A без повторного кодирования"
    else
      FFMPEG_ARGS+=(-c:a aac -b:a 256k)
      MODE_TEXT="конвертация в M4A/AAC 256k"
    fi
    ;;
  mp3)
    if [[ "$AUDIO_CODEC" == "mp3" ]]; then
      FFMPEG_ARGS+=(-c:a copy)
      MODE_TEXT="MP3 без повторного кодирования"
    else
      FFMPEG_ARGS+=(-c:a libmp3lame -q:a 2)
      MODE_TEXT="конвертация в MP3 высокого качества"
    fi
    ;;
  wav)
    FFMPEG_ARGS+=(-c:a pcm_s16le)
    MODE_TEXT="конвертация в несжатый WAV"
    ;;
  flac)
    if [[ "$AUDIO_CODEC" == "flac" ]]; then
      FFMPEG_ARGS+=(-c:a copy)
      MODE_TEXT="FLAC без повторного кодирования"
    else
      FFMPEG_ARGS+=(-c:a flac)
      MODE_TEXT="конвертация в FLAC без потерь после декодирования"
    fi
    ;;
esac

DURATION="$(duration_seconds "$INPUT")"
STARTED="$(date +%s)"

echo "Источник:       $INPUT"
echo "Аудиокодек:     $AUDIO_CODEC"
echo "Результат:      $OUTPUT"
echo "Режим:          $MODE_TEXT"
echo "Длительность:   $(format_time "$DURATION")"

set +e
ffmpeg \
  -hide_banner \
  -y \
  -nostdin \
  -nostats \
  -stats_period 1 \
  -progress pipe:1 \
  -i "$INPUT" \
  "${FFMPEG_ARGS[@]}" \
  "$TEMP_OUTPUT" 2>"$ERROR_LOG" |
  while IFS='=' read -r key value; do
    case "$key" in
      out_time_us|out_time_ms)
        if [[ "$value" =~ '^[0-9]+$' ]]; then
          print_progress_line "$STARTED" "$DURATION" $((value / 1000000))
        fi
        ;;
      progress)
        if [[ "$value" == "end" ]]; then
          print_progress_line "$STARTED" "$DURATION" "$DURATION"
        fi
        ;;
    esac
  done
FFMPEG_STATUS="${pipestatus[1]}"
set -e
echo

if [[ "$FFMPEG_STATUS" != "0" ]]; then
  echo "Ошибка ffmpeg:"
  sed -n '1,120p' "$ERROR_LOG"
  exit "$FFMPEG_STATUS"
fi

if [[ "$OUTPUT" -ef "$INPUT" || "${OUTPUT:A}" == "${INPUT:A}" ]]; then
      echo "Ошибка: результат не может заменять исходный файл" >&2
      exit 1
    fi
    if [[ "$OVERWRITE" == 1 ]]; then
      mv -f -- "$TEMP_OUTPUT" "$OUTPUT"
    else
      ln -- "$TEMP_OUTPUT" "$OUTPUT" || { echo "Имя результата занято; исходные файлы сохранены" >&2; exit 1; }
      rm -f -- "$TEMP_OUTPUT"
    fi
echo "Готово: $OUTPUT"
