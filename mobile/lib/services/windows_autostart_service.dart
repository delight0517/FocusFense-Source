import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

import 'app_logger.dart';
import 'autostart_result.dart';
import 'windows_hidden_process.dart';
import 'windows_start_menu_service.dart';

/// Windows user-login autostart.
///
/// The Run-registry value is written via the native Win32 `RegSetValueEx`
/// API rather than `reg.exe /d` because reg.exe strips embedded quote
/// characters during its own arg processing, which corrupted earlier
/// `cmd /c start "" /D "..." "..."` commands so badly that nothing
/// launched at logon. The value we now store is just the EXE path
/// quoted — Flutter Desktop resolves `data\flutter_assets` relative to
/// the module path, so a working-directory wrapper is unnecessary.
final class WindowsAutostartService {
  WindowsAutostartService._();
  static final WindowsAutostartService instance = WindowsAutostartService._();

  static const String kShortcutName = 'Focus Fense.lnk';
  static const String kRunValueName = 'SixVPNBlocker';
  static const String kLogonTaskName = 'SixVPNBlockerAutostart';
  static const String kBootGuardTaskName = 'SixVPNBlockerBootGuard';
  static const int kLogonDelaySeconds = 25;
  static const int kBootGuardDelaySeconds = 55;
  static const String _runSubKey =
      r'Software\Microsoft\Windows\CurrentVersion\Run';
  static const String _approvedRunSubKey =
      r'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run';
  static const String _hklmRunSubKey =
      r'SOFTWARE\Microsoft\Windows\CurrentVersion\Run';

  bool get isSupported => Platform.isWindows;

  String get _startupDir {
    final String appData = Platform.environment['APPDATA'] ?? '';
    return p.join(
      appData,
      'Microsoft',
      'Windows',
      'Start Menu',
      'Programs',
      'Startup',
    );
  }

  String get _shortcutPath => p.join(_startupDir, kShortcutName);

  Future<bool> isInstalled() async {
    if (!isSupported) return false;
    final String? reg = _readRunRegistryValueNative();
    if (reg == null || reg.trim().isEmpty) return false;
    final String? exe = await _canonicalAutostartExe();
    if (exe == null) return false;
    final String normExe = p.normalize(exe).toLowerCase();
    final String normReg = reg.toLowerCase();
    return normReg.contains(normExe);
  }

  /// Refresh Run registry + logon task; remove legacy Startup shortcut.
  Future<void> repairAutostart() async {
    if (!isSupported) return;
    try {
      final File startup = File(_shortcutPath);
      if (await startup.exists()) {
        await startup.delete();
        AppLogger.instance.info(
          'autostart: removed duplicate Startup shortcut',
        );
      }
    } catch (_) {}
    final String? exe = await _canonicalAutostartExe();
    if (exe == null) return;
    final String value = _runRegistryValue(exe);
    final bool wrote = _writeRunRegistryNative(value);
    AppLogger.instance.info(
      'autostart: native Run write ${wrote ? "ok" : "FAILED"} → $value',
    );
    _ensureStartupApprovedEnabledNative();
    await _ensureLogonTask(exe);
    await _ensureBootGuardTask(exe);
  }

  Future<String?> _canonicalAutostartExe() async {
    final String primary = p.join(
      Platform.environment['LOCALAPPDATA'] ?? '',
      'Programs',
      WindowsStartMenuService.kInstallSubdir,
      'FocusFense.exe',
    );
    if (await File(primary).exists()) return primary;
    return WindowsStartMenuService.resolveLaunchExe();
  }

  Future<AutostartResult> install() async {
    if (!isSupported) {
      return const AutostartResult(ok: false, message: 'Windows only');
    }

    final String? exe = await _canonicalAutostartExe();
    if (exe == null) {
      return const AutostartResult(
        ok: false,
        message: '실행 파일(.exe) 경로를 찾을 수 없습니다.',
      );
    }

    await repairAutostart();
    if (!await isInstalled()) {
      return const AutostartResult(
        ok: false,
        message: '자동 시작 등록 실패 (Run 레지스트리)',
      );
    }

    return const AutostartResult(
      ok: true,
      message: 'Windows 로그인 시 자동 시작 · Run 레지스트리 (native)',
    );
  }

  Future<AutostartResult> uninstall() async {
    if (!isSupported) {
      return const AutostartResult(ok: false, message: 'Windows only');
    }
    try {
      final File f = File(_shortcutPath);
      if (await f.exists()) {
        await f.delete();
      }
      _deleteRunRegistryNative();
      await _removeLogonTask();
      await _removeBootGuardTask();
    } catch (e) {
      return AutostartResult(ok: false, message: e.toString());
    }
    return const AutostartResult(ok: true, message: '자동 시작 해제됨');
  }

  /// User-selected manual mode: remove startup launch entries and disable
  /// resilience tasks while keeping their definitions available for a later
  /// explicit re-enable in Settings.
  Future<AutostartResult> disableForManualMode() async {
    if (!isSupported) {
      return const AutostartResult(ok: false, message: 'Windows only');
    }
    try {
      final File startup = File(_shortcutPath);
      if (await startup.exists()) await startup.delete();
      _deleteRunRegistryNative();
      const List<String> tasks = <String>[
        'SixVPNBlockerAutostart',
        'SixVPNBlockerBootGuard',
        'SixVPNBlockerOfflineGuard',
        'SixVPNBlockerWatchdog',
        'SixVPNBlockerWatchdog2',
        'SixVPNBlockerElevatedMaintain',
        'SixVPNBrowserGuard',
        'SixVPNTier3Watchdog',
      ];
      final List<String> failures = <String>[];
      for (final String task in tasks) {
        final ProcessResult query = await windowsRunHidden(
          _schtasksExe(),
          <String>['/Query', '/TN', task],
        );
        if (query.exitCode != 0) continue;
        final ProcessResult result = await windowsRunHidden(
          _schtasksExe(),
          <String>['/Change', '/TN', task, '/Disable'],
        );
        if (result.exitCode != 0) failures.add(task);
      }
      if (failures.isNotEmpty) {
        return AutostartResult(
          ok: false,
          message: '자동 실행은 껐지만 일부 복구 작업 비활성화 실패: ${failures.join(', ')}',
        );
      }
      return const AutostartResult(
        ok: true,
        message: '수동 실행 모드 — 시작 항목 제거, 복구 작업은 비활성화 상태로 보존',
      );
    } catch (e) {
      return AutostartResult(ok: false, message: e.toString());
    }
  }

  /// The value Windows will execute at logon. Bare EXE path, quoted in
  /// case the install path ever contains a space (current path doesn't,
  /// but other users on the machine may).
  String _runRegistryValue(String exe) => '"$exe"';

  // ---- HKLM Run mirror (machine-wide autostart, requires UAC once) ----

  /// Read-only — anyone can query HKLM\...\Run.
  Future<bool> isHklmMirrorInstalled() async {
    if (!isSupported) return false;
    final String? exe = await _canonicalAutostartExe();
    if (exe == null) return false;
    final String? value = _readRegistryStringNative(
      hive: HKEY_LOCAL_MACHINE,
      subKey: _hklmRunSubKey,
      name: kRunValueName,
    );
    if (value == null || value.trim().isEmpty) return false;
    final String normExe = p.normalize(exe).toLowerCase();
    return value.toLowerCase().contains(normExe);
  }

  /// Triggers a UAC prompt and writes `HKLM\...\Run\SixVPNBlocker`. After
  /// install, the entry survives:
  ///   - "Disable" in Task Manager > Startup Apps (HKCU-only setting)
  ///   - the user creating a brand-new Windows account on this PC
  /// Returns ok=false if the UAC prompt is cancelled or the elevated
  /// writer fails. Idempotent — safe to call repeatedly.
  Future<AutostartResult> installHklmMirror() async {
    if (!isSupported) {
      return const AutostartResult(ok: false, message: 'Windows only');
    }
    final String? exe = await _canonicalAutostartExe();
    if (exe == null) {
      return const AutostartResult(
        ok: false,
        message: '실행 파일(.exe) 경로를 찾을 수 없습니다.',
      );
    }
    final String? script = await _resolveHklmScriptPath();
    if (script == null) {
      return const AutostartResult(
        ok: false,
        message: 'Install-Hklm-Autostart.ps1 를 찾지 못했어요 (개발 빌드 전용).',
      );
    }
    final ProcessResult r = await _runElevatedPs(
      script: script,
      args: <String>['-ExePath', exe],
    );
    if (r.exitCode != 0) {
      final String err = '${r.stderr}${r.stdout}'.trim();
      AppLogger.instance.warn(
        'autostart_hklm: elevation failed exit=${r.exitCode} $err',
      );
      return AutostartResult(
        ok: false,
        message: err.isEmpty ? 'UAC 거부 또는 관리자 권한 실패 (코드 ${r.exitCode})' : err,
      );
    }
    final bool ok = await isHklmMirrorInstalled();
    AppLogger.instance.info('autostart_hklm: install verified=$ok');
    return AutostartResult(
      ok: ok,
      message: ok
          ? 'HKLM 미러 등록됨 — 어느 사용자 계정에서도 자동 시작'
          : '레지스트리 쓰기는 성공했지만 검증 실패 (다시 시도해주세요)',
    );
  }

  Future<AutostartResult> uninstallHklmMirror() async {
    if (!isSupported) {
      return const AutostartResult(ok: false, message: 'Windows only');
    }
    if (!await isHklmMirrorInstalled()) {
      return const AutostartResult(ok: true, message: 'HKLM 미러가 이미 없어요.');
    }
    final String? script = await _resolveHklmScriptPath();
    if (script == null) {
      return const AutostartResult(
        ok: false,
        message: 'Install-Hklm-Autostart.ps1 를 찾지 못했어요.',
      );
    }
    final String? exe = await _canonicalAutostartExe();
    final ProcessResult r = await _runElevatedPs(
      script: script,
      args: <String>['-ExePath', exe ?? 'unused', '-Remove'],
    );
    if (r.exitCode != 0) {
      final String err = '${r.stderr}${r.stdout}'.trim();
      return AutostartResult(
        ok: false,
        message: err.isEmpty ? 'UAC 거부 또는 실패' : err,
      );
    }
    return const AutostartResult(ok: true, message: 'HKLM 미러 해제됨');
  }

  /// The PS script that does the actual HKLM write. Embedded here so we
  /// don't rely on the rebuild script copying a tools/ folder into the
  /// install dir — one less moving piece to break. Idempotent: we
  /// (over)write it on every call.
  static const String _kHklmWriterPs = r'''
param(
  [Parameter(Mandatory = $true)] [string] $ExePath,
  [switch] $Remove
)
$ErrorActionPreference = 'Stop'
$runKeyPath = 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$valueName  = 'SixVPNBlocker'
try {
  $runKey = [Microsoft.Win32.Registry]::LocalMachine.OpenSubKey($runKeyPath, $true)
  if (-not $runKey) {
    $runKey = [Microsoft.Win32.Registry]::LocalMachine.CreateSubKey($runKeyPath)
  }
  if ($Remove) {
    try { $runKey.DeleteValue($valueName, $false) } catch {}
    exit 0
  }
  if (-not (Test-Path -LiteralPath $ExePath)) { exit 2 }
  $value = '"' + $ExePath + '"'
  $runKey.SetValue($valueName, $value, [Microsoft.Win32.RegistryValueKind]::String)
  exit 0
} catch {
  Write-Error "HKLM autostart write failed: $_"
  exit 1
} finally {
  if ($runKey) { $runKey.Close() }
}
''';

  /// Always materialize the embedded script under
  /// `%LOCALAPPDATA%\SixVPNBlocker\tools\` so `Start-Process -Verb RunAs -File`
  /// can find it. Overwrites any previous copy.
  Future<String?> _resolveHklmScriptPath() async {
    final String la = Platform.environment['LOCALAPPDATA'] ?? '';
    if (la.isEmpty) return null;
    final String dir = p.join(la, 'SixVPNBlocker', 'tools');
    try {
      final Directory d = Directory(dir);
      if (!await d.exists()) await d.create(recursive: true);
      final File f = File(p.join(dir, 'Install-Hklm-Autostart.ps1'));
      await f.writeAsString(_kHklmWriterPs, flush: true);
      return f.path;
    } catch (e) {
      AppLogger.instance.warn('autostart_hklm: script write failed', error: e);
      return null;
    }
  }

  /// Elevate via `Start-Process -Verb RunAs` and wait for the elevated
  /// process to exit. The non-elevated outer PowerShell exits with the
  /// inner script's exit code (0 = success, non-zero = UAC denied or
  /// script failure).
  Future<ProcessResult> _runElevatedPs({
    required String script,
    required List<String> args,
  }) async {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final String ps = p.join(
      windir,
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
    // Build the inner argument list as a single PS string array literal,
    // quoting each element to survive Start-Process's join.
    final List<String> innerArgs = <String>[
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      script,
      ...args,
    ];
    final String argsArrayLit = innerArgs
        .map((String a) => "'${a.replaceAll("'", "''")}'")
        .join(',');
    // UAC cancel throws Win32Exception (HRESULT 0x800704C7 = 1223).
    // Convert to a clean non-zero exit so the Dart side can distinguish
    // "user said no" from "elevated script failed".
    final String outer =
        "try { \$p=Start-Process -FilePath powershell -Verb RunAs -Wait -PassThru "
        '-ArgumentList @($argsArrayLit); '
        "exit \$p.ExitCode } catch { exit 1223 }";
    return windowsRunHidden(ps, <String>[
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      outer,
    ]);
  }

  /// Read a REG_SZ from HKLM or HKCU.
  String? _readRegistryStringNative({
    required int hive,
    required String subKey,
    required String name,
  }) {
    final Pointer<HKEY> phk = calloc<HKEY>();
    try {
      final Pointer<Utf16> subKeyPtr = subKey.toNativeUtf16();
      final int open = RegOpenKeyEx(hive, subKeyPtr, 0, KEY_QUERY_VALUE, phk);
      calloc.free(subKeyPtr);
      if (open != ERROR_SUCCESS) return null;
      final int hKey = phk.value;
      final Pointer<Utf16> namePtr = name.toNativeUtf16();
      final Pointer<DWORD> typePtr = calloc<DWORD>();
      final Pointer<DWORD> cbPtr = calloc<DWORD>();
      int r = RegQueryValueEx(hKey, namePtr, nullptr, typePtr, nullptr, cbPtr);
      if (r != ERROR_SUCCESS || cbPtr.value == 0) {
        calloc.free(namePtr);
        calloc.free(typePtr);
        calloc.free(cbPtr);
        RegCloseKey(hKey);
        return null;
      }
      final Pointer<Uint8> buf = calloc<Uint8>(cbPtr.value + 2);
      r = RegQueryValueEx(hKey, namePtr, nullptr, typePtr, buf, cbPtr);
      String? out;
      if (r == ERROR_SUCCESS) {
        final int chars = cbPtr.value ~/ 2;
        final Uint16List view = buf.cast<Uint16>().asTypedList(chars);
        int end = view.length;
        while (end > 0 && view[end - 1] == 0) end--;
        out = String.fromCharCodes(view.sublist(0, end));
      }
      calloc.free(namePtr);
      calloc.free(typePtr);
      calloc.free(cbPtr);
      calloc.free(buf);
      RegCloseKey(hKey);
      return out;
    } catch (_) {
      return null;
    } finally {
      calloc.free(phk);
    }
  }

  // ---- Native Win32 registry helpers ----

  bool _writeRunRegistryNative(String value) {
    final Pointer<HKEY> phk = calloc<HKEY>();
    try {
      final Pointer<Utf16> subKey = _runSubKey.toNativeUtf16();
      final int open = RegCreateKeyEx(
        HKEY_CURRENT_USER,
        subKey,
        0,
        nullptr,
        REG_OPTION_NON_VOLATILE,
        KEY_SET_VALUE,
        nullptr,
        phk,
        nullptr,
      );
      calloc.free(subKey);
      if (open != ERROR_SUCCESS) {
        AppLogger.instance.warn('autostart: RegCreateKeyEx Run = $open');
        return false;
      }
      final int hKey = phk.value;
      final Pointer<Utf16> name = kRunValueName.toNativeUtf16();
      final Pointer<Utf16> data = value.toNativeUtf16();
      final int byteLen = (value.length + 1) * 2;
      final int set = RegSetValueEx(
        hKey,
        name,
        0,
        REG_SZ,
        data.cast<Uint8>(),
        byteLen,
      );
      calloc.free(name);
      calloc.free(data);
      RegCloseKey(hKey);
      if (set != ERROR_SUCCESS) {
        AppLogger.instance.warn('autostart: RegSetValueEx Run = $set');
        return false;
      }
      return true;
    } catch (e) {
      AppLogger.instance.warn(
        'autostart: native Run write exception',
        error: e,
      );
      return false;
    } finally {
      calloc.free(phk);
    }
  }

  void _deleteRunRegistryNative() {
    final Pointer<HKEY> phk = calloc<HKEY>();
    try {
      final Pointer<Utf16> subKey = _runSubKey.toNativeUtf16();
      final int open = RegOpenKeyEx(
        HKEY_CURRENT_USER,
        subKey,
        0,
        KEY_SET_VALUE,
        phk,
      );
      calloc.free(subKey);
      if (open != ERROR_SUCCESS) return;
      final Pointer<Utf16> name = kRunValueName.toNativeUtf16();
      RegDeleteValue(phk.value, name);
      calloc.free(name);
      RegCloseKey(phk.value);
    } catch (_) {
      /* best-effort */
    } finally {
      calloc.free(phk);
    }
  }

  String? _readRunRegistryValueNative() {
    final Pointer<HKEY> phk = calloc<HKEY>();
    try {
      final Pointer<Utf16> subKey = _runSubKey.toNativeUtf16();
      final int open = RegOpenKeyEx(
        HKEY_CURRENT_USER,
        subKey,
        0,
        KEY_QUERY_VALUE,
        phk,
      );
      calloc.free(subKey);
      if (open != ERROR_SUCCESS) return null;
      final int hKey = phk.value;
      final Pointer<Utf16> name = kRunValueName.toNativeUtf16();
      final Pointer<DWORD> typePtr = calloc<DWORD>();
      final Pointer<DWORD> cbPtr = calloc<DWORD>();
      // First call sizes the buffer.
      int r = RegQueryValueEx(hKey, name, nullptr, typePtr, nullptr, cbPtr);
      if (r != ERROR_SUCCESS || cbPtr.value == 0) {
        calloc.free(name);
        calloc.free(typePtr);
        calloc.free(cbPtr);
        RegCloseKey(hKey);
        return null;
      }
      final int bufBytes = cbPtr.value;
      final Pointer<Uint8> buf = calloc<Uint8>(bufBytes + 2);
      r = RegQueryValueEx(hKey, name, nullptr, typePtr, buf, cbPtr);
      String? out;
      if (r == ERROR_SUCCESS) {
        final int chars = cbPtr.value ~/ 2;
        out = buf.cast<Uint16>().asTypedList(chars).let((Uint16List u) {
          // Trim trailing NUL if present.
          int end = u.length;
          while (end > 0 && u[end - 1] == 0) end--;
          return String.fromCharCodes(u.sublist(0, end));
        });
      }
      calloc.free(name);
      calloc.free(typePtr);
      calloc.free(cbPtr);
      calloc.free(buf);
      RegCloseKey(hKey);
      return out;
    } catch (_) {
      return null;
    } finally {
      calloc.free(phk);
    }
  }

  /// Windows 11 Startup Apps UI — force-enable our Run entry (no toggle off
  /// from Task Manager > Startup unless the user explicitly disabled it
  /// after install).
  void _ensureStartupApprovedEnabledNative() {
    final Pointer<HKEY> phk = calloc<HKEY>();
    try {
      final Pointer<Utf16> subKey = _approvedRunSubKey.toNativeUtf16();
      final int open = RegCreateKeyEx(
        HKEY_CURRENT_USER,
        subKey,
        0,
        nullptr,
        REG_OPTION_NON_VOLATILE,
        KEY_SET_VALUE,
        nullptr,
        phk,
        nullptr,
      );
      calloc.free(subKey);
      if (open != ERROR_SUCCESS) return;
      final Pointer<Utf16> name = kRunValueName.toNativeUtf16();
      // 12 bytes, first byte 0x02 → "enabled". Layout documented across the
      // shell-team blog posts referenced by Sysinternals Autoruns.
      final Uint8List payload = Uint8List.fromList(<int>[
        0x02,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
        0,
      ]);
      final Pointer<Uint8> buf = calloc<Uint8>(payload.length);
      for (int i = 0; i < payload.length; i++) {
        buf[i] = payload[i];
      }
      RegSetValueEx(phk.value, name, 0, REG_BINARY, buf, payload.length);
      calloc.free(name);
      calloc.free(buf);
      RegCloseKey(phk.value);
    } catch (_) {
      /* best-effort */
    } finally {
      calloc.free(phk);
    }
  }

  // ---- schtasks fallback (Run registry primary) ----

  static String _schtasksExe() {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return p.join(windir, 'System32', 'schtasks.exe');
  }

  Future<bool> _logonTaskInstalled() async {
    try {
      final ProcessResult r = await windowsRunHidden(_schtasksExe(), <String>[
        '/Query',
        '/TN',
        kLogonTaskName,
        '/FO',
        'LIST',
      ]);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Best-effort backup when Run registry is disabled in Task Manager.
  /// Uses PowerShell's `Register-ScheduledTask` rather than `schtasks /Create`
  /// because schtasks refuses to create an ONLOGON task for the current
  /// interactive user without a password (`Access is denied`). The PS
  /// scheduler module talks to the Task Scheduler service directly and
  /// works without a password as long as the calling process is the same
  /// user.
  Future<void> _ensureLogonTask(String exe) async {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final String ps = p.join(
      windir,
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
    // Single-quote the EXE for PowerShell so backslashes are literal and the
    // path can't be interpreted as anything other than a file path.
    final String exeLit = "'${exe.replaceAll("'", "''")}'";
    final String script = <String>[
      r"$ErrorActionPreference='Stop'",
      "\$a=New-ScheduledTaskAction -Execute $exeLit",
      r'$u="$env:USERDOMAIN\$env:USERNAME"',
      r'$t=New-ScheduledTaskTrigger -AtLogOn -User $u',
      '\$t.Delay=\'PT${kLogonDelaySeconds}S\'',
      r'$s=New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -AllowStartIfOnBatteries',
      r'$p=New-ScheduledTaskPrincipal -UserId $u -LogonType Interactive -RunLevel Limited',
      "Register-ScheduledTask -TaskName '$kLogonTaskName' -Action \$a -Trigger \$t -Settings \$s -Principal \$p -Force | Out-Null",
    ].join(';');
    final ProcessResult create = await windowsRunHidden(ps, <String>[
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      script,
    ]);
    if (create.exitCode == 0) {
      AppLogger.instance.info(
        'autostart: logon task $kLogonTaskName registered',
      );
    } else {
      AppLogger.instance.warn(
        'autostart: logon task skipped exit=${create.exitCode} (Run registry is primary)',
      );
    }
  }

  Future<void> _removeLogonTask() async {
    if (!await _logonTaskInstalled()) return;
    await windowsRunHidden(_schtasksExe(), <String>[
      '/Delete',
      '/F',
      '/TN',
      kLogonTaskName,
    ]);
  }

  static const String _kBootGuardPs = r'''
param([Parameter(Mandatory = $true)] [string] $ExePath)
$ErrorActionPreference = 'SilentlyContinue'
if (Get-Process -Name FocusFense -ErrorAction SilentlyContinue) { exit 0 }
if (-not (Test-Path -LiteralPath $ExePath)) { exit 1 }
$dir = Split-Path -Parent $ExePath
Start-Process -FilePath $ExePath -WorkingDirectory $dir
exit 0
''';

  Future<String?> _writeBootGuardScript(String exe) async {
    final String la = Platform.environment['LOCALAPPDATA'] ?? '';
    if (la.isEmpty) return null;
    final String dir = p.join(la, 'SixVPNBlocker', 'tools');
    try {
      final Directory d = Directory(dir);
      if (!await d.exists()) await d.create(recursive: true);
      final File f = File(p.join(dir, 'boot_guard_launch.ps1'));
      await f.writeAsString(_kBootGuardPs, flush: true);
      final File target = File(p.join(dir, 'boot_guard_target.txt'));
      await target.writeAsString(exe, flush: true);
      return f.path;
    } catch (e) {
      AppLogger.instance.warn(
        'autostart: boot guard script write failed',
        error: e,
      );
      return null;
    }
  }

  /// Wraps the PowerShell boot-guard call in `wscript.exe`, which has no
  /// console subsystem at all. Task Scheduler launching `powershell.exe`
  /// directly — even with `-WindowStyle Hidden` — briefly flashes a black
  /// console frame before the window style takes effect; `WScript.Shell.Run`
  /// with `windowStyle=0` never allocates a console in the first place.
  Future<String?> _writeBootGuardVbs(String guardPsPath, String exe) async {
    final String la = Platform.environment['LOCALAPPDATA'] ?? '';
    if (la.isEmpty) return null;
    final String dir = p.join(la, 'SixVPNBlocker', 'tools');
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final String ps = p.join(
      windir,
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
    // A Windows command-line argument, double-quoted for the shell.
    String cmdQuote(String s) => '"${s.replaceAll('"', '\\"')}"';
    // The same string re-quoted as a single VBScript string literal.
    String vbQuote(String s) => '"${s.replaceAll('"', '""')}"';
    final String commandLine =
        '${cmdQuote(ps)} -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ${cmdQuote(guardPsPath)} -ExePath ${cmdQuote(exe)}';
    final String vbs = <String>[
      'Set objShell = CreateObject("WScript.Shell")',
      'objShell.Run ${vbQuote(commandLine)}, 0, False',
    ].join('\r\n');
    try {
      final Directory d = Directory(dir);
      if (!await d.exists()) await d.create(recursive: true);
      final File f = File(p.join(dir, 'boot_guard_launch.vbs'));
      await f.writeAsString(vbs, flush: true);
      return f.path;
    } catch (e) {
      AppLogger.instance.warn(
        'autostart: boot guard vbs write failed',
        error: e,
      );
      return null;
    }
  }

  Future<bool> _bootGuardTaskInstalled() async {
    try {
      final ProcessResult r = await windowsRunHidden(_schtasksExe(), <String>[
        '/Query',
        '/TN',
        kBootGuardTaskName,
        '/FO',
        'LIST',
      ]);
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  /// Second-chance launcher ~55s after logon if Run + delayed logon task both missed.
  ///
  /// The task action runs `wscript.exe` on a generated `.vbs` wrapper rather
  /// than `powershell.exe` directly. Task Scheduler launching a console
  /// subsystem exe — even with `-WindowStyle Hidden` — briefly flashes a
  /// black console frame at every logon; `wscript.exe` has no console
  /// subsystem at all, so `WScript.Shell.Run(cmd, 0, False)` never shows one.
  Future<void> _ensureBootGuardTask(String exe) async {
    final String? guardPs = await _writeBootGuardScript(exe);
    if (guardPs == null) return;
    final String? guardVbs = await _writeBootGuardVbs(guardPs, exe);
    if (guardVbs == null) return;
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final String ps = p.join(
      windir,
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
    final String wscript = p.join(windir, 'System32', 'wscript.exe');
    final String vbsLit = "'${guardVbs.replaceAll("'", "''")}'";
    final String script = <String>[
      r"$ErrorActionPreference='Stop'",
      '\$vbsPath=$vbsLit',
      r'$arg="//B //Nologo `"$vbsPath`""',
      "\$a=New-ScheduledTaskAction -Execute '${wscript.replaceAll("'", "''")}' -Argument \$arg",
      r'$u="$env:USERDOMAIN\$env:USERNAME"',
      r'$t=New-ScheduledTaskTrigger -AtLogOn -User $u',
      '\$t.Delay=\'PT${kBootGuardDelaySeconds}S\'',
      r'$s=New-ScheduledTaskSettingsSet -StartWhenAvailable -DontStopOnIdleEnd -AllowStartIfOnBatteries',
      r'$p=New-ScheduledTaskPrincipal -UserId $u -LogonType Interactive -RunLevel Limited',
      "Register-ScheduledTask -TaskName '$kBootGuardTaskName' -Action \$a -Trigger \$t -Settings \$s -Principal \$p -Force | Out-Null",
    ].join(';');
    final ProcessResult create = await windowsRunHidden(ps, <String>[
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-Command',
      script,
    ]);
    if (create.exitCode == 0) {
      AppLogger.instance.info(
        'autostart: boot guard task $kBootGuardTaskName registered',
      );
    } else {
      AppLogger.instance.warn(
        'autostart: boot guard task skipped exit=${create.exitCode}',
      );
    }
  }

  Future<void> _removeBootGuardTask() async {
    if (!await _bootGuardTaskInstalled()) return;
    await windowsRunHidden(_schtasksExe(), <String>[
      '/Delete',
      '/F',
      '/TN',
      kBootGuardTaskName,
    ]);
  }
}

extension _LetExt<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
