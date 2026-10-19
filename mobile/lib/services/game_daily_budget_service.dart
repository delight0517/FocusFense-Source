// @feature: game-daily-budget — policy/accounting within the existing process layer.
// Uses existing usage_daily/hourly rows, never a second process enforcement loop.
import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_block_user_notice_service.dart';
import 'backup_service.dart';
import 'block_sync_service.dart';
import 'local_database.dart';
import 'lock_policy_service.dart';
import 'usage_limit_policy_service.dart';

typedef GameUsageReader = Future<int> Function(DateTime day);
typedef GameUsageWriter = Future<void> Function(int seconds, DateTime day);

final class GameDailyBudgetService {
  GameDailyBudgetService._()
    : _clock = null,
      _loadOverride = null,
      _saveOverride = null,
      _readOverride = null,
      _writeOverride = null,
      _notifyOverride = null,
      _lockedOverride = null;
  static final GameDailyBudgetService instance = GameDailyBudgetService._();

  GameDailyBudgetService.forTesting({
    required DateTime Function() clock,
    required Future<Map<String, Object?>> Function() load,
    required Future<void> Function(Map<String, Object?>) save,
    required GameUsageReader readUsage,
    required GameUsageWriter writeUsage,
    required Future<void> Function(int remaining, int used, int max) notify,
    Future<bool> Function()? settingsLocked,
  }) : _clock = clock,
       _loadOverride = load,
       _saveOverride = save,
       _readOverride = readUsage,
       _writeOverride = writeUsage,
       _notifyOverride = notify,
       _lockedOverride = settingsLocked;

  static const String subject = 'app-group|games';
  static const String _prefsKey = 'game_daily_budget_v1';
  final DateTime Function()? _clock;
  final Future<Map<String, Object?>> Function()? _loadOverride;
  final Future<void> Function(Map<String, Object?>)? _saveOverride;
  final GameUsageReader? _readOverride;
  final GameUsageWriter? _writeOverride;
  final Future<void> Function(int, int, int)? _notifyOverride;
  final Future<bool> Function()? _lockedOverride;
  Map<String, Object?>? _config;
  Future<void> _queue = Future<void>.value();
  Set<String> _lockedTargets = <String>{};
  String? _lockDay;
  String? _lastObservedExecutable;
  DateTime? _lastObservedAt;

  DateTime get _now => (_clock ?? DateTime.now)();
  static String _day(DateTime at) => '${at.year}-${at.month}-${at.day}';
  static DateTime _midnight(DateTime at) => DateTime(at.year, at.month, at.day);
  static DateTime _nextMidnight(DateTime at) =>
      DateTime(at.year, at.month, at.day + 1);

  /// Runtime identity normalization only; matching stays exact, never a substring.
  static String canonicalExe(String raw) => raw
      .trim()
      .replaceAll('\\', '/')
      .split('/')
      .last
      .replaceFirst(RegExp(r'^win\|', caseSensitive: false), '')
      .toLowerCase();

  static const Set<String> _neverGames = <String>{
    'chrome.exe',
    'firefox.exe',
    'msedge.exe',
    'aside.exe',
    'brave.exe',
    'opera.exe',
    'steam.exe',
    'steamwebhelper.exe',
    'battle.net.exe',
    'battlenet.exe',
    'epicgameslauncher.exe',
    'galaxyclient.exe',
    'wallpaper32.exe',
    'wallpaper64.exe',
    'wallpaperui.exe',
    'crashreportclient.exe',
    'unitycrashhandler64.exe',
    'unityhub.exe',
    'unrealeditor.exe',
    'ue4editor.exe',
    'ue5editor.exe',
    'ue5editor-cmd.exe',
    'godot.exe',
    'blender.exe',
    'fmodel.exe',
    'devenv.exe',
    'code.exe',
    'rider64.exe',
    'dotnet.exe',
    'msbuild.exe',
    'obs64.exe',
    'discord.exe',
    'notepad.exe',
    'notepad++.exe',
    'focusfense.exe',
    'explorer.exe',
    'taskmgr.exe',
    'applicationframehost.exe',
    'searchhost.exe',
    'startmenuexperiencehost.exe',
    'powershell.exe',
    'pwsh.exe',
    'cmd.exe',
    'riotclientservices.exe',
    'riotclientux.exe',
  };

  static const List<String> _gameInstallPathMarkers = <String>[
    r'\steamapps\common\',
    r'\epic games\',
    r'\xboxgames\',
    r'\gog galaxy\games\',
    r'\ubisoft game launcher\games\',
    r'\ea games\',
    r'\origin games\',
    r'\riot games\',
  ];

  static final RegExp _shippedGameExecutable = RegExp(
    r'(?:[-_](?:win32|win64))?[-_]shipping\.exe$',
    caseSensitive: false,
  );

  Future<T> _exclusive<T>(Future<T> Function() body) {
    final Future<T> result = _queue.then((_) => body());
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> _load() async {
    if (_config != null) return;
    Map<String, Object?> raw = <String, Object?>{};
    if (_loadOverride != null) {
      raw = await _loadOverride();
    } else {
      final String? encoded = (await SharedPreferences.getInstance()).getString(
        _prefsKey,
      );
      if (encoded != null) {
        raw = Map<String, Object?>.from(jsonDecode(encoded) as Map);
      }
    }
    _config = <String, Object?>{
      'enabled': false,
      'maxMinutes': 30,
      'warningMinutes': 10,
      'targets': <String>[],
      ...raw,
    };
  }

  Future<void> _save() async {
    if (_saveOverride != null) {
      await _saveOverride(Map<String, Object?>.from(_config!));
      return;
    }
    await (await SharedPreferences.getInstance()).setString(
      _prefsKey,
      jsonEncode(_config),
    );
  }

  List<String> get _targets => List<String>.from(
    (_config?['targets'] as List? ?? const <String>[]).where(
      (Object? value) => value is String && !isExcludedExecutable(value),
    ),
  );
  int get _maxSeconds => (_config!['maxMinutes'] as int) * 60;
  int get _warningSeconds => (_config!['warningMinutes'] as int) * 60;
  Future<int> _read(DateTime at) => _readOverride != null
      ? _readOverride(at)
      : LocalDatabase.instance.usageDailyTotal(subject, at);
  Future<void> _write(int seconds, DateTime at) => _writeOverride != null
      ? _writeOverride(seconds, at)
      : LocalDatabase.instance.addUsageSeconds(
          subject,
          seconds,
          at,
          background: false,
        );

  Future<void> _writeWithinDailyLimit(int seconds, DateTime at) async {
    if (seconds <= 0) return;
    final int used = await _read(at);
    final int accepted = (_maxSeconds - used).clamp(0, seconds);
    if (accepted > 0) await _write(accepted, at);
  }

  Future<Map<String, Object?>> configure({
    required bool enabled,
    required int maxMinutes,
    required int warningMinutes,
    required List<String> targets,
  }) => _exclusive(
    () => _configure(
      enabled: enabled,
      maxMinutes: maxMinutes,
      warningMinutes: warningMinutes,
      targets: targets,
    ),
  );

  Future<Map<String, Object?>> _configure({
    required bool enabled,
    required int maxMinutes,
    required int warningMinutes,
    required List<String> targets,
    String? warnedDay,
  }) async {
    if (maxMinutes < 1 ||
        maxMinutes > 1440 ||
        warningMinutes < 0 ||
        warningMinutes >= maxMinutes ||
        (enabled && targets.isEmpty) ||
        targets.length > 100) {
      throw ArgumentError(
        'maxMinutes 1..1440; warningMinutes 0..<maxMinutes; targets 1..100',
      );
    }
    final List<String> next = targets.map(canonicalExe).toSet().toList()
      ..sort();
    if (next.any(
      (e) =>
          !RegExp(r'^[a-z0-9_. -]+\.exe$').hasMatch(e) ||
          isExcludedExecutable(e),
    )) {
      throw ArgumentError(
        'Only explicit game executable names are allowed; browsers, launchers and editors are excluded',
      );
    }
    await _load();
    final bool weakening =
        _config!['enabled'] == true &&
        (!enabled ||
            maxMinutes > (_config!['maxMinutes'] as int) ||
            !_targets.every(next.contains));
    if (weakening && await (_lockedOverride?.call() ?? _settingsLocked())) {
      throw StateError(
        'Game budget cannot be weakened while protection settings are locked',
      );
    }
    _config!.addAll(<String, Object?>{
      'enabled': enabled,
      'maxMinutes': maxMinutes,
      'warningMinutes': warningMinutes,
      'targets': next,
    });
    if (warnedDay != null && _config!['warnedDay'] != _day(_now)) {
      _config!['warnedDay'] = warnedDay;
    }
    await _save();
    if (_loadOverride == null) BackupService.instance.scheduleSync();
    return _status();
  }

  Future<Map<String, Object?>> toBackupMap() => _exclusive(() async {
    await _load();
    return Map<String, Object?>.from(_config!);
  });

  Future<void> restoreFromBackup(Object? raw) => _exclusive(() async {
    if (raw is! Map) return;
    final Map<String, Object?> data = Map<String, Object?>.from(raw);
    final Object? targets = data['targets'];
    if (data['enabled'] is! bool ||
        data['maxMinutes'] is! int ||
        data['warningMinutes'] is! int ||
        targets is! List ||
        targets.any((e) => e is! String)) {
      throw ArgumentError('Invalid game budget backup');
    }
    final Object? warned = data['warnedDay'];
    if (warned != null &&
        (warned is! String ||
            !RegExp(r'^\d{4}-\d{1,2}-\d{1,2}$').hasMatch(warned))) {
      throw ArgumentError('Invalid warning day');
    }
    await _configure(
      enabled: data['enabled']! as bool,
      maxMinutes: data['maxMinutes']! as int,
      warningMinutes: data['warningMinutes']! as int,
      targets: List<String>.from(targets),
      warnedDay: warned as String?,
    );
  });

  Future<bool> _settingsLocked() async =>
      !await UsageLimitPolicyService.instance.canEditLimitsNow() ||
      await LockPolicyService.instance.isEffectivelyLocked(
        await LocalDatabase.instance.rulesMeta(),
      );

  Future<Map<String, Object?>> status() => _exclusive(() async {
    await _load();
    return <String, Object?>{
      ...await _status(),
      'settingsLocked': await (_lockedOverride?.call() ?? _settingsLocked()),
    };
  });
  Future<void> refresh() => _exclusive(() async {
    await _load();
    await _status();
  });

  Future<Map<String, Object?>> _status() async {
    final DateTime now = _now;
    final int used = await _read(now);
    final int remaining = (_maxSeconds - used).clamp(0, _maxSeconds);
    final bool enabled = _config!['enabled'] == true;
    final bool locked = enabled && used >= _maxSeconds;
    final String today = _day(now);
    final Set<String> before = _lockedTargets;
    _lockDay = today;
    _lockedTargets = locked ? _targets.toSet() : <String>{};
    if (_loadOverride == null &&
        (before.length != _lockedTargets.length ||
            !before.containsAll(_lockedTargets))) {
      // Only update the existing process layer on a transition, never run
      // browser/hosts/DNS repair every foreground accounting sample.
      BlockSyncService.instance.syncAppTargetsNow();
    }
    if (enabled &&
        _warningSeconds > 0 &&
        remaining > 0 &&
        remaining <= _warningSeconds &&
        _config!['warnedDay'] != today) {
      // Persist before delivering so process restarts/concurrent samples cannot repeat today's warning.
      _config!['warnedDay'] = _day(now);
      await _save();
      if (_notifyOverride != null) {
        await _notifyOverride(remaining, used, _maxSeconds);
      } else {
        await Future<void>.sync(
          () => AppBlockUserNoticeService.instance.notifyGameBudgetWarning(
            remainingSeconds: remaining,
            usedSeconds: used,
            maxSeconds: _maxSeconds,
          ),
        );
      }
    }
    if (locked && _config!['exhaustedDay'] != today) {
      // Record before showing UI so refreshes and process restarts cannot
      // repeat the end-of-budget notice during the same day.
      _config!['exhaustedDay'] = today;
      await _save();
      await AppBlockUserNoticeService.instance.notifyGameBudgetExhausted(
        usedSeconds: used,
        maxSeconds: _maxSeconds,
      );
    }
    return <String, Object?>{
      'enabled': enabled,
      'maxMinutes': _config!['maxMinutes'],
      'warningMinutes': _config!['warningMinutes'],
      'targets': _targets,
      'subject': subject,
      'usedSeconds': used,
      'remainingSeconds': remaining,
      'maxSeconds': _maxSeconds,
      'warningSeconds': _warningSeconds,
      'warnedToday': _config!['warnedDay'] == today,
      'locked': locked,
      'resetAt': _nextMidnight(now).toIso8601String(),
      'accounting':
          'pooled foreground; exact process names; local calendar day',
      'lastObservedExecutable': _lastObservedExecutable,
      'lastObservedAt': _lastObservedAt?.toIso8601String(),
    };
  }

  Set<String> get lockedTargets => _lockDay == _day(_now)
      ? Set<String>.unmodifiable(_lockedTargets)
      : const <String>{};
  bool isProcessLocked(String executable) =>
      lockedTargets.contains(canonicalExe(executable));

  static bool isExcludedExecutable(String executable) {
    final String exe = canonicalExe(executable);
    return _neverGames.contains(exe) || exe.startsWith('unitycrashhandler');
  }

  /// Unknown applications are never assumed to be games just because they
  /// became foreground. Ask only when a strong game-install path or a common
  /// Unreal shipping executable signature supports that classification.
  static bool isLikelyGameExecutable(
    String executable, {
    String? executablePath,
  }) {
    final String exe = canonicalExe(executable);
    if (!RegExp(r'^[a-z0-9_. -]+\.exe$').hasMatch(exe) ||
        isExcludedExecutable(exe)) {
      return false;
    }
    if (_shippedGameExecutable.hasMatch(exe)) return true;
    final String path = (executablePath ?? '').toLowerCase().replaceAll(
      '/',
      r'\',
    );
    return _gameInstallPathMarkers.any(path.contains);
  }

  /// Claims a one-time question for an unfamiliar foreground program. It is
  /// never counted until the user explicitly adds it to the game list. A
  /// prompt is limited to executables with a strong game-path/name signal.
  Future<bool> claimFirstRunQuestion(
    String executable, {
    String? executablePath,
  }) => _exclusive(() async {
    await _load();
    final String exe = canonicalExe(executable);
    if (_config!['enabled'] != true ||
        !isLikelyGameExecutable(exe, executablePath: executablePath) ||
        _targets.contains(exe)) {
      return false;
    }
    final List<String> asked = List<String>.from(
      _config!['firstRunQuestions'] as List? ?? const <String>[],
    );
    if (asked.contains(exe)) return false;
    asked.add(exe);
    _config!['firstRunQuestions'] = asked;
    await _save();
    return true;
  });

  Future<Map<String, Object?>> includeFirstRunGame(String executable) =>
      _exclusive(() async {
        await _load();
        final String exe = canonicalExe(executable);
        if (!RegExp(r'^[a-z0-9_. -]+\.exe$').hasMatch(exe) ||
            isExcludedExecutable(exe)) {
          throw ArgumentError(
            'This executable is not eligible for game limits',
          );
        }
        final List<String> next = <String>{..._targets, exe}.toList()..sort();
        return _configure(
          enabled: true,
          maxMinutes: _config!['maxMinutes'] as int,
          warningMinutes: _config!['warningMinutes'] as int,
          targets: next,
        );
      });

  /// Called only for a foreground interval verified by UsageTrackingService.
  /// True replaces the ordinary per-app row, avoiding double counting global usage.
  Future<bool> onForegroundUsage({
    required String bundleId,
    required int seconds,
    required DateTime observedAt,
  }) => _exclusive(() async {
    await _load();
    _lastObservedExecutable = canonicalExe(bundleId);
    _lastObservedAt = observedAt;
    if (_config!['enabled'] != true ||
        isExcludedExecutable(bundleId) ||
        !_targets.contains(canonicalExe(bundleId))) {
      return false;
    }
    if (seconds <= 0 || seconds > 90) {
      return true; // Ignore sleep/debugger gaps, never fabricate game minutes.
    }
    final DateTime start = observedAt.subtract(Duration(seconds: seconds));
    final DateTime today = _midnight(observedAt);
    if (start.isBefore(today)) {
      final int before = today.difference(start).inSeconds;
      if (before > 0) {
        await _writeWithinDailyLimit(
          before,
          today.subtract(const Duration(milliseconds: 1)),
        );
      }
      final int after = seconds - before;
      if (after > 0) await _writeWithinDailyLimit(after, observedAt);
    } else {
      await _writeWithinDailyLimit(seconds, observedAt);
    }
    await _status();
    return true;
  });
}
