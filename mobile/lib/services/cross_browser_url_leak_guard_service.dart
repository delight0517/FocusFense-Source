import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/cross_browser_leak_scenario.dart';
import 'app_logger.dart';
import 'automated_browser_handoff_service.dart';
import 'chrome_extension_payload_service.dart';
import 'chrome_load_extension_launcher.dart';
import 'chrome_shortcut_hijack_service.dart';
import 'firefox_config_service.dart';
import 'tier_enforcement_service.dart';
import 'windows_browser_bypass_closer_service.dart';
import 'windows_chromium_registry_service.dart';
import 'windows_emergency_block_service.dart';
import 'windows_hidden_process.dart';

/// Seals five cross-browser URL-block leak paths on every universal sync.
///
/// See [CrossBrowserLeakScenario] for the catalog. Each scenario maps to an
/// independent fix — one failure does not skip the rest.
final class CrossBrowserUrlLeakGuardService {
  CrossBrowserUrlLeakGuardService._();
  static final CrossBrowserUrlLeakGuardService instance =
      CrossBrowserUrlLeakGuardService._();

  static String _psExe() {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return p.join(
      windir,
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
  }

  /// Run all five leak seals. Called from [UniversalBrowserBlockService].
  Future<CrossBrowserLeakGuardReport> sealAll({String reason = 'sync'}) async {
    if (!Platform.isWindows) {
      return const CrossBrowserLeakGuardReport(
        ok: true,
        message: 'Windows 전용',
        sealed: <CrossBrowserLeakScenario>[],
        steps: <String>[],
      );
    }

    final List<String> steps = <String>[];
    final List<CrossBrowserLeakScenario> sealed = <CrossBrowserLeakScenario>[];

    // ① Plain browser launch — shortcuts + HKCU Start Menu override.
    final bool s1 = await _sealPlainLaunch(steps);
    if (s1) sealed.add(CrossBrowserLeakScenario.plainBrowserLaunch);

    // ②⑤ Derivative + policy precedence — single bypass closer pass.
    final BypassCloserResult closerResult = await _runBypassCloser(steps);
    if (_derivativeSealed(closerResult)) {
      sealed.add(CrossBrowserLeakScenario.derivativeChromiumGap);
    }
    if (_policySealed(closerResult)) {
      sealed.add(CrossBrowserLeakScenario.policyPrecedenceBypass);
    }

    // ③ Firefox DoH + private + PAC autoconfig in profiles.
    final bool s3 = await _sealFirefoxNetwork(steps);
    if (s3) sealed.add(CrossBrowserLeakScenario.firefoxDohOrPrivate);

    // ④ Network stack — DNS/QUIC on primary Chromium roots.
    final bool s4 = await _sealNetworkStack(steps);
    if (s4) sealed.add(CrossBrowserLeakScenario.networkStackBypass);

    final String msg =
        '브라우저 간 URL 누수 방어 ${sealed.length}/5 — ${sealed.map((CrossBrowserLeakScenario s) => s.title).join(", ")}';
    AppLogger.instance.info('cross_browser_leak_guard [$reason]: $msg steps=$steps');

    return CrossBrowserLeakGuardReport(
      ok: sealed.length >= 3,
      message: msg,
      sealed: sealed,
      steps: steps,
    );
  }

  Future<bool> _sealPlainLaunch(List<String> steps) async {
    try {
      final String? folder =
          await ChromeExtensionPayloadService.ensureStablePayload();
      if (folder != null && folder.isNotEmpty) {
        await ChromeLoadExtensionLauncher.install(extensionFolder: folder);
        final ShortcutHijackResult hijack =
            await ChromeShortcutHijackService.instance.apply(
          extensionFolder: folder,
          force: true,
        );
        steps.add('hijack=${hijack.patchedCount}');
        await TierEnforcementService.instance.runTier3Once();
        steps.add('tier3_shortcut_repatch');
      }
      await _ensureUserChromeStartMenuOverride(steps);
      final AutomatedHandoffResult handoff =
          await AutomatedBrowserHandoffService.instance.runZeroTouch(
        reason: 'leak_guard',
        force: false,
      );
      if (!handoff.skipped) {
        steps.add('handoff:${handoff.actions.join("|")}');
      }
      return true;
    } catch (e) {
      steps.add('plain_launch_fail:$e');
      return false;
    }
  }

  Future<void> _ensureUserChromeStartMenuOverride(List<String> steps) async {
    final String vbs = ChromeLoadExtensionLauncher.chromeVbsPath;
    final String workDir = ChromeLoadExtensionLauncher.sixVpnDir;
    if (!await File(vbs).exists()) return;

    final String userLnk = p.join(
      Platform.environment['APPDATA'] ?? '',
      r'Microsoft\Windows\Start Menu\Programs',
      'Google Chrome.lnk',
    );
    final String ps = r'''
$vbs = 'VBS_PATH'
$work = 'WORK_DIR'
$chrome = @(
  (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
  (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
  (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
$lnk = 'USER_LNK'
try {
  $parent = Split-Path -Parent $lnk
  if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
  $sh = New-Object -ComObject WScript.Shell
  $sc = $sh.CreateShortcut($lnk)
  $sc.TargetPath = $vbs
  $sc.Arguments = ''
  $sc.WorkingDirectory = $work
  if ($chrome) { $sc.IconLocation = "$chrome,0" }
  $sc.Save()
  Write-Output 'user_chrome_override_ok'
} catch {
  Write-Output "user_chrome_override_fail:$($_.Exception.Message)"
}
'''
        .replaceAll('VBS_PATH', vbs.replaceAll("'", "''"))
        .replaceAll('WORK_DIR', workDir.replaceAll("'", "''"))
        .replaceAll('USER_LNK', userLnk.replaceAll("'", "''"));

    final ProcessResult pr = await windowsRunHidden(
      _psExe(),
      <String>[
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-Command',
        ps,
      ],
    );
    final String out = '${pr.stdout}'.trim();
    steps.add(out.contains('ok') ? 'user_chrome_lnk' : 'user_chrome_lnk_skip');
  }

  Future<BypassCloserResult> _runBypassCloser(List<String> steps) async {
    try {
      final BypassCloserResult r =
          await WindowsBrowserBypassCloserService.instance.applyAll();
      steps.addAll(r.steps);
      return r;
    } catch (e) {
      steps.add('bypass_closer_fail:$e');
      return BypassCloserResult(ok: false, message: '$e', steps: steps);
    }
  }

  bool _derivativeSealed(BypassCloserResult r) {
    return r.steps.any(
      (String s) =>
          s.startsWith('derivatives_') || s.startsWith('blocklist_'),
    );
  }

  bool _policySealed(BypassCloserResult r) {
    return r.steps.any(
      (String s) =>
          s.startsWith('allowlist_') ||
          s.startsWith('incognito_') ||
          s.startsWith('edge_ie_'),
    );
  }

  Future<bool> _sealFirefoxNetwork(List<String> steps) async {
    try {
      final String pac = WindowsEmergencyBlockService.pacPath();
      final List<String> profiles = await FirefoxConfigService.instance
          .applyNetworkBlockPrefsInAllProfiles(pacFilePath: pac);
      steps.add('firefox_profiles=${profiles.length}');
      return profiles.isNotEmpty || !await _firefoxInstalled();
    } catch (e) {
      steps.add('firefox_network_fail:$e');
      return false;
    }
  }

  Future<bool> _firefoxInstalled() async {
    final List<String> paths = <String>[
      p.join(
        Platform.environment['ProgramFiles'] ?? r'C:\Program Files',
        'Mozilla Firefox',
        'firefox.exe',
      ),
      p.join(
        Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)',
        'Mozilla Firefox',
        'firefox.exe',
      ),
    ];
    for (final String path in paths) {
      if (await File(path).exists()) return true;
    }
    return false;
  }

  Future<bool> _sealNetworkStack(List<String> steps) async {
    try {
      final String pacPath = WindowsEmergencyBlockService.pacPath();
      final bool primary =
          await WindowsChromiumRegistryService.instance.applyPacEverywhere(
        pacPath,
      );
      steps.add(primary ? 'pac_primary_ok' : 'pac_primary_fail');
      return primary;
    } catch (e) {
      steps.add('network_stack_fail:$e');
      return false;
    }
  }

}
