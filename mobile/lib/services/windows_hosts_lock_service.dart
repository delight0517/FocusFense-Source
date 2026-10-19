import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'windows_hidden_process.dart';
import 'windows_system_block_service.dart';

/// Locks `%WINDIR%\\System32\\drivers\\etc\\hosts` after a successful UAC
/// apply — read-only attribute + deny write for built-in Users group.
///
/// Principle B from the user's blocker blueprint: standard users cannot
/// edit hosts to bypass DNS sinkhole. Admin (or this app via UAC) can still
/// update through the elevated apply path.
final class WindowsHostsLockService {
  WindowsHostsLockService._();
  static final WindowsHostsLockService instance = WindowsHostsLockService._();

  bool get isSupported => Platform.isWindows;

  static String hostsPath() => WindowsSystemBlockService.systemHostsPath();

  static String _psExe() {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return p.join(windir, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  }

  /// PowerShell fragment embedded in the elevated hosts script (admin only).
  static String elevatedLockFragment() {
    return r'''
  # --- 6 VPN Blocker: lock hosts (read-only + Users deny write) ---
  try {
    $hp = $HostsPath
    attrib -R $hp 2>$null | Out-Null
    icacls $hp /inheritance:r 2>$null | Out-Null
    icacls $hp /grant:r "SYSTEM:(F)" "Administrators:(F)" 2>$null | Out-Null
    icacls $hp /grant "Users:(R)" 2>$null | Out-Null
    attrib +R $hp 2>$null | Out-Null
    Write-Host "[sixvpn] hosts locked: $hp"
  } catch {
    Write-Host "[sixvpn] hosts lock skip: $($_.Exception.Message)"
  }
''';
  }

  static String elevatedUnlockFragment() {
    return r'''
  try {
    $hp = $HostsPath
    attrib -R $hp 2>$null | Out-Null
    icacls $hp /reset 2>$null | Out-Null
    Write-Host "[sixvpn] hosts unlock: $hp"
  } catch {
    Write-Host "[sixvpn] hosts unlock skip: $($_.Exception.Message)"
  }
''';
  }

  /// Best-effort probe (no admin): read-only flag + writable test.
  Future<HostsLockStatus> probe() async {
    if (!isSupported) {
      return const HostsLockStatus(locked: false, readOnly: false, message: 'Windows 전용');
    }
    final String path = hostsPath();
    final File f = File(path);
    if (!await f.exists()) {
      return HostsLockStatus(locked: false, readOnly: false, message: 'hosts 없음');
    }
    try {
      final ProcessResult r = await windowsRunHidden(
        _psExe(),
        <String>[
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-Command',
          r'''
$hp = 'HOSTS_PATH'
$ro = $false
try {
  $item = Get-Item -LiteralPath $hp -Force
  $ro = $item.IsReadOnly
} catch {}
$writable = $false
try {
  $fs = [System.IO.File]::Open($hp, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
  $fs.Close()
  $writable = $true
} catch {}
Write-Output "ro=$ro writable=$writable"
'''.replaceAll('HOSTS_PATH', path.replaceAll("'", "''")),
        ],
      );
      final String out = '${r.stdout}'.trim();
      final bool ro = out.contains('ro=True');
      final bool writable = out.contains('writable=True');
      final bool locked = ro && !writable;
      return HostsLockStatus(
        locked: locked,
        readOnly: ro,
        writable: writable,
        message: locked
            ? '읽기 전용 + 쓰기 거부'
            : (ro ? '읽기 전용 (부분)' : '잠금 없음 — UAC 적용 시 자동 잠금'),
      );
    } catch (e) {
      return HostsLockStatus(locked: false, readOnly: false, message: 'probe skip: $e');
    }
  }
}

final class HostsLockStatus {
  const HostsLockStatus({
    required this.locked,
    required this.readOnly,
    this.writable = false,
    required this.message,
  });

  final bool locked;
  final bool readOnly;
  final bool writable;
  final String message;
}
