import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/allowed_browser_app_catalog.dart';
import '../models/active_app_block_entry.dart';
import '../models/block_app.dart';
import 'package:path/path.dart' as p;

import 'app_block_user_notice_service.dart';
import 'app_logger.dart';
import 'browser_app_allowlist_service.dart';
import 'block_activity_log_service.dart';
import 'default_browser_promoter_service.dart';
import 'own_kill_ledger.dart';
import 'windows_hidden_process.dart';

/// Windows app terminator: [BlockApp] rows from SQLite drive matching.
///
/// * Non-Chromium exes → `taskkill /F /IM <exe>` (kills all PIDs of that image).
/// * Chromium (`chrome.exe` / `msedge.exe` / `brave.exe`) → one CIM query for
///   command lines, then kill only PIDs whose `--app-id=` matches the rule
///   (or main browser only when [BlockApp.mainBrowserKey]).
/// * Legacy rows (no `win|…` bundle) → [BlockApp] with empty [BlockApp.exeName]
///   and [windowTitleMatch] set → `taskkill /FI WINDOWTITLE …` (substring).
final class WindowsAppBlockService {
  WindowsAppBlockService._();
  static final WindowsAppBlockService instance = WindowsAppBlockService._();

  // 2026-06-19 perf fix: was 2s → tasklist.exe spawned ~N children every 2s
  // (one per plain-block entry). CLAUDE.md rule #2: >2 child processes →
  // ≥5min interval. Settled on 60s at the time because Process.run-per-entry
  // every 2s was the #1 sustained CPU hog.
  //
  // 2026-07-06 fix: the 60s floor meant a blocked game/app could run for up
  // to 60s before detection+kill+notify — user-reported "should pop the
  // moment something is closed, but it takes a while". Root cause was the
  // per-entry tasklist.exe spawn, not the interval itself: batched into a
  // single tasklist call for every plain-block exeName at once (see
  // `_listPidsForAllExes`), so child-process count per tick is now 1
  // regardless of entry count — safely back under the 30s floor.
  static const Duration _tickInterval = Duration(seconds: 30);

  /// WMIC/CIM queries are throttled to avoid subprocess churn.
  static const Duration _browserListMinInterval = Duration(seconds: 45);

  /// Prevent repeated taskkill storms for the same target.
  static const Duration _killCooldown = Duration(seconds: 9);

  static String _taskkillExe() {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return p.join(windir, 'System32', 'taskkill.exe');
  }

  late final Set<String> _alwaysProtected = () {
    final String self = File(
      Platform.resolvedExecutable,
    ).uri.pathSegments.last.toLowerCase();
    return <String>{
      self,
      'FocusFense.exe',
      'explorer.exe',
      'dwm.exe',
      'csrss.exe',
      'winlogon.exe',
      'services.exe',
      'lsass.exe',
      'smss.exe',
      'svchost.exe',
      'taskmgr.exe',
      'systemsettings.exe',
      'searchhost.exe',
      'sihost.exe',
      'runtimebroker.exe',
    };
  }();

  List<ActiveAppBlockEntry> _entries = <ActiveAppBlockEntry>[];
  bool firefoxKeptOpen = false;

  Future<void> keepFirefoxOpen() async {
    await (await SharedPreferences.getInstance()).setBool(
      'firefox_work_keep_open_v1',
      true,
    );
    firefoxKeptOpen = true;
    _alwaysProtected.add('firefox.exe');
    _entries.removeWhere((entry) => entry.app.exeName == 'firefox.exe');
    await _syncIfeoSidecar();
  }

  Timer? _timer;
  bool _running = false;
  List<_BrowserProcess>? _cachedBrowserProcs;
  DateTime? _browserProcsFetchedAt;
  final Set<String> _seenLaunchKeys = <String>{};
  final Map<String, DateTime> _lastKillByKey = <String, DateTime>{};

  // --- Phase 6 (L5): "never opens" instead of "opens then gets killed" -----
  // The 30s poll+kill loop above stays as a safety net (still runs
  // unconditionally), but for exes that qualify we additionally hijack their
  // launch via IFEO (Image File Execution Options) so a click during a
  // blocked schedule never shows a window at all. See
  // mobile/docs/ENFORCEMENT_MIGRATION_STATUS.md for the full design.
  //
  // The actual registry write needs admin rights, so this process only
  // writes an unprivileged JSON "sidecar" describing which exes are
  // currently blocked; `Elevated-Maintain-Block.ps1` (already-registered
  // elevated scheduled task, no new UAC prompt) reads it and syncs the IFEO
  // keys. We trigger that task on-demand (`schtasks /Run`) whenever the
  // active exe set changes so the switch is near-instant instead of waiting
  // for its 30-minute cadence.
  static const String kIfeoSidecarFileName = 'process_layer_active_exes.json';

  String _ifeoSidecarPath() => p.join(
    Platform.environment['LOCALAPPDATA'] ?? '',
    'SixVPNBlocker',
    kIfeoSidecarFileName,
  );

  String? _lastIfeoSignature;

  /// Pure calculation of "which exes qualify for IFEO launch-blocking" — a
  /// static method (no I/O) so it can be golden-tested without touching the
  /// registry or filesystem. IFEO only intercepts by exe *name*, so:
  ///   * window-title-only legacy rows (`exeName` empty) can never qualify.
  ///   * Chrome/Edge PWA sub-entries share the parent browser's exe — hijacking
  ///     `chrome.exe` would also block every PWA, which is a different,
  ///     already-handled feature (browser_policy layer). Excluded.
  ///   * [alwaysProtected] (OS-critical processes + our own exe) is a hard
  ///     exclusion regardless of what a schedule says.
  static Map<String, String> ifeoEligibleDisplayNames(
    List<ActiveAppBlockEntry> entries,
    Set<String> alwaysProtected,
  ) {
    final Map<String, String> out = <String, String>{};
    for (final ActiveAppBlockEntry e in entries) {
      final BlockApp app = e.app;
      final String exe = app.exeName;
      if (exe.isEmpty) continue;
      if (app.isPwa) continue;
      if (alwaysProtected.contains(exe)) continue;
      out.putIfAbsent(
        exe,
        () => app.displayName.trim().isEmpty ? exe : app.displayName.trim(),
      );
    }
    return out;
  }

  /// Writes the IFEO sidecar JSON and, only when the eligible exe *set*
  /// actually changed, nudges the already-elevated maintain task to sync the
  /// registry right away instead of waiting for its 30-minute tick.
  Future<void> _syncIfeoSidecar() async {
    if (!Platform.isWindows) return;
    try {
      final Map<String, String> eligible = ifeoEligibleDisplayNames(
        _entries,
        _alwaysProtected,
      );
      final Map<String, String> reasons = <String, String>{};
      for (final ActiveAppBlockEntry e in _entries) {
        final String exe = e.app.exeName;
        if (!eligible.containsKey(exe) || reasons.containsKey(exe)) continue;
        reasons[exe] = _reasonForEntry(e);
      }
      final List<String> sortedExes = eligible.keys.toList()..sort();
      final String signature = sortedExes.join(',');
      if (signature == _lastIfeoSignature) return;

      final Map<String, dynamic> payload = <String, dynamic>{
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
        'activeExes': <String, dynamic>{
          for (final String exe in sortedExes)
            exe: <String, String>{
              'displayName': eligible[exe]!,
              'reason': reasons[exe] ?? '',
            },
        },
      };
      final Directory dir = Directory(p.dirname(_ifeoSidecarPath()));
      if (!await dir.exists()) await dir.create(recursive: true);
      await File(
        _ifeoSidecarPath(),
      ).writeAsString(jsonEncode(payload), flush: true);
      _lastIfeoSignature = signature;

      final String schtasks = p.join(
        Platform.environment['WINDIR'] ?? r'C:\Windows',
        'System32',
        'schtasks.exe',
      );
      await windowsRunHidden(schtasks, <String>[
        '/Run',
        '/TN',
        'SixVPNBlockerElevatedMaintain',
      ]);
    } catch (e) {
      AppLogger.instance.warn('ifeo_sidecar: sync failed: $e');
    }
  }

  /// Replaces the active block list with schedule / quick-block context.
  Future<void> setBlockEntries(List<ActiveAppBlockEntry> entries) async {
    if (!Platform.isWindows) return;
    // @incident: firefox_work_window_closed — preserve the user's work browser;
    // URL/category rules remain active while executable termination is excluded.
    firefoxKeptOpen =
        (await SharedPreferences.getInstance()).getBool(
          'firefox_work_keep_open_v1',
        ) ==
        true;
    if (firefoxKeptOpen) _alwaysProtected.add('firefox.exe');
    _entries = entries
        .where(
          (ActiveAppBlockEntry e) =>
              e.app.exeName.isNotEmpty ||
              (e.app.windowTitleMatch?.trim().isNotEmpty ?? false),
        )
        .toList();
    unawaited(_syncIfeoSidecar());
    if (_entries.isEmpty) {
      _timer?.cancel();
      _timer = null;
      _cachedBrowserProcs = null;
      _browserProcsFetchedAt = null;
      _seenLaunchKeys.clear();
      _lastKillByKey.clear();
      return;
    }
    _cachedBrowserProcs = null;
    _browserProcsFetchedAt = null;
    _timer ??= Timer.periodic(_tickInterval, (_) => unawaited(_tick()));
    await _tick();
  }

  @Deprecated('Use setBlockEntries via ActiveAppBlockRegistryService')
  Future<void> setBlockApps(List<BlockApp> apps) async {
    await setBlockEntries(
      apps
          .map(
            (BlockApp a) => ActiveAppBlockEntry(
              app: a,
              context: const AppBlockContext(
                source: AppBlockSource.schedule,
                scheduleLabels: <String>['스케줄'],
              ),
            ),
          )
          .toList(),
    );
  }

  Future<void> _tick() async {
    if (!Platform.isWindows || _entries.isEmpty || _running) return;
    _running = true;
    try {
      final List<ActiveAppBlockEntry> browserBlocks = <ActiveAppBlockEntry>[];
      final List<ActiveAppBlockEntry> plainBlocks = <ActiveAppBlockEntry>[];
      for (final ActiveAppBlockEntry entry in _entries) {
        final BlockApp app = entry.app;
        if (_alwaysProtected.contains(app.exeName)) continue;
        if (app.exeName.isEmpty) {
          plainBlocks.add(entry);
          continue;
        }
        if (app.isChromiumBrowser) {
          browserBlocks.add(entry);
        } else {
          plainBlocks.add(entry);
        }
      }

      // Single batched tasklist call for every plain-block exeName instead
      // of one spawn per entry — keeps child-process count at 1/tick no
      // matter how many apps/games are on the active block list.
      final Set<String> plainExeNames = plainBlocks
          .map((ActiveAppBlockEntry e) => e.app.exeName)
          .where((String n) => n.isNotEmpty)
          .toSet();
      final Map<String, Set<int>> pidsByExe = await _listPidsForExes(
        plainExeNames,
      );

      // @incident: firefox_background_task_false_block — Firefox launches
      // its own firefox.exe for silent background-update / default-browser
      // checks (command line contains `--backgroundtask`) and spawns one
      // firefox.exe per tab/GPU child process (`-contentproc`, `--type=`)
      // even when the user never opened a browser window. `tasklist` only
      // gives the image name, so those helper processes were
      // indistinguishable from a real launch — every one got force-killed
      // and fired a "Firefox 종료됨" notice the user never expected
      // ("실행하지 않은 앱에 대한 알림"). Only spawned when firefox.exe is
      // actually present, so this stays within the 2-child-process/tick
      // budget (tasklist + this WMIC call).
      if ((pidsByExe['firefox.exe'] ?? const <int>{}).isNotEmpty) {
        pidsByExe['firefox.exe'] = await _foregroundFirefoxPids(
          pidsByExe['firefox.exe']!,
        );
      }

      final Set<String> killedExes = <String>{};
      for (final ActiveAppBlockEntry entry in plainBlocks) {
        final BlockApp app = entry.app;
        if (app.exeName.isEmpty) {
          final String? t = app.windowTitleMatch?.trim();
          if (t != null && t.isNotEmpty) {
            await _killByWindowTitle(t, entry: entry);
          }
          continue;
        }
        final Set<int> pids =
            pidsByExe[app.exeName.toLowerCase()] ?? const <int>{};
        _notifyOnNewLaunches(entry: entry, pids: pids, keyPrefix: app.exeName);
        if (pids.isNotEmpty && killedExes.add(app.exeName)) {
          await _killByExe(app.exeName, entry: entry);
        }
        final String? title = app.windowTitleMatch?.trim();
        if (title != null && title.isNotEmpty) {
          await _killByWindowTitle(title, entry: entry);
        }
      }

      if (browserBlocks.isNotEmpty) {
        final List<_BrowserProcess> running =
            await _listBrowserProcessesCached();
        if (running.isNotEmpty) {
          // ALLOW-LIST GUARD (2026-06-21): never process-kill a browser that is
          // currently hosting an allow-listed app (Gemini / Gmail / Google
          // 로그인 / YouTube Music). All tabs share one browser process, so a
          // kill would close the allowed app too. The extension blocks the
          // disallowed tabs per-URL instead. See AllowedBrowserAppCatalog.
          final Set<String> allowedHosts = await BrowserAppAllowlistService
              .instance
              .browsersHostingAllowedApps();
          final Map<int, ActiveAppBlockEntry> pidEntries =
              <int, ActiveAppBlockEntry>{};
          for (final ActiveAppBlockEntry entry in browserBlocks) {
            // Explicit browser hold must still close the main browser when a
            // login tab is open; _matchesBrowserBlock continues to exclude PWAs.
            if (!entry.context.browserReleaseHold &&
                allowedHosts.contains(entry.app.exeName.toLowerCase())) {
              AppLogger.instance.info(
                'windows_app_block: skip kill ${entry.app.exeName} — 허용 앱(Gemini/Gmail/YouTube Music 등) 창이 열려 있어 브라우저 종료 보류 (차단 사이트는 확장이 차단)',
              );
              continue;
            }
            for (final _BrowserProcess proc in running) {
              if (proc.exeName != entry.app.exeName) continue;
              if (_matchesBrowserBlock(proc, entry.app)) {
                pidEntries[proc.pid] = entry;
              }
            }
          }
          if (pidEntries.isNotEmpty) {
            final ActiveAppBlockEntry sample = pidEntries.values.first;
            _notifyOnNewLaunches(
              entry: sample,
              pids: pidEntries.keys.toSet(),
              keyPrefix: '${sample.app.exeName}:browser',
            );
            await _killPids(pidEntries.keys.toSet(), entry: sample);
          }
        }
      }
    } catch (e, st) {
      AppLogger.instance.warn('windows_app_block tick: $e\n$st');
    } finally {
      _running = false;
    }
  }

  void _notifyOnNewLaunches({
    required ActiveAppBlockEntry entry,
    required Set<int> pids,
    required String keyPrefix,
  }) {
    if (pids.isEmpty) return;
    for (final int pid in pids) {
      final String key = '$keyPrefix:$pid';
      if (_seenLaunchKeys.contains(key)) continue;
      _seenLaunchKeys.add(key);
      AppBlockUserNoticeService.instance.notifyAppLaunchBlocked(
        appDisplayName: entry.app.displayName,
        context: entry.context,
        debounceKey: '${entry.dedupeKey}_launch',
      );
      break;
    }
    _seenLaunchKeys.removeWhere((String k) {
      if (!k.startsWith('$keyPrefix:')) return false;
      return !pids.any((int pid) => k == '$keyPrefix:$pid');
    });
  }

  /// Drops Firefox's own silent background helper processes (background
  /// update / default-browser checks, per-tab content/GPU child processes)
  /// from [pids] so only a genuine user-facing Firefox window counts as a
  /// "launch". See the `@incident: firefox_background_task_false_block`
  /// comment at the call site for why this exists. Fails open (returns
  /// [pids] unchanged) if the command-line probe itself fails, so a probe
  /// error never blocks a real enforcement kill.
  Future<Set<int>> _foregroundFirefoxPids(Set<int> pids) async {
    try {
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final String wmic = p.join(windir, 'System32', 'wbem', 'WMIC.exe');
      if (!await File(wmic).exists()) return pids;
      final ProcessResult res = await windowsRunHidden(wmic, <String>[
        'process',
        'where',
        "name='firefox.exe'",
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

      for (final String raw in stdout.split(RegExp(r'\r?\n'))) {
        final String line = raw.trim();
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
      final Set<int> foreground = <int>{};
      for (final int candidate in pids) {
        final String cl = (cmdByPid[candidate] ?? '').toLowerCase();
        if (cl.contains('--backgroundtask') ||
            cl.contains('-contentproc') ||
            cl.contains('--type=')) {
          continue;
        }
        foreground.add(candidate);
      }
      return foreground;
    } catch (_) {
      return pids;
    }
  }

  /// One `tasklist.exe` call (no `/FI` filter) covering every requested
  /// image name at once, keyed by lowercased exe name. Replaces the old
  /// one-spawn-per-entry pattern that forced the tick interval up to 60s —
  /// see the `_tickInterval` comment.
  Future<Map<String, Set<int>>> _listPidsForExes(Set<String> imageNames) async {
    if (imageNames.isEmpty) return const <String, Set<int>>{};
    final Set<String> wanted = imageNames
        .map((String n) => n.toLowerCase())
        .toSet();
    try {
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final ProcessResult pr = await windowsRunHidden(
        p.join(windir, 'System32', 'tasklist.exe'),
        <String>['/FO', 'CSV', '/NH'],
      );
      final String out = '${pr.stdout}';
      final Map<String, Set<int>> byExe = <String, Set<int>>{};
      for (final String line in out.split(RegExp(r'\r?\n'))) {
        final String t = line.trim();
        if (t.isEmpty || t.startsWith('INFO:')) continue;
        final List<String> cols = _parseCsvLine(t);
        if (cols.length < 2) continue;
        final String image = cols[0].toLowerCase().trim();
        if (!wanted.contains(image)) continue;
        final int pid = int.tryParse(cols[1].replaceAll('"', '')) ?? 0;
        if (pid > 0) (byExe[image] ??= <int>{}).add(pid);
      }
      return byExe;
    } catch (_) {
      return const <String, Set<int>>{};
    }
  }

  List<String> _parseCsvLine(String line) {
    final List<String> out = <String>[];
    final StringBuffer cur = StringBuffer();
    bool inQuote = false;
    for (int i = 0; i < line.length; i++) {
      final String ch = line[i];
      if (ch == '"') {
        inQuote = !inQuote;
        continue;
      }
      if (ch == ',' && !inQuote) {
        out.add(cur.toString());
        cur.clear();
        continue;
      }
      cur.write(ch);
    }
    out.add(cur.toString());
    return out;
  }

  bool _matchesBrowserBlock(_BrowserProcess proc, BlockApp block) {
    final String? blockId = block.chromeAppId;
    if (block.exeName == 'aside.exe' &&
        BlockApp.isAsideCliCommandLine(proc.commandLine)) {
      return false;
    }
    if (proc.commandLine.contains('--type=')) return false;

    if (blockId == null || blockId == BlockApp.mainBrowserKey) {
      // Brave has its own extension + URLBlocklist path. Killing the main
      // browser process feels random to the user and can close unrelated work;
      // keep process termination only for explicit Brave PWA app-id rules.
      if (block.exeName == 'brave.exe') return false;
      if (proc.commandLine.contains('--app-id=')) return false;
      if (proc.commandLine.contains('--app=')) return false;
      return true;
    }
    final String? procId = BlockApp.extractAppId(proc.commandLine);
    return procId == blockId;
  }

  Future<void> _killByExe(
    String imageName, {
    required ActiveAppBlockEntry entry,
  }) async {
    final String key = 'exe:$imageName';
    if (!_allowKillNow(key)) return;
    try {
      final String name = entry.app.displayName.trim().isNotEmpty
          ? entry.app.displayName.trim()
          : imageName;
      // Stamp BEFORE taskkill so BrowserExitWatcherService cannot mis-classify
      // this as an external exit during the race window.
      OwnKillLedger.instance.stampImage(
        imageName: imageName,
        reason: '스케줄 앱 차단 — $name',
        reasonKey: 'app_block_exe',
        scheduleLabel: name,
      );
      final ProcessResult pr = await windowsRunHidden(_taskkillExe(), <String>[
        '/F',
        '/IM',
        imageName,
      ]);
      // @incident: firefox_phantom_close_notice — exit 128 means taskkill
      // found NOTHING to kill (the pid(s) we saw in the tasklist snapshot a
      // moment ago already exited on their own — Firefox's background-task/
      // update-check helper processes are extremely short-lived). Treating
      // 128 the same as 0 (real kill) meant this fired a "Firefox 종료됨"
      // popup on every tick where a helper process merely raced past us,
      // even though the user never opened Firefox and nothing was actually
      // terminated. Only exit 0 (an actual kill) is notice-worthy.
      if (pr.exitCode == 0) {
        BlockActivityLogService.instance.record(
          kind: BlockActivityKind.protection,
          message: '스케줄 앱 차단: $name 종료 — 활성 스케줄에 의해 차단됨',
          data: <String, Object?>{'exe': imageName, 'label': name},
          debounceKey: 'app_block_$imageName',
        );
        // Always-visible desktop popup so the user knows WHAT closed and WHY.
        AppBlockUserNoticeService.instance.notifyBrowserKilledWithReason(
          browserOrAppDisplayName: name,
          reasonKo: _reasonForEntry(entry),
          debounceKey: 'popup_exe_$imageName',
        );
        // If the killed exe is the OS default browser, the next web link
        // the user clicks would hit the same kill loop. Open the Default
        // Apps settings now (bypasses the 25-min cooldown) so they can
        // promote a 6 VPN-protected browser to default.
        unawaited(
          DefaultBrowserPromoterService.instance.reactToBrowserKill(
            imageName: imageName,
            reasonKo: '스케줄 앱 차단 — $name',
          ),
        );
      }
    } catch (e, st) {
      if (kDebugMode) debugPrint('killByExe($imageName) failed: $e\n$st');
    }
  }

  Future<void> _killByWindowTitle(
    String titleSubstring, {
    required ActiveAppBlockEntry entry,
  }) async {
    // GUARD 1 (2026-06-21): a bare browser brand title ("Google Chrome",
    // "Microsoft Edge", "Mozilla Firefox", …) matches EVERY window of that
    // browser — every Chrome window title ends in "- Google Chrome". Running
    // `taskkill *Google Chrome*` here nukes Gemini/Gmail/YouTube Music too.
    // The whole-browser block must go through the browser-block path (exe +
    // --app-id aware, allow-list guarded), never an indiscriminate title kill.
    if (AllowedBrowserAppCatalog.isGenericBrowserBrand(titleSubstring)) {
      AppLogger.instance.info(
        'windows_app_block: 브라우저 브랜드 제목 "$titleSubstring" 무차별 종료 거부 '
        '(모든 창 매칭 → Gemini/Gmail까지 죽음). 확장/URL 레이어가 차단 처리.',
      );
      return;
    }
    // GUARD 2: never kill an allow-listed app by window title.
    if (AllowedBrowserAppCatalog.isAllowedWindowTitle(titleSubstring)) {
      AppLogger.instance.info(
        'windows_app_block: 허용 앱 제목 "$titleSubstring" 종료 거부',
      );
      return;
    }
    final String key = 'title:${titleSubstring.toLowerCase()}';
    if (!_allowKillNow(key)) return;
    AppBlockUserNoticeService.instance.notifyAppLaunchBlocked(
      appDisplayName: entry.app.displayName,
      context: entry.context,
      debounceKey: 'title_${titleSubstring.hashCode}',
    );
    try {
      // Title-based kill — we don't know the target image up front. Stamp a
      // synthetic image so the watcher's image-fallback path can correlate.
      OwnKillLedger.instance.stampImage(
        imageName: 'titlematch:$titleSubstring',
        reason: '스케줄 창 제목 차단 — "$titleSubstring"',
        reasonKey: 'app_block_title',
      );
      await windowsRunHidden(_taskkillExe(), <String>[
        '/F',
        '/FI',
        'WINDOWTITLE eq *$titleSubstring*',
      ]);
      BlockActivityLogService.instance.record(
        kind: BlockActivityKind.protection,
        message: '스케줄 창 제목 차단: "$titleSubstring" 종료',
        debounceKey: 'app_block_title_$titleSubstring',
      );
      AppBlockUserNoticeService.instance.notifyBrowserKilledWithReason(
        browserOrAppDisplayName: entry.app.displayName.trim().isNotEmpty
            ? entry.app.displayName.trim()
            : titleSubstring,
        reasonKo: _reasonForEntry(entry),
        debounceKey: 'popup_title_${titleSubstring.hashCode}',
      );
      // Browser window titles ("Google Chrome", "Mozilla Firefox" …)
      // hit here too. We don't know the exe up front, so let the promoter
      // run a generic check — it will scan the OS default and act if
      // the current default browser is blocked.
      unawaited(
        DefaultBrowserPromoterService.instance.reactToAnyKill(
          reasonKo: '스케줄 창 제목 차단 — "$titleSubstring"',
        ),
      );
    } catch (e, st) {
      if (kDebugMode) {
        debugPrint('killByWindowTitle($titleSubstring) failed: $e\n$st');
      }
    }
  }

  Future<void> _killPids(
    Set<int> pids, {
    required ActiveAppBlockEntry entry,
  }) async {
    final String key = 'pids:${entry.dedupeKey}';
    if (!_allowKillNow(key)) return;
    try {
      final String name = entry.app.displayName.trim().isNotEmpty
          ? entry.app.displayName.trim()
          : '브라우저 앱';
      // Stamp every PID BEFORE the kill — per-PID stamps are sharper than
      // the image-level fallback because /T also takes child PIDs we never
      // see. The watcher only ever sees top-level browser processes so
      // per-PID coverage on the main browser PID is what we actually need.
      for (final int pid in pids) {
        OwnKillLedger.instance.stampPid(
          pid: pid,
          imageName: 'browser.exe',
          reason: '스케줄 브라우저 앱 차단 — $name',
          reasonKey: 'app_block_pid',
          scheduleLabel: name,
        );
      }
      final List<String> args = <String>['/F', '/T'];
      for (final int pid in pids) {
        args.addAll(<String>['/PID', '$pid']);
      }
      final ProcessResult pr = await windowsRunHidden(_taskkillExe(), args);
      AppLogger.instance.info('windows_app_block: taskkill pids=$pids');
      // @incident: firefox_phantom_close_notice — see _killByExe: exit 128
      // means every listed PID was already gone by the time taskkill ran
      // (race with a short-lived helper process), so nothing was actually
      // terminated. Only notify on a real kill (exit 0).
      if (pr.exitCode == 0) {
        BlockActivityLogService.instance.record(
          kind: BlockActivityKind.protection,
          message: '스케줄 앱 차단: $name 종료 — 활성 스케줄에 의해 차단됨',
          data: <String, Object?>{'pids': pids.toList(), 'label': name},
          debounceKey: 'app_block_pids_${pids.first}',
        );
        // Always-visible desktop popup naming the closed browser + reason.
        AppBlockUserNoticeService.instance.notifyBrowserKilledWithReason(
          browserOrAppDisplayName: name,
          reasonKo: _reasonForEntry(entry),
          debounceKey: 'popup_browser_${entry.app.exeName}',
        );
        // PID-set kill targets browser child processes — surface the
        // settings page if that browser is the OS default. The entry's
        // exeName tells us which image these PIDs belonged to.
        unawaited(
          DefaultBrowserPromoterService.instance.reactToBrowserKill(
            imageName: entry.app.exeName,
            reasonKo: '스케줄 브라우저 차단 — $name',
          ),
        );
      }
    } catch (e, st) {
      if (kDebugMode) debugPrint('killPids($pids) failed: $e\n$st');
    }
  }

  Future<List<_BrowserProcess>> _listBrowserProcessesCached() async {
    final DateTime now = DateTime.now();
    if (_cachedBrowserProcs != null &&
        _browserProcsFetchedAt != null &&
        now.difference(_browserProcsFetchedAt!) < _browserListMinInterval) {
      return _cachedBrowserProcs!;
    }
    final List<_BrowserProcess> fresh = await _listBrowserProcesses();
    _cachedBrowserProcs = fresh;
    _browserProcsFetchedAt = now;
    return fresh;
  }

  /// Human-readable cause for the desktop popup, e.g.
  /// "스케줄 'Internet Browser' 차단 (해제 21:30)" or "빠른 차단".
  String _reasonForEntry(ActiveAppBlockEntry entry) {
    final AppBlockContext c = entry.context;
    final String labels = c.scheduleLabels
        .where((String s) => s.trim().isNotEmpty)
        .join(', ');
    String base;
    switch (c.source) {
      case AppBlockSource.schedule:
        base = labels.isNotEmpty ? "스케줄 '$labels' 차단" : '활성 스케줄에 의한 차단';
      case AppBlockSource.quickBlock:
        base = labels.isNotEmpty ? '빠른 차단 ($labels)' : '빠른 차단';
      case AppBlockSource.maintenance:
        base = c.maintenanceTitle?.trim().isNotEmpty == true
            ? '유지보수: ${c.maintenanceTitle}'
            : '유지보수 작업 중 차단';
    }
    final DateTime? end = c.endsAt;
    if (end != null) {
      final String hh = end.hour.toString().padLeft(2, '0');
      final String mm = end.minute.toString().padLeft(2, '0');
      base = '$base — $hh:$mm 해제';
    }
    final String tagLine = c.tagLineKo;
    if (tagLine.isNotEmpty) {
      base = '$base · 원인 태그: $tagLine';
    }
    return base;
  }

  bool _allowKillNow(String key) {
    final DateTime now = DateTime.now();
    final DateTime? last = _lastKillByKey[key];
    if (last != null && now.difference(last) < _killCooldown) {
      return false;
    }
    _lastKillByKey[key] = now;
    if (_lastKillByKey.length > 240) {
      _lastKillByKey.removeWhere(
        (String _, DateTime at) =>
            now.difference(at) > const Duration(minutes: 3),
      );
    }
    return true;
  }

  Future<List<_BrowserProcess>> _listBrowserProcesses() async {
    try {
      final List<_BrowserProcess>? wmic = await _listBrowserProcessesWmic();
      if (wmic != null && wmic.isNotEmpty) return wmic;
      return await _listBrowserProcessesPowerShellFallback();
    } catch (e, st) {
      if (kDebugMode) debugPrint('listBrowserProcesses failed: $e\n$st');
      return const <_BrowserProcess>[];
    }
  }

  /// No PowerShell — avoids black console flash on many Windows builds.
  Future<List<_BrowserProcess>?> _listBrowserProcessesWmic() async {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final String wmic = p.join(windir, 'System32', 'wbem', 'WMIC.exe');
    if (!await File(wmic).exists()) return null;

    final ProcessResult res = await windowsRunHidden(wmic, <String>[
      'process',
      'where',
      "name='chrome.exe' or name='msedge.exe' or name='brave.exe' or name='Aside.exe'",
      'get',
      'ProcessId,Name,CommandLine',
      '/format:list',
    ]);
    if (res.exitCode != 0) return null;
    final String stdout = (res.stdout ?? '').toString();
    if (stdout.trim().isEmpty) return const <_BrowserProcess>[];

    final List<_BrowserProcess> out = <_BrowserProcess>[];
    int pid = 0;
    String name = '';
    final StringBuffer cmd = StringBuffer();
    void flushBlock() {
      if (pid > 0 && name.isNotEmpty) {
        out.add(
          _BrowserProcess(
            pid: pid,
            exeName: name.toLowerCase(),
            commandLine: cmd.toString(),
          ),
        );
      }
      pid = 0;
      name = '';
      cmd.clear();
    }

    for (final String raw in stdout.split(RegExp(r'\r?\n'))) {
      final String line = raw.trim();
      if (line.isEmpty) {
        flushBlock();
        continue;
      }
      final int eq = line.indexOf('=');
      if (eq <= 0) continue;
      final String key = line.substring(0, eq).trim();
      final String val = line.substring(eq + 1).trim();
      switch (key) {
        case 'ProcessId':
          pid = int.tryParse(val) ?? 0;
        case 'Name':
          name = val;
        case 'CommandLine':
          cmd.write(val);
      }
    }
    flushBlock();
    return out;
  }

  Future<List<_BrowserProcess>>
  _listBrowserProcessesPowerShellFallback() async {
    const String pipeline =
        "Get-CimInstance Win32_Process -Filter \"Name = 'chrome.exe' OR Name = 'msedge.exe' OR Name = 'brave.exe' OR Name = 'Aside.exe'\" | "
        "Select-Object ProcessId,Name,CommandLine | ConvertTo-Json -Compress -Depth 3";

    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final ProcessResult res = await windowsRunHidden(
      p.join(windir, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'),
      <String>[
        '-NoProfile',
        '-NoLogo',
        '-NonInteractive',
        '-Command',
        pipeline,
      ],
    );
    if (res.exitCode != 0) return const <_BrowserProcess>[];
    final String stdout = (res.stdout ?? '').toString().trim();
    if (stdout.isEmpty) return const <_BrowserProcess>[];

    Object? decoded;
    try {
      decoded = jsonDecode(stdout);
    } catch (_) {
      return const <_BrowserProcess>[];
    }
    final List<dynamic> rows = <dynamic>[];
    if (decoded is List<dynamic>) {
      rows.addAll(decoded);
    } else if (decoded is Map<String, dynamic>) {
      rows.add(decoded);
    }
    final List<_BrowserProcess> out = <_BrowserProcess>[];
    for (final dynamic row in rows) {
      if (row is! Map<String, dynamic>) continue;
      final int pid = (row['ProcessId'] as num?)?.toInt() ?? 0;
      final String name = ((row['Name'] as String?) ?? '').trim().toLowerCase();
      final String cmd = (row['CommandLine'] as String?) ?? '';
      if (pid <= 0 || name.isEmpty) continue;
      out.add(_BrowserProcess(pid: pid, exeName: name, commandLine: cmd));
    }
    return out;
  }
}

class _BrowserProcess {
  const _BrowserProcess({
    required this.pid,
    required this.exeName,
    required this.commandLine,
  });

  final int pid;
  final String exeName;
  final String commandLine;
}
