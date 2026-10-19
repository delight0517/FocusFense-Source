import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'block_activity_log_service.dart';
import 'blocking_self_heal_prefs.dart';
import 'browser_protection_truth_service.dart';
import 'windows_hidden_process.dart';

/// Runs [Test-AllBrowsers-UrlBlock.ps1] and maintains a **hard-kill roster**
/// for browsers that leak test URLs or lack registry patterns.
///
/// When URLBlocklist cannot be trusted, [UnprotectedBrowserKillGuardService]
/// terminates those browsers on sight (user-requested fallback).
final class BrowserLiveUrlBlockGateService {
  BrowserLiveUrlBlockGateService._();
  static final BrowserLiveUrlBlockGateService instance =
      BrowserLiveUrlBlockGateService._();

  static const List<String> kDefaultTestUrls = <String>[
    'https://mingky01.live/',
    'https://linkdamoa01.com/',
  ];

  // Auto-run guard: 4-hour FILE-BASED cooldown (survives restarts) +
  // in-memory running flag (no concurrent runs).
  // force=true bypasses cooldown for manual/diagnostics/post-update callers.
  // Auto-run also requires BlockingSelfHealPrefs.autoLiveTestEnabled() = true
  // (default OFF) so the headless browser storm never fires without opt-in.
  static const Duration _kCooldown = Duration(hours: 4);
  static const String _kLastRunFile = 'live_test_last_run.json';
  bool _running = false;
  DateTime? _lastRunAt; // in-memory fast-path; file is authoritative

  static String _sixVpnDir() {
    final String local = Platform.environment['LOCALAPPDATA'] ?? '';
    return p.join(local, 'SixVPNBlocker');
  }

  static String reportPath() =>
      p.join(_sixVpnDir(), 'debug', 'all_browsers_url_block_test.json');

  static String rosterPath() =>
      p.join(_sixVpnDir(), 'browser_hard_kill_roster.json');

  String _repoToolsScript() {
    final String dest = p.join(_sixVpnDir(), 'tools', 'Test-AllBrowsers-UrlBlock.ps1');
    final String? marker = Platform.environment['SIXVPN_REPO_ROOT'];
    if (marker != null && marker.isNotEmpty) {
      return p.join(marker, 'mobile', 'tools', 'Test-AllBrowsers-UrlBlock.ps1');
    }
    return dest;
  }

  Future<void> _ensureScriptDeployed() async {
    final String dest = p.join(_sixVpnDir(), 'tools', 'Test-AllBrowsers-UrlBlock.ps1');
    if (await File(dest).exists()) return;
    final String src = _repoToolsScript();
    if (src == dest) return;
    if (!await File(src).exists()) return;
    await Directory(p.dirname(dest)).create(recursive: true);
    await File(src).copy(dest);
  }

  /// Runs the all-browser probe (registry + headless). Writes JSON report + roster.
  ///
  /// Automatic calls (from syncs, scans) are rate-limited to [_kCooldown].
  /// Pass [force] = true for manual / diagnostics-screen invocations.
  Future<BrowserLiveUrlBlockGateReport> runLiveTest({
    bool applyPolicyFirst = true,
    String reason = 'manual',
    bool force = false,
  }) async {
    if (!Platform.isWindows) {
      return const BrowserLiveUrlBlockGateReport(
        ok: true,
        message: 'Windows 전용',
        hardKillIds: <String>[],
      );
    }
    if (_running) {
      AppLogger.instance.info(
        'browser_live_url_gate [$reason]: skipped — already running',
      );
      return BrowserLiveUrlBlockGateReport(
        ok: false,
        message: '이미 실행 중',
        hardKillIds: (await hardKillBrowserIds()).toList(),
      );
    }
    if (!force) {
      // Auto live test is OFF by default — requires explicit opt-in.
      // This prevents headless browser launches from firing invisibly in
      // the background every time a sync/scan/orchestrator runs.
      final bool autoEnabled =
          await BlockingSelfHealPrefs.instance.autoLiveTestEnabled();
      if (!autoEnabled) {
        AppLogger.instance.info(
          'browser_live_url_gate [$reason]: skipped — auto live test 꺼짐 '
          '(설정 → 도구 → 자동 URL 실측에서 켤 수 있음)',
        );
        return BrowserLiveUrlBlockGateReport(
          ok: false,
          message: '자동 URL 실측 꺼짐',
          hardKillIds: (await hardKillBrowserIds()).toList(),
        );
      }
      // File-based cooldown: survives across restarts.
      final DateTime? lastFile = await _readLastRunFile();
      final DateTime? effective =
          (_lastRunAt != null && lastFile != null)
              ? (_lastRunAt!.isAfter(lastFile!) ? _lastRunAt : lastFile)
              : (_lastRunAt ?? lastFile);
      if (effective != null) {
        final Duration elapsed = DateTime.now().difference(effective);
        if (elapsed < _kCooldown) {
          AppLogger.instance.info(
            'browser_live_url_gate [$reason]: skipped — 쿨다운 '
            '(${elapsed.inMinutes}분 경과 / ${_kCooldown.inHours}시간 필요)',
          );
          return BrowserLiveUrlBlockGateReport(
            ok: false,
            message: '쿨다운 중 (${_kCooldown.inHours}시간마다 자동 실행)',
            hardKillIds: (await hardKillBrowserIds()).toList(),
          );
        }
      }
    }
    _running = true;
    _lastRunAt = DateTime.now();

    try {
      await _ensureScriptDeployed();
      final String script = p.join(
        _sixVpnDir(),
        'tools',
        'Test-AllBrowsers-UrlBlock.ps1',
      );
      if (!await File(script).exists()) {
        return BrowserLiveUrlBlockGateReport(
          ok: false,
          message: 'Test-AllBrowsers-UrlBlock.ps1 없음',
          hardKillIds: (await hardKillBrowserIds()).toList(),
        );
      }

      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final String psExe = p.join(
        windir,
        'System32',
        'WindowsPowerShell',
        'v1.0',
        'powershell.exe',
      );
      final List<String> args = <String>[
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script,
      ];
      if (applyPolicyFirst) args.add('-ApplyPolicyFirst');

      final Stopwatch sw = Stopwatch()..start();
      final ProcessResult pr = await windowsRunHidden(
        psExe,
        args,
      ).timeout(
        const Duration(minutes: 8),
        onTimeout: () => ProcessResult(0, -1, '', 'timeout'),
      );

      BrowserLiveUrlBlockGateReport report;
      try {
        final File f = File(reportPath());
        if (await f.exists()) {
          final Object? decoded = jsonDecode(await f.readAsString());
          report = BrowserLiveUrlBlockGateReport.fromJson(
            decoded is Map ? Map<String, Object?>.from(decoded) : <String, Object?>{},
          );
        } else {
          report = BrowserLiveUrlBlockGateReport(
            ok: pr.exitCode == 0,
            message: 'report missing exit=${pr.exitCode}',
            hardKillIds: <String>[],
          );
        }
      } catch (e) {
        report = BrowserLiveUrlBlockGateReport(
          ok: false,
          message: 'parse failed: $e',
          hardKillIds: <String>[],
        );
      }

      await _writeRoster(report);
      await _writeLastRunFile();
      BrowserProtectionTruthService.instance.notifyLiveGateUpdated();
      AppLogger.instance.info(
        'browser_live_url_gate [$reason]: ok=${report.ok} '
        'hardKill=${report.hardKillIds} ms=${sw.elapsedMilliseconds}',
      );
      BlockActivityLogService.instance.record(
        kind: BlockActivityKind.protection,
        message: report.summaryKo.isNotEmpty
            ? report.summaryKo
            : '브라우저 URL 실측: hardKill=${report.hardKillIds.join(",")}',
        data: report.toJson(),
        debounceKey: 'live_url_gate',
      );
      return report;
    } finally {
      _running = false;
    }
  }

  Future<DateTime?> _readLastRunFile() async {
    try {
      final File f = File(p.join(_sixVpnDir(), _kLastRunFile));
      if (!await f.exists()) return null;
      final Object? decoded = jsonDecode(await f.readAsString());
      if (decoded is Map) {
        final String? ts = decoded['lastRunAt'] as String?;
        if (ts != null) return DateTime.tryParse(ts);
      }
    } catch (_) {}
    return null;
  }

  Future<void> _writeLastRunFile() async {
    try {
      _lastRunAt = DateTime.now();
      final File f = File(p.join(_sixVpnDir(), _kLastRunFile));
      await f.writeAsString(
        jsonEncode(<String, String>{
          'lastRunAt': _lastRunAt!.toIso8601String(),
        }),
        flush: true,
      );
    } catch (_) {}
  }

  Future<void> _writeRoster(BrowserLiveUrlBlockGateReport report) async {
    final Map<String, Object?> body = <String, Object?>{
      'updatedAt': DateTime.now().toIso8601String(),
      'hardKillIds': report.hardKillIds,
      'ok': report.ok,
      'summaryKo': report.summaryKo,
      'browsers': report.browsers.map((BrowserLiveGateRow b) => b.toJson()).toList(),
      'reportPath': reportPath(),
    };
    try {
      final File f = File(rosterPath());
      await f.parent.create(recursive: true);
      await f.writeAsString(
        const JsonEncoder.withIndent('  ').convert(body),
        flush: true,
      );
    } catch (e) {
      AppLogger.instance.warn('browser_live_url_gate roster write failed: $e');
    }
  }

  Future<Set<String>> hardKillBrowserIds() async {
    try {
      final File f = File(rosterPath());
      if (!await f.exists()) return <String>{};
      final Object? decoded = jsonDecode(await f.readAsString());
      if (decoded is! Map) return <String>{};
      final Object? ids = decoded['hardKillIds'];
      if (ids is! List) return <String>{};
      return ids
          .map((dynamic e) => e.toString())
          .where((String s) => s.isNotEmpty)
          .toSet();
    } catch (_) {
      return <String>{};
    }
  }

  Future<bool> shouldHardKill(String browserId) async {
    return (await hardKillBrowserIds()).contains(browserId);
  }
}

final class BrowserLiveUrlBlockGateReport {
  const BrowserLiveUrlBlockGateReport({
    required this.ok,
    required this.message,
    required this.hardKillIds,
    this.summaryKo = '',
    this.browsers = const <BrowserLiveGateRow>[],
  });

  final bool ok;
  final String message;
  final List<String> hardKillIds;
  final String summaryKo;
  final List<BrowserLiveGateRow> browsers;

  factory BrowserLiveUrlBlockGateReport.fromJson(Map<String, Object?> json) {
    final List<BrowserLiveGateRow> rows = <BrowserLiveGateRow>[];
    final Object? bl = json['browsers'];
    if (bl is List) {
      for (final Object item in bl) {
        if (item is Map) {
          rows.add(BrowserLiveGateRow.fromJson(Map<String, Object?>.from(item)));
        }
      }
    }
    final Object? hk = json['hardKillIds'];
    return BrowserLiveUrlBlockGateReport(
      ok: json['ok'] == true,
      message: '${json['summaryKo'] ?? json['message'] ?? ''}',
      summaryKo: '${json['summaryKo'] ?? ''}',
      hardKillIds: hk is List
          ? hk.map((dynamic e) => e.toString()).toList(growable: false)
          : const <String>[],
      browsers: rows,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'ok': ok,
        'message': message,
        'summaryKo': summaryKo,
        'hardKillIds': hardKillIds,
        'browsers': browsers.map((BrowserLiveGateRow b) => b.toJson()).toList(),
      };
}

final class BrowserLiveGateRow {
  const BrowserLiveGateRow({
    required this.id,
    required this.displayName,
    required this.installed,
    required this.registryOk,
    required this.liveBlocked,
    required this.hardKill,
    this.detailKo = '',
  });

  final String id;
  final String displayName;
  final bool installed;
  final bool registryOk;
  final bool liveBlocked;
  final bool hardKill;
  final String detailKo;

  factory BrowserLiveGateRow.fromJson(Map<String, Object?> json) {
    return BrowserLiveGateRow(
      id: '${json['id'] ?? ''}',
      displayName: '${json['displayName'] ?? ''}',
      installed: json['installed'] == true,
      registryOk: json['registryOk'] == true,
      liveBlocked: json['liveBlocked'] == true,
      hardKill: json['hardKill'] == true,
      detailKo: '${json['detailKo'] ?? ''}',
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'displayName': displayName,
        'installed': installed,
        'registryOk': registryOk,
        'liveBlocked': liveBlocked,
        'hardKill': hardKill,
        'detailKo': detailKo,
      };
}
