import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'windows_desktop_rebuild_service.dart';
import 'windows_hidden_process.dart';

/// After the user approves UAC **once**, registers an elevated scheduled task
/// that restarts DNS sinkhole / verifies hosts without further prompts.
final class WindowsSilentElevatedMaintainService {
  WindowsSilentElevatedMaintainService._();
  static final WindowsSilentElevatedMaintainService instance =
      WindowsSilentElevatedMaintainService._();

  static const String kTaskName = 'SixVPNBlockerElevatedMaintain';
  static const String kStampFileName = 'blocking_active_v1.json';

  String _localDir() {
    final String local = Platform.environment['LOCALAPPDATA'] ?? '';
    return p.join(local, 'SixVPNBlocker');
  }

  String stampPath() => p.join(_localDir(), kStampFileName);

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

  String _schtasksExe() {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return p.join(windir, 'System32', 'schtasks.exe');
  }

  Future<void> writeBlockingStamp({required bool active}) async {
    if (!Platform.isWindows) return;
    final Directory dir = Directory(_localDir());
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final File f = File(stampPath());
    if (!active) {
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
      return;
    }
    await f.writeAsString(
      jsonEncode(<String, Object>{
        'active': true,
        'updatedAt': DateTime.now().toUtc().toIso8601String(),
      }),
      flush: true,
    );
  }

  Future<bool> isTaskRegistered() async {
    if (!Platform.isWindows) return false;
    final ProcessResult r = await windowsRunHidden(
      _schtasksExe(),
      <String>['/Query', '/TN', kTaskName, '/FO', 'LIST'],
    );
    return r.exitCode == 0;
  }

  /// Call from inside an **already elevated** PowerShell fragment (hosts apply).
  static String elevatedRegisterTaskFragment() {
    final String maintain = p
        .join(
          Platform.environment['LOCALAPPDATA'] ?? '',
          'SixVPNBlocker',
          'tools',
          'Elevated-Maintain-Block.ps1',
        )
        .replaceAll("'", "''");
    return r'''
  # --- 6 VPN Blocker: register silent elevated maintain task (one-time) ---
  try {
    $maintainScript = '$maintain'
    if (-not (Test-Path -LiteralPath $maintainScript)) {
      Write-Host "[sixvpn] elevated maintain script missing: $maintainScript"
    }
    $stamp = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker\blocking_active_v1.json'
    @{ active = $true; updatedAt = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath $stamp -Encoding UTF8
    $taskName = 'SixVPNBlockerElevatedMaintain'
    $existing = schtasks /Query /TN $taskName /FO LIST 2>$null
    if (-not $existing) {
      $arg = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$maintainScript`""
      $a = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
      $t = New-ScheduledTaskTrigger -Once -At (Get-Date)
      $t.Repetition = (New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 30) -RepetitionDuration (New-TimeSpan -Days 9999)).Repetition
      $s = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew
      $p = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive -RunLevel Highest
      Register-ScheduledTask -TaskName $taskName -Action $a -Trigger $t -Settings $s -Principal $p -Force | Out-Null
    }
  } catch {}
''';
  }

  Future<bool> ensureScriptOnDisk() async {
    if (!Platform.isWindows) return false;
    final String? mobileRoot =
        await WindowsDesktopRebuildService.discoverMobileRoot(persist: false);
    if (mobileRoot == null) return false;
    final String src =
        p.join(mobileRoot, 'tools', 'Elevated-Maintain-Block.ps1');
    if (!await File(src).exists()) return false;
    final String destDir = p.join(_localDir(), 'tools');
    await Directory(destDir).create(recursive: true);
    final String dest = p.join(destDir, 'Elevated-Maintain-Block.ps1');
    await File(src).copy(dest);
    return true;
  }

  /// After successful UAC apply — stamp + elevated task registered in-script.
  Future<void> onElevatedApplySuccess() async {
    if (!Platform.isWindows) return;
    await ensureScriptOnDisk();
    await writeBlockingStamp(active: true);
    AppLogger.instance.info('elevated_maintain: stamp written');
  }
}
