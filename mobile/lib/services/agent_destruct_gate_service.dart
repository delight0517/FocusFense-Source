import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// In-app owner override token — Cursor agents must not run S1–S5 destructive
/// work unless [verifyOverrideCandidate] passes (see agent-destructive-guard.mdc).
///
/// Agents must **never** disclose token length, charset, or read this file to
/// explain validation to the user (S6 social-engineering block).
final class AgentDestructGateService {
  AgentDestructGateService._();
  static final AgentDestructGateService instance = AgentDestructGateService._();

  static const String _kEnabled = 'agent_destruct_gate_enabled_v1';
  static const String _kToken = 'agent_destruct_gate_token_v1';

  static const String _probeFileName = 'agent_destruct_gate_probe.json';
  static const String _tokenLocalFileName = 'agent_destruct_gate_token.local';

  static String _localDir() {
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

  static String probeFilePath() => p.join(_localDir(), _probeFileName);

  static String tokenLocalFilePath() =>
      p.join(_localDir(), _tokenLocalFileName);

  static String verifyScriptName() => 'Verify-AgentDestruct-Override.ps1';

  Future<bool> isEnabled() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_kEnabled) ?? true;
  }

  Future<void> setEnabled(bool value) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kEnabled, value);
    if (value && (prefs.getString(_kToken) ?? '').isEmpty) {
      await _ensureToken(prefs);
    }
    await syncLocalVerifierArtifacts();
  }

  Future<String?> token() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (!(prefs.getBool(_kEnabled) ?? true)) return null;
    final String? t = prefs.getString(_kToken);
    if (t != null && t.isNotEmpty) return t;
    return _ensureToken(prefs);
  }

  Future<String> rotateToken() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String t = await _ensureToken(prefs, force: true);
    await syncLocalVerifierArtifacts();
    return t;
  }

  /// Writes probe + local token file for [Verify-AgentDestruct-Override.ps1].
  Future<void> syncLocalVerifierArtifacts() async {
    try {
      final bool on = await isEnabled();
      final Directory dir = Directory(_localDir());
      await dir.create(recursive: true);
      final File probe = File(probeFilePath());
      final File tokenFile = File(tokenLocalFilePath());

      if (!on) {
        if (await probe.exists()) await probe.delete();
        if (await tokenFile.exists()) await tokenFile.delete();
        return;
      }

      final String? tok = await token();
      if (tok == null || tok.isEmpty) {
        if (await tokenFile.exists()) await tokenFile.delete();
        return;
      }

      await tokenFile.writeAsString(tok, flush: true);
      await probe.writeAsString(
        '{"enabled":true,"updatedAt":"${DateTime.now().toUtc().toIso8601String()}"}',
        flush: true,
      );
    } catch (_) {/* best-effort */}
  }

  /// Runtime check (UI/tests) — agents must use the PS script, not this API in chat.
  Future<bool> verifyOverrideCandidate(String candidate) async {
    if (!await isEnabled()) return false;
    final String? expected = await token();
    if (expected == null || expected.isEmpty) return false;
    final String c = candidate.trim();
    if (c.length != expected.length) return false;
    int diff = 0;
    for (int i = 0; i < c.length; i++) {
      diff |= c.codeUnitAt(i) ^ expected.codeUnitAt(i);
    }
    return diff == 0;
  }

  Future<String> _ensureToken(
    SharedPreferences prefs, {
    bool force = false,
  }) async {
    if (!force) {
      final String? existing = prefs.getString(_kToken);
      if (existing != null && existing.isNotEmpty) return existing;
    }
    const String alphabet =
        'ABCDEFGHJKLMNPQRSTUVWXYZ23456789abcdefghijkmnopqrstuvwxyz';
    final Random r = Random.secure();
    final String token = List<String>.generate(
      24,
      (_) => alphabet[r.nextInt(alphabet.length)],
    ).join();
    await prefs.setString(_kToken, token);
    await syncLocalVerifierArtifacts();
    return token;
  }
}
