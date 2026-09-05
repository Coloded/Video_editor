#!/usr/bin/env zsh
set -euo pipefail

# AVI -> macOS-friendly MP4/MOV.
# Best case: remux only, no quality loss, video/audio streams are copied.
# Fallback: keep H.264/HEVC video as-is and convert audio to AAC.
# Last resort: high-quality H.264 re-encode for files with incompatible video.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_DIR="${OUT_DIR:-$SCRIPT_DIR/converted_for_mac}"
OVERWRITE="${OVERWRITE:-0}"
REQUESTED_FILE=""
LAST_FFMPEG_LOG=""
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
  ./convert_avi_for_mac.sh -f "имя_файла.avi"

Можно передать только имя файла, если он лежит в той же папке, что и скрипт.

Опции:
  -f, --file FILE       AVI-файл для конвертации
  -o, --out-dir DIR     Папка результата. По умолчанию: ./converted_for_mac
  --overwrite           Перезаписывать готовый файл, если он уже есть
  -h, --help            Показать справку

Пример:
  ./convert_avi_for_mac.sh -f "Периметр_СПА_вход_Богема_20260528_224750_20260528_230250.avi"

Что делает:
  1. Пробует MP4 без потери качества: -c copy
  2. Если MP4 не подходит, пробует MOV без потери качества: -c copy
  3. Если нужно, делает MP4 для macOS: видео копируется, звук -> AAC
  4. Если видео-кодек несовместимый, перекодирует в H.264 с высоким качеством
EOF
}

need_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Не найден $1."
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

probe_codec() {
  local input="$1"
  local selector="$2"

  ffprobe -v error \
    -select_streams "$selector" \
    -show_entries stream=codec_name \
    -of default=noprint_wrappers=1:nokey=1 \
    "$input" 2>/dev/null | head -n 1
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
  ext=".${base##*.}"
  base="${base%.*}"
  n=1

  while [[ -e "$dir/$base-$n$ext" ]]; do
    n=$((n + 1))
  done

  echo "$dir/$base-$n$ext"
}

temp_output_path() {
  local output="$1"
  local stem ext

  stem="${output%.*}"
  ext="${output##*.}"
  echo "$stem.tmp.$$.$ext"
}

resolve_input() {
  local raw="$1"
  local candidate

  for candidate in \
    "$raw" \
    "$SCRIPT_DIR/$raw" \
    "$SCRIPT_DIR/$raw.avi" \
    "$SCRIPT_DIR/$raw.AVI"; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return
    fi
  done

  echo "$raw"
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

  printf "\rПрошло: %s | Видео: %s / %s | %3d%% | Осталось: %s" \
    "$(format_time "$elapsed")" \
    "$(format_time "$media_pos")" \
    "$(format_time "$duration")" \
    "$percent" \
    "$eta_text"
}

run_ffmpeg_with_progress() {
  local label="$1"
  local input="$2"
  local output="$3"
  shift 3

  local duration started err_file tmp_output ffmpeg_status media_pos key value
  duration="$(duration_seconds "$input")"
  started="$(date +%s)"
  err_file="$(mktemp -t ffmpeg-error.XXXXXX)"
  tmp_output="$(temp_output_path "$output")"
  LAST_FFMPEG_LOG="$err_file"
  TMP_FILES+=("$err_file" "$tmp_output")

  echo
  echo "Режим: $label"
  echo "Конвертирую: $input"
  echo "В файл:       $output"
  echo "Длительность: $(format_time "$duration")"

  set +e
  ffmpeg \
    -hide_banner \
    -y \
    -nostdin \
    -nostats \
    -stats_period 1 \
    -progress pipe:1 \
    "$@" \
    "$tmp_output" 2>"$err_file" |
    while IFS='=' read -r key value; do
      case "$key" in
        out_time_us|out_time_ms)
          if [[ "$value" =~ '^[0-9]+$' ]]; then
            media_pos=$((value / 1000000))
            print_progress_line "$started" "$duration" "$media_pos"
          fi
          ;;
        progress)
          if [[ "$value" == "end" ]]; then
            print_progress_line "$started" "$duration" "$duration"
          fi
          ;;
      esac
    done
  ffmpeg_status="${pipestatus[1]}"
  set -e

  echo

  if [[ "$ffmpeg_status" == "0" ]]; then
    if [[ "$OVERWRITE" != "1" && -e "$output" ]]; then
      echo "Файл уже существует: $output"
      rm -f "$tmp_output"
      return 1
    fi

    if [[ "$output" -ef "$input" || "${output:A}" == "${input:A}" ]]; then
      echo "Ошибка: результат не может заменять исходный файл" >&2
      exit 1
    fi
    if [[ "$OVERWRITE" == 1 ]]; then
      mv -f -- "$tmp_output" "$output"
    else
      ln -- "$tmp_output" "$output" || { echo "Имя результата занято; исходные файлы сохранены" >&2; exit 1; }
      rm -f -- "$tmp_output"
    fi
    echo "Готово: $output"
    return 0
  fi

  rm -f "$tmp_output"
  return "$ffmpeg_status"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--file)
        shift
        if [[ $# -eq 0 || -z "${1:-}" ]]; then
          echo "После -f нужно указать имя AVI-файла."
          exit 1
        fi
        REQUESTED_FILE="$1"
        shift
        ;;
      -o|--out-dir)
        shift
        if [[ $# -eq 0 || -z "${1:-}" ]]; then
          echo "После -o нужно указать папку результата."
          exit 1
        fi
        OUT_DIR="$1"
        shift
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
        echo "Неизвестный параметр: $1"
        usage
        exit 1
        ;;
    esac
  done
}

convert_one() {
  local input="$1"

  if [[ ! -f "$input" ]]; then
    echo "Файл не найден: $input"
    exit 1
  fi

  local name base mp4_out mov_out final_out video_codec audio_codec
  name="$(basename "$input")"
  base="${name%.*}"
  mp4_out="$(unique_output_path "$OUT_DIR/$base.mp4")"
  mov_out="$(unique_output_path "$OUT_DIR/$base.mov")"
  final_out="$(unique_output_path "$OUT_DIR/$base.mac.mp4")"
  video_codec="$(probe_codec "$input" "v:0")"
  audio_codec="$(probe_codec "$input" "a:0")"

  echo
  echo "Входной файл: $input"
  echo "Видео-кодек:  ${video_codec:-неизвестно}"
  echo "Аудио-кодек:  ${audio_codec:-нет/неизвестно}"
  echo "Папка вывода: $OUT_DIR"

  if run_ffmpeg_with_progress \
    "MP4 без потери качества, копирование потоков (-c copy)" \
    "$input" \
    "$mp4_out" \
    -fflags +genpts \
    -i "$input" \
    -map 0 \
    -c copy \
    -movflags +faststart; then
    echo "Потеря качества: нет, видео и звук скопированы без перекодирования."
    return 0
  fi

  echo "MP4 без перекодирования не подошёл, пробую MOV без потери качества..."

  if run_ffmpeg_with_progress \
    "MOV без потери качества, копирование потоков (-c copy)" \
    "$input" \
    "$mov_out" \
    -fflags +genpts \
    -i "$input" \
    -map 0 \
    -c copy; then
    echo "Потеря качества: нет, видео и звук скопированы без перекодирования."
    return 0
  fi

  if [[ "$video_codec" == "h264" || "$video_codec" == "hevc" ]]; then
    echo "MOV тоже не подошёл. Делаю MP4 для macOS: видео без потерь, звук в AAC..."

    if run_ffmpeg_with_progress \
      "MP4 для macOS: видео copy, звук AAC" \
      "$input" \
      "$final_out" \
      -fflags +genpts \
      -i "$input" \
      -map "0:v:0" \
      -map "0:a?" \
      -c:v copy \
      -c:a aac \
      -b:a 192k \
      -movflags +faststart; then
      echo "Потеря качества видео: нет, видеопоток скопирован."
      echo "Звук перекодирован в AAC для совместимости с macOS."
      return 0
    fi
  else
    echo "Видео-кодек не H.264/HEVC. Делаю качественный H.264 для macOS..."

    if run_ffmpeg_with_progress \
      "MP4 для macOS: высококачественный H.264 + AAC" \
      "$input" \
      "$final_out" \
      -fflags +genpts \
      -i "$input" \
      -map "0:v:0" \
      -map "0:a?" \
      -c:v libx264 \
      -preset slow \
      -crf 16 \
      -pix_fmt yuv420p \
      -c:a aac \
      -b:a 192k \
      -movflags +faststart; then
      echo "Видео перекодировано в H.264 с высоким качеством: CRF 16."
      return 0
    fi
  fi

  echo
  echo "Не удалось сконвертировать файл. Последние строки ffmpeg:"
  if [[ -n "$LAST_FFMPEG_LOG" && -f "$LAST_FFMPEG_LOG" ]]; then
    tail -n 30 "$LAST_FFMPEG_LOG"
  fi
  exit 1
}

parse_args "$@"
need_tool ffmpeg
need_tool ffprobe
mkdir -p "$OUT_DIR"

if [[ -z "$REQUESTED_FILE" ]]; then
  echo "Укажи файл через -f."
  usage
  exit 1
fi

convert_one "$(resolve_input "$REQUESTED_FILE")"
