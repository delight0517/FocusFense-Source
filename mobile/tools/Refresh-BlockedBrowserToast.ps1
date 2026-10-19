param()

$ErrorActionPreference = 'Stop'

$dir = 'C:\ProgramData\SixVPNBlocker'
New-Item -ItemType Directory -Force -Path $dir | Out-Null

$psPath = Join-Path $dir 'ShowBlockedBrowserToast.ps1'
$vbsPath = Join-Path $dir 'BlockedBrowserToastLauncher.vbs'

$script = @'
# 6 VPN Blocker - branded toast shown when an IFEO-blocked browser is launched.
$ErrorActionPreference='SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
$attempted = if ($args.Count -gt 0) { [string]$args[0] } else { 'chrome.exe' }
$exeName = Split-Path $attempted -Leaf
if ([string]::IsNullOrWhiteSpace($exeName) -or $exeName -eq 'unknown') { $exeName = 'chrome.exe' }
$display = switch -wildcard ($exeName.ToLower()) {
  'chrome.exe'  { 'Google Chrome' }
  'msedge.exe'  { 'Microsoft Edge' }
  'opera.exe'   { 'Opera' }
  'opera_gx*'   { 'Opera GX' }
  'whale.exe'   { 'Naver Whale' }
  'vivaldi.exe' { 'Vivaldi' }
  default       { $exeName }
}
try {
  Add-Content -Path 'C:\ProgramData\SixVPNBlocker\browser_launch_attempts.log' -Value ('[' + (Get-Date -Format 'o') + '] BLOCKED ' + $display + ' (' + $attempted + ')') -Encoding UTF8
} catch {}
$title = $display + ' 실행 차단됨'
$body = '6 VPN Blocker가 차단 우회를 막기 위해 이 브라우저 실행을 잠궜습니다. 바이러스가 아니라 정상 보호 동작입니다.'
$accent=[System.Drawing.Color]::FromArgb(56,209,159)
$bg=[System.Drawing.Color]::FromArgb(26,27,32)
$sub=[System.Drawing.Color]::FromArgb(178,180,190)
$f=New-Object System.Windows.Forms.Form
$f.FormBorderStyle='None'; $f.StartPosition='Manual'; $f.TopMost=$true; $f.ShowInTaskbar=$false
$f.Width=420; $f.Height=140; $f.BackColor=$bg
$wa=[System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$f.Left=$wa.Right-$f.Width-20; $f.Top=$wa.Bottom-$f.Height-20
$r=14
$gp=New-Object System.Drawing.Drawing2D.GraphicsPath
$gp.AddArc(0,0,$r,$r,180,90)
$gp.AddArc($f.Width-$r-1,0,$r,$r,270,90)
$gp.AddArc($f.Width-$r-1,$f.Height-$r-1,$r,$r,0,90)
$gp.AddArc(0,$f.Height-$r-1,$r,$r,90,90)
$gp.CloseAllFigures()
$f.Region=New-Object System.Drawing.Region($gp)
$f.Add_Paint({ param($s,$e) $e.Graphics.SmoothingMode='AntiAlias'; $e.Graphics.FillRectangle((New-Object System.Drawing.SolidBrush($accent)),0,0,5,$f.Height) })
$brand=New-Object System.Windows.Forms.Label
$brand.Text=[char]9679 + ' 6 VPN BLOCKER'; $brand.ForeColor=$accent; $brand.BackColor=$bg
$brand.Font=New-Object System.Drawing.Font('Segoe UI',8,[System.Drawing.FontStyle]::Bold)
$brand.AutoSize=$true; $brand.Left=22; $brand.Top=14
$lt=New-Object System.Windows.Forms.Label
$lt.Text=$title; $lt.ForeColor=[System.Drawing.Color]::White; $lt.BackColor=$bg
$lt.Font=New-Object System.Drawing.Font('Segoe UI Semibold',12,[System.Drawing.FontStyle]::Bold)
$lt.AutoSize=$false; $lt.Left=22; $lt.Top=36; $lt.Width=380; $lt.Height=24
$lb=New-Object System.Windows.Forms.Label
$lb.Text=$body; $lb.ForeColor=$sub; $lb.BackColor=$bg
$lb.Font=New-Object System.Drawing.Font('Segoe UI',9.5)
$lb.AutoSize=$false; $lb.Left=22; $lb.Top=63; $lb.Width=384; $lb.Height=66
$f.Controls.Add($brand); $f.Controls.Add($lt); $f.Controls.Add($lb)
$close={ try { $f.Close() } catch {} }
$f.Add_Click($close); $brand.Add_Click($close); $lt.Add_Click($close); $lb.Add_Click($close)
$t=New-Object System.Windows.Forms.Timer; $t.Interval=9000; $t.Add_Tick({ $f.Close() }); $t.Start()
$f.Opacity=0
$fi=New-Object System.Windows.Forms.Timer; $fi.Interval=16; $fi.Add_Tick({ if($f.Opacity -lt 0.96){ $f.Opacity=$f.Opacity+0.08 } else { $fi.Stop() } }); $fi.Start()
[System.Media.SystemSounds]::Asterisk.Play()
$f.Add_Shown({ $f.Activate(); $f.BringToFront() })
[System.Windows.Forms.Application]::Run($f)
exit 0
'@

$vbs = @'
Dim sh, browserPath, cmd
Set sh = CreateObject("WScript.Shell")
browserPath = ""
If WScript.Arguments.Count > 0 Then browserPath = WScript.Arguments(0)
cmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ""C:\ProgramData\SixVPNBlocker\ShowBlockedBrowserToast.ps1"" """ & browserPath & """"
sh.Run cmd, 0, False
'@

[System.IO.File]::WriteAllText($psPath, $script, [System.Text.UTF8Encoding]::new($true))
[System.IO.File]::WriteAllText($vbsPath, $vbs, [System.Text.Encoding]::ASCII)

$dbg = 'C:\Windows\System32\wscript.exe //B //Nologo "C:\ProgramData\SixVPNBlocker\BlockedBrowserToastLauncher.vbs"'
$ifeoRoot = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'
foreach ($exe in @('chrome.exe','msedge.exe','whale.exe','vivaldi.exe','opera.exe')) {
  $key = Join-Path $ifeoRoot $exe
  if (Test-Path -LiteralPath $key) {
    $oldDebugger = (Get-ItemProperty -LiteralPath $key -Name Debugger -ErrorAction SilentlyContinue).Debugger
    if ($oldDebugger -and ($oldDebugger -match 'SixVPNBlocker|BlockedBrowserToastLauncher|ShowBlockedBrowserToast')) {
      Set-ItemProperty -LiteralPath $key -Name Debugger -Value $dbg -Type String -Force
    }
  }
}

Get-Content -LiteralPath $psPath -TotalCount 24
