import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_block_user_notice_service.dart';
import 'app_logger.dart';
import 'block_activity_log_service.dart';
import 'blocking_ecosystem_scan_service.dart';
import 'browser_block_health_monitor_service.dart';
import 'browser_enforcement_readiness_service.dart';
import 'browser_install_safety_service.dart';
import 'browser_protection_truth_service.dart';
import 'chrome_kill_exempt_service.dart';
import 'own_kill_ledger.dart';
import 'unprotected_browser_kill_guard_prefs.dart';
import 'windows_hidden_process.dart';

/// Blocks browsers that cannot enforce URL rules — **at launch** (fast watch)
/// with a short fallback tick. Chrome Gmail/Gemini PWAs are never killed.
final class UnprotectedBrowserKillGuardService {
  UnprotectedBrowserKillGuardService._();
  static final UnprotectedBrowserKillGuardService instance =
      UnprotectedBrowserKillGuardService._();

  /// Match [WindowsAppBlockService] cadence — no multi-minute wait on leaks.
  static const Duration _tickInterval = Duration(seconds: 4);
  static const Duration _urgentTickInterval = Duration(seconds: 2);
  static const Duration _launchWatchInterval = Duration(seconds: 2);
  static const Duration _bootDelay = Duration(seconds: 2);
  static const Duration _probeMaxAge = Duration(seconds: 30);
  static const Duration _killCooldown = Duration(seconds: 4);
  static const Duration _forceKillCooldown = Duration(seconds: 2);
  /// Launch block — no grace; user asked not to use Chrome then close later.
  static const int _launchBlockGraceSeconds = 0;
  /// Brief grace only when policy was just applied and browser may reload HKCU.
  static const int _policyReloadGraceSeconds = 4;

  static const Map<String, String> _idToExe = <String, String>{
    'chrome': 'chrome.exe',
    'edge': 'msedge.exe',
    'firefox': 'firefox.exe',
    'whale': 'whale.exe',
    'brave': 'brave.exe',
    'vivaldi': 'vivaldi.exe',
    'opera': 'opera.exe',
  };

  Timer? _timer;
  Timer? _urgentTimer;
  Timer? _launchTimer;
  bool _running = false;
  bool _busy = false;
  DateTime? _lastKillAt;
  final Map<String, DateTime> _lastKillByBrowser = <String, DateTime>{};
  final Map<String, Set<int>> _seenPidsByBrowser = <String, Set<int>>{};

  Future<void> start() async {
    // 6 VPN: NEUTRALIZED 2026-06-12 per user directive.
    // Users complained that Opera/Firefox/Edge/Whale/Naver Whale were being
    // silently force-killed within minutes of launch. The "hard_kill" UI
    // labels users see (e.g. "msedge.exe가 열리면 앱이 즉시 종료") were
    // produced by this service's 4-second periodic tick + 2-second launch
    // watch with grace=0 — any unprotected browser process was taskkill'd
    // on sight. That UX is intolerable; replaced with notification at
    // the access-attempt point (hosts NXDOMAIN + extension overlay).
    // Block enforcement now comes from: hosts sinkhole, URLBlocklist
    // policy, browser extension content_script — NOT from killing browsers.
    if (!Platform.isWindows) return;
    AppLogger.instance.info(
        'unprotected_browser_kill_guard: NEUTRALIZED (no-op start)');
    return;
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _urgentTimer?.cancel();
    _launchTimer?.cancel();
    _timer = null;
    _urgentTimer = null;
    _launchTimer = null;
  }

  void notifyPolicyApplied() {
    // 6 VPN: NEUTRALIZED — no longer triggers hard-kill of unprotected browsers.
    BrowserEnforcementReadinessService.instance.invalidate();
    BlockingEcosystemScanService.instance.requestRefresh(
      reason: 'post_apply_notify_only',
      force: true,
    );
  }

  /// Live gate leak / policy apply — NEUTRALIZED. Was killing browsers
  /// within 0-second grace; that UX is intolerable. Block enforcement
  /// must come from hosts/policy/extension layers, not process termination.
  Future<void> enforceImmediately({
    String reason = 'immediate',
    bool forceProbe = true,
  }) async {
    AppLogger.instance.info(
        'unprotected_browser_kill_guard.enforceImmediately: no-op ($reason)');
    return;
  }

  Future<void> _enforceStaleBrowsers({required String reason}) async {
    if (!_running || !Platform.isWindows) return;
    if (!await UnprotectedBrowserKillGuardPrefs.instance.enabled()) return;
    if (await BrowserInstallSafetyService.instance.shouldPauseAllKills()) {
      return;
    }
    final BrowserBlockHealthReport report =
        await BrowserBlockHealthMonitorService.instance.probe(
      reason: 'kill_guard_$reason',
    );
    await _killUnprotected(report, reason, launchBlock: false);
  }

  /// Fast path — kill brand-new PIDs before the user can browse (~3s cadence).
  Future<void> _launchWatch({required String reason}) async {
    if (!_running || _busy || !Platform.isWindows) return;
    if (!await UnprotectedBrowserKillGuardPrefs.instance.enabled()) return;
    if (await BrowserInstallSafetyService.instance.shouldPauseAllKills()) {
      return;
    }
    if (await ChromeKillExemptService.instance.chromeKillGuardPaused()) {
      return;
    }

    final Set<String> forceKill =
        await BrowserProtectionTruthService.instance.forceKillBrowserIds();
    if (forceKill.isEmpty) return;

    BrowserBlockHealthReport? report =
        BrowserBlockHealthMonitorService.instance.latest;
    if (report == null || !report.hasAnyRule) return;

    for (final String browserId in forceKill) {
      final String? exe = _idToExe[browserId];
      if (exe == null) continue;
      final List<int> pids =
          await ChromeKillExemptService.instance.killablePidsForExe(exe);
      final Set<int> seen =
          _seenPidsByBrowser.putIfAbsent(browserId, () => <int>{});
      for (final int pid in pids) {
        if (seen.contains(pid)) continue;
        seen.add(pid);
        if (seen.length > 200) {
          seen.removeWhere((int p) => !pids.contains(p));
        }
        await _killPid(
          browserId: browserId,
          displayName: _displayName(browserId, report),
          pid: pid,
          probeReason: '${reason}_launch_block',
          launchBlock: true,
        );
      }
    }
  }

  Future<void> _tick({
    String reason = 'periodic',
    bool forceProbe = false,
  }) async {
    if (!_running || _busy || !Platform.isWindows) return;
    if (!await UnprotectedBrowserKillGuardPrefs.instance.enabled()) return;
    if (await BrowserInstallSafetyService.instance.shouldPauseAllKills()) {
      return;
    }

    _busy = true;
    try {
      BrowserBlockHealthReport? report =
          BrowserBlockHealthMonitorService.instance.latest;
      final DateTime now = DateTime.now();
      final bool stale = report == null ||
          now.difference(report.checkedAt) > _probeMaxAge;
      if (forceProbe || stale) {
        report = await BrowserBlockHealthMonitorService.instance.probe(
          reason: 'kill_guard_$reason',
        );
      }
      if (!report.hasAnyRule) return;

      await _killUnprotected(report, reason, launchBlock: true);
      _scheduleUrgentIfNeeded(report);
    } catch (e, st) {
      AppLogger.instance.warn('unprotected_browser_kill_guard: $e\n$st');
    } finally {
      _busy = false;
    }
  }

  void _scheduleUrgentIfNeeded(BrowserBlockHealthReport report) {
    final bool needsUrgent = report.browsers.any(
      (BrowserHealth b) =>
          b.installed &&
          b.running &&
          !b.effectivelyBlockActive,
    );
    if (!needsUrgent) {
      _urgentTimer?.cancel();
      _urgentTimer = null;
      return;
    }
    if (_urgentTimer != null) return;
    _urgentTimer = Timer(_urgentTickInterval, () {
      _urgentTimer = null;
      unawaited(_tick(reason: 'urgent_stale_policy'));
      unawaited(_launchWatch(reason: 'urgent'));
    });
  }

  Future<void> _killUnprotected(
    BrowserBlockHealthReport report,
    String probeReason, {
    required bool launchBlock,
  }) async {
    if (await ChromeKillExemptService.instance.chromeKillGuardPaused()) {
      return;
    }

    final DateTime now = DateTime.now();
    final Set<String> forceKill =
        await BrowserProtectionTruthService.instance.forceKillBrowserIds();

    for (final BrowserHealth b in report.browsers) {
      if (b.id == 'chrome' &&
          await ChromeKillExemptService.instance.chromeKillGuardPaused()) {
        continue;
      }

      if (forceKill.contains(b.id) && b.installed && b.running) {
        if (await BrowserInstallSafetyService.instance
            .shouldSkipKillForBrowser(b.id)) {
          continue;
        }
        if (_withinGrace(b.processStart, now, launchBlock: launchBlock)) {
          continue;
        }
        if (_recentlyKilled(b.id, now, forceKill: true)) continue;
        await _forceTerminateBrowser(
          browserId: b.id,
          displayName: b.displayName,
          probeReason: '${probeReason}_truth_force_kill',
          launchBlock: launchBlock,
        );
        continue;
      }

      if (b.effectivelyBlockActive || !b.installed || !b.running) continue;
      if (await BrowserInstallSafetyService.instance
          .shouldSkipKillForBrowser(b.id)) {
        continue;
      }
      if (_withinGrace(b.processStart, now, launchBlock: launchBlock)) {
        continue;
      }
      if (_recentlyKilled(b.id, now)) continue;
      await _forceTerminateBrowser(
        browserId: b.id,
        displayName: b.displayName,
        probeReason: probeReason,
        launchBlock: launchBlock,
      );
    }
  }

  String _displayName(String browserId, BrowserBlockHealthReport report) {
    for (final BrowserHealth b in report.browsers) {
      if (b.id == browserId) return b.displayName;
    }
    return browserId;
  }

  bool _withinGrace(
    DateTime? processStart,
    DateTime now, {
    required bool launchBlock,
  }) {
    if (processStart == null) return false;
    final int grace = launchBlock
        ? _launchBlockGraceSeconds
        : _policyReloadGraceSeconds;
    if (grace <= 0) return false;
    return now.difference(processStart).inSeconds < grace;
  }

  bool _recentlyKilled(
    String browserId,
    DateTime now, {
    bool forceKill = false,
  }) {
    final DateTime? last = _lastKillByBrowser[browserId];
    if (last == null) return false;
    final Duration gap = forceKill ? _forceKillCooldown : _killCooldown;
    return now.difference(last) < gap;
  }

  /// App-block style: terminate every non-exempt process for this browser image.
  Future<void> _forceTerminateBrowser({
    required String browserId,
    required String displayName,
    required String probeReason,
    required bool launchBlock,
  }) async {
    final String? exe = _idToExe[browserId];
    if (exe == null) return;
    if (browserId == 'chrome' &&
        await ChromeKillExemptService.instance.chromeKillGuardPaused()) {
      return;
    }

    List<int> pids =
        await ChromeKillExemptService.instance.killablePidsForExe(exe);
    if (pids.isEmpty && browserId != 'chrome') {
      await _killByImage(
        browserId: browserId,
        displayName: displayName,
        exe: exe,
        probeReason: probeReason,
        launchBlock: launchBlock,
      );
      return;
    }
    for (final int pid in pids) {
      await _killPid(
        browserId: browserId,
        displayName: displayName,
        pid: pid,
        probeReason: probeReason,
        launchBlock: launchBlock,
        skipNotice: pids.length > 1,
      );
    }
    if (pids.length > 1) {
      AppBlockUserNoticeService.instance.notifyBrowserLaunchBlocked(
        browserDisplayName: displayName,
        detailKo: launchBlock
            ? '$displayName 실행을 막았습니다 — URL 차단이 먹히지 않아 즉시 종료합니다.'
            : '$displayName을(를) 종료했습니다 — 차단 정책이 아직 로드되지 않았습니다.',
      );
    }
  }

  Future<void> _killByImage({
    required String browserId,
    required String displayName,
    required String exe,
    required String probeReason,
    required bool launchBlock,
  }) async {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final String taskkill = p.join(windir, 'System32', 'taskkill.exe');
    final String userMsg = launchBlock
        ? '$displayName 실행을 막았습니다 — URL 차단이 이 브라우저에서 먹히지 않아 '
            '열리자마자 종료합니다.'
        : '$displayName을(를) 종료했습니다 — 차단 정책이 아직 로드되지 않았습니다.';

    AppBlockUserNoticeService.instance.notifyBrowserLaunchBlocked(
      browserDisplayName: displayName,
      detailKo: userMsg,
    );

    try {
      OwnKillLedger.instance.stampImage(
        imageName: exe,
        reason: userMsg,
        reasonKey: launchBlock
            ? 'unprotected_launch_block'
            : 'unprotected_policy_reload',
        scheduleLabel: displayName,
      );
      final ProcessResult pr = await windowsRunHidden(
        taskkill,
        <String>['/F', '/IM', exe],
      );
      _lastKillAt = DateTime.now();
      _lastKillByBrowser[browserId] = _lastKillAt!;
      AppLogger.instance.warn(
        'unprotected_browser_kill_image: $displayName /IM $exe '
        'launchBlock=$launchBlock exit=${pr.exitCode}',
      );
      BlockActivityLogService.instance.record(
        kind: BlockActivityKind.protection,
        message: userMsg,
        data: <String, Object?>{
          'browser': browserId,
          'exe': exe,
          'probeReason': probeReason,
          'launchBlock': launchBlock,
          'mode': 'taskkill_im',
        },
        debounceKey: 'kill_unprotected_img_$browserId',
      );
    } catch (e) {
      AppLogger.instance.warn('kill image $displayName failed: $e');
    }
  }

  Future<void> _killPid({
    required String browserId,
    required String displayName,
    required int pid,
    required String probeReason,
    required bool launchBlock,
    bool skipNotice = false,
  }) async {
    final String? exe = _idToExe[browserId];
    if (exe == null) return;

    if (browserId == 'chrome' &&
        await ChromeKillExemptService.instance.shouldExemptPid(pid)) {
      return;
    }

    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final String taskkill = p.join(windir, 'System32', 'taskkill.exe');

    final String userMsg = launchBlock
        ? '$displayName 실행을 막았습니다 — URL 차단이 이 브라우저에서 먹히지 않아 '
            '열리자마자 종료합니다. Whale·Firefox 등 「URL 가능」 브라우저를 쓰세요.'
        : '$displayName을(를) 종료했습니다 — 차단 정책이 아직 로드되지 않았습니다. '
            '완전히 닫았다가 다시 열면 URL 차단이 적용됩니다.';

    if (!skipNotice) {
      AppBlockUserNoticeService.instance.notifyBrowserLaunchBlocked(
        browserDisplayName: displayName,
        detailKo: userMsg,
      );
    }

    try {
      final String? exeImageName = (exe?.trim().isNotEmpty ?? false) ? exe : null;
      OwnKillLedger.instance.stampPid(
        pid: pid,
        imageName: exeImageName ?? '${browserId}.exe',
        reason: launchBlock
            ? '$displayName 미보호 실행 차단 — URL 차단 미적용 브라우저'
            : '$displayName 정책 미로드 — 재시작 유도',
        reasonKey: launchBlock
            ? 'unprotected_launch_block'
            : 'unprotected_policy_reload',
        scheduleLabel: displayName,
      );
      final ProcessResult pr = await windowsRunHidden(
        taskkill,
        <String>['/F', '/PID', '$pid'],
      );
      _lastKillAt = DateTime.now();
      _lastKillByBrowser[browserId] = _lastKillAt!;

      AppLogger.instance.warn(
        'unprotected_browser_kill: $displayName pid=$pid '
        'launchBlock=$launchBlock exit=${pr.exitCode}',
      );
      BlockActivityLogService.instance.record(
        kind: BlockActivityKind.protection,
        message: userMsg,
        data: <String, Object?>{
          'browser': browserId,
          'pid': pid,
          'probeReason': probeReason,
          'launchBlock': launchBlock,
        },
        debounceKey: 'kill_unprotected_${browserId}_$pid',
      );
    } catch (e) {
      AppLogger.instance.warn('kill $displayName failed: $e');
    }
  }
}
