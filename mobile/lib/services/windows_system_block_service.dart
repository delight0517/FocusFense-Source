import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'chromium_policy_service.dart';
import 'firefox_config_service.dart';
import 'mac_system_block_service.dart';
import 'windows_chrome_extension_install_service.dart';
import 'windows_dns_lock_service.dart';
import 'windows_emergency_block_service.dart';
import 'windows_firewall_block_service.dart';
import 'windows_hosts_lock_service.dart';
import 'windows_hidden_process.dart';
import 'windows_hkcu_policy_service.dart';
import 'windows_silent_elevated_maintain_service.dart';
import 'windows_background_components_service.dart';
import 'blocked_browser_launch_notice_service.dart';
import 'windows_uac_apply_session.dart';
import 'opera_chromium_policy_file_service.dart';

// Path of the elevated PowerShell transcript log (created by the inner script
// every run). Surface this to the user when "result.txt 없음" errors fire so
// the next failure leaves a trail.
String _elevateTranscriptPath() {
  final String pd = Platform.environment['ProgramData'] ?? r'C:\ProgramData';
  return '$pd\\SixVPNBlocker\\elevate_transcript.log';
}

/// Truncates [s] to [max] chars with an ellipsis suffix — keeps the dialog
/// readable when PS prints hundreds of lines of stderr.
/// Result of [WindowsSystemBlockService.prepareBrowserLayers] — browser
/// blocking without waiting for UAC.
final class WindowsBrowserLayersPrep {
  const WindowsBrowserLayersPrep({
    required this.managedPayload,
    required this.hkcu,
    required this.emergency,
    this.supported = true,
  });

  const WindowsBrowserLayersPrep.unsupported()
    : managedPayload = '',
      hkcu = null,
      emergency = null,
      supported = false;

  final String managedPayload;
  final HkcuPolicyResult? hkcu;
  final EmergencyBlockResult? emergency;
  final bool supported;
}

String _snip(String s, int max) {
  final String t = s.trim();
  if (t.length <= max) return t;
  return '${t.substring(0, max)}…(${t.length - max} chars truncated)';
}

/// Builds the final `MacBlockResult` after `_elevatedWrite`'s inner pipeline
/// finishes (or fails). Escalates to **success** when:
///   1. We were activating (non-empty payload), AND
///   2. HKCU policy installed for at least one browser.
///
/// In that case Chrome/Edge/Firefox ARE blocked — the elevated hosts write
/// is a secondary layer. We surface the elevated error as a warning suffix
/// instead of failing the whole apply.
///
/// Deactivate (empty payload) never escalates: the user needs to know if
/// hosts is still blocked.
MacBlockResult _resultWithHkcu({
  required bool elevatedOk,
  required String elevatedMessage,
  required String payload,
  required HkcuPolicyResult? hkcu,
  EmergencyBlockResult? emergency,
  String successStdout = '',
}) {
  final bool isActivate = payload.trim().isNotEmpty;
  final bool hkcuOk = hkcu != null && hkcu.success;
  final bool emergencyOk = emergency != null && emergency.anyLayerActive;
  final String hkcuTail = hkcu == null
      ? ''
      : '\n\n─ HKCU 정책 (관리자 없이) ─\n${hkcu.message}';
  final String emergencyTail = emergency == null
      ? ''
      : '\n\n─ 비상 차단 (UAC/정책 우회) ─\n${emergency.summary}';

  if (elevatedOk) {
    return MacBlockResult.success(
      stdout: successStdout.isEmpty
          ? (hkcu == null ? '' : hkcu.message) + emergencyTail
          : '$successStdout$hkcuTail$emergencyTail',
    );
  }

  // @incident: uac_edr_write_failure_fallback — report success if any
  // fallback layer (HKCU policy / emergency block) is active; elevated
  // hosts write can fail under UAC/EDR interference, don't regress the
  // whole apply to "failed" when a fallback layer is still enforcing.
  // Elevated failed — HKCU policy and/or PAC/extension/BAT may still block.
  if (isActivate && (hkcuOk || emergencyOk)) {
    final String primary = hkcuOk
        ? '✅ Chrome / Edge / Firefox (HKCU 정책)\n${hkcu.message}'
        : '✅ 비상 차단 경로 (관리자 권한 없이)\n${emergency!.summary}';
    return MacBlockResult.success(
      stdout:
          '$primary$emergencyTail\n\n'
          '⚠ 시스템 hosts·NRPT는 적용되지 않았습니다 (UAC/EDR).\n'
          'Chrome/Edge: 확장 프로그램 켜짐 + chrome://policy → Reload policies.\n'
          '시스템 DNS까지 막으려면 바탕화면 「6 VPN Blocker - hosts 적용 (관리자).bat」을 '
          '관리자 권한으로 한 번 실행하세요.\n'
          '─ 관리자 측 오류 ─\n$elevatedMessage$hkcuTail',
    );
  }

  return MacBlockResult.failure('$elevatedMessage$hkcuTail$emergencyTail');
}

/// Windows **system** DNS block via `%WINDIR%\System32\drivers\etc\hosts`
/// using the same marker region as [MacSystemBlockService].
///
/// UAC elevation follows `docs/UAC_ELEVATED_WINDOWS_FILE_WRITE_BLUEPRINT.md`:
/// UTF-8 **BOM** on the elevated `.ps1` (PS 5.1 + non-English locale),
/// sentinel `result.txt` as ground truth for child success, and
/// `Start-Process … -PassThru` assignment (no pipeline) for exit codes.
final class WindowsSystemBlockService {
  WindowsSystemBlockService._();
  static final WindowsSystemBlockService instance =
      WindowsSystemBlockService._();

  static const List<int> _utf8Bom = <int>[0xEF, 0xBB, 0xBF];

  bool get isSupported => Platform.isWindows;

  /// `%WINDIR%\\System32\\drivers\\etc\\hosts` (64-bit view).
  static String systemHostsPath() {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return p.join(windir, 'System32', 'drivers', 'etc', 'hosts');
  }

  String _hostsPath() => systemHostsPath();

  /// Same bytes→text rules as [isActive], for diagnostics UI.
  /// Same marker merge as the elevated PowerShell script (Dart-side for CMD BAT).
  static String mergeHostsWithManagedRegion(
    String original,
    String managedPayload,
  ) {
    const String markerStart = MacSystemBlockService.kMarkerStart;
    const String markerEnd = MacSystemBlockService.kMarkerEnd;
    final int i = original.indexOf(markerStart);
    final int j = original.indexOf(markerEnd);
    String merged;
    if (i >= 0 && j > i) {
      final String before = original.substring(0, i).trimRight();
      final String after = original.substring(j + markerEnd.length).trimLeft();
      merged = after.isEmpty ? before : '$before\n\n$after';
    } else {
      merged = original.trimRight();
    }
    if (managedPayload.trim().isEmpty) {
      return '$merged\n';
    }
    return '${merged.trimRight()}\n\n${managedPayload.trim()}\n';
  }

  static Future<String?> tryReadSystemHostsNormalized() async {
    if (!Platform.isWindows) return null;
    try {
      final File f = File(systemHostsPath());
      if (!await f.exists()) return null;
      return await _readHostsNormalized(f);
    } catch (_) {
      return null;
    }
  }

  /// Always the **64-bit** Windows PowerShell on x64 Windows (`…\System32\…`),
  /// so elevated hosts writes hit the real `drivers\etc\hosts`, not the WoW64
  /// copy under `SysWOW64` (32-bit `powershell.exe` redirects `System32`).
  String _nativeWindowsPowerShellExe() {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return p.join(
      windir,
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
  }

  Future<bool> isActive() async {
    if (!isSupported) return false;
    try {
      final File f = File(_hostsPath());
      if (!await f.exists()) return false;
      final String all = await _readHostsNormalized(f);
      return all.contains(MacSystemBlockService.kMarkerStart) &&
          all.contains(MacSystemBlockService.kMarkerEnd);
    } catch (_) {
      return false;
    }
  }

  /// Reads `hosts` the same way the elevated merge script does: UTF-8 (with or
  /// without BOM) or UTF-16 LE (common when edited with Windows Notepad as
  /// "Unicode"). Pure UTF-8 [readAsString] misses markers in UTF-16 files.
  static Future<String> _readHostsNormalized(File f) async {
    final List<int> b = await f.readAsBytes();
    if (b.length >= 2 && b[0] == 0xFF && b[1] == 0xFE) {
      return _decodeUtf16Le(b, 2);
    }
    if (b.length >= 2 && b[0] == 0xFE && b[1] == 0xFF) {
      return _decodeUtf16Be(b, 2);
    }
    int start = 0;
    if (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) {
      start = 3;
    }
    return utf8.decode(b.sublist(start), allowMalformed: true);
  }

  static String _decodeUtf16Le(List<int> b, int start) {
    final StringBuffer sb = StringBuffer();
    for (int i = start; i + 1 < b.length; i += 2) {
      final int unit = b[i] | (b[i + 1] << 8);
      if (unit == 0) {
        break;
      }
      if (unit >= 0xD800 && unit <= 0xDBFF && i + 3 < b.length) {
        final int hi = unit;
        final int lo = b[i + 2] | (b[i + 3] << 8);
        if (lo >= 0xDC00 && lo <= 0xDFFF) {
          final int cp = 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00);
          sb.writeCharCode(cp);
          i += 2;
          continue;
        }
      }
      sb.writeCharCode(unit);
    }
    return sb.toString();
  }

  static String _decodeUtf16Be(List<int> b, int start) {
    final StringBuffer sb = StringBuffer();
    for (int i = start; i + 1 < b.length; i += 2) {
      final int unit = (b[i] << 8) | b[i + 1];
      if (unit == 0) {
        break;
      }
      sb.writeCharCode(unit);
    }
    return sb.toString();
  }

  /// Fast path (no UAC): Firefox profiles, HKCU URLBlocklist, PAC, extension rules.
  Future<WindowsBrowserLayersPrep> prepareBrowserLayers({
    bool enableSafeSearch = true,
  }) async {
    if (!isSupported) {
      return const WindowsBrowserLayersPrep.unsupported();
    }
    try {
      final List<String> ff = await FirefoxConfigService.instance
          .disableDoHInAllProfiles();
      AppLogger.instance.info(
        'windows hosts: firefox user.js applied to ${ff.length} profile(s)',
      );
    } catch (e, st) {
      AppLogger.instance.warn('windows hosts: firefox step failed', error: e);
      AppLogger.instance.log('DEBUG', 'firefox stack', stack: st);
    }

    final HkcuPolicyResult hkcu = await WindowsHkcuPolicyService.instance
        .applyNow();
    AppLogger.instance.info(
      'windows hosts: HKCU policy success=${hkcu.success} '
      'targets=${hkcu.targets.join(",")}',
    );

    final List<String> dnsHosts = await MacSystemBlockService.instance
        .enabledHostsExpanded();
    await WindowsDnsLockService.instance.writeBlocklist(dnsHosts);
    final String block = await MacSystemBlockService.instance
        .buildManagedHostsRegion(enableSafeSearch: enableSafeSearch);
    final EmergencyBlockResult emergency = await WindowsEmergencyBlockService
        .instance
        .applyNow();
    return WindowsBrowserLayersPrep(
      managedPayload: block,
      hkcu: hkcu,
      emergency: emergency,
    );
  }

  /// Slow path: UAC hosts · DNS sinkhole · Program Files policies.
  Future<MacBlockResult> applyElevatedHosts(
    String managedPayload, {
    HkcuPolicyResult? hkcu,
    EmergencyBlockResult? emergency,
  }) {
    if (!isSupported) {
      return Future<MacBlockResult>.value(MacBlockResult.unsupported());
    }
    return _elevatedWrite(managedPayload, hkcu: hkcu, emergency: emergency);
  }

  Future<MacBlockResult> activate({bool enableSafeSearch = true}) async {
    if (!isSupported) {
      return MacBlockResult.unsupported();
    }
    final WindowsBrowserLayersPrep prep = await prepareBrowserLayers(
      enableSafeSearch: enableSafeSearch,
    );
    if (!prep.supported) {
      return MacBlockResult.unsupported();
    }
    return applyElevatedHosts(
      prep.managedPayload,
      hkcu: prep.hkcu,
      emergency: prep.emergency,
    );
  }

  /// Always attempt elevation even when a normal-user cleanup fails. Retry
  /// local phases afterward so an admin repair can resolve their earlier error.
  static Future<MacBlockResult> runDeactivationPhases({
    required List<Future<void> Function()> local,
    required Future<MacBlockResult> Function() elevated,
  }) async {
    Future<int> cleanup() async {
      var failures = 0;
      for (final phase in local) {
        try {
          await phase();
        } catch (_) {
          failures++;
        }
      }
      return failures;
    }

    final failed = await cleanup();
    final result = await elevated();
    if (!result.ok) return result;
    if (failed > 0 && await cleanup() > 0) {
      return MacBlockResult.failure(
        '관리자 정책 정리는 수행했지만 일부 사용자 설정 해제가 남았습니다. 다시 시도해 주세요.',
      );
    }
    return result;
  }

  Future<MacBlockResult> deactivate() async {
    if (!isSupported) return MacBlockResult.unsupported();
    HkcuPolicyResult? hkcu;
    return runDeactivationPhases(
      local: [
        () async {
          hkcu = await WindowsHkcuPolicyService.instance.removeNow();
          if (!hkcu!.success) throw StateError(hkcu!.message);
        },
        () async {
          await OperaChromiumPolicyFileService.instance.restoreBackups();
        },
        () => WindowsEmergencyBlockService.instance.removePac(),
      ],
      elevated: () => _elevatedWrite('', hkcu: hkcu),
    );
  }

  /// When nested `Start-Process -Verb RunAs` from Flutter's PS fails (AV/EDR),
  /// try `Shell.Application.ShellExecute` via cscript — often still shows UAC.
  static Future<int?> _tryElevateScriptViaVbs({
    required String ps64Exe,
    required List<String> elevatedArgs,
    required File scriptFile,
    required File resultFile,
    required String tmpPath,
  }) async {
    final String argList = elevatedArgs
        .map((String a) => '"${a.replaceAll('"', '""')}"')
        .join(' ');
    final File vbs = File(p.join(tmpPath, 'sixvpn_launch_elev.vbs'));
    final String vbsBody =
        '''
Set sh = CreateObject("Shell.Application")
sh.ShellExecute "${ps64Exe.replaceAll('\\', '\\\\')}", ${argList.isEmpty ? '""' : '"$argList"'}, "", "runas", 0
''';
    await vbs.writeAsString(vbsBody, flush: true);
    try {
      await windowsStartDetachedHidden(
        p.join(
          Platform.environment['WINDIR'] ?? r'C:\Windows',
          'System32',
          'cscript.exe',
        ),
        <String>['//nologo', vbs.path],
      );
    } catch (_) {
      return null;
    }
    for (int i = 0; i < 90; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final int? code = await _readSentinelExitCode(resultFile);
      if (code != null) return code;
    }
    return null;
  }

  /// Interprets [resultFile] written by the elevated script. Last non-empty
  /// line must be `0` or `1`; preceding lines are optional error text.
  static Future<int?> _readSentinelExitCode(File resultFile) async {
    if (!await resultFile.exists()) return null;
    try {
      final String raw = await resultFile.readAsString();
      final List<String> lines = raw
          .split(RegExp(r'\r?\n'))
          .map((String l) => l.trim())
          .where((String l) => l.isNotEmpty)
          .toList();
      if (lines.isEmpty) return null;
      return int.tryParse(lines.last);
    } catch (_) {
      return null;
    }
  }

  static Future<String?> _readSentinelErrorBody(File resultFile) async {
    if (!await resultFile.exists()) return null;
    try {
      final String raw = await resultFile.readAsString();
      final List<String> lines = raw
          .split(RegExp(r'\r?\n'))
          .map((String l) => l.trim())
          .where((String l) => l.isNotEmpty)
          .toList();
      if (lines.length <= 1) return null;
      return lines.sublist(0, lines.length - 1).join('\n');
    } catch (_) {
      return null;
    }
  }

  Future<MacBlockResult> _elevatedWrite(
    String managedPayload, {
    HkcuPolicyResult? hkcu,
    EmergencyBlockResult? emergency,
  }) async {
    Directory? tmp;
    try {
      tmp = Directory.systemTemp.createTempSync('sixvpn_elevate_');
      final String tmpPath = tmp.path;
      final File payloadFile = File(p.join(tmpPath, 'payload.txt'));
      final File scriptFile = File(p.join(tmpPath, 'elevate.ps1'));
      final File resultFile = File(p.join(tmpPath, 'result.txt'));

      await payloadFile.writeAsString(managedPayload, flush: true);

      final bool installingBlock = managedPayload.trim().isNotEmpty;
      if (installingBlock) {
        await WindowsSilentElevatedMaintainService.instance
            .ensureScriptOnDisk();
      }
      File? policySourceFile;
      File? chromiumPolicyFile;
      File? firewallIpsFile;
      if (installingBlock) {
        policySourceFile = File(p.join(tmpPath, 'firefox_policy.json'));
        await policySourceFile.writeAsString(
          FirefoxConfigService.kDistributionPolicyJson,
          flush: true,
        );
        chromiumPolicyFile = File(p.join(tmpPath, 'chromium_policy.json'));
        await chromiumPolicyFile.writeAsString(
          await ChromiumPolicyService.buildPolicyJson(),
          flush: true,
        );
        try {
          final List<String> fwIps = await WindowsFirewallBlockService.instance
              .resolveBlockedIps();
          if (fwIps.isNotEmpty) {
            firewallIpsFile = File(p.join(tmpPath, 'firewall_ips.txt'));
            await firewallIpsFile.writeAsString(fwIps.join('\n'), flush: true);
            unawaited(WindowsFirewallBlockService.instance.prepareStateOnly());
          }
        } catch (_) {}
      }

      final String hostsPath = _hostsPath();
      final String markerStart = MacSystemBlockService.kMarkerStart;
      final String markerEnd = MacSystemBlockService.kMarkerEnd;
      final String extRegistryPs = installingBlock
          ? WindowsChromeExtensionInstallService.elevatedRegistryFragment(
              extensionFolderPath:
                  await WindowsChromeExtensionInstallService.defaultChromeExtensionPath(),
            )
          : '';

      // Inner script: markers are ASCII-only (see MacSystemBlockService).
      // UTF-8 for hosts read/write; sentinel last line is 0 or 1.
      final String chromiumRegistryActivatePs =
          await ChromiumPolicyService.elevatedRegistryPolicyFragment();
      final String chromiumRegistryRemovePs =
          ChromiumPolicyService.elevatedRegistryPolicyRemoveFragment();
      final String nrptActivatePs =
          WindowsDnsLockService.elevatedNrptActivateFragment();
      final String nrptDeactivatePs =
          WindowsDnsLockService.elevatedNrptDeactivateFragment();
      final String innerPs =
          '''
param(
  [Parameter(Mandatory = \$true)][string]\$PayloadPath,
  [Parameter(Mandatory = \$true)][string]\$HostsPath,
  [Parameter(Mandatory = \$true)][string]\$MarkerStart,
  [Parameter(Mandatory = \$true)][string]\$MarkerEnd,
  [Parameter(Mandatory = \$false)][string]\$PolicySource = '',
  [Parameter(Mandatory = \$false)][string]\$ChromiumPolicySource = '',
  [Parameter(Mandatory = \$false)][string]\$FirewallIpsPath = '',
  [Parameter(Mandatory = \$true)][string]\$ResultPath
)
\$ErrorActionPreference = 'Stop'
\$utf8 = New-Object System.Text.UTF8Encoding \$false
\$nl = [Environment]::NewLine
# Tombstone: write a default-failure sentinel before any risky work, so if
# the script is killed mid-flight (AV, crash) the parent still has a useful
# result.txt instead of "result.txt 없음".
try {
  [System.IO.File]::WriteAllText(\$ResultPath, 'elevated_script_started_but_not_finished' + \$nl + '1', \$utf8)
} catch {}
# Transcript log so the *next* failure leaves evidence under ProgramData.
\$sixTranscript = Join-Path \$env:ProgramData 'SixVPNBlocker\\elevate_transcript.log'
try {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent \$sixTranscript) -ErrorAction SilentlyContinue | Out-Null
  Start-Transcript -Path \$sixTranscript -Append -Force | Out-Null
} catch {}
function Read-HostsUnified {
  param([string]\$Path)
  \$bytes = [System.IO.File]::ReadAllBytes(\$Path)
  if (\$bytes.Length -ge 2 -and \$bytes[0] -eq 0xFF -and \$bytes[1] -eq 0xFE) {
    return [System.Text.Encoding]::Unicode.GetString(\$bytes, 2, \$bytes.Length - 2)
  }
  if (\$bytes.Length -ge 3 -and \$bytes[0] -eq 0xEF -and \$bytes[1] -eq 0xBB -and \$bytes[2] -eq 0xBF) {
    return [System.Text.Encoding]::UTF8.GetString(\$bytes, 3, \$bytes.Length - 3)
  }
  return [System.Text.Encoding]::UTF8.GetString(\$bytes)
}
function Write-HostsUnifiedWithRetry {
  param([string]\$Path, [string]\$Text)
  \$bytes = \$utf8.GetBytes(\$Text)
  \$lastError = ''
  for (\$attempt = 1; \$attempt -le 40; \$attempt++) {
    try {
      \$fs = [System.IO.File]::Open(
        \$Path,
        [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write,
        [System.IO.FileShare]::ReadWrite
      )
      try {
        \$fs.Write(\$bytes, 0, \$bytes.Length)
        \$fs.Flush()
      } finally {
        \$fs.Dispose()
      }
      Write-Host "[sixvpn] hosts written attempt \$attempt"
      return
    } catch {
      \$lastError = \$_.Exception.Message
      Write-Host "[sixvpn] hosts write retry \$attempt: \$lastError"
      Start-Sleep -Milliseconds 250
    }
  }
  throw "hosts write locked after retries: \$lastError"
}
try {
  # 32-bit PS on 64-bit OS: \\System32\\ redirects to SysWOW64 — use Sysnative
  # so we edit the same hosts file 64-bit apps (Flutter) read.
  if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    \$bs = [char]92
    \$needle = \$bs + 'System32' + \$bs
    \$idx = \$HostsPath.IndexOf(\$needle, [StringComparison]::OrdinalIgnoreCase)
    if (\$idx -ge 0) {
      \$sysnative = \$bs + 'Sysnative' + \$bs
      \$HostsPath = \$HostsPath.Substring(0, \$idx) + \$sysnative + \$HostsPath.Substring(\$idx + \$needle.Length)
    }
  }
  if (-not (Test-Path -LiteralPath \$HostsPath)) {
    throw "hosts file not found: \$HostsPath"
  }
  \$orig = Read-HostsUnified -Path \$HostsPath
  \$i = \$orig.IndexOf(\$MarkerStart)
  \$j = \$orig.IndexOf(\$MarkerEnd)
  if (\$i -ge 0 -and \$j -gt \$i) {
    \$before = \$orig.Substring(0, \$i).TrimEnd()
    \$after = \$orig.Substring(\$j + \$MarkerEnd.Length).TrimStart()
    \$merged = \$before + \$nl + \$nl + \$after
  } else {
    \$merged = \$orig.TrimEnd()
  }
  \$payload = [System.IO.File]::ReadAllText(\$PayloadPath, \$utf8)
  if (\$payload.Trim().Length -gt 0) {
    \$merged = \$merged.TrimEnd() + \$nl + \$nl + \$payload.Trim() + \$nl
  }
  Write-HostsUnifiedWithRetry -Path \$HostsPath -Text \$merged
  \$pDns = Start-Process -FilePath "\$env:SystemRoot\\System32\\ipconfig.exe" -ArgumentList '/flushdns' -Wait -PassThru -NoNewWindow
  if (\$pDns.ExitCode -ne 0) { Write-Host "[sixvpn] ipconfig exit \$(\$pDns.ExitCode)" }
  if (\$payload.Trim().Length -gt 0) {
${WindowsHostsLockService.elevatedLockFragment()}
  }
${WindowsFirewallBlockService.elevatedFirewallFragment()}
  if (\$PolicySource -ne '' -and (Test-Path -LiteralPath \$PolicySource)) {
    \$pf86 = \${env:ProgramFiles(x86)}
    \$distDirs = @(
      (Join-Path \$env:ProgramFiles 'Mozilla Firefox\\distribution'),
      (Join-Path \$pf86 'Mozilla Firefox\\distribution')
    )
    foreach (\$dist in \$distDirs) {
      try {
        \$mozRoot = Split-Path -Parent \$dist
        if (-not (Test-Path -LiteralPath \$mozRoot)) { continue }
        New-Item -ItemType Directory -Force -Path \$dist -ErrorAction Stop | Out-Null
        \$dest = Join-Path \$dist 'policies.json'
        \$backup = \$dest + '.focusfense-backup'
        \$created = \$dest + '.focusfense-created'
        if (-not (Test-Path -LiteralPath \$backup) -and -not (Test-Path -LiteralPath \$created)) {
          if (Test-Path -LiteralPath \$dest) {
            Copy-Item -LiteralPath \$dest -Destination \$backup -ErrorAction Stop
          } else {
            [System.IO.File]::WriteAllText(\$created, 'pending', \$utf8)
          }
        }
        Copy-Item -LiteralPath \$PolicySource -Destination \$dest -Force
        if (Test-Path -LiteralPath \$created) {
          \$hash = (Get-FileHash -LiteralPath \$dest -Algorithm SHA256).Hash
          [System.IO.File]::WriteAllText(\$created, \$hash, \$utf8)
        }
      } catch {
        Write-Host "[sixvpn] firefox policy skip (\$dist): \$(\$_.Exception.Message)"
      }
    }
  }
  if (\$ChromiumPolicySource -ne '' -and (Test-Path -LiteralPath \$ChromiumPolicySource)) {
    \$pf86 = \${env:ProgramFiles(x86)}
    \$chromiumDirs = @(
      (Join-Path \$env:ProgramFiles 'Google\\Chrome\\Application\\policies\\managed'),
      (Join-Path \$pf86 'Google\\Chrome\\Application\\policies\\managed'),
      (Join-Path \$env:ProgramFiles 'Microsoft\\Edge\\Application\\policies\\managed'),
      (Join-Path \$pf86 'Microsoft\\Edge\\Application\\policies\\managed')
    )
    foreach (\$dir in \$chromiumDirs) {
      try {
        \$root = Split-Path -Parent (Split-Path -Parent \$dir)
        if (-not (Test-Path -LiteralPath \$root)) { continue }
        New-Item -ItemType Directory -Force -Path \$dir -ErrorAction Stop | Out-Null
        \$dest = Join-Path \$dir 'policies.json'
        Copy-Item -LiteralPath \$ChromiumPolicySource -Destination \$dest -Force
        Write-Host "[sixvpn] chromium policy installed at \$dest"
      } catch {
        Write-Host "[sixvpn] chromium policy skip (\$dir): \$(\$_.Exception.Message)"
      }
    }
      }
$extRegistryPs
  if (\$payload.Trim().Length -gt 0) {
$chromiumRegistryActivatePs
${WindowsDnsLockService.elevatedDnsActivateFragment()}
$nrptActivatePs
${WindowsDnsLockService.elevatedDnsFinalizeFragment()}
${WindowsSilentElevatedMaintainService.elevatedRegisterTaskFragment()}
${WindowsBackgroundComponentsService.elevatedOrphanCleanupFragment()}
${BlockedBrowserLaunchNoticeService.elevatedDeployFragment()}
  } else {
${WindowsHostsLockService.elevatedUnlockFragment()}
${WindowsFirewallBlockService.elevatedFirewallRemoveFragment()}
$chromiumRegistryRemovePs
${WindowsDnsLockService.elevatedDnsDeactivateFragment()}
$nrptDeactivatePs
    \$pf86 = \${env:ProgramFiles(x86)}
    \$distDirs = @(
      (Join-Path \$env:ProgramFiles 'Mozilla Firefox\\distribution'),
      (Join-Path \$pf86 'Mozilla Firefox\\distribution')
    )
    foreach (\$dist in \$distDirs) {
      \$mozRoot = Split-Path -Parent \$dist
      if (-not (Test-Path -LiteralPath \$mozRoot)) { continue }
      \$dest = Join-Path \$dist 'policies.json'
      \$backup = \$dest + '.focusfense-backup'
      \$created = \$dest + '.focusfense-created'
      try {
        if (Test-Path -LiteralPath \$backup) {
          Copy-Item -LiteralPath \$backup -Destination \$dest -Force -ErrorAction Stop
          Remove-Item -LiteralPath \$backup -Force -ErrorAction Stop
          Remove-Item -LiteralPath \$created -Force -ErrorAction SilentlyContinue
          Write-Host "[sixvpn] firefox policy backup restored: \$dest"
        } elseif (Test-Path -LiteralPath \$created) {
          \$expectedHash = [System.IO.File]::ReadAllText(\$created).Trim()
          \$currentHash = if (Test-Path -LiteralPath \$dest) { (Get-FileHash -LiteralPath \$dest -Algorithm SHA256).Hash } else { '' }
          if (\$expectedHash -and \$expectedHash -ne 'pending' -and \$currentHash -eq \$expectedHash) {
            Remove-Item -LiteralPath \$dest -Force -ErrorAction Stop
            Remove-Item -LiteralPath \$created -Force -ErrorAction Stop
            Write-Host "[sixvpn] FocusFence-created Firefox policy removed: \$dest"
          } elseif (-not (Test-Path -LiteralPath \$dest)) {
            Remove-Item -LiteralPath \$created -Force -ErrorAction Stop
          } else {
            throw "Firefox policies.json changed after FocusFence wrote it; preserving it: \$dest"
          }
        } else {
          # A one-time elevated setup may have installed the current file
          # before this version had a protected sidecar. Require the recorded
          # target, original-absence marker, and exact content hash.
          \$manualManifest = Join-Path \$env:LOCALAPPDATA 'SixVPNBlocker\\manual_activation_backups\\firefox-policy-apply-last.json'
          if (Test-Path -LiteralPath \$manualManifest) {
            \$manual = Get-Content -LiteralPath \$manualManifest -Raw | ConvertFrom-Json
            \$currentHash = if (Test-Path -LiteralPath \$dest) { (Get-FileHash -LiteralPath \$dest -Algorithm SHA256).Hash } else { '' }
            if (\$manual.result -eq 'ok' -and \$manual.backup -like '*.json.absent' -and \$manual.target -eq \$dest -and \$manual.sha256 -match '^[A-Fa-f0-9]{64}\$' -and \$currentHash -eq \$manual.sha256) {
              Remove-Item -LiteralPath \$dest -Force -ErrorAction Stop
              Write-Host "[sixvpn] verified FocusFence test policy removed: \$dest"
            }
          }
        }
      } catch {
        Write-Host "[sixvpn] firefox policy cleanup failed (\$dist): \$(\$_.Exception.Message)"
        throw
      }
    }
  }
  [System.IO.File]::WriteAllText(\$ResultPath, '0', \$utf8)
} catch {
  try {
    \$msg = \$_.Exception.Message
    [System.IO.File]::WriteAllText(\$ResultPath, \$msg + \$nl + '1', \$utf8)
  } catch {
    try { [System.IO.File]::WriteAllText(\$ResultPath, '1', \$utf8) } catch {}
  }
} finally {
  try { Stop-Transcript | Out-Null } catch {}
}
''';

      await scriptFile.writeAsBytes(<int>[
        ..._utf8Bom,
        ...utf8.encode(innerPs),
      ], flush: true);

      String psSingleQuoted(String s) => "'${s.replaceAll("'", "''")}'";

      final String ps64Exe = _nativeWindowsPowerShellExe();

      final List<String> elevatedArgs = <String>[
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        scriptFile.path,
        '-PayloadPath',
        payloadFile.path,
        '-HostsPath',
        hostsPath,
        '-MarkerStart',
        markerStart,
        '-MarkerEnd',
        markerEnd,
        '-PolicySource',
        policySourceFile?.path ?? '',
        '-ChromiumPolicySource',
        chromiumPolicyFile?.path ?? '',
        '-FirewallIpsPath',
        firewallIpsFile?.path ?? '',
        '-ResultPath',
        resultFile.path,
      ];
      final String argListPs = elevatedArgs.map(psSingleQuoted).join(',');
      // Start-Process -Verb RunAs from 64-bit PS (see tools/test_hosts_launcher.ps1).
      // Nested ProcessStartInfo+runas from a child PS often fails with Access denied
      // before UAC appears when launched from Flutter.
      final String cmd =
          '\$ErrorActionPreference = \'Stop\'; '
          '\$p = Start-Process -FilePath ${psSingleQuoted(ps64Exe)} '
          '-ArgumentList @($argListPs) '
          '-Verb RunAs -Wait -PassThru -WindowStyle Hidden; '
          'if (\$null -eq \$p) { exit 1 } '
          'elseif (\$null -ne \$p.ExitCode) { exit [int]\$p.ExitCode } '
          'else { exit 0 }';

      AppLogger.instance.info(
        'windows hosts: payloadChars=${managedPayload.length} script=${scriptFile.path}',
      );
      AppLogger.instance.info('windows hosts: requesting UAC elevation…');
      late final int launcherExit;
      String err = '';
      String out = '';
      try {
        final WindowsHiddenProcess proc =
            await windowsStartHidden(ps64Exe, <String>[
              '-NoProfile',
              '-ExecutionPolicy',
              'Bypass',
              '-WindowStyle',
              'Hidden',
              '-Command',
              cmd,
            ]);
        WindowsUacApplySession.instance.registerLauncher(
          pid: proc.pid,
          kill: proc.kill,
        );
        final StringBuffer errBuf = StringBuffer();
        final StringBuffer outBuf = StringBuffer();
        proc.stderr.transform(utf8.decoder).listen(errBuf.write);
        proc.stdout.transform(utf8.decoder).listen(outBuf.write);
        launcherExit = await WindowsUacApplySession.instance.waitForExit(
          waitExit: () => proc.exitCode,
        );
        err = errBuf.toString().trim();
        out = outBuf.toString().trim();
      } on ProcessException catch (e) {
        WindowsUacApplySession.instance.unregister();
        AppLogger.instance.error(
          'windows hosts: UAC launcher failed',
          error: e,
        );
        return _resultWithHkcu(
          elevatedOk: false,
          elevatedMessage:
              'UAC를 시작하지 못했습니다 (Access denied). '
              '진단 화면에서 「지금 적용」을 누르고 UAC에서 「예」를 선택하세요. '
              '회사 PC·보안 정책이면 관리자에게 문의하세요.',
          payload: managedPayload,
          hkcu: hkcu,
          emergency: emergency,
        );
      } finally {
        WindowsUacApplySession.instance.unregister();
      }
      if (WindowsUacApplySession.instance.cancelRequested) {
        return MacBlockResult.cancelled();
      }
      final int exitCode = WindowsUacApplySession.instance.interpretExitCode(
        launcherExit,
      );
      if (exitCode == -2) {
        return MacBlockResult.failure(
          'UAC 대기 시간 초과(4분). Windows UAC 창에서 「예」를 누르거나, '
          '「취소」 후 다시 시도하세요. DNS 싱크홀 단계가 오래 걸릴 수 있습니다.',
        );
      }
      if (exitCode == -3) {
        return MacBlockResult.cancelled();
      }
      if (out.isNotEmpty) {
        AppLogger.instance.info('windows hosts launcher stdout: $out');
      }
      if (err.isNotEmpty) {
        AppLogger.instance.info('windows hosts launcher stderr: $err');
      }

      final int? sentinel = await _readSentinelExitCode(resultFile);
      final String? errBody = await _readSentinelErrorBody(resultFile);

      if (sentinel == null) {
        AppLogger.instance.info(
          'windows hosts: sentinel missing — retry UAC via VBS ShellExecute',
        );
        final int? vbsSentinel = await _tryElevateScriptViaVbs(
          ps64Exe: ps64Exe,
          elevatedArgs: elevatedArgs,
          scriptFile: scriptFile,
          resultFile: resultFile,
          tmpPath: tmpPath,
        );
        if (vbsSentinel == 0) {
          final bool expectMarkers = managedPayload.trim().isNotEmpty;
          final bool markersOk = !expectMarkers || await isActive();
          if (markersOk) {
            return _resultWithHkcu(
              elevatedOk: true,
              elevatedMessage: '',
              payload: managedPayload,
              hkcu: hkcu,
              emergency: emergency,
              successStdout: 'UAC 적용 완료 (VBS ShellExecute 경로)',
            );
          }
        }
        if (exitCode != 0) {
          final String errLower = err.toLowerCase();
          if (errLower.contains('canceled') ||
              errLower.contains('cancelled') ||
              errLower.contains('operation was canceled')) {
            return MacBlockResult.cancelled();
          }
          final String outSnip = _snip(out, 600);
          final String errSnip = _snip(err, 600);
          return _resultWithHkcu(
            elevatedOk: false,
            elevatedMessage:
                'UAC 또는 PowerShell 실패\n'
                'exit code: $exitCode\n'
                'result.txt: 없음 (관리자 스크립트가 끝까지 실행되지 못함)\n'
                '가능 원인: AV/EDR이 PowerShell 차단, 그룹정책이 UAC 거부, '
                '또는 파워셸 런처 자체 실패\n'
                '대안: 바탕화면 「6 VPN Blocker - hosts 적용 (관리자).bat」 (CMD만 사용)\n'
                '─ stdout ─\n${outSnip.isEmpty ? "(비어 있음)" : outSnip}\n'
                '─ stderr ─\n${errSnip.isEmpty ? "(비어 있음)" : errSnip}\n'
                '관리자 transcript 경로 (다음 시도부터 기록): ${_elevateTranscriptPath()}',
            payload: managedPayload,
            hkcu: hkcu,
            emergency: emergency,
          );
        }
        final String outSnip = _snip(out, 600);
        final String errSnip = _snip(err, 600);
        return _resultWithHkcu(
          elevatedOk: false,
          elevatedMessage:
              'UAC가 거부되었거나 관리자 스크립트가 시작되지 않았습니다.\n'
              '(result.txt 없음, exit code: $exitCode)\n'
              '대처: 다시 「지금 적용」 또는 바탕화면 BAT (VBS→CMD, PowerShell 없음).\n'
              '─ stdout ─\n${outSnip.isEmpty ? "(비어 있음)" : outSnip}\n'
              '─ stderr ─\n${errSnip.isEmpty ? "(비어 있음)" : errSnip}\n'
              '관리자 transcript 경로 (다음 시도부터 기록): ${_elevateTranscriptPath()}',
          payload: managedPayload,
          hkcu: hkcu,
          emergency: emergency,
        );
      }

      if (sentinel != 0) {
        final String detail = errBody?.trim().isNotEmpty == true
            ? errBody!.trim()
            : '관리자 스크립트 실패 (sentinel=$sentinel)';
        return _resultWithHkcu(
          elevatedOk: false,
          elevatedMessage: detail,
          payload: managedPayload,
          hkcu: hkcu,
          emergency: emergency,
        );
      }

      if (exitCode != 0) {
        final String errLower = err.toLowerCase();
        if (errLower.contains('canceled') ||
            errLower.contains('cancelled') ||
            errLower.contains('operation was canceled')) {
          return MacBlockResult.cancelled();
        }
      }

      final bool expectMarkers = managedPayload.trim().isNotEmpty;
      bool nowOn = await isActive();
      if (expectMarkers && !nowOn) {
        for (int i = 0; i < 10; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          nowOn = await isActive();
          if (nowOn) {
            break;
          }
        }
      }
      if (expectMarkers != nowOn) {
        return _resultWithHkcu(
          elevatedOk: false,
          elevatedMessage: expectMarkers
              ? 'hosts에 managed 블록이 없습니다. UAC를 허용했는지 확인하세요. '
                    'Chrome 보안 DNS는 OS 기본값이어야 합니다.'
              : 'managed 블록을 지우지 못했습니다.',
          payload: managedPayload,
          hkcu: hkcu,
          emergency: emergency,
        );
      }

      unawaited(
        WindowsSilentElevatedMaintainService.instance.onElevatedApplySuccess(),
      );
      return _resultWithHkcu(
        elevatedOk: true,
        elevatedMessage: '',
        payload: managedPayload,
        hkcu: hkcu,
        emergency: emergency,
        successStdout: out,
      );
    } finally {
      if (tmp != null) {
        try {
          await tmp.delete(recursive: true);
        } catch (_) {
          /* temp cleanup best-effort */
        }
      }
    }
  }
}
