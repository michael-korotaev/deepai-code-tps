param(
  [int]$Port = 57451,
  [switch]$Quiet
)

# Остановка счётчика: закрывает окно и хаб.
# Плагин/расширение остаются на месте — они просто не находят хаб.

$ErrorActionPreference = 'Continue'
$root = $PSScriptRoot
$hubPath = Join-Path $root 'tps-hub.mjs'
$overlayPath = Join-Path $root 'overlay.ps1'
$self = $PID

$killed = 0
Get-CimInstance Win32_Process |
  Where-Object {
    $_.ProcessId -ne $self -and $_.CommandLine -and (
      ($_.Name -eq 'node.exe' -and $_.CommandLine.Contains($hubPath)) -or
      ($_.Name -eq 'powershell.exe' -and $_.CommandLine.Contains($overlayPath))
    )
  } |
  ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    $killed += 1
  }

if (-not $Quiet) {
  Write-Host "Остановлено процессов: $killed"
  Start-Sleep -Milliseconds 300
  try {
    $null = Invoke-RestMethod -Uri "http://127.0.0.1:$Port/__tps/state" -TimeoutSec 1
    Write-Host "Внимание: порт $Port всё ещё отвечает." -ForegroundColor Yellow
  } catch {
    Write-Host "Порт $Port свободен."
  }
}
