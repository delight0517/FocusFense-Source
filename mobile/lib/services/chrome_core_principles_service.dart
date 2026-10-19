import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'block_activity_log_service.dart';
import 'extension_rules_builder.dart';
import 'universal_browser_block_service.dart';
import 'windows_extension_guard_service.dart';
import 'windows_hidden_process.dart';
import 'windows_hosts_lock_service.dart';

/// Core blocker blueprint (user-requested):
///
/// **A.** Chrome/Edge enterprise policy — ExtensionInstallForcelist,
///     URLBlocklist, ExtensionSettings (no delete / no dev mode).
/// **B.** hosts file lock after UAC apply (read-only + Users deny write).
/// **C.** Standard-user account — app probes admin membership and advises.
///
/// Chrome focus: specific sites + YouTube channels + channel video IDs via
/// [ExtensionRulesBuilder] → HKCU URLBlocklist + extension DOM + PAC.
final class ChromeCorePrinciplesService {
  ChromeCorePrinciplesService._();
  static final ChromeCorePrinciplesService instance =
      ChromeCorePrinciplesService._();

  static String _psExe() {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return p.join(windir, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  }

  /// Push A (browser policy + extension) on every meaningful rule change.
  Future<CorePrinciplesApplyResult> applyNow({String reason = 'core'}) async {
    if (!Platform.isWindows) {
      return const CorePrinciplesApplyResult(
        ok: false,
        message: 'Windows 전용',
      );
    }
    final UniversalBlockResult browser =
        await UniversalBrowserBlockService.instance.syncNow(reason: reason);
    final ExtensionPolicyVerifyResult verify =
        await WindowsExtensionGuardService.verifyAllPolicies();

    final CorePrinciplesStatus status = await probe();

    final bool ok = browser.ok && (verify.chromeHkcuForcelistOk || verify.chromeForcelistOk);
    final String msg = ok
        ? '핵심 원리 A 적용 — Chrome 정책·확장 강제 (${status.youtubeVideoCount}영상·${status.youtubeHandleCount}채널)'
        : '일부 정책 미적용 — 진단에서 「Chrome 보호」재시도';

    BlockActivityLogService.instance.record(
      kind: BlockActivityKind.protection,
      message: msg,
      data: <String, Object?>{
        'reason': reason,
        'principleA': status.principleA,
        'principleB': status.principleB,
        'principleC': status.principleC,
      },
      debounceKey: 'core_principles',
    );
    AppLogger.instance.info('core_principles [$reason] ok=$ok A=${status.principleA}');

    return CorePrinciplesApplyResult(ok: ok, message: msg, status: status);
  }

  /// Read-only status for diagnostics / UI chips.
  Future<CorePrinciplesStatus> probe() async {
    if (!Platform.isWindows) {
      return const CorePrinciplesStatus(
        principleA: false,
        principleB: false,
        principleC: false,
        adminAccount: true,
        message: 'Windows 전용',
      );
    }

    final ExtensionPolicyVerifyResult v =
        await WindowsExtensionGuardService.verifyAllPolicies();
    final HostsLockStatus hostsLock =
        await WindowsHostsLockService.instance.probe();
    final bool admin = await _isRunningAsAdmin();

    final ExtensionRulesPayload rules =
        await ExtensionRulesBuilder.buildForBrowserEnforcement();

    final bool principleA = v.chromeHkcuForcelistOk ||
        v.chromeForcelistOk ||
        (v.chromeHkcuOk && v.chromeOk);
    final bool principleB = hostsLock.locked || hostsLock.readOnly;
    // C: recommended when blocker user is NOT admin (can't undo policies easily).
    final bool principleC = !admin;

    final List<String> parts = <String>[
      if (principleA) 'A:Chrome정책' else 'A:미적용',
      if (principleB) 'B:hosts잠금' else 'B:hosts열림',
      if (principleC) 'C:표준계정(권장)' else 'C:관리자계정(표준권장)',
    ];

    return CorePrinciplesStatus(
      principleA: principleA,
      principleB: principleB,
      principleC: principleC,
      adminAccount: admin,
      hostsLock: hostsLock,
      forcelistOk: v.chromeHkcuForcelistOk || v.chromeForcelistOk,
      urlBlocklistOk: v.chromeHkcuOk,
      youtubeHandleCount: rules.blockedYoutubeHandles.length,
      youtubeVideoCount: rules.blockedYoutubeVideoIds.length,
      domainCount: rules.blockedDomains.length,
      message: parts.join(' · '),
    );
  }

  static Future<bool> _isRunningAsAdmin() async {
    try {
      final ProcessResult r = await windowsRunHidden(
        _psExe(),
        <String>[
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          r'''
$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Write-Output "admin=$admin"
''',
        ],
      );
      return '${r.stdout}'.contains('admin=True');
    } catch (_) {
      return false;
    }
  }
}

final class CorePrinciplesStatus {
  const CorePrinciplesStatus({
    required this.principleA,
    required this.principleB,
    required this.principleC,
    required this.adminAccount,
    required this.message,
    this.hostsLock,
    this.forcelistOk = false,
    this.urlBlocklistOk = false,
    this.youtubeHandleCount = 0,
    this.youtubeVideoCount = 0,
    this.domainCount = 0,
  });

  final bool principleA;
  final bool principleB;
  final bool principleC;
  final bool adminAccount;
  final HostsLockStatus? hostsLock;
  final bool forcelistOk;
  final bool urlBlocklistOk;
  final int youtubeHandleCount;
  final int youtubeVideoCount;
  final int domainCount;
  final String message;

  bool get allRecommended => principleA && (principleB || principleC);
}

final class CorePrinciplesApplyResult {
  const CorePrinciplesApplyResult({
    required this.ok,
    required this.message,
    this.status,
  });

  final bool ok;
  final String message;
  final CorePrinciplesStatus? status;
}
