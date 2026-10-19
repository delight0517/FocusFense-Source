import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';
import 'block_activity_log_service.dart';
import 'build_identity_service.dart';
import 'chrome_extension_payload_service.dart';
import 'chrome_load_extension_launcher.dart';
import 'crash_journal_service.dart';
import 'cursor_agent_fix_log_service.dart';
import 'extension_guard_prefs.dart';
import 'rebuild_preferences_service.dart';
import 'windows_emergency_block_service.dart';
import 'windows_hkcu_policy_service.dart';

/// **Rebuild Auto-Shower** — 리빌드 직후 이전 차단·확장·중복 레이어를
/// 깨끗이 비운 뒤 [PostRebuildBootstrapService] / 오케스트레이터가 다시 깔도록 함.
///
/// * **유지**: SQLite 스케줄·규칙, 백업, 리빌드 설정 토글 3종
/// * **삭제**: HKCU URLBlocklist, PAC, 확장 미러 중복, 적용 캐시·쿨다운 플래그
///
/// 로그: `%USERPROFILE%\Documents\SixVPN_Blocker_Debug\rebuild_auto_shower_last.json`
final class RebuildAutoShowerService {
  RebuildAutoShowerService._();
  static final RebuildAutoShowerService instance = RebuildAutoShowerService._();

  static const String kPendingFileName = 'rebuild_auto_shower_pending.txt';

  static bool completedThisSession = false;
  static bool _running = false;

  String get reportPath => p.join(
        CrashJournalService.instance.debugFolderPath,
        'rebuild_auto_shower_last.json',
      );

  static String? _localAppDataDir() => Platform.environment['LOCALAPPDATA'];

  static String get _pendingPath {
    final String la = _localAppDataDir() ?? r'C:\Users\Public';
    return p.join(la, 'SixVPNBlocker', kPendingFileName);
  }

  /// Runs once per session when rebuild script queued [kPendingFileName].
  Future<RebuildShowerReport> runIfNeeded({
    String reason = 'launch',
    bool force = false,
  }) async {
    if (!Platform.isWindows) {
      return RebuildShowerReport.skipped('Windows 전용');
    }
    if (_running) {
      return RebuildShowerReport.skipped('샤워 실행 중');
    }
    if (completedThisSession && !force) {
      return RebuildShowerReport.skipped('이번 세션 샤워 완료');
    }

    final bool enabled =
        await RebuildPreferencesService.instance.rebuildAutoShowerEnabled();
    if (!enabled && !force) {
      return RebuildShowerReport.skipped('자동 샤워 꺼짐');
    }

    final bool pending = await _readPendingFlag();
    if (!force && !pending) {
      return RebuildShowerReport.skipped('리빌드 샤워 대기 없음');
    }

    _running = true;
    final DateTime started = DateTime.now();
    final List<RebuildShowerStep> steps = <RebuildShowerStep>[];
    final List<String> removed = <String>[];
    final List<String> kept = <String>['sqlite_rules', 'backup', 'rebuild_prefs'];

    try {
      AppLogger.instance.info('rebuild_auto_shower: start reason=$reason');
      BlockActivityLogService.instance.record(
        kind: BlockActivityKind.boot,
        message: '리빌드 자동 샤워 시작 — 이전 차단·확장 레이어 정리',
        debounceKey: 'rebuild_auto_shower',
      );

      await _step(steps, 'hkcu_policies_remove', () async {
        final HkcuPolicyResult r =
            await WindowsHkcuPolicyService.instance.removeNow();
        return r.success
            ? 'HKCU URLBlocklist 제거 (${r.targets.join(", ")})'
            : 'HKCU 제거: ${r.message}';
      });

      await _step(steps, 'pac_remove', () async {
        await WindowsEmergencyBlockService.instance.removePac();
        return 'PAC AutoConfigURL 제거';
      });

      await _step(steps, 'extension_mirror_clean', () async {
        final int n = await _cleanExtensionMirrors(removed);
        return '확장 미러 정리 $n건';
      });

      await _step(steps, 'extension_guard_cache', () async {
        await ExtensionGuardPrefs.instance.setChromeSourcePath('');
        // load-extension flag restored in load_extension_launchers step below.
        return '확장 경로 캐시 초기화';
      });

      await _step(steps, 'enforcement_prefs', () async {
        final int n = await _clearEnforcementRuntimePrefs();
        return '적용 런타임 prefs $n키 삭제';
      });

      await _step(steps, 'fresh_extension_payload', () async {
        await ChromeExtensionPayloadService.ensureStablePayload();
        return 'LOCALAPPDATA 확장 페이로드 재생성';
      });

      await _step(steps, 'load_extension_launchers', () async {
        final String folder = ChromeLoadExtensionLauncher.stableChromeExtDir;
        if (!await File(p.join(folder, 'manifest.json')).exists()) {
          return 'manifest 없음 — 부트스트랩에서 재설치';
        }
        final LoadExtensionLauncherResult r =
            await ChromeLoadExtensionLauncher.install(extensionFolder: folder);
        return r.ok ? '보호 VBS 실행기 재설치' : r.message;
      });

      await _clearPendingFlag();

      final BuildIdentity build = await BuildIdentityService.instance.current();
      final bool ok = steps.every((RebuildShowerStep s) => s.ok);
      final RebuildShowerReport report = RebuildShowerReport(
        at: DateTime.now(),
        buildLabel: '${build.version}+${build.buildNumber}',
        reason: reason,
        ok: ok,
        verdict: ok
            ? '자동 샤워 완료 — 차단·확장 레이어 초기화 후 재적용 예정'
            : '자동 샤워 일부 실패 — 로그 확인',
        steps: steps,
        removed: removed,
        kept: kept,
        durationMs: DateTime.now().difference(started).inMilliseconds,
      );

      await _persist(report);
      completedThisSession = true;

      await CursorAgentFixLogService.instance.record(
        CursorAgentFixEntry(
          component: 'rebuild_auto_shower',
          action: reason,
          ok: ok,
          verdict: report.verdict,
          reason: reason,
          details: report.toJson(),
          appliedLayers: const <String>['shower_clean'],
          fixesAttempted:
              steps.map((RebuildShowerStep s) => s.name).toList(),
        ),
      );

      BlockActivityLogService.instance.record(
        kind: BlockActivityKind.boot,
        message: report.verdict,
        data: report.toJson(),
        level: ok ? 'info' : 'warn',
        debounceKey: 'rebuild_auto_shower_done',
      );

      AppLogger.instance.info('rebuild_auto_shower: ${report.verdict}');
      return report;
    } catch (e, st) {
      AppLogger.instance.error('rebuild_auto_shower failed', error: e, stack: st);
      final RebuildShowerReport fail = RebuildShowerReport(
        at: DateTime.now(),
        buildLabel: 'error',
        reason: reason,
        ok: false,
        verdict: '자동 샤워 오류: $e',
        steps: steps,
        removed: removed,
        kept: kept,
        durationMs: DateTime.now().difference(started).inMilliseconds,
        error: '$e',
      );
      await _persist(fail);
      return fail;
    } finally {
      _running = false;
    }
  }

  Future<void> _step(
    List<RebuildShowerStep> out,
    String name,
    Future<String> Function() body,
  ) async {
    try {
      final String detail = await body();
      out.add(RebuildShowerStep(name: name, ok: true, detail: detail));
    } catch (e) {
      out.add(RebuildShowerStep(name: name, ok: false, detail: '$e'));
    }
  }

  Future<int> _cleanExtensionMirrors(List<String> removed) async {
    final String la = _localAppDataDir() ?? '';
    if (la.isEmpty) return 0;
    final Directory root = Directory(p.join(la, 'SixVPNBlocker'));
    if (!await root.exists()) return 0;

    int count = 0;
    await for (final FileSystemEntity e in root.list()) {
      if (e is! Directory) continue;
      final String base = p.basename(e.path);
      if (base.startsWith('chrome_blocker_retired') ||
          base.startsWith('chrome_blocker_staging')) {
        try {
          await e.delete(recursive: true);
          removed.add(base);
          count++;
        } catch (_) {}
      }
    }

    // Force remirror on next install
    final Directory stable = Directory(ChromeLoadExtensionLauncher.stableChromeExtDir);
    if (await stable.exists()) {
      try {
        final Directory retired = Directory(
          '${stable.path}_shower_${DateTime.now().millisecondsSinceEpoch}',
        );
        await stable.rename(retired.path);
        removed.add(p.basename(retired.path));
        count++;
      } catch (_) {}
    }
    return count;
  }

  /// Clears enforcement cooldown / cache keys — **not** user block rules (SQLite).
  Future<int> _clearEnforcementRuntimePrefs() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    const Set<String> keep = <String>{
      'rebuild_heavy_post_bootstrap_v1',
      'rebuild_no_auto_agent_v2',
      'rebuild_auto_shower_v1',
    };
    final Set<String> keys = prefs.getKeys();
    int n = 0;
    for (final String key in keys) {
      if (keep.contains(key)) continue;
      if (key.startsWith('post_bootstrap_') ||
          key == 'post_bootstrap_last_build_v1' ||
          key.startsWith('extension_guard_chrome_path') ||
          key.startsWith('boot_browser_') ||
          key.startsWith('youtube_hosts_') ||
          key.startsWith('blocking_self_heal_last') ||
          key.startsWith('hosts_health_') ||
          key.startsWith('cursor_agent_') ||
          key.startsWith('autonomous_apply_')) {
        await prefs.remove(key);
        n++;
      }
    }
    return n;
  }

  Future<bool> _readPendingFlag() async {
    try {
      final File f = File(_pendingPath);
      return await f.exists();
    } catch (_) {
      return false;
    }
  }

  Future<void> _clearPendingFlag() async {
    try {
      final File f = File(_pendingPath);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  static Future<void> writePendingFlag(String buildLabel) async {
    if (!Platform.isWindows) return;
    try {
      final String la = _localAppDataDir() ?? r'C:\Users\Public';
      final Directory dir = Directory(p.join(la, 'SixVPNBlocker'));
      await dir.create(recursive: true);
      await File(p.join(dir.path, kPendingFileName))
          .writeAsString(buildLabel.trim(), flush: true);
    } catch (_) {}
  }

  Future<void> _persist(RebuildShowerReport report) async {
    try {
      await CrashJournalService.instance.warmup();
      await File(reportPath).writeAsString(
        const JsonEncoder.withIndent('  ').convert(report.toJson()),
        flush: true,
      );
    } catch (e) {
      AppLogger.instance.warn('rebuild_auto_shower persist: $e');
    }
  }
}

final class RebuildShowerStep {
  const RebuildShowerStep({
    required this.name,
    required this.ok,
    required this.detail,
  });

  final String name;
  final bool ok;
  final String detail;

  Map<String, Object?> toJson() => <String, Object?>{
        'name': name,
        'ok': ok,
        'detail': detail,
      };
}

final class RebuildShowerReport {
  RebuildShowerReport({
    required this.at,
    required this.buildLabel,
    required this.reason,
    required this.ok,
    required this.verdict,
    required this.steps,
    required this.removed,
    required this.kept,
    required this.durationMs,
    this.error,
  });

  factory RebuildShowerReport.skipped(String msg) => RebuildShowerReport(
        at: DateTime.now(),
        buildLabel: 'skip',
        reason: 'skipped',
        ok: true,
        verdict: msg,
        steps: const <RebuildShowerStep>[],
        removed: const <String>[],
        kept: const <String>[],
        durationMs: 0,
      );

  final DateTime at;
  final String buildLabel;
  final String reason;
  final bool ok;
  final String verdict;
  final List<RebuildShowerStep> steps;
  final List<String> removed;
  final List<String> kept;
  final int durationMs;
  final String? error;

  Map<String, Object?> toJson() => <String, Object?>{
        'at': at.toIso8601String(),
        'buildLabel': buildLabel,
        'reason': reason,
        'ok': ok,
        'verdict': verdict,
        'steps': steps.map((RebuildShowerStep s) => s.toJson()).toList(),
        'removed': removed,
        'kept': kept,
        'durationMs': durationMs,
        if (error != null) 'error': error,
        'reportPath': RebuildAutoShowerService.instance.reportPath,
        'note':
            '스케줄·차단 규칙(SQLite)은 유지됩니다. 적용 레이어(HKCU·PAC·확장)만 초기화 후 재적용합니다.',
      };
}
