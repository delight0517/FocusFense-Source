import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_logger.dart';
import 'chrome_extension_identity.dart';

/// Result of exporting extension assets to an easy-to-find folder (Downloads first).
final class BrowserExtensionExportResult {
  const BrowserExtensionExportResult({
    required this.ok,
    required this.path,
    required this.locationLabel,
    this.repairs = const <String>[],
    this.error,
  });

  final bool ok;
  final String path;

  /// e.g. `다운로드`, `문서`
  final String locationLabel;
  final List<String> repairs;
  final String? error;
}

/// Writes Chrome/Firefox extension folders under
/// `Downloads/SixVPN_확장/` (or Documents fallback) with self-heal retries.
final class BrowserExtensionExportService {
  BrowserExtensionExportService._();

  static const String kRootFolderName = 'SixVPN_확장';
  static const String kChromeSubdir = 'chrome_blocker';
  static const String kFirefoxSubdir = 'firefox_blocker';

  // @reference: uBlock Origin Lite 2026.1012.1545 — reconcile a validated
  // persisted state at startup; original implementation, no upstream code copied.
  // @incident: extension-export-destroys-last-good — stage before replacing.
  static Future<String> exportVerifiedChromiumPayload({
    required String browserId,
    required List<String> assetPaths,
    required String targetDir,
    AssetBundle? bundle,
  }) async {
    final assets = bundle ?? rootBundle;
    final target = p.normalize(p.absolute(targetDir));
    final parent = Directory(p.dirname(target));
    await parent.create(recursive: true);
    final lock = await File('$target.publish.lock').open(mode: FileMode.append);
    var locked = false;
    final nonce = '$pid-${DateTime.now().microsecondsSinceEpoch}';
    final stage = Directory('$target.stage-$nonce');
    final backup = '$target.previous-$nonce';
    var oldFolder = false, oldCrx = false, newFolder = false, newCrx = false;
    try {
      await lock.lock(FileLock.exclusive);
      locked = true;
      for (final name in <String>[target, '$target.crx']) {
        if (await FileSystemEntity.type(name, followLinks: false) ==
            FileSystemEntityType.link) {
          throw const FileSystemException('Payload target cannot be a link');
        }
      }
      await stage.create();
      final names = <String>{};
      for (final asset in assetPaths) {
        final name = p.basename(asset);
        if (!names.add(name)) throw FormatException('Duplicate asset: $name');
        final data = await assets.load(asset);
        await File(p.join(stage.path, name)).writeAsBytes(
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
          flush: true,
        );
      }
      await exportSignedChromiumPackage(
        browserId: browserId,
        folder: stage.path,
        bundle: assets,
      );
      if (await Directory(target).exists()) {
        await Directory(target).rename(backup);
        oldFolder = true;
      }
      if (await File('$target.crx').exists()) {
        await File('$target.crx').rename('$backup.crx');
        oldCrx = true;
      }
      await stage.rename(target);
      newFolder = true;
      await File('${stage.path}.crx').rename('$target.crx');
      newCrx = true;
      // Retain the prior verified payload for recovery; never delete it here.
      return target;
    } catch (_) {
      if (newCrx) await File('$target.crx').rename('${stage.path}.failed.crx');
      if (newFolder) await Directory(target).rename('${stage.path}.failed');
      if (oldCrx) await File('$backup.crx').rename('$target.crx');
      if (oldFolder) await Directory(backup).rename(target);
      rethrow;
    } finally {
      // Only this invocation's new staging files are removed.
      try {
        if (await stage.exists()) await stage.delete(recursive: true);
        final crx = File('${stage.path}.crx');
        if (await crx.exists()) await crx.delete();
      } finally {
        if (locked) await lock.unlock();
        await lock.close();
      }
    }
  }

  /// Ships the pre-signed package beside the exported directory. Never invokes
  /// a browser or puts the private signing key on an end user's installation.
  static Future<void> exportSignedChromiumPackage({
    required String browserId,
    required String folder,
    AssetBundle? bundle,
  }) async {
    if (browserId != 'chrome' && browserId != 'aside') {
      throw ArgumentError.value(browserId, 'browserId');
    }
    final AssetBundle assets = bundle ?? rootBundle;
    final String asset =
        'assets/browser_extensions/$browserId/${browserId}_blocker.crx';
    final ByteData data = await assets.load(asset);
    final bytes = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    final Map<String, dynamic> metadata =
        jsonDecode(await assets.loadString('$asset.manifest.json'))
            as Map<String, dynamic>;
    if (ChromeExtensionIdentity.readCrx3Identity(bytes) !=
            ChromeExtensionIdentity.extensionId ||
        metadata['extensionId'] != ChromeExtensionIdentity.extensionId ||
        metadata['sha256'] != sha256.convert(bytes).toString()) {
      throw const FormatException(
        'Signed Chromium package identity/hash mismatch',
      );
    }
    final Map<String, dynamic> files =
        metadata['files'] as Map<String, dynamic>;
    if (!files.containsKey('manifest.json')) {
      throw const FormatException('Signed package source manifest missing');
    }
    for (final entry in files.entries) {
      if (entry.key != p.basename(entry.key) || entry.key.contains('..')) {
        throw const FormatException('Unsafe signed package entry');
      }
      final File file = File(p.join(folder, entry.key));
      if (sha256.convert(await file.readAsBytes()).toString() != entry.value) {
        throw FormatException('Signed package source differs: ${entry.key}');
      }
    }
    final destination = File('$folder.crx');
    if (await destination.exists() &&
        sha256.convert(await destination.readAsBytes()).toString() ==
            metadata['sha256']) {
      return;
    }
    final pending = File(
      '$folder.crx.next-$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await pending.writeAsBytes(bytes, flush: true);
      await pending.rename(destination.path);
    } finally {
      if (await pending.exists()) await pending.delete();
    }
  }

  // @incident: stale-update-manifest — a .crx suffix alone does not establish
  // that updates.xml references the current signed package/version/hash.
  static Future<void> writeSignedChromiumUpdateManifest({
    required String browserId,
    required String folder,
    AssetBundle? bundle,
  }) async {
    if (browserId != 'chrome' && browserId != 'aside') {
      throw ArgumentError.value(browserId, 'browserId');
    }
    final assets = bundle ?? rootBundle;
    final asset =
        'assets/browser_extensions/$browserId/${browserId}_blocker.crx';
    final metadata =
        jsonDecode(await assets.loadString('$asset.manifest.json'))
            as Map<String, dynamic>;
    final package = File('$folder.crx');
    final bytes = await package.readAsBytes();
    final manifestBytes = await File(
      p.join(folder, 'manifest.json'),
    ).readAsBytes();
    final manifest =
        jsonDecode(utf8.decode(manifestBytes)) as Map<String, dynamic>;
    final hash = sha256.convert(bytes).toString();
    if (ChromeExtensionIdentity.readCrx3Identity(bytes) !=
            ChromeExtensionIdentity.extensionId ||
        hash != metadata['sha256'] ||
        metadata['extensionId'] != ChromeExtensionIdentity.extensionId ||
        manifest['version'] != metadata['version'] ||
        sha256.convert(manifestBytes).toString() !=
            (metadata['files'] as Map<String, dynamic>)['manifest.json']) {
      throw const FormatException(
        'Update package differs from bundled signed payload',
      );
    }
    String escape(String value) => value
        .replaceAll('&', '&amp;')
        .replaceAll("'", '&apos;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    final xml =
        "<?xml version='1.0' encoding='UTF-8'?>"
        "<gupdate xmlns='http://www.google.com/update2/response' protocol='2.0'>"
        "<app appid='${ChromeExtensionIdentity.extensionId}'>"
        "<updatecheck codebase='${escape(package.absolute.uri.toString())}' "
        "version='${escape(manifest['version'] as String)}' hash_sha256='$hash' />"
        '</app></gupdate>';
    final output = File(p.join(folder, 'updates.xml'));
    if (await output.exists() && await output.readAsString() == xml) return;
    final pending = File(
      '${output.path}.next-$pid-${DateTime.now().microsecondsSinceEpoch}',
    );
    try {
      await pending.writeAsString(xml, flush: true);
      await pending.rename(output.path);
    } finally {
      if (await pending.exists()) await pending.delete();
    }
  }

  /// Resolves `…/Downloads/SixVPN_확장` (creates if missing).
  static Future<Directory> resolveExportRoot() async {
    Directory? downloads;
    try {
      downloads = await getDownloadsDirectory();
    } catch (_) {
      downloads = null;
    }
    if (downloads != null && downloads.path.isNotEmpty) {
      final Directory root = Directory(p.join(downloads.path, kRootFolderName));
      await root.create(recursive: true);
      return root;
    }

    if (Platform.isWindows) {
      final String? user = Platform.environment['USERPROFILE'];
      if (user != null && user.isNotEmpty) {
        final Directory root = Directory(
          p.join(user, 'Downloads', kRootFolderName),
        );
        await root.create(recursive: true);
        return root;
      }
    }

    final Directory docs = await getApplicationDocumentsDirectory();
    final Directory root = Directory(p.join(docs.path, kRootFolderName));
    await root.create(recursive: true);
    return root;
  }

  static String locationLabelFor(Directory root) {
    final String norm = p.normalize(root.path).toLowerCase();
    if (norm.contains('download')) return '다운로드';
    return '문서';
  }

  /// Full path where Chrome/Edge assets will be written (may not exist yet).
  static Future<String> expectedChromePath() async {
    final Directory root = await resolveExportRoot();
    return p.join(root.path, kChromeSubdir);
  }

  static Future<String> expectedFirefoxPath() async {
    final Directory root = await resolveExportRoot();
    return p.join(root.path, kFirefoxSubdir);
  }

  static Future<String> exportRootDisplayLine() async {
    final Directory root = await resolveExportRoot();
    return '${locationLabelFor(root)}\\$kRootFolderName\n${root.path}';
  }

  static Future<String?> existingFolderPath(String subdirName) async {
    try {
      final Directory root = await resolveExportRoot();
      final Directory out = Directory(p.join(root.path, subdirName));
      final File manifest = File(p.join(out.path, 'manifest.json'));
      if (await manifest.exists()) return out.path;
    } catch (_) {}
    return null;
  }

  static Future<BrowserExtensionExportResult> exportAssets({
    required List<String> assetPaths,
    required String subdirName,
  }) async {
    final List<String> repairs = <String>[];
    repairs.addAll(await AppLogger.instance.repairLogFileIfNeeded());

    Object? lastError;
    for (int attempt = 0; attempt < 2; attempt++) {
      try {
        final Directory root = await resolveExportRoot();
        final Directory out = Directory(p.join(root.path, subdirName));
        final browsers = <String>['chrome', 'aside'].where(
          (browser) => assetPaths.contains(
            'assets/browser_extensions/$browser/manifest.json',
          ),
        );
        if (browsers.isNotEmpty) {
          await exportVerifiedChromiumPayload(
            browserId: browsers.single,
            assetPaths: assetPaths,
            targetDir: out.path,
          );
        } else {
          if (attempt == 1 && await out.exists()) {
            await out.delete(recursive: true);
            repairs.add('보내기 폴더를 비우고 다시 만들었습니다');
          }
          await out.create(recursive: true);

          for (final String assetPath in assetPaths) {
            final ByteData data = await rootBundle.load(assetPath);
            final String name = p.basename(assetPath);
            final File f = File(p.join(out.path, name));
            await f.writeAsBytes(
              data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
              flush: true,
            );
          }
        }

        final String manifestPath = p.join(out.path, 'manifest.json');
        await File(p.join(out.path, '여기를_선택하세요.txt')).writeAsString(
          '■ 6 VPN Blocker 확장 — 이 폴더를 고르세요\n\n'
          '전체 경로:\n${out.path}\n\n'
          'Chrome / Edge: 탐색기에서 **이 폴더(chrome_blocker)** 를 선택\n'
          '(manifest.json이 들어 있는 폴더)\n\n'
          'Firefox: 「임시 애드온」에서 아래 **파일 하나**만 선택\n'
          '$manifestPath\n',
          flush: true,
        );
        await File(
          p.join(out.path, 'FOLDER_PATH.txt'),
        ).writeAsString(out.path, flush: true);

        return BrowserExtensionExportResult(
          ok: true,
          path: out.path,
          locationLabel: locationLabelFor(root),
          repairs: repairs,
        );
      } catch (e, st) {
        lastError = e;
        AppLogger.instance.error(
          'extension export attempt ${attempt + 1} failed',
          error: e,
          stack: st,
        );
        repairs.addAll(await AppLogger.instance.repairLogFileIfNeeded());
      }
    }

    return BrowserExtensionExportResult(
      ok: false,
      path: '',
      locationLabel: '',
      repairs: repairs,
      error: lastError?.toString() ?? '알 수 없는 오류',
    );
  }
}
