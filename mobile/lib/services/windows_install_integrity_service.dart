import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'uninstall_friction_policy_service.dart';
import 'windows_desktop_rebuild_service.dart';
import 'windows_hidden_process.dart';
import 'windows_start_menu_service.dart';
import 'windows_integration_prefs.dart';

/// Multi-shard install mirrors + partial-delete heal (manual uninstall barrier).
///
/// Unauthorized removal must delete **all** copies within ~30s (watchdog interval).
/// Any surviving shard restores canonical, alias, backups, Run registry, shortcuts.
abstract final class WindowsInstallIntegrityService {
  static const List<String> _shardRelPaths = <String>[
    'backup/FocusFense.exe',
    'cache/v1/runner_payload.exe',
    'policy_batch/install_shard_b.exe',
    'staged/search_mirror.exe',
  ];

  static const String _manifestName = 'install_integrity_v2.json';
  static const String _repairScriptName = 'Repair-Install-Integrity.ps1';

  static const List<String> kGuardTaskNames = <String>[
    'SixVPNBlockerWatchdog',
    'SixVPNBlockerWatchdog2',
    'SixVPNBlockerAutostart',
    'SixVPNBlockerBootGuard',
    'SixVPNBlockerOfflineGuard',
    'SixVPNBlockerElevatedMaintain',
  ];

  /// The subset of [kGuardTaskNames] that `Install-Windows-OsIntegration.ps1`
  /// always registers (unlike `SixVPNBlockerElevatedMaintain`, which only
  /// gets registered as a side effect of an elevated hosts-apply and isn't
  /// present on every install). This is what [_detectPartialTamper] checks —
  /// if any of these five is missing, relaunch-on-crash or autostart itself
  /// is silently gone, which exe-file checks alone never notice.
  static const List<String> kCoreResilienceTaskNames = <String>[
    'SixVPNBlockerWatchdog',
    'SixVPNBlockerWatchdog2',
    'SixVPNBlockerAutostart',
    'SixVPNBlockerBootGuard',
    'SixVPNBlockerOfflineGuard',
  ];

  static String get _localDir {
    final String la = Platform.environment['LOCALAPPDATA'] ?? '';
    return p.join(la, 'SixVPNBlocker');
  }

  static String get installDir {
    final String la = Platform.environment['LOCALAPPDATA'] ?? '';
    return p.join(la, 'Programs', WindowsStartMenuService.kInstallSubdir);
  }

  static String get canonicalExe => p.join(installDir, 'FocusFense.exe');

  static String get searchAliasExe =>
      p.join(installDir, WindowsStartMenuService.kSearchExeName);

  static List<String> get shardPaths =>
      _shardRelPaths.map((String r) => p.join(_localDir, r)).toList();

  static List<String> get allMirrorTargets => <String>[
    canonicalExe,
    searchAliasExe,
    ...shardPaths,
  ];

  /// Mirror running install exe to all shards; heal if any piece was removed.
  static Future<void> ensureMirrorAndHeal() async {
    if (!Platform.isWindows) return;
    if (await WindowsIntegrationPrefs.instance.isAutostartExplicitlyOff()) {
      AppLogger.instance.info(
        'install_integrity: skipped by manual autostart-off preference',
      );
      return;
    }
    if (await UninstallFrictionPolicyService.instance.isRemovalAuthorized()) {
      return;
    }
    await _ensureRepairScriptOnDisk();
    await _mirrorToAllTargets();
    final bool partial = await _detectPartialTamper();
    if (partial) {
      final bool healed = await _healAllFromBestSource();
      if (healed) {
        AppLogger.instance.warn(
          'install_integrity: partial manual-delete healed (multi-shard restore)',
        );
        await _runRepairScript();
      }
    }
    if (await File(canonicalExe).exists()) {
      await WindowsStartMenuService.ensureSearchShortcuts();
    }
  }

  static Future<void> _ensureRepairScriptOnDisk() async {
    try {
      final String? mobileRoot =
          await WindowsDesktopRebuildService.discoverMobileRoot(persist: false);
      if (mobileRoot == null) return;
      final String src = p.join(mobileRoot, 'tools', _repairScriptName);
      if (!await File(src).exists()) return;
      final String destDir = p.join(_localDir, 'tools');
      await Directory(destDir).create(recursive: true);
      await File(src).copy(p.join(destDir, _repairScriptName));
    } catch (e) {
      AppLogger.instance.warn(
        'install_integrity: script copy failed',
        error: e,
      );
    }
  }

  static Future<void> _mirrorToAllTargets() async {
    try {
      final String? source = await _bestSourceExe(preferRunning: true);
      if (source == null) return;
      final File src = File(source);
      if (!await src.exists()) return;
      final DateTime srcMod = await src.lastModified();

      for (final String target in allMirrorTargets) {
        if (p.normalize(target).toLowerCase() ==
            p.normalize(source).toLowerCase()) {
          continue;
        }
        try {
          await Directory(p.dirname(target)).create(recursive: true);
          final File dest = File(target);
          final bool needsCopy =
              !await dest.exists() || srcMod.isAfter(await dest.lastModified());
          if (needsCopy) {
            await src.copy(target);
          }
        } catch (_) {
          /* continue other shards */
        }
      }
      await _writeManifest(source);
    } catch (e) {
      AppLogger.instance.warn('install_integrity: mirror failed', error: e);
    }
  }

  static Future<bool> _detectPartialTamper() async {
    if (!await File(canonicalExe).exists()) return true;
    if (!await File(searchAliasExe).exists()) return true;
    int shardCount = 0;
    for (final String shard in shardPaths) {
      if (await File(shard).exists()) shardCount++;
    }
    if (shardCount < shardPaths.length) return true;
    // Exe-file checks alone miss the failure mode this exists for: every
    // shard can be intact while someone (an AI session "cleaning up"
    // scheduled tasks, a broken uninstaller, etc.) deletes the relaunch /
    // autostart tasks themselves, leaving crash-relaunch and login-autostart
    // silently dead. Treat any missing core task as tamper too.
    if (!await _areCoreResilienceTasksPresent()) return true;
    return false;
  }

  /// True only if every task in [kCoreResilienceTaskNames] is still
  /// registered. Uses `schtasks /Query` (same tool the elevated-maintain
  /// service already uses) so this needs no elevation.
  static Future<bool> _areCoreResilienceTasksPresent() async {
    try {
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final String schtasks = p.join(windir, 'System32', 'schtasks.exe');
      for (final String taskName in kCoreResilienceTaskNames) {
        final ProcessResult r = await windowsRunHidden(schtasks, <String>[
          '/Query',
          '/TN',
          taskName,
          '/FO',
          'LIST',
        ]);
        if (r.exitCode != 0) return false;
      }
      return true;
    } catch (e) {
      AppLogger.instance.warn('install_integrity: task check failed', error: e);
      // Fail closed (assume tasks missing) so a check-tool error still
      // triggers a repair pass rather than silently skipping one.
      return false;
    }
  }

  static Future<bool> _healAllFromBestSource() async {
    final String? source = await _bestSourceExe(preferRunning: true);
    if (source == null) return false;

    try {
      await Directory(installDir).create(recursive: true);
      for (final String target in allMirrorTargets) {
        if (p.normalize(target).toLowerCase() ==
            p.normalize(source).toLowerCase()) {
          continue;
        }
        try {
          await Directory(p.dirname(target)).create(recursive: true);
          await File(source).copy(target);
        } catch (_) {}
      }
      await WindowsStartMenuService.ensureSearchExeAlias();
      return true;
    } catch (e) {
      AppLogger.instance.warn('install_integrity: heal failed', error: e);
      return false;
    }
  }

  static Future<void> _runRepairScript() async {
    final String script = p.join(_localDir, 'tools', _repairScriptName);
    if (!await File(script).exists()) return;
    try {
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      await windowsRunHidden(
        p.join(
          windir,
          'System32',
          'WindowsPowerShell',
          'v1.0',
          'powershell.exe',
        ),
        <String>[
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-WindowStyle',
          'Hidden',
          '-File',
          script,
          '-Quiet',
        ],
      );
    } catch (e) {
      AppLogger.instance.warn(
        'install_integrity: repair script failed',
        error: e,
      );
    }
  }

  static Future<void> _writeManifest(String sourceExe) async {
    try {
      await Directory(_localDir).create(recursive: true);
      final Map<String, Object> body = <String, Object>{
        'version': 2,
        'note':
            'Unauthorized removal must delete ALL targets within ~30s or watchdog restores.',
        'source': sourceExe,
        'canonical': canonicalExe,
        'alias': searchAliasExe,
        'shards': shardPaths,
        'guardTasks': kGuardTaskNames,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      };
      await File(
        p.join(_localDir, _manifestName),
      ).writeAsString(JsonEncoder.withIndent('  ').convert(body), flush: true);
    } catch (_) {}
  }

  static Future<String?> _bestSourceExe({required bool preferRunning}) async {
    if (preferRunning) {
      final String running = Platform.resolvedExecutable;
      if (running.toLowerCase().endsWith('.exe') &&
          await File(running).exists()) {
        return running;
      }
    }
    for (final String path in allMirrorTargets) {
      if (await File(path).exists()) return path;
    }

    final String? mobileRoot =
        await WindowsDesktopRebuildService.discoverMobileRoot(persist: false);
    if (mobileRoot != null) {
      final String release = p.join(
        mobileRoot,
        'build',
        'windows',
        'x64',
        'runner',
        'Release',
        'FocusFense.exe',
      );
      if (await File(release).exists()) return release;
    }
    return null;
  }
}
