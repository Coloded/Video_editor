#!/usr/bin/env zsh
set -euo pipefail

# Compress a video to a macOS-friendly MP4.
# Default mode uses CRF quality-based compression.
# Optional --target-mb uses a 2-pass H.264 encode for approximate target size.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INPUT_FILE=""
OUTPUT_FILE=""
CODEC="h264"
CRF=""
PRESET="slow"
TARGET_MB=""
SCALE_720P=0
OVERWRITE=0
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
  ./compress_video_for_mac.sh -f "video.mp4"

Опции:
  -f, --file FILE       Файл для сжатия
  -o, --output FILE     Куда сохранить. По умолчанию: рядом, *.compressed.mp4
  --codec h264|hevc     Кодек. h264 = совместимее, hevc = меньше размер
  --crf NUMBER          Качество. H.264: 23-28, HEVC: 26-32
  --target-mb NUMBER    Примерный размер результата в MB, включает 2-pass H.264
  --720p                Уменьшить 1080p до 720p
  --preset NAME         speed/quality: medium, slow, slower. По умолчанию: slow
  --overwrite           Перезаписать выходной файл
  -h, --help            Справка

Примеры:
  ./compress_video_for_mac.sh -f "Сломана дверь .mp4"
  ./compress_video_for_mac.sh -f "Сломана дверь .mp4" --crf 26
  ./compress_video_for_mac.sh -f "Сломана дверь .mp4" --target-mb 40
  ./compress_video_for_mac.sh -f "Сломана дверь .mp4" --codec hevc --crf 29
  ./compress_video_for_mac.sh -f "Сломана дверь .mp4" --720p --target-mb 25

Подсказка:
  Меньше CRF = лучше качество и больше файл.
  Больше CRF = сильнее сжатие и меньше файл.
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

has_audio() {
  local input="$1"

  ffprobe -v error \
    -select_streams a:0 \
    -show_entries stream=index \
    -of default=noprint_wrappers=1:nokey=1 \
    "$input" 2>/dev/null | grep -q .
}

resolve_input() {
  local raw="$1"
  local candidate

  for candidate in \
    "$raw" \
    "$SCRIPT_DIR/$raw" \
    "$SCRIPT_DIR/$raw.mp4" \
    "$SCRIPT_DIR/$raw.mov" \
    "$SCRIPT_DIR/$raw.avi" \
    "$SCRIPT_DIR/$raw.mkv"; do
    if [[ -f "$candidate" ]]; then
      echo "$candidate"
      return
    fi
  done

  echo "$raw"
}

default_output_path() {
  local input="$1"
  local dir name base

  dir="$(dirname "$input")"
  name="$(basename "$input")"
  base="${name%.*}"
  echo "$dir/$base.compressed.mp4"
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
  local use_temp="$4"
  shift 4

  local duration started err_file real_output ffmpeg_status media_pos key value
  duration="$(duration_seconds "$input")"
  started="$(date +%s)"
  err_file="$(mktemp -t ffmpeg-compress-error.XXXXXX)"
  LAST_FFMPEG_LOG="$err_file"
  TMP_FILES+=("$err_file")

  if [[ "$use_temp" == "1" ]]; then
    real_output="${output%.*}.tmp.$$.$(basename "${output##*.}")"
    TMP_FILES+=("$real_output")
  else
    real_output="$output"
  fi

  echo
  echo "Режим: $label"
  echo "Источник: $input"
  echo "Результат: $output"
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
    "$real_output" 2>"$err_file" |
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
    if [[ "$use_temp" == "1" ]]; then
      if [[ "$output" -ef "$input" || "${output:A}" == "${input:A}" ]]; then
      echo "Ошибка: результат не может заменять исходный файл" >&2
      exit 1
    fi
    if [[ "$OVERWRITE" == 1 ]]; then
      mv -f -- "$real_output" "$output"
    else
      ln -- "$real_output" "$output" || { echo "Имя результата занято; исходные файлы сохранены" >&2; exit 1; }
      rm -f -- "$real_output"
    fi
    fi
    return 0
  fi

  [[ "$use_temp" == "1" ]] && rm -f "$real_output"
  return "$ffmpeg_status"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f|--file)
        shift
        [[ $# -gt 0 ]] || { echo "После -f нужно указать файл."; exit 1; }
        INPUT_FILE="$1"
        shift
        ;;
      -o|--output)
        shift
        [[ $# -gt 0 ]] || { echo "После -o нужно указать файл результата."; exit 1; }
        OUTPUT_FILE="$1"
        shift
        ;;
      --codec)
        shift
        [[ $# -gt 0 ]] || { echo "После --codec нужно указать h264 или hevc."; exit 1; }
        CODEC="$1"
        shift
        ;;
      --crf)
        shift
        [[ $# -gt 0 ]] || { echo "После --crf нужно указать число."; exit 1; }
        CRF="$1"
        shift
        ;;
      --target-mb)
        shift
        [[ $# -gt 0 ]] || { echo "После --target-mb нужно указать размер."; exit 1; }
        TARGET_MB="$1"
        shift
        ;;
      --720p)
        SCALE_720P=1
        shift
        ;;
      --preset)
        shift
        [[ $# -gt 0 ]] || { echo "После --preset нужно указать имя."; exit 1; }
        PRESET="$1"
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

validate_args() {
  [[ -z "$CRF" ]] || { [[ "$CRF" =~ '^[0-9]+([.][0-9]+)?$' ]] && awk -v n="$CRF" 'BEGIN {exit !(n >= 0 && n <= 51)}'; } || { echo "--crf должен быть от 0 до 51"; exit 1; }
  [[ -z "$TARGET_MB" ]] || { [[ "$TARGET_MB" =~ '^[0-9]+([.][0-9]+)?$' ]] && awk -v n="$TARGET_MB" 'BEGIN {exit !(n > 0 && n < 10000000)}'; } || { echo "--target-mb должен быть положительным числом"; exit 1; }
  case "$PRESET" in ultrafast|superfast|veryfast|faster|fast|medium|slow|slower|veryslow) ;; *) echo "Неверный --preset"; exit 1 ;; esac
  [[ -n "$INPUT_FILE" ]] || { echo "Укажи файл через -f."; usage; exit 1; }
  [[ "$CODEC" == "h264" || "$CODEC" == "hevc" ]] || { echo "--codec должен быть h264 или hevc."; exit 1; }

  if [[ -n "$TARGET_MB" && "$CODEC" != "h264" ]]; then
    echo "--target-mb сейчас работает через 2-pass H.264. Убери --codec hevc или используй --crf."
    exit 1
  fi
}

compress_crf() {
  local input="$1"
  local output="$2"
  local video_args=()
  local scale_args=()
  local mode effective_crf

  if [[ "$CODEC" == "h264" ]]; then
    effective_crf="${CRF:-24}"
    mode="H.264 CRF $effective_crf"
    video_args=(-c:v libx264 -preset "$PRESET" -crf "$effective_crf" -pix_fmt yuv420p)
  else
    effective_crf="${CRF:-29}"
    mode="HEVC/H.265 CRF $effective_crf"
    video_args=(-c:v libx265 -preset "$PRESET" -crf "$effective_crf" -tag:v hvc1 -pix_fmt yuv420p)
  fi

  if [[ "$SCALE_720P" == "1" ]]; then
    scale_args=(-vf "scale=w='if(gte(iw,ih),-2,min(iw,720))':h='if(gte(iw,ih),min(ih,720),-2)'")
    mode="$mode, 720p"
  fi

  run_ffmpeg_with_progress \
    "$mode" \
    "$input" \
    "$output" \
    1 \
    -i "$input" \
    -map "0:v:0" \
    -map "0:a?" \
    "${scale_args[@]}" \
    "${video_args[@]}" \
    -c:a aac \
    -b:a 128k \
    -movflags +faststart
}

compress_target_size() {
  local input="$1"
  local output="$2"
  local duration audio_kbps total_kbps video_kbps passlog scale_args=()

  duration="$(duration_seconds "$input")"
  if (( duration <= 0 )); then
    echo "Не удалось определить длительность, используй режим --crf."
    exit 1
  fi

  if has_audio "$input"; then
    audio_kbps=$((128 * $(ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$input" | awk 'NF { n++ } END { print n+0 }')))
  else
    audio_kbps=0
  fi

  total_kbps=$((TARGET_MB * 8000 * 0.98 / duration))
  video_kbps=$((total_kbps - audio_kbps))

  if (( video_kbps < 300 )); then
    echo "Слишком маленький --target-mb для этого ролика. Минимум нужен больше."
    exit 1
  fi

  if [[ "$SCALE_720P" == "1" ]]; then
    scale_args=(-vf "scale=w='if(gte(iw,ih),-2,min(iw,720))':h='if(gte(iw,ih),min(ih,720),-2)'")
  fi

  passlog="$(mktemp -t ffmpeg-passlog.XXXXXX)"
  TMP_FILES+=("$passlog" "$passlog.log" "$passlog.log.mbtree" "$passlog-0.log" "$passlog-0.log.mbtree")

  echo "Целевой размер: ${TARGET_MB} MB"
  echo "Расчётный видео-битрейт: ${video_kbps}k"

  run_ffmpeg_with_progress \
    "2-pass H.264, проход 1/2" \
    "$input" \
    "/dev/null" \
    0 \
    -i "$input" \
    -map "0:v:0" \
    "${scale_args[@]}" \
    -an \
    -c:v libx264 \
    -preset "$PRESET" \
    -b:v "${video_kbps}k" \
    -pix_fmt yuv420p \
    -pass 1 \
    -passlogfile "$passlog" \
    -f null || return 1

  run_ffmpeg_with_progress \
    "2-pass H.264, проход 2/2" \
    "$input" \
    "$output" \
    1 \
    -i "$input" \
    -map "0:v:0" \
    -map "0:a?" \
    "${scale_args[@]}" \
    -c:v libx264 \
    -preset "$PRESET" \
    -b:v "${video_kbps}k" \
    -pix_fmt yuv420p \
    -pass 2 \
    -passlogfile "$passlog" \
    -c:a aac \
    -b:a 128k \
    -movflags +faststart
}

show_result_size() {
  local input="$1"
  local output="$2"
  local in_size out_size

  in_size="$(du -h "$input" | awk '{print $1}')"
  out_size="$(du -h "$output" | awk '{print $1}')"
  echo
  echo "Готово: $output"
  echo "Было:  $in_size"
  echo "Стало: $out_size"
}

parse_args "$@"
validate_args
need_tool ffmpeg
need_tool ffprobe

INPUT_FILE="$(resolve_input "$INPUT_FILE")"
[[ -f "$INPUT_FILE" ]] || { echo "Файл не найден: $INPUT_FILE"; exit 1; }

if [[ -z "$OUTPUT_FILE" ]]; then
  OUTPUT_FILE="$(default_output_path "$INPUT_FILE")"
fi

OUTPUT_FILE="$(unique_output_path "$OUTPUT_FILE")"

echo "Видео-кодек исходника: $(probe_codec "$INPUT_FILE" "v:0")"
echo "Аудио-кодек исходника: $(probe_codec "$INPUT_FILE" "a:0")"

if [[ -n "$TARGET_MB" ]]; then
  compress_target_size "$INPUT_FILE" "$OUTPUT_FILE"
else
  compress_crf "$INPUT_FILE" "$OUTPUT_FILE"
fi

if [[ -f "$OUTPUT_FILE" ]]; then
  show_result_size "$INPUT_FILE" "$OUTPUT_FILE"
else
  echo
  echo "Не удалось сжать файл. Последние строки ffmpeg:"
  [[ -n "$LAST_FFMPEG_LOG" && -f "$LAST_FFMPEG_LOG" ]] && tail -n 30 "$LAST_FFMPEG_LOG"
  exit 1
fi
