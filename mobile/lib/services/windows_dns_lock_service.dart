import 'dart:io';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'mac_system_block_service.dart';

/// Windows **DNS-lock** layer: loopback resolver + adapter DNS → 127.0.0.1.
/// Complements hosts (IPv6/DoH bypass). Activated from elevated hosts script.
final class WindowsDnsLockService {
  WindowsDnsLockService._();
  static final WindowsDnsLockService instance = WindowsDnsLockService._();

  static String programDataDir() {
    final String? pd = Platform.environment['ProgramData'];
    return p.join(pd ?? r'C:\ProgramData', 'SixVPNBlocker');
  }

  static String blocklistPath() => p.join(programDataDir(), 'dns_blocklist.txt');
  static String dnsScriptPath() => p.join(programDataDir(), 'SixVpnLoopbackDns.ps1');
  static String dnsTcpScriptPath() => p.join(programDataDir(), 'SixVpnLoopbackDnsTcp.ps1');
  static String dnsPidPath() => p.join(programDataDir(), 'dns_sink.pid');
  static String dnsTcpPidPath() => p.join(programDataDir(), 'dns_sink_tcp.pid');
  static String dnsBackupPath() => p.join(programDataDir(), 'dns_adapter_backup.txt');
  static String elevateTranscriptPath() =>
      p.join(programDataDir(), 'elevate_transcript.log');

  /// Comment tag used on every NRPT rule the app installs, so we can find &
  /// remove only our own rules without touching anything the user added.
  static const String kNrptTag = 'SixVPNBlocker';

  /// Sinkhole IP for NRPT rules. RFC5735 loopback range that nothing should be
  /// listening on; resolvers fail fast and Chrome's built-in DNS client honors
  /// the Windows DNS Client / NRPT path when `BuiltInDnsClientEnabled=0`.
  static const String kNrptSinkIp = '127.0.0.2';

  /// Writes one canonical host per line for the elevated DNS sink script.
  Future<void> writeBlocklist(Iterable<String> hosts) async {
    if (!Platform.isWindows) return;
    final Directory dir = Directory(programDataDir());
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final Set<String> lines = <String>{};
    for (final String raw in hosts) {
      final String h = MacSystemBlockService.canonicalHost(raw);
      if (h.isNotEmpty) lines.add(h);
    }
    await File(blocklistPath()).writeAsString(
      '${lines.join('\n')}\n',
      flush: true,
    );
    await _ensureDnsScriptsOnDisk();
  }

  Future<void> _ensureDnsScriptsOnDisk() async {
    final Directory dir = Directory(programDataDir());
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final File udpOut = File(dnsScriptPath());
    final String udpBundled =
        await rootBundle.loadString('assets/windows/SixVpnLoopbackDns.ps1');
    await udpOut.writeAsString(udpBundled, flush: true);
    final File tcpOut = File(dnsTcpScriptPath());
    final String tcpBundled =
        await rootBundle.loadString('assets/windows/SixVpnLoopbackDnsTcp.ps1');
    await tcpOut.writeAsString(tcpBundled, flush: true);
  }

  /// PowerShell fragment appended inside the elevated hosts apply script.
  /// Every `$` is escaped for embedding in a Dart multiline string (`\$`).
  static String elevatedDnsActivateFragment() {
    final String dir = programDataDir().replaceAll("'", "''");
    final String script = dnsScriptPath().replaceAll("'", "''");
    final String tcpScript = dnsTcpScriptPath().replaceAll("'", "''");
    final String list = blocklistPath().replaceAll("'", "''");
    final String pidFile = dnsPidPath().replaceAll("'", "''");
    final String tcpPidFile = dnsTcpPidPath().replaceAll("'", "''");
    final String backup = dnsBackupPath().replaceAll("'", "''");
    return _psEmbed(r'''
  # --- 6 VPN Blocker: loopback DNS lock (Chrome/Edge DoH bypass helper) ---
  function Test-SixVpnLoopback53Free {
    try {
      $probe = New-Object System.Net.Sockets.UdpClient
      $probe.Client.SetSocketOption([System.Net.Sockets.SocketOptionLevel]::Socket, [System.Net.Sockets.SocketOptionName]::ReuseAddress, $true)
      $ep = New-Object System.Net.IPEndPoint ([System.Net.IPAddress]::Loopback), 53
      $probe.Client.Bind($ep)
      $probe.Close()
      return $true
    } catch { return $false }
  }
  function Stop-SixVpnDnscacheForSink {
    try { Set-Service -Name Dnscache -StartupType Manual -ErrorAction SilentlyContinue } catch {}
    try { Stop-Service -Name Dnscache -Force -ErrorAction SilentlyContinue } catch {}
    try { & "$env:SystemRoot\System32\net.exe" stop dnscache /y 2>&1 | Out-Null } catch {}
    for ($i = 0; $i -lt 35; $i++) {
      if (Test-SixVpnLoopback53Free) { return $true }
      Start-Sleep -Milliseconds 250
    }
    return $false
  }
  function Start-SixVpnDnsSink {
    param([string]$Script, [string]$List, [string]$PidPath, [string]$ErrName)
    $errLog = Join-Path (Split-Path -Parent $PidPath) $ErrName
    if (Test-Path -LiteralPath $errLog) { Remove-Item -LiteralPath $errLog -Force -ErrorAction SilentlyContinue }
    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
      -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$Script,'-BlocklistPath',$List,'-PidFile',$PidPath) `
      -WindowStyle Hidden | Out-Null
    for ($w = 0; $w -lt 30; $w++) {
      if (Test-Path -LiteralPath $PidPath) { return $true }
      Start-Sleep -Milliseconds 350
    }
    return $false
  }
  function Stop-SixVpnSinkPidFile {
    param([string]$PidPath)
    if (Test-Path -LiteralPath $PidPath) {
      $oldPid = Get-Content -LiteralPath $PidPath -ErrorAction SilentlyContinue
      if ($oldPid -match '^\d+$') {
        Stop-Process -Id ([int]$oldPid) -Force -ErrorAction SilentlyContinue
      }
      Remove-Item -LiteralPath $PidPath -Force -ErrorAction SilentlyContinue
    }
  }
  try {
    $sixDir = '@dir@'
    $sixScript = '@script@'
    $sixTcpScript = '@tcpScript@'
    $sixList = '@list@'
    $sixPid = '@pidFile@'
    $sixTcpPid = '@tcpPidFile@'
    $sixBackup = '@backup@'
    $errLog = Join-Path $sixDir 'dns_sink_error.log'
    New-Item -ItemType Directory -Force -Path $sixDir -ErrorAction SilentlyContinue | Out-Null
    $ifaces = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Loopback|Virtual|VPN|TAP|TUN|Wintun|WireGuard|Hyper-V' }
    $backupLines = @()
    foreach ($ifa in $ifaces) {
      $name = $ifa.Name
      $cur = (Get-DnsClientServerAddress -InterfaceAlias $name -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses -join ','
      $backupLines += "$name|$cur"
    }
    if ($backupLines.Count -gt 0) {
      Set-Content -LiteralPath $sixBackup -Value ($backupLines -join "`n") -Encoding UTF8
    }
    $sinkOk = $false
    $tcpOk = $false
    if (-not (Test-Path -LiteralPath $sixScript)) {
      Write-Host "[sixvpn] DNS script missing at $sixScript"
    } else {
      Stop-SixVpnSinkPidFile -PidPath $sixPid
      Stop-SixVpnSinkPidFile -PidPath $sixTcpPid
      if (Test-SixVpnLoopback53Free) {
        $sinkOk = Start-SixVpnDnsSink -Script $sixScript -List $sixList -PidPath $sixPid -ErrName 'dns_sink_error.log'
        if ($sinkOk) { Write-Host "[sixvpn] DNS UDP sink OK (port free)" }
      }
      if (-not $sinkOk) {
        $portFree = Stop-SixVpnDnscacheForSink
        Write-Host "[sixvpn] Dnscache stopped portFree=$portFree"
        if ($portFree) {
          $sinkOk = Start-SixVpnDnsSink -Script $sixScript -List $sixList -PidPath $sixPid -ErrName 'dns_sink_error.log'
        }
      }
      if (-not $sinkOk) {
        Start-Sleep -Seconds 2
        $null = Stop-SixVpnDnscacheForSink
        $sinkOk = Start-SixVpnDnsSink -Script $sixScript -List $sixList -PidPath $sixPid -ErrName 'dns_sink_error.log'
      }
      if ($sinkOk -and (Test-Path -LiteralPath $sixTcpScript)) {
        $tcpOk = Start-SixVpnDnsSink -Script $sixTcpScript -List $sixList -PidPath $sixTcpPid -ErrName 'dns_sink_tcp_error.log'
        Write-Host "[sixvpn] DNS TCP sink tcpOk=$tcpOk"
      }
      if (-not $sinkOk) {
        if (Test-Path -LiteralPath $errLog) {
          $errTxt = (Get-Content -LiteralPath $errLog -Raw -ErrorAction SilentlyContinue).Trim()
          if ($errTxt.Length -gt 0) { Write-Host "[sixvpn] DNS sink bind error: $errTxt" }
        } else {
          Write-Host "[sixvpn] DNS sink failed — port 53 still in use"
        }
        Write-Host "[sixvpn] WARN: restoring Dnscache (NRPT/hosts fallback)"
        try { Set-Service -Name Dnscache -StartupType Automatic -ErrorAction SilentlyContinue } catch {}
        try { & "$env:SystemRoot\System32\net.exe" start dnscache 2>&1 | Out-Null } catch {}
        try { Start-Service -Name Dnscache -ErrorAction SilentlyContinue } catch {}
      } else {
        Write-Host "[sixvpn] DNS sink running (UDP=$sinkOk TCP=$tcpOk) — Dnscache remains stopped"
        try { & "$env:SystemRoot\System32\ipconfig.exe" /flushdns 2>&1 | Out-Null } catch {}
      }
    }
  } catch {
    Write-Host "[sixvpn] DNS lock skip: $($_.Exception.Message)"
  }
''')
        .replaceAll('@dir@', dir)
        .replaceAll('@script@', script)
        .replaceAll('@tcpScript@', tcpScript)
        .replaceAll('@list@', list)
        .replaceAll('@pidFile@', pidFile)
        .replaceAll('@tcpPidFile@', tcpPidFile)
        .replaceAll('@backup@', backup);
  }

  /// Runs after NRPT install: adapter DNS → 127.0.0.1 only when sink is up.
  static String elevatedDnsFinalizeFragment() {
    final String pidFile = dnsPidPath().replaceAll("'", "''");
    return _psEmbed(r'''
  try {
    $sixPid = '@pidFile@'
    $sixTag = '@tag@'
    $sinkRunning = Test-Path -LiteralPath $sixPid
    $nrptCount = 0
    try {
      $nrptCount = @(Get-DnsClientNrptRule -ErrorAction SilentlyContinue | Where-Object { $_.Comment -eq $sixTag }).Count
    } catch {}
    $ifaces = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Loopback|Virtual|VPN|TAP|TUN|Wintun|WireGuard|Hyper-V' }
    foreach ($ifa in $ifaces) {
      $name = $ifa.Name
      if ($sinkRunning) {
        Set-DnsClientServerAddress -InterfaceAlias $name -ServerAddresses @('127.0.0.1') -ErrorAction SilentlyContinue
        $after = @(Get-DnsClientServerAddress -InterfaceAlias $name -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses
        if ($after.Count -gt 1 -or ($after -notcontains '127.0.0.1')) {
          Set-DnsClientServerAddress -InterfaceAlias $name -ServerAddresses @('127.0.0.1') -ErrorAction SilentlyContinue
          Write-Host "[sixvpn] secondary DNS cleared on $name (was $($after -join ','))"
        } else {
          Write-Host "[sixvpn] DNS set $name -> 127.0.0.1 only"
        }
      } elseif ($nrptCount -gt 0) {
        Write-Host "[sixvpn] NRPT $nrptCount rules — adapter $name DNS unchanged (Dnscache path)"
      } else {
        Write-Host "[sixvpn] DNS unchanged $name (no sink, no NRPT)"
      }
    }
    try { & "$env:SystemRoot\System32\ipconfig.exe" /flushdns 2>&1 | Out-Null } catch {}
  } catch {
    Write-Host "[sixvpn] DNS finalize skip: $($_.Exception.Message)"
  }
''').replaceAll('@pidFile@', pidFile).replaceAll('@tag@', kNrptTag);
  }

  static String elevatedDnsDeactivateFragment() {
    final String backup = dnsBackupPath().replaceAll("'", "''");
    final String pidFile = dnsPidPath().replaceAll("'", "''");
    final String tcpPidFile = dnsTcpPidPath().replaceAll("'", "''");
    return _psEmbed(r'''
  try {
    foreach ($pf in @('@pidFile@','@tcpPidFile@')) {
      if (Test-Path -LiteralPath $pf) {
        $oldPid = Get-Content -LiteralPath $pf -ErrorAction SilentlyContinue
        if ($oldPid -match '^\d+$') { Stop-Process -Id ([int]$oldPid) -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue
      }
    }
    if (Test-Path -LiteralPath '@backup@') {
      Get-Content -LiteralPath '@backup@' -Encoding UTF8 | ForEach-Object {
        $parts = $_ -split '\|', 2
        if ($parts.Count -lt 2) { return }
        $alias = $parts[0]
        $was = $parts[1]
        if ([string]::IsNullOrWhiteSpace($was)) {
          Set-DnsClientServerAddress -InterfaceAlias $alias -ResetServerAddresses -ErrorAction SilentlyContinue
        } else {
          $addrs = $was -split ',' | Where-Object { $_ -match '\S' }
          if ($addrs.Count -gt 0) {
            Set-DnsClientServerAddress -InterfaceAlias $alias -ServerAddresses $addrs -ErrorAction SilentlyContinue
          } else {
            Set-DnsClientServerAddress -InterfaceAlias $alias -ResetServerAddresses -ErrorAction SilentlyContinue
          }
        }
      }
      Remove-Item -LiteralPath '@backup@' -Force -ErrorAction SilentlyContinue
    }
    try { Set-Service -Name Dnscache -StartupType Automatic -ErrorAction SilentlyContinue } catch {}
    try { Start-Service -Name Dnscache -ErrorAction SilentlyContinue } catch {}
    try { & "$env:SystemRoot\System32\net.exe" start dnscache 2>&1 | Out-Null } catch {}
    Write-Host "[sixvpn] DNS lock restored"
  } catch {
    Write-Host "[sixvpn] DNS restore skip: $($_.Exception.Message)"
  }
''')
        .replaceAll('@pidFile@', pidFile)
        .replaceAll('@tcpPidFile@', tcpPidFile)
        .replaceAll('@backup@', backup);
  }

  /// NRPT (Name Resolution Policy Table) activate fragment.
  ///
  /// Reads the blocklist file and installs one NRPT rule per host (tagged with
  /// [kNrptTag] in `Comment`) pointing both `.host` and `host` itself to
  /// [kNrptSinkIp]. NRPT runs **inside Dnscache**, so it does not fight us for
  /// port 53 the way the loopback sink does — this works even when the sink
  /// failed to start. Chromium with `BuiltInDnsClientEnabled=0` (see
  /// [ChromiumPolicyService]) routes through Dnscache and is therefore
  /// captured by NRPT.
  static String elevatedNrptActivateFragment() {
    final String list = blocklistPath().replaceAll("'", "''");
    return _psEmbed(r'''
  # --- 6 VPN Blocker: NRPT rules (Dnscache-level domain sinkhole) ---
  try {
    $sixList = '@list@'
    $sixTag = '@tag@'
    $sixSink = '@sink@'
    # Remove any previously installed rules tagged by us (idempotent re-apply).
    try {
      Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
        Where-Object { $_.Comment -eq $sixTag } |
        ForEach-Object {
          Remove-DnsClientNrptRule -Name $_.Name -Force -ErrorAction SilentlyContinue
        }
    } catch {}
    if (Test-Path -LiteralPath $sixList) {
      $hosts = @(Get-Content -LiteralPath $sixList -ErrorAction SilentlyContinue |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and ($_ -notmatch '^\s*#') })
      $count = 0
      foreach ($h in $hosts) {
        # NRPT namespace matches FQDN suffix, e.g. ".example.com" covers
        # foo.example.com but NOT example.com itself — add both forms.
        $nsApex = $h
        $nsWild = '.' + $h
        foreach ($ns in @($nsApex, $nsWild)) {
          try {
            Add-DnsClientNrptRule -Namespace $ns -NameServers $sixSink -Comment $sixTag -ErrorAction Stop | Out-Null
            $count++
          } catch {
            Write-Host "[sixvpn] NRPT add fail ($ns): $($_.Exception.Message)"
          }
        }
      }
      Write-Host "[sixvpn] NRPT installed $count rules for $($hosts.Count) hosts -> $sixSink"
      try { & "$env:SystemRoot\System32\ipconfig.exe" /flushdns 2>&1 | Out-Null } catch {}
    } else {
      Write-Host "[sixvpn] NRPT skip: blocklist missing at $sixList"
    }
  } catch {
    Write-Host "[sixvpn] NRPT activate skip: $($_.Exception.Message)"
  }
''')
        .replaceAll('@list@', list)
        .replaceAll('@tag@', kNrptTag)
        .replaceAll('@sink@', kNrptSinkIp);
  }

  /// Removes only the NRPT rules this app installed (matched by [kNrptTag]).
  static String elevatedNrptDeactivateFragment() {
    return _psEmbed(r'''
  try {
    $sixTag = '@tag@'
    $removed = 0
    Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
      Where-Object { $_.Comment -eq $sixTag } |
      ForEach-Object {
        try {
          Remove-DnsClientNrptRule -Name $_.Name -Force -ErrorAction Stop
          $removed++
        } catch {
          Write-Host "[sixvpn] NRPT remove fail ($($_.Name)): $($_.Exception.Message)"
        }
      }
    Write-Host "[sixvpn] NRPT removed $removed rules"
    try { & "$env:SystemRoot\System32\ipconfig.exe" /flushdns 2>&1 | Out-Null } catch {}
  } catch {
    Write-Host "[sixvpn] NRPT deactivate skip: $($_.Exception.Message)"
  }
''').replaceAll('@tag@', kNrptTag);
  }

  static String _psEmbed(String ps) => ps.replaceAll(r'$', r'\$');

  Future<void> logStatus() async {
    if (!Platform.isWindows) return;
    final bool listOk = await File(blocklistPath()).exists();
    AppLogger.instance.info('WindowsDnsLock blocklist=$listOk path=${blocklistPath()}');
  }
}
