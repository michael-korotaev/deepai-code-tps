param(
  [int]$Port = 57451,
  [switch]$Quiet
)

# Запуск счётчика: хаб метрик + окно-оверлей. Идемпотентно.
# models.json не трогает — модель всегда подключена напрямую.

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$logDir = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

$hubPath = Join-Path $root 'tps-hub.mjs'
$overlayPath = Join-Path $root 'overlay.ps1'

function Test-Port([int]$p) {
  try {
    $c = New-Object System.Net.Sockets.TcpClient
    $c.Connect('127.0.0.1', $p)
    $c.Close()
    return $true
  } catch { return $false }
}

# 1. Хаб
if (Test-Port $Port) {
  if (-not $Quiet) { Write-Host "Хаб уже слушает 127.0.0.1:$Port" }
} else {
  $nodeArgs = @($hubPath, '--port', "$Port")
  Start-Process -FilePath 'node' -ArgumentList $nodeArgs -WindowStyle Hidden -RedirectStandardOutput (Join-Path $logDir 'hub.log') -RedirectStandardError (Join-Path $logDir 'hub.log.err') | Out-Null
  for ($i = 0; $i -lt 30 -and -not (Test-Port $Port); $i++) { Start-Sleep -Milliseconds 100 }
  if (-not (Test-Port $Port)) {
    Write-Host "Не удалось поднять хаб. Смотрите $(Join-Path $logDir 'hub.log.err')" -ForegroundColor Red
    exit 1
  }
  if (-not $Quiet) { Write-Host "Хаб запущен: 127.0.0.1:$Port" }
}

# 2. Окно
$overlay = Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'powershell.exe' -and $_.CommandLine -and $_.CommandLine.Contains($overlayPath) }
if ($overlay) {
  if (-not $Quiet) { Write-Host 'Окно уже открыто.' }
} else {
  Start-Process -FilePath 'powershell.exe' -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Sta', '-File', $overlayPath -RedirectStandardOutput (Join-Path $logDir 'overlay.log') -RedirectStandardError (Join-Path $logDir 'overlay.log.err') | Out-Null
  if (-not $Quiet) { Write-Host 'Окно запущено.' }
}

if (-not $Quiet) {
  Start-Sleep -Milliseconds 500
  try {
    $s = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/__tps/state" -TimeoutSec 2
    Write-Host ("Состояние: {0} · модель {1}" -f $(if ($s.active) { 'генерация' } else { 'idle' }), $(if ($s.model) { $s.model } else { '—' }))
  } catch { }
  Write-Host "Дашборд: http://127.0.0.1:$Port/__tps/"
}
