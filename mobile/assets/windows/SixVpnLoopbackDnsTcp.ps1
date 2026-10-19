# 6 VPN Blocker — loopback DNS sink TCP (127.0.0.1:53). Companion to UDP sink.
param(
  [Parameter(Mandatory = $true)][string]$BlocklistPath,
  [Parameter(Mandatory = $true)][string]$PidFile
)
$ErrorActionPreference = 'Continue'
$errLog = Join-Path (Split-Path -Parent $PidFile) 'dns_sink_tcp_error.log'
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
function Read-Qname([byte[]]$buf, [int]$start) {
  $labels = New-Object System.Collections.Generic.List[string]
  $pos = $start
  while ($pos -lt $buf.Length) {
    $len = $buf[$pos]
    if ($len -eq 0) { $pos++; break }
    if ($len -gt 63) { return $null }
    $labels.Add([System.Text.Encoding]::ASCII.GetString($buf, $pos + 1, $len))
    $pos += 1 + $len
  }
  return ($labels -join '.').ToLower()
}
try {
  $listener = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback), 53
  $listener.Start()
  [System.IO.File]::WriteAllText($PidFile, [string]$PID)
} catch {
  $msg = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
  [System.IO.File]::WriteAllText($errLog, "bind TCP 127.0.0.1:53 failed: $msg")
  exit 1
}
while ($true) {
  try {
    $client = $listener.AcceptTcpClient()
  } catch { continue }
  try {
    $stream = $client.GetStream()
    $stream.ReadTimeout = 3000
    $ms = New-Object System.IO.MemoryStream
    $buf = New-Object byte[] 4096
    $read = $stream.Read($buf, 0, $buf.Length)
    if ($read -lt 12) { $client.Close(); continue }
    $qname = Read-Qname $buf 12
    if ($null -eq $qname) { $client.Close(); continue }
    if (Is-Blocked $qname) {
      $resp = New-Object byte[] ($read + 16)
      [Array]::Copy($buf, $resp, $read)
      $resp[2] = 0x81; $resp[3] = 0x80
      $resp[6] = 0; $resp[7] = 1
      $resp[10] = 0; $resp[11] = 1
      $rlen = $read
      $resp[$rlen++] = 0xC0; $resp[$rlen++] = 0x0C
      $resp[$rlen++] = 0; $resp[$rlen++] = 1
      $resp[$rlen++] = 0; $resp[$rlen++] = 1
      $resp[$rlen++] = 0; $resp[$rlen++] = 0; $resp[$rlen++] = 0; $resp[$rlen++] = 60
      $resp[$rlen++] = 0; $resp[$rlen++] = 4
      $resp[$rlen++] = 0; $resp[$rlen++] = 0; $resp[$rlen++] = 0; $resp[$rlen++] = 0
      $resp = $resp[0..($rlen - 1)]
      $stream.Write($resp, 0, $resp.Length)
    } else {
      $fwd = New-Object System.Net.Sockets.TcpClient
      $fwd.Connect('1.1.1.1', 53)
      $fs = $fwd.GetStream()
      $lenBytes = [BitConverter]::GetBytes([uint16]$read)
      if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($lenBytes) }
      $fs.Write($lenBytes, 0, 2)
      $fs.Write($buf, 0, $read)
      $fs.Flush()
      $lenBuf = New-Object byte[] 2
      $null = $fs.Read($lenBuf, 0, 2)
      $ansLen = [BitConverter]::ToUInt16($lenBuf, 0)
      if ([BitConverter]::IsLittleEndian) {
        $ansLen = [System.Net.IPAddress]::NetworkToHostOrder([int16]$ansLen)
      }
      $ans = New-Object byte[] $ansLen
      $got = 0
      while ($got -lt $ansLen) {
        $got += $fs.Read($ans, $got, $ansLen - $got)
      }
      $stream.Write($ans, 0, $ans.Length)
      $fwd.Close()
    }
  } catch {} finally {
    try { $client.Close() } catch {}
  }
}
