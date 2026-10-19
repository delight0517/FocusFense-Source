import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'chrome_load_extension_launcher.dart';

/// Reads bundled vs installed Chrome extension semver.
abstract final class ChromeExtensionVersion {
  static const String _bundledAsset =
      'assets/browser_extensions/chrome/manifest.json';

  static String? _bundledCache;

  static Future<String> bundled() async {
    if (_bundledCache != null) return _bundledCache!;
    try {
      final String raw = await rootBundle.loadString(_bundledAsset);
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        final String? v = decoded['version'] as String?;
        if (v != null && v.trim().isNotEmpty) {
          _bundledCache = v.trim();
          return _bundledCache!;
        }
      }
    } catch (_) {}
    return '1.0.0';
  }

  static Future<String?> installed() async {
    final String path = p.join(
      ChromeLoadExtensionLauncher.stableChromeExtDir,
      'manifest.json',
    );
    return _readVersionFile(path);
  }

  static Future<String?> readFromFolder(String folder) async {
    return _readVersionFile(p.join(folder, 'manifest.json'));
  }

  static Future<String?> _readVersionFile(String manifestPath) async {
    try {
      final File f = File(manifestPath);
      if (!await f.exists()) return null;
      final Object? decoded = jsonDecode(await f.readAsString());
      if (decoded is Map<String, dynamic>) {
        return (decoded['version'] as String?)?.trim();
      }
    } catch (_) {}
    return null;
  }

  static Future<bool> installedIsStale() async {
    final String target = await bundled();
    final String? current = await installed();
    if (current == null) return true;
    return current != target;
  }
}
