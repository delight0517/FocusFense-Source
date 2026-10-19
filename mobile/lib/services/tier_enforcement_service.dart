import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'chrome_browser_watchdog_service.dart';
import 'chrome_load_extension_launcher.dart';
import 'chrome_shortcut_hijack_service.dart';
import 'extension_rules_snapshot_service.dart';
import 'extension_guard_prefs.dart';
import 'windows_extension_guard_service.dart';
import 'windows_hidden_process.dart';
import 'windows_protection_mode_prefs.dart';

/// 3-Tier bypass when Chrome/Edge registry policies are blocked (corp PC).
///
/// 1) Shortcut hijack (all .lnk → VBS + optional --load-extension on chrome.exe)
/// 2) HKCU URL protocol `sixvpn-open:` → protected Chrome with URL
/// 3) Scheduled process watchdog — kill chrome/msedge without extension, relaunch protected
final class TierEnforcementService {
  TierEnforcementService._();
  static final TierEnforcementService instance = TierEnforcementService._();

  static const String kTier3TaskName = 'SixVPNTier3Watchdog';
  static const String kLinkProtocol = 'sixvpn-open';

  Timer? _foregroundTier3Timer;

  static String get _markerDir => ChromeLoadExtensionLauncher.sixVpnDir;

  static String get _tier3Script =>
      p.join(_markerDir, 'tier3_watchdog_once.ps1');

  static String get _tier3VbsLauncher =>
      p.join(_markerDir, 'tier3_watchdog_launch.vbs');

  static String get _linkHandlerVbs =>
      p.join(_markerDir, 'Launch-6VPN-Link.vbs');

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

  static String _schtasksExe() {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return p.join(windir, 'System32', 'schtasks.exe');
  }

  static String _wscriptExe() {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return p.join(windir, 'System32', 'wscript.exe');
  }

  /// Returns true when HKLM/HKCU ExtensionInstallForcelist is not usable.
  static Future<bool> isRegistryPolicyBlocked() async {
    if (!Platform.isWindows) return false;
    final ExtensionPolicyVerifyResult v =
        await WindowsExtensionGuardService.verifyAllPolicies();
    final bool registryChrome =
        v.chromeHklmOk || v.chromeHkcuOk || v.chromeForcelistOk;
    final bool registryEdge = v.edgeHklmOk || v.edgeHkcuOk || v.edgeForcelistOk;
    return !registryChrome && !registryEdge;
  }

  /// Install / refresh all tiers after extension payload is on disk.
  Future<TierEnforcementResult> installAllTiers({
    required String extensionFolder,
    bool force = false,
  }) async {
    if (!Platform.isWindows) {
      return const TierEnforcementResult(
        ok: false,
        message: 'Windows 전용',
        registryBlocked: false,
      );
    }
    if (WindowsProtectionModePrefs.isProtectionExplicitlyOff) {
      return const TierEnforcementResult(
        ok: false,
        message: '수동 보호 꺼짐 상태라 Tier 3 복구 작업을 등록하지 않았습니다.',
        registryBlocked: false,
      );
    }

    final bool registryBlocked = await isRegistryPolicyBlocked();
    final String ext = await ChromeLoadExtensionLauncher.mirrorExtensionFolder(
      extensionFolder,
    );

    if (!await File(p.join(ext, 'manifest.json')).exists()) {
      return TierEnforcementResult(
        ok: false,
        message: '확장 manifest 없음 — 먼저 자율 설치 실행',
        registryBlocked: registryBlocked,
      );
    }

    final List<String> steps = <String>[];

    // Tier 1 — shortcuts
    final ShortcutHijackResult hijack = await ChromeShortcutHijackService
        .instance
        .apply(extensionFolder: ext, force: force || registryBlocked);
    steps.add('tier1_hijack:${hijack.patchedCount}');

    await _writeTier1ArgumentInjectionScript(ext);
    await _runTier1ArgumentInjection();
    steps.add('tier1_args_inject');

    await ChromeLoadExtensionLauncher.install(extensionFolder: ext);
    final bool snap = await ExtensionRulesSnapshotService.instance
        .writeToChromePayload(sourceFolder: ext);
    steps.add(snap ? 'rules_snapshot_ok' : 'rules_snapshot_skip');

    // Tier 2 — link protocol (HKCU only — often allowed when HKLM Chrome policy is not)
    final bool linkOk = await _installLinkProtocolHandler(ext);
    steps.add(linkOk ? 'tier2_protocol_ok' : 'tier2_protocol_skip');

    // Tier 3 — process watchdog (aggressive when registry blocked)
    final bool tier3Ok = await _installTier3Watchdog(
      extensionFolder: ext,
      aggressive: registryBlocked,
    );
    steps.add(tier3Ok ? 'tier3_watchdog_ok' : 'tier3_watchdog_fail');

    // Existing 5-min shortcut refresh task
    if (await ExtensionGuardPrefs.instance.isWatchdogEnabled() ||
        registryBlocked) {
      await ChromeBrowserWatchdogService.instance.install();
      steps.add('browser_guard_task');
    }

    final ExtensionPolicyVerifyResult after =
        await WindowsExtensionGuardService.verifyAllPolicies(force: true);
    final bool ok = after.chromeOk && after.edgeOk;

    final String msg = registryBlocked
        ? (ok
              ? '3단계 우회 활성 — 레지스트리 없이 Chrome/Edge 보호'
              : '3단계 우회 설치됨 — 「6 VPN Blocker (Chrome)」·작업표시줄 바로가기 사용')
        : (ok ? '정책 + 3단계 보조 설치 완료' : '3단계 보조 설치 완료');

    await runTier3Once();
    await Future<void>.delayed(const Duration(milliseconds: 800));
    await runTier3Once();

    AppLogger.instance.info(
      'tier_enforcement: $steps registryBlocked=$registryBlocked',
    );
    return TierEnforcementResult(
      ok: ok || after.chromeLoadExtensionFallbackOk,
      message: msg,
      registryBlocked: registryBlocked,
      tier1Patched: hijack.patchedCount,
      tier2Protocol: linkOk,
      tier3Watchdog: tier3Ok,
      steps: steps,
      verify: after,
    );
  }

  /// One-shot tier3 run (app resume).
  Future<void> runTier3Once() async {
    if (!Platform.isWindows) return;
    if (WindowsProtectionModePrefs.isProtectionExplicitlyOff) return;
    if (!await File(_tier3Script).exists()) return;
    try {
      await windowsRunHidden(_psExe(), <String>[
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        _tier3Script,
      ]);
    } catch (_) {}
  }

  static Future<void> _writeTier1ArgumentInjectionScript(String ext) async {
    final String extEsc = ext.replaceAll("'", "''");
    final String script =
        r'''
$ErrorActionPreference = 'SilentlyContinue'
$ext = 'EXT_PATH'
$patched = 0
function Patch-LnkArgs([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return }
  try {
    $sh = New-Object -ComObject WScript.Shell
    $sc = $sh.CreateShortcut($path)
    $t = ($sc.TargetPath -replace '/','\').ToLowerInvariant()
    if ($t -notmatch '\\chrome\.exe$' -and $t -notmatch '\\msedge\.exe$') { return }
    if ($sc.Arguments -match 'load-extension|disable-extensions-except') { return }
    $arg = '--disable-extensions-except="' + $ext + '" --load-extension="' + $ext + '"'
    if ($sc.Arguments) { $sc.Arguments = "$arg $($sc.Arguments)" } else { $sc.Arguments = $arg }
    $sc.Save()
    $script:patched++
  } catch {}
}
$roots = @(
  (Join-Path $env:USERPROFILE 'Desktop'),
  (Join-Path $env:PUBLIC 'Desktop'),
  (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
  (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs'),
  (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar')
)
foreach ($root in $roots) {
  if (-not (Test-Path -LiteralPath $root)) { continue }
  Get-ChildItem -LiteralPath $root -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue |
    ForEach-Object { Patch-LnkArgs $_.FullName }
}
Write-Output "args_patched=$patched"
'''
            .replaceAll('EXT_PATH', extEsc);
    await File(
      p.join(_markerDir, 'tier1_lnk_args.ps1'),
    ).writeAsString(script, flush: true);
  }

  static Future<void> _runTier1ArgumentInjection() async {
    final String f = p.join(_markerDir, 'tier1_lnk_args.ps1');
    if (!await File(f).exists()) return;
    try {
      await windowsRunHidden(_psExe(), <String>[
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        f,
      ]);
    } catch (_) {}
  }

  static Future<bool> _installLinkProtocolHandler(String ext) async {
    try {
      final Directory dir = Directory(_markerDir);
      if (!await dir.exists()) await dir.create(recursive: true);

      final String vbs =
          '''
' Tier 2 — open URL in protected Chrome (HKCU protocol)
Option Explicit
Dim url, ext, chrome, sh, args, raw
raw = ""
If WScript.Arguments.Count > 0 Then raw = WScript.Arguments(0)
url = raw
If InStr(LCase(url), "sixvpn-open:") = 1 Then
  url = Mid(url, Len("sixvpn-open:") + 1)
  If Left(url, 2) = "//" Then url = Mid(url, 3)
End If
If Len(url) = 0 Then url = "about:blank"
ext = "${ext.replaceAll('"', '""')}"
chrome = "${_findChromeForVbs().replaceAll('"', '""')}"
If Len(chrome) = 0 Then WScript.Quit 1
Set sh = CreateObject("WScript.Shell")
args = "--load-extension=""" & ext & """ """ & url & """"
sh.Run """" & chrome & """ " & args, 1, False
''';
      await File(_linkHandlerVbs).writeAsString(vbs, flush: true);

      final String handler =
          '${_wscriptExe()} //B //Nologo "${_linkHandlerVbs.replaceAll("'", "''")}" "%1"';
      final String ps =
          r'''
$ErrorActionPreference = 'Stop'
$proto = 'PROTO_NAME'
$handler = 'HANDLER_CMD'
New-Item -Path "HKCU:\Software\Classes\$proto" -Force | Out-Null
Set-ItemProperty -LiteralPath "HKCU:\Software\Classes\$proto" -Name '(Default)' -Value '6 VPN Blocker URL'
New-ItemProperty -LiteralPath "HKCU:\Software\Classes\$proto" -Name 'URL Protocol' -Value '' -PropertyType String -Force | Out-Null
New-Item -Path "HKCU:\Software\Classes\$proto\shell\open\command" -Force | Out-Null
Set-ItemProperty -LiteralPath "HKCU:\Software\Classes\$proto\shell\open\command" -Name '(Default)' -Value $handler
Write-Output 'protocol_ok'
'''
              .replaceAll('PROTO_NAME', kLinkProtocol)
              .replaceAll('HANDLER_CMD', handler.replaceAll("'", "''"));
      final ProcessResult r = await windowsRunHidden(_psExe(), <String>[
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-Command',
        ps,
      ]);
      return r.exitCode == 0 && '${r.stdout}'.contains('protocol_ok');
    } catch (e) {
      AppLogger.instance.warn('tier2 protocol install failed', error: e);
      return false;
    }
  }

  static String _findChromeForVbs() {
    final List<String> paths = <String>[
      p.join(
        Platform.environment['ProgramFiles'] ?? r'C:\Program Files',
        'Google',
        'Chrome',
        'Application',
        'chrome.exe',
      ),
      p.join(
        Platform.environment['LOCALAPPDATA'] ?? '',
        'Google',
        'Chrome',
        'Application',
        'chrome.exe',
      ),
    ];
    for (final String path in paths) {
      if (path.isNotEmpty && File(path).existsSync()) return path;
    }
    return r'C:\Program Files\Google\Chrome\Application\chrome.exe';
  }

  static Future<bool> _installTier3Watchdog({
    required String extensionFolder,
    required bool aggressive,
  }) async {
    final Directory dir = Directory(_markerDir);
    if (!await dir.exists()) await dir.create(recursive: true);

    final String extEsc = extensionFolder.replaceAll("'", "''");
    final String chromeVbs = ChromeLoadExtensionLauncher.chromeVbsPath
        .replaceAll("'", "''");
    final String edgeVbs = ChromeLoadExtensionLauncher.edgeVbsPath.replaceAll(
      "'",
      "''",
    );

    final String enforceFlag = p
        .join(
          ChromeLoadExtensionLauncher.sixVpnDir,
          'youtube_enforce_active.flag',
        )
        .replaceAll("'", "''");
    // NON-DESTRUCTIVE watchdog. The old version force-killed any Chrome/Edge
    // window that wasn't launched with `--load-extension` every few minutes —
    // even when the app was closed — which is exactly the "브라우저가 시도때도
    // 없이 꺼진다" complaint. We NO LONGER kill running browsers. Blocking now
    // relies on non-destructive layers: shortcut hijack (new launches get the
    // extension), HKCU URLBlocklist policy (blocks the URL in every instance),
    // and the content script. This script only re-patches shortcuts so the
    // NEXT launch is protected; it never touches a running process.
    //
    // Killing is gated behind an explicit opt-in flag file
    // (`tier3_allow_kill.flag`) that the app never writes by default.
    final String allowKillFlag = p
        .join(ChromeLoadExtensionLauncher.sixVpnDir, 'tier3_allow_kill.flag')
        .replaceAll("'", "''");
    final String hijackScript = p
        .join(ChromeLoadExtensionLauncher.sixVpnDir, 'shortcut_hijack.ps1')
        .replaceAll("'", "''");
    final String ps =
        r'''
$ErrorActionPreference = 'SilentlyContinue'
$ext = 'EXT_PATH'
$chromeVbs = 'CHROME_VBS'
$edgeVbs = 'EDGE_VBS'
$enforceFlag = 'ENFORCE_FLAG'
$allowKill = (Test-Path -LiteralPath 'ALLOW_KILL_FLAG')
$hijack = 'HIJACK_PS1'
$killed = 0
function Show-6VpnCloseNotice([string]$name) {
  try {
    $dir = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker'
    $script = Join-Path $dir 'ShowSixVpnToast.ps1'
    if (-not (Test-Path -LiteralPath $script)) { return }
    $payload = Join-Path $dir ('toast_tier3_' + [guid]::NewGuid().ToString('N') + '.json')
    @{
      title = "$name 종료됨"
      body = '6 VPN Blocker가 보호 브라우저로 전환하기 위해 이 창을 닫았습니다.'
    } | ConvertTo-Json -Compress | Set-Content -LiteralPath $payload -Encoding UTF8
    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
      '-NoProfile',
      '-STA',
      '-ExecutionPolicy',
      'Bypass',
      '-WindowStyle',
      'Hidden',
      '-File',
      $script,
      '-Payload',
      $payload
    ) -WindowStyle Hidden
  } catch {}
}

# Always safe: re-patch shortcuts so the NEXT browser launch loads the
# extension. This does not touch any running window.
if (Test-Path -LiteralPath $hijack) {
  powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $hijack | Out-Null
}

# Killing is OFF unless the user explicitly drops the opt-in flag. By default
# this whole block is skipped, so browsers are never closed by the watchdog.
if ($allowKill) {
  $graceSeconds = 120
  function Test-Protected([string]$cmd) {
    if ([string]::IsNullOrWhiteSpace($cmd)) { return $false }
    if ($cmd -match 'load-extension|disable-extensions-except|sixvpnblocker|chrome_blocker') { return $true }
    return $false
  }
  function Get-ProcAgeSeconds($proc) {
    try {
      $start = [Management.ManagementDateTimeConverter]::ToDateTime($proc.CreationDate)
      return ([DateTime]::Now - $start).TotalSeconds
    } catch { return [double]::MaxValue }
  }
  $procs = Get-CimInstance Win32_Process -Filter "Name='chrome.exe' OR Name='msedge.exe'" -ErrorAction SilentlyContinue
  foreach ($p in $procs) {
    $cmd = $p.CommandLine
    if ($cmd -match '--type=') { continue }
    if (Test-Protected $cmd) { continue }
    if ((Get-ProcAgeSeconds $p) -le $graceSeconds) { continue }
    $vbs = if ($p.Name -eq 'msedge.exe') { $edgeVbs } else { $chromeVbs }
    if (-not (Test-Path -LiteralPath $vbs)) { continue }
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
    $killed++
    Show-6VpnCloseNotice $p.Name
    Start-Process -FilePath 'wscript.exe' -ArgumentList @('//B','//Nologo',$vbs) -WindowStyle Hidden
  }
}
Write-Output "killed=$killed allowKill=$allowKill"
'''
            .replaceAll('EXT_PATH', extEsc)
            .replaceAll('CHROME_VBS', chromeVbs)
            .replaceAll('EDGE_VBS', edgeVbs)
            .replaceAll('ENFORCE_FLAG', enforceFlag)
            .replaceAll('ALLOW_KILL_FLAG', allowKillFlag)
            .replaceAll('HIJACK_PS1', hijackScript);

    await File(_tier3Script).writeAsString(ps, flush: true);

    final String psEsc = _tier3Script.replaceAll('"', '""');
    await File(_tier3VbsLauncher).writeAsString(
      'CreateObject("Wscript.Shell").Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$psEsc""", 0, False',
      flush: true,
    );

    // 3 min when registry is locked (corp PC — extension is our only path);
    // 5 min otherwise. The previous `1 : 1` killed user browsers every minute.
    final int intervalMin = aggressive ? 3 : 5;
    try {
      await windowsRunHidden(_schtasksExe(), <String>[
        '/Delete',
        '/F',
        '/TN',
        kTier3TaskName,
      ]);
    } catch (_) {}

    final ProcessResult create =
        await windowsRunHidden(_schtasksExe(), <String>[
          '/Create',
          '/F',
          '/TN',
          kTier3TaskName,
          '/SC',
          'MINUTE',
          '/MO',
          '$intervalMin',
          '/RL',
          'LIMITED',
          '/TR',
          '${_wscriptExe()} //B //Nologo "$_tier3VbsLauncher"',
        ]);
    return create.exitCode == 0;
  }

  /// Deprecated — scheduled task only (avoids 20s PowerShell loop lag).
  void startForegroundTier3Guard() {}

  void stopForegroundTier3Guard() {
    _foregroundTier3Timer?.cancel();
    _foregroundTier3Timer = null;
  }
}

final class TierEnforcementResult {
  const TierEnforcementResult({
    required this.ok,
    required this.message,
    required this.registryBlocked,
    this.tier1Patched = 0,
    this.tier2Protocol = false,
    this.tier3Watchdog = false,
    this.steps = const <String>[],
    this.verify,
  });

  final bool ok;
  final String message;
  final bool registryBlocked;
  final int tier1Patched;
  final bool tier2Protocol;
  final bool tier3Watchdog;
  final List<String> steps;
  final ExtensionPolicyVerifyResult? verify;
}
