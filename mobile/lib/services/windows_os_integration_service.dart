import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'windows_autostart_service.dart';
import 'windows_offline_block_guard_service.dart';
import 'windows_watchdog_service.dart';
import 'windows_desktop_rebuild_service.dart';
import 'windows_hidden_process.dart';
import 'windows_install_integrity_service.dart';
import 'uninstall_friction_policy_service.dart';
import 'windows_integration_prefs.dart';
import 'windows_start_menu_service.dart';

/// Ensures Windows Search discovery + login autostart (default ON unless user opted out).
abstract final class WindowsOsIntegrationService {
  static Future<void> ensureOnBoot({bool silent = false}) async {
    if (!Platform.isWindows) return;
    try {
      final bool optedOut = await WindowsIntegrationPrefs.instance
          .isAutostartExplicitlyOff();
      if (optedOut) {
        AppLogger.instance.info(
          'windows integration: honoring manual autostart-off preference',
        );
        return;
      }
      await _repairFirefoxPoliciesIfNeeded(noElevate: silent);
      await WindowsInstallIntegrityService.ensureMirrorAndHeal();
      await WindowsStartMenuService.ensureSearchExeAlias();
      await WindowsStartMenuService.ensureInstallIcon();
      final StartMenuInstallResult menu =
          await WindowsStartMenuService.ensureSearchShortcuts();
      if (menu.ok) {
        AppLogger.instance.info('start_menu: ${menu.message}');
      } else {
        AppLogger.instance.warn('start_menu: ${menu.message}');
      }

      final bool removalOk = await UninstallFrictionPolicyService.instance
          .isRemovalAuthorized();
      if (!optedOut || !removalOk) {
        // Always repair — Run registry may point at a stale exe or miss working dir.
        await WindowsAutostartService.instance.repairAutostart();
        final bool installed = await WindowsAutostartService.instance
            .isInstalled();
        if (!installed) {
          final r = await WindowsAutostartService.instance.install();
          AppLogger.instance.info('autostart ensure: ${r.message}');
        } else {
          AppLogger.instance.info(
            'autostart ensure: repaired (Run + logon task)',
          );
        }
        await WindowsWatchdogService.instance.syncTargetPath();
        await WindowsOfflineBlockGuardService.instance.ensureRegistered();
      }
    } catch (e, st) {
      AppLogger.instance.error(
        'windows_os_integration failed',
        error: e,
        stack: st,
      );
    }
  }

  static Future<void> _repairFirefoxPoliciesIfNeeded({
    bool noElevate = false,
  }) async {
    try {
      final String? mobileRoot =
          await WindowsDesktopRebuildService.discoverMobileRoot(persist: false);
      if (mobileRoot == null) return;
      final String repair = p.join(
        mobileRoot,
        'tools',
        'Repair-Firefox-Policies.ps1',
      );
      if (!await File(repair).exists()) return;
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final List<String> args = <String>[
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        repair,
      ];
      if (noElevate) {
        args.add('-NoElevate');
      }
      await windowsRunHidden(
        p.join(
          windir,
          'System32',
          'WindowsPowerShell',
          'v1.0',
          'powershell.exe',
        ),
        args,
      );
      AppLogger.instance.info(
        'firefox_policy_repair: OK (noElevate=$noElevate)',
      );
    } catch (e) {
      AppLogger.instance.warn('firefox_policy_repair skipped', error: e);
    }
  }
}
