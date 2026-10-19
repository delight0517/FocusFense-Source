import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_block_user_notice_service.dart';
import 'app_logger.dart';
import 'default_browser_promoter_service.dart';
import 'own_kill_ledger.dart';
import 'windows_hidden_process.dart';

/// Periodically snapshots running browser PIDs. When a PID we previously saw
/// disappears we cross-check [OwnKillLedger] — if **this app** killed it, the
/// kill site has already surfaced its own notice. If the ledger has nothing,
/// we surface a "외부 원인" (external cause) notice so the user is not left
/// wondering "왜 갑자기 Chrome이 꺼졌지?".
///
/// Cadence chosen per `mobile/CLAUDE.md`'s performance budget:
///   * 30 s tick (the floor for any periodic probe).
///   * 1 child process per tick (tasklist.exe) — well under the 2-process /
///     ≥5 minute escalation threshold.
///   * Skips ticks when `AppLifecycleState != resumed` so the watcher does
///     no work while the user isn't looking.
final class BrowserExitWatcherService {
  BrowserExitWatcherService._();
  static final BrowserExitWatcherService instance =
      BrowserExitWatcherService._();

  // Performance budget — 30 s tick, 1 tasklist.exe per tick, cached
  // per-image display names. See mobile/CLAUDE.md §"ABSOLUTE PERFORMANCE
  // BUDGET". DO NOT speed this up below 30 s without revising that doc.
  //
  // We INTENTIONALLY do not gate the tick on AppLifecycleState — this is
  // a tray app and most of the time the user has the main window hidden.
  // Pausing the watcher when the window is hidden would defeat the whole
  // point ("Chrome disappeared while I was reading and I have no idea why").
  // 1 tasklist.exe / 30 s is well under the performance budget either way.
  static const Duration _tickInterval = Duration(seconds: 30);

  // Browsers we care about. Image names are matched case-insensitively
  // against tasklist output. Keep this in sync with the kill sites — any
  // executable we might terminate should appear here.
  static const Map<String, String> _watchedImages = <String, String>{
    'chrome.exe': 'Chrome',
    'msedge.exe': 'Edge',
    'brave.exe': 'Brave',
    'whale.exe': 'Whale',
    'firefox.exe': 'Firefox',
    'librewolf.exe': 'LibreWolf',
    'vivaldi.exe': 'Vivaldi',
    'opera.exe': 'Opera',
    'aside.exe': 'Aside',
  };

  static bool watchesImage(String imageName) =>
      _watchedImages.containsKey(imageName.toLowerCase());

  Timer? _timer;
  bool _busy = false;
  bool _started = false;
  Map<int, String> _lastSnapshot = const <int, String>{};

  void start() {
    if (_started) return;
    if (!Platform.isWindows) return;
    _started = true;
    // Note: we used to early-return on SilentBootstrapContext.suppressUserPrompts
    // but that left the baseline empty for the entire bootstrap window
    // (often minutes). The activity-log entry is suppressed-aware in
    // AppBlockUserNoticeService, so we just keep snapshotting.
    unawaited(_primeSnapshot());
    _timer ??= Timer.periodic(_tickInterval, (_) => unawaited(_tick()));
  }

  void stop() {
    if (!_started) return;
    _started = false;
    _timer?.cancel();
    _timer = null;
    _lastSnapshot = const <int, String>{};
  }

  Future<void> _primeSnapshot() async {
    try {
      _lastSnapshot = await _snapshot();
    } catch (_) {}
  }

  Future<void> _tick() async {
    if (!_started || _busy) return;
    _busy = true;
    try {
      final Map<int, String> current = await _snapshot();
      final Map<int, String> previous = _lastSnapshot;
      _lastSnapshot = current;
      if (previous.isEmpty) return;

      final DateTime now = DateTime.now();
      bool firedPromoter = false;
      for (final MapEntry<int, String> ent in previous.entries) {
        final int pid = ent.key;
        final String image = ent.value;
        if (current.containsKey(pid)) continue;
        final bool ours = OwnKillLedger.instance.wasOursRecently(
          pid: pid,
          imageName: image,
        );
        // Whether ours or external, if the OS default browser just died
        // the user is one click away from losing every link they open.
        // Reactive promoter runs at most once per 60 s.
        if (!firedPromoter) {
          firedPromoter = true;
          unawaited(
            DefaultBrowserPromoterService.instance.reactToBrowserKill(
              imageName: image,
              reasonKo: ours ? '브라우저 종료 감지 (앱 차단)' : '브라우저 외부 원인 종료 감지',
            ),
          );
        }
        final String display = _watchedImages[image] ?? image;
        // Universal close-notice source: every browser that disappears gets a
        // popup so the user always knows WHAT closed and WHY.
        if (ours) {
          final OwnKillReason? mine = OwnKillLedger.instance.reasonFor(
            pid: pid,
            imageName: image,
          );
          // windows_app_block already fires its own immediate popup at kill
          // time — don't double-pop those. Other ledger sources (realtime
          // guard migrate, extension reload, …) don't self-notify → surface
          // them here so no close is ever silent.
          if (mine == null) continue;
          if (image == 'aside.exe') {
            // @incident: aside_blocked_main_browser_no_guidance — an app-owned
            // Aside close must tell the user how to switch to a browser that
            // FocusFense currently verifies, instead of leaving the main
            // browsing session stranded without an actionable next step.
            unawaited(
              DefaultBrowserPromoterService.instance
                  .guideAfterBlockedMainBrowser(
                    blockedBrowserName: display,
                    reasonKo: mine.reason,
                  ),
            );
          }
          AppBlockUserNoticeService.instance.notifyBrowserKilledWithReason(
            browserOrAppDisplayName: display,
            reasonKo: mine.reason,
            debounceKey: 'watch_killed_${image}_${mine.reasonKey}',
          );
          AppLogger.instance.info(
            'browser_exit_watcher: ours exit $image pid=$pid — ${mine.reason}',
          );
          continue;
        }
        AppBlockUserNoticeService.instance.notifyExternalBrowserExit(
          browserDisplayName: display,
          pid: pid,
          detectedAt: now,
        );
        AppLogger.instance.info(
          'browser_exit_watcher: external exit $image pid=$pid',
        );
      }
    } catch (e, st) {
      AppLogger.instance.warn('browser_exit_watcher tick failed: $e\n$st');
    } finally {
      _busy = false;
    }
  }

  /// Returns `{pid: imageName(lowercased)}` for every watched browser
  /// currently running. Uses a single `tasklist /FO CSV /NH` call so we
  /// stay under the per-tick subprocess budget.
  Future<Map<int, String>> _snapshot() async {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final String tasklist = p.join(windir, 'System32', 'tasklist.exe');
    final ProcessResult res = await windowsRunHidden(tasklist, const <String>[
      '/FO',
      'CSV',
      '/NH',
    ]);
    if (res.exitCode != 0) return const <int, String>{};
    final String raw = (res.stdout ?? '').toString();
    if (raw.trim().isEmpty) return const <int, String>{};

    final Map<int, String> out = <int, String>{};
    for (final String line in raw.split(RegExp(r'\r?\n'))) {
      if (line.isEmpty) continue;
      // CSV columns: "image","pid","sessionName","sessionNum","memUsage"
      final List<String> cols = _parseCsvRow(line);
      if (cols.length < 2) continue;
      final String image = cols[0].toLowerCase().trim();
      if (!_watchedImages.containsKey(image)) continue;
      final int? pid = int.tryParse(cols[1].trim());
      if (pid == null || pid <= 0) continue;
      out[pid] = image;
    }
    if (out.isEmpty) return out;
    return _foregroundOnly(out);
  }

  // @incident: firefox_background_task_false_block — originally fixed only
  // for Firefox in windows_app_block_service.dart's app-kill path
  // (_foregroundFirefoxPids). 2026-07-06 investigation found the exact same
  // pattern hitting this watcher for every browser: notification_history.jsonl
  // showed Chrome/Brave/Firefox "외부 원인 종료" events firing every 30-60s from
  // constantly-churning PIDs that were never a real foreground window —
  // browser background-update tasks and per-tab/GPU/utility child processes,
  // which `tasklist` can't tell apart from a real launch. Filters them out
  // here too so this watcher's notices (once un-suppressed by the
  // SilentBootstrapContext timeout fix) reflect real window closes only.
  Future<Map<int, String>> _foregroundOnly(Map<int, String> pids) async {
    try {
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final String wmic = p.join(windir, 'System32', 'wbem', 'WMIC.exe');
      if (!await File(wmic).exists()) return pids;
      final String whereClause = _watchedImages.keys
          .map((String exe) => "name='$exe'")
          .join(' or ');
      final ProcessResult res = await windowsRunHidden(wmic, <String>[
        'process',
        'where',
        '($whereClause)',
        'get',
        'ProcessId,CommandLine',
        '/format:list',
      ]);
      if (res.exitCode != 0) return pids;
      final String stdout = (res.stdout ?? '').toString();
      final Map<int, String> cmdByPid = <int, String>{};
      int pid = 0;
      final StringBuffer cmd = StringBuffer();
      void flushBlock() {
        if (pid > 0) cmdByPid[pid] = cmd.toString();
        pid = 0;
        cmd.clear();
      }

      for (final String rawLine in stdout.split(RegExp(r'\r?\n'))) {
        final String line = rawLine.trim();
        if (line.isEmpty) {
          flushBlock();
          continue;
        }
        final int eq = line.indexOf('=');
        if (eq <= 0) continue;
        final String key = line.substring(0, eq).trim();
        final String val = line.substring(eq + 1).trim();
        if (key == 'ProcessId') {
          pid = int.tryParse(val) ?? 0;
        } else if (key == 'CommandLine') {
          cmd.write(val);
        }
      }
      flushBlock();
      final Map<int, String> foreground = <int, String>{};
      pids.forEach((int candidatePid, String image) {
        final String cl = (cmdByPid[candidatePid] ?? '').toLowerCase();
        final bool isBackgroundHelper =
            cl.contains('--backgroundtask') ||
            cl.contains('-contentproc') ||
            cl.contains('--type=') ||
            cl.contains('--headless');
        if (!isBackgroundHelper) {
          foreground[candidatePid] = image;
        }
      });
      return foreground;
    } catch (_) {
      return pids;
    }
  }

  static List<String> _parseCsvRow(String line) {
    final List<String> out = <String>[];
    final StringBuffer buf = StringBuffer();
    bool inQ = false;
    for (int i = 0; i < line.length; i++) {
      final String ch = line[i];
      if (ch == '"') {
        if (inQ && i + 1 < line.length && line[i + 1] == '"') {
          buf.write('"');
          i++;
        } else {
          inQ = !inQ;
        }
      } else if (ch == ',' && !inQ) {
        out.add(buf.toString());
        buf.clear();
      } else {
        buf.write(ch);
      }
    }
    out.add(buf.toString());
    return out;
  }
}
