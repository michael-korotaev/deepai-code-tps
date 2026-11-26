param(
  [int]$Port = 57451,
  [int]$IntervalMs = 150,
  [switch]$NoWatchdog
)

# Оверлей «токены/сек»: маленькое всегда-сверху окно, читает
# http://127.0.0.1:<Port>/__tps/state у tps-hub.mjs.
# Перетаскивание — левой кнопкой, закрыть — двойной клик.

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$root = $PSScriptRoot
$logDir = Join-Path $root 'logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$proxyLog = Join-Path $logDir 'hub.log'
$proxyScript = Join-Path $root 'tps-hub.mjs'
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

function Start-Proxy {
  if (Test-Port $Port) { return }
  $nodeArgs = @($proxyScript, '--port', "$Port")
  Start-Process -FilePath 'node' -ArgumentList $nodeArgs -WindowStyle Hidden `
    -RedirectStandardOutput $proxyLog -RedirectStandardError "$proxyLog.err" | Out-Null
}

Start-Proxy

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" ResizeMode="NoResize"
        Width="292" Height="132" Title="DeepAI TPS">
  <Border Background="#E6101216" CornerRadius="10" BorderBrush="#2A3040" BorderThickness="1" Padding="12,7">
    <Grid>
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <DockPanel Grid.Row="0">
        <TextBlock x:Name="ModelText" FontSize="10" Foreground="#7C869B" TextTrimming="CharacterEllipsis"/>
        <TextBlock x:Name="StateText" FontSize="10" Foreground="#7C869B" HorizontalAlignment="Right" Margin="8,0,0,0"/>
      </DockPanel>
      <StackPanel Grid.Row="1" Orientation="Horizontal" VerticalAlignment="Center" Margin="0,2,0,4">
        <TextBlock x:Name="TpsText" FontSize="38" FontWeight="Bold" Foreground="#44DDFF" FontFamily="Consolas"/>
        <TextBlock Text="tok/s" FontSize="11" Foreground="#7C869B" VerticalAlignment="Bottom" Margin="6,0,0,8"/>
        <StackPanel Margin="18,0,0,0" VerticalAlignment="Center">
          <TextBlock x:Name="AvgText" FontSize="11" Foreground="#C9D1E1" FontFamily="Consolas"/>
          <TextBlock x:Name="TtftText" FontSize="11" Foreground="#C9D1E1" FontFamily="Consolas"/>
        </StackPanel>
      </StackPanel>
      <ProgressBar x:Name="Bar" Grid.Row="2" Height="4" Maximum="60" Value="0"
                   Foreground="#00FF88" Background="#20242E" BorderThickness="0"/>
    </Grid>
  </Border>
</Window>
'@

[xml]$xml = $xaml
$reader = New-Object System.Xml.XmlNodeReader $xml
$window = [Windows.Markup.XamlReader]::Load($reader)

$ui = @{}
foreach ($name in 'ModelText', 'StateText', 'TpsText', 'AvgText', 'TtftText', 'Bar') {
  $ui[$name] = $window.FindName($name)
}

# Позиция окна запоминается между запусками
if (Test-Path $posFile) {
  try {
    $pos = Get-Content $posFile -Raw | ConvertFrom-Json
    if ($pos.Left -gt -10000) { $window.Left = [double]$pos.Left; $window.Top = [double]$pos.Top }
  } catch { }
}
if ($window.Left -eq 0 -and $window.Top -eq 0) {
  $work = [System.Windows.SystemParameters]::WorkArea
  $window.Left = $work.Right - 312
  $window.Top = $work.Top + 64
}

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
  elseif ($v -gt 0) { '#FF4444' }
  else { '#3A4050' }
}

function F1($v, [string]$fmt = '0.0') {
  if ($null -eq $v) { return '—' }
  return ([double]$v).ToString($fmt, [System.Globalization.CultureInfo]::InvariantCulture)
}

function Format-Ms($ms) {
  if ($null -eq $ms) { return '—' }
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
    $ui.StateText.Text = 'proxy off'
    $ui.TpsText.Text = '—'
    $ui.TpsText.Foreground = '#3A4050'
    $ui.Bar.Value = 0
    return
  }

  $tps = 0.0
  if ($s.active -and $s.tps) { $tps = [double]$s.tps }
  $ui.TpsText.Text = F1 $(if ($s.active) { $tps } else { 0 })
  $ui.TpsText.Foreground = Get-StateColor $tps
  $ui.Bar.Value = [Math]::Min(60, $tps)
  $ui.Bar.Foreground = Get-StateColor $tps

  $ui.ModelText.Text = if ($s.model) { [string]$s.model } else { '—' }
  if ($s.active) {
    $gen = ''
    if ($s.firstTokenAt) {
      $gen = Format-Ms ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() - [double]$s.firstTokenAt)
    }
    $ui.StateText.Text = "tok $([Math]::Round([double]$s.tokens)) | $gen"
    $ui.AvgText.Text = 'avg  ' + $(if ($s.avgTps) { F1 $s.avgTps } else { '—' })
    $ui.TtftText.Text = 'ttft ' + (Format-Ms $s.ttftMs)
  } else {
    $ui.StateText.Text = 'idle'
    if ($s.turns -and $s.turns.Count -gt 0) {
      $t = $s.turns[0]
      $ui.AvgText.Text = 'last ' + $(if ($t.avgTps) { F1 $t.avgTps } else { '—' })
      $ui.TtftText.Text = 'ttft ' + (Format-Ms $t.ttftMs)
    } else {
      $ui.AvgText.Text = 'avg  —'
      $ui.TtftText.Text = 'ttft —'
    }
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
      Start-Proxy
      $script:failures = 0
    }
  })
  $watch.Start()
}

$window.Add_Closed({ $timer.Stop() })
[void]$window.ShowDialog()
