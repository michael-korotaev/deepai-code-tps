#!/usr/bin/env bash
# Сборка «TPS Counter.app» — menu bar приложения для macOS.
#
#   ./macos/build.sh          # пересобрать при изменении исходников
#   ./macos/build.sh --force  # пересобрать принудительно
#
# Результат: macos/dist/TPS Counter.app (внутри — бинарь tps-counter и хаб tps-hub.mjs).

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$root/.." && pwd)"
app="$root/dist/TPS Counter.app"
exe="$app/Contents/MacOS/tps-counter"
src="$root/TPSApp.swift"
plist="$root/Info.plist"
hub="$repo/tps-hub.mjs"

force=0
case "${1:-}" in
  --force|-f) force=1 ;;
  "" ) ;;
  * ) echo "Неизвестный аргумент: $1" >&2; exit 1 ;;
esac

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc не найден. Установите Xcode Command Line Tools: xcode-select --install" >&2
  exit 1
fi

if [[ $force -eq 0 && -x "$exe" && "$exe" -nt "$src" && "$exe" -nt "$plist" && "$exe" -nt "$hub" ]]; then
  echo "TPS Counter.app актуален: $app"
  exit 0
fi

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
tmp="$exe.tmp.$$"
trap 'rm -f "$tmp"' EXIT

echo "Собираю TPS Counter.app…"
swiftc -O -parse-as-library -swift-version 5 \
  -framework AppKit -framework SwiftUI \
  "$src" -o "$tmp"
mv "$tmp" "$exe"
chmod +x "$exe"

cp "$plist" "$app/Contents/Info.plist"
cp "$hub" "$app/Contents/Resources/tps-hub.mjs"
printf 'APPL????' > "$app/Contents/PkgInfo"

# ad-hoc подпись: стабильный идентификатор для LaunchServices и LaunchAgent
codesign --force --sign - "$app" >/dev/null 2>&1 || true

echo "Готово: $app"
