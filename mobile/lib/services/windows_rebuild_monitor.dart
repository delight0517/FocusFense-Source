import 'dart:async';
import 'dart:io' show exit, Platform;

import 'package:flutter/foundation.dart';

import '../models/windows_rebuild_status.dart';
import 'rebuild_phase_guide.dart';
import 'windows_desktop_rebuild_service.dart';

/// Polls `rebuild_status.json` while an in-app Windows rebuild runs.
final class WindowsRebuildMonitor extends ChangeNotifier {
  WindowsRebuildMonitor._();
  static final WindowsRebuildMonitor instance = WindowsRebuildMonitor._();

  Timer? _pollTimer;
  Timer? _selfHealTimer;
  bool _active = false;
  bool _exitScheduled = false;
  WindowsRebuildStatus? _last;
  List<String> _consoleTail = const <String>[];
  int? _externalPid;
  int _stallPolls = 0;
  DateTime? _startedAt;
  DateTime? _sessionStartedAt;
  bool _sawSessionBoot = false;
  bool _sawLiveExternalPid = false;
  bool _resumedFromBoot = false;
  DateTime? _lastUiNotifyAt;
  DateTime? _lastProgressAt;
  DateTime? _lastHeartbeatAt;

  static const Duration _stallTimeout = Duration(seconds: 90);
  static const Duration _heartbeatInterval = Duration(seconds: 8);

  bool get isActive => _active;
  int? get externalPid => _externalPid;
  WindowsRebuildStatus? get status => _last;
  List<String> get consoleTail => _consoleTail;

  String get displayMessage {
    final GuideCopy g = phaseGuide;
    if (_last?.message.isNotEmpty == true) return _last!.message;
    return g.detail;
  }

  double? get displayProgress => _last?.progress;

  int get elapsedSeconds {
    final DateTime? t = _startedAt;
    if (t == null) return 0;
    return DateTime.now().difference(t).inSeconds;
  }

  GuideCopy get phaseGuide => RebuildPhaseGuide.forPhase(
        _last?.phase ?? 'starting',
        elapsedSec: elapsedSeconds,
        statusMessage: _last?.message,
      );

  /// On boot: attach to an in-flight external rebuild, or clear stale status.
  Future<void> resumeIfNeeded() async {
    if (!Platform.isWindows || _active) return;

    final List<String> tail =
        await WindowsDesktopRebuildService.readConsoleLogTail(maxLines: 50);
    final int? pid = await WindowsDesktopRebuildService.readExternalRebuildPid();
    final bool pidAlive =
        pid != null && await WindowsDesktopRebuildService.isProcessAlive(pid);

    if (WindowsDesktopRebuildService.consoleTailIndicatesSuccess(tail) &&
        !pidAlive) {
      await WindowsDesktopRebuildService.clearStaleRebuildArtifactsIfComplete();
      return;
    }

    final WindowsRebuildStatus? st =
        await WindowsDesktopRebuildService.readRebuildStatus();
    if (st != null && (st.isDone || st.isFailed)) {
      await clearStatusFile();
      await WindowsDesktopRebuildService.clearExternalRebuildPid();
      await WindowsDesktopRebuildService.clearRebuildSession();
      return;
    }

    final bool looksInFlight = st != null &&
        <String>{
          'starting',
          'pub_get',
          'pre_exit',
          'building',
          'installing',
          'relaunching',
        }.contains(st.phase);

    // Stale installing/relaunching JSON while the builder already finished.
    if (looksInFlight &&
        WindowsDesktopRebuildService.consoleTailIndicatesSuccess(tail) &&
        !pidAlive) {
      await WindowsDesktopRebuildService.clearStaleRebuildArtifactsIfComplete();
      return;
    }

    if (pidAlive || looksInFlight) {
      begin(resume: true);
    }
  }

  /// Begin polling after [WindowsDesktopRebuildService.launchRebuildPipeline].
  ///
  /// When [sessionPrepared] is true, the caller already ran
  /// [WindowsDesktopRebuildService.prepareNewInAppRebuildSession] and passed
  /// [sessionStartedAt] so stale console tails cannot close the app instantly.
  void begin({
    bool resume = false,
    bool sessionPrepared = false,
    DateTime? sessionStartedAt,
  }) {
    if (!Platform.isWindows) return;
    _active = true;
    _exitScheduled = false;
    _resumedFromBoot = resume;
    if (!resume) {
      _consoleTail = const <String>[];
      _last = const WindowsRebuildStatus(
        phase: 'starting',
        message: '① 준비 — 소스 폴더와 Flutter를 확인합니다 (약 10초)',
        progress: 0.05,
      );
      _externalPid = null;
      _stallPolls = 0;
      _startedAt = sessionStartedAt ?? DateTime.now();
      _sessionStartedAt = _startedAt;
      _sawSessionBoot = sessionPrepared;
      _sawLiveExternalPid = false;
      if (!sessionPrepared) {
        unawaited(_prepareNewSessionArtifacts());
      }
    } else {
      _startedAt ??= DateTime.now();
      _sessionStartedAt = sessionStartedAt;
      unawaited(_loadResumeSession());
    }
    _lastProgressAt = DateTime.now();
    _lastUiNotifyAt = null;
    _lastHeartbeatAt = null;
    notifyListeners();
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(milliseconds: 750), (_) {
      unawaited(_pollOnce());
    });
    _selfHealTimer?.cancel();
    _selfHealTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      unawaited(_selfHealTick());
    });
    unawaited(_pollOnce());
  }

  Future<void> _prepareNewSessionArtifacts() async {
    final DateTime t =
        await WindowsDesktopRebuildService.prepareNewInAppRebuildSession();
    _sessionStartedAt = t;
    _sawSessionBoot = true;
  }

  Future<void> _loadResumeSession() async {
    _sessionStartedAt =
        await WindowsDesktopRebuildService.readRebuildSessionStartedAt() ??
            _startedAt;
  }

  void cancel() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _selfHealTimer?.cancel();
    _selfHealTimer = null;
    _active = false;
    _exitScheduled = false;
    _last = null;
    _consoleTail = const <String>[];
    _startedAt = null;
    _sessionStartedAt = null;
    _sawSessionBoot = false;
    _sawLiveExternalPid = false;
    _resumedFromBoot = false;
    _lastProgressAt = null;
    _lastUiNotifyAt = null;
    _lastHeartbeatAt = null;
    notifyListeners();
  }

  Future<void> _pollOnce() async {
    if (!_active) return;

    WindowsRebuildStatus? next =
        await WindowsDesktopRebuildService.readRebuildStatus();
    if (!WindowsDesktopRebuildService.statusBelongsToSession(
      next,
      _sessionStartedAt,
    )) {
      next = null;
    }

    final int? filePid =
        await WindowsDesktopRebuildService.readExternalRebuildPid();
    if (filePid != null) {
      if (_externalPid == null || _externalPid != filePid) {
        _externalPid = filePid;
      }
      if (await WindowsDesktopRebuildService.isProcessAlive(filePid)) {
        _sawLiveExternalPid = true;
      }
    }

    final List<String> tail =
        await WindowsDesktopRebuildService.readConsoleLogTail(maxLines: 60);
    _noteSessionBoot(tail);
    final WindowsRebuildStatus? inferred =
        _sawSessionBoot
            ? WindowsDesktopRebuildService.inferStatusFromConsoleTail(tail)
            : null;
    next = _mergeStatus(next, inferred);

    bool dirty = false;
    if (next != null && next != _last) {
      _last = next;
      dirty = true;
    }

    List<String> displayTail = tail;
    if (displayTail.isEmpty) {
      final List<String> launcher =
          await WindowsDesktopRebuildService.readExternalLauncherLogTail();
      if (launcher.isNotEmpty) {
        displayTail = <String>[
          '─ 외부 런처 ─',
          ...launcher,
          '─ 빌드 로그 대기 중… ─',
        ];
      }
    } else if (_externalPid != null &&
        !displayTail.any((String l) => l.startsWith('─ 외부 PID'))) {
      displayTail = <String>[
        '─ 외부 PID $_externalPid · 로그 동기화 중 ─',
        ...displayTail,
      ];
    }

    if (displayTail.isEmpty) {
      _stallPolls++;
      if (_stallPolls > 30 && _last?.phase == 'starting') {
        _last = WindowsRebuildStatus(
          phase: 'starting',
          message:
              '로그가 아직 없습니다. AV가 PowerShell을 막았을 수 있습니다. '
              '설정 → Windows 개발 빌드의 터미널 명령으로 수동 빌드하세요.',
          progress: _last?.progress ?? 0.06,
        );
        dirty = true;
      }
    } else {
      _stallPolls = 0;
    }

    if (!_listsEqual(displayTail, _consoleTail)) {
      _consoleTail = displayTail;
      dirty = true;
    }

    if (dirty) {
      final DateTime now = DateTime.now();
      _lastProgressAt = now;
      _notifyThrottled();
    }

    // Console completion self-heal — only after THIS session's boot marker.
    if (WindowsDesktopRebuildService.consoleTailIndicatesSuccessForSession(
      displayTail,
      sessionStartedAt: _sessionStartedAt,
    )) {
      final bool alive = await _externalBuilderAlive();
      if (!alive) {
        await _finishSuccess(exitCode: 0, fromConsole: true);
        return;
      }
    }
    if (WindowsDesktopRebuildService.consoleTailIndicatesFailureForSession(
      displayTail,
      sessionStartedAt: _sessionStartedAt,
    )) {
      final bool alive = await _externalBuilderAlive();
      if (!alive) {
        _failAndRecover(
          '빌드가 실패한 것 같습니다. 아래 로그를 확인한 뒤 다시 시도하세요.',
        );
        return;
      }
    }

    if (next?.isFailed == true) {
      _active = false;
      _pollTimer?.cancel();
      _selfHealTimer?.cancel();
      notifyListeners();
      return;
    }

    if (next?.phase == 'done' && (next?.exitCode ?? -1) == 0 && !_exitScheduled) {
      await _finishSuccess(exitCode: 0, fromConsole: false);
      return;
    }

    if (next?.requestAppExit == true &&
        !_exitScheduled &&
        !_resumedFromBoot &&
        WindowsDesktopRebuildService.statusBelongsToSession(
          next,
          _sessionStartedAt,
        )) {
      final String phase = next!.phase;
      if (phase == 'failed') return;
      if (phase != 'pre_exit' &&
          phase != 'installing' &&
          phase != 'relaunching' &&
          phase != 'done') {
        return;
      }
      _exitScheduled = true;
      _last = WindowsRebuildStatus(
        phase: phase,
        message: phase == 'pre_exit'
            ? next.message
            : '빌드 완료! 잠시 후 새 버전을 실행합니다…',
        progress: phase == 'pre_exit' ? next.progress : 0.95,
        requestAppExit: true,
      );
      notifyListeners();
      final int delayMs = phase == 'pre_exit' ? 2200 : 400;
      await Future<void>.delayed(Duration(milliseconds: delayMs));
      if (kDebugMode) {
        // ignore: avoid_print
        print('[RebuildMonitor] exiting (phase=$phase)');
      }
      exit(0);
    }
  }

  WindowsRebuildStatus? _mergeStatus(
    WindowsRebuildStatus? file,
    WindowsRebuildStatus? inferred,
  ) {
    if (file == null) return inferred;
    if (inferred == null) return file;
    if (inferred.isDone || inferred.phase == 'relaunching') return inferred;
    final double fp = file.progress ?? 0;
    final double ip = inferred.progress ?? 0;
    if (ip > fp + 0.02) return inferred;
    if (file.requestAppExit) return file;
    if (file.updatedAt != null && file.updatedAt!.isNotEmpty) {
      const Set<String> stalePhases = <String>{
        'starting',
        'pub_get',
        'installing',
        'building',
      };
      if (stalePhases.contains(file.phase) &&
          (inferred.phase == 'building' ||
              inferred.phase == 'installing' ||
              inferred.phase == 'relaunching')) {
        return inferred;
      }
      return file;
    }
    return inferred.progress != null ? inferred : file;
  }

  Future<void> _finishSuccess({required int exitCode, required bool fromConsole}) async {
    if (_exitScheduled) return;
    _exitScheduled = true;
    await clearStatusFile();
    await WindowsDesktopRebuildService.clearExternalRebuildPid();
    await WindowsDesktopRebuildService.clearRebuildSession();

    // Fresh relaunch after rebuild — do not exit the new process.
    if (_resumedFromBoot) {
      cancel();
      return;
    }

    _active = false;
    _pollTimer?.cancel();
    _selfHealTimer?.cancel();
    _last = WindowsRebuildStatus(
      phase: 'done',
      message: fromConsole
          ? '업데이트 완료 — 새 버전으로 전환합니다…'
          : '최신 버전으로 전환 중… 잠시 후 현재 창을 닫습니다.',
      progress: 1,
      requestAppExit: true,
      exitCode: exitCode,
    );
    notifyListeners();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    exit(0);
  }

  Future<void> _selfHealTick() async {
    if (!_active || _exitScheduled) return;
    final DateTime now = DateTime.now();
    final DateTime? started = _startedAt;
    if (started == null) return;

    _maybeHeartbeat(now, started);

    if (now.difference(started) > const Duration(minutes: 25)) {
      _failAndRecover(
        '빌드 모니터 타임아웃(25분) — 상태를 초기화했습니다.\n'
        '「닫기」를 누르고 다시 시도하거나, 설정 → Windows 개발 빌드에서 '
        '터미널 명령으로 직접 빌드하세요.',
      );
      return;
    }

    final DateTime lastProgress = _lastProgressAt ?? started;
    if (now.difference(lastProgress) > _stallTimeout) {
      final bool alive = await _externalBuilderAlive();
      if (!alive) {
        if (WindowsDesktopRebuildService.consoleTailIndicatesSuccessForSession(
          _consoleTail,
          sessionStartedAt: _sessionStartedAt,
        )) {
          await _finishSuccess(exitCode: 0, fromConsole: true);
          return;
        }
        _failAndRecover(
          '빌드가 멈춘 것 같아요 (${_stallTimeout.inSeconds}초간 진행 없음, 외부 PowerShell도 종료됨).\n'
          '소스 경로에 공백이 있거나 보안 프로그램이 차단했을 수 있습니다. 「닫기」 후 다시 시도하거나 '
          '설정 → Windows 개발 빌드의 터미널 명령으로 직접 빌드하세요.',
        );
        return;
      }
      _lastProgressAt = now.subtract(_stallTimeout ~/ 2);
      _notifyThrottled();
    }
  }

  void _maybeHeartbeat(DateTime now, DateTime started) {
    final DateTime? lastHb = _lastHeartbeatAt;
    if (lastHb != null && now.difference(lastHb) < _heartbeatInterval) return;
    _lastHeartbeatAt = now;

    final int sec = now.difference(started).inSeconds;
    String phase = _last?.phase ?? 'starting';
    if (phase == 'starting' &&
        _consoleTail.any((String l) => l.toLowerCase().contains('flutter build'))) {
      phase = 'building';
    }
    final GuideCopy g = RebuildPhaseGuide.forPhase(
      phase,
      elapsedSec: sec,
      statusMessage: _last?.message,
    );
    final String msg = '${g.step} ${g.title} — ${g.detail}';

    if (_last?.message != msg || _last?.phase != phase) {
      _last = WindowsRebuildStatus(
        phase: phase,
        message: msg,
        progress: _last?.progress,
        requestAppExit: _last?.requestAppExit ?? false,
        exitCode: _last?.exitCode,
      );
      _notifyThrottled();
    } else {
      notifyListeners();
    }
  }

  void _notifyThrottled() {
    final DateTime now = DateTime.now();
    if (_lastUiNotifyAt == null ||
        now.difference(_lastUiNotifyAt!) >= const Duration(milliseconds: 250)) {
      _lastUiNotifyAt = now;
      notifyListeners();
    }
  }

  void _noteSessionBoot(List<String> tail) {
    if (_sawSessionBoot) return;
    if (tail.any(
      (String line) =>
          line.contains('in-app rebuild session') ||
          line.contains('Rebuild-6VPN-Windows.ps1 started') ||
          line.contains('=== 6 VPN Blocker rebuild v'),
    )) {
      _sawSessionBoot = true;
    }
  }

  Future<bool> _externalBuilderAlive() async {
    final int? pid = _externalPid;
    if (pid == null) return true;
    try {
      final bool alive =
          await WindowsDesktopRebuildService.isProcessAlive(pid);
      if (alive) {
        _sawLiveExternalPid = true;
        return true;
      }
      final bool psBooted = _consoleTail.any(
        (String line) => line.contains('Rebuild-6VPN-Windows.ps1 started'),
      );
      if (psBooted) return false;
      final DateTime? started = _startedAt;
      if (started != null &&
          DateTime.now().difference(started) > const Duration(seconds: 18)) {
        return false;
      }
      if (!_sawLiveExternalPid && !_sawSessionBoot) return true;
      return false;
    } catch (_) {
      return true;
    }
  }

  void _failAndRecover(String message) {
    _active = false;
    _exitScheduled = false;
    _pollTimer?.cancel();
    _selfHealTimer?.cancel();
    _last = WindowsRebuildStatus(
      phase: 'failed',
      message: message,
      progress: 0,
    );
    notifyListeners();
  }

  Future<void> clearStatusFile() =>
      WindowsDesktopRebuildService.clearRebuildStatus();

  static bool _listsEqual(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
