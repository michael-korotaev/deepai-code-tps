#!/usr/bin/env bash
# Остановка счётчика TPS на macOS: закрывает menu bar приложение и хаб.
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

app_running() {
  pgrep -f "Contents/MacOS/tps-counter" >/dev/null 2>&1 || pgrep -x tps-counter >/dev/null 2>&1
}

# --- 1. мягко закрыть приложение (оно само погасит свой хаб) ---------------
if app_running; then
  osascript -e 'tell application id "com.mikhailkorotaev.deepai-code-tps" to quit' \
    >/dev/null 2>&1 || true
  for _ in $(seq 1 25); do
    app_running || break
    sleep 0.1
  done
fi

# --- 2. добить всё, что осталось ------------------------------------------
pids() {
  {
    pgrep -f "Contents/MacOS/tps-counter" 2>/dev/null || true
    pgrep -x tps-counter 2>/dev/null || true
    pgrep -f "tps-hub.mjs --port $port" 2>/dev/null || true
    pgrep -f "$root/tps-hub.mjs" 2>/dev/null || true
    pgrep -f "$root/build/tps-overlay" 2>/dev/null || true
    pgrep -f "tps-overlay --port .*--repo-root $root" 2>/dev/null || true
  } | sort -u
}

killed=0
for pid in $(pids); do
  [ "$pid" = "$$" ] && continue
  if kill "$pid" 2>/dev/null; then killed=$((killed + 1)); fi
done

sleep 0.3

for pid in $(pids); do
  [ "$pid" = "$$" ] && continue
  kill -9 "$pid" 2>/dev/null || true
done

if [ "$quiet" -eq 0 ]; then
  say "Остановлено процессов: $killed"
  if nc -z 127.0.0.1 "$port" >/dev/null 2>&1; then
    echo "Внимание: порт $port всё ещё отвечает." >&2
  else
    say "Порт $port свободен."
  fi
fi
