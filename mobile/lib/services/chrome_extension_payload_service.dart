import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/browser_extension_asset_manifest.dart';
import 'app_logger.dart';
import 'browser_extension_export_service.dart';
import 'chrome_extension_version.dart';
import 'chrome_load_extension_launcher.dart';
import 'extension_guard_prefs.dart';

/// Ensures Chrome/Edge extension files exist (not just updates.xml / empty BAT).
abstract final class ChromeExtensionPayloadService {
  static String get programDataChromeDir {
    final String pd = Platform.environment['ProgramData'] ?? r'C:\ProgramData';
    return p.join(pd, 'SixVPNBlocker', 'chrome_blocker');
  }

  static Future<bool> hasManifest(String dir) async {
    if (dir.isEmpty) return false;
    return File(p.join(dir, 'manifest.json')).exists();
  }

  /// Finds any folder that actually contains the MV3 extension payload.
  static Future<String?> resolveValidSource() async {
    final String? saved = await ExtensionGuardPrefs.instance.chromeSourcePath();
    if (saved != null && await hasManifest(saved)) return saved;

    final String stable = ChromeLoadExtensionLauncher.stableChromeExtDir;
    if (await hasManifest(stable)) return stable;

    if (await hasManifest(programDataChromeDir)) {
      return programDataChromeDir;
    }

    final String? docs = await BrowserExtensionExportService.existingFolderPath(
      BrowserExtensionExportService.kChromeSubdir,
    );
    if (docs != null) return docs;

    final String? docsDefault = await _defaultDocsChromePath();
    if (docsDefault != null && await hasManifest(docsDefault)) {
      return docsDefault;
    }

    return null;
  }

  static Future<String?> _defaultDocsChromePath() async {
    try {
      return await BrowserExtensionExportService.expectedChromePath();
    } catch (_) {
      return null;
    }
  }

  /// Writes bundled assets directly into [targetDir] (ASCII-safe LOCALAPPDATA).
  static Future<String?> exportBundledTo(String targetDir) async {
    try {
      final out = Directory(
        await BrowserExtensionExportService.exportVerifiedChromiumPayload(
          browserId: 'chrome',
          assetPaths: BrowserExtensionAssetManifest.chrome,
          targetDir: targetDir,
        ),
      );

      if (await hasManifest(out.path)) {
        AppLogger.instance.info(
          'chrome_payload: bundled export -> ${out.path}',
        );
        return out.path;
      }
    } catch (e, st) {
      AppLogger.instance.error(
        'chrome_payload: bundled export failed',
        error: e,
        stack: st,
      );
    }
    return null;
  }

  /// Guarantees `%LOCALAPPDATA%\\SixVPNBlocker\\chrome_blocker\\manifest.json`.
  static Future<String?> ensureStablePayload({String? preferredSource}) async {
    String? source = preferredSource;
    if (source != null && !await hasManifest(source)) {
      source = null;
    }
    source ??= await resolveValidSource();
    if (source != null && await ChromeExtensionVersion.installedIsStale()) {
      source = await exportBundledTo(
        ChromeLoadExtensionLauncher.stableChromeExtDir,
      );
    }
    source ??= await exportBundledTo(
      ChromeLoadExtensionLauncher.stableChromeExtDir,
    );

    if (source == null) return null;

    String stable;
    try {
      stable = await ChromeLoadExtensionLauncher.mirrorExtensionFolder(source);
    } catch (_) {
      final repaired = await exportBundledTo(
        ChromeLoadExtensionLauncher.stableChromeExtDir,
      );
      if (repaired == null) return null;
      stable = repaired;
    }
    if (!await hasManifest(stable)) {
      AppLogger.instance.warn(
        'chrome_payload: mirror failed — retry bundled export',
      );
      final String? fresh = await exportBundledTo(stable);
      if (fresh == null || !await hasManifest(fresh)) return null;
      await ExtensionGuardPrefs.instance.setChromeSourcePath(fresh);
      return fresh;
    }

    await ExtensionGuardPrefs.instance.setChromeSourcePath(stable);
    await BrowserExtensionExportService.exportSignedChromiumPackage(
      browserId: 'chrome',
      folder: stable,
    );
    await _repairProgramDataCopyFrom(stable);
    await _ensureUpdatesXml(stable);
    return stable;
  }

  /// Publish only an exact bundled signed CRX; never advertise manifest.json
  /// as a package or keep a stale update URL solely because it ends in .crx.
  static Future<void> _ensureUpdatesXml(String folder) async {
    if (!Platform.isWindows) return;
    await BrowserExtensionExportService.writeSignedChromiumUpdateManifest(
      browserId: 'chrome',
      folder: folder,
    );
  }

  static Future<void> _repairProgramDataCopyFrom(String source) async {
    if (!Platform.isWindows) return;
    final bool stale = await ChromeExtensionVersion.installedIsStale();
    if (await hasManifest(programDataChromeDir) && !stale) return;
    try {
      final Directory dest = Directory(programDataChromeDir);
      if (await dest.exists()) {
        await dest.delete(recursive: true);
      }
      await dest.create(recursive: true);
      await for (final FileSystemEntity e in Directory(
        source,
      ).list(recursive: true)) {
        if (e is! File) continue;
        final String rel = p.relative(e.path, from: source);
        final File out = File(p.join(dest.path, rel));
        await out.parent.create(recursive: true);
        await e.copy(out.path);
      }
      if (await hasManifest(programDataChromeDir)) {
        AppLogger.instance.info('chrome_payload: repaired ProgramData copy');
      }
    } catch (e) {
      AppLogger.instance.warn(
        'chrome_payload: ProgramData repair skip',
        error: e,
      );
    }
  }

  static Future<bool> stablePayloadReady() =>
      hasManifest(ChromeLoadExtensionLauncher.stableChromeExtDir);
}
