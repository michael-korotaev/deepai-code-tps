#!/usr/bin/env bash
# Собирает нативный оверлей macOS (Swift/AppKit) в build/tps-overlay.
# Нужен swiftc: Xcode или Command Line Tools (xcode-select --install).
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$root/overlay.swift"
bin="$root/build/tps-overlay"
force="${1:-}"

mkdir -p "$root/build"

if [ "$force" != "--force" ] && [ -x "$bin" ] && [ "$bin" -nt "$src" ]; then
  exit 0
fi

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc не найден. Установите Command Line Tools: xcode-select --install" >&2
  exit 1
fi

echo "Сборка окна (swiftc)…"
tmp="$bin.tmp.$$"
trap 'rm -f "$tmp"' EXIT
swiftc -O -parse-as-library -swift-version 5 -framework AppKit "$src" -o "$tmp"
mv "$tmp" "$bin"
trap - EXIT
echo "Готово: $bin"
