import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import '../enforcement/layers/browser_policy_layer.dart';
import 'browser_enforcement_readiness_service.dart';
import 'chrome_gmail_gemini_allowlist_service.dart';
import 'chromium_policy_service.dart';
import 'opera_chromium_policy_file_service.dart';
import 'windows_hidden_process.dart';

/// Writes Chrome/Edge + Chromium derivatives + Firefox blocklists in **one**
/// PowerShell `-File` invocation (patterns loaded from line-delimited sidecar).
///
/// Firefox receives channel/video patterns **without** YouTube apex rows.
/// Chromium gets full YouTube apex only when no Six VPN extension is ready;
/// with extension, YouTube is list-only (extension + per-channel URL rows).
/// Chrome may use Gmail/Gemini-only allowlist mode separately.
final class WindowsUrlBlocklistBatchService {
  WindowsUrlBlocklistBatchService._();
  static final WindowsUrlBlocklistBatchService instance =
      WindowsUrlBlocklistBatchService._();

  static const int _kMaxEntries = 1000;
  static bool _applyInFlight = false;

  /// Parsed from PS `${Name}_OK` lines — keep in sync with [_scriptBody].
  static const List<String> _kDerivativeBrowserNames = <String>[
    'Whale',
    'Brave',
    'Vivaldi',
    'Opera',
    'Opera_GX',
    'Edge_Beta',
    'Edge_Dev',
    'Chromium',
  ];

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

  String _workDir() {
    final String local = Platform.environment['LOCALAPPDATA'] ?? '';
    return p.join(local, 'SixVPNBlocker', 'policy_batch');
  }

  static const Map<String, String> _kBrowserIdToPsFlag = <String, String>{
    'chrome': 'ChromeExtReady',
    'edge': 'EdgeExtReady',
    'whale': 'WhaleExtReady',
    'brave': 'BraveExtReady',
    'vivaldi': 'VivaldiExtReady',
    'opera': 'OperaExtReady',
    'opera_gx': 'OperaGxExtReady',
  };

  /// Apply split patterns: per-browser YouTube apex vs list-only + Firefox.
  Future<List<String>> applyActivePatterns() async {
    if (!Platform.isWindows) return <String>[];
    final List<String> base =
        await ChromiumPolicyService.activeBlocklistPatterns();
    final List<String> chromiumFull =
        await ChromiumPolicyService.activeBlocklistPatternsForChromiumBrowser(
          'chrome',
          extensionHandlesYoutube: false,
        );
    final List<String> chromiumListOnly =
        await ChromiumPolicyService.activeBlocklistPatternsForChromiumBrowser(
          'chrome',
          extensionHandlesYoutube: true,
        );
    final List<String> firefox =
        await ChromiumPolicyService.activeBlocklistPatternsForFirefox();
    if (base.isEmpty && firefox.isEmpty) return <String>[];
    final Map<String, BrowserEnforcementReadiness> readiness =
        await BrowserEnforcementReadinessService.instance.snapshot(force: true);
    final Map<String, bool> extFlags = <String, bool>{
      for (final MapEntry<String, String> e in _kBrowserIdToPsFlag.entries)
        e.value: readiness[e.key]?.youtubeListOnlyMode ?? false,
    };
    return applySplitPatterns(
      chromiumFullPatterns: chromiumFull,
      chromiumListOnlyPatterns: chromiumListOnly,
      firefoxPatterns: firefox,
      browserExtensionReadyFlags: extFlags,
    );
  }

  /// Legacy single-list apply (all browsers same patterns).
  Future<List<String>> applyPatterns(List<String> patterns) async {
    if (!Platform.isWindows || patterns.isEmpty) return <String>[];
    return applySplitPatterns(
      chromiumFullPatterns: patterns,
      chromiumListOnlyPatterns: patterns,
      firefoxPatterns: patterns,
    );
  }

  Future<List<String>> applySplitPatterns({
    List<String>? chromiumPatterns,
    List<String>? chromiumFullPatterns,
    List<String>? chromiumListOnlyPatterns,
    required List<String> firefoxPatterns,
    Map<String, bool> browserExtensionReadyFlags = const <String, bool>{},
  }) async {
    if (!Platform.isWindows) return <String>[];
    if (_applyInFlight) {
      AppLogger.instance.info('url_blocklist_batch: skip duplicate in-flight');
      return <String>[];
    }
    _applyInFlight = true;
    final Stopwatch sw = Stopwatch()..start();
    final List<String> chromiumFull =
        chromiumFullPatterns ?? chromiumPatterns ?? const <String>[];
    try {
      final List<String> chromiumListOnly =
          chromiumListOnlyPatterns ?? chromiumFull;
      if (chromiumFull.isEmpty &&
          chromiumListOnly.isEmpty &&
          firefoxPatterns.isEmpty) {
        return <String>[];
      }

      final bool chromeGmailAllowlist = await ChromeGmailGeminiAllowlistService
          .instance
          .enabled();

      List<String> slice(List<String> src) =>
          src.length > _kMaxEntries ? src.sublist(0, _kMaxEntries) : src;
      final List<String> chromiumFullSlice = slice(chromiumFull);
      final List<String> chromiumListSlice = slice(chromiumListOnly);
      final List<String> firefoxSlice = slice(firefoxPatterns);

      final Directory dir = Directory(_workDir());
      await dir.create(recursive: true);
      final String chromiumFullPath = p.join(
        dir.path,
        'url_blocklist_chromium_full.txt',
      );
      final String chromiumListPath = p.join(
        dir.path,
        'url_blocklist_chromium_list.txt',
      );
      final String firefoxList = p.join(dir.path, 'url_blocklist_firefox.txt');
      final String psPath = p.join(dir.path, 'apply_url_blocklist.ps1');

      await File(
        chromiumFullPath,
      ).writeAsString('${chromiumFullSlice.join('\n')}\n', flush: true);
      await File(
        chromiumListPath,
      ).writeAsString('${chromiumListSlice.join('\n')}\n', flush: true);
      await File(
        firefoxList,
      ).writeAsString('${firefoxSlice.join('\n')}\n', flush: true);
      await File(psPath).writeAsString(_scriptBody(), flush: true);

      final List<String> psArgs = <String>[
        '-NoProfile',
        '-NonInteractive',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        psPath,
        '-ChromiumFullList',
        chromiumFullPath,
        '-ChromiumListOnlyList',
        chromiumListPath,
        '-FirefoxList',
        firefoxList,
        '-SkipChromeBlocklist',
        '0',
        '-ChromeGmailOnly',
        chromeGmailAllowlist ? '1' : '0',
      ];
      for (final MapEntry<String, bool> e
          in browserExtensionReadyFlags.entries) {
        psArgs.add('-${e.key}');
        psArgs.add(e.value ? '1' : '0');
      }

      final ProcessResult pr = await windowsRunHidden(_powershellExe(), psArgs);
      final String out = '${pr.stdout}'.trim();
      if (pr.exitCode != 0) {
        AppLogger.instance.warn(
          'url_blocklist_batch: exit=${pr.exitCode} ms=${sw.elapsedMilliseconds} err=${pr.stderr}',
        );
      } else {
        AppLogger.instance.info(
          'url_blocklist_batch: ok chromium_full=${chromiumFullSlice.length} '
          'chromium_list=${chromiumListSlice.length} '
          'firefox=${firefoxSlice.length} chrome_gmail_allowlist=$chromeGmailAllowlist '
          'ext_flags=$browserExtensionReadyFlags '
          'ms=${sw.elapsedMilliseconds}\n$out',
        );
      }

      final List<String> targets = <String>[];
      if (out.contains('Chrome_OK') || out.contains('Chrome_SKIP')) {
        targets.add('Chrome');
      }
      if (out.contains('Edge_OK')) targets.add('Edge');
      if (out.contains('Firefox_OK')) targets.add('Firefox');
      for (final String name in _kDerivativeBrowserNames) {
        if (out.contains('${name}_OK')) targets.add(name);
      }
      final List<String> operaPatterns =
          browserExtensionReadyFlags['OperaExtReady'] == true ||
              browserExtensionReadyFlags['OperaGxExtReady'] == true
          ? chromiumListSlice
          : chromiumFullSlice;
      final List<String> operaFile = await OperaChromiumPolicyFileService
          .instance
          .applyPatterns(operaPatterns);
      for (final String id in operaFile) {
        final String label = id == 'opera_gx' ? 'Opera_GX_file' : 'Opera_file';
        if (!targets.contains(label)) targets.add(label);
      }
      return targets;
    } catch (e) {
      AppLogger.instance.warn(
        'url_blocklist_batch failed after ${sw.elapsedMilliseconds}ms: $e',
      );
      return <String>[];
    } finally {
      _applyInFlight = false;
    }
  }

  static String _scriptBody() =>
      r'''
param(
  [Parameter(Mandatory=$true)][string]$ChromiumFullList,
  [Parameter(Mandatory=$true)][string]$ChromiumListOnlyList,
  [Parameter(Mandatory=$true)][string]$FirefoxList,
  [string]$SkipChromeBlocklist = '0',
  [string]$ChromeGmailOnly = '0',
  [string]$ChromeExtReady = '0',
  [string]$EdgeExtReady = '0',
  [string]$WhaleExtReady = '0',
  [string]$BraveExtReady = '0',
  [string]$VivaldiExtReady = '0',
  [string]$OperaExtReady = '0',
  [string]$OperaGxExtReady = '0'
)
$ErrorActionPreference = 'Stop'
__OWNERSHIP__
function Read-PatternList([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { return @() }
  return @(Get-Content -LiteralPath $Path -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
}
$chromiumFull = Read-PatternList $ChromiumFullList
$chromiumListOnly = Read-PatternList $ChromiumListOnlyList
$firefox = Read-PatternList $FirefoxList
if ($chromiumFull.Count -eq 0 -and $chromiumListOnly.Count -eq 0 -and $firefox.Count -eq 0) { Write-Output 'FAIL no patterns'; exit 1 }

function Pick-ChromiumPatterns([string]$ExtReadyFlag) {
  if ($ExtReadyFlag -eq '1' -and $chromiumListOnly.Count -gt 0) { return $chromiumListOnly }
  return $chromiumFull
}

function Pick-ChromePatterns() {
  if ($ChromeGmailOnly -eq '1') { return @('<*>') }
  return Pick-ChromiumPatterns $ChromeExtReady
}

function Set-BrowserBlocklist {
  param([string]$BrowserName, [string]$Root, [string]$BlocklistRel, [object]$Patterns)
  try {
    $Patterns = @($Patterns)
    if (-not (Test-Path -LiteralPath $Root)) {
      New-Item -Path $Root -Force -ErrorAction Stop | Out-Null
    }
    $blocklist = Join-Path $Root $BlocklistRel
    Set-FFOwnedList -key $blocklist -patterns $Patterns
    Write-Output "${BrowserName}_OK entries=$($Patterns.Count)"
    return $true
  } catch {
    Write-Output "${BrowserName}_FAIL: $($_.Exception.Message)"
    return $false
  }
}

$installed = 0

$chrome = 'HKCU:\SOFTWARE\Policies\Google\Chrome'
try {
  if (-not (Test-Path -LiteralPath $chrome)) { New-Item -Path $chrome -Force -ErrorAction Stop | Out-Null }
  Set-ItemProperty -LiteralPath $chrome -Name 'BuiltInDnsClientEnabled' -Value 0 -Type DWord -Force -ErrorAction Stop
  Set-ItemProperty -LiteralPath $chrome -Name 'DnsOverHttpsMode' -Value 'off' -Type String -Force -ErrorAction Stop
} catch { Write-Output "Chrome_DNS_FAIL: $($_.Exception.Message)" }
if ($SkipChromeBlocklist -eq '1') {
  Write-Output 'Chrome_SKIP allowlist_mode'
} elseif (Set-BrowserBlocklist -BrowserName 'Chrome' -Root $chrome -BlocklistRel 'URLBlocklist' -Patterns (Pick-ChromePatterns)) {
  $installed++
}

$chromeMachine = 'HKLM:\SOFTWARE\Policies\Google\Chrome'
try {
  if (-not (Test-Path -LiteralPath $chromeMachine)) { New-Item -Path $chromeMachine -Force -ErrorAction Stop | Out-Null }
  Set-ItemProperty -LiteralPath $chromeMachine -Name 'BuiltInDnsClientEnabled' -Value 0 -Type DWord -Force -ErrorAction Stop
  Set-ItemProperty -LiteralPath $chromeMachine -Name 'DnsOverHttpsMode' -Value 'off' -Type String -Force -ErrorAction Stop
  if ($SkipChromeBlocklist -ne '1') {
    if (Set-BrowserBlocklist -BrowserName 'Chrome_HKLM' -Root $chromeMachine -BlocklistRel 'URLBlocklist' -Patterns (Pick-ChromePatterns)) {
      $installed++
    }
  }
} catch { Write-Output "Chrome_HKLM_FAIL: $($_.Exception.Message)" }

$edge = 'HKCU:\SOFTWARE\Policies\Microsoft\Edge'
try {
  if (-not (Test-Path -LiteralPath $edge)) { New-Item -Path $edge -Force -ErrorAction Stop | Out-Null }
  Set-ItemProperty -LiteralPath $edge -Name 'BuiltInDnsClientEnabled' -Value 0 -Type DWord -Force -ErrorAction Stop
  Set-ItemProperty -LiteralPath $edge -Name 'DnsOverHttpsMode' -Value 'off' -Type String -Force -ErrorAction Stop
} catch { Write-Output "Edge_DNS_FAIL: $($_.Exception.Message)" }
if (Set-BrowserBlocklist -BrowserName 'Edge' -Root $edge -BlocklistRel 'URLBlocklist' -Patterns (Pick-ChromiumPatterns $EdgeExtReady)) { $installed++ }

$derivativeRoots = @(
  @{ Name = 'Whale'; Root = 'HKCU:\SOFTWARE\Policies\NAVER\Whale'; ExtFlag = $WhaleExtReady },
  @{ Name = 'Brave'; Root = 'HKCU:\SOFTWARE\Policies\BraveSoftware\Brave-Browser'; ExtFlag = $BraveExtReady },
  @{ Name = 'Vivaldi'; Root = 'HKCU:\SOFTWARE\Policies\Vivaldi'; ExtFlag = $VivaldiExtReady },
  @{ Name = 'Opera'; Root = 'HKCU:\SOFTWARE\Policies\Opera Software\Opera Stable'; ExtFlag = $OperaExtReady },
  @{ Name = 'Opera_GX'; Root = 'HKCU:\SOFTWARE\Policies\Opera Software\Opera GX Stable'; ExtFlag = $OperaGxExtReady },
  @{ Name = 'Edge_Beta'; Root = 'HKCU:\SOFTWARE\Policies\Microsoft\EdgeBeta'; ExtFlag = $EdgeExtReady },
  @{ Name = 'Edge_Dev'; Root = 'HKCU:\SOFTWARE\Policies\Microsoft\EdgeDev'; ExtFlag = $EdgeExtReady },
  @{ Name = 'Chromium'; Root = 'HKCU:\SOFTWARE\Policies\Chromium'; ExtFlag = $ChromeExtReady }
)
foreach ($d in $derivativeRoots) {
  $root = $d.Root
  try {
    if (-not (Test-Path -LiteralPath $root)) { New-Item -Path $root -Force -ErrorAction Stop | Out-Null }
    Set-ItemProperty -LiteralPath $root -Name 'BuiltInDnsClientEnabled' -Value 0 -Type DWord -Force -ErrorAction Stop
    Set-ItemProperty -LiteralPath $root -Name 'DnsOverHttpsMode' -Value 'off' -Type String -Force -ErrorAction Stop
    Set-ItemProperty -LiteralPath $root -Name 'IncognitoModeAvailability' -Value 1 -Type DWord -Force -ErrorAction Stop
  } catch { Write-Output "$($d.Name)_DNS_FAIL: $($_.Exception.Message)" }
  if (Set-BrowserBlocklist -BrowserName $d.Name -Root $root -BlocklistRel 'URLBlocklist' -Patterns (Pick-ChromiumPatterns $d.ExtFlag)) {
    $installed++
  }
}

$firefoxRoot = 'HKCU:\SOFTWARE\Policies\Mozilla\Firefox'
$firefoxPatterns = $firefox
try {
  if (-not (Test-Path -LiteralPath $firefoxRoot)) { New-Item -Path $firefoxRoot -Force -ErrorAction Stop | Out-Null }
  $doh = Join-Path $firefoxRoot 'DNSOverHTTPS'
  if (-not (Test-Path -LiteralPath $doh)) { New-Item -Path $doh -Force -ErrorAction Stop | Out-Null }
  Set-ItemProperty -LiteralPath $doh -Name 'Enabled' -Value 0 -Type DWord -Force -ErrorAction Stop
  Set-ItemProperty -LiteralPath $doh -Name 'Locked' -Value 1 -Type DWord -Force -ErrorAction Stop
  $filter = Join-Path $firefoxRoot 'WebsiteFilter'
  if (-not (Test-Path -LiteralPath $filter)) { New-Item -Path $filter -Force -ErrorAction Stop | Out-Null }
  $block = Join-Path $filter 'Block'
  Set-FFOwnedList -key $block -patterns $firefoxPatterns
  Write-Output "Firefox_OK entries=$($firefoxPatterns.Count)"
  $installed++
} catch {
  Write-Output "Firefox_FAIL: $($_.Exception.Message)"
}

Write-Output "installed=$installed"
exit 0
'''
          .replaceAll(
            '__OWNERSHIP__',
            BrowserPolicyLayer.ownedListsPowerShell(),
          );
}
