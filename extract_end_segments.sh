#!/usr/bin/env zsh
set -euo pipefail

# Create three clips taken from the very end of an audio or video file.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REQUESTED_FILE=""
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
  ./extract_end_segments.sh -f "video.audio.m4a"

Скрипт создаёт три отдельных файла с концом исходника:
  *.last-1s.*     последние 1 секунда
  *.last-1_5s.*   последние 1.5 секунды
  *.last-2s.*     последние 2 секунды

Опции:
  -f, --file FILE   Исходное аудио или видео
  --overwrite       Перезаписать ранее созданные файлы
  -h, --help        Показать справку

Аудио и видео копируются без повторного кодирования и потери качества.
EOF
}

need_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Ошибка: не найден $1."
    echo "Установить можно так: brew install ffmpeg"
    exit 1
  fi
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

duration_seconds() {
  ffprobe -v error \
    -show_entries format=duration \
    -of default=noprint_wrappers=1:nokey=1 \
    "$1" 2>/dev/null
}

format_time() {
  local value="${1:-0}"

  awk -v value="$value" 'BEGIN {
    hours = int(value / 3600)
    minutes = int((value - hours * 3600) / 60)
    seconds = value - hours * 3600 - minutes * 60
    printf "%02d:%02d:%04.1f", hours, minutes, seconds
  }'
}

print_progress() {
  local started="$1"
  local target="$2"
  local position="$3"
  local elapsed percent eta

  elapsed=$(( $(date +%s) - started ))
  percent="$(awk -v pos="$position" -v total="$target" \
    'BEGIN { p = total > 0 ? pos * 100 / total : 0; if (p > 100) p = 100; printf "%d", p }')"

  if [[ "$position" != "0" ]]; then
    eta="$(awk -v elapsed="$elapsed" -v pos="$position" -v total="$target" \
      'BEGIN { value = pos > 0 ? elapsed * (total - pos) / pos : 0; if (value < 0) value = 0; printf "%d", value }')"
  else
    eta=0
  fi

  printf "\rПрошло: %s | Фрагмент: %s / %s | %3d%% | Осталось: %s" \
    "$(format_time "$elapsed")" \
    "$(format_time "$position")" \
    "$(format_time "$target")" \
    "$percent" \
    "$(format_time "$eta")"
}

extract_segment() {
  local seconds="$1"
  local label="$2"
  local output="$3"
  local temp_output error_log started ffmpeg_status key value position

  if [[ -e "$output" && "$OVERWRITE" != "1" ]]; then
    echo "Ошибка: файл уже существует: $output"
    echo "Для перезаписи добавьте --overwrite"
    return 1
  fi

  temp_output="${output%.*}.tmp.$$.$EXTENSION"
  error_log="$(mktemp -t extract-end.XXXXXX)"
  TMP_FILES+=("$temp_output" "$error_log")
  started="$(date +%s)"

  echo
  echo "Берём с конца: $label"
  echo "Результат: $output"

  set +e
  ffmpeg \
    -hide_banner \
    -y \
    -nostdin \
    -nostats \
    -progress pipe:1 \
    -sseof "-$seconds" \
    -i "$INPUT" \
    -t "$seconds" \
    -map 0 \
    -map_metadata 0 \
    -c copy \
    -avoid_negative_ts make_zero \
    "$temp_output" 2>"$error_log" |
    while IFS='=' read -r key value; do
      case "$key" in
        out_time_us|out_time_ms)
          if [[ "$value" =~ '^[0-9]+$' ]]; then
            position="$(awk -v value="$value" 'BEGIN { printf "%.3f", value / 1000000 }')"
            print_progress "$started" "$seconds" "$position"
          fi
          ;;
        progress)
          [[ "$value" == "end" ]] && print_progress "$started" "$seconds" "$seconds"
          ;;
      esac
    done
  ffmpeg_status="${pipestatus[1]}"
  set -e
  echo

  if [[ "$ffmpeg_status" != "0" ]]; then
    echo "Ошибка ffmpeg:"
    sed -n '1,120p' "$error_log"
    return "$ffmpeg_status"
  fi

  if [[ "$output" -ef "$INPUT" || "${output:A}" == "${INPUT:A}" ]]; then
      echo "Ошибка: результат не может заменять исходный файл" >&2
      exit 1
    fi
    if [[ "$OVERWRITE" == 1 ]]; then
      mv -f -- "$temp_output" "$output"
    else
      ln -- "$temp_output" "$output" || { echo "Имя результата занято; исходные файлы сохранены" >&2; exit 1; }
      rm -f -- "$temp_output"
    fi
  echo "Готово: $output"
}

while (( $# > 0 )); do
  case "$1" in
    -f|--file)
      (( $# >= 2 )) || { echo "Ошибка: после $1 нужно имя файла."; exit 1; }
      REQUESTED_FILE="$2"
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
  echo "Ошибка: укажите исходный файл через -f."
  usage
  exit 1
fi

need_tool ffmpeg
need_tool ffprobe
need_tool awk

INPUT="$(resolve_input "$REQUESTED_FILE")"
if [[ ! -f "$INPUT" ]]; then
  echo "Ошибка: файл не найден: $REQUESTED_FILE"
  exit 1
fi

DURATION="$(duration_seconds "$INPUT")"
if [[ -z "$DURATION" || "$DURATION" == "N/A" ]]; then
  echo "Ошибка: не удалось определить длительность файла."
  exit 1
fi

if ! awk -v duration="$DURATION" 'BEGIN { exit !(duration >= 2) }'; then
  echo "Ошибка: файл короче 2 секунд, три фрагмента создать нельзя."
  exit 1
fi

INPUT_DIR="$(cd "$(dirname "$INPUT")" && pwd)"
INPUT_NAME="$(basename "$INPUT")"

if [[ "$INPUT_NAME" == *.* ]]; then
  EXTENSION="${INPUT_NAME##*.}"
  STEM="${INPUT_NAME%.*}"
else
  EXTENSION="mkv"
  STEM="$INPUT_NAME"
fi

echo "Источник:     $INPUT"
echo "Длительность: $DURATION сек."
echo "Режим:        копирование без потери качества"

extract_segment "1" "1 секунду" "$INPUT_DIR/$STEM.last-1s.$EXTENSION"
extract_segment "1.5" "1.5 секунды" "$INPUT_DIR/$STEM.last-1_5s.$EXTENSION"
extract_segment "2" "2 секунды" "$INPUT_DIR/$STEM.last-2s.$EXTENSION"

echo
echo "Готово: созданы три фрагмента с конца файла."
