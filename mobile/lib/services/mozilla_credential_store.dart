// Credential workflow, not an enforcement layer. Compatible with the existing
// Python DPAPI vault; backups are usable only by the original Windows profile.
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';
import 'windows_hidden_process.dart';

class MozillaCredentialException implements Exception {
  final String message;
  const MozillaCredentialException(this.message);
  @override
  String toString() => message;
}

class MozillaCredentials {
  final String issuer;
  final String secret;
  const MozillaCredentials(this.issuer, this.secret);
  @override
  String toString() => 'MozillaCredentials([redacted])';
}

class MozillaCredentialStatus {
  final bool exists;
  final bool readable;
  final String path;
  const MozillaCredentialStatus(this.exists, this.readable, this.path);
}

class MozillaCredentialBackup {
  final String path;
  final String sha256;
  // A write to a Drive Desktop folder does not prove a cloud upload completed.
  final bool cloudUploadVerified = false;
  const MozillaCredentialBackup(this.path, this.sha256);
}

class MozillaCredentialStore {
  static const expectedAccount = String.fromEnvironment('FOCUSFENSE_MOZILLA_ACCOUNT', defaultValue: 'developer@example.invalid');
  static const addonId = 'sixvpn-blocker@sixvpnblocker.app';
  static const _purpose = 'FocusFense/MozillaAMO/credentials/v1';
  static const _wrappingQuotes = <int>{
    0x22, // "
    0x27, // '
    0x60, // `
    0x2018, // ‘
    0x2019, // ’
    0x201c, // “
    0x201d, // ”
  };
  final String storePath;
  final String backupDirectory;

  MozillaCredentialStore({String? storePath, String? backupDirectory})
    : storePath =
          storePath ??
          p.join(
            Platform.environment['LOCALAPPDATA']!,
            'FocusFense',
            'credentials',
            'mozilla-amo.dpapi.json',
          ),
      backupDirectory =
          backupDirectory ??
          p.join(
            Platform.environment['USERPROFILE']!,
            'Documents',
            'FocusFence Canonical Backups',
            'credentials',
            'mozilla-amo',
          );

  static Never _invalid() => throw const MozillaCredentialException(
    'Mozilla 자격증명을 확인할 수 없습니다. 계정, 파일 및 원래 Windows 프로필을 확인해 주세요.',
  );

  /// Removes copy/paste wrappers and whitespace without changing credential
  /// characters. Mozilla issuer and secret values are both whitespace-free.
  static String normalizeInput(String value) {
    var normalized = value.trim();
    while (normalized.isNotEmpty &&
        _wrappingQuotes.contains(normalized.codeUnitAt(0))) {
      normalized = normalized.substring(1).trimLeft();
    }
    while (normalized.isNotEmpty &&
        _wrappingQuotes.contains(
          normalized.codeUnitAt(normalized.length - 1),
        )) {
      normalized = normalized.substring(0, normalized.length - 1).trimRight();
    }
    return normalized.replaceAll(RegExp(r'\s+'), '');
  }

  static void _identity(Map<String, dynamic> value) {
    if (value['schema'] != 1 ||
        value['account'] != expectedAccount ||
        value['addonId'] != addonId) {
      _invalid();
    }
  }

  static List<int> _crypt(List<int> bytes, {bool decrypt = false}) {
    if (!Platform.isWindows) _invalid();
    final input = calloc<CRYPT_INTEGER_BLOB>();
    final entropy = calloc<CRYPT_INTEGER_BLOB>();
    final output = calloc<CRYPT_INTEGER_BLOB>();
    final purpose = utf8.encode(_purpose);
    input.ref.cbData = bytes.length;
    input.ref.pbData = calloc<Uint8>(bytes.length);
    entropy.ref.cbData = purpose.length;
    entropy.ref.pbData = calloc<Uint8>(purpose.length);
    input.ref.pbData.asTypedList(bytes.length).setAll(0, bytes);
    entropy.ref.pbData.asTypedList(purpose.length).setAll(0, purpose);
    try {
      final ok = decrypt
          ? CryptUnprotectData(
              input,
              nullptr,
              entropy,
              nullptr,
              nullptr,
              1,
              output,
            )
          : CryptProtectData(
              input,
              nullptr,
              entropy,
              nullptr,
              nullptr,
              1,
              output,
            );
      if (ok == 0) _invalid();
      return List<int>.from(output.ref.pbData.asTypedList(output.ref.cbData));
    } finally {
      input.ref.pbData.asTypedList(bytes.length).fillRange(0, bytes.length, 0);
      if (output.ref.pbData != nullptr) {
        output.ref.pbData
            .asTypedList(output.ref.cbData)
            .fillRange(0, output.ref.cbData, 0);
        LocalFree(output.ref.pbData);
      }
      calloc.free(input.ref.pbData);
      calloc.free(entropy.ref.pbData);
      calloc.free(input);
      calloc.free(entropy);
      calloc.free(output);
    }
  }

  static MozillaCredentials _decode(List<int> bytes) {
    try {
      final outer = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      _identity(outer);
      if (outer['protection'] != 'Windows-DPAPI-CurrentUser') _invalid();
      final clear = _crypt(
        base64Decode(outer['ciphertext'] as String),
        decrypt: true,
      );
      try {
        final inner = jsonDecode(utf8.decode(clear)) as Map<String, dynamic>;
        _identity(inner);
        final issuer = inner['issuer'];
        final secret = inner['secret'];
        if (issuer is! String ||
            secret is! String ||
            issuer.trim().isEmpty ||
            secret.trim().isEmpty) {
          _invalid();
        }
        return MozillaCredentials(issuer, secret);
      } finally {
        clear.fillRange(0, clear.length, 0);
      }
    } catch (_) {
      _invalid();
    }
  }

  Future<MozillaCredentials> load() async {
    try {
      return _decode(await File(storePath).readAsBytes());
    } catch (_) {
      _invalid();
    }
  }

  Future<MozillaCredentialStatus> status() async {
    final exists = await File(storePath).exists();
    var readable = false;
    if (exists) {
      try {
        await load();
        readable = true;
      } catch (_) {}
    }
    return MozillaCredentialStatus(exists, readable, storePath);
  }

  Future<void> save({
    required String issuer,
    required String secret,
    String account = expectedAccount,
  }) async {
    final normalizedIssuer = normalizeInput(issuer);
    final normalizedSecret = normalizeInput(secret);
    if (account != expectedAccount ||
        normalizedIssuer.isEmpty ||
        normalizedSecret.isEmpty) {
      _invalid();
    }
    final plain = utf8.encode(
      jsonEncode({
        'schema': 1,
        'account': account,
        'addonId': addonId,
        'issuer': normalizedIssuer,
        'secret': normalizedSecret,
      }),
    );
    late List<int> encrypted;
    try {
      encrypted = _crypt(plain);
    } finally {
      plain.fillRange(0, plain.length, 0);
    }
    final bytes = utf8.encode(
      jsonEncode({
        'schema': 1,
        'account': account,
        'addonId': addonId,
        'createdAtUtc': DateTime.now().toUtc().toIso8601String(),
        'protection': 'Windows-DPAPI-CurrentUser',
        'ciphertext': base64Encode(encrypted),
      }),
    );
    _decode(bytes);
    await _replace(bytes);
  }

  Future<void> _replace(List<int> bytes) async {
    final target = File(storePath);
    await target.parent.create(recursive: true);
    if (await target.exists()) await backupCiphertext();
    final temporary = File(
      '$storePath.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await temporary.create(exclusive: true);
      await _restrict(temporary.path);
      await temporary.writeAsBytes(bytes, flush: true);
      _decode(await temporary.readAsBytes());
      await temporary.rename(storePath);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  static Future<void> _restrict(String path) async {
    // Only non-secret paths/SID reach child arguments; no Python is required.
    final identity = await windowsRunHidden('whoami.exe', [
      '/user',
      '/fo',
      'csv',
      '/nh',
    ]);
    final sid = RegExp(
      r'S-1-\d+(?:-\d+)+',
    ).firstMatch('${identity.stdout}')?.group(0);
    if (identity.exitCode != 0 || sid == null) _invalid();
    final result = await windowsRunHidden('icacls.exe', [
      path,
      '/inheritance:r',
      '/grant:r',
      '*$sid:F',
    ]);
    if (result.exitCode != 0) _invalid();
  }

  Future<MozillaCredentialBackup> backupCiphertext({String? directory}) async {
    final bytes = await File(storePath).readAsBytes();
    _decode(bytes);
    final root = Directory(directory ?? backupDirectory);
    await root.create(recursive: true);
    final target = File(
      p.join(
        root.path,
        'mozilla-amo-${DateTime.now().toUtc().microsecondsSinceEpoch}.dpapi.json',
      ),
    );
    await target.create(exclusive: true);
    try {
      await _restrict(target.path);
    } catch (_) {
      // Drive Desktop virtual filesystems may not implement NTFS ACLs. Only
      // CurrentUser DPAPI ciphertext reaches backups; the primary vault above
      // still requires a restricted ACL before its first byte is written.
    }
    await target.writeAsBytes(bytes, flush: true);
    final digest = sha256.convert(bytes).toString();
    if (sha256.convert(await target.readAsBytes()).toString() != digest) {
      _invalid();
    }
    return MozillaCredentialBackup(target.path, digest);
  }

  Future<void> restoreVerifiedBackup({
    required String path,
    required String expectedSha256,
  }) async {
    final bytes = await File(path).readAsBytes();
    if (sha256.convert(bytes).toString() != expectedSha256.toLowerCase()) {
      _invalid();
    }
    _decode(bytes);
    await _replace(bytes);
  }
}
