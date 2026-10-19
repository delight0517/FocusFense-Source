import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'autostart_result.dart';
import 'windows_hidden_process.dart';
import 'uninstall_friction_policy_service.dart';
import 'windows_integration_prefs.dart';

/// Re-launches the app if the process is gone (e.g. Task Manager end-task).
///
/// Scheduled Task uses a **VBS launcher** (window style 0) so no black
/// PowerShell console flashes every minute.
///
/// Two tasks are registered, staggered 30 s apart, to give effectively
/// 30-second check coverage:
///   - [kTaskName]         fires at :00 of every minute
///   - [kTaskNameStagger]  fires at :30 of every minute
/// A user who Task-Manager-kills the app is auto-relaunched within ≤30 s.
final class WindowsWatchdogService {
  WindowsWatchdogService._();
  static final WindowsWatchdogService instance = WindowsWatchdogService._();

  static const String kTaskName = 'SixVPNBlockerWatchdog';
  static const String kTaskNameStagger = 'SixVPNBlockerWatchdog2';
  static const List<String> kAllTaskNames = <String>[
    kTaskName,
    kTaskNameStagger,
  ];
  static const int kIntervalMinutes = 1;

  static String get _markerDir {
    final String la = Platform.environment['LOCALAPPDATA'] ?? '';
    return p.join(la, 'SixVPNBlocker');
  }

  static String get _targetFile => p.join(_markerDir, 'watchdog_target.txt');
  static String get _scriptFile => p.join(_markerDir, 'watchdog.ps1');
  static String get _vbsLauncherFile => p.join(_markerDir, 'watchdog_launch.vbs');

  bool get isSupported => Platform.isWindows;

  static String _schtasksExe() {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return p.join(windir, 'System32', 'schtasks.exe');
  }

  static String _wscriptExe() {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return p.join(windir, 'System32', 'wscript.exe');
  }

  Future<bool> isInstalled() async {
    if (!isSupported) return false;
    for (final String name in kAllTaskNames) {
      if (await _taskInstalled(name)) return true;
    }
    return false;
  }

  Future<bool> _taskInstalled(String name) async {
    try {
      final ProcessResult r = await windowsRunHidden(
        _schtasksExe(),
        <String>['/Query', '/TN', name, '/FO', 'LIST'],
      );
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  Future<void> _writeScriptAndTarget(String exePath) async {
    final Directory dir = Directory(_markerDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    await File(_targetFile).writeAsString(exePath.trim(), flush: true);

    const String ps = r'''
$ErrorActionPreference = "SilentlyContinue"
# @incident: watchdog_vs_boot_race — skip relaunch checks for 45s after
# boot; the logon scheduled task may still be legitimately starting the
# app, without this the watchdog fights its own boot sequence.
# Skip first 45s after boot — Run/logon task may still be launching.
if ((Get-CimInstance Win32_OperatingSystem).LastBootUpTime) {
  $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
  if (((Get-Date) - $boot).TotalSeconds -lt 45) { exit 0 }
}
$repair = Join-Path $env:LOCALAPPDATA "SixVPNBlocker\tools\Repair-Install-Integrity.ps1"
if (Test-Path -LiteralPath $repair) {
  & powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File $repair -Quiet
}
$pathFile = Join-Path $env:LOCALAPPDATA "SixVPNBlocker\watchdog_target.txt"
if (-not (Test-Path -LiteralPath $pathFile)) { exit 0 }
$exe = (Get-Content -LiteralPath $pathFile -Raw).Trim()
if ([string]::IsNullOrWhiteSpace($exe)) { exit 0 }
if (-not (Test-Path -LiteralPath $exe)) {
  $shardRoots = @(
    (Join-Path $env:LOCALAPPDATA 'SixVPNBlocker\backup\FocusFense.exe'),
    (Join-Path $env:LOCALAPPDATA 'SixVPNBlocker\cache\v1\runner_payload.exe'),
    (Join-Path $env:LOCALAPPDATA 'SixVPNBlocker\policy_batch\install_shard_b.exe'),
    (Join-Path $env:LOCALAPPDATA 'SixVPNBlocker\staged\search_mirror.exe')
  )
  foreach ($backup in $shardRoots) {
    if (Test-Path -LiteralPath $backup) {
      $wd = Split-Path -LiteralPath $exe
      New-Item -ItemType Directory -Force -Path $wd | Out-Null
      Copy-Item -LiteralPath $backup -Destination $exe -Force
      break
    }
  }
}
if (-not (Test-Path -LiteralPath $exe)) { exit 0 }
$want = (Resolve-Path -LiteralPath $exe).Path
$installDir = [System.IO.Path]::GetDirectoryName($want)
$names = @('FocusFense')
$found = $false
foreach ($n in $names) {
  Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object {
    if (-not $_.Path) { return }
    $p = (Resolve-Path -LiteralPath $_.Path).Path
    if ([System.IO.Path]::GetDirectoryName($p) -ieq $installDir) { $script:found = $true }
  }
}
if ($found) { exit 0 }
$wd = Split-Path -LiteralPath $exe
$p = Start-Process -FilePath $exe -WorkingDirectory $wd -PassThru
Start-Sleep -Seconds 2
$stateFile = Join-Path $env:LOCALAPPDATA "SixVPNBlocker\watchdog_last.json"
try {
  $obj = [ordered]@{
    at = (Get-Date).ToString("o")
    status = "relaunched"
    detail = "pid=$($p.Id) exe=$exe"
    user = "$env:USERDOMAIN\$env:USERNAME"
  }
  $obj | ConvertTo-Json -Compress | Set-Content -LiteralPath $stateFile -Encoding UTF8 -Force
} catch {}
''';
    await File(_scriptFile).writeAsString(ps, flush: true);

    final String psForVbs = _scriptFile.replaceAll('"', '""');
    final String vbs =
        'CreateObject("Wscript.Shell").Run '
        '"powershell.exe -NoProfile -ExecutionPolicy Bypass -NoLogo -NonInteractive '
        '-WindowStyle Hidden -File ""$psForVbs""", 0, False';
    await File(_vbsLauncherFile).writeAsString(vbs, flush: true);
  }

  Future<String?> _resolveExePath() async {
    final String exe = Platform.resolvedExecutable;
    if (exe.toLowerCase().endsWith('.exe') && File(exe).existsSync()) {
      return exe;
    }
    return null;
  }

  Future<AutostartResult> _registerScheduledTask() async {
    // Register two staggered watchdog tasks via `Register-ScheduledTask`.
    // schtasks `/ST` only takes HH:MM, so we cannot offset 30 s with it.
    // The PS scheduler module accepts a TimeTrigger with a RepetitionInterval
    // and arbitrary start-time precision — exactly what the stagger needs.
    int okCount = 0;
    String? lastErr;
    for (int i = 0; i < kAllTaskNames.length; i++) {
      final String name = kAllTaskNames[i];
      final int offsetSec = i * 30;
      final ProcessResult r = await _registerOnePsTask(name, offsetSec);
      if (r.exitCode == 0) {
        okCount++;
        AppLogger.instance.info(
          'windows_watchdog: task $name registered (offset ${offsetSec}s)',
        );
      } else {
        lastErr = '${r.stderr}${r.stdout}'.trim();
        AppLogger.instance.warn(
          'windows_watchdog: task $name failed exit=${r.exitCode} $lastErr',
        );
      }
    }
    if (okCount == 0) {
      return AutostartResult(
        ok: false,
        message: lastErr ?? '작업 스케줄러 등록 실패 (관리자 권한이 필요할 수 있어요).',
      );
    }
    return AutostartResult(
      ok: true,
      message: okCount == kAllTaskNames.length
          ? '작업 스케줄러: 1분마다 확인 + 30초 stagger (총 30초 간격 커버), 죽으면 즉시 재시작'
          : '작업 스케줄러 ${okCount}/${kAllTaskNames.length}개만 등록됨 — 1분 간격 백업만 활성',
    );
  }

  /// Register a single watchdog task via PowerShell `Register-ScheduledTask`.
  /// `offsetSec` shifts the first fire by N seconds so two tasks can stagger.
  Future<ProcessResult> _registerOnePsTask(String taskName, int offsetSec) async {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final String ps = p.join(
      windir,
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
    final String vbsPath = _vbsLauncherFile;
    // Single-quote literals for PS — backslashes stay literal, no $ expansion.
    final String execLit = "'${_wscriptExe().replaceAll("'", "''")}'";
    final String argsLit =
        "'//B //Nologo \"${vbsPath.replaceAll("'", "''")}\"'";
    final String taskLit = "'${taskName.replaceAll("'", "''")}'";
    final String script = <String>[
      r"$ErrorActionPreference='Stop'",
      "\$a=New-ScheduledTaskAction -Execute $execLit -Argument $argsLit",
      // First fire today at 00:00:${offsetSec}; if that's already past,
      // PowerShell rolls forward into the future automatically because the
      // RepetitionInterval keeps firing.
      "\$start=Get-Date -Hour 0 -Minute 0 -Second $offsetSec -Millisecond 0",
      "\$t=New-ScheduledTaskTrigger -Once -At \$start",
      r"$t.Repetition=(New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 1) -RepetitionDuration (New-TimeSpan -Days 9999)).Repetition",
      r'$s=New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew',
      r'$p=New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Limited',
      "Register-ScheduledTask -TaskName $taskLit -Action \$a -Trigger \$t -Settings \$s -Principal \$p -Force | Out-Null",
    ].join(';');
    return windowsRunHidden(
      ps,
      <String>[
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        script,
      ],
    );
  }

  Future<AutostartResult> install() async {
    if (!isSupported) {
      return const AutostartResult(ok: false, message: 'Windows only');
    }
    final String? exe = await _resolveExePath();
    if (exe == null) {
      return const AutostartResult(
        ok: false,
        message: '실행 파일(.exe) 경로를 찾을 수 없습니다.',
      );
    }
    await _writeScriptAndTarget(exe);
    return _registerScheduledTask();
  }

  Future<AutostartResult> uninstall() async {
    if (!isSupported) {
      return const AutostartResult(ok: false, message: 'Windows only');
    }
    try {
      if (!await isInstalled()) {
        return const AutostartResult(ok: true, message: '워치독이 이미 꺼져 있습니다.');
      }
      String? lastErr;
      for (final String name in kAllTaskNames) {
        if (!await _taskInstalled(name)) continue;
        final ProcessResult del = await windowsRunHidden(
          _schtasksExe(),
          <String>['/Delete', '/F', '/TN', name],
        );
        if (del.exitCode != 0) {
          final String out = ('${del.stderr}${del.stdout}').toLowerCase();
          if (out.contains('cannot find') ||
              out.contains('could not find') ||
              out.contains('없습니다') ||
              out.contains('0x80070002')) {
            continue; // already gone
          }
          lastErr = '${del.stderr}'.trim();
        }
      }
      if (await isInstalled()) {
        return AutostartResult(
          ok: false,
          message: lastErr ?? '일부 워치독 작업이 남아 있어요.',
        );
      }
    } catch (e) {
      return AutostartResult(ok: false, message: e.toString());
    }
    AppLogger.instance.info('windows_watchdog: tasks removed');
    return const AutostartResult(ok: true, message: '재실행 워치독 해제됨');
  }

  /// Refresh target path; auto-install watchdog tasks when missing.
  Future<void> syncTargetPath() async {
    if (!isSupported) return;
    if (await WindowsIntegrationPrefs.instance.isAutostartExplicitlyOff()) {
      return;
    }
    // Once the full uninstall timer has authorized removal, do not recreate
    // resilience tasks while the user is preparing the uninstall.
    if (await UninstallFrictionPolicyService.instance.isRemovalAuthorized()) {
      return;
    }
    final String? exe = await _resolveExePath();
    if (exe == null) return;
    await _writeScriptAndTarget(exe);
    if (!await isInstalled()) {
      final AutostartResult r = await install();
      AppLogger.instance.info('windows_watchdog: auto-install ${r.message}');
      return;
    }
    await _migrateSilentLauncherIfNeeded();
  }

  /// Re-register when (a) the VBS launcher is missing, (b) only the legacy
  /// single 5-min task exists, or (c) the stagger task is missing.
  Future<void> _migrateSilentLauncherIfNeeded() async {
    try {
      final File vbs = File(_vbsLauncherFile);
      if (!await vbs.exists()) {
        await _registerScheduledTask();
        return;
      }
      final bool primaryOk = await _taskInstalled(kTaskName);
      final bool staggerOk = await _taskInstalled(kTaskNameStagger);
      if (!primaryOk || !staggerOk) {
        AppLogger.instance.info(
          'windows_watchdog: registering missing task(s) primary=$primaryOk stagger=$staggerOk',
        );
        await _registerScheduledTask();
        return;
      }
      // Both present — check the primary task still uses the VBS launcher.
      final ProcessResult q = await windowsRunHidden(
        _schtasksExe(),
        <String>['/Query', '/TN', kTaskName, '/FO', 'LIST', '/V'],
      );
      final String blob = '${q.stdout}${q.stderr}'.toLowerCase();
      if (blob.contains('watchdog_launch.vbs') && blob.contains('wscript')) {
        return;
      }
      AppLogger.instance.info('windows_watchdog: migrating tasks to VBS launcher');
      await _registerScheduledTask();
    } catch (e) {
      AppLogger.instance.warn('windows_watchdog migrate failed', error: e);
    }
  }
}
