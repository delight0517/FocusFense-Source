import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'mac_system_block_service.dart';
import 'windows_hidden_process.dart';

/// Layer 5 — Windows Firewall outbound IP blocks for enabled domain rules.
///
/// Complements hosts/PAC: blocks resolved IPs even when DNS is bypassed.
/// Throttled: max [_kMaxHosts] lookups, [_kRefreshInterval] between refreshes.
final class FirewallBlockResult {
  const FirewallBlockResult({
    required this.active,
    required this.ruleCount,
    required this.resolvedCount,
    this.message = '',
    this.adminBatPath,
    this.needsElevation = false,
  });

  final bool active;
  final int ruleCount;
  final int resolvedCount;
  final String message;

  /// When netsh needs admin, a one-click BAT is written here.
  final String? adminBatPath;
  final bool needsElevation;

  bool get pendingOrActive => active || adminBatPath != null;
}

final class WindowsFirewallBlockService {
  WindowsFirewallBlockService._();
  static final WindowsFirewallBlockService instance =
      WindowsFirewallBlockService._();

  static const String rulePrefix = 'SixVPN_Block_';
  static const String _rulePrefix = rulePrefix;
  static const int _kMaxHosts = 28;
  static const Duration _kRefreshInterval = Duration(hours: 4);
  static const Duration _kLookupTimeout = Duration(seconds: 4);

  String? _lastHostsHash;
  DateTime? _lastSyncAt;
  FirewallBlockResult? _lastResult;
  bool _syncing = false;

  static String stateFilePath() {
    final String? la = Platform.environment['LOCALAPPDATA'];
    return p.join(la ?? '', 'SixVPNBlocker', 'firewall_rules.json');
  }

  static String _statePath() => stateFilePath();

  /// CMD lines embedded in combined hosts+firewall admin script.
  static String buildCmdFirewallSection(Iterable<String> ips) {
    final StringBuffer out = StringBuffer()
      ..writeln('echo [6 VPN Blocker] firewall layer 5...')
      ..writeln('set FW_OK=0');
    for (final String raw in ips) {
      final String ip = raw.trim();
      if (ip.isEmpty) continue;
      final String name = '${rulePrefix}${ip.replaceAll('.', '_')}';
      out.writeln(
        'netsh advfirewall firewall delete rule name="$name" >nul 2>&1',
      );
      out.writeln(
        'netsh advfirewall firewall add rule name="$name" dir=out action=block remoteip=$ip enable=yes',
      );
      out.writeln('if not errorlevel 1 set FW_OK=1');
    }
    out.writeln(
      'echo firewall_done FW_OK=%FW_OK%>> "%ProgramData%\\SixVPNBlocker\\hosts_apply_cmd.log"',
    );
    return out.toString();
  }

  /// Read saved IPs or resolve fresh for admin CMD embedding.
  Future<String> buildCmdFirewallSectionFromState() async {
    try {
      final File f = File(stateFilePath());
      if (await f.exists()) {
        final dynamic raw = jsonDecode(await f.readAsString());
        if (raw is List && raw.isNotEmpty) {
          return buildCmdFirewallSection(raw.map((dynamic e) => '$e'));
        }
      }
    } catch (_) {}
    final List<String> ips = await resolveBlockedIps();
    if (ips.isEmpty) return '';
    await _writeState(ips);
    await _writeAdminFirewallBat(ips);
    return buildCmdFirewallSection(ips);
  }

  static String _netshExe() {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return p.join(windir, 'System32', 'netsh.exe');
  }

  /// Resolve up to [_kMaxHosts] IPv4 addresses for enabled domain rules.
  Future<List<String>> resolveBlockedIps() async {
    if (!Platform.isWindows) return const <String>[];
    final List<String> hosts = await MacSystemBlockService.instance
        .enabledHostsExpanded();
    final List<String> capped = _pickResolvableHosts(hosts);
    final Set<String> ips = <String>{};
    for (final String host in capped) {
      ips.addAll(await _resolveHost(host));
      if (ips.length >= _kMaxHosts) break;
    }
    // YouTube CDN — optional extra targets when rules include YT blocks.
    if (ips.length < _kMaxHosts) {
      for (final String yt in <String>['www.youtube.com', 'youtube.com']) {
        ips.addAll(await _resolveHost(yt));
        if (ips.length >= _kMaxHosts) break;
      }
    }
    return ips.take(_kMaxHosts).toList();
  }

  /// PowerShell fragment for UAC elevate script (layer 5 with hosts).
  static String elevatedFirewallFragment() {
    return r'''
  if ($FirewallIpsPath -ne '' -and (Test-Path -LiteralPath $FirewallIpsPath)) {
    $fwAdded = 0
    foreach ($line in Get-Content -LiteralPath $FirewallIpsPath) {
      $ip = ($line -as [string]).Trim()
      if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { continue }
      $name = 'SixVPN_Block_' + ($ip -replace '\.', '_')
      try {
        netsh advfirewall firewall delete rule name="$name" 2>$null | Out-Null
        netsh advfirewall firewall add rule name="$name" dir=out action=block remoteip=$ip enable=yes | Out-Null
        if ($LASTEXITCODE -eq 0) { $fwAdded++ }
      } catch {}
    }
    Write-Host "[sixvpn] firewall rules added: $fwAdded"
  }
''';
  }

  static String elevatedFirewallRemoveFragment() {
    return r'''
  if ($FirewallIpsPath -ne '' -and (Test-Path -LiteralPath $FirewallIpsPath)) {
    foreach ($line in Get-Content -LiteralPath $FirewallIpsPath) {
      $ip = ($line -as [string]).Trim()
      if ($ip -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { continue }
      $name = 'SixVPN_Block_' + ($ip -replace '\.', '_')
      netsh advfirewall firewall delete rule name="$name" 2>$null | Out-Null
    }
  }
''';
  }

  /// Writes state JSON + admin BAT without netsh (for experiments / pre-UAC).
  Future<FirewallBlockResult> prepareStateOnly() async {
    final List<String> ipList = await resolveBlockedIps();
    if (ipList.isEmpty) {
      return const FirewallBlockResult(
        active: false,
        ruleCount: 0,
        resolvedCount: 0,
        message: 'resolve empty',
      );
    }
    final String? bat = await _writeAdminFirewallBat(ipList);
    await _writeState(ipList);
    return FirewallBlockResult(
      active: false,
      ruleCount: 0,
      resolvedCount: ipList.length,
      adminBatPath: bat,
      needsElevation: bat != null,
      message: 'BAT+state ready (${ipList.length} IPs)',
    );
  }

  /// Debounced sync — safe to call from rule-change paths.
  Future<FirewallBlockResult> syncFromHosts({bool force = false}) async {
    if (!Platform.isWindows) {
      return const FirewallBlockResult(
        active: false,
        ruleCount: 0,
        resolvedCount: 0,
        message: 'Windows 전용',
      );
    }
    if (_syncing) {
      return _lastResult ??
          const FirewallBlockResult(
            active: false,
            ruleCount: 0,
            resolvedCount: 0,
          );
    }
    final List<String> hosts = await MacSystemBlockService.instance
        .enabledHostsExpanded();
    final String hash = hosts.join('|');
    final DateTime now = DateTime.now();
    if (!force &&
        _lastResult != null &&
        _lastHostsHash == hash &&
        _lastSyncAt != null &&
        now.difference(_lastSyncAt!) < _kRefreshInterval) {
      return _lastResult!;
    }
    if (hosts.isEmpty) {
      await _removeAllManagedRules();
      _lastHostsHash = hash;
      _lastSyncAt = now;
      _lastResult = const FirewallBlockResult(
        active: false,
        ruleCount: 0,
        resolvedCount: 0,
        message: '활성 도메인 없음 — 방화벽 규칙 제거',
      );
      return _lastResult!;
    }

    _syncing = true;
    try {
      final List<String> ipList = await resolveBlockedIps();
      if (ipList.isEmpty) {
        _lastResult = FirewallBlockResult(
          active: false,
          ruleCount: 0,
          resolvedCount: 0,
          message: 'DNS 조회 실패 — hosts/PAC는 계속 동작',
        );
        return _lastResult!;
      }
      await _removeAllManagedRules();
      int added = 0;
      for (final String ip in ipList) {
        if (await _addRule(ip)) added++;
      }
      String? adminBat;
      bool needsElev = false;
      if (added == 0 && ipList.isNotEmpty) {
        adminBat = await _writeAdminFirewallBat(ipList);
        needsElev = adminBat != null;
      }
      await _writeState(ipList);
      _lastHostsHash = hash;
      _lastSyncAt = now;
      _lastResult = FirewallBlockResult(
        active: added > 0,
        ruleCount: added,
        resolvedCount: ipList.length,
        adminBatPath: adminBat,
        needsElevation: needsElev,
        message: added > 0
            ? '방화벽 $added개 IP 차단 (CDN 일부만 — hosts가 주력)'
            : needsElev
            ? '관리자 BAT 준비됨 — 우클릭 관리자 실행 필요'
            : '방화벽 규칙 추가 실패',
      );
      AppLogger.instance.info(
        'firewall_block: added=$added ips=${ipList.length}',
      );
      return _lastResult!;
    } catch (e, st) {
      AppLogger.instance.warn('firewall_block sync failed', error: e);
      AppLogger.instance.log('DEBUG', 'firewall stack', stack: st);
      return _lastResult ??
          FirewallBlockResult(
            active: false,
            ruleCount: 0,
            resolvedCount: 0,
            message: e.toString(),
          );
    } finally {
      _syncing = false;
    }
  }

  Future<void> deactivate() async {
    if (!Platform.isWindows) return;
    await _removeAllManagedRules();
    _lastHostsHash = null;
    _lastSyncAt = null;
    _lastResult = const FirewallBlockResult(
      active: false,
      ruleCount: 0,
      resolvedCount: 0,
      message: '방화벽 규칙 제거됨',
    );
  }

  /// Read-only post-cleanup probe. Null means Windows could not verify state.
  Future<bool?> hasManagedRules() async {
    if (!Platform.isWindows) return false;
    const String script = r'''
$ErrorActionPreference = 'Stop'
$rules = @(Get-NetFirewallRule -ErrorAction SilentlyContinue | Where-Object {
  $_.DisplayName -like 'SixVPN_Block_*' -or $_.Name -like 'SixVPN_Block_*'
})
if ($rules.Count -gt 0) { Write-Output 'YES' } else { Write-Output 'NO' }
''';
    try {
      final ProcessResult result = await windowsRunHidden(
        p.join(
          Platform.environment['WINDIR'] ?? r'C:\Windows',
          'System32',
          'WindowsPowerShell',
          'v1.0',
          'powershell.exe',
        ),
        <String>[
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          script,
        ],
      );
      if (result.exitCode != 0) return null;
      return (result.stdout ?? '').toString().contains('YES');
    } catch (_) {
      return null;
    }
  }

  FirewallBlockResult? get lastResult => _lastResult;

  List<String> _pickResolvableHosts(List<String> hosts) {
    final List<String> out = <String>[];
    final Set<String> seen = <String>{};
    for (final String h in hosts) {
      final String host = h.trim().toLowerCase();
      if (host.isEmpty || seen.contains(host)) continue;
      if (host.contains('*') || host.startsWith('0.')) continue;
      if (!host.contains('.')) continue;
      seen.add(host);
      out.add(host);
      if (out.length >= _kMaxHosts) break;
    }
    return out;
  }

  Future<List<String>> _resolveHost(String host) async {
    try {
      final List<InternetAddress> addrs = await InternetAddress.lookup(
        host,
      ).timeout(_kLookupTimeout);
      return addrs
          .where((InternetAddress a) => a.type == InternetAddressType.IPv4)
          .map((InternetAddress a) => a.address)
          .where((String ip) => !_isLoopbackOrPrivate(ip))
          .toList();
    } catch (_) {
      return const <String>[];
    }
  }

  bool _isLoopbackOrPrivate(String ip) {
    if (ip.startsWith('127.') || ip == '0.0.0.0') return true;
    if (ip.startsWith('10.')) return true;
    if (ip.startsWith('192.168.')) return true;
    final List<String> parts = ip.split('.');
    if (parts.length == 4) {
      final int? a = int.tryParse(parts[0]);
      final int? b = int.tryParse(parts[1]);
      if (a == 172 && b != null && b >= 16 && b <= 31) return true;
    }
    return false;
  }

  Future<bool> _addRule(String ip) async {
    final String name = '$_rulePrefix${ip.replaceAll('.', '_')}';
    try {
      final ProcessResult pr = await windowsRunHidden(_netshExe(), <String>[
        'advfirewall',
        'firewall',
        'add',
        'rule',
        'name=$name',
        'dir=out',
        'action=block',
        'remoteip=$ip',
        'enable=yes',
      ]);
      return pr.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> _removeAllManagedRules() async {
    try {
      final File state = File(_statePath());
      if (await state.exists()) {
        final dynamic raw = jsonDecode(await state.readAsString());
        if (raw is List) {
          for (final dynamic item in raw) {
            final String ip = '$item';
            await _deleteRule(ip);
          }
        }
      }
    } catch (_) {}
    try {
      if (await File(_statePath()).exists()) {
        await File(_statePath()).delete();
      }
    } catch (_) {}
  }

  Future<void> _deleteRule(String ip) async {
    final String name = '$_rulePrefix${ip.replaceAll('.', '_')}';
    try {
      await windowsRunHidden(_netshExe(), <String>[
        'advfirewall',
        'firewall',
        'delete',
        'rule',
        'name=$name',
      ]);
    } catch (_) {}
  }

  Future<void> _writeState(List<String> ips) async {
    try {
      final File f = File(_statePath());
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(ips), flush: true);
    } catch (_) {}
  }

  static String programDataDir() {
    final String? pd = Platform.environment['ProgramData'];
    return p.join(pd ?? r'C:\ProgramData', 'SixVPNBlocker');
  }

  /// CMD-only BAT for firewall rules (netsh requires elevation).
  Future<String?> _writeAdminFirewallBat(List<String> ips) async {
    try {
      final String dir = programDataDir();
      await Directory(dir).create(recursive: true);
      final String batPath = p.join(dir, 'apply_firewall_admin.cmd');
      final StringBuffer lines = StringBuffer()
        ..writeln('@echo off')
        ..writeln('setlocal')
        ..writeln('echo [6 VPN Blocker] firewall outbound block...');
      for (final String ip in ips) {
        final String name = '$_rulePrefix${ip.replaceAll('.', '_')}';
        lines.writeln(
          'netsh advfirewall firewall delete rule name="$name" >nul 2>&1',
        );
        lines.writeln(
          'netsh advfirewall firewall add rule name="$name" dir=out action=block remoteip=$ip enable=yes',
        );
      }
      lines.writeln('echo Done. >> "%~dp0firewall_apply_cmd.log"');
      lines.writeln('exit /b 0');
      await File(batPath).writeAsString(lines.toString(), flush: true);

      final String? profile = Platform.environment['USERPROFILE'];
      if (profile != null) {
        final String desktop = p.join(profile, 'Desktop');
        final String shortcut = p.join(
          desktop,
          '6 VPN Blocker - firewall 적용 (관리자).bat',
        );
        await File(shortcut).writeAsString(
          '@echo off\r\n'
          'powershell -NoProfile -ExecutionPolicy Bypass -Command '
          '"Start-Process -FilePath \'$batPath\' -Verb RunAs"\r\n',
          flush: true,
        );
      }
      return batPath;
    } catch (_) {
      return null;
    }
  }
}
