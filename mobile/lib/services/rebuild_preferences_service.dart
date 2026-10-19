import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// User controls for how aggressively rebuilds and post-rebuild bootstraps run.
final class RebuildPreferencesService {
  RebuildPreferencesService._();
  static final RebuildPreferencesService instance =
      RebuildPreferencesService._();

  static const String _heavyPostRebuildKey = 'rebuild_heavy_post_bootstrap_v1';
  static const String _noAutoAgentRebuildKey = 'rebuild_no_auto_agent_v2';
  static const String _autoShowerKey = 'rebuild_auto_shower_v1';

  /// 리빌드 후 이전 차단·확장·중복 레이어 자동 정리. Default **on**.
  Future<bool> rebuildAutoShowerEnabled() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoShowerKey) ?? true;
  }

  Future<void> setRebuildAutoShowerEnabled(bool value) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoShowerKey, value);
  }

  static const String kNoAutoRebuildRepoFlag = 'NO_AUTO_REBUILD';
  static const String kNoAutoRebuildLocalFlag = 'no_auto_rebuild.flag';

  /// Full UAC + browser reinstall pipeline after a new build. Default **off**
  /// — most users only need a light rules sync.
  Future<bool> heavyPostRebuildBootstrap() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_heavyPostRebuildKey) ?? false;
  }

  Future<void> setHeavyPostRebuildBootstrap(bool value) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_heavyPostRebuildKey, value);
  }

  /// When true, Cursor/agents skip automatic `Rebuild-6VPN-Windows.ps1 -LaunchAfter`.
  /// Default **off** — agents rebuild after meaningful `mobile/` changes.
  Future<bool> noAutoAgentRebuild() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_noAutoAgentRebuildKey) ?? false;
  }

  Future<void> setNoAutoAgentRebuild(bool value) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_noAutoAgentRebuildKey, value);
    await _syncNoAutoRebuildFlags(disableAuto: value);
  }

  /// Repo + LOCALAPPDATA markers agents and rebuild.ps1 can read without Dart.
  Future<void> _syncNoAutoRebuildFlags({required bool disableAuto}) async {
    final String? la = Platform.environment['LOCALAPPDATA'];
    if (la != null && la.isNotEmpty) {
      final String localFlag =
          p.join(la, 'SixVPNBlocker', kNoAutoRebuildLocalFlag);
      try {
        final File f = File(localFlag);
        if (disableAuto) {
          await f.parent.create(recursive: true);
          await f.writeAsString('1', flush: true);
        } else if (await f.exists()) {
          await f.delete();
        }
      } catch (_) {}
    }

    if (!Platform.isWindows) return;
    try {
      final String? repoFlag = await _repoNoAutoRebuildPath();
      if (repoFlag == null) return;
      final File f = File(repoFlag);
      if (disableAuto) {
        if (!await f.exists()) {
          await f.writeAsString(
            '# Cursor/AI auto-rebuild disabled. Delete this file or turn off in Settings.\n',
            flush: true,
          );
        }
      } else if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {}
  }

  static Future<String?> _repoNoAutoRebuildPath() async {
    final String? marker =
        Platform.environment['LOCALAPPDATA'] != null
            ? p.join(
                Platform.environment['LOCALAPPDATA']!,
                'SixVPNBlocker',
                'rebuild_mobile_root.txt',
              )
            : null;
    if (marker != null) {
      try {
        final File mf = File(marker);
        if (await mf.exists()) {
          final String root = (await mf.readAsString()).trim();
          if (root.isNotEmpty) {
            return p.join(root, 'tools', kNoAutoRebuildRepoFlag);
          }
        }
      } catch (_) {}
    }
    return null;
  }

  /// Call once on app boot so flags exist even before the user opens Settings.
  Future<void> ensureFlagsSynced() async {
    await _syncNoAutoRebuildFlags(disableAuto: await noAutoAgentRebuild());
  }

  static bool noAutoRebuildFlagPresentSync() {
    if (!Platform.isWindows) return false;
    final String? la = Platform.environment['LOCALAPPDATA'];
    if (la != null) {
      final File local = File(p.join(la, 'SixVPNBlocker', kNoAutoRebuildLocalFlag));
      if (local.existsSync()) return true;
      try {
        final File marker =
            File(p.join(la, 'SixVPNBlocker', 'rebuild_mobile_root.txt'));
        if (marker.existsSync()) {
          final String root = marker.readAsStringSync().trim();
          if (root.isNotEmpty) {
            final File repo =
                File(p.join(root, 'tools', kNoAutoRebuildRepoFlag));
            if (repo.existsSync()) return true;
          }
        }
      } catch (_) {}
    }
    return false;
  }
}
