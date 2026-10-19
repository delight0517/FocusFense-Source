import 'dart:async';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../data/browser_ecosystem_catalog.dart';
import 'app_logger.dart';
import 'browser_block_health_monitor_service.dart';
import 'new_browser_install_notifier.dart';
import 'unprotected_browser_kill_guard_prefs.dart';

/// 모든 브라우저가 kill 대상일 때 설치·복구가 막히지 않도록 하는 안전망.
final class BrowserInstallSafetyService {
  BrowserInstallSafetyService._();
  static final BrowserInstallSafetyService instance =
      BrowserInstallSafetyService._();

  static const String _kGraceUntilKey = 'browser_install_grace_until_v1';
  static const String _kLockdownGraceKey = 'browser_lockdown_grace_until_v1';
  static const String _kGraceReasonKey = 'browser_install_grace_reason_v1';

  static const Duration kUserInstallGrace = Duration(minutes: 45);
  static const Duration kNovelBrowserGrace = Duration(minutes: 25);
  static const Duration kLockdownAutoGrace = Duration(minutes: 60);

  final Set<String> _novelApplying = <String>{};
  BrowserLockdownSnapshot? _lockdown;
  Timer? _evalTimer;
  bool _running = false;

  BrowserLockdownSnapshot? get lockdown => _lockdown;

  void start() {
    if (!Platform.isWindows || _running) return;
    _running = true;
    unawaited(_evaluate(reason: 'boot'));
    _evalTimer?.cancel();
    _evalTimer = Timer.periodic(const Duration(minutes: 3), (_) {
      unawaited(_evaluate(reason: 'periodic'));
    });
  }

  void stop() {
    _running = false;
    _evalTimer?.cancel();
    _evalTimer = null;
  }

  Future<bool> shouldPauseAllKills() async {
    if (!Platform.isWindows) return false;
    if (await _isGraceActive()) return true;
    if (await _isLockdownGraceActive()) return true;
    if (_novelApplying.isNotEmpty) return true;
    return false;
  }

  Future<bool> shouldSkipKillForBrowser(String browserId) async {
    if (await shouldPauseAllKills()) return true;
    return _novelApplying.contains(browserId);
  }

  /// 유저가 「브라우저 설치 허용」을 눌렀을 때.
  Future<void> beginUserInstallGrace() async {
    await _setGraceUntil(
      DateTime.now().add(kUserInstallGrace),
      reason: 'user_install_allow',
    );
    AppLogger.instance.info('browser_install_safety: user install grace ON');
  }

  Future<Duration?> remainingGrace() async {
    final DateTime? until = await _readGraceUntil();
    if (until == null) return null;
    final Duration left = until.difference(DateTime.now());
    if (left.isNegative) return null;
    return left;
  }

  Future<void> onNovelDetected({
    required String browserId,
    required String displayName,
  }) async {
    _novelApplying.add(browserId);
    await _setGraceUntil(
      DateTime.now().add(kNovelBrowserGrace),
      reason: 'novel_$browserId',
    );
    NewBrowserInstallNotifier.instance.report(
      NewBrowserInstallEvent(
        browserId: browserId,
        displayName: displayName,
        phase: NewBrowserInstallPhase.detected,
        messageKo:
            '$displayName(이)가 새로 설치되었습니다.\n'
            '곧 플러그인·URL 차단 적용을 자동으로 시작합니다…',
        at: DateTime.now(),
      ),
    );
  }

  Future<void> onNovelApplying({
    required String browserId,
    required String displayName,
  }) async {
    NewBrowserInstallNotifier.instance.report(
      NewBrowserInstallEvent(
        browserId: browserId,
        displayName: displayName,
        phase: NewBrowserInstallPhase.applying,
        messageKo:
            '$displayName — 플러그인·차단 목록을 받아 적용 중입니다.\n'
            '잠시만 기다려 주세요 (브라우저 강제 종료 일시 중지).',
        at: DateTime.now(),
      ),
    );
  }

  Future<void> onNovelApplyDone({
    required String browserId,
    required String displayName,
    required bool ok,
  }) async {
    _novelApplying.remove(browserId);
    NewBrowserInstallNotifier.instance.report(
      NewBrowserInstallEvent(
        browserId: browserId,
        displayName: displayName,
        phase: ok ? NewBrowserInstallPhase.done : NewBrowserInstallPhase.failed,
        messageKo: ok
            ? '$displayName — 자동 적용 완료. 브라우저를 완전히 닫았다가 다시 열어주세요.'
            : '$displayName — 일부만 적용됐습니다. 「원탭 차단 적용」을 실행하세요.',
        at: DateTime.now(),
      ),
    );
  }

  Future<void> _evaluate({required String reason}) async {
    if (!Platform.isWindows) return;
    if (!await UnprotectedBrowserKillGuardPrefs.instance.enabled()) {
      _lockdown = null;
      return;
    }

    BrowserBlockHealthReport? report =
        BrowserBlockHealthMonitorService.instance.latest;
    if (report == null ||
        DateTime.now().difference(report.checkedAt) > const Duration(minutes: 5)) {
      report = await BrowserBlockHealthMonitorService.instance.probe(
        reason: 'install_safety_$reason',
      );
    }

    final List<BrowserHealth> installed =
        report.browsers.where((BrowserHealth b) => b.installed).toList();
    if (installed.isEmpty) {
      _lockdown = null;
      return;
    }

    final bool anyProtected =
        installed.any((BrowserHealth b) => b.blockActive);
    if (anyProtected) {
      _lockdown = null;
      return;
    }

    if (!await _isLockdownGraceActive()) {
      await _setLockdownGraceUntil(DateTime.now().add(kLockdownAutoGrace));
    }

    _lockdown = BrowserLockdownSnapshot(
      installedCount: installed.length,
      graceUntil: await _readLockdownGraceUntil(),
      messageKo:
          '설치된 브라우저 ${installed.length}개 모두 URL 차단이 꺼져 있습니다.\n'
          '새 브라우저 설치·다운로드를 위해 ${kLockdownAutoGrace.inMinutes}분간 '
          '브라우저 강제 종료를 멈춥니다.',
    );
  }

  Future<void> _setGraceUntil(DateTime until, {required String reason}) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kGraceUntilKey, until.toUtc().toIso8601String());
    await prefs.setString(_kGraceReasonKey, reason);
  }

  Future<void> _setLockdownGraceUntil(DateTime until) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLockdownGraceKey, until.toUtc().toIso8601String());
  }

  Future<DateTime?> _readGraceUntil() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_kGraceUntilKey);
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  Future<DateTime?> _readLockdownGraceUntil() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_kLockdownGraceKey);
    if (raw == null) return null;
    return DateTime.tryParse(raw);
  }

  Future<bool> _isGraceActive() async {
    final DateTime? until = await _readGraceUntil();
    return until != null && DateTime.now().isBefore(until);
  }

  Future<bool> _isLockdownGraceActive() async {
    final DateTime? until = await _readLockdownGraceUntil();
    return until != null && DateTime.now().isBefore(until);
  }

  static String? installUrlFor(String browserId) {
    return BrowserCatalogEntry.forId(browserId)?.installUrl;
  }
}

final class BrowserLockdownSnapshot {
  const BrowserLockdownSnapshot({
    required this.installedCount,
    required this.graceUntil,
    required this.messageKo,
  });

  final int installedCount;
  final DateTime? graceUntil;
  final String messageKo;
}
