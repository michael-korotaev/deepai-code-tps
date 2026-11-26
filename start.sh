#!/usr/bin/env bash
# Включение счётчика TPS на macOS: menu bar приложение и встроенный хаб метрик.
# Идемпотентно; models.json не трогает — модель всегда подключена напрямую.
#
# Использование: ./start.sh [--port 57451] [--quiet] [--no-app]
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
app="$root/macos/dist/TPS Counter.app"
port="${TPS_PORT:-57451}"
quiet=0
with_app=1

while [ $# -gt 0 ]; do
  case "$1" in
    --port) port="${2:-}"; shift 2 ;;
    --port=*) port="${1#*=}"; shift ;;
    --quiet|-q) quiet=1; shift ;;
    --no-app|--no-overlay) with_app=0; shift ;;
    -h|--help) sed -n '2,5p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

say() { [ "$quiet" -eq 1 ] || echo "$@"; }

# launchd запускает агента с минимальным PATH — добавляем обычные места Homebrew
export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

mkdir -p "$root/logs"

port_open() { nc -z 127.0.0.1 "$1" >/dev/null 2>&1; }
app_running() {
  pgrep -f "Contents/MacOS/tps-counter" >/dev/null 2>&1 || pgrep -x tps-counter >/dev/null 2>&1
}

# старый плавающий оверлей (до перехода на .app) не должен висеть рядом
pkill -f "$root/build/tps-overlay" >/dev/null 2>&1 || true
pkill -f "tps-overlay --port .*--repo-root $root" >/dev/null 2>&1 || true

if ! "$root/macos/build.sh"; then
  echo "Приложение не собрано." >&2
  exit 1
fi

# --- 1. приложение в menu bar ---------------------------------------------
if [ "$with_app" -eq 1 ]; then
  if app_running; then
    say "Приложение уже запущено (значок в строке меню)."
  elif open "$app" --args --port "$port" >/dev/null 2>&1; then
    say "Приложение запущено: значок в строке меню."
  else
    # запасной путь без LaunchServices (например, из ssh-сессии)
    nohup "$app/Contents/MacOS/tps-counter" --port "$port" \
      >>"$root/logs/app.log" 2>>"$root/logs/app.log.err" &
    disown 2>/dev/null || true
    say "Приложение запущено напрямую."
  fi

  for _ in $(seq 1 50); do
    port_open "$port" && break
    sleep 0.1
  done
  if ! port_open "$port"; then
    echo "Хаб не поднялся. Логи: ~/Library/Application Support/TPS Counter/logs/" >&2
    exit 1
  fi
else
  # только хаб, без menu bar приложения
  node_bin="$(command -v node 2>/dev/null || true)"
  if [ -z "$node_bin" ]; then
    echo "node не найден в PATH (нужен Node.js 18+)." >&2
    exit 1
  fi
  if port_open "$port"; then
    say "Хаб уже слушает 127.0.0.1:$port"
  else
    nohup "$node_bin" "$root/tps-hub.mjs" --port "$port" \
      >>"$root/logs/hub.log" 2>>"$root/logs/hub.log.err" &
    disown 2>/dev/null || true
    for _ in $(seq 1 30); do
      port_open "$port" && break
      sleep 0.1
    done
    if ! port_open "$port"; then
      echo "Не удалось поднять хаб. Смотрите $root/logs/hub.log.err" >&2
      exit 1
    fi
    say "Хаб запущен: 127.0.0.1:$port"
  fi
fi

if [ "$quiet" -eq 0 ]; then
  sleep 0.2
  if command -v node >/dev/null 2>&1; then
    curl -s -m 2 "http://127.0.0.1:$port/__tps/state" | node -e '
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
  fi
  echo "Дашборд: http://127.0.0.1:$port/__tps/"
  if [ "$with_app" -eq 1 ]; then
    echo "Свернуть/показать — клик по значку в строке меню."
  fi
fi
