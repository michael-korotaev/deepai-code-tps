#!/usr/bin/env bash
# Остановка счётчика TPS на macOS: закрывает окно и хаб.
# Плагин/расширение остаются на месте — они просто не находят хаб.
#
# Использование: ./stop.sh [--port 57451] [--quiet]
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
port="${TPS_PORT:-57451}"
quiet=0

while [ $# -gt 0 ]; do
  case "$1" in
    --port) port="${2:-}"; shift 2 ;;
    --port=*) port="${1#*=}"; shift ;;
    --quiet|-q) quiet=1; shift ;;
    -h|--help) sed -n '2,5p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

say() { [ "$quiet" -eq 1 ] || echo "$@"; }

killed=0
for pattern in "$root/build/tps-overlay" "tps-overlay --port .*--repo-root $root" "$root/tps-hub.mjs" "tps-hub.mjs --port $port"; do
  for pid in $(pgrep -f "$pattern" 2>/dev/null || true); do
    [ "$pid" = "$$" ] && continue
    if kill "$pid" 2>/dev/null; then killed=$((killed + 1)); fi
  done
done

sleep 0.3

# если кто-то не отдал порт сразу — добиваем
for pattern in "$root/build/tps-overlay" "tps-overlay --port .*--repo-root $root" "$root/tps-hub.mjs" "tps-hub.mjs --port $port"; do
  pkill -9 -f "$pattern" 2>/dev/null || true
done

if [ "$quiet" -eq 0 ]; then
  say "Остановлено процессов: $killed"
  if nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
    echo "Внимание: порт $port всё ещё отвечает." >&2
  else
    say "Порт $port свободен."
  fi
fi
