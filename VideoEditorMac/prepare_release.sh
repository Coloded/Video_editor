#!/usr/bin/env zsh
set -euo pipefail

ROOT="${0:A:h}"
WORKSPACE="${ROOT:h}"
PLIST="$ROOT/Info.plist"
BUILD_SCRIPT="$ROOT/build_app.sh"
SPARKLE_FETCH="$ROOT/fetch_sparkle.sh"
UPDATES_DIR="$WORKSPACE/updates"
RELEASE_NOTES="$UPDATES_DIR/release-notes.md"
SKIP_BUILD=0
TEMP_DIR=""

die() {
  print -ru2 -- "Ошибка подготовки релиза: $*"
  exit 1
}

cleanup() {
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" && "${TEMP_DIR:t}" == video-editor-release.* ]]; then
    rm -rf -- "$TEMP_DIR"
  fi
}
trap cleanup EXIT INT TERM

usage() {
  cat <<'EOF'
Подготовка стабильного обновления Video Editor

Использование:
  ./VideoEditorMac/prepare_release.sh
  ./VideoEditorMac/prepare_release.sh --skip-build

По умолчанию скрипт собирает приложение и оба DMG, затем подписывает
Video_Editor-stable.dmg ключом Sparkle из Связки ключей и обновляет
updates/appcast.xml. Параметр --skip-build использует уже готовые DMG.
EOF
}

while (( $# > 0 )); do
  case "$1" in
    --skip-build) SKIP_BUILD=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "неизвестный параметр: $1" ;;
  esac
  shift
done

for command_name in plutil grep mktemp mkdir cp rm stat; do
  command -v "$command_name" >/dev/null 2>&1 || die "не найдена команда '$command_name'"
done
[[ -x "$BUILD_SCRIPT" ]] || die "не найден исполняемый build_app.sh"
[[ -x "$SPARKLE_FETCH" ]] || die "не найден исполняемый fetch_sparkle.sh"
[[ -f "$RELEASE_NOTES" ]] || die "не найдено описание обновления: $RELEASE_NOTES"

if [[ "$SKIP_BUILD" == "0" ]]; then
  "$BUILD_SCRIPT" --no-install
fi

APP_VERSION="$(plutil -extract CFBundleShortVersionString raw "$PLIST" 2>/dev/null || true)"
BUILD_VERSION="$(plutil -extract CFBundleVersion raw "$PLIST" 2>/dev/null || true)"
[[ "$APP_VERSION" =~ '^[0-9]+([.][0-9]+)*$' ]] || die "некорректная версия приложения"
[[ "$BUILD_VERSION" =~ '^[0-9]+$' ]] || die "некорректный номер сборки"

VERSIONED_DMG="$WORKSPACE/dist/Video-Editor-${APP_VERSION}-arm64.dmg"
STABLE_DMG="$WORKSPACE/dist/Video_Editor-stable.dmg"
[[ -s "$VERSIONED_DMG" ]] || die "не найден образ версии: $VERSIONED_DMG"
[[ -s "$STABLE_DMG" ]] || die "не найден постоянный образ: $STABLE_DMG"

SPARKLE_ROOT="$($SPARKLE_FETCH)" || die "не удалось подготовить Sparkle"
GENERATE_APPCAST="$SPARKLE_ROOT/bin/generate_appcast"
[[ -x "$GENERATE_APPCAST" ]] || die "не найден generate_appcast"

TEMP_DIR="$(mktemp -d -t video-editor-release.XXXXXX)" || die "не удалось создать временную папку"
ARCHIVES_DIR="$TEMP_DIR/archives"
mkdir -p "$ARCHIVES_DIR" "$UPDATES_DIR" || die "не удалось создать рабочие папки"
cp "$STABLE_DMG" "$ARCHIVES_DIR/Video_Editor-stable.dmg" || die "не удалось скопировать stable-DMG"
cp "$RELEASE_NOTES" "$ARCHIVES_DIR/Video_Editor-stable.md" || die "не удалось добавить описание обновления"

GENERATE_ARGS=(
  --download-url-prefix "https://github.com/Coloded/Video_editor/releases/latest/download/"
  --link "https://github.com/Coloded/Video_editor"
  --embed-release-notes
  --maximum-versions 1
  --maximum-deltas 0
  -o "$TEMP_DIR/appcast.xml"
  "$ARCHIVES_DIR"
)

if [[ -n "${SPARKLE_ED_KEY_FILE:-}" ]]; then
  "$GENERATE_APPCAST" --ed-key-file "$SPARKLE_ED_KEY_FILE" "${GENERATE_ARGS[@]}" || \
    die "generate_appcast не смог подписать обновление ключом из файла"
elif [[ -n "${SPARKLE_ED_KEY:-}" ]]; then
  print -rn -- "$SPARKLE_ED_KEY" | \
    "$GENERATE_APPCAST" --ed-key-file - "${GENERATE_ARGS[@]}" || \
    die "generate_appcast не смог подписать обновление ключом из переменной окружения"
else
  "$GENERATE_APPCAST" "${GENERATE_ARGS[@]}" || \
    die "generate_appcast не смог подписать обновление ключом из Связки ключей"
fi

[[ -s "$TEMP_DIR/appcast.xml" ]] || die "appcast.xml не создан"
grep -Fq "Video_Editor-stable.dmg" "$TEMP_DIR/appcast.xml" || die "в appcast отсутствует stable-DMG"
grep -Fq "sparkle:edSignature=" "$TEMP_DIR/appcast.xml" || die "в appcast отсутствует подпись EdDSA"
grep -Fq "<sparkle:version>$BUILD_VERSION</sparkle:version>" "$TEMP_DIR/appcast.xml" || \
  die "appcast содержит неверный номер сборки"
grep -Fq "<sparkle:shortVersionString>$APP_VERSION</sparkle:shortVersionString>" "$TEMP_DIR/appcast.xml" || \
  die "appcast содержит неверную версию приложения"

python3 "$ROOT/validate_release.py" --appcast "$TEMP_DIR/appcast.xml" || die "проверка релиза не пройдена"
cp "$TEMP_DIR/appcast.xml" "$UPDATES_DIR/appcast.xml.new"
mv -f "$UPDATES_DIR/appcast.xml.new" "$UPDATES_DIR/appcast.xml" || die "не удалось сохранить appcast.xml"

print -r -- "✓ Релиз Video Editor ${APP_VERSION} (build ${BUILD_VERSION}) подготовлен"
print -r -- "$VERSIONED_DMG"
print -r -- "$STABLE_DMG"
print -r -- "$UPDATES_DIR/appcast.xml"
print -r -- "После проверки создайте и отправьте тег v${APP_VERSION}; GitHub Actions опубликует оба DMG."
