# 6 VPN Blocker — loopback DNS sink (127.0.0.1:53). Elevated parent starts this.
param(
  [Parameter(Mandatory = $true)][string]$BlocklistPath,
  [Parameter(Mandatory = $true)][string]$PidFile
)
$ErrorActionPreference = 'Continue'
$logDir = Split-Path -Parent $PidFile
$errLog = Join-Path $logDir 'dns_sink_error.log'
$block = @{}
if (Test-Path -LiteralPath $BlocklistPath) {
  Get-Content -LiteralPath $BlocklistPath -Encoding UTF8 | ForEach-Object {
    $h = ($_ -split '#')[0].Trim().ToLower()
    if ($h.Length -gt 0) { $block[$h] = $true }
  }
}
function Is-Blocked([string]$name) {
  $n = $name.TrimEnd('.').ToLower()
  if ($block.ContainsKey($n)) { return $true }
  foreach ($k in $block.Keys) {
    if ($n -eq $k -or $n.EndsWith('.' + $k)) { return $true }
  }
  return $false
}
try {
  $udp = New-Object System.Net.Sockets.UdpClient
  $udp.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
  $ep = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Loopback), 53
  $udp.Client.Bind($ep)
  [System.IO.File]::WriteAllText($PidFile, [string]$PID)
} catch {
  $msg = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
  [System.IO.File]::WriteAllText($errLog, "bind 127.0.0.1:53 failed: $msg")
  exit 1
}
$forward = New-Object System.Net.Sockets.UdpClient
$forward.Client.ReceiveTimeout = 3000
while ($true) {
  $remote = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Any), 0
  try {
    $buf = $udp.Receive([ref]$remote)
  } catch {
    continue
  }
  if ($buf.Length -lt 12) { continue }
  $id = $buf[0..1]
  $flags = [BitConverter]::ToUInt16($buf, 2)
  if (($flags -band 0x8000) -ne 0) { continue }
  $qd = [BitConverter]::ToUInt16($buf, 4)
  if ($qd -lt 1) { continue }
  $pos = 12
  $labels = New-Object System.Collections.Generic.List[string]
  while ($pos -lt $buf.Length) {
    $len = $buf[$pos]
    if ($len -eq 0) { $pos++; break }
    if ($len -gt 63) { break }
    $labels.Add([System.Text.Encoding]::ASCII.GetString($buf, $pos + 1, $len))
    $pos += 1 + $len
  }
  $qname = ($labels -join '.').ToLower()
  $pos += 4
  if (Is-Blocked $qname) {
    $resp = New-Object byte[] ($buf.Length + 16)
    [Array]::Copy($buf, $resp, $buf.Length)
    $resp[2] = 0x81; $resp[3] = 0x80
    $resp[6] = 0; $resp[7] = 1
    $resp[10] = 0; $resp[11] = 1
    $rlen = $buf.Length
    $resp[$rlen++] = 0xC0; $resp[$rlen++] = 0x0C
    $resp[$rlen++] = 0; $resp[$rlen++] = 1
    $resp[$rlen++] = 0; $resp[$rlen++] = 1
    $resp[$rlen++] = 0; $resp[$rlen++] = 0; $resp[$rlen++] = 0; $resp[$rlen++] = 60
    $resp[$rlen++] = 0; $resp[$rlen++] = 4
    $resp[$rlen++] = 0; $resp[$rlen++] = 0; $resp[$rlen++] = 0; $resp[$rlen++] = 0
    $resp = $resp[0..($rlen-1)]
    $udp.Send($resp, $resp.Length, $remote) | Out-Null
  } else {
    try {
      $fwdEp = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Parse('1.1.1.1')), 53
      $forward.Send($buf, $buf.Length, '1.1.1.1', 53) | Out-Null
      $ans = $forward.Receive([ref]$fwdEp)
      $udp.Send($ans, $ans.Length, $remote) | Out-Null
    } catch {}
  }
}
