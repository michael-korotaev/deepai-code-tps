#!/usr/bin/env bash
# Полный откат на macOS: убрать dsh-плагин и pi-расширение, LaunchAgent и
# процессы. Модели при этом не затрагиваются.
#
# --keep-overlay оставляет собранный «TPS Counter.app» и его логи.
#
# Использование: ./uninstall.sh [--keep-extension] [--keep-agent] [--keep-overlay]
set -uo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
keep_extension=0
keep_agent=0
keep_overlay=0

while [ $# -gt 0 ]; do
  case "$1" in
    --keep-extension) keep_extension=1; shift ;;
    --keep-agent) keep_agent=1; shift ;;
    --keep-overlay) keep_overlay=1; shift ;;
    -h|--help) sed -n '2,6p' "$0" | sed 's/^# \?//'; exit 0 ;;
    *) echo "неизвестный аргумент: $1" >&2; exit 2 ;;
  esac
done

export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"

"$root/stop.sh" --quiet

state_path="$root/install-state.json"
state_get() {
  [ -f "$state_path" ] || return 0
  node -e '
const fs = require("node:fs");
try {
  const state = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  process.stdout.write(String(state[process.argv[2]] ?? ""));
} catch {
  process.stdout.write("");
}' "$state_path" "$1"
}

if [ "$keep_extension" -eq 0 ]; then
  dsh_home="$(state_get dshHome)"
  if [ -z "$dsh_home" ] || [ ! -d "$dsh_home" ]; then
    dsh_home="${DSH_HOME:-}"
    if [ -z "$dsh_home" ] || [ ! -d "$dsh_home" ]; then
      for candidate in "$HOME/.deepai-code/userdata/deepai/dsh" "$HOME/.dsh"; do
        if [ -d "$candidate" ]; then dsh_home="$candidate"; break; fi
      done
    fi
  fi

  if [ -n "$dsh_home" ] && [ -d "$dsh_home" ]; then
    patch="$dsh_home/cordis.patch.yml"
    if [ -f "$patch" ]; then
      node "$root/scripts/patch-yaml.mjs" remove "$patch" tps-push >/dev/null || true
      echo "Запись плагина убрана из $patch"
    fi
    rm -f "$dsh_home/tps-push.mjs" && echo "dsh-плагин удалён: $dsh_home/tps-push.mjs"
    old_patch="$dsh_home/profiles/acp/cordis.patch.yml"
    if [ -f "$old_patch" ] && grep -q "tps-push" "$old_patch" 2>/dev/null; then
      node "$root/scripts/patch-yaml.mjs" remove "$old_patch" tps-push >/dev/null || true
    fi
    rm -f "$dsh_home/profiles/acp/tps-push.mjs"
  fi

  extension_path="$(state_get extensionPath)"
  if [ -z "$extension_path" ]; then
    agent_dir="${PI_CODING_AGENT_DIR:-$HOME/.deepai-code/userdata/deepai/pi/deepai}"
    extension_path="$agent_dir/extensions/tps-push.js"
  fi
  if [ -f "$extension_path" ]; then
    rm -f "$extension_path" && echo "pi-расширение удалено: $extension_path"
  fi
fi

if [ "$keep_agent" -eq 0 ]; then
  plist="$HOME/Library/LaunchAgents/com.deepai-code.tps.plist"
  if [ -f "$plist" ] || launchctl print "gui/$UID/com.deepai-code.tps" >/dev/null 2>&1; then
    launchctl bootout "gui/$UID/com.deepai-code.tps" >/dev/null 2>&1 || true
    launchctl unload "$plist" >/dev/null 2>&1 || true
    rm -f "$plist"
    echo "LaunchAgent удалён."
  fi
fi

rm -f "$state_path"
if [ "$keep_overlay" -eq 0 ]; then
  rm -rf "$root/build" "$root/macos/dist"
  rm -rf "$HOME/Library/Application Support/TPS Counter"
fi
echo "Готово. Модели подключены напрямую, измеритель выключен."
