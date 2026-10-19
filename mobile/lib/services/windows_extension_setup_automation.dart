import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'browser_extension_export_service.dart';
import 'browser_extension_launcher.dart';
import 'chrome_extension_state_probe.dart';
import 'extension_guard_prefs.dart';
import 'firefox_config_service.dart';
import 'firefox_xpi_packager.dart';
import 'easy_setup_bulletproof_installer.dart';
import 'chrome_unification_service.dart';
import 'extension_install_user_message.dart';
import 'protection_coverage_service.dart';
import 'windows_desktop_rebuild_service.dart';
import 'windows_extension_guard_service.dart';
import 'windows_extension_self_heal_service.dart';
import 'silent_bootstrap_context.dart';
import 'windows_firefox_extension_install_service.dart';
import 'windows_hidden_process.dart';

/// One-tap: export → UAC (Chrome+Firefox policies) → profile XPI → browser restart.
final class WindowsExtensionSetupAutomation {
  WindowsExtensionSetupAutomation._();
  static final WindowsExtensionSetupAutomation instance =
      WindowsExtensionSetupAutomation._();

  bool get isSupported => Platform.isWindows;

  Future<ExtensionSetupAutomationResult> runFullSetup({
    required List<String> chromeAssetPaths,
    required List<String> firefoxAssetPaths,
    void Function(String status)? onStatus,
    bool exportFirefox = true,

    /// No chrome://extensions popups — for autonomous background install.
    bool silent = false,

    /// HKLM / UAC — only from explicit user actions in browser extensions UI.
    bool allowElevated = false,
  }) async {
    if (!isSupported) {
      return const ExtensionSetupAutomationResult(
        ok: false,
        phase: ExtensionSetupPhase.failed,
        message: 'Windows 전용입니다.',
      );
    }
    void status(String s) {
      onStatus?.call(s);
      AppLogger.instance.info('extension_auto: $s');
    }

    try {
      status('① Chrome/Edge 확장 폴더 준비…');
      final exportChrome = await BrowserExtensionExportService.exportAssets(
        assetPaths: chromeAssetPaths,
        subdirName: BrowserExtensionExportService.kChromeSubdir,
      );
      if (!exportChrome.ok) {
        return ExtensionSetupAutomationResult(
          ok: false,
          phase: ExtensionSetupPhase.export,
          message: '폴더 준비 실패: ${exportChrome.error ?? "알 수 없음"}',
          chromePath: exportChrome.path,
        );
      }

      String? firefoxPath;
      if (exportFirefox) {
        status('① Firefox 확장 폴더 + XPI 패키징…');
        final exportFf = await BrowserExtensionExportService.exportAssets(
          assetPaths: firefoxAssetPaths,
          subdirName: BrowserExtensionExportService.kFirefoxSubdir,
        );
        if (exportFf.ok) {
          firefoxPath = exportFf.path;
          try {
            await FirefoxXpiPackager.instance.ensureProgramDataXpi(
              sourceFolder: exportFf.path,
            );
          } catch (e) {
            AppLogger.instance.error('firefox_xpi ensure failed', error: e);
            return ExtensionSetupAutomationResult(
              ok: false,
              phase: ExtensionSetupPhase.export,
              message:
                  'Firefox XPI 패키징 실패: $e\n\n'
                  '· 앱을 한 번 닫고 **쉬운 설치**를 다시 실행하세요.\n'
                  '· 백신이 ${FirefoxXpiPackager.programDataFirefoxDir} 를 막지 않는지 확인하세요.',
              chromePath: exportChrome.path,
              firefoxPath: firefoxPath,
            );
          }
        }
      }

      status('② HKCU + 바탕화면 바로가기 (UAC 없음)…');
      WindowsExtensionSelfHealService.instance.clearCooldown();
      ExtensionSelfHealResult heal = await WindowsExtensionSelfHealService
          .instance
          .runSelfHeal(
            attemptElevated: false,
            onStatus: status,
            chromeSourceOverride: exportChrome.path,
            userInitiated: true,
          );
      ExtensionPolicyVerifyResult verify =
          heal.verify ?? await WindowsExtensionGuardService.verifyAllPolicies();

      if (firefoxPath != null) {
        status('③ Firefox 프로필에 XPI 복사 + DoH 잠금…');
        await WindowsFirefoxExtensionInstallService.instance
            .installXpiToAllProfiles();
        await FirefoxConfigService.instance.disableDoHInAllProfiles();
        verify = await WindowsExtensionGuardService.verifyAllPolicies();
      }

      ExtensionGuardResult guard = const ExtensionGuardResult(
        ok: false,
        message: 'UAC 생략 — HKCU/바로가기 모드 우선',
      );

      final bool mayElevate =
          allowElevated &&
          !SilentBootstrapContext.suppressElevated &&
          !await ExtensionGuardPrefs.instance.isElevatedGuardSkipped();
      if (!verify.protectionOk && mayElevate) {
        status('③-b UAC (선택) — 관리자 정책 한 번만…');
        guard = await WindowsExtensionGuardService.instance.runElevatedGuard(
          chromeExtensionFolder: exportChrome.path,
        );
        verify = await WindowsExtensionGuardService.verifyAllPolicies();
        if (!verify.protectionOk) {
          await ExtensionGuardPrefs.instance.setElevatedGuardSkipped(true);
          heal = await WindowsExtensionSelfHealService.instance.runSelfHeal(
            attemptElevated: false,
            onStatus: status,
            verifyBefore: verify,
            chromeSourceOverride: exportChrome.path,
            userInitiated: false,
          );
          verify = heal.verify ?? verify;
        }
      } else if (!verify.protectionOk) {
        heal = await WindowsExtensionSelfHealService.instance.runSelfHeal(
          attemptElevated: false,
          onStatus: status,
          verifyBefore: verify,
          chromeSourceOverride: exportChrome.path,
          userInitiated: true,
        );
        verify = heal.verify ?? verify;
      }

      final ChromeExtensionProbeResult chromeProbe =
          await ChromeExtensionStateProbe.probe(browser: 'chrome');
      final FirefoxInstallVerifyResult ffVerify =
          await WindowsFirefoxExtensionInstallService.verify();

      // ④-a Chrome/Edge 3-tier 통합 (HKLM/HKCU 성공 여부와 무관하게 항상 실행).
      // Registry-blocked PCs only get protection through this path: load-extension
      // .bat launchers + shortcut hijack + watchdog. The previous gate
      // (`if (verify.chromeLoadExtensionFallbackOk)`) was chicken-and-egg —
      // the flag only flips true AFTER unification runs, so the unification
      // step was effectively dead code on the very PCs that need it most.
      status('④-a Chrome/Edge 3계층 통합 (바로가기 + 워치독)…');
      await ChromeUnificationService.instance.ensureUnifiedChrome(
        extensionFolder: exportChrome.path,
        applyPolicies: true,
      );
      verify = await WindowsExtensionGuardService.verifyAllPolicies();

      status('④-b 정책 적용 확인 — 열린 브라우저는 유지하고 다음 실행 때 반영합니다.');
      verify = await WindowsExtensionGuardService.verifyAllPolicies();

      if (!silent) {
        status('⑤ 확장 설정 페이지 열기…');
        if (!verify.chromeLoadExtensionFallbackOk) {
          await BrowserExtensionLauncher.openChromeExtensions();
        }
        if (firefoxPath != null &&
            await WindowsFirefoxExtensionInstallService.isFirefoxInstalled() &&
            !verify.firefoxPolicyOk) {
          await BrowserExtensionLauncher.openFirefoxDebugging();
        }
      } else {
        status('⑤ 자율 모드 — 브라우저 설정 창 생략');
      }

      if (!verify.protectionOk) {
        status('④-c PowerShell 원클릭 스크립트…');
        await _runSetupScriptFallback();
        verify = await WindowsExtensionGuardService.verifyAllPolicies();
      }

      String? extraLead;
      if (verify.firefoxPolicyOk && verify.chromeOk) {
        extraLead = heal.message.split('\n').first;
      } else if (verify.firefoxPolicyOk) {
        extraLead =
            '✅ Firefox 완료 · ❌ Chrome/Edge\n${await _failureHints(guard)}';
      } else {
        extraLead = '${guard.message}\n${await _failureHints(guard)}';
      }

      final String msg = await ExtensionInstallUserMessage.formatSetupResult(
        verify: verify,
        firefoxVerify: ffVerify,
        hasUnpackedDevCopy: chromeProbe.hasUnpackedCopy,
        extraLead: extraLead,
      );

      final bool ok =
          verify.firefoxPolicyOk &&
          verify.chromeOk &&
          verify.edgeOk &&
          !chromeProbe.hasUnpackedCopy;
      if (verify.chromeOk) {
        await ExtensionGuardPrefs.instance.setChromeSourcePath(
          exportChrome.path,
        );
        await ExtensionGuardPrefs.instance.setWatchdogEnabled(true);
      }

      status('⑥ 레지스트리 막힌 PC — BAT·바로가기·감시자…');
      final BulletproofInstallResult bullet =
          await EasySetupBulletproofInstaller.instance.applyAfterSetup(
            chromeExtensionFolder: exportChrome.path,
            onStatus: status,
          );

      ProtectionCoverageService.instance.invalidateCache();

      final String fullMessage = bullet.message.isEmpty
          ? msg
          : '$msg\n\n【강화 설치】\n${bullet.message}';

      return ExtensionSetupAutomationResult(
        ok: ok,
        phase: ok
            ? ExtensionSetupPhase.done
            : (verify.chromeOk
                  ? ExtensionSetupPhase.needsManualCleanup
                  : ExtensionSetupPhase.failed),
        message: fullMessage,
        chromePath: exportChrome.path,
        firefoxPath: firefoxPath,
        verify: verify,
        firefoxVerify: ffVerify,
        hasUnpackedCopy: chromeProbe.hasUnpackedCopy,
        usesLoadExtensionShortcut: verify.chromeLoadExtensionFallbackOk,
        guardLog: await WindowsExtensionGuardService.readGuardLogTail(
          maxLines: 20,
        ),
        portableBatPath: bullet.batPath,
        desktopBatPath: bullet.desktopBatPath,
      );
    } catch (e, st) {
      AppLogger.instance.error('extension_auto failed', error: e, stack: st);
      return ExtensionSetupAutomationResult(
        ok: false,
        phase: ExtensionSetupPhase.failed,
        message: '자동 설치 오류: $e',
      );
    }
  }

  static Future<void> _runSetupScriptFallback() async {
    final String? root = await WindowsDesktopRebuildService.discoverMobileRoot(
      persist: false,
    );
    if (root == null) return;
    final String script = p.join(root, 'tools', 'Setup-Blocker-Windows.ps1');
    if (!await File(script).exists()) return;
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    try {
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
          '-ExecutionPolicy',
          'Bypass',
          '-WindowStyle',
          'Hidden',
          '-File',
          script,
          '-MobileRoot',
          root,
        ],
      );
    } catch (_) {}
  }

  static Future<String> _failureHints(ExtensionGuardResult guard) async {
    final int? exit =
        await WindowsExtensionGuardService.readGuardLastExitCode();
    final StringBuffer sb = StringBuffer('【안 되면】\n');
    if (guard.message.contains('UAC 취소')) {
      sb.writeln('· UAC 창에서 **예**를 눌러야 합니다 (아니오 = 레지스트리 0개).');
    } else if (exit == 2) {
      sb.writeln('· HKLM 쓰기가 막힌 PC입니다 (학교·회사·보안 SW).');
    } else {
      sb.writeln('· 앱을 **관리자 권한으로 실행** 후 「한 번에 자동 설치」 재시도.');
    }
    sb.writeln('· 로그: C:\\ProgramData\\SixVPNBlocker\\guard_last.log');
    return sb.toString().trim();
  }
}

enum ExtensionSetupPhase {
  export,
  uac,
  verify,
  needsManualCleanup,
  done,
  failed,
}

final class ExtensionSetupAutomationResult {
  const ExtensionSetupAutomationResult({
    required this.ok,
    required this.phase,
    required this.message,
    this.chromePath,
    this.firefoxPath,
    this.verify,
    this.firefoxVerify,
    this.hasUnpackedCopy = false,
    this.usesLoadExtensionShortcut = false,
    this.guardLog,
    this.portableBatPath,
    this.desktopBatPath,
  });

  final bool ok;
  final ExtensionSetupPhase phase;
  final String message;
  final String? chromePath;
  final String? firefoxPath;
  final ExtensionPolicyVerifyResult? verify;
  final FirefoxInstallVerifyResult? firefoxVerify;
  final bool hasUnpackedCopy;
  final bool usesLoadExtensionShortcut;
  final String? guardLog;
  final String? portableBatPath;
  final String? desktopBatPath;
}
