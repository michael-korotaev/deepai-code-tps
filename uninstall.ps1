param([switch]$KeepTask, [switch]$KeepExtension)

# Полный откат: убрать dsh-плагин и pi-расширение, задачу и процессы.

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$statePath = Join-Path $root 'install-state.json'

& (Join-Path $root 'stop.ps1') -Quiet

$state = $null
if (Test-Path $statePath) {
  try { $state = Get-Content $statePath -Raw | ConvertFrom-Json } catch { }
}

if (-not $KeepExtension) {
  # dsh-плагин: машинный слой $DSH_HOME/cordis.patch.yml
  $dshHome = $null
  if ($state -and $state.dshHome) { $dshHome = [string]$state.dshHome }
  if (-not $dshHome) {
    $dshHome = $env:DSH_HOME
    if (-not $dshHome) { $dshHome = Join-Path $env:USERPROFILE '.deepai-code/userdata/deepai/dsh' }
  }
  $patchPath = Join-Path $dshHome 'cordis.patch.yml'
  $pluginPath = Join-Path $dshHome 'tps-push.mjs'

  if (Test-Path $patchPath) {
    $nl = [Environment]::NewLine
    $text = Get-Content $patchPath -Raw
    $block = '- insert:' + $nl + '    - id: tps-push' + $nl + '      name: ./tps-push.mjs'
    $text = $text.Replace($block, '')
    $text = $text.Replace($block.Replace($nl, [string][char]10), '')
    $kept = $text -split [string][char]10 | Where-Object {
      $_.Trim() -ne '' -and
      $_ -notmatch 'Машинный слой dsh' -and
      $_ -notmatch 'Профиль приложение пересоздаёт' -and
      $_ -notmatch 'applied after the profile layer' -and
      $_ -notmatch "app's --patch overlay" -and
      $_ -notmatch 'profile reset'
    }
    if (@($kept | Where-Object { $_.TrimStart().StartsWith('-') }).Count -eq 0) {
      Remove-Item $patchPath -Force
      Write-Host "Машинный слой удалён: $patchPath"
    } else {
      Set-Content -Path $patchPath -Value ($kept -join [Environment]::NewLine) -Encoding utf8
      Write-Host "Запись плагина убрана из $patchPath"
    }
  }
  if (Test-Path $pluginPath) {
    Remove-Item $pluginPath -Force
    Write-Host "dsh-плагин удалён: $pluginPath"
  }
  # следы старой установки в профиле
  $oldPatch = Join-Path $dshHome 'profiles/acp/cordis.patch.yml'
  if ((Test-Path $oldPatch) -and ((Get-Content $oldPatch -Raw) -match 'tps-push')) {
    Set-Content -Path $oldPatch -Value '[]' -Encoding utf8
  }
  $oldPlugin = Join-Path $dshHome 'profiles/acp/tps-push.mjs'
  if (Test-Path $oldPlugin) { Remove-Item $oldPlugin -Force }

  # pi-расширение
  $ext = $null
  if ($state -and $state.extensionPath) { $ext = [string]$state.extensionPath }
  if (-not $ext) {
    $agentDir = if ($env:PI_CODING_AGENT_DIR) { $env:PI_CODING_AGENT_DIR } else { Join-Path $env:USERPROFILE '.deepai-code/userdata/deepai/pi/deepai' }
    $ext = Join-Path $agentDir 'extensions/tps-push.js'
  }
  if (Test-Path $ext) {
    Remove-Item $ext -Force
    Write-Host "pi-расширение удалено: $ext"
  }
}

if (-not $KeepTask) {
  $taskName = 'DeepAI TPS Overlay'
  if ($state -and $state.taskName) { $taskName = [string]$state.taskName }
  Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
  Write-Host "Задача Планировщика удалена: $taskName"
}

$lnk = $null
if ($state -and $state.shortcutPath) { $lnk = [string]$state.shortcutPath }
if (-not $lnk) { $lnk = Join-Path $env:APPDATA 'Microsoft/Windows/Start Menu/Programs/DeepAI TPS.lnk' }
if (Test-Path $lnk) {
  Remove-Item $lnk -Force
  Write-Host "Ярлык в «Пуске» удалён: $lnk"
}

Remove-Item $statePath -Force -ErrorAction SilentlyContinue
Write-Host 'Готово. Модели подключены напрямую, измеритель выключен.'
