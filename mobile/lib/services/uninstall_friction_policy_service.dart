import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'windows_hidden_process.dart';

/// Active uninstall-assistant countdown (survives app close / rebuild; cleared on reboot).
final class UninstallActiveSession {
  const UninstallActiveSession({
    required this.endsAt,
    required this.fullSec,
    required this.usingFullFriction,
  });

  final DateTime endsAt;
  final int fullSec;
  final bool usingFullFriction;

  int get remainingSec {
    final int r = endsAt.difference(DateTime.now()).inSeconds;
    return r < 0 ? 0 : r;
  }

  bool get isComplete => !DateTime.now().isBefore(endsAt);
}

/// Configurable uninstall-assistant wait + anti-circumvention.
///
/// * Countdown persists on disk until it finishes or the PC reboots.
/// * Wait duration may be **increased** anytime.
/// * **Shortening** the wait requires sitting through the current wait length first.
final class UninstallFrictionPolicyService {
  UninstallFrictionPolicyService._();
  static final UninstallFrictionPolicyService instance =
      UninstallFrictionPolicyService._();

  static const String _kWaitSec = 'uninstall_wait_seconds_v1';
  static const String _kShortenLockUntilMs =
      'uninstall_wait_edit_lock_until_ms_v1';
  static const String _kFrictionEnforced = 'uninstall_friction_enforced_v1';

  static const String _kSessionEndsAtMs = 'uninstall_session_ends_at_ms_v1';
  static const String _kSessionFullSec = 'uninstall_session_full_sec_v1';
  static const String _kSessionBootTick = 'uninstall_session_boot_tick_ms_v1';
  static const String _kSessionFullFriction =
      'uninstall_session_full_friction_v1';

  static const String _sessionFileName = 'uninstall_session_v1.json';

  static const String _kRemovalAuthorized = 'uninstall_removal_authorized_v1';
  static const String _kRemovalBootTick = 'uninstall_removal_boot_tick_v1';
  static const String _removalAuthFileName = 'removal_authorized_v1.json';

  /// Minimum uninstall wait (30 minutes). No 5-minute emergency shortcuts.
  static const int kMinWaitSec = 1800;

  /// Default full wait — 1 hour (not 30 minutes).
  static const int kDefaultWaitSec = 3600;

  /// Presets shown in Settings (seconds). All ≥ 30 minutes.
  static const List<int> kPresetSeconds = <int>[
    3600,
    7200,
    10800,
    21600,
    86400,
  ];

  static String _markerDir() {
    final String? la = Platform.environment['LOCALAPPDATA'];
    if (la != null && la.isNotEmpty) {
      return p.join(la, 'SixVPNBlocker');
    }
    final String? home = Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      return p.join(home, 'Library', 'Application Support', 'SixVPNBlocker');
    }
    return p.join(Directory.systemTemp.path, 'SixVPNBlocker');
  }

  static String _sessionFilePath() =>
      p.join(_markerDir(), _sessionFileName);

  /// Full uninstall wait is always enforced — no short/emergency bypass.
  Future<bool> isFrictionEnforced() async => true;

  /// Set when the uninstall-assistant timer completes (valid until reboot).
  Future<void> markRemovalAuthorized() async {
    final int? bootTick = await _readBootTickMs();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kRemovalAuthorized, true);
    if (bootTick != null) {
      await prefs.setInt(_kRemovalBootTick, bootTick);
    } else {
      await prefs.remove(_kRemovalBootTick);
    }
    await _writeRemovalAuthFile(bootTick);
  }

  /// True only after uninstall timer finished this boot session.
  Future<bool> isRemovalAuthorized() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(_kRemovalAuthorized) ?? false)) return false;
    final int? stored = prefs.getInt(_kRemovalBootTick);
    if (!await _bootTickStillValid(stored)) {
      await clearRemovalAuthorization();
      return false;
    }
    return true;
  }

  /// Autostart off / manual exe delete allowed only after timer + no active session.
  Future<bool> canDisableAutostartForRemoval() async {
    if (await loadActiveSession() != null) return false;
    return isRemovalAuthorized();
  }

  Future<void> clearRemovalAuthorization() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kRemovalAuthorized);
    await prefs.remove(_kRemovalBootTick);
    try {
      final File f = File(p.join(_markerDir(), _removalAuthFileName));
      if (await f.exists()) await f.delete();
    } catch (_) {/* best-effort */}
  }

  Future<void> _writeRemovalAuthFile(int? bootTick) async {
    try {
      final String dir = _markerDir();
      await Directory(dir).create(recursive: true);
      await File(p.join(dir, _removalAuthFileName)).writeAsString(
        jsonEncode(<String, Object?>{
          'authorized': true,
          'authorizedAt': DateTime.now().toUtc().toIso8601String(),
          if (bootTick != null) 'bootTickMs': bootTick,
        }),
        flush: true,
      );
    } catch (_) {/* prefs still hold flag */}
  }

  Future<void> setFrictionEnforced(bool value) async {
    if (!value) return;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kFrictionEnforced, true);
  }

  Future<int> getWaitSeconds() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final int v = prefs.getInt(_kWaitSec) ?? kDefaultWaitSec;
    return v.clamp(kMinWaitSec, 86400 * 7);
  }

  Future<void> setWaitSeconds(int seconds) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kWaitSec, seconds.clamp(kMinWaitSec, 86400 * 7));
  }

  Future<DateTime?> shortenLockUntil() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final int? ms = prefs.getInt(_kShortenLockUntilMs);
    if (ms == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// @deprecated Use [shortenLockUntil].
  Future<DateTime?> editLockUntil() => shortenLockUntil();

  /// Whether the wait may be **shortened** in Settings right now.
  Future<bool> canShortenWaitDurationNow() async {
    final DateTime? u = await shortenLockUntil();
    if (u == null) return true;
    return !DateTime.now().isBefore(u);
  }

  /// Whether any wait-duration edit is allowed (legacy — prefer direction checks).
  Future<bool> canChangeWaitDurationNow() async => canShortenWaitDurationNow();

  /// After picking a new wait length, block **shortening** until that length elapses.
  Future<void> lockShortenForCurrentWait(int waitSeconds) async {
    final DateTime until =
        DateTime.now().add(Duration(seconds: waitSeconds.clamp(kMinWaitSec, 86400 * 7)));
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kShortenLockUntilMs, until.millisecondsSinceEpoch);
  }

  /// Try to change wait duration. Increases always apply; decreases need [canShortenWaitDurationNow].
  Future<UninstallWaitChangeResult> trySetWaitSeconds(int newSec) async {
    final int clamped = newSec.clamp(kMinWaitSec, 86400 * 7);
    final int current = await getWaitSeconds();
    if (clamped == current) {
      return const UninstallWaitChangeResult(ok: true, increased: false);
    }
    if (clamped > current) {
      await setWaitSeconds(clamped);
      await lockShortenForCurrentWait(clamped);
      return const UninstallWaitChangeResult(ok: true, increased: true);
    }
    if (!await canShortenWaitDurationNow()) {
      return UninstallWaitChangeResult(
        ok: false,
        increased: false,
        blockedUntil: await shortenLockUntil(),
      );
    }
    await setWaitSeconds(clamped);
    await lockShortenForCurrentWait(clamped);
    return const UninstallWaitChangeResult(ok: true, increased: false);
  }

  // ---- Persistent uninstall countdown (survives close / rebuild) ----

  Future<UninstallActiveSession?> loadActiveSession() async {
    final Map<String, Object?>? map = await _readSessionMap();
    if (map == null) return null;

    final int? bootTick = _asIntOrNull(map['bootTickMs']);
    if (!await _bootTickStillValid(bootTick)) {
      await clearSession();
      return null;
    }

    final int endsMs = _asInt(map['endsAtMs'], 0);
    if (endsMs <= 0) {
      await clearSession();
      return null;
    }
    final DateTime endsAt = DateTime.fromMillisecondsSinceEpoch(endsMs);
    if (!DateTime.now().isBefore(endsAt)) {
      await markRemovalAuthorized();
      await clearSession();
      return null;
    }

    return UninstallActiveSession(
      endsAt: endsAt,
      fullSec: _asInt(map['fullSec'], kDefaultWaitSec),
      usingFullFriction: map['usingFullFriction'] != false,
    );
  }

  Future<void> startSession({
    required int durationSec,
    required bool usingFullFriction,
  }) async {
    final int sec = durationSec.clamp(1, 86400 * 7);
    final DateTime endsAt = DateTime.now().add(Duration(seconds: sec));
    final int? bootTick = await _readBootTickMs();

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kSessionEndsAtMs, endsAt.millisecondsSinceEpoch);
    await prefs.setInt(_kSessionFullSec, sec);
    await prefs.setBool(_kSessionFullFriction, usingFullFriction);
    if (bootTick != null) {
      await prefs.setInt(_kSessionBootTick, bootTick);
    } else {
      await prefs.remove(_kSessionBootTick);
    }

    await _writeSessionFile(<String, Object?>{
      'endsAtMs': endsAt.millisecondsSinceEpoch,
      'fullSec': sec,
      'usingFullFriction': usingFullFriction,
      if (bootTick != null) 'bootTickMs': bootTick,
    });
  }

  /// User cancelled the uninstall countdown — clears disk + prefs session.
  Future<void> cancelSession() async => clearSession();

  Future<void> clearSession() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kSessionEndsAtMs);
    await prefs.remove(_kSessionFullSec);
    await prefs.remove(_kSessionBootTick);
    await prefs.remove(_kSessionFullFriction);
    try {
      final File f = File(_sessionFilePath());
      if (await f.exists()) await f.delete();
    } catch (_) {/* best-effort */}
  }

  Future<Map<String, Object?>> toBackupMap() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final int wait =
        (prefs.getInt(_kWaitSec) ?? kDefaultWaitSec).clamp(kMinWaitSec, 86400 * 7);
    final int? lockMs = prefs.getInt(_kShortenLockUntilMs);
    final bool enforced = prefs.getBool(_kFrictionEnforced) ?? true;
    final Map<String, Object?> out = <String, Object?>{
      'waitSeconds': wait,
      'frictionEnforced': enforced,
    };
    if (lockMs != null) {
      out['editLockUntilMs'] = lockMs;
      out['shortenLockUntilMs'] = lockMs;
    }
    final UninstallActiveSession? session = await loadActiveSession();
    if (session != null) {
      out['activeSession'] = <String, Object?>{
        'endsAtMs': session.endsAt.millisecondsSinceEpoch,
        'fullSec': session.fullSec,
        'usingFullFriction': session.usingFullFriction,
        'bootTickMs': prefs.getInt(_kSessionBootTick),
      };
    }
    return out;
  }

  Future<void> restoreFromBackupMap(Object? raw) async {
    if (raw is! Map) return;
    final Map<String, Object?> m = raw.map<String, Object?>(
      (Object? k, Object? v) => MapEntry<String, Object?>(k.toString(), v),
    );
    final int wait = _asInt(m['waitSeconds'], kDefaultWaitSec).clamp(kMinWaitSec, 86400 * 7);
    await setWaitSeconds(wait);
    await setFrictionEnforced(true);
    final int? lockMs = _asIntOrNull(m['shortenLockUntilMs']) ??
        _asIntOrNull(m['editLockUntilMs']);
    if (lockMs == null || lockMs <= 0) {
      await _clearShortenLock();
    } else {
      final DateTime until = DateTime.fromMillisecondsSinceEpoch(lockMs);
      if (until.isAfter(DateTime.now())) {
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        await prefs.setInt(_kShortenLockUntilMs, lockMs);
      } else {
        await _clearShortenLock();
      }
    }

    final Object? sess = m['activeSession'];
    if (sess is Map) {
      final Map<String, Object?> sm = sess.map<String, Object?>(
        (Object? k, Object? v) => MapEntry<String, Object?>(k.toString(), v),
      );
      await _writeSessionFile(sm);
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final int endsMs = _asInt(sm['endsAtMs'], 0);
      if (endsMs > 0) {
        await prefs.setInt(_kSessionEndsAtMs, endsMs);
        await prefs.setInt(_kSessionFullSec, _asInt(sm['fullSec'], wait));
        await prefs.setBool(
          _kSessionFullFriction,
          sm['usingFullFriction'] != false,
        );
        final int? bt = _asIntOrNull(sm['bootTickMs']);
        if (bt != null) {
          await prefs.setInt(_kSessionBootTick, bt);
        }
      }
      if (!await canResumeRestoredSession()) {
        await clearSession();
      }
    }
  }

  Future<bool> canResumeRestoredSession() async {
    return (await loadActiveSession()) != null;
  }

  Future<void> _clearShortenLock() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kShortenLockUntilMs);
  }

  Future<Map<String, Object?>?> _readSessionMap() async {
    Map<String, Object?>? fromFile;
    try {
      final File f = File(_sessionFilePath());
      if (await f.exists()) {
        final Object? decoded = json.decode(await f.readAsString());
        if (decoded is Map) {
          fromFile = decoded.map<String, Object?>(
            (Object? k, Object? v) => MapEntry<String, Object?>(k.toString(), v),
          );
        }
      }
    } catch (_) {/* fall through */}

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final int? endsMs = prefs.getInt(_kSessionEndsAtMs);
    if (endsMs == null && fromFile == null) return null;

    return <String, Object?>{
      'endsAtMs': endsMs ?? _asInt(fromFile?['endsAtMs'], 0),
      'fullSec': prefs.getInt(_kSessionFullSec) ??
          _asInt(fromFile?['fullSec'], kDefaultWaitSec),
      'usingFullFriction': prefs.getBool(_kSessionFullFriction) ??
          (fromFile?['usingFullFriction'] != false),
      'bootTickMs': prefs.getInt(_kSessionBootTick) ??
          _asIntOrNull(fromFile?['bootTickMs']),
    };
  }

  Future<void> _writeSessionFile(Map<String, Object?> map) async {
    try {
      final String dir = _markerDir();
      await Directory(dir).create(recursive: true);
      await File(_sessionFilePath()).writeAsString(
        const JsonEncoder.withIndent('  ').convert(map),
        flush: true,
      );
    } catch (_) {/* prefs still hold session */}
  }

  Future<bool> _bootTickStillValid(int? storedBootTick) async {
    if (storedBootTick == null) return true;
    final int? current = await _readBootTickMs();
    if (current == null) return true;
    return current >= storedBootTick;
  }

  Future<int?> _readBootTickMs() async {
    if (Platform.isWindows) {
      try {
        final ProcessResult r = await windowsRunHidden(
          'powershell',
          <String>[
            '-NoProfile',
            '-Command',
            '[uint64]((Get-Date) - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalMilliseconds',
          ],
        );
        if (r.exitCode != 0) return null;
        return int.tryParse((r.stdout as String).trim());
      } catch (_) {
        return null;
      }
    }
    if (Platform.isMacOS) {
      try {
        final ProcessResult r = Process.runSync('sysctl', <String>['-n', 'kern.boottime']);
        if (r.exitCode != 0) return null;
        final String out = (r.stdout as String).trim();
        final RegExp sec = RegExp(r'sec\s*=\s*(\d+)');
        final Match? m = sec.firstMatch(out);
        if (m == null) return null;
        return int.tryParse(m.group(1) ?? '') ;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  static int _asInt(Object? v, [int fallback = 0]) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? fallback;
    if (v is bool) return v ? 1 : 0;
    return fallback;
  }

  static int? _asIntOrNull(Object? v) {
    if (v == null) return null;
    final int n = _asInt(v, -1);
    return n < 0 ? null : n;
  }
}

final class UninstallWaitChangeResult {
  const UninstallWaitChangeResult({
    required this.ok,
    required this.increased,
    this.blockedUntil,
  });

  final bool ok;
  final bool increased;
  final DateTime? blockedUntil;
}
