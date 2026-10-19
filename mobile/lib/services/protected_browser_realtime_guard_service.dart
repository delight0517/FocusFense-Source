import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/allowed_browser_app_catalog.dart';
import 'app_block_user_notice_service.dart';
import 'app_logger.dart';
import 'block_activity_log_service.dart';
import 'browser_app_allowlist_service.dart';
import 'chrome_load_extension_launcher.dart';
import 'easy_setup_bulletproof_prefs.dart';
import 'own_kill_ledger.dart';
import 'windows_browser_proxy_policy_service.dart';
import 'windows_extension_guard_service.dart';
import 'windows_hidden_process.dart';

/// In-app realtime guard: repatch shortcuts + soft-handoff unprotected Chrome/Edge/Firefox.
///
/// Covers Win+Search direct exe, stale taskbar pins, and missed hijacks — without
/// the old 1-minute kill-everything flash loop.
final class ProtectedBrowserRealtimeGuardService {
  ProtectedBrowserRealtimeGuardService._();
  static final ProtectedBrowserRealtimeGuardService instance =
      ProtectedBrowserRealtimeGuardService._();

  // ignore: unused_field
  static const Duration _tickInterval = Duration(seconds: 180);
  // ignore: unused_field
  static const Duration _tickIntervalYoutube = Duration(seconds: 120);
  static const Duration _policyCacheTtl = Duration(minutes: 5);

  /// Shortcuts are pre-hijacked so normal Chrome opens protected from the start.
  /// If a raw exe bypass still appears, migrate it immediately and explain it.
  static const int _killGraceSeconds = 0;
  static String get _scriptFile => p.join(
    ChromeLoadExtensionLauncher.sixVpnDir,
    'browser_realtime_guard.ps1',
  );

  static String get _policyFlagFile => p.join(
    ChromeLoadExtensionLauncher.sixVpnDir,
    'chrome_policy_active.flag',
  );

  Timer? _timer;
  bool _tickRunning = false;
  bool _scriptWritten = false;
  DateTime? _policyCacheAt;
  bool? _policyCacheValue;

  /// Soft periodic guard: repatch shortcuts + migrate unprotected browsers.
  /// Does NOT run the old 180s kill-everything loop (that caused random closes).
  void start() {
    if (!Platform.isWindows) return;
    _timer?.cancel();
    _timer = Timer.periodic(_tickInterval, (_) {
      unawaited(_softTick());
    });
    Future<void>.delayed(const Duration(seconds: 45), () {
      if (_timer != null) unawaited(_softTick());
    });
  }

  Future<void> _softTick() async {
    if (!await EasySetupBulletproofPrefs.instance.realtimeBrowserGuard()) {
      return;
    }
    await runOnce(graceSeconds: _killGraceSeconds);
  }

  /// One-shot soft handoff: repatch shortcuts + migrate unprotected browsers.
  /// Returns migrated browser id (`chrome`/`edge`/`firefox`) or `none`.
  Future<String?> runOnce({int graceSeconds = _killGraceSeconds}) async {
    if (!Platform.isWindows) return null;
    if (_tickRunning) return null;
    if (!await ChromeLoadExtensionLauncher.isInstalled()) return null;
    _tickRunning = true;
    try {
      await _writePolicyFlag();
      await BrowserAppAllowlistService.instance.syncSidecar();
      await _writeScript(graceSeconds: graceSeconds);
      _scriptWritten = true;
      // The embedded PS script may Stop-Process unprotected chrome/edge.
      // Pre-stamp the ledger at image level so BrowserExitWatcherService
      // doesn't mis-classify them as external. Image TTL is 90 s, the
      // script finishes in seconds.
      //
      // @incident: firefox_relaunch_loop — do NOT pre-stamp Firefox;
      // extension/policy reload can land inside the kill-ledger window and
      // trigger a false "전환 차단됨" notice.
      // Firefox is deliberately excluded: Invoke-SoftHandoff always
      // returns false for firefox (see the guard inside the embedded
      // script below) and never touches it. Stamping firefox.exe here
      // anyway falsely credited this app for any Firefox exit that
      // happened to land in the 90 s window — producing a "Firefox가
      // 보호 브라우저로 전환되어 종료됨" notice even when the user never
      // opened Firefox and this service did nothing to it. See
      // memory/project_firefox_relaunch_loop and the 2026-07-06 user
      // report of phantom Firefox "차단됨" notices.
      const String reason = '보호 브라우저로 자동 전환 — 미보호 인스턴스 종료';
      for (final String exe in const <String>['chrome.exe', 'msedge.exe']) {
        OwnKillLedger.instance.stampImage(
          imageName: exe,
          reason: reason,
          reasonKey: 'realtime_guard_migrate',
        );
      }
      final ProcessResult r = await windowsRunHidden(_psExe(), <String>[
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        _scriptFile,
      ]);
      final String out = '${r.stdout}'.trim();
      if (out.isNotEmpty) {
        AppLogger.instance.info('browser_realtime: $out');
      }
      _parseAndLog(out);
      final RegExpMatch? m = RegExp(r'migrated=(\w+)').firstMatch(out);
      return m?.group(1) ?? 'none';
    } catch (e, st) {
      AppLogger.instance.warn('browser_realtime runOnce failed: $e\n$st');
      return null;
    } finally {
      _tickRunning = false;
    }
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  // ignore: unused_element
  Future<void> _tickRetired() async {
    if (_tickRunning) return;
    if (!await EasySetupBulletproofPrefs.instance.realtimeBrowserGuard()) {
      return;
    }
    if (!await ChromeLoadExtensionLauncher.isInstalled()) {
      return;
    }
    _tickRunning = true;
    try {
      if (!_scriptWritten) {
        await _writePolicyFlag();
        await _writeScript();
        _scriptWritten = true;
      }
      final ProcessResult r = await windowsRunHidden(_psExe(), <String>[
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        _scriptFile,
      ]);
      final String out = '${r.stdout}'.trim();
      if (out.isNotEmpty) {
        AppLogger.instance.info('browser_realtime: $out');
      }
      _parseAndLog(out);
    } catch (e, st) {
      AppLogger.instance.warn('browser_realtime tick failed: $e\n$st');
    } finally {
      _tickRunning = false;
    }
  }

  Future<void> syncScriptOnly() async {
    if (!Platform.isWindows) return;
    await _writePolicyFlag();
    await _writeScript();
  }

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

  Future<void> _writePolicyFlag() async {
    try {
      final DateTime now = DateTime.now();
      bool active;
      if (_policyCacheAt != null &&
          _policyCacheValue != null &&
          now.difference(_policyCacheAt!) < _policyCacheTtl) {
        active = _policyCacheValue!;
      } else {
        final ExtensionPolicyVerifyResult v =
            await WindowsExtensionGuardService.verifyAllPolicies();
        final bool ytEnforce = await WindowsBrowserProxyPolicyService.instance
            .isYoutubeEnforceActive();
        active =
            ytEnforce ||
            v.chromeHklmOk ||
            v.chromeHkcuOk ||
            v.edgeHklmOk ||
            v.edgeHkcuOk;
        _policyCacheAt = now;
        _policyCacheValue = active;
      }
      final File f = File(_policyFlagFile);
      await f.parent.create(recursive: true);
      await f.writeAsString(active ? '1' : '0', flush: true);
    } catch (_) {}
  }

  void _parseAndLog(String out) {
    final RegExpMatch? m = RegExp(r'migrated=(\w+)').firstMatch(out);
    if (m == null || m.group(1) == 'none') return;
    final String which = m.group(1)!;
    final String displayName = switch (which) {
      'edge' => 'Edge',
      'firefox' => 'Firefox',
      _ => 'Chrome',
    };
    const String reason =
        '보호 브라우저로 자동 전환 — 일반 아이콘은 처음부터 보호 실행기로 열리도록 다시 고쳤고, 직접 실행된 미보호 창은 즉시 닫았습니다.';
    BlockActivityLogService.instance.record(
      kind: BlockActivityKind.protection,
      message: '보호 없이 열린 $displayName → 보호 브라우저로 즉시 전환',
      data: <String, Object?>{'browser': which, 'source': 'realtime_guard'},
      debounceKey: 'rt_migrate_$which',
    );
    AppBlockUserNoticeService.instance.notifyBrowserKilledWithReason(
      browserOrAppDisplayName: displayName,
      reasonKo: reason,
      debounceKey: 'rt_migrate_notice_$which',
    );
  }

  Future<void> _writeScript({int graceSeconds = _killGraceSeconds}) async {
    final Directory dir = Directory(ChromeLoadExtensionLauncher.sixVpnDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    String esc(String s) => s.replaceAll("'", "''");
    final String hijack = esc(
      p.join(ChromeLoadExtensionLauncher.sixVpnDir, 'shortcut_hijack.ps1'),
    );
    final String policyFlag = esc(_policyFlagFile);
    final String ytEnforceFlag = esc(
      p.join(
        ChromeLoadExtensionLauncher.sixVpnDir,
        'youtube_enforce_active.flag',
      ),
    );
    final String chromeVbs = esc(ChromeLoadExtensionLauncher.chromeVbsPath);
    final String edgeVbs = esc(ChromeLoadExtensionLauncher.edgeVbsPath);
    final String firefoxVbs = esc(ChromeLoadExtensionLauncher.firefoxVbsPath);
    final String allowTokens = AllowedBrowserAppCatalog.allTitleTokens()
        .map((String t) => "'${esc(t)}'")
        .join(',');

    const String body = r'''
$ErrorActionPreference = 'SilentlyContinue'
$patched = 0
$migrated = 'none'
$hijack = 'HIJACK_PS1'
$policyFlag = 'POLICY_FLAG'
$ytEnforceFlag = 'YT_ENFORCE_FLAG'
$chromeVbs = 'CHROME_VBS'
$edgeVbs = 'EDGE_VBS'
$firefoxVbs = 'FIREFOX_VBS'
$policyActive = (Test-Path -LiteralPath $policyFlag) -and ((Get-Content -LiteralPath $policyFlag -Raw).Trim() -eq '1')
$ytEnforce = Test-Path -LiteralPath $ytEnforceFlag
$graceSeconds = GRACE_SECONDS
# Allow-listed in-browser apps (Gemini / Gmail / Google 로그인 / YouTube Music).
# If a browser has any window whose title contains one of these, NEVER hand it
# off / kill it — that would close the allowed app too. See AllowedBrowserAppCatalog.
$allowTokens = @(ALLOW_TOKENS)

function Test-AllowedBrowserWindowOpen([string]$imageName) {
  if ($allowTokens.Count -eq 0) { return $false }
  $stem = $imageName -replace '\.exe$',''
  foreach ($pr in (Get-Process -Name $stem -ErrorAction SilentlyContinue)) {
    $t = $pr.MainWindowTitle
    if ([string]::IsNullOrWhiteSpace($t)) { continue }
    $tl = $t.ToLower()
    foreach ($tok in $allowTokens) { if ($tl.Contains($tok)) { return $true } }
  }
  return $false
}

if (Test-Path -LiteralPath $hijack) {
  $out = powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File $hijack 2>&1
  if ($out -match 'patched=(\d+)') { $patched = [int]$Matches[1] }
}

function Test-Protected([string]$cmd, [string]$browser) {
  if ([string]::IsNullOrWhiteSpace($cmd)) { return $false }
  # Load-extension args are the strongest signal — always trust them, even
  # under YouTube enforcement. The extension is what enforces YT blocking.
  if ($cmd -match 'load-extension|disable-extensions-except|sixvpnblocker|chrome_blocker') { return $true }
  if ($cmd -match '--disable-extensions') { return $false }
  # HKCU PAC + URLBlocklist applies to plain chrome.exe — do not kill it.
  if ($policyActive -and ($browser -eq 'chrome' -or $browser -eq 'edge')) { return $true }
  if ($ytEnforce) { return $false }
  return $false
}

function Get-MainProcs([string]$imageName) {
  Get-CimInstance Win32_Process -Filter "Name='$imageName'" -ErrorAction SilentlyContinue |
    Where-Object {
      $c = $_.CommandLine
      $null -ne $c -and $c -notmatch '--type=' -and $c -notmatch '--webview'
    }
}

function Get-ProcAgeSeconds($proc) {
  try {
    $start = [Management.ManagementDateTimeConverter]::ToDateTime($proc.CreationDate)
    return ([DateTime]::Now - $start).TotalSeconds
  } catch {
    return [double]::MaxValue
  }
}

function Invoke-SoftHandoff([string]$browser, [string]$vbs, [string]$imageName) {
  if (-not (Test-Path -LiteralPath $vbs)) { return $false }
  # Firefox guard: a "handoff" relaunches plain firefox.exe, but firefox has no
  # protected-launch flag (unlike Chrome's --load-extension) — its protection is
  # the force-installed enterprise extension policy, and a relaunched window is
  # never any more protected than the one already running. So the handoff can
  # never succeed for firefox: it just spawned a fresh window on every tick (the
  # "Firefox opens every minute" bug). Leave firefox to the policy watchdog and
  # never launch or kill it from here.
  if ($browser -eq 'firefox') { return $false }
  # Allow-list guard: keep Gemini/Gmail/YouTube Music/Google 로그인 alive.
  if (Test-AllowedBrowserWindowOpen $imageName) { return $false }
  $procs = @(Get-MainProcs $imageName)
  if ($procs.Count -eq 0) { return $false }
  $protected = @($procs | Where-Object { Test-Protected $_.CommandLine $browser })
  # Grace period — never kill a freshly-launched browser. Without this, the
  # user clicks Chrome, reads half a page, and the window vanishes.
  $killable = @($procs | Where-Object {
    -not (Test-Protected $_.CommandLine $browser) -and
    (Get-ProcAgeSeconds $_) -gt $graceSeconds
  })
  if ($killable.Count -eq 0) { return $false }
  # Only kill if we can actually replace it — otherwise the user is left with
  # no browser at all.
  if ($protected.Count -eq 0) {
    $proc = Start-Process -FilePath 'wscript.exe' -ArgumentList @('//B','//Nologo',$vbs) -WindowStyle Hidden -PassThru -ErrorAction SilentlyContinue
    if (-not $proc) { return $false }
    Start-Sleep -Milliseconds 500
    $afterProtected = @(Get-MainProcs $imageName | Where-Object { Test-Protected $_.CommandLine $browser })
    if ($afterProtected.Count -eq 0) { return $false }
  }
  foreach ($p in $killable) {
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
  }
  return $true
}

if (Invoke-SoftHandoff 'chrome' $chromeVbs 'chrome.exe') { $migrated = 'chrome' }
elseif (Invoke-SoftHandoff 'edge' $edgeVbs 'msedge.exe') { $migrated = 'edge' }
elseif (Invoke-SoftHandoff 'firefox' $firefoxVbs 'firefox.exe') { $migrated = 'firefox' }

Write-Output "patched=$patched migrated=$migrated policy=$policyActive"
''';

    await File(_scriptFile).writeAsString(
      body
          .replaceAll('HIJACK_PS1', hijack)
          .replaceAll('POLICY_FLAG', policyFlag)
          .replaceAll('YT_ENFORCE_FLAG', ytEnforceFlag)
          .replaceAll('CHROME_VBS', chromeVbs)
          .replaceAll('EDGE_VBS', edgeVbs)
          .replaceAll('FIREFOX_VBS', firefoxVbs)
          .replaceAll('ALLOW_TOKENS', allowTokens)
          .replaceAll('GRACE_SECONDS', '$graceSeconds'),
      flush: true,
    );
  }
}
