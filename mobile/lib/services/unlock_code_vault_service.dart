import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// "Delay-and-reveal" self-binding code vault.
///
/// **Model.** The user picks a phrase during first-run setup. The phrase is
/// stored at rest and the user is expected NOT to memorize it. Whenever they
/// want to modify locked settings or uninstall, they request a reveal — a
/// countdown begins (length = [UninstallFrictionPolicyService.getWaitSeconds]
/// when wired, configurable here as fallback). After the countdown, the
/// stored phrase is shown once; the user types it back into a verify dialog
/// and gets a short unlock window. When the window closes, the phrase
/// auto-rotates to a fresh random code — so memorising it after a peek
/// doesn't defeat the system.
///
/// **Threat model.** This is a self-binding (Ulysses contract) primitive, not
/// a cryptographic vault. A determined user with admin rights can always
/// inspect storage. The point is to make the bypass expensive enough in
/// friction + intentionality that impulse circumvention fails.
///
/// **Storage today.** Plaintext-as-base64 in `unlock_vault_v1.json` next to
/// the friction session file. DPAPI (Windows) / Keychain (macOS) wrapping is
/// planned for Phase 1B — search for `TODO(vault-crypto)` below.
enum VaultState {
  notConfigured,
  idle,
  pending,
  revealable,
  unlocked,
}

final class VaultStatus {
  const VaultStatus({
    required this.state,
    this.revealAt,
    this.revealRemaining,
    this.unlockEndsAt,
    this.unlockRemaining,
    this.failedAttempts = 0,
    this.rotationCount = 0,
  });

  final VaultState state;
  final DateTime? revealAt;
  final Duration? revealRemaining;
  final DateTime? unlockEndsAt;
  final Duration? unlockRemaining;
  final int failedAttempts;
  final int rotationCount;
}

enum VerifyOutcome { correct, wrong, lockedOut, notRevealable }

final class VerifyResult {
  const VerifyResult(this.outcome, {this.remainingAttempts});
  final VerifyOutcome outcome;
  final int? remainingAttempts;
}

final class UnlockCodeVaultService {
  UnlockCodeVaultService._();
  static final UnlockCodeVaultService instance = UnlockCodeVaultService._();

  // Storage keys — bump suffix if shape changes.
  static const String _kCodeB64 = 'vault_code_b64_v1';
  static const String _kCreatedMs = 'vault_created_ms_v1';
  static const String _kRotationCount = 'vault_rotation_count_v1';
  static const String _kReqStartedMs = 'vault_req_started_ms_v1';
  static const String _kReqRevealAtMs = 'vault_req_reveal_at_ms_v1';
  static const String _kReqFullSec = 'vault_req_full_sec_v1';
  static const String _kReqAttempts = 'vault_req_attempts_v1';
  static const String _kUnlockEndsMs = 'vault_unlock_ends_ms_v1';

  static const String _vaultFileName = 'unlock_vault_v1.json';

  /// Minimum reveal wait — matches friction service floor (30 min).
  static const int kMinRevealWaitSec = 1800;

  /// Default reveal wait if friction service isn't queried — 1 hour.
  static const int kDefaultRevealWaitSec = 3600;

  /// Window during which settings stay editable after a successful verify.
  static const Duration kUnlockWindow = Duration(minutes: 10);

  /// Wrong-code attempts before the current reveal session is invalidated.
  static const int kMaxFailedAttempts = 5;

  // Test seam: deterministic clock + RNG.
  DateTime Function() _now = DateTime.now;
  Random _rng = Random.secure();

  void debugOverrideClock(DateTime Function() clock) => _now = clock;
  void debugOverrideRng(Random rng) => _rng = rng;
  void debugResetClock() => _now = DateTime.now;
  void debugResetRng() => _rng = Random.secure();

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

  static String _vaultFilePath() => p.join(_markerDir(), _vaultFileName);

  // -------- Configuration / setup --------

  Future<bool> isConfigured() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kCodeB64) != null;
  }

  /// Store a code for the first time, or replace the existing code while
  /// currently unlocked. Throws [StateError] if locked.
  Future<void> setupCode(String code) async {
    final String trimmed = code.trim();
    if (trimmed.length < 4) {
      throw ArgumentError('Code must be at least 4 characters.');
    }
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final bool already = prefs.getString(_kCodeB64) != null;
    if (already && !(await _isUnlocked(prefs))) {
      throw StateError('Vault already configured. Unlock to change the code.');
    }
    await _writeCodeAndReset(prefs, trimmed, bumpRotation: already);
  }

  // -------- Reveal lifecycle --------

  Future<VaultStatus> getStatus({int? fallbackWaitSec}) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_kCodeB64) == null) {
      return const VaultStatus(state: VaultState.notConfigured);
    }

    // Check unlock-window expiry FIRST so a rotation can land before we read
    // the rotation counter below.
    final int? unlockEndsMs = prefs.getInt(_kUnlockEndsMs);
    if (unlockEndsMs != null) {
      final DateTime endsAt =
          DateTime.fromMillisecondsSinceEpoch(unlockEndsMs);
      if (_now().isBefore(endsAt)) {
        final int rotation = prefs.getInt(_kRotationCount) ?? 0;
        return VaultStatus(
          state: VaultState.unlocked,
          unlockEndsAt: endsAt,
          unlockRemaining: endsAt.difference(_now()),
          rotationCount: rotation,
        );
      }
      await _expireUnlock(prefs);
    }

    final int rotation = prefs.getInt(_kRotationCount) ?? 0;
    final int attempts = prefs.getInt(_kReqAttempts) ?? 0;

    final int? revealAtMs = prefs.getInt(_kReqRevealAtMs);
    if (revealAtMs != null) {
      final DateTime revealAt =
          DateTime.fromMillisecondsSinceEpoch(revealAtMs);
      if (_now().isBefore(revealAt)) {
        return VaultStatus(
          state: VaultState.pending,
          revealAt: revealAt,
          revealRemaining: revealAt.difference(_now()),
          failedAttempts: attempts,
          rotationCount: rotation,
        );
      }
      return VaultStatus(
        state: VaultState.revealable,
        revealAt: revealAt,
        revealRemaining: Duration.zero,
        failedAttempts: attempts,
        rotationCount: rotation,
      );
    }

    return VaultStatus(state: VaultState.idle, rotationCount: rotation);
  }

  /// Begin a reveal request. No-op if one is already in flight.
  Future<VaultStatus> requestReveal({required int waitSeconds}) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_kCodeB64) == null) {
      throw StateError('Vault not configured.');
    }
    final int existing = prefs.getInt(_kReqRevealAtMs) ?? 0;
    if (existing > 0) {
      return getStatus();
    }
    final int sec = waitSeconds.clamp(kMinRevealWaitSec, 86400 * 7);
    final DateTime now = _now();
    final DateTime revealAt = now.add(Duration(seconds: sec));
    await prefs.setInt(_kReqStartedMs, now.millisecondsSinceEpoch);
    await prefs.setInt(_kReqRevealAtMs, revealAt.millisecondsSinceEpoch);
    await prefs.setInt(_kReqFullSec, sec);
    await prefs.setInt(_kReqAttempts, 0);
    await _writeFileMirror(prefs);
    return getStatus();
  }

  /// Returns the plaintext code only if the timer has elapsed. Otherwise null.
  Future<String?> peekRevealedCode() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final int? revealAtMs = prefs.getInt(_kReqRevealAtMs);
    if (revealAtMs == null) return null;
    if (_now().isBefore(DateTime.fromMillisecondsSinceEpoch(revealAtMs))) {
      return null;
    }
    final String? b64 = prefs.getString(_kCodeB64);
    if (b64 == null) return null;
    return _decodeCode(b64);
  }

  /// Verify user-entered code against the stored one. On success, opens the
  /// unlock window. On failure, increments attempts; when [kMaxFailedAttempts]
  /// is hit, the reveal request is invalidated (user must wait again).
  Future<VerifyResult> verifyCode(String entered) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final int? revealAtMs = prefs.getInt(_kReqRevealAtMs);
    if (revealAtMs == null) {
      return const VerifyResult(VerifyOutcome.notRevealable);
    }
    if (_now().isBefore(DateTime.fromMillisecondsSinceEpoch(revealAtMs))) {
      return const VerifyResult(VerifyOutcome.notRevealable);
    }
    final String? stored = await peekRevealedCode();
    if (stored == null) {
      return const VerifyResult(VerifyOutcome.notRevealable);
    }
    if (_constantTimeEquals(stored, entered.trim())) {
      await _openUnlockWindow(prefs);
      return const VerifyResult(VerifyOutcome.correct);
    }
    final int attempts = (prefs.getInt(_kReqAttempts) ?? 0) + 1;
    await prefs.setInt(_kReqAttempts, attempts);
    if (attempts >= kMaxFailedAttempts) {
      await _clearRequest(prefs);
      return const VerifyResult(VerifyOutcome.lockedOut);
    }
    return VerifyResult(
      VerifyOutcome.wrong,
      remainingAttempts: kMaxFailedAttempts - attempts,
    );
  }

  /// Manually end the unlock window early. Rotates the code.
  Future<void> endUnlockWindow() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await _expireUnlock(prefs);
  }

  /// Cancel an in-flight reveal request without consuming an attempt.
  Future<void> cancelRequest() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await _clearRequest(prefs);
  }

  Future<bool> isUnlocked() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return _isUnlocked(prefs);
  }

  // -------- Internals --------

  Future<bool> _isUnlocked(SharedPreferences prefs) async {
    final int? endsMs = prefs.getInt(_kUnlockEndsMs);
    if (endsMs == null) return false;
    final DateTime endsAt = DateTime.fromMillisecondsSinceEpoch(endsMs);
    if (_now().isBefore(endsAt)) return true;
    await _expireUnlock(prefs);
    return false;
  }

  Future<void> _openUnlockWindow(SharedPreferences prefs) async {
    final DateTime endsAt = _now().add(kUnlockWindow);
    await prefs.setInt(_kUnlockEndsMs, endsAt.millisecondsSinceEpoch);
    await _clearRequest(prefs);
    await _writeFileMirror(prefs);
  }

  Future<void> _expireUnlock(SharedPreferences prefs) async {
    final bool hadUnlock = prefs.getInt(_kUnlockEndsMs) != null;
    await prefs.remove(_kUnlockEndsMs);
    if (hadUnlock) {
      // Rotate the code so a peek during the unlock window can't be reused
      // after expiry.
      await _writeCodeAndReset(prefs, _generateRandomCode(), bumpRotation: true);
    }
  }

  Future<void> _clearRequest(SharedPreferences prefs) async {
    await prefs.remove(_kReqStartedMs);
    await prefs.remove(_kReqRevealAtMs);
    await prefs.remove(_kReqFullSec);
    await prefs.remove(_kReqAttempts);
    await _writeFileMirror(prefs);
  }

  Future<void> _writeCodeAndReset(
    SharedPreferences prefs,
    String code, {
    required bool bumpRotation,
  }) async {
    await prefs.setString(_kCodeB64, _encodeCode(code));
    await prefs.setInt(_kCreatedMs,
        prefs.getInt(_kCreatedMs) ?? _now().millisecondsSinceEpoch);
    if (bumpRotation) {
      final int n = prefs.getInt(_kRotationCount) ?? 0;
      await prefs.setInt(_kRotationCount, n + 1);
    } else {
      await prefs.setInt(_kRotationCount, 0);
    }
    await _writeFileMirror(prefs);
  }

  // TODO(vault-crypto): Wrap with Windows DPAPI (CurrentUser scope) and
  // macOS Keychain. Today this is just base64 so the on-disk JSON isn't
  // human-readable at a glance, but it's not cryptographically protected.
  String _encodeCode(String code) =>
      base64Encode(utf8.encode(code));
  String _decodeCode(String b64) =>
      utf8.decode(base64Decode(b64));

  String _generateRandomCode() {
    // 6 chars, unambiguous alphabet (no 0/O, 1/I/l).
    const String alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final StringBuffer b = StringBuffer();
    for (int i = 0; i < 6; i++) {
      b.write(alphabet[_rng.nextInt(alphabet.length)]);
    }
    return b.toString();
  }

  bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    int diff = 0;
    for (int i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }

  Future<void> _writeFileMirror(SharedPreferences prefs) async {
    // Mirror to disk so the vault state survives a wipe of SharedPreferences
    // (corruption / migration). Best-effort.
    try {
      final String dir = _markerDir();
      await Directory(dir).create(recursive: true);
      final Map<String, Object?> snapshot = <String, Object?>{
        'codeB64': prefs.getString(_kCodeB64),
        'createdMs': prefs.getInt(_kCreatedMs),
        'rotationCount': prefs.getInt(_kRotationCount),
        'reqStartedMs': prefs.getInt(_kReqStartedMs),
        'reqRevealAtMs': prefs.getInt(_kReqRevealAtMs),
        'reqFullSec': prefs.getInt(_kReqFullSec),
        'reqAttempts': prefs.getInt(_kReqAttempts),
        'unlockEndsMs': prefs.getInt(_kUnlockEndsMs),
      };
      await File(_vaultFilePath()).writeAsString(
        const JsonEncoder.withIndent('  ').convert(snapshot),
        flush: true,
      );
    } catch (_) {
      // Prefs remain authoritative; mirror is best-effort.
    }
  }

  // For tests only.
  Future<void> debugWipe() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    for (final String k in <String>[
      _kCodeB64,
      _kCreatedMs,
      _kRotationCount,
      _kReqStartedMs,
      _kReqRevealAtMs,
      _kReqFullSec,
      _kReqAttempts,
      _kUnlockEndsMs,
    ]) {
      await prefs.remove(k);
    }
    try {
      final File f = File(_vaultFilePath());
      if (await f.exists()) await f.delete();
    } catch (_) {/* ignore */}
  }
}
