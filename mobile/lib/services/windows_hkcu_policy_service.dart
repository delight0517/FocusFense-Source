import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import '../enforcement/layers/browser_policy_layer.dart';
import 'chrome_gmail_gemini_allowlist_service.dart';
import 'chromium_policy_service.dart';
import 'windows_url_blocklist_batch_service.dart';
import 'windows_hidden_process.dart';

/// Outcome of an HKCU policy apply / remove. Surfaced in the diagnostic
/// "지금 적용" dialog so the user sees what was installed even when the
/// elevated path (UAC) is being blocked by AV/EDR/group policy.
final class HkcuPolicyResult {
  const HkcuPolicyResult({
    required this.success,
    required this.message,
    this.installedCount = 0,
    this.patternCount = 0,
    this.targets = const <String>[],
  });

  final bool success;
  final String message;

  /// Number of browser hives successfully written to (0..11).
  final int installedCount;

  /// Number of URL patterns written per browser.
  final int patternCount;

  /// e.g. `['Chrome', 'Edge', 'Firefox']`.
  final List<String> targets;
}

/// **HKCU-only** Chrome / Edge / Chromium derivatives / Firefox blocklist installer.
///
/// **No UAC. No admin. No elevation.**
/// All three browsers honor `HKCU\Software\Policies\…` on Windows:
///
/// * Chrome / Edge — `URLBlocklist`, `BuiltInDnsClientEnabled`,
///   `DnsOverHttpsMode` (forces Windows DNS Client / hosts; disables DoH).
/// * Firefox 102+ — `WebsiteFilter\Block`, `DNSOverHTTPS\Enabled=0`,
///   `DNSOverHTTPS\Locked=1` (browser-level URL block + DoH off).
///
/// This is the **fallback path** when the elevated hosts/registry write
/// keeps failing with `result.txt 없음` (AV/EDR killing PowerShell, GPO
/// denying UAC, etc.). Even with hosts unmodified, this alone blocks
/// the user's three main browsers — which is what the user actually
/// uses to visit blocked sites.
///
/// Hot-reload: Chrome/Edge auto-refresh policy every ~30 min, or
/// `chrome://policy` → "Reload policies". Firefox needs a restart.
final class WindowsHkcuPolicyService {
  WindowsHkcuPolicyService._();
  static final WindowsHkcuPolicyService instance = WindowsHkcuPolicyService._();

  bool get isSupported => Platform.isWindows;

  String _powershellExe() {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return p.join(
      windir,
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
  }

  /// Writes Chrome/Edge/Firefox HKCU policies. Returns coverage in
  /// `result.targets`. Even partial success is good — every browser that
  /// reads the policy is now blocked.
  Future<HkcuPolicyResult> applyNow() async {
    if (!isSupported) {
      return const HkcuPolicyResult(
        success: false,
        message: 'Windows에서만 동작합니다.',
      );
    }

    try {
      final List<String> chromiumPatterns =
          await ChromiumPolicyService.activeBlocklistPatternsForChromium();
      final List<String> firefoxPatterns =
          await ChromiumPolicyService.activeBlocklistPatternsForFirefox();
      final bool hasPatterns =
          chromiumPatterns.isNotEmpty || firefoxPatterns.isNotEmpty;

      final List<String> targets = await WindowsUrlBlocklistBatchService
          .instance
          .applyActivePatterns();
      if (targets.isEmpty) {
        if (!hasPatterns) {
          return await removeNow();
        }
        if (await ChromeGmailGeminiAllowlistService.instance.enabled()) {
          await ChromeGmailGeminiAllowlistService.instance.applyNow();
        }
        return HkcuPolicyResult(
          success: false,
          message: 'HKCU URLBlocklist 적용 대상 없음 — 활성 패턴은 있으므로 기존 정책은 삭제하지 않음',
          patternCount: chromiumPatterns.length,
        );
      }

      final int installed = targets.length;

      if (installed == 0) {
        return HkcuPolicyResult(
          success: false,
          message: 'HKCU URLBlocklist 배치 적용 실패 (Chrome/Edge/파생/Firefox)',
          patternCount: chromiumPatterns.length,
        );
      }

      if (await ChromeGmailGeminiAllowlistService.instance.enabled()) {
        await ChromeGmailGeminiAllowlistService.instance.applyNow();
      }

      return HkcuPolicyResult(
        success: true,
        message:
            'HKCU 정책 설치됨 → ${targets.join(", ")} '
            '(Chromium ${chromiumPatterns.length} · Firefox ${firefoxPatterns.length}개, '
            'Chrome Gmail/Gemini=${await ChromeGmailGeminiAllowlistService.instance.enabled() ? "ON" : "OFF"})',
        installedCount: installed,
        patternCount: chromiumPatterns.length,
        targets: targets,
      );
    } catch (e, st) {
      AppLogger.instance.error('hkcu policy run failed', error: e);
      AppLogger.instance.log('DEBUG', 'hkcu stack', stack: st);
      return HkcuPolicyResult(
        success: false,
        message: 'HKCU 정책 실행 실패: $e',
        patternCount: 0,
      );
    }
  }

  /// Removes journaled list values, preserving unrelated or subsequently edited
  /// entries. Machine values can require the full OFF elevated cleanup.
  Future<HkcuPolicyResult> removeNow() async {
    if (!isSupported) {
      return const HkcuPolicyResult(success: false, message: 'unsupported');
    }
    final String ps =
        BrowserPolicyLayer.ownedListsPowerShell() +
        "\n\$ErrorActionPreference = 'Stop'; Restore-FFOwnedLists; exit 0\n";

    try {
      final ProcessResult pr =
          await windowsRunHidden(_powershellExe(), <String>[
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy',
            'Bypass',
            '-WindowStyle',
            'Hidden',
            '-Command',
            ps,
          ]);
      final String out = (pr.stdout ?? '').toString().trim();
      AppLogger.instance.info('hkcu policy remove: exit=${pr.exitCode}\n$out');
      return HkcuPolicyResult(
        success: pr.exitCode == 0,
        message: pr.exitCode == 0
            ? '기록된 FocusFense URL 정책 정리 완료. 기록이 없는 이전 정책은 별도 확인이 필요합니다.'
            : 'HKCU 정책 제거 실패\n$out',
      );
    } catch (e) {
      AppLogger.instance.error('hkcu policy remove failed', error: e);
      return HkcuPolicyResult(success: false, message: 'HKCU 정책 제거 실행 실패: $e');
    }
  }

  /// Quick check (for diagnostics UI): is any of Chrome/Edge/Firefox HKCU
  /// blocklist populated right now?
  Future<bool> isActive() async {
    if (!isSupported) return false;
    const String ps = r'''
$keys = @(
  'HKCU:\SOFTWARE\Policies\Google\Chrome\URLBlocklist',
  'HKCU:\SOFTWARE\Policies\Microsoft\Edge\URLBlocklist',
  'HKCU:\SOFTWARE\Policies\Mozilla\Firefox\WebsiteFilter\Block'
)
foreach ($k in $keys) {
  if (Test-Path -LiteralPath $k) {
    $vals = (Get-Item -LiteralPath $k).Property
    if ($vals -and $vals.Count -gt 0) { Write-Output 'YES'; exit 0 }
  }
}
Write-Output 'NO'
exit 0
''';
    try {
      final ProcessResult pr =
          await windowsRunHidden(_powershellExe(), <String>[
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy',
            'Bypass',
            '-WindowStyle',
            'Hidden',
            '-Command',
            ps,
          ]);
      return (pr.stdout ?? '').toString().contains('YES');
    } catch (_) {
      return false;
    }
  }

  Future<bool> hasRequiredBrowserPolicies() async {
    if (!isSupported) return false;
    const String ps = r'''
function Has-Values([string]$Key) {
  if (-not (Test-Path -LiteralPath $Key)) { return $false }
  $vals = (Get-Item -LiteralPath $Key).Property
  return ($vals -and $vals.Count -gt 0)
}
function Has-Opera-PolicyFile {
  $file = Join-Path $env:APPDATA 'Opera Software\Opera Stable\policies\managed\policies.json'
  if (-not (Test-Path -LiteralPath $file)) { return $false }
  try {
    $raw = Get-Content -LiteralPath $file -Raw -ErrorAction Stop
    return (($raw -match '"URLBlocklist"') -and (($raw -match 'youtube\.com') -or ($raw -match 'youtu\.be')))
  } catch {
    return $false
  }
}
$ok = Has-Values 'HKCU:\SOFTWARE\Policies\Google\Chrome\URLBlocklist'
$operaPaths = @(
  (Join-Path $env:LOCALAPPDATA 'Programs\Opera\opera.exe'),
  (Join-Path $env:ProgramFiles 'Opera\opera.exe')
)
if (${env:ProgramFiles(x86)}) {
  $operaPaths += (Join-Path ${env:ProgramFiles(x86)} 'Opera\opera.exe')
}
$operaInstalled = $false
foreach ($path in $operaPaths) {
  if ($path -and (Test-Path -LiteralPath $path)) {
    $operaInstalled = $true
    break
  }
}
if ($operaInstalled) {
  $operaHkcuOk = Has-Values 'HKCU:\SOFTWARE\Policies\Opera Software\Opera Stable\URLBlocklist'
  $ok = $ok -and ($operaHkcuOk -or (Has-Opera-PolicyFile))
}
Write-Output ($(if ($ok) { 'YES' } else { 'NO' }))
''';
    try {
      final ProcessResult pr =
          await windowsRunHidden(_powershellExe(), <String>[
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy',
            'Bypass',
            '-WindowStyle',
            'Hidden',
            '-Command',
            ps,
          ]);
      return (pr.stdout ?? '').toString().contains('YES');
    } catch (_) {
      return false;
    }
  }
}
