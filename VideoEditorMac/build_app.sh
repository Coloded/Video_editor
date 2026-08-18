#!/usr/bin/env zsh
set -euo pipefail

ROOT="${0:A:h}"
WORKSPACE="${ROOT:h}"
SOURCE="$ROOT/Sources/main.swift"
PLIST="$ROOT/Info.plist"
ENGINE="$ROOT/Resources/video_engine"
ICON="$ROOT/Resources/AppIcon-master.png"
APP="$WORKSPACE/Video Editor.app"

CHECK_ONLY=0
SKIP_RUNTIME_CHECK=0
STAGING=""
PREVIOUS_APP=""

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"

info() { print -r -- "▶ $*"; }
success() { print -r -- "✓ $*"; }
warn() { print -ru2 -- "! $*"; }

die() {
  print -ru2 -- ""
  print -ru2 -- "Ошибка: $*"
  exit 1
}

usage() {
  cat <<'EOF'
Сборка Video Editor для Apple Silicon

Использование:
  ./VideoEditorMac/build_app.sh
  ./VideoEditorMac/build_app.sh --check-only
  ./VideoEditorMac/build_app.sh --skip-runtime-check

Параметры:
  --check-only          Только проверить окружение, ничего не собирать
  --skip-runtime-check  Не требовать FFmpeg/ffprobe во время сборки
  -h, --help           Показать эту справку

Если не установлены Apple Command Line Tools или FFmpeg, скрипт объяснит,
чего не хватает, и в интерактивном Terminal предложит начать установку.
EOF
}

confirm() {
  local prompt="$1"
  local answer=""
  if [[ "${VIDEO_EDITOR_ASSUME_YES:-0}" == "1" ]]; then
    return 0
  fi
  [[ -t 0 ]] || return 1
  print -rn -- "$prompt [y/N]: "
  read -r answer || return 1
  case "${answer:l}" in
    y|yes|д|да) return 0 ;;
    *) return 1 ;;
  esac
}

cleanup() {
  if [[ -n "$PREVIOUS_APP" && -e "$PREVIOUS_APP" && ! -e "$APP" ]]; then
    warn "Восстанавливаю предыдущую сборку после прерывания."
    mv "$PREVIOUS_APP" "$APP" || warn "Не удалось автоматически восстановить: $APP"
  fi
  if [[ -n "$STAGING" && -d "$STAGING" && "${STAGING:t}" == video-editor-app.* ]]; then
    rm -rf -- "$STAGING"
  fi
}
trap cleanup EXIT INT TERM

while (( $# > 0 )); do
  case "$1" in
    --check-only) CHECK_ONLY=1 ;;
    --skip-runtime-check) SKIP_RUNTIME_CHECK=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "неизвестный параметр: $1" ;;
  esac
  shift
done

request_command_line_tools() {
  warn "Не установлены Apple Command Line Tools."
  print -ru2 -- "Они содержат Swift, macOS SDK, codesign и другие инструменты сборки."
  print -ru2 -- "Установка запускается стандартной командой: xcode-select --install"
  if command -v xcode-select >/dev/null 2>&1 && \
     confirm "Открыть системное окно установки Command Line Tools?"; then
    if xcode-select --install; then
      die "дождитесь завершения установки Command Line Tools и запустите сборку ещё раз"
    fi
    die "не удалось открыть установщик. Выполните вручную: xcode-select --install"
  fi
  die "установите Command Line Tools командой 'xcode-select --install', затем повторите сборку"
}

require_command() {
  local command_name="$1"
  local explanation="$2"
  command -v "$command_name" >/dev/null 2>&1 || \
    die "не найдена команда '$command_name'. $explanation"
}

check_input_file() {
  local path="$1"
  local description="$2"
  [[ -f "$path" ]] || die "не найден $description: $path"
  [[ -r "$path" ]] || die "нет прав на чтение $description: $path"
}

check_runtime_tools() {
  if [[ "$SKIP_RUNTIME_CHECK" == "1" ]]; then
    warn "Проверка FFmpeg пропущена по параметру --skip-runtime-check."
    return
  fi
  if command -v ffmpeg >/dev/null 2>&1 && command -v ffprobe >/dev/null 2>&1; then
    success "FFmpeg и ffprobe найдены"
    return
  fi

  warn "Не найдены FFmpeg и/или ffprobe. Сборка возможна, но приложение не сможет обрабатывать видео."
  local brew_path=""
  local candidate
  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x "$candidate" ]]; then
      brew_path="$candidate"
      break
    fi
  done

  if [[ -z "$brew_path" ]]; then
    print -ru2 -- "Сначала установите Homebrew с https://brew.sh/, затем выполните:"
    print -ru2 -- "  brew install ffmpeg"
    die "FFmpeg является обязательной зависимостью готового приложения"
  fi
  if ! confirm "Установить FFmpeg сейчас через Homebrew?"; then
    die "установите FFmpeg командой '$brew_path install ffmpeg' или используйте --skip-runtime-check"
  fi

  info "Устанавливаю FFmpeg через Homebrew"
  "$brew_path" install ffmpeg || die "Homebrew не смог установить FFmpeg; проверьте сообщения выше"
  command -v ffmpeg >/dev/null 2>&1 || die "FFmpeg не найден после установки Homebrew"
  command -v ffprobe >/dev/null 2>&1 || die "ffprobe не найден после установки Homebrew"
  success "FFmpeg установлен"
}

info "Проверяю окружение сборки"
check_input_file "$SOURCE" "исходный файл Swift"
check_input_file "$PLIST" "Info.plist"
check_input_file "$ENGINE" "внутренний video_engine"
check_input_file "$ICON" "исходную иконку"
[[ -d "$WORKSPACE" ]] || die "не найдена папка проекта: $WORKSPACE"
[[ -w "$WORKSPACE" ]] || die "нет прав на запись в папку проекта: $WORKSPACE"

command -v xcrun >/dev/null 2>&1 || request_command_line_tools

for specification in \
  "sips:системная утилита обработки изображений отсутствует" \
  "plutil:системная утилита проверки plist отсутствует" \
  "codesign:системная утилита подписи отсутствует" \
  "lipo:установите или обновите Apple Command Line Tools" \
  "perl:системный Perl необходим для создания icns" \
  "stat:системная команда stat отсутствует" \
  "awk:системная команда awk отсутствует" \
  "df:системная команда df отсутствует" \
  "file:системная команда file отсутствует" \
  "grep:системная команда grep отсутствует" \
  "head:системная команда head отсутствует" \
  "cp:системная команда cp отсутствует" \
  "mv:системная команда mv отсутствует" \
  "rm:системная команда rm отсутствует" \
  "mkdir:системная команда mkdir отсутствует" \
  "mktemp:системная команда mktemp отсутствует" \
  "chmod:системная команда chmod отсутствует" \
  "cat:системная команда cat отсутствует"; do
  command_name="${specification%%:*}"
  explanation="${specification#*:}"
  require_command "$command_name" "$explanation"
done

SDK=""
if ! SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)" || [[ ! -d "$SDK" ]]; then
  request_command_line_tools
fi
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
SDK_MAJOR="${SDK_VERSION%%.*}"
if [[ ! "$SDK_MAJOR" =~ '^[0-9]+$' || "$SDK_MAJOR" -lt 13 ]]; then
  die "нужен macOS SDK 13 или новее; найден SDK '${SDK_VERSION:-неизвестной версии}'. Обновите Xcode или Command Line Tools"
fi
success "macOS SDK $SDK_VERSION: $SDK"

SWIFT_VERSION=""
if ! SWIFT_VERSION="$(xcrun swiftc --version 2>&1)"; then
  print -ru2 -- "$SWIFT_VERSION"
  die "Swift compiler недоступен. Установите/обновите Xcode Command Line Tools; если требуется лицензия Xcode, откройте Xcode и примите её"
fi
success "$(print -r -- "$SWIFT_VERSION" | head -n 1)"

plutil -lint "$PLIST" >/dev/null || die "Info.plist содержит ошибку"
ENGINE_SYNTAX=""
if ! ENGINE_SYNTAX="$(zsh -n "$ENGINE" 2>&1)"; then
  print -ru2 -- "$ENGINE_SYNTAX"
  die "внутренний video_engine содержит синтаксическую ошибку zsh"
fi

ICON_WIDTH="$(sips -g pixelWidth "$ICON" 2>/dev/null | awk '/pixelWidth:/ { print $2; exit }')"
ICON_HEIGHT="$(sips -g pixelHeight "$ICON" 2>/dev/null | awk '/pixelHeight:/ { print $2; exit }')"
if [[ ! "$ICON_WIDTH" =~ '^[0-9]+$' || ! "$ICON_HEIGHT" =~ '^[0-9]+$' ]]; then
  die "не удалось прочитать размеры иконки: $ICON"
fi
if (( ICON_WIDTH < 1024 || ICON_HEIGHT < 1024 )); then
  die "иконка должна быть не меньше 1024x1024; сейчас ${ICON_WIDTH}x${ICON_HEIGHT}"
fi
success "Исходники, Info.plist, video_engine и иконка проверены"

AVAILABLE_KB="$(df -Pk "$WORKSPACE" | awk 'NR == 2 { print $4 }')"
if [[ "$AVAILABLE_KB" =~ '^[0-9]+$' ]] && (( AVAILABLE_KB < 102400 )); then
  die "недостаточно свободного места: для сборки требуется минимум 100 МБ"
fi

check_runtime_tools
if [[ "$CHECK_ONLY" == "1" ]]; then
  success "Все обязательные проверки пройдены. Сборку можно запускать."
  exit 0
fi

if ! STAGING="$(mktemp -d -t video-editor-app.XXXXXX)" || [[ ! -d "$STAGING" ]]; then
  die "не удалось создать временную папку для сборки"
fi
STAGED_APP="$STAGING/Video Editor.app"
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources" || \
  die "не удалось создать структуру приложения во временной папке"

info "Компилирую Swift под Apple Silicon (arm64)"
if ! MACOSX_DEPLOYMENT_TARGET=11.0 xcrun swiftc \
  -target "arm64-apple-macos11.0" \
  -swift-version 5 \
  -O \
  -sdk "$SDK" \
  -module-cache-path "$STAGING/ModuleCache" \
  -framework AppKit \
  -framework AVFoundation \
  -framework AVKit \
  -framework UniformTypeIdentifiers \
  "$SOURCE" \
  -o "$STAGED_APP/Contents/MacOS/VideoEditor"; then
  die "Swift compiler не смог собрать приложение; исправьте ошибки, показанные выше"
fi

cp "$PLIST" "$STAGED_APP/Contents/Info.plist" || die "не удалось скопировать Info.plist"
cp "$ENGINE" "$STAGED_APP/Contents/Resources/video_engine" || die "не удалось добавить video_engine"

info "Создаю AppIcon.icns"
ICONSET="$STAGING/AppIcon.iconset"
mkdir -p "$ICONSET" || die "не удалось создать временную папку иконок"
for spec in \
  "16 icon_16x16.png" \
  "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" \
  "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" \
  "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" \
  "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" \
  "1024 icon_512x512@2x.png"; do
  size="${spec%% *}"
  name="${spec#* }"
  sips -z "$size" "$size" "$ICON" --out "$ICONSET/$name" >/dev/null || \
    die "не удалось создать размер иконки ${size}x${size}"
done

ICON_ENTRIES=(
  "icp4 icon_16x16.png"
  "ic11 icon_16x16@2x.png"
  "icp5 icon_32x32.png"
  "ic12 icon_32x32@2x.png"
  "ic07 icon_128x128.png"
  "ic13 icon_128x128@2x.png"
  "ic08 icon_256x256.png"
  "ic14 icon_256x256@2x.png"
  "ic09 icon_512x512.png"
  "ic10 icon_512x512@2x.png"
)
ICNS_SIZE=8
for entry in "${ICON_ENTRIES[@]}"; do
  name="${entry#* }"
  bytes="$(stat -f '%z' "$ICONSET/$name")" || die "не удалось определить размер $name"
  ICNS_SIZE=$((ICNS_SIZE + bytes + 8))
done
ICNS_FILE="$STAGED_APP/Contents/Resources/AppIcon.icns"
perl -e 'print "icns", pack("N", $ARGV[0])' "$ICNS_SIZE" > "$ICNS_FILE" || \
  die "не удалось создать заголовок AppIcon.icns"
for entry in "${ICON_ENTRIES[@]}"; do
  type="${entry%% *}"
  name="${entry#* }"
  bytes="$(stat -f '%z' "$ICONSET/$name")" || die "не удалось определить размер $name"
  perl -e 'print $ARGV[0], pack("N", $ARGV[1])' "$type" "$((bytes + 8))" >> "$ICNS_FILE" || \
    die "не удалось добавить $name в AppIcon.icns"
  cat "$ICONSET/$name" >> "$ICNS_FILE" || die "не удалось записать $name в AppIcon.icns"
done

chmod 755 "$STAGED_APP/Contents/MacOS/VideoEditor" || die "не удалось сделать основной бинарник исполняемым"
chmod 755 "$STAGED_APP/Contents/Resources/video_engine" || die "не удалось сделать video_engine исполняемым"
printf 'APPL????' > "$STAGED_APP/Contents/PkgInfo" || die "не удалось создать PkgInfo"

info "Проверяю собранное приложение"
plutil -lint "$STAGED_APP/Contents/Info.plist" >/dev/null || die "Info.plist в готовом bundle повреждён"
ARCHS="$(lipo -archs "$STAGED_APP/Contents/MacOS/VideoEditor" 2>/dev/null)" || \
  die "не удалось определить архитектуру собранного бинарника"
[[ " $ARCHS " == *" arm64 "* ]] || die "собран неверный бинарник: ожидалась arm64, получено '$ARCHS'"
file "$STAGED_APP/Contents/MacOS/VideoEditor" | grep -q 'arm64' || \
  die "команда file не подтверждает архитектуру arm64"

codesign --force --deep --sign - "$STAGED_APP" >/dev/null || die "не удалось подписать приложение ad-hoc подписью"
codesign --verify --deep --strict --verbose=2 "$STAGED_APP" || die "проверка подписи приложения завершилась ошибкой"

if [[ -e "$APP" ]]; then
  PREVIOUS_APP="$STAGING/Previous Video Editor.app"
  mv "$APP" "$PREVIOUS_APP" || die "не удалось временно убрать предыдущую сборку: $APP"
fi
if ! mv "$STAGED_APP" "$APP"; then
  if [[ -n "$PREVIOUS_APP" && -e "$PREVIOUS_APP" ]]; then
    mv "$PREVIOUS_APP" "$APP" || true
  fi
  die "не удалось поместить готовое приложение в $APP; предыдущая сборка восстановлена"
fi
if [[ -n "$PREVIOUS_APP" && -e "$PREVIOUS_APP" ]]; then
  rm -rf -- "$PREVIOUS_APP"
fi

success "Сборка завершена"
print -r -- "$APP"
