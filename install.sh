#!/usr/bin/env bash
# Установка измерителя TPS на macOS:
#   1) dsh-плагин tps-push.mjs в машинный слой движка (DeepAI Code 0.3.x);
#   2) pi-расширение tps-push.js в <agent-dir>/extensions (старые/pi-чаты);
#   3) при --with-agent — LaunchAgent на вход в систему;
#   4) собирает menu bar приложение «TPS Counter.app» и запускает его.
# models.json НЕ меняется: прямое подключение к модели остаётся как есть.
#
# Плагин ставится НЕ в profiles/acp: приложение при каждом старте пересоздаёт
# $DSH_HOME/profiles. Машинный слой $DSH_HOME/cordis.patch.yml оно не трогает.
#
# Использование: ./install.sh [--port 57451] [--with-agent] [--no-start] [--quiet]
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
port="${TPS_PORT:-57451}"
with_agent=0
no_start=0
quiet=0

while [ $# -gt 0 ]; do
  case "$1" in
    --port) port="${2:-}"; shift 2 ;;
    --port=*) port="${1#*=}"; shift ;;
    --with-agent) with_agent=1; shift ;;
    --no-start) no_start=1; shift ;;
    --quiet|-q) quiet=1; shift ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

say() { [ "$quiet" -eq 1 ] || echo "$@"; }

export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"
mkdir -p "$root/logs"

if ! command -v node >/dev/null 2>&1; then
  echo "node не найден в PATH (нужен Node.js 18+)." >&2
  exit 1
fi

state_path="$root/install-state.json"

json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# --- 1. dsh-плагин (DeepAI Code 0.3.x, движок dsh) -------------------------
dsh_home="${DSH_HOME:-}"
if [ -z "$dsh_home" ] || [ ! -d "$dsh_home" ]; then
  dsh_home=""
  for candidate in "$HOME/.deepai-code/userdata/deepai/dsh" "$HOME/.dsh"; do
    if [ -d "$candidate" ]; then dsh_home="$candidate"; break; fi
  done
fi

dsh_plugin=""
dsh_patch=""
if [ -n "$dsh_home" ] && [ -f "$root/dsh/tps-push.mjs" ]; then
  dsh_plugin="$dsh_home/tps-push.mjs"
  dsh_patch="$dsh_home/cordis.patch.yml"
  cp -f "$root/dsh/tps-push.mjs" "$dsh_plugin"
  if [ -f "$dsh_patch" ]; then
    cp -f "$dsh_patch" "$dsh_patch.bak-$(date +%Y%m%d-%H%M%S)"
  fi
  node "$root/scripts/patch-yaml.mjs" add "$dsh_patch" tps-push ./tps-push.mjs >/dev/null
  say "dsh-плагин установлен: $dsh_plugin"

  # следы старой установки в профиле (профиль приложение пересоздаёт)
  old_patch="$dsh_home/profiles/acp/cordis.patch.yml"
  if [ -f "$old_patch" ] && grep -q "tps-push" "$old_patch" 2>/dev/null; then
    node "$root/scripts/patch-yaml.mjs" remove "$old_patch" tps-push >/dev/null || true
  fi
else
  say "dsh-профиль не найден — пропускаю dsh-плагин (${dsh_home:-нет каталога})"
fi

# --- 2. pi-расширение (на случай pi-чатов) ---------------------------------
agent_dir="${PI_CODING_AGENT_DIR:-$HOME/.deepai-code/userdata/deepai/pi/deepai}"
extension_path=""
if [ -d "$agent_dir" ] && [ -f "$root/extension/tps-push.js" ]; then
  mkdir -p "$agent_dir/extensions"
  extension_path="$agent_dir/extensions/tps-push.js"
  cp -f "$root/extension/tps-push.js" "$extension_path"
  rm -f "$agent_dir/extensions/tps-push.ts" "$agent_dir/extensions/tps-push.js.bak"
  say "pi-расширение установлено: $extension_path"
fi

# --- 3. состояние установки ------------------------------------------------
installed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
cat > "$state_path" <<EOF
{
  "dshHome": "$(json_escape "${dsh_home:-}")",
  "dshPatchPath": "$(json_escape "${dsh_patch:-}")",
  "dshPluginPath": "$(json_escape "${dsh_plugin:-}")",
  "agentDir": "$(json_escape "$agent_dir")",
  "extensionPath": "$(json_escape "$extension_path")",
  "appPath": "$(json_escape "$root/macos/dist/TPS Counter.app")",
  "port": $port,
  "installedAt": "$installed_at"
}
EOF

# --- 4. автозапуск (только по --with-agent) --------------------------------
if [ "$with_agent" -eq 1 ]; then
  plist="$HOME/Library/LaunchAgents/com.deepai-code.tps.plist"
  mkdir -p "$(dirname "$plist")"
  cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.deepai-code.tps</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-a</string>
    <string>$root/macos/dist/TPS Counter.app</string>
    <string>--args</string>
    <string>--port</string>
    <string>$port</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>LimitLoadToSessionType</key><string>Aqua</string>
  <key>StandardOutPath</key><string>$root/logs/agent.log</string>
  <key>StandardErrorPath</key><string>$root/logs/agent.log.err</string>
</dict>
</plist>
EOF
  launchctl bootout "gui/$UID/com.deepai-code.tps" >/dev/null 2>&1 || true
  if ! launchctl bootstrap "gui/$UID" "$plist" >/dev/null 2>&1; then
    launchctl load -w "$plist" >/dev/null 2>&1 || true
  fi
  say "LaunchAgent установлен: $plist"
fi

# --- 5. приложение в menu bar и хаб ----------------------------------------
if ! "$root/macos/build.sh"; then
  echo "TPS Counter.app не собрано." >&2
  exit 1
fi

if [ "$no_start" -eq 0 ]; then
  # перезапуск, чтобы подхватить свежую сборку
  "$root/stop.sh" --quiet || true
  if [ "$quiet" -eq 1 ]; then
    "$root/start.sh" --port "$port" --quiet
  else
    "$root/start.sh" --port "$port"
  fi
fi

if [ "$quiet" -eq 0 ]; then
  echo
  echo "Готово. Значок TPS — в строке меню. Метрики пойдут в новых чатах (плагин читается при старте чата)."
  echo "Дашборд: http://127.0.0.1:$port/__tps/"
fi
