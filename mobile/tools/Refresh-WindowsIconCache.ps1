# Refreshes Windows taskbar icons after exe update WITHOUT opening File Explorer.
# Old script used Start-Process explorer → unwanted Explorer window every rebuild/restart.
$ErrorActionPreference = 'SilentlyContinue'

$ie4u = Join-Path $env:SystemRoot 'System32\ie4uinit.exe'
if (Test-Path -LiteralPath $ie4u) {
  & $ie4u -show 2>$null
}

try {
  Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class SixVpnShellNotify {
  [DllImport("shell32.dll")]
  public static extern void SHChangeNotify(int eventId, uint flags, IntPtr item1, IntPtr item2);
}
'@ -ErrorAction SilentlyContinue | Out-Null
  [SixVpnShellNotify]::SHChangeNotify(0x08000000, 0x1000, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
} catch {}

# Do NOT kill/restart explorer — that can reopen last folder windows on login/rebuild.
Write-Host 'Icon cache refresh done (ie4uinit only, no Explorer window).' -ForegroundColor Cyan
