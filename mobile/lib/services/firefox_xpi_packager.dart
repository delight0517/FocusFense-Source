import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'mozilla_signing_client.dart';
import 'windows_extension_guard_service.dart';

/// Deploy exact approved signed bytes; never rebuild an unsigned runtime ZIP.
final class FirefoxXpiPackager {
  FirefoxXpiPackager._();
  FirefoxXpiPackager.forTesting(
    this._loader,
    this._output, {
    Directory? releases,
  }) : _releases =
           releases ?? Directory(p.join(_output!.path, 'approved-releases'));
  static final instance = FirefoxXpiPackager._();
  Future<Uint8List> Function()? _loader;
  Directory? _output;
  Directory? _releases;
  static const kXpiFileName = '$kFirefoxExtensionId.xpi';
  static const kBundledSignedAsset =
      'assets/browser_extensions/firefox/sixvpn_blocker_signed.xpi';
  static String get programDataFirefoxDir => p.join(
    Platform.environment['ProgramData'] ?? r'C:\ProgramData',
    'SixVPNBlocker',
    'firefox',
  );
  static String get programDataXpiPath =>
      p.join(programDataFirefoxDir, kXpiFileName);
  static String fileUrlForXpi(String xpiPath) =>
      WindowsExtensionGuardService.fileUrlForFolder(xpiPath);
  Directory get _releaseDirectory =>
      _releases ??
      Directory(
        p.join(
          Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path,
          'FocusFense',
          'signed-releases',
          'firefox',
        ),
      );

  Future<Uint8List> _signedBytes() async {
    final Uint8List bytes;
    if (_loader != null) {
      bytes = await _loader!();
    } else {
      final data = await rootBundle.load(kBundledSignedAsset);
      bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    }
    try {
      MozillaSigningClient.validatedPackageVersion(
        bytes,
        requireSignature: true,
      );
    } catch (_) {
      throw StateError(
        'Bundled signed Firefox XPI is invalid; refusing unsigned fallback',
      );
    }
    return bytes;
  }

  static int _compareVersion(String a, String b) {
    final left = a.split('.').map(int.parse).toList();
    final right = b.split('.').map(int.parse).toList();
    for (var i = 0; i < 4; i++) {
      final difference =
          (i < left.length ? left[i] : 0) - (i < right.length ? right[i] : 0);
      if (difference != 0) {
        return difference;
      }
    }
    return 0;
  }

  Future<Uint8List?> _approvedBytes(Uint8List bundled) async {
    try {
      final pointer = File(p.join(_releaseDirectory.path, 'current.json'));
      if (!await pointer.exists()) {
        return null;
      }
      final metadata = jsonDecode(await pointer.readAsString()) as Map;
      final digest = metadata['sha256'];
      final version = metadata['version'];
      if (metadata['addonId'] != MozillaSigningClient.addonId ||
          digest is! String ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ||
          version is! String ||
          !RegExp(r'^[0-9]+(?:\.[0-9]+){0,3}$').hasMatch(version) ||
          metadata['amoVersionId'] is! int ||
          (metadata['amoVersionId'] as int) <= 0) {
        return null;
      }
      final file = File(p.join(_releaseDirectory.path, '$version-$digest.xpi'));
      if (await file.length() > MozillaSigningClient.maxPackageBytes) {
        return null;
      }
      final bytes = await file.readAsBytes();
      if (sha256.convert(bytes).toString() != digest ||
          MozillaSigningClient.validatedPackageVersion(
                bytes,
                requireSignature: true,
              ) !=
              version ||
          _compareVersion(
                version,
                MozillaSigningClient.validatedPackageVersion(
                  bundled,
                  requireSignature: true,
                ),
              ) <
              0) {
        return null;
      }
      return bytes;
    } catch (_) {
      return null;
    }
  }

  /// Chosen approved release, with the bundled release as verified fallback.
  Future<Uint8List> trustedSignedBytes() async {
    final bundled = await _signedBytes();
    return await _approvedBytes(bundled) ?? bundled;
  }

  Future<String> trustedSignedVersion() async =>
      MozillaSigningClient.validatedPackageVersion(
        await trustedSignedBytes(),
        requireSignature: true,
      );

  /// Pin a receipt-validated AMO download. Firefox still validates actual crypto.
  Future<void> adoptApprovedDownload(MozillaSignedDownload download) async {
    if (download.versionId <= 0) {
      throw StateError('Invalid AMO receipt');
    }
    final source = File(download.path);
    if (await source.length() > MozillaSigningClient.maxPackageBytes) {
      throw StateError('Package too large');
    }
    final bytes = await source.readAsBytes();
    final digest = sha256.convert(bytes).toString();
    final version = MozillaSigningClient.validatedPackageVersion(
      bytes,
      requireSignature: true,
    );
    if (digest != download.sha256 || version != download.version) {
      throw StateError('Signed download receipt mismatch');
    }
    final current = await trustedSignedBytes();
    final currentVersion = MozillaSigningClient.validatedPackageVersion(
      current,
      requireSignature: true,
    );
    if (_compareVersion(version, currentVersion) < 0) {
      throw StateError('Firefox release downgrade refused');
    }
    if (_compareVersion(version, currentVersion) == 0 &&
        sha256.convert(current).toString() != digest) {
      throw StateError('Different bytes for the same approved Firefox version');
    }
    final directory = _releaseDirectory;
    await directory.create(recursive: true);
    final immutable = File(p.join(directory.path, '$version-$digest.xpi'));
    if (await immutable.exists()) {
      if (sha256.convert(await immutable.readAsBytes()).toString() != digest) {
        throw StateError('Pinned package damaged');
      }
    } else {
      await immutable.create(exclusive: true);
      await immutable.writeAsBytes(bytes, flush: true);
      if (sha256.convert(await immutable.readAsBytes()).toString() != digest) {
        throw StateError('Pinned package verification failed');
      }
    }
    final metadata = jsonEncode({
      'schema': 1,
      'addonId': MozillaSigningClient.addonId,
      'version': version,
      'amoVersionId': download.versionId,
      'sha256': digest,
      'adoptedAtUtc': DateTime.now().toUtc().toIso8601String(),
    });
    final receipt = File(p.join(directory.path, '$version-$digest.json'));
    if (!await receipt.exists()) {
      await receipt.writeAsString(metadata, flush: true);
    }
    final temporary = File(
      p.join(
        directory.path,
        'current-$pid-${DateTime.now().microsecondsSinceEpoch}.tmp',
      ),
    );
    try {
      await temporary.writeAsString(metadata, flush: true);
      await temporary.rename(p.join(directory.path, 'current.json'));
    } finally {
      if (await temporary.exists()) {
        await temporary.delete();
      }
    }
  }

  /// Historical name retained for callers; compares selected approved release.
  Future<bool> isBundledSignedCopy(File file) async {
    final expected = await trustedSignedBytes();
    final actual = await file.readAsBytes();
    return expected.length == actual.length &&
        sha256.convert(expected) == sha256.convert(actual);
  }

  Future<File> ensureProgramDataXpi({required String sourceFolder}) async {
    final bytes = await trustedSignedBytes();
    final directory = _output ?? Directory(programDataFirefoxDir);
    await directory.create(recursive: true);
    final dest = File(p.join(directory.path, kXpiFileName));
    final temporary = File(
      p.join(
        directory.path,
        'signed-staging-$pid-${DateTime.now().microsecondsSinceEpoch}.tmp',
      ),
    );
    try {
      await temporary.writeAsBytes(bytes, flush: true);
      await temporary.rename(dest.path);
      return dest;
    } finally {
      if (await temporary.exists()) {
        await temporary.delete();
      }
    }
  }
}
