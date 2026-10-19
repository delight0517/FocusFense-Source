import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/block_app.dart';
import 'app_block_user_notice_service.dart';
import 'app_logger.dart';
import 'block_activity_log_service.dart';
import 'extension_rules_builder.dart';
import 'windows_hidden_process.dart';
import 'windows_process_lister.dart';

/// Layer 4 — monitors browser window titles and closes tabs matching block rules.
///
/// Catches bypass when extension/PAC miss (e.g. unprotected Chrome briefly visible).
/// Tick every [_kTickInterval]; uses cached process list from [WindowsProcessLister].
final class WindowTitleGuardResult {
  const WindowTitleGuardResult({
    required this.active,
    required this.patternCount,
    this.lastClosedTitle = '',
  });

  final bool active;
  final int patternCount;
  final String lastClosedTitle;
}

final class WindowsWindowTitleGuardService {
  WindowsWindowTitleGuardService._();
  static final WindowsWindowTitleGuardService instance =
      WindowsWindowTitleGuardService._();

  // 2026-06-19 perf fix: was 5s → ProcessLister window enum every 5s. Combined
  // with _killPids() already being neutralized (see _killPids comment below),
  // this whole tick is mostly defensive logging. CLAUDE.md rule #1: ≥30s.
  static const Duration _kTickInterval = Duration(seconds: 60);
  static const Duration _kBraveYoutubeFallbackTickInterval = Duration(
    seconds: 4,
  );
  static const Set<String> _browserExes = <String>{
    'chrome.exe',
    'msedge.exe',
    'firefox.exe',
    'brave.exe',
    'vivaldi.exe',
    'opera.exe',
  };

  List<String> _patterns = <String>[];
  Timer? _timer;
  Duration? _timerInterval;
  bool _running = false;
  WindowTitleGuardResult? _lastResult;

  WindowTitleGuardResult? get lastResult => _lastResult;

  static String heartbeatPath() {
    final String? la = Platform.environment['LOCALAPPDATA'];
    return p.join(la ?? '', 'SixVPNBlocker', 'window_title_guard.json');
  }

  /// Rebuild patterns from extension rules + optional [BlockApp] title rows.
  Future<void> syncPatterns({
    ExtensionRulesPayload? rules,
    List<BlockApp> extraApps = const <BlockApp>[],
  }) async {
    if (!Platform.isWindows) return;
    final ExtensionRulesPayload payload =
        rules ?? await ExtensionRulesBuilder.buildForBrowserEnforcement();
    final Set<String> patterns = <String>{};

    for (final String handle in payload.blockedYoutubeHandles) {
      final String h = handle.trim();
      if (h.isEmpty) continue;
      patterns.add('@$h');
      patterns.add(h);
      patterns.add('$h - YouTube');
      try {
        final String decoded = Uri.decodeComponent(h);
        if (decoded != h) {
          patterns.add('@$decoded');
          patterns.add(decoded);
          patterns.add('$decoded - YouTube');
        }
      } catch (_) {}
    }
    for (final String cid in payload.blockedYoutubeChannelIds) {
      final String c = cid.trim();
      if (c.length >= 10) patterns.add('/channel/$c');
    }
    for (final String vid in payload.blockedYoutubeVideoIds) {
      final String v = vid.trim();
      if (v.length >= 6) patterns.add(v);
    }
    if (payload.hasYoutubeChannelBlocks ||
        payload.blockedYoutubeVideoIds.isNotEmpty) {
      // If a Chromium derivative such as Brave has no working extension/policy,
      // this gives the final guard a generic YouTube title match.
      patterns.add(' - YouTube');
      patterns.add('YouTube - Brave');
    }
    for (final String k in payload.keywords) {
      final String s = k.trim();
      if (s.isEmpty) continue;
      final String sl = s.toLowerCase();
      if (sl.contains('youtube') ||
          sl.contains('youtu.be') ||
          sl.startsWith('watch?v=') ||
          sl.startsWith('@') ||
          sl.startsWith('/')) {
        patterns.add(s);
      }
    }
    for (final String d in payload.blockedDomains) {
      final String dom = d.trim().toLowerCase().replaceAll('www.', '');
      if (dom.isNotEmpty) patterns.add(dom);
    }
    for (final dynamic q in payload.searchQueries) {
      if (q is Map) {
        final String term = '${q['term'] ?? ''}'.trim();
        if (term.length >= 2) patterns.add(term);
      } else {
        final String term = '$q'.trim();
        if (term.length >= 2) patterns.add(term);
      }
    }
    for (final BlockApp app in extraApps) {
      final String? t = app.windowTitleMatch?.trim();
      if (t != null && t.isNotEmpty) patterns.add(t);
      if (app.displayName.trim().isNotEmpty) {
        patterns.add(app.displayName.trim());
      }
    }

    _patterns = patterns
        .map((String s) => s.toLowerCase())
        .where((String s) => s.length >= 2)
        .toSet()
        .toList();

    _lastResult = WindowTitleGuardResult(
      active: _patterns.isNotEmpty,
      patternCount: _patterns.length,
    );

    if (_patterns.isEmpty) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    final bool braveYoutubeFallback = _patterns.any(
      (String p) => p.contains('youtube'),
    );
    final Duration interval = braveYoutubeFallback
        ? _kBraveYoutubeFallbackTickInterval
        : _kTickInterval;
    if (_timer == null || _timerInterval != interval) {
      _timer?.cancel();
      _timer = Timer.periodic(interval, (_) => unawaited(_tick()));
      _timerInterval = interval;
    }
    await _writeHeartbeat();
    await _tick();
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _timerInterval = null;
    _patterns = <String>[];
    _lastResult = const WindowTitleGuardResult(active: false, patternCount: 0);
    await _writeHeartbeat();
  }

  Future<void> _writeHeartbeat() async {
    try {
      final File f = File(heartbeatPath());
      await f.parent.create(recursive: true);
      await f.writeAsString(
        jsonEncode(<String, Object?>{
          'active': _patterns.isNotEmpty,
          'patternCount': _patterns.length,
          'tickSeconds': (_timerInterval ?? _kTickInterval).inSeconds,
          'at': DateTime.now().toIso8601String(),
        }),
        flush: true,
      );
    } catch (_) {}
  }

  Future<void> _tick() async {
    if (!Platform.isWindows || _patterns.isEmpty || _running) return;
    _running = true;
    try {
      final List<RunningProcessInfo> procs = await WindowsProcessLister.instance
          .list(onlyWithWindow: true);
      final Set<int> killPids = <int>{};
      final Set<int> braveYoutubePids = <int>{};
      String? matchedTitle;
      String? matchedPattern;

      for (final RunningProcessInfo proc in procs) {
        if (!_browserExes.contains(proc.exeName.toLowerCase())) continue;
        if (!proc.hasWindow) continue;
        final String title = proc.windowTitle.toLowerCase();
        if (title.isEmpty) continue;
        for (final String pat in _patterns) {
          if (title.contains(pat)) {
            killPids.add(proc.pid);
            if (proc.exeName.toLowerCase() == 'brave.exe' &&
                title.contains('youtube')) {
              braveYoutubePids.add(proc.pid);
            }
            matchedTitle = proc.windowTitle;
            matchedPattern = pat;
            break;
          }
        }
      }

      final Set<int> directBraveYoutubePids = await _directBraveYoutubePids();
      if (directBraveYoutubePids.isNotEmpty) {
        killPids.addAll(directBraveYoutubePids);
        braveYoutubePids.addAll(directBraveYoutubePids);
        matchedTitle ??= 'Brave YouTube';
        matchedPattern ??= 'youtube';
      }

      if (killPids.isEmpty) return;

      await _killPids(killPids, braveYoutubePids: braveYoutubePids);
      _lastResult = WindowTitleGuardResult(
        active: true,
        patternCount: _patterns.length,
        lastClosedTitle: matchedTitle ?? '',
      );
      BlockActivityLogService.instance.record(
        kind: BlockActivityKind.blockHit,
        message: '창 제목 차단: ${matchedTitle ?? ""} (패턴: ${matchedPattern ?? ""})',
        level: 'info',
      );
      AppLogger.instance.info(
        'window_title_guard: closed pids=$killPids title=$matchedTitle',
      );
      await _writeHeartbeat();
    } catch (e, st) {
      AppLogger.instance.warn('window_title_guard tick: $e\n$st');
    } finally {
      _running = false;
    }
  }

  Future<void> _killPids(
    Set<int> pids, {
    Set<int> braveYoutubePids = const <int>{},
  }) async {
    // 6 VPN: kill action neutralized per user directive 2026-06-10.
    // Browsers were being force-closed when title matched (e.g. session-restored
    // YouTube tabs containing a blocked channel name). Per-tab close requires
    // the extension layer; killing the whole browser process surprises the user
    // ("chrome 갑자기 꺼짐"). Log-only — extension layer handles tab block.
    //
    // Exception: Brave without a working extension/policy was observed opening
    // YouTube normally. In that fallback case the user's rule is explicit:
    // no plugin/protection means whole YouTube must be blocked.
    if (braveYoutubePids.isNotEmpty) {
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final String taskkill = p.join(windir, 'System32', 'taskkill.exe');
      for (final int pid in braveYoutubePids) {
        await windowsRunHidden(taskkill, <String>[
          '/PID',
          '$pid',
          '/T',
          '/F',
        ]);
      }
      AppBlockUserNoticeService.instance.notifyBrowserKilledWithReason(
        browserOrAppDisplayName: 'Brave',
        reasonKo:
            'Brave 플러그인/정책이 없어 YouTube 전체 차단으로 종료했습니다. 원인 태그: 브라우저 플러그인 · URL 정책 · 시스템 보호',
        debounceKey: 'brave_youtube_fallback_kill',
      );
      AppLogger.instance.info(
        'window_title_guard: brave youtube fallback killed pids=$braveYoutubePids',
      );
    }
    final Set<int> suppressed = pids.difference(braveYoutubePids);
    if (suppressed.isEmpty) return;
    AppLogger.instance.info(
      'window_title_guard: kill suppressed (UX guard) for pids=$suppressed',
    );
  }

  Future<Set<int>> _directBraveYoutubePids() async {
    try {
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final String psExe = p.join(
        windir,
        'System32',
        'WindowsPowerShell',
        'v1.0',
        'powershell.exe',
      );
      const String script = r'''
$rows = Get-Process brave -ErrorAction SilentlyContinue |
  Where-Object { $_.MainWindowTitle -match 'YouTube' } |
  Select-Object -ExpandProperty Id
$rows | ConvertTo-Json -Compress
''';
      final ProcessResult res = await windowsRunHidden(psExe, <String>[
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        script,
      ]);
      if (res.exitCode != 0) return const <int>{};
      final String raw = '${res.stdout}'.trim();
      if (raw.isEmpty || raw == 'null') return const <int>{};
      final Object? parsed = jsonDecode(raw);
      if (parsed is int) return <int>{parsed};
      if (parsed is List) return parsed.whereType<int>().toSet();
    } catch (_) {}
    return const <int>{};
  }
}
