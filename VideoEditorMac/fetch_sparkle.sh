#!/usr/bin/env zsh
set -euo pipefail

ROOT="${0:A:h}"
SPARKLE_VERSION="2.9.6"
SPARKLE_SHA256="52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192"
SPARKLE_URL="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
CACHE_ROOT="${VIDEO_EDITOR_DEPENDENCY_CACHE:-$ROOT/.build-dependencies}"
SPARKLE_ROOT="$CACHE_ROOT/Sparkle-${SPARKLE_VERSION}"
TEMP_DIR=""

die() {
  print -ru2 -- "Ошибка загрузки Sparkle: $*"
  exit 1
}

cleanup() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" && "${TEMP_DIR:t}" == .sparkle-download.* ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

valid_distribution() {
  [[ -d "$SPARKLE_ROOT/Sparkle.framework" ]] && \
    [[ -x "$SPARKLE_ROOT/bin/generate_appcast" ]] && \
    [[ -x "$SPARKLE_ROOT/bin/sign_update" ]] && \
    [[ -x "$SPARKLE_ROOT/bin/generate_keys" ]] && \
    [[ -f "$SPARKLE_ROOT/LICENSE" ]]
}

CACHED_ARCHIVE="$CACHE_ROOT/Sparkle-${SPARKLE_VERSION}.tar.xz"
archive_valid() {
  [[ -f "$CACHED_ARCHIVE" ]] && [[ "$(shasum -a 256 "$CACHED_ARCHIVE" | awk '{print $1}')" == "$SPARKLE_SHA256" ]]
}
if [[ "${1:-}" == --check-only ]]; then
  archive_valid || die "проверенный архив отсутствует; запустите fetch_sparkle.sh для подготовки зависимости"
  valid_distribution || die "Sparkle не распакован; запустите fetch_sparkle.sh"
  print -r -- "$SPARKLE_ROOT"
  exit 0
fi
[[ $# == 0 ]] || die "неизвестный параметр: $1"

for command_name in curl shasum tar awk mkdir mktemp mv rm; do
  command -v "$command_name" >/dev/null 2>&1 || die "не найдена команда '$command_name'"
done

mkdir -p "$CACHE_ROOT" || die "не удалось создать кэш зависимостей: $CACHE_ROOT"
[[ -w "$CACHE_ROOT" ]] || die "нет прав на запись в кэш зависимостей: $CACHE_ROOT"
TEMP_DIR="$(mktemp -d "$CACHE_ROOT/.sparkle-download.XXXXXX")" || \
  die "не удалось создать временную папку"
ARCHIVE="$TEMP_DIR/Sparkle-${SPARKLE_VERSION}.tar.xz"
EXTRACTED="$TEMP_DIR/extracted"
mkdir -p "$EXTRACTED" || die "не удалось создать папку распаковки"

if archive_valid; then
  cp "$CACHED_ARCHIVE" "$ARCHIVE"
else
  print -ru2 -- "▶ Загружаю Sparkle ${SPARKLE_VERSION} с официального GitHub"
  curl -fL --retry 3 --connect-timeout 20 "$SPARKLE_URL" -o "$ARCHIVE" || die "не удалось скачать официальный архив Sparkle"
fi

ACTUAL_SHA256="$(shasum -a 256 "$ARCHIVE" | awk '{ print $1 }')"
[[ "$ACTUAL_SHA256" == "$SPARKLE_SHA256" ]] || \
  die "контрольная сумма не совпала; ожидалась $SPARKLE_SHA256, получена $ACTUAL_SHA256"

tar -xJf "$ARCHIVE" -C "$EXTRACTED" || die "не удалось распаковать официальный архив"
[[ -d "$EXTRACTED/Sparkle.framework" ]] || die "в архиве отсутствует Sparkle.framework"
[[ -x "$EXTRACTED/bin/generate_appcast" ]] || die "в архиве отсутствует generate_appcast"
[[ -f "$EXTRACTED/LICENSE" ]] || die "в архиве отсутствует лицензия Sparkle"

# Always reconstruct executable dependencies from the pinned archive.
# Never bless or execute a previously extracted cache solely by file existence.
mv -f "$ARCHIVE" "$CACHED_ARCHIVE"
if [[ -e "$SPARKLE_ROOT" ]]; then mv "$SPARKLE_ROOT" "$TEMP_DIR/previous"; fi
mv "$EXTRACTED" "$SPARKLE_ROOT" || die "не удалось сохранить Sparkle в кэш"
print -ru2 -- "✓ Sparkle ${SPARKLE_VERSION} загружен и проверен по SHA-256"
print -r -- "$SPARKLE_ROOT"
