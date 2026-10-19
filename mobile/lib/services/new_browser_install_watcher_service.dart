import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'block_activity_log_service.dart';
import 'browser_install_safety_service.dart';
import 'installed_browsers_auto_apply_service.dart';
import 'browser_extension_force_install_service.dart';
import 'chrome_extension_payload_service.dart';
import 'universal_browser_block_service.dart';
import 'brave_extension_install_service.dart';
import 'chromium_derivative_extension_service.dart';
import '../data/chromium_derivative_browsers.dart';
import 'windows_browser_bypass_closer_service.dart';
import 'windows_extension_self_heal_service.dart';
import 'windows_firefox_extension_install_service.dart';
import 'work_context_tracker.dart';

/// Detects **newly installed** browsers and applies extension + block policies.
/// Poll is intentionally slow (3 min) — boot apply is owned by
/// [BootBrowserAutofixService] / [InstalledBrowsersAutoApplyService].
final class NewBrowserInstallWatcherService {
  NewBrowserInstallWatcherService._();
  static final NewBrowserInstallWatcherService instance =
      NewBrowserInstallWatcherService._();

  static const Duration kPollInterval = Duration(minutes: 3);
  static const Duration kBootDelay = Duration(seconds: 100);
  static const Duration kInstallScanCacheTtl = Duration(minutes: 2);

  Timer? _timer;
  bool _running = false;
  bool _tickBusy = false;
  Set<String>? _cachedInstalled;
  DateTime? _cachedInstalledAt;

  String _statePath() {
    final String local = Platform.environment['LOCALAPPDATA'] ?? '';
    return p.join(local, 'SixVPNBlocker', 'known_browsers_v1.json');
  }

  String _reportPath() {
    final String local = Platform.environment['LOCALAPPDATA'] ?? '';
    return p.join(local, 'SixVPNBlocker', 'new_browser_watcher_last.json');
  }

  void start() {
    if (!Platform.isWindows || _running) return;
    _running = true;
    Future<void>.delayed(kBootDelay, () {
      if (!_running) return;
      unawaited(tick(reason: 'boot'));
    });
    _timer?.cancel();
    _timer = Timer.periodic(kPollInterval, (_) {
      unawaited(tick(reason: 'poll'));
    });
    AppLogger.instance.info('new_browser_watcher: started (${kPollInterval.inSeconds}s)');
  }

  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  Future<void> tick({String reason = 'manual'}) async {
    if (!Platform.isWindows || _tickBusy) return;
    if (reason == 'poll' &&
        (WorkContextTracker.instance.isBusy ||
            InstalledBrowsersAutoApplyService.instance.isBusy)) {
      return;
    }
    _tickBusy = true;
    try {
      final Set<String> installed = await _scanInstalledIds();
      final _KnownState state = await _loadState();

      if (!state.seeded) {
        AppLogger.instance.info(
          'new_browser_watcher: first seed — ${installed.length} browsers (delegated apply)',
        );
        await _saveState(
          _KnownState(seeded: true, knownIds: installed),
        );
        if (installed.isNotEmpty) {
          unawaited(
            InstalledBrowsersAutoApplyService.instance.applyAllInstalled(
              reason: 'watcher_seed',
              force: true,
              showBanner: true,
            ),
          );
        }
        return;
      }

      final Set<String> novel =
          installed.difference(state.knownIds);
      if (novel.isEmpty) return;

      final List<Map<String, Object?>> applied = <Map<String, Object?>>[];
      for (final String id in novel) {
        final _WatchedBrowser? browser = _catalogById(id);
        if (browser == null) continue;
        await BrowserInstallSafetyService.instance.onNovelDetected(
          browserId: browser.id,
          displayName: browser.displayName,
        );
        await BrowserInstallSafetyService.instance.onNovelApplying(
          browserId: browser.id,
          displayName: browser.displayName,
        );
        final Map<String, Object?> row = await _applyToNewBrowser(browser);
        await BrowserInstallSafetyService.instance.onNovelApplyDone(
          browserId: browser.id,
          displayName: browser.displayName,
          ok: row['ok'] as bool? ?? false,
        );
        applied.add(row);
      }

      await _saveState(
        _KnownState(
          seeded: true,
          knownIds: <String>{...state.knownIds, ...installed},
        ),
      );

      await File(_reportPath()).writeAsString(
        jsonEncode(<String, Object?>{
          'at': DateTime.now().toUtc().toIso8601String(),
          'reason': reason,
          'novel': novel.toList(),
          'applied': applied,
        }),
        flush: true,
      );

      AppLogger.instance.info(
        'new_browser_watcher: new=${novel.join(",")} reason=$reason',
      );
    } catch (e, st) {
      AppLogger.instance.warn('new_browser_watcher tick failed: $e\n$st');
    } finally {
      _tickBusy = false;
    }
  }

  Future<Map<String, Object?>> _applyToNewBrowser(_WatchedBrowser b) async {
    final Stopwatch sw = Stopwatch()..start();
    final List<String> actions = <String>[];
    bool ok = false;
    String detail = '';

    try {
      AppLogger.instance.info('new_browser_watcher: applying → ${b.displayName}');
      BlockActivityLogService.instance.record(
        kind: BlockActivityKind.selfHeal,
        message: '새 브라우저 감지: ${b.displayName} — 확장·차단 적용 중',
        data: <String, Object?>{'browserId': b.id},
      );

      if (b.engine == _BrowserEngine.firefox) {
        await WindowsFirefoxExtensionInstallService.instance
            .applyHkcuExtensionPolicy();
        actions.add('firefox_hkcu_xpi');
        ok = true;
        detail = 'Firefox XPI + ExtensionSettings + WebsiteFilter';
      } else {
        final String? folder =
            await ChromeExtensionPayloadService.ensureStablePayload();
        if (folder != null) {
          await WindowsExtensionSelfHealService.instance.reapplyHkcuOnly(
            sourceFolder: folder,
          );
          actions.add('chromium_hkcu_forcelist');
        }
        if (b.id == 'brave') {
          final BraveExtensionApplyResult brave =
              await BraveExtensionInstallService.instance.apply(
            reason: 'new_browser_brave',
            force: true,
          );
          actions.add('brave_ext:${brave.ok}');
        }
        if (chromiumDerivativeById(b.id) != null) {
          final DerivativeExtensionApplyResult derivative =
              await ChromiumDerivativeExtensionService.instance.apply(
            b.id,
            reason: 'new_browser_${b.id}',
            force: true,
          );
          actions.add('derivative_${b.id}:${derivative.ok}');
        }
        await UniversalBrowserBlockService.instance.syncNow(
          reason: 'new_browser_${b.id}',
        );
        actions.add('universal_block_sync');
        final BypassCloserResult closer =
            await WindowsBrowserBypassCloserService.instance.applyAll();
        if (closer.ok) actions.add('bypass_closer');
        ok = true;
        detail = closer.message;
      }

      final BrowserExtensionForceInstallReport force =
          await BrowserExtensionForceInstallService.instance.installAll(
        force: true,
        reason: 'new_browser_${b.id}',
        attemptElevated: false,
      );
      actions.add('force_install:${force.ok}');
      ok = ok && force.ok;

      BlockActivityLogService.instance.record(
        kind: BlockActivityKind.selfHeal,
        message: ok
            ? '새 브라우저 ${b.displayName}: 확장·차단 적용 완료'
            : '새 브라우저 ${b.displayName}: 일부 적용 실패',
        data: <String, Object?>{'actions': actions.join(' · ')},
      );
    } catch (e) {
      detail = '$e';
      AppLogger.instance.warn('new_browser_watcher apply ${b.id}: $e');
    }

    return <String, Object?>{
      'id': b.id,
      'displayName': b.displayName,
      'ok': ok,
      'ms': sw.elapsedMilliseconds,
      'actions': actions,
      'detail': detail,
    };
  }

  Future<Set<String>> _scanInstalledIds() async {
    final DateTime now = DateTime.now();
    if (_cachedInstalled != null &&
        _cachedInstalledAt != null &&
        now.difference(_cachedInstalledAt!) < kInstallScanCacheTtl) {
      return Set<String>.from(_cachedInstalled!);
    }
    final Set<String> out = <String>{};
    for (final _WatchedBrowser b in _kCatalog) {
      if (await _anyExeExists(b.exeCandidates)) {
        out.add(b.id);
      }
    }
    _cachedInstalled = out;
    _cachedInstalledAt = now;
    return out;
  }

  Future<bool> _anyExeExists(List<String> candidates) async {
    for (final String raw in candidates) {
      final String path = _expandEnv(raw);
      if (path.isNotEmpty && await File(path).exists()) {
        return true;
      }
    }
    return false;
  }

  String _expandEnv(String raw) {
    String s = raw;
    final Map<String, String> env = Platform.environment;
    for (final MapEntry<String, String> e in env.entries) {
      s = s.replaceAll('%${e.key}%', e.value);
    }
    s = s.replaceAll(r'%ProgramFiles(x86)%', env['ProgramFiles(x86)'] ?? '');
    return s;
  }

  Future<_KnownState> _loadState() async {
    final File f = File(_statePath());
    if (!await f.exists()) {
      return const _KnownState(seeded: false, knownIds: <String>{});
    }
    try {
      final Object? decoded = jsonDecode(await f.readAsString());
      if (decoded is! Map<String, dynamic>) {
        return const _KnownState(seeded: false, knownIds: <String>{});
      }
      final List<Object?> raw = decoded['knownIds'] as List<Object?>? ?? <Object?>[];
      return _KnownState(
        seeded: decoded['seeded'] as bool? ?? true,
        knownIds: raw.whereType<String>().toSet(),
      );
    } catch (_) {
      return const _KnownState(seeded: false, knownIds: <String>{});
    }
  }

  Future<void> _saveState(_KnownState state) async {
    final File f = File(_statePath());
    await f.parent.create(recursive: true);
    final List<String> ids = state.knownIds.toList()..sort();
    await f.writeAsString(
      jsonEncode(<String, Object?>{
        'seeded': state.seeded,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
        'knownIds': ids,
      }),
      flush: true,
    );
  }

  static _WatchedBrowser? _catalogById(String id) {
    for (final _WatchedBrowser b in _kCatalog) {
      if (b.id == id) return b;
    }
    return null;
  }
}

enum _BrowserEngine { chromium, firefox }

final class _WatchedBrowser {
  const _WatchedBrowser({
    required this.id,
    required this.displayName,
    required this.exeCandidates,
    required this.engine,
  });

  final String id;
  final String displayName;
  final List<String> exeCandidates;
  final _BrowserEngine engine;
}

const List<_WatchedBrowser> _kCatalog = <_WatchedBrowser>[
  _WatchedBrowser(
    id: 'chrome',
    displayName: 'Google Chrome',
    engine: _BrowserEngine.chromium,
    exeCandidates: <String>[
      r'%ProgramFiles%\Google\Chrome\Application\chrome.exe',
      r'%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe',
      r'%LOCALAPPDATA%\Google\Chrome\Application\chrome.exe',
    ],
  ),
  _WatchedBrowser(
    id: 'edge',
    displayName: 'Microsoft Edge',
    engine: _BrowserEngine.chromium,
    exeCandidates: <String>[
      r'%ProgramFiles%\Microsoft\Edge\Application\msedge.exe',
      r'%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe',
    ],
  ),
  _WatchedBrowser(
    id: 'firefox',
    displayName: 'Mozilla Firefox',
    engine: _BrowserEngine.firefox,
    exeCandidates: <String>[
      r'%ProgramFiles%\Mozilla Firefox\firefox.exe',
      r'%ProgramFiles(x86)%\Mozilla Firefox\firefox.exe',
    ],
  ),
  _WatchedBrowser(
    id: 'brave',
    displayName: 'Brave',
    engine: _BrowserEngine.chromium,
    exeCandidates: <String>[
      r'%ProgramFiles%\BraveSoftware\Brave-Browser\Application\brave.exe',
      r'%ProgramFiles(x86)%\BraveSoftware\Brave-Browser\Application\brave.exe',
      r'%LOCALAPPDATA%\BraveSoftware\Brave-Browser\Application\brave.exe',
    ],
  ),
  _WatchedBrowser(
    id: 'whale',
    displayName: 'Naver Whale',
    engine: _BrowserEngine.chromium,
    exeCandidates: <String>[
      r'%ProgramFiles%\Naver\Naver Whale\Application\whale.exe',
      r'%ProgramFiles(x86)%\Naver\Naver Whale\Application\whale.exe',
      r'%LOCALAPPDATA%\Naver\Naver Whale\Application\whale.exe',
    ],
  ),
  _WatchedBrowser(
    id: 'vivaldi',
    displayName: 'Vivaldi',
    engine: _BrowserEngine.chromium,
    exeCandidates: <String>[
      r'%ProgramFiles%\Vivaldi\Application\vivaldi.exe',
      r'%ProgramFiles(x86)%\Vivaldi\Application\vivaldi.exe',
      r'%LOCALAPPDATA%\Vivaldi\Application\vivaldi.exe',
    ],
  ),
  _WatchedBrowser(
    id: 'opera',
    displayName: 'Opera',
    engine: _BrowserEngine.chromium,
    exeCandidates: <String>[
      r'%ProgramFiles%\Opera\opera.exe',
      r'%ProgramFiles(x86)%\Opera\opera.exe',
      r'%LOCALAPPDATA%\Programs\Opera\opera.exe',
    ],
  ),
  _WatchedBrowser(
    id: 'opera_gx',
    displayName: 'Opera GX',
    engine: _BrowserEngine.chromium,
    exeCandidates: <String>[
      r'%ProgramFiles%\Opera GX\opera.exe',
      r'%LOCALAPPDATA%\Programs\Opera GX\opera.exe',
    ],
  ),
];

final class _KnownState {
  const _KnownState({required this.seeded, required this.knownIds});
  final bool seeded;
  final Set<String> knownIds;
}
