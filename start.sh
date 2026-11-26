#!/usr/bin/env bash
# Включение счётчика TPS на macOS: хаб метрик + окно-оверлей. Идемпотентно.
# models.json не трогает — модель всегда подключена напрямую.
#
# Использование: ./start.sh [--port 57451] [--quiet] [--no-overlay]
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
port="${TPS_PORT:-57451}"
quiet=0
with_overlay=1

while [ $# -gt 0 ]; do
  case "$1" in
    --port) port="${2:-}"; shift 2 ;;
    --port=*) port="${1#*=}"; shift ;;
    --quiet|-q) quiet=1; shift ;;
    --no-overlay) with_overlay=0; shift ;;
    -h|--help) sed -n '2,5p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

say() { [ "$quiet" -eq 1 ] || echo "$@"; }

# launchd запускает агента с минимальным PATH — добавляем обычные места Homebrew
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

mkdir -p "$root/logs"

node_bin="$(command -v node 2>/dev/null || true)"
if [ -z "$node_bin" ]; then
  echo "node не найден в PATH (нужен Node.js 18+)." >&2
  exit 1
fi

port_open() { nc -z 127.0.0.1 "$1" >/dev/null 2>&1; }

# --- 1. хаб метрик ---------------------------------------------------------
if port_open "$port"; then
  say "Хаб уже слушает 127.0.0.1:$port"
else
  nohup "$node_bin" "$root/tps-hub.mjs" --port "$port" \
    >>"$root/logs/hub.log" 2>>"$root/logs/hub.log.err" &
  disown 2>/dev/null || true
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
    port_open "$port" && break
    sleep 0.1
  done
  if ! port_open "$port"; then
    echo "Не удалось поднять хаб. Смотрите $root/logs/hub.log.err" >&2
    exit 1
  fi
  say "Хаб запущен: 127.0.0.1:$port"
fi

# --- 2. окно ---------------------------------------------------------------
if [ "$with_overlay" -eq 1 ]; then
  if ! "$root/scripts/build-overlay.sh"; then
    echo "Окно не собрано — счётчик работает только в дашборде." >&2
  else
    bin="$root/build/tps-overlay"
    if pgrep -f "tps-overlay .*--repo-root $root" >/dev/null 2>&1; then
      say "Окно уже открыто."
    else
      nohup "$bin" --port "$port" --repo-root "$root" --node "$node_bin" \
        >>"$root/logs/overlay.log" 2>>"$root/logs/overlay.log.err" &
      disown 2>/dev/null || true
      sleep 0.4
      say "Окно запущено."
    fi
  fi
fi

if [ "$quiet" -eq 0 ]; then
  sleep 0.2
  curl -s -m 2 "http://127.0.0.1:$port/__tps/state" | "$node_bin" -e '
let raw = "";
process.stdin.on("data", (chunk) => { raw += chunk; });
process.stdin.on("end", () => {
  try {
    const state = JSON.parse(raw);
    console.log(`Состояние: ${state.active ? "генерация" : "idle"} · модель ${state.model ?? "—"}`);
  } catch {
    /* хаб не ответил — молчим */
  }
});'
  echo "Дашборд: http://127.0.0.1:$port/__tps/"
fi
