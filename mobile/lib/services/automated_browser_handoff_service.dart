import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_block_user_notice_service.dart';
import 'app_logger.dart';
import 'block_activity_log_service.dart';
import 'blocking_self_heal_prefs.dart';
import 'chrome_load_extension_launcher.dart';
import 'chrome_shortcut_hijack_service.dart';
import 'extension_rules_builder.dart';
import 'own_kill_ledger.dart';
import 'protected_browser_realtime_guard_service.dart';
import 'chrome_extension_state_probe.dart';
import 'windows_hidden_process.dart';
import 'windows_protection_mode_prefs.dart';

/// Zero-touch: user never has to close Chrome / tap 「Chrome 열기」 manually.
final class AutomatedBrowserHandoffService {
  AutomatedBrowserHandoffService._();
  static final AutomatedBrowserHandoffService instance =
      AutomatedBrowserHandoffService._();

  static const Duration kCooldown = Duration(minutes: 4);
  DateTime? _lastRun;

  Future<AutomatedHandoffResult> runZeroTouch({
    required String reason,
    bool force = false,
  }) async {
    if (WindowsProtectionModePrefs.isProtectionExplicitlyOff) {
      return const AutomatedHandoffResult(
        ok: true,
        message: '수동 보호가 꺼져 있어 브라우저 전환을 건너뜁니다.',
        skipped: true,
        actions: <String>['manual_protection_off'],
      );
    }
    if (!Platform.isWindows) {
      return const AutomatedHandoffResult(
        ok: true,
        message: 'Windows 전용',
        actions: <String>[],
      );
    }
    if (!await BlockingSelfHealPrefs.instance.zeroTouchHandoff() && !force) {
      return const AutomatedHandoffResult(
        ok: true,
        message: 'Zero-touch 꺼짐',
        skipped: true,
        actions: <String>[],
      );
    }
    final DateTime now = DateTime.now();
    if (!force && _lastRun != null && now.difference(_lastRun!) < kCooldown) {
      return AutomatedHandoffResult(
        ok: true,
        message: '최근 자동 전환됨',
        skipped: true,
        actions: const <String>[],
      );
    }
    _lastRun = now;

    final List<String> actions = <String>[];
    final ExtensionRulesPayload rules =
        await ExtensionRulesBuilder.buildActiveNow();
    final bool needsBrowser =
        rules.hasYoutubeChannelBlocks ||
        rules.blockedDomains.isNotEmpty ||
        rules.keywords.isNotEmpty;

    BrowserProcessProbe before = await _probeBrowsers();
    actions.add(
      'probe_before:c${before.chromeProtected}/u${before.chromeUnprotected}',
    );

    final String? extFolder = await _extensionFolder();
    if (extFolder != null) {
      final ShortcutHijackResult hijack = await ChromeShortcutHijackService
          .instance
          .apply(extensionFolder: extFolder, force: true);
      if (hijack.patchedCount > 0) {
        actions.add('hijack:${hijack.patchedCount}');
      }
    }

    final String? migrated = await ProtectedBrowserRealtimeGuardService.instance
        .runOnce();
    if (migrated != null && migrated != 'none') {
      actions.add('migrated:$migrated');
    }

    BrowserProcessProbe mid = await _probeBrowsers();

    // @incident: BROWSER_BLOCK_PIPELINE_POSTMORTEM §2.3 — never cold-launch
    // a browser here, caused random Chrome pop-ups. Only piggyback on a
    // window the user already opened.
    // The "zero-touch" handoff used to launch Chrome **cold** when rules
    // existed and Chrome wasn't running. That caused Chrome to pop open
    // randomly every time this service fired (boot, resume, periodic, etc.).
    // We now ONLY launch the protected Chrome/Edge if the user already has
    // an unprotected Chrome/Edge window open — that's a legitimate handoff,
    // not a cold-launch surprise.
    //
    // See docs/BROWSER_BLOCK_PIPELINE_POSTMORTEM.md §2.3 — DO NOT reintroduce
    // a "cold launch" path here. If you think you need one, you don't — read
    // the doc and use BlockActivityLogService events instead.
    if (force &&
        needsBrowser &&
        !mid.chromeProtected &&
        mid.chromeUnprotected) {
      await ChromeLoadExtensionLauncher.launchChrome();
      actions.add('launch_protected_chrome');
      await Future<void>.delayed(const Duration(seconds: 2));
      await ProtectedBrowserRealtimeGuardService.instance.runOnce();
      actions.add('handoff_pass2');
    }

    if (force && needsBrowser && !mid.edgeProtected && mid.edgeUnprotected) {
      await ChromeLoadExtensionLauncher.launchEdge();
      actions.add('launch_protected_edge');
    }

    final BrowserProcessProbe after = await _probeBrowsers();
    final bool chromeOk = await isChromeEffectivelyProtected();
    final bool rulesFetch = await _waitForExtensionPing(
      timeout: const Duration(seconds: 18),
    );
    if (rulesFetch) actions.add('rules_fetch_ok');

    final bool ok =
        !needsBrowser || chromeOk || after.edgeProtected || rulesFetch;

    final String message = ok
        ? (after.chromeProtected
              ? 'Chrome 보호 모드 자동 적용됨 — 별도 조작 불필요'
              : '브라우저 보호 자동 점검 완료')
        : 'Chrome 보호 자동 전환 시도함 — 잠시 후 앱이 다시 점검합니다';

    BlockActivityLogService.instance.record(
      kind: BlockActivityKind.selfHeal,
      message: message,
      data: <String, Object?>{
        'reason': reason,
        'chromeProtected': after.chromeProtected,
        'chromeUnprotected': after.chromeUnprotected,
        'edgeProtected': after.edgeProtected,
        'rulesFetch': rulesFetch,
        'actions': actions,
      },
      debounceKey: 'zero_touch_handoff',
    );
    AppLogger.instance.info('zero_touch [$reason] ok=$ok actions=$actions');

    return AutomatedHandoffResult(
      ok: ok,
      message: message,
      chromeProtected: after.chromeProtected,
      edgeProtected: after.edgeProtected,
      rulesFetchSeen: rulesFetch,
      actions: actions,
    );
  }

  Future<String?> _extensionFolder() async {
    final String stable = ChromeLoadExtensionLauncher.stableChromeExtDir;
    if (await File(p.join(stable, 'manifest.json')).exists()) return stable;
    return null;
  }

  Future<bool> _waitForExtensionPing({required Duration timeout}) async {
    final DateTime deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (BlockActivityLogService.instance.events.any(
        (BlockActivityEvent e) => e.kind == BlockActivityKind.rulesFetch,
      )) {
        return true;
      }
      try {
        final File sum = File(BlockActivityLogService.instance.summaryPath);
        if (await sum.exists()) {
          final Object? decoded = jsonDecode(await sum.readAsString());
          if (decoded is Map) {
            final List<dynamic> events =
                decoded['recentEvents'] as List<dynamic>? ?? <dynamic>[];
            for (final dynamic e in events) {
              if (e is Map && e['kind'] == 'rulesFetch') return true;
            }
          }
        }
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 800));
    }
    return false;
  }

  /// True when Chrome has the extension properly installed (prefs + cmdline check).
  static Future<bool> isChromeEffectivelyProtected() async {
    final BrowserProcessProbe probe = await probeBrowsers();
    if (probe.chromeRunning) {
      // load-extension OR HKCU PAC+URLBlocklist (plain chrome.exe).
      return probe.chromeProtected && !probe.chromeUnprotected;
    }

    final ChromeExtensionProbeResult prefsProbe =
        await ChromeExtensionStateProbe.probe(browser: 'chrome');
    if (prefsProbe.extensionNotPresent) return false;
    return prefsProbe.hasRegistryManaged || prefsProbe.hasUnpackedCopy;
  }

  /// Force-stops every chrome.exe (handoff — user tapped 「보호 Chrome으로 전환」).
  static Future<int> forceStopAllChrome() async {
    if (!Platform.isWindows) return 0;
    try {
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      const String reason = '보호 Chrome으로 전환 — 사용자 요청';
      OwnKillLedger.instance.stampImage(
        imageName: 'chrome.exe',
        reason: reason,
        reasonKey: 'handoff_force_stop',
      );
      final ProcessResult r = await windowsRunHidden(
        p.join(windir, 'System32', 'taskkill.exe'),
        <String>['/F', '/IM', 'chrome.exe'],
      );
      if (r.exitCode == 0 || r.exitCode == 128) {
        AppBlockUserNoticeService.instance.notifyBrowserKilledWithReason(
          browserOrAppDisplayName: 'Chrome',
          reasonKo: reason,
          debounceKey: 'handoff_force_stop',
        );
        return 1;
      }
    } catch (_) {}
    return 0;
  }

  /// Closes main-frame Chrome processes that lack --load-extension.
  /// 6 VPN: neutralized 2026-06-10. Plain chrome.exe (taskbar pin, Run dialog)
  /// was being auto-killed within seconds — user opens Chrome, then it vanishes.
  /// Block layers (hosts + URLBlocklist + extension when present + window-title
  /// log) are sufficient; no need to terminate the whole browser process.
  static Future<int> closeUnprotectedChrome() async {
    return 0;
  }

  static Future<BrowserProcessProbe> probeBrowsers() => _probeBrowsers();

  static Future<BrowserProcessProbe> _probeBrowsers() async {
    if (!Platform.isWindows) {
      return const BrowserProcessProbe(
        chromeRunning: false,
        chromeProtected: false,
        chromeUnprotected: false,
        edgeRunning: false,
        edgeProtected: false,
        edgeUnprotected: false,
      );
    }
    const String ps = r'''
$sixDir = 'SIXVPN_DIR'
$policyFlag = Join-Path $sixDir 'chrome_policy_active.flag'
$policyActive = (Test-Path -LiteralPath $policyFlag) -and ((Get-Content -LiteralPath $policyFlag -Raw).Trim() -eq '1')
function Test-Protected([string]$cmd, [string]$browser) {
  if ([string]::IsNullOrWhiteSpace($cmd)) { return $false }
  if ($cmd -match 'load-extension|disable-extensions-except|chrome_blocker|sixvpnblocker') { return $true }
  if ($policyActive -and ($browser -eq 'chrome' -or $browser -eq 'edge')) { return $true }
  return $false
}
function MainCount([string]$name) {
  @(Get-CimInstance Win32_Process -Filter "Name='$name'" -EA SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -notmatch '--type=' }).Count
}
function ProtectedCount([string]$name, [string]$browser) {
  @(Get-CimInstance Win32_Process -Filter "Name='$name'" -EA SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -notmatch '--type=' -and (Test-Protected $_.CommandLine $browser) }).Count
}
$cr = MainCount 'chrome.exe'
$cp = ProtectedCount 'chrome.exe' 'chrome'
$er = MainCount 'msedge.exe'
$ep = ProtectedCount 'msedge.exe' 'edge'
Write-Output "chrome_run=$cr chrome_prot=$cp edge_run=$er edge_prot=$ep"
''';
    final String probePs = ps.replaceAll(
      'SIXVPN_DIR',
      ChromeLoadExtensionLauncher.sixVpnDir.replaceAll("'", "''"),
    );
    try {
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final ProcessResult r = await windowsRunHidden(
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
          '-Command',
          probePs,
        ],
      );
      final String out = '${r.stdout}'.trim();
      int cr = 0, cp = 0, er = 0, ep = 0;
      final RegExpMatch? m1 = RegExp(r'chrome_run=(\d+)').firstMatch(out);
      final RegExpMatch? m2 = RegExp(r'chrome_prot=(\d+)').firstMatch(out);
      final RegExpMatch? m3 = RegExp(r'edge_run=(\d+)').firstMatch(out);
      final RegExpMatch? m4 = RegExp(r'edge_prot=(\d+)').firstMatch(out);
      if (m1 != null) cr = int.tryParse(m1.group(1)!) ?? 0;
      if (m2 != null) cp = int.tryParse(m2.group(1)!) ?? 0;
      if (m3 != null) er = int.tryParse(m3.group(1)!) ?? 0;
      if (m4 != null) ep = int.tryParse(m4.group(1)!) ?? 0;
      return BrowserProcessProbe(
        chromeRunning: cr > 0,
        chromeProtected: cp > 0,
        chromeUnprotected: cr > cp,
        edgeRunning: er > 0,
        edgeProtected: ep > 0,
        edgeUnprotected: er > ep,
      );
    } catch (_) {
      return const BrowserProcessProbe(
        chromeRunning: false,
        chromeProtected: false,
        chromeUnprotected: false,
        edgeRunning: false,
        edgeProtected: false,
        edgeUnprotected: false,
      );
    }
  }
}

final class BrowserProcessProbe {
  const BrowserProcessProbe({
    required this.chromeRunning,
    required this.chromeProtected,
    required this.chromeUnprotected,
    required this.edgeRunning,
    required this.edgeProtected,
    required this.edgeUnprotected,
  });

  final bool chromeRunning;
  final bool chromeProtected;
  final bool chromeUnprotected;
  final bool edgeRunning;
  final bool edgeProtected;
  final bool edgeUnprotected;
}

final class AutomatedHandoffResult {
  const AutomatedHandoffResult({
    required this.ok,
    required this.message,
    required this.actions,
    this.skipped = false,
    this.chromeProtected = false,
    this.edgeProtected = false,
    this.rulesFetchSeen = false,
  });

  final bool ok;
  final bool skipped;
  final String message;
  final bool chromeProtected;
  final bool edgeProtected;
  final bool rulesFetchSeen;
  final List<String> actions;
}
