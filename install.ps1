param(
  [int]$Port = 57451,
  [switch]$NoTask,
  [switch]$NoShortcut,
  [switch]$NoStart,
  [switch]$Quiet
)

# Установка счётчика TPS:
#   1) dsh-плагин tps-push.mjs в машинный слой движка (DeepAI Code 0.3.x);
#   2) pi-расширение tps-push.js в <agent-dir>/extensions (старые/pi-чаты);
#   3) задача Планировщика на вход в систему (тихий запуск через autostart.vbs);
#   4) ярлык в меню «Пуск»;
#   5) запускает хаб и оверлей.
# models.json НЕ меняется: прямое подключение к модели остаётся как есть.
#
# Плагин ставится НЕ в profiles/acp: приложение при каждом старте удаляет
# $DSH_HOME/profiles целиком и создаёт заново. Машинный слой
# $DSH_HOME/cordis.patch.yml приложение не трогает.

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$logDir = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$statePath = Join-Path $root 'install-state.json'
$state = [ordered]@{}
if (Test-Path $statePath) {
  try {
    $prev = Get-Content $statePath -Raw | ConvertFrom-Json
    foreach ($name in 'agentDir', 'extensionPath', 'dshHome', 'dshPatchPath', 'dshPluginPath', 'shortcutPath', 'taskName') {
      $value = $prev.$name
      if ($value) { $state[$name] = [string]$value }
    }
  } catch { }
}

# --- 1. dsh-плагин (DeepAI Code 0.3.x, движок dsh) -------------------------
$dshHome = $env:DSH_HOME
if (-not $dshHome) { $dshHome = Join-Path $env:USERPROFILE '.deepai-code/userdata/deepai/dsh' }
if (-not (Test-Path $dshHome)) {
  $alt = Join-Path $env:USERPROFILE '.dsh'
  if (Test-Path $alt) { $dshHome = $alt }
}
$dshSource = Join-Path $root 'dsh/tps-push.mjs'
$dshTarget = Join-Path $dshHome 'tps-push.mjs'
$patchPath = Join-Path $dshHome 'cordis.patch.yml'

if ((Test-Path $dshSource) -and (Test-Path $dshHome)) {
  Copy-Item $dshSource $dshTarget -Force
  $current = ''
  if (Test-Path $patchPath) { $current = Get-Content $patchPath -Raw }
  if ($current -notmatch 'tps-push') {
    $entry = @(
      '# Машинный слой dsh: применяется после слоя профиля и до --patch приложения.',
      '# Профиль приложение пересоздаёт, а этот файл — нет.',
      '- insert:',
      '    - id: tps-push',
      '      name: ./tps-push.mjs'
    ) -join [Environment]::NewLine
    if ($current.Trim() -eq '' -or $current.Trim() -eq '[]') {
      Set-Content -Path $patchPath -Value ($entry + [Environment]::NewLine) -Encoding utf8
    } else {
      Add-Content -Path $patchPath -Value $entry -Encoding utf8
    }
  }
  $state['dshHome'] = $dshHome
  $state['dshPatchPath'] = $patchPath
  $state['dshPluginPath'] = $dshTarget

  # подчистить следы старой установки в профиле
  $oldProfilePatch = Join-Path $dshHome 'profiles/acp/cordis.patch.yml'
  if ((Test-Path $oldProfilePatch) -and ((Get-Content $oldProfilePatch -Raw) -match 'tps-push')) {
    Set-Content -Path $oldProfilePatch -Value '[]' -Encoding utf8
  }
  if (-not $Quiet) { Write-Host "dsh-плагин установлен: $dshTarget" }
} else {
  if (-not $Quiet) { Write-Host "dsh-профиль не найден — пропускаю dsh-плагин ($dshHome)" -ForegroundColor Yellow }
}

# --- 2. pi-расширение (на случай pi-чатов) ---------------------------------
$agentDir = $env:PI_CODING_AGENT_DIR
if (-not $agentDir) { $agentDir = Join-Path $env:USERPROFILE '.deepai-code/userdata/deepai/pi/deepai' }
$extDir = Join-Path $agentDir 'extensions'
$extSource = Join-Path $root 'extension/tps-push.js'
$extTarget = Join-Path $extDir 'tps-push.js'

if ((Test-Path $extSource) -and (Test-Path $agentDir)) {
  New-Item -ItemType Directory -Force -Path $extDir | Out-Null
  Copy-Item $extSource $extTarget -Force
  foreach ($legacy in 'tps-push.ts', 'tps-push.js.bak') {
    $p = Join-Path $extDir $legacy
    if (Test-Path $p) { Remove-Item $p -Force }
  }
  $state['agentDir'] = $agentDir
  $state['extensionPath'] = $extTarget
  if (-not $Quiet) { Write-Host "pi-расширение установлено: $extTarget" }
}

# --- 3. автозапуск при входе в систему -------------------------------------
$taskName = 'DeepAI TPS Overlay'
$launcher = Join-Path $root 'autostart.vbs'
if ($NoTask) {
  if (-not $Quiet) { Write-Host 'Автозапуск не менялся (-NoTask).' }
} elseif (-not (Test-Path $launcher)) {
  if (-not $Quiet) { Write-Host "Нет $launcher — автозапуск пропущен." -ForegroundColor Yellow }
} else {
  $wscriptPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
  $action = New-ScheduledTaskAction -Execute $wscriptPath -Argument ('//B "{0}"' -f $launcher)
  $trigger = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
  $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable
  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings -Description 'Индикатор токенов/сек для DeepAI Code' -Force | Out-Null
  $state['taskName'] = $taskName
  if (-not $Quiet) { Write-Host "Автозапуск: задача '$taskName' (без окна консоли)" }
}

# --- 4. ярлык в меню «Пуск» ------------------------------------------------
if (-not $NoShortcut) {
  $shortcutDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
  $shortcutPath = Join-Path $shortcutDir 'DeepAI TPS.lnk'
  $wsh = New-Object -ComObject WScript.Shell
  $sc = $wsh.CreateShortcut($shortcutPath)
  $sc.TargetPath = Join-Path $env:SystemRoot 'System32\wscript.exe'
  $sc.Arguments = '//B "' + $launcher + '"'
  $sc.WorkingDirectory = $root
  $sc.IconLocation = (Join-Path $env:SystemRoot 'System32\shell32.dll') + ',137'
  $sc.Description = 'DeepAI TPS — скорость генерации токенов'
  $sc.WindowStyle = 7
  $sc.Save()
  $state['shortcutPath'] = $shortcutPath
  if (-not $Quiet) {
    Write-Host "Ярлык в «Пуске»: $shortcutPath"
    Write-Host 'Чтобы вынести его на «Начальный экран»: правый клик по ярлыку в «Пуске» → «Закрепить в меню "Пуск"».'
  }
}

$state['port'] = $Port
$state['installedAt'] = (Get-Date).ToString('o')
$state | ConvertTo-Json -Depth 6 | Set-Content -Path $statePath -Encoding utf8

if (-not $NoStart) {
  & (Join-Path $root 'start.ps1') -Port $Port -Quiet
}

if (-not $Quiet) {
  Write-Host ''
  Write-Host 'Готово. Метрики пойдут в новых чатах (плагин читается при старте чата).'
  Write-Host "Дашборд: http://127.0.0.1:$Port/__tps/"
}
