import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'package:path/path.dart' as p;

import '../models/block_app.dart';
import 'windows_hidden_process.dart';

/// One running process row.
final class RunningProcessInfo {
  const RunningProcessInfo({
    required this.exeName,
    required this.pid,
    required this.windowTitle,
    this.commandLine,
    this.chromeAppId,
    this.executablePath,
  });

  final String exeName;
  final int pid;
  final String windowTitle;

  /// Full path to the image on disk when available (picker accuracy).
  final String? executablePath;

  /// Full process command line. Only populated for processes we explicitly
  /// enriched (currently: Chromium-based browsers), since `Get-CimInstance
  /// Win32_Process` is expensive across the whole system.
  final String? commandLine;

  /// Parsed `--app-id=<hash>` from [commandLine], if any. `null` for the
  /// main browser process or for non-browser processes.
  final String? chromeAppId;

  bool get hasWindow => windowTitle.isNotEmpty && windowTitle != 'N/A';

  bool get isChromiumBrowser => BlockApp.browserExes.contains(exeName);

  /// True if this row is a Chrome-installed app (PWA), not the main browser.
  bool get isChromePwa =>
      isChromiumBrowser && chromeAppId != null && chromeAppId!.isNotEmpty;

  /// Stable identity for de-dup in the picker. For PWAs, the app-id makes
  /// each Chrome app a separate row; for everything else, the exe name does.
  String get groupKey => isChromePwa ? '$exeName?app-id=$chromeAppId' : exeName;

  String get displayLabel => hasWindow ? windowTitle : exeName;
}

/// Lists running processes on Windows.
///
/// Speed strategy:
///   - "with window" mode (default) uses PowerShell `Get-Process` filtered by
///     `MainWindowHandle != 0` — typically <1s, vs `tasklist /v` which can
///     take 2-5s.
///   - "all processes" mode falls back to `tasklist /fo csv /nh` (no /v),
///     which is near-instant.
///   - Results are cached in-memory for [_cacheTtl]; the screen renders the
///     stale list immediately while a refresh runs in the background.
class WindowsProcessLister {
  WindowsProcessLister._();

  static final WindowsProcessLister instance = WindowsProcessLister._();

  static const Duration _cacheTtl = Duration(seconds: 30);

  static String _psExe() {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return p.join(
      windir,
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
  }

  static String _cmdExe() {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return p.join(windir, 'System32', 'cmd.exe');
  }

  // Per-mode cache.
  List<RunningProcessInfo>? _withWindowCache;
  DateTime? _withWindowCacheAt;
  List<RunningProcessInfo>? _allCache;
  DateTime? _allCacheAt;

  // Coalesce concurrent calls so we don't spawn duplicate child processes.
  Future<List<RunningProcessInfo>>? _inflightWithWindow;
  Future<List<RunningProcessInfo>>? _inflightAll;

  /// Returns the cached list immediately if fresh; otherwise fetches.
  Future<List<RunningProcessInfo>> list({bool onlyWithWindow = true}) {
    final List<RunningProcessInfo>? cached =
        onlyWithWindow ? _withWindowCache : _allCache;
    final DateTime? at = onlyWithWindow ? _withWindowCacheAt : _allCacheAt;
    final bool fresh = cached != null &&
        at != null &&
        DateTime.now().difference(at) < _cacheTtl;
    if (fresh) {
      return Future<List<RunningProcessInfo>>.value(cached);
    }
    return _refresh(onlyWithWindow: onlyWithWindow);
  }

  /// Returns the cached list synchronously (or empty), good for "show
  /// instantly" patterns. Call [refreshAsync] right after.
  List<RunningProcessInfo> peekCached({bool onlyWithWindow = true}) {
    final List<RunningProcessInfo>? cached =
        onlyWithWindow ? _withWindowCache : _allCache;
    return cached ?? const <RunningProcessInfo>[];
  }

  /// Force a refresh. Coalesced — duplicate concurrent calls share one fetch.
  Future<List<RunningProcessInfo>> refreshAsync({bool onlyWithWindow = true}) {
    return _refresh(onlyWithWindow: onlyWithWindow);
  }

  Future<List<RunningProcessInfo>> _refresh({required bool onlyWithWindow}) {
    if (onlyWithWindow) {
      return _inflightWithWindow ??= _doFetchWithWindow().whenComplete(() {
        _inflightWithWindow = null;
      });
    } else {
      return _inflightAll ??= _doFetchAll().whenComplete(() {
        _inflightAll = null;
      });
    }
  }

  Future<List<RunningProcessInfo>> _doFetchWithWindow() async {
    if (!Platform.isWindows) return const <RunningProcessInfo>[];
    try {
      return await _doFetchWithWindowInner().timeout(
        const Duration(seconds: 10),
        onTimeout: () => _coerceCache(_withWindowCache),
      );
    } catch (e, st) {
      if (kDebugMode) debugPrint('Get-Process w/window failed: $e\n$st');
      return _coerceCache(_withWindowCache);
    }
  }

  Future<List<RunningProcessInfo>> _doFetchWithWindowInner() async {
    try {
      // CRITICAL: force the PowerShell child to emit UTF-8 on stdout.
      // Without this, MainWindowTitle for non-ASCII apps (Korean, Japanese,
      // emoji, etc.) gets transcoded through the legacy OEM/ANSI code page
      // and arrives at us as a stream of `?` characters.
      const String preamble =
          "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; "
          "\$OutputEncoding = [System.Text.Encoding]::UTF8; "
          "\$ProgressPreference = 'SilentlyContinue'; ";
      const String pipeline =
          "Get-Process | Where-Object { \$_.MainWindowHandle -ne 0 -and \$_.MainWindowTitle.Length -gt 0 } | "
          "Select-Object Id,ProcessName,MainWindowTitle,@{N='Path';E={\$_.Path}} | ConvertTo-Json -Compress -Depth 3";

      final ProcessResult res = await windowsRunHidden(
        _psExe(),
        <String>[
          '-NoProfile',
          '-NoLogo',
          '-WindowStyle',
          'Hidden',
          '-Command',
          preamble + pipeline,
        ],
      );
      if (res.exitCode != 0) {
        return _coerceCache(_withWindowCache);
      }
      final String stdout = (res.stdout ?? '').toString().trim();
      final List<RunningProcessInfo> parsed = _parsePowershellJson(stdout);

      // Enrich Chromium-based browser entries with their CommandLine so we
      // can split the main browser from each installed PWA / Chrome app.
      List<RunningProcessInfo> enriched = parsed;
      try {
        enriched = await _enrichBrowsers(parsed).timeout(
          const Duration(seconds: 4),
          onTimeout: () => parsed,
        );
      } catch (_) {
        enriched = parsed;
      }

      List<RunningProcessInfo> merged = enriched;
      try {
        merged = _mergeGameBackgroundProcesses(
          enriched,
          await _fetchGameBackgroundRows().timeout(
            const Duration(seconds: 3),
            onTimeout: () => const <RunningProcessInfo>[],
          ),
        );
      } catch (_) {
        merged = enriched;
      }
      _withWindowCache = merged;
      _withWindowCacheAt = DateTime.now();
      return merged;
    } catch (e, st) {
      if (kDebugMode) debugPrint('Get-Process w/window inner failed: $e\n$st');
      return _coerceCache(_withWindowCache);
    }
  }

  Future<List<RunningProcessInfo>> _doFetchAll() async {
    if (!Platform.isWindows) return const <RunningProcessInfo>[];
    try {
      return await _doFetchAllInner().timeout(
        const Duration(seconds: 8),
        onTimeout: () => _coerceCache(_allCache),
      );
    } catch (e, st) {
      if (kDebugMode) debugPrint('tasklist failed: $e\n$st');
      return _coerceCache(_allCache);
    }
  }

  Future<List<RunningProcessInfo>> _doFetchAllInner() async {
    try {
      // Wrap tasklist with `chcp 65001` so its output is UTF-8 — same
      // reasoning as _doFetchWithWindow above. ProcessName-only mode here
      // (no `/v`) still benefits because some user-installed exes have
      // Unicode image names.
      final ProcessResult res = await windowsRunHidden(
        _cmdExe(),
        <String>[
          '/d',
          '/c',
          'chcp 65001 >nul && tasklist /fo csv /nh',
        ],
      );
      if (res.exitCode != 0) {
        return _coerceCache(_allCache);
      }
      final String stdout = (res.stdout ?? '').toString();
      final List<RunningProcessInfo> rows = _parseTasklistCsv(stdout);
      final List<RunningProcessInfo> enriched = await _enrichPaths(rows);
      final List<RunningProcessInfo> filtered = _filterBackgroundNoise(enriched);
      _allCache = filtered;
      _allCacheAt = DateTime.now();
      return filtered;
    } catch (e, st) {
      if (kDebugMode) debugPrint('tasklist inner failed: $e\n$st');
      return _coerceCache(_allCache);
    }
  }

  List<RunningProcessInfo> _coerceCache(List<RunningProcessInfo>? c) =>
      c ?? const <RunningProcessInfo>[];

  /// Looks up the CommandLine for any browser PIDs in [rows] via
  /// `Get-CimInstance Win32_Process` (filtered server-side to a handful of
  /// browser exe names). Then SPLITS each chrome.exe row into one row per
  /// distinct app-id (or "main browser") so the picker can show "YouTube
  /// Music (Chrome 앱)" separately from "Google Chrome".
  Future<List<RunningProcessInfo>> _enrichBrowsers(List<RunningProcessInfo> rows) async {
    final List<int> browserPids = <int>[
      for (final RunningProcessInfo r in rows)
        if (r.isChromiumBrowser && r.pid > 0) r.pid,
    ];
    if (browserPids.isEmpty) return rows;

    final Map<int, String> cmdById = await _fetchBrowserCommandLines();
    if (cmdById.isEmpty) return rows;

    // Find every browser PID (including ones without a window — child
    // processes for renderer/gpu, but also the *parent* of a PWA which may
    // not own the foreground window). We want each unique --app-id to surface
    // even if the picker only shows one window per app.
    final List<RunningProcessInfo> out = <RunningProcessInfo>[];

    // Group existing rows by exe + app-id, picking the most-informative
    // window title.
    final Map<String, RunningProcessInfo> grouped = <String, RunningProcessInfo>{};
    for (final RunningProcessInfo r in rows) {
      if (!r.isChromiumBrowser) {
        out.add(r);
        continue;
      }
      final String? cmd = cmdById[r.pid];
      final String? appId = BlockApp.extractAppId(cmd);
      final RunningProcessInfo enriched = RunningProcessInfo(
        exeName: r.exeName,
        pid: r.pid,
        windowTitle: r.windowTitle,
        commandLine: cmd,
        chromeAppId: appId,
        executablePath: r.executablePath,
      );
      final String key = enriched.groupKey;
      final RunningProcessInfo? existing = grouped[key];
      if (existing == null || existing.windowTitle.isEmpty) {
        grouped[key] = enriched;
      }
    }
    out.addAll(grouped.values);

    out.sort((RunningProcessInfo a, RunningProcessInfo b) {
      final int c = a.displayLabel.toLowerCase().compareTo(b.displayLabel.toLowerCase());
      if (c != 0) return c;
      return a.exeName.compareTo(b.exeName);
    });
    return out;
  }

  /// Returns a map from browser PID → CommandLine. Filters server-side so
  /// the WMI query stays cheap (typically <300ms).
  Future<Map<int, String>> _fetchBrowserCommandLines() async {
    try {
      const String preamble =
          "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; "
          "\$OutputEncoding = [System.Text.Encoding]::UTF8; "
          "\$ProgressPreference = 'SilentlyContinue'; ";
      const String pipeline =
          "Get-CimInstance Win32_Process -Filter \"Name = 'chrome.exe' OR Name = 'msedge.exe' OR Name = 'brave.exe'\" | "
          "Select-Object ProcessId,CommandLine | ConvertTo-Json -Compress -Depth 3";

      final ProcessResult res = await windowsRunHidden(
        _psExe(),
        <String>[
          '-NoProfile',
          '-NoLogo',
          '-WindowStyle',
          'Hidden',
          '-Command',
          preamble + pipeline,
        ],
      );
      if (res.exitCode != 0) return const <int, String>{};
      final String stdout = (res.stdout ?? '').toString().trim();
      if (stdout.isEmpty) return const <int, String>{};

      Object? decoded;
      try {
        decoded = jsonDecode(stdout);
      } catch (_) {
        return const <int, String>{};
      }
      final List<dynamic> rows = <dynamic>[];
      if (decoded is List<dynamic>) {
        rows.addAll(decoded);
      } else if (decoded is Map<String, dynamic>) {
        rows.add(decoded);
      }
      final Map<int, String> out = <int, String>{};
      for (final dynamic row in rows) {
        if (row is! Map<String, dynamic>) continue;
        final int pid = (row['ProcessId'] as num?)?.toInt() ?? 0;
        final String cmd = (row['CommandLine'] as String?) ?? '';
        if (pid > 0) out[pid] = cmd;
      }
      return out;
    } catch (e, st) {
      if (kDebugMode) debugPrint('fetchBrowserCommandLines failed: $e\n$st');
      return const <int, String>{};
    }
  }

  List<RunningProcessInfo> _parsePowershellJson(String stdout) {
    if (stdout.isEmpty) return const <RunningProcessInfo>[];
    Object? decoded;
    try {
      decoded = jsonDecode(stdout);
    } catch (_) {
      return const <RunningProcessInfo>[];
    }
    final List<dynamic> rows = <dynamic>[];
    if (decoded is List<dynamic>) {
      rows.addAll(decoded);
    } else if (decoded is Map<String, dynamic>) {
      rows.add(decoded);
    }

    final List<RunningProcessInfo> out = <RunningProcessInfo>[];
    final Set<String> seen = <String>{};
    for (final dynamic row in rows) {
      if (row is! Map<String, dynamic>) continue;
      final String name = ((row['ProcessName'] as String?) ?? '').trim();
      final int pid = (row['Id'] as num?)?.toInt() ?? 0;
      final String title = ((row['MainWindowTitle'] as String?) ?? '').trim();
      if (name.isEmpty) continue;
      final String exe = '${name.toLowerCase()}.exe';
      final String key = '$exe|$title';
      if (seen.contains(key)) continue;
      seen.add(key);
      final String pathRaw = ((row['Path'] as String?) ?? '').trim();
      out.add(RunningProcessInfo(
        exeName: exe,
        pid: pid,
        windowTitle: title,
        executablePath: pathRaw.isEmpty ? null : pathRaw,
      ));
    }
    out.sort((RunningProcessInfo a, RunningProcessInfo b) {
      final int c = a.displayLabel.toLowerCase().compareTo(b.displayLabel.toLowerCase());
      if (c != 0) return c;
      return a.exeName.compareTo(b.exeName);
    });
    return out;
  }

  List<RunningProcessInfo> _parseTasklistCsv(String stdout) {
    final List<RunningProcessInfo> out = <RunningProcessInfo>[];
    final Set<String> seen = <String>{};
    for (final String line in stdout.split('\n')) {
      final String trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final List<String> cols = _parseCsvLine(trimmed);
      if (cols.length < 2) continue;
      final String image = cols[0].trim();
      final int pid = int.tryParse(cols[1].trim()) ?? 0;
      if (image.isEmpty) continue;
      final String exe = image.toLowerCase();
      if (seen.contains(exe)) continue;
      seen.add(exe);
      out.add(RunningProcessInfo(exeName: exe, pid: pid, windowTitle: ''));
    }
    out.sort((RunningProcessInfo a, RunningProcessInfo b) =>
        a.exeName.compareTo(b.exeName));
    return out;
  }

  /// Game launchers often run without a foreground window — surface them even
  /// when「창이 있는 앱만」is on.
  static const Set<String> _gameBackgroundExes = <String>{
    'battle.net.exe',
    'agent.exe',
    'sc2_x64.exe',
    'steam.exe',
    'steamwebhelper.exe',
    'epicgameslauncher.exe',
    'riotclientservices.exe',
  };

  Future<List<RunningProcessInfo>> _fetchGameBackgroundRows() async {
    try {
      const String preamble =
          "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; "
          "\$OutputEncoding = [System.Text.Encoding]::UTF8; "
          "\$ProgressPreference = 'SilentlyContinue'; ";
      const String pipeline =
          r"$n=@('battle.net','Agent','SC2_x64','steam','EpicGamesLauncher','RiotClientServices'); "
          r'Get-Process -Name $n -ErrorAction SilentlyContinue | '
          r"Select-Object Id,ProcessName,@{N='Path';E={$_.Path}} | "
          r'ConvertTo-Json -Compress -Depth 3';
      final ProcessResult res = await windowsRunHidden(
        _psExe(),
        <String>[
          '-NoProfile',
          '-NoLogo',
          '-WindowStyle',
          'Hidden',
          '-Command',
          preamble + pipeline,
        ],
      );
      if (res.exitCode != 0) return const <RunningProcessInfo>[];
      return _parsePowershellJson((res.stdout ?? '').toString().trim());
    } catch (e, st) {
      if (kDebugMode) debugPrint('fetchGameBackgroundRows failed: $e\n$st');
      return const <RunningProcessInfo>[];
    }
  }

  List<RunningProcessInfo> _mergeGameBackgroundProcesses(
    List<RunningProcessInfo> windowed,
    List<RunningProcessInfo> background,
  ) {
    final Map<String, RunningProcessInfo> byKey = <String, RunningProcessInfo>{
      for (final RunningProcessInfo r in windowed) r.groupKey: r,
    };
    for (final RunningProcessInfo extra in background) {
      if (!_gameBackgroundExes.contains(extra.exeName)) continue;
      byKey.putIfAbsent(extra.groupKey, () => extra);
    }
    final List<RunningProcessInfo> out = byKey.values.toList();
    out.sort((RunningProcessInfo a, RunningProcessInfo b) {
      final int c =
          a.displayLabel.toLowerCase().compareTo(b.displayLabel.toLowerCase());
      if (c != 0) return c;
      return a.exeName.compareTo(b.exeName);
    });
    return out;
  }

  Future<List<RunningProcessInfo>> _enrichPaths(
    List<RunningProcessInfo> rows,
  ) async {
    if (rows.isEmpty) return rows;
    final Map<String, String> pathByExe = await _fetchPathsForExes(
      rows.map((RunningProcessInfo r) => r.exeName).toSet(),
    );
    if (pathByExe.isEmpty) return rows;
    return <RunningProcessInfo>[
      for (final RunningProcessInfo r in rows)
        RunningProcessInfo(
          exeName: r.exeName,
          pid: r.pid,
          windowTitle: r.windowTitle,
          commandLine: r.commandLine,
          chromeAppId: r.chromeAppId,
          executablePath: r.executablePath ?? pathByExe[r.exeName],
        ),
    ];
  }

  Future<Map<String, String>> _fetchPathsForExes(Set<String> exes) async {
    if (exes.isEmpty) return const <String, String>{};
    final String names = exes
        .map((String e) => e.replaceAll("'", "''"))
        .map((String e) => "'$e'")
        .join(',');
    try {
      const String preamble =
          "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8; "
          "\$OutputEncoding = [System.Text.Encoding]::UTF8; "
          "\$ProgressPreference = 'SilentlyContinue'; ";
      final String pipeline =
          'Get-Process -ErrorAction SilentlyContinue | '
          "Where-Object { \$names -contains \$_.ProcessName.ToLower() + '.exe' } | "
          'Select-Object @{N=\'Exe\';E={\$_.ProcessName.ToLower() + \'.exe\'}},Path | '
          'ConvertTo-Json -Compress -Depth 3';
      final ProcessResult res = await windowsRunHidden(
        _psExe(),
        <String>[
          '-NoProfile',
          '-NoLogo',
          '-WindowStyle',
          'Hidden',
          '-Command',
          "$preamble\$names=@($names); $pipeline",
        ],
      );
      if (res.exitCode != 0) return const <String, String>{};
      final String stdout = (res.stdout ?? '').toString().trim();
      if (stdout.isEmpty) return const <String, String>{};
      Object? decoded;
      try {
        decoded = jsonDecode(stdout);
      } catch (_) {
        return const <String, String>{};
      }
      final List<dynamic> list = <dynamic>[];
      if (decoded is List<dynamic>) {
        list.addAll(decoded);
      } else if (decoded is Map<String, dynamic>) {
        list.add(decoded);
      }
      final Map<String, String> out = <String, String>{};
      for (final dynamic row in list) {
        if (row is! Map<String, dynamic>) continue;
        final String exe = ((row['Exe'] as String?) ?? '').trim().toLowerCase();
        final String path = ((row['Path'] as String?) ?? '').trim();
        if (exe.isEmpty || path.isEmpty) continue;
        out.putIfAbsent(exe, () => path);
      }
      return out;
    } catch (e, st) {
      if (kDebugMode) debugPrint('fetchPathsForExes failed: $e\n$st');
      return const <String, String>{};
    }
  }

  List<RunningProcessInfo> _filterBackgroundNoise(List<RunningProcessInfo> rows) {
    const Set<String> noise = <String>{
      'svchost.exe',
      'runtimebroker.exe',
      'dllhost.exe',
      'conhost.exe',
      'sihost.exe',
      'searchhost.exe',
      'system.exe',
      'registry.exe',
      'smss.exe',
      'csrss.exe',
      'wininit.exe',
      'services.exe',
      'lsass.exe',
      'fontdrvhost.exe',
      'dwm.exe',
      'explorer.exe',
    };
    return rows.where((RunningProcessInfo r) {
      if (noise.contains(r.exeName)) return false;
      if (r.hasWindow) return true;
      if (_gameBackgroundExes.contains(r.exeName)) return true;
      final String path = r.executablePath?.toLowerCase() ?? '';
      if (path.contains(r'program files') ||
          path.contains(r'program files (x86)') ||
          path.contains(r'appdata\local') ||
          path.contains(r'appdata\roaming')) {
        return true;
      }
      return false;
    }).toList();
  }

  static List<String> _parseCsvLine(String line) {
    final List<String> out = <String>[];
    final StringBuffer buf = StringBuffer();
    bool inQuotes = false;
    for (int i = 0; i < line.length; i++) {
      final String c = line[i];
      if (c == '"') {
        if (inQuotes && i + 1 < line.length && line[i + 1] == '"') {
          buf.write('"');
          i++;
        } else {
          inQuotes = !inQuotes;
        }
      } else if (c == ',' && !inQuotes) {
        out.add(buf.toString());
        buf.clear();
      } else {
        buf.write(c);
      }
    }
    out.add(buf.toString());
    return out;
  }
}
