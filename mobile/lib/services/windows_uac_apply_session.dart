import 'dart:async';

import 'app_logger.dart';

/// Tracks the in-flight UAC / elevated PowerShell launcher so the UI can
/// cancel or time out instead of hanging forever.
final class WindowsUacApplySession {
  WindowsUacApplySession._();
  static final WindowsUacApplySession instance = WindowsUacApplySession._();

  /// Max wait for user to approve UAC + elevated script (Dnscache stop can be slow).
  static const Duration kDefaultTimeout = Duration(minutes: 4);

  int? _launcherPid;
  void Function()? _killLauncher;
  bool _cancelRequested = false;

  bool get isActive => _launcherPid != null;
  bool get cancelRequested => _cancelRequested;

  void registerLauncher({required int pid, required void Function() kill}) {
    _launcherPid = pid;
    _killLauncher = kill;
    _cancelRequested = false;
  }

  void unregister() {
    _launcherPid = null;
    _killLauncher = null;
  }

  /// New apply dialog session — clears stale cancel from a prior run.
  void resetSession() {
    _cancelRequested = false;
    unregister();
  }

  /// UI 「취소」 or dialog dismissed while apply is running.
  Future<void> requestCancel() async {
    _cancelRequested = true;
    await _killLauncherProcess();
  }

  Future<void> _killLauncherProcess() async {
    final int? pid = _launcherPid;
    final void Function()? kill = _killLauncher;
    _launcherPid = null;
    _killLauncher = null;
    if (pid == null) return;
    try {
      kill?.call();
      AppLogger.instance.warn('windows UAC: launcher cancelled (pid=$pid)');
    } catch (e) {
      AppLogger.instance.warn('windows UAC: kill launcher failed: $e');
    }
  }

  /// Runs [waitExit] but enforces [timeout] and honours [requestCancel].
  Future<int> waitForExit({
    required Future<int> Function() waitExit,
    Duration timeout = kDefaultTimeout,
  }) async {
    _cancelRequested = false;
    try {
      return await waitExit().timeout(
        timeout,
        onTimeout: () async {
          AppLogger.instance.warn('windows UAC: timed out after ${timeout.inSeconds}s');
          await requestCancel();
          return -2;
        },
      );
    } catch (e) {
      if (_cancelRequested) return -3;
      rethrow;
    }
  }

  int interpretExitCode(int code) {
    if (_cancelRequested || code == -3) return -3;
    if (code == -2) return -2;
    return code;
  }
}
