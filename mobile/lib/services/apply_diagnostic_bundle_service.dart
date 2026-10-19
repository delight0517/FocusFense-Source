import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/apply_activation_report.dart';
import 'automated_browser_handoff_service.dart';
import 'build_identity_service.dart';
import 'chromium_policy_service.dart';
import 'extension_rules_builder.dart';
import 'windows_dns_lock_service.dart';
import 'windows_emergency_block_service.dart';
import 'windows_extension_guard_service.dart';
import 'windows_hidden_process.dart';
import 'windows_hkcu_policy_service.dart';
import 'windows_system_block_service.dart';
import 'windows_uac_apply_session.dart';
import 'youtube_video_block_resolver.dart';

/// Rich clipboard bundle for 「시스템 차단 적용」→「전체 복사」.
final class ApplyDiagnosticBundleService {
  ApplyDiagnosticBundleService._();
  static final ApplyDiagnosticBundleService instance =
      ApplyDiagnosticBundleService._();

  static const List<String> kDefaultProbeVideos = <String>[
    'wCrc7vy_Tmk',
    'lDRT5e6JsY4',
    'so-Rv8RlCUc',
    'oYVEqFdjNDs',
  ];

  Future<String> buildForClipboard({
    ApplyActivationReport? report,
    bool userCancelled = false,
    Object? error,
    int elapsedSec = 0,
    List<String>? probeVideoIds,
  }) async {
    final StringBuffer b = StringBuffer();
    final DateTime now = DateTime.now();
    b.writeln('=== 6 VPN Blocker · 시스템 차단 진단 번들 ===');
    b.writeln('생성: ${now.toIso8601String()}');
    b.writeln('경과: ${elapsedSec}s');
    if (userCancelled) b.writeln('상태: 사용자 취소');
    b.writeln();

    b.writeln('── 빌드 / 환경 ──');
    b.writeln(await BuildIdentityService.instance.summaryLine());
    b.writeln('OS: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}');
    b.writeln('locale: ${Platform.localeName}');
    b.writeln('USER: ${Platform.environment['USERNAME'] ?? '?'}');
    b.writeln('COMPUTER: ${Platform.environment['COMPUTERNAME'] ?? '?'}');
    b.writeln('LOCALAPPDATA: ${Platform.environment['LOCALAPPDATA'] ?? '?'}');
    b.writeln('ProgramFiles: ${Platform.environment['ProgramFiles'] ?? '?'}');
    b.writeln('WINDIR: ${Platform.environment['WINDIR'] ?? '?'}');
    b.writeln('UAC active: ${WindowsUacApplySession.instance.isActive}');
    b.writeln('UAC cancel requested: ${WindowsUacApplySession.instance.cancelRequested}');
    b.writeln();

    if (Platform.isWindows) {
      b.writeln('── 네트워크 / DNS ──');
      b.writeln(await _runPsSnippet(r'''
$dns = Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
  Select-Object InterfaceAlias, ServerAddresses
if ($dns) { $dns | ForEach-Object { "$($_.InterfaceAlias): $($_.ServerAddresses -join ', ')" } }
else { 'Get-DnsClientServerAddress failed' }
$svc = Get-Service -Name Dnscache -ErrorAction SilentlyContinue
if ($svc) { "Dnscache: $($svc.Status)" }
'''));
      b.writeln();

      b.writeln('── Chrome / Edge / Firefox 상태 ──');
      try {
        final BrowserProcessProbe browsers =
            await AutomatedBrowserHandoffService.probeBrowsers();
        b.writeln(
          'chrome running=${browsers.chromeRunning} protected=${browsers.chromeProtected} '
          'unprotected=${browsers.chromeUnprotected}',
        );
        b.writeln(
          'edge running=${browsers.edgeRunning} protected=${browsers.edgeProtected}',
        );
      } catch (e) {
        b.writeln('browser probe error: $e');
      }
      try {
        final ExtensionPolicyVerifyResult ext =
            await WindowsExtensionGuardService.verifyAllPolicies();
        b.writeln('extension protectionOk=${ext.protectionOk}');
        b.writeln('chrome forcelist=${ext.chromeForcelistOk} loadExt=${ext.chromeLoadExtensionFallbackOk}');
      } catch (e) {
        b.writeln('extension verify error: $e');
      }
      b.writeln();

      b.writeln('── HKCU URLBlocklist (관리자 없음) ──');
      final bool hkcuActive = await WindowsHkcuPolicyService.instance.isActive();
      b.writeln('HKCU blocklist active: $hkcuActive');
      b.writeln(await _runPsSnippet(r'''
$keys = @(
  'HKCU:\SOFTWARE\Policies\Google\Chrome\URLBlocklist',
  'HKCU:\SOFTWARE\Policies\Microsoft\Edge\URLBlocklist'
)
foreach ($k in $keys) {
  if (Test-Path -LiteralPath $k) {
    $n = (Get-Item -LiteralPath $k).Property.Count
    Write-Output "$k entries=$n"
  } else { Write-Output "$k missing" }
}
$chrome = 'HKCU:\SOFTWARE\Policies\Google\Chrome'
if (Test-Path $chrome) {
  $doh = (Get-ItemProperty -Path $chrome -Name DnsOverHttpsMode -ErrorAction SilentlyContinue).DnsOverHttpsMode
  $dns = (Get-ItemProperty -Path $chrome -Name BuiltInDnsClientEnabled -ErrorAction SilentlyContinue).BuiltInDnsClientEnabled
  Write-Output "Chrome DnsOverHttpsMode=$doh BuiltInDnsClientEnabled=$dns"
}
'''));
      b.writeln();

      b.writeln('── Program Files policies.json (UAC 경로) ──');
      b.writeln(await _runPsSnippet(r'''
$paths = @(
  "$env:ProgramFiles\Google\Chrome\Application\policies\managed\policies.json",
  "$env:ProgramFiles\Microsoft\Edge\Application\policies\managed\policies.json"
)
foreach ($p in $paths) { Write-Output "$p exists=$(Test-Path -LiteralPath $p)" }
'''));
      b.writeln();

      b.writeln('── hosts / PAC / 싱크홀 ──');
      final String? hosts =
          await WindowsSystemBlockService.tryReadSystemHostsNormalized();
      b.writeln('hosts readable: ${hosts != null}');
      if (hosts != null) {
        b.writeln(
          'hosts markers: start=${hosts.contains('# === 6 VPN Blocker BEGIN')} '
          'end=${hosts.contains('# === 6 VPN Blocker END')}',
        );
        b.writeln('hosts lines: ${hosts.split(RegExp(r'\r?\n')).length}');
      }
      final bool sinkPid = await File(WindowsDnsLockService.dnsPidPath()).exists();
      b.writeln('dns sinkhole pid file: $sinkPid');
      final EmergencyBlockResult emergency =
          await WindowsEmergencyBlockService.instance.readStatus();
      b.writeln('PAC applied: ${emergency.pacApplied} path=${emergency.pacPath}');
      b.writeln('extension rules hosts: ${emergency.extensionHostCount}');
      b.writeln();

      b.writeln('── 규칙 / YouTube 프로브 ──');
      try {
        final ExtensionRulesPayload rules =
            await ExtensionRulesBuilder.buildForBrowserEnforcement();
        b.writeln(
          'domains=${rules.blockedDomains.length} '
          'ytHandles=${rules.blockedYoutubeHandles.length} '
          'ytVideos=${rules.blockedYoutubeVideoIds.length} '
          'keywords=${rules.keywords.length}',
        );
        final List<String> patterns =
            await ChromiumPolicyService.activeBlocklistPatterns();
        b.writeln('URLBlocklist patterns (computed): ${patterns.length}');
        final List<String> probes = probeVideoIds ?? kDefaultProbeVideos;
        for (final String vid in probes) {
          final String lower = vid.toLowerCase();
          final bool inPatterns = patterns.any(
            (String pat) => pat.toLowerCase().contains(lower),
          );
          final YoutubeBlockCheckResult check =
              await YoutubeVideoBlockResolver.instance.checkVideo(vid);
          b.writeln(
            'watch?v=$vid → rules.blocked=${check.blocked} '
            'inURLBlocklist=$inPatterns '
            'channel=${check.channelHandle ?? check.channelId ?? "?"} '
            'matched=${check.matched ?? check.rule ?? "-"}',
          );
        }
      } catch (e) {
        b.writeln('rules probe error: $e');
      }
      b.writeln();

      b.writeln('── 관리자 transcript (마지막 40줄) ──');
      final String pd = Platform.environment['ProgramData'] ?? r'C:\ProgramData';
      final File transcript =
          File(p.join(pd, 'SixVPNBlocker', 'elevate_transcript.log'));
      if (await transcript.exists()) {
        try {
          final List<String> lines = await transcript.readAsLines();
          final int start = lines.length > 40 ? lines.length - 40 : 0;
          b.writeln(lines.sublist(start).join('\n'));
        } catch (e) {
          b.writeln('read failed: $e');
        }
      } else {
        b.writeln('(없음 — UAC 적용 전이거나 아직 기록 안 됨)');
      }
      b.writeln();
    }

    b.writeln('── 적용 결과 요약 ──');
    if (error != null) {
      b.writeln('오류: $error');
    }
    if (report != null) {
      b.writeln(report.success ? '활성화 완료' : '일부 실패');
      b.writeln(report.summary);
      b.writeln();
      for (final ApplyActivationStep s in report.steps) {
        b.writeln('${s.ok ? "OK" : "FAIL"}  ${s.label}');
        b.writeln('     ${s.detail}');
      }
    } else if (!userCancelled && error == null) {
      b.writeln('(적용 진행 중이거나 결과 없음)');
    }

    return b.toString().trimRight();
  }

  Future<String> _runPsSnippet(String body) async {
    if (!Platform.isWindows) return 'n/a';
    try {
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final ProcessResult r = await windowsRunHidden(
        p.join(windir, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'),
        <String>[
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-WindowStyle',
          'Hidden',
          '-Command',
          body,
        ],
      );
      final String out = '${r.stdout}'.trim();
      final String err = '${r.stderr}'.trim();
      if (out.isNotEmpty) return out;
      if (err.isNotEmpty) return 'stderr: $err';
      return '(empty, exit=${r.exitCode})';
    } catch (e) {
      return 'ps error: $e';
    }
  }
}
