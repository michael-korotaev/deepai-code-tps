param(
  [int]$Port = 57451,
  [int]$IntervalMs = 150,
  [switch]$NoWatchdog
)

# Компактный оверлей «токены/сек»: одна строка, всегда сверху.
# Читает http://127.0.0.1:<Port>/__tps/state у tps-hub.mjs.
# Перетаскивание — левой кнопкой, закрыть — двойной клик.

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$root = $PSScriptRoot
$logDir = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$hubLog = Join-Path $logDir 'hub.log'
$hubScript = Join-Path $root 'tps-hub.mjs'
$posFile = Join-Path $root 'overlay-pos.txt'
$stateUrl = "http://127.0.0.1:$Port/__tps/state"

function Test-Port([int]$p) {
  try {
    $c = New-Object System.Net.Sockets.TcpClient
    $c.Connect('127.0.0.1', $p)
    $c.Close()
    return $true
  } catch { return $false }
}

function Start-Hub {
  if (Test-Port $Port) { return }
  Start-Process -FilePath 'node' -ArgumentList @($hubScript, '--port', "$Port") -WindowStyle Hidden -RedirectStandardOutput $hubLog -RedirectStandardError "$hubLog.err" | Out-Null
}

Start-Hub

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ShowActivated="False"
        ResizeMode="NoResize" Width="240" Height="32" Title="DeepAI TPS">
  <Border Background="#F0131620" CornerRadius="8" BorderBrush="#28FFFFFF" BorderThickness="1" Padding="9,0">
    <Grid>
      <Grid.ColumnDefinitions>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="Auto"/>
        <ColumnDefinition Width="*"/>
        <ColumnDefinition Width="Auto"/>
      </Grid.ColumnDefinitions>
      <Ellipse x:Name="Dot" Grid.Column="0" Width="6" Height="6" Fill="#3A4050" VerticalAlignment="Center" Margin="0,0,7,0"/>
      <StackPanel Grid.Column="1" Orientation="Horizontal" VerticalAlignment="Center">
        <TextBlock x:Name="TpsText" Text="0.0" FontSize="15" FontWeight="Bold" FontFamily="Consolas" Foreground="#4A5364"/>
        <TextBlock Text="tok/s" FontSize="9" Foreground="#7C869B" VerticalAlignment="Bottom" Margin="4,0,0,2"/>
      </StackPanel>
      <TextBlock x:Name="MetaText" Grid.Column="3" Text="idle" FontSize="9.5" Foreground="#8A94A8"
                 VerticalAlignment="Center" HorizontalAlignment="Right" Margin="8,0,0,0"/>
    </Grid>
  </Border>
</Window>
'@

[xml]$xml = $xaml
$reader = New-Object System.Xml.XmlNodeReader $xml
$window = [Windows.Markup.XamlReader]::Load($reader)
$window.Cursor = [System.Windows.Input.Cursors]::SizeAll

$ui = @{}
foreach ($name in 'Dot', 'TpsText', 'MetaText') {
  $ui[$name] = $window.FindName($name)
}

# Позиция запоминается между запусками
if (Test-Path $posFile) {
  try {
    $pos = Get-Content $posFile -Raw | ConvertFrom-Json
    if ($pos.Left -gt -10000) { $window.Left = [double]$pos.Left; $window.Top = [double]$pos.Top }
  } catch { }
}
# не даём окну уехать за край экрана (например, после смены разрешения)
$work = [System.Windows.SystemParameters]::WorkArea
$maxLeft = $work.Right - $window.Width - 8
$maxTop = $work.Bottom - $window.Height - 8
if ($window.Left -lt $work.Left) { $window.Left = $work.Left + 8 }
if ($window.Top -lt $work.Top) { $window.Top = $work.Top + 8 }
if ($window.Left -gt $maxLeft) { $window.Left = $maxLeft }
if ($window.Top -gt $maxTop) { $window.Top = $maxTop }
if ($window.Left -eq 0 -and $window.Top -eq 0) { $window.Top = $work.Top + 12 }
try { @{ Left = $window.Left; Top = $window.Top } | ConvertTo-Json | Set-Content $posFile -Encoding utf8 } catch { }

$script:dragging = $false
$script:dragStart = $null
$window.Add_MouseLeftButtonDown({
  if ($_.ClickCount -eq 2) { $window.Close(); return }
  $script:dragging = $true
  $script:dragStart = @($_.GetPosition($window).X, $_.GetPosition($window).Y, $window.Left, $window.Top)
  $window.CaptureMouse() | Out-Null
})
$window.Add_MouseLeftButtonUp({
  $script:dragging = $false
  $window.ReleaseMouseCapture()
  try { @{ Left = $window.Left; Top = $window.Top } | ConvertTo-Json | Set-Content $posFile -Encoding utf8 } catch { }
})
$window.Add_MouseMove({
  if (-not $script:dragging) { return }
  $p = $_.GetPosition($window)
  $window.Left = [double]$script:dragStart[2] + ($p.X - [double]$script:dragStart[0])
  $window.Top = [double]$script:dragStart[3] + ($p.Y - [double]$script:dragStart[1])
})

function Get-StateColor([double]$v) {
  if ($v -ge 45) { '#44DDFF' }
  elseif ($v -ge 30) { '#00FF88' }
  elseif ($v -ge 15) { '#FFAA00' }
  elseif ($v -gt 0) { '#FF6666' }
  else { '#4A5364' }
}

function F1($v) {
  if ($null -eq $v) { return '—' }
  return ([double]$v).ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-Ms($ms) {
  if ($null -eq $ms) { return '—' }
  if ($ms -le 0) { return '—' }
  if ($ms -lt 1000) { return ('{0} ms' -f [int]$ms) }
  return (([double]$ms / 1000.0).ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture) + ' s')
}

$script:failures = 0
$tick = {
  try {
    $s = Invoke-RestMethod -Uri $stateUrl -TimeoutSec 1
    $script:failures = 0
  } catch {
    $script:failures += 1
    $ui.TpsText.Text = '—'
    $ui.TpsText.Foreground = '#4A5364'
    $ui.Dot.Fill = '#3A4050'
    $ui.MetaText.Text = 'off'
    return
  }

  $active = [bool]$s.active
  $tps = 0.0
  if ($active -and $s.tps) { $tps = [double]$s.tps }

  $ui.TpsText.Text = F1 $tps
  $ui.TpsText.Foreground = Get-StateColor $tps
  $ui.Dot.Fill = if ($active) { '#00E08A' } else { '#3A4050' }

  if ($active) {
    $ui.MetaText.Text = 'avg ' + (F1 $s.avgTps) + ' · ' + (Format-Ms $s.ttftMs)
  } elseif ($s.turns -and $s.turns.Count -gt 0) {
    $t = $s.turns[0]
    $ui.MetaText.Text = 'last ' + (F1 $t.avgTps) + ' · ' + (Format-Ms $t.ttftMs)
  } else {
    $ui.MetaText.Text = 'idle'
  }
}

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds($IntervalMs)
$timer.Add_Tick($tick)
$timer.Start()

if (-not $NoWatchdog) {
  $watch = New-Object System.Windows.Threading.DispatcherTimer
  $watch.Interval = [TimeSpan]::FromSeconds(5)
  $watch.Add_Tick({
    if ($script:failures -ge 6) {
      Start-Hub
      $script:failures = 0
    }
  })
  $watch.Start()
}

$window.Add_Closed({ $timer.Stop() })
[void]$window.ShowDialog()
