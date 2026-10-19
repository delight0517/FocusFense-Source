import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'windows_elevate_retry_helper.dart';
import 'windows_hidden_process.dart';

/// Detects and repairs ACL-locked `HKCU\SOFTWARE\Policies\*` keys.
///
/// **Why this exists.** On some machines (corporate Family Safety, leftover
/// from a previous elevated install, an enterprise lockdown tool, etc.) the
/// `HKCU\SOFTWARE\Policies\Google\Chrome` and Edge keys are owned by SYSTEM
/// and the interactive user is granted only `ReadKey`. The app's normal
/// `reg.exe add` calls then fail with `ERROR_ACCESS_DENIED` and the user
/// silently sees "정책 미적용 → 확장 제거 가능 + URLBlocklist 비어있음".
///
/// The fix is one-shot: take ownership of the locked sub-tree, grant the
/// current user `FullControl`, then return so the normal apply path can
/// proceed. After this runs once, every future watchdog tick can write
/// policies as the regular user — no further UAC needed.
final class WindowsPolicyAclUnlockService {
  WindowsPolicyAclUnlockService._();
  static final WindowsPolicyAclUnlockService instance =
      WindowsPolicyAclUnlockService._();

  static const List<String> _kPolicyRoots = <String>[
    r'SOFTWARE\Policies\Google\Chrome',
    r'SOFTWARE\Policies\Microsoft\Edge',
    r'SOFTWARE\Policies\Microsoft\EdgeBeta',
    r'SOFTWARE\Policies\Microsoft\EdgeDev',
    r'SOFTWARE\Policies\Mozilla\Firefox',
    r'SOFTWARE\Policies\Chromium',
    r'SOFTWARE\Policies\NAVER\Whale',
    r'SOFTWARE\Policies\BraveSoftware\Brave-Browser',
    r'SOFTWARE\Policies\Vivaldi',
    r'SOFTWARE\Policies\Opera Software\Opera Stable',
    r'SOFTWARE\Policies\Opera Software\Opera GX Stable',
  ];

  /// Cheap probe — writes a throwaway value to `HKCU\Policies\Google\Chrome`
  /// and immediately removes it. Returns `true` when the write succeeded
  /// (policies are writable, no ACL lock).
  ///
  /// Falls back to `false` when reg.exe returns non-zero (almost always
  /// ACCESS DENIED on a locked key) or when the key doesn't exist yet (the
  /// app's policy apply path will create it; we treat "doesn't exist" as
  /// writable since `reg add` is allowed to create it).
  Future<bool> hkcuPoliciesWritable() async {
    if (!Platform.isWindows) return true;
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final String regExe = p.join(windir, 'System32', 'reg.exe');
    const String probeKey = r'HKCU\SOFTWARE\Policies\Google\Chrome';
    const String probeName = '_SixVPNAclProbe';

    try {
      // Try to write a throwaway value.
      final ProcessResult add = await windowsRunHidden(
        regExe,
        <String>[
          'add',
          probeKey,
          '/v',
          probeName,
          '/t',
          'REG_SZ',
          '/d',
          '1',
          '/f',
        ],
      );
      if (add.exitCode != 0) {
        AppLogger.instance.warn(
          'acl_probe: HKCU policy write blocked — '
          'exit=${add.exitCode} stderr=${add.stderr}',
        );
        return false;
      }
      // Clean up the probe so it doesn't leak into real policy.
      await windowsRunHidden(
        regExe,
        <String>['delete', probeKey, '/v', probeName, '/f'],
      );
      return true;
    } catch (e) {
      AppLogger.instance.warn('acl_probe threw: $e');
      return false;
    }
  }

  /// Returns the script text that runs (elevated) to:
  ///   1. enable SeTakeOwnershipPrivilege on the admin token (NOT enabled
  ///      by default even for administrators)
  ///   2. take ownership of every `HKCU\SOFTWARE\Policies\<browser>` subtree
  ///      (the previous version skipped this and SetAccessControl threw
  ///      "Cannot write to the registry key" forever)
  ///   3. grant the real interactive user FullControl on each one
  ///   4. probe each key by writing+deleting a throwaway value, so the
  ///      log shows definitive success
  ///   5. log the result so the app can read it back
  ///
  /// Output: `%LOCALAPPDATA%\SixVPNBlocker\acl_unlock_exit.txt` (0=ok,1=fail)
  /// and a detailed per-key log at `acl_unlock.log`.
  ///
  /// ASCII-only on purpose: PowerShell 5.1 reads scripts as the system
  /// ANSI codepage by default. Box-drawing characters / em-dashes in
  /// comments get re-decoded as garbled bytes that break the parser
  /// (TerminatorExpectedAtEndOfString, etc.). Stick to ASCII.
  static String elevatedUnlockScript({required String realUserSidString}) {
    final String roots = _kPolicyRoots
        .map((String r) => "  '$r'")
        .join(',\n');
    return '''
\$ErrorActionPreference = 'Continue'
\$log = Join-Path \$env:LOCALAPPDATA 'SixVPNBlocker\\acl_unlock.log'
\$exitFile = Join-Path \$env:LOCALAPPDATA 'SixVPNBlocker\\acl_unlock_exit.txt'

try {
  \$sid = '$realUserSidString'
  \$profKey = "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\ProfileList\\\$sid"
  if (Test-Path -LiteralPath \$profKey) {
    \$profile = (Get-ItemProperty -LiteralPath \$profKey -Name ProfileImagePath -EA 0).ProfileImagePath
    if (\$profile) {
      \$elevatedLocal = Join-Path \$profile 'AppData\\Local'
      \$log = Join-Path \$elevatedLocal 'SixVPNBlocker\\acl_unlock.log'
      \$exitFile = Join-Path \$elevatedLocal 'SixVPNBlocker\\acl_unlock_exit.txt'
    }
  }
} catch {}

New-Item -ItemType Directory -Force -Path (Split-Path \$log) -EA SilentlyContinue | Out-Null
function L(\$m) {
  \$line = "\$(Get-Date -Format o) \$m"
  Add-Content -Path \$log -Value \$line
  Write-Host \$line
}

L "=== 6VPN ACL unlock v2 (P/Invoke + ownership) sid=$realUserSidString ==="

\$tokenSrc = @'
using System;
using System.Runtime.InteropServices;
public class TokenAdjuster {
    [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
    internal static extern bool AdjustTokenPrivileges(IntPtr htok, bool disall, ref TokPriv1Luid newst, int len, IntPtr prev, IntPtr relen);
    [DllImport("kernel32.dll", ExactSpelling = true)]
    internal static extern IntPtr GetCurrentProcess();
    [DllImport("advapi32.dll", ExactSpelling = true, SetLastError = true)]
    internal static extern bool OpenProcessToken(IntPtr h, int acc, ref IntPtr phtok);
    [DllImport("advapi32.dll", SetLastError = true)]
    internal static extern bool LookupPrivilegeValue(string host, string name, ref long pluid);
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    public struct TokPriv1Luid {
        public int Count;
        public long Luid;
        public int Attr;
    }
    public const int SE_PRIVILEGE_ENABLED = 0x00000002;
    public const int TOKEN_QUERY = 0x00000008;
    public const int TOKEN_ADJUST_PRIVILEGES = 0x00000020;
    public static bool AddPrivilege(string privilege) {
        IntPtr htok = IntPtr.Zero;
        if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, ref htok))
            return false;
        TokPriv1Luid tp;
        tp.Count = 1;
        tp.Luid = 0;
        tp.Attr = SE_PRIVILEGE_ENABLED;
        if (!LookupPrivilegeValue(null, privilege, ref tp.Luid))
            return false;
        return AdjustTokenPrivileges(htok, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
    }
}
'@

try {
  Add-Type -TypeDefinition \$tokenSrc -ErrorAction Stop
} catch {
  L ("Add-Type skip: " + \$_.Exception.Message)
}

\$null = [TokenAdjuster]::AddPrivilege('SeTakeOwnershipPrivilege')
\$null = [TokenAdjuster]::AddPrivilege('SeRestorePrivilege')
\$null = [TokenAdjuster]::AddPrivilege('SeBackupPrivilege')
L 'token privileges enabled'

\$realSid = '$realUserSidString'
\$administratorsSid = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
\$userSidObj = New-Object System.Security.Principal.SecurityIdentifier(\$realSid)

\$roots = @(
$roots
)

\$hkuRoot = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::Users, [Microsoft.Win32.RegistryView]::Default)

\$okCount = 0
\$failCount = 0
\$skipCount = 0

foreach (\$r in \$roots) {
  \$subPath = \$realSid + '\\' + \$r
  \$hu = 'HKEY_USERS\\' + \$subPath
  \$key = \$null
  try {
    try {
      \$key = \$hkuRoot.OpenSubKey(
        \$subPath,
        [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
        [System.Security.AccessControl.RegistryRights]::TakeOwnership
      )
    } catch {
      L ('open TakeOwnership failed: ' + \$hu + ' : ' + \$_.Exception.Message)
    }
    if (\$null -eq \$key) {
      L ('skip ' + \$hu + ' (does not exist)')
      \$skipCount = \$skipCount + 1
      continue
    }
    \$acl = \$key.GetAccessControl()
    \$acl.SetOwner(\$administratorsSid)
    \$key.SetAccessControl(\$acl)
    \$key.Close()
    L ('OWNED ' + \$hu)

    \$key = \$hkuRoot.OpenSubKey(
      \$subPath,
      [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
      [System.Security.AccessControl.RegistryRights]::ChangePermissions
    )
    \$acl = \$key.GetAccessControl()
    \$userRule = New-Object System.Security.AccessControl.RegistryAccessRule(
      \$userSidObj, 'FullControl', 'ContainerInherit', 'None', 'Allow'
    )
    \$adminRule = New-Object System.Security.AccessControl.RegistryAccessRule(
      \$administratorsSid, 'FullControl', 'ContainerInherit', 'None', 'Allow'
    )
    \$acl.SetAccessRule(\$userRule)
    \$acl.SetAccessRule(\$adminRule)
    \$key.SetAccessControl(\$acl)
    \$key.Close()
    L ('GRANTED ' + \$hu + ' : FullControl to user + Administrators')
    \$okCount = \$okCount + 1
  } catch {
    L ('FAIL ' + \$hu + ' : ' + \$_.Exception.Message)
    \$failCount = \$failCount + 1
    if (\$key) { try { \$key.Close() } catch {} }
  }
}

L '=== probes ==='
\$probeOk = 0
\$probeFail = 0
foreach (\$r in \$roots) {
  \$reg = 'Registry::HKEY_USERS\\' + \$realSid + '\\' + \$r
  if (-not (Test-Path -LiteralPath \$reg)) { continue }
  try {
    Set-ItemProperty -LiteralPath \$reg -Name '_SixVPNAclProbe' -Value 'ok' -Type String -Force -ErrorAction Stop
    Remove-ItemProperty -LiteralPath \$reg -Name '_SixVPNAclProbe' -Force -ErrorAction SilentlyContinue
    L ('PROBE OK ' + \$r)
    \$probeOk = \$probeOk + 1
  } catch {
    L ('PROBE FAIL ' + \$r + ' : ' + \$_.Exception.Message)
    \$probeFail = \$probeFail + 1
  }
}

L ('=== done ok=' + \$okCount + ' fail=' + \$failCount + ' skip=' + \$skipCount + ' probe_ok=' + \$probeOk + ' probe_fail=' + \$probeFail + ' ===')

if (\$probeOk -gt 0 -and \$probeFail -eq 0) {
  Set-Content -LiteralPath \$exitFile -Value '0' -Encoding ASCII -Force
  exit 0
} elseif (\$probeOk -gt 0) {
  Set-Content -LiteralPath \$exitFile -Value '0' -Encoding ASCII -Force
  exit 0
} else {
  Set-Content -LiteralPath \$exitFile -Value '1' -Encoding ASCII -Force
  exit 1
}
''';
  }

  bool _hasAttemptedThisRun = false;

  /// 2026-07-06: `_hasAttemptedThisRun` only guards against repeats within
  /// a single process lifetime. If the app itself restarts (watchdog
  /// relaunch, update relaunch, crash recovery) that in-memory gate resets
  /// to `false` and a still-locked ACL fires a brand new UAC "예" prompt —
  /// matching the user report of a PowerShell/UAC confirm dialog popping up
  /// repeatedly with no obvious trigger. Persist the last-attempt timestamp
  /// to disk so the elevation prompt is rate-limited across restarts too,
  /// not just within one.
  // @incident: project_hkcu_acl_lockdown — prevents repeated UAC prompts
  // across app restarts while HKCU\Policies ACL remains locked.
  static const Duration _persistentCooldown = Duration(hours: 4);

  static String _attemptTimestampPath() {
    final String localAppData = Platform.environment['LOCALAPPDATA'] ?? '';
    return p.join(localAppData, 'SixVPNBlocker', 'acl_unlock_attempt.txt');
  }

  Future<bool> _cooledDownAcrossRestarts() async {
    try {
      final File f = File(_attemptTimestampPath());
      if (!await f.exists()) return true;
      final DateTime last = DateTime.parse((await f.readAsString()).trim());
      return DateTime.now().difference(last) >= _persistentCooldown;
    } catch (_) {
      return true;
    }
  }

  Future<void> _markAttemptNow() async {
    try {
      final File f = File(_attemptTimestampPath());
      await f.parent.create(recursive: true);
      await f.writeAsString(
        DateTime.now().toIso8601String(),
        flush: true,
      );
    } catch (_) {}
  }

  /// Clears the one-attempt-per-run gate so a fresh user-initiated
  /// 「지금 모두 적용」 click always gets its own elevation attempt, even if
  /// an earlier attempt this session silently failed (AV/EDR ate the UAC
  /// prompt). Call this once at the top of a user-initiated apply run —
  /// not per-step, so a single click still only pops UAC once. This also
  /// bypasses the persistent cross-restart cooldown, since the user just
  /// explicitly asked for a retry.
  void resetAttemptGate() {
    _hasAttemptedThisRun = false;
    try {
      final File f = File(_attemptTimestampPath());
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// Resolves the **real** interactive user's SID and runs the elevated
  /// unlock script via UAC (Start-Process -Verb RunAs, falling back to VBS
  /// ShellExecute if that's silently swallowed — see
  /// [WindowsElevateRetryHelper]).
  ///
  /// One attempt per app run — if the user clicked "No" on the UAC prompt,
  /// we don't keep popping it; call [resetAttemptGate] to allow a retry.
  /// Returns true when the script reported success.
  Future<bool> runElevatedUnlockIfNeeded() async {
    if (!Platform.isWindows) return true;
    if (_hasAttemptedThisRun) return false;
    _hasAttemptedThisRun = true;

    // Skip the whole thing if policies are already writable.
    if (await hkcuPoliciesWritable()) return true;

    if (!await _cooledDownAcrossRestarts()) {
      AppLogger.instance.info(
        'acl_unlock: suppressed by persistent cross-restart cooldown '
        '(< $_persistentCooldown since last UAC attempt)',
      );
      return false;
    }
    await _markAttemptNow();

    final String? sid = await _resolveCurrentUserSid();
    if (sid == null) {
      AppLogger.instance.warn('acl_unlock: could not resolve current user SID');
      return false;
    }

    try {
      final String programData =
          Platform.environment['ProgramData'] ?? r'C:\ProgramData';
      final Directory dir =
          Directory(p.join(programData, 'SixVPNBlocker'));
      if (!await dir.exists()) await dir.create(recursive: true);
      final File script = File(p.join(dir.path, 'acl_unlock.ps1'));
      await script.writeAsString(
        elevatedUnlockScript(realUserSidString: sid),
        flush: true,
      );

      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final String ps64 = p.join(
        windir,
        'System32',
        'WindowsPowerShell',
        'v1.0',
        'powershell.exe',
      );
      final String localAppData =
          Platform.environment['LOCALAPPDATA'] ?? '';
      final File exitFile = File(
        p.join(localAppData, 'SixVPNBlocker', 'acl_unlock_exit.txt'),
      );

      final int? scriptExit = await WindowsElevateRetryHelper.runElevated(
        ps64Exe: ps64,
        scriptPath: script.path,
        exitSentinelFile: exitFile,
      );

      AppLogger.instance.info('acl_unlock UAC: sentinel exit=$scriptExit');
      if (scriptExit != 0) return false;
      // Re-probe to confirm.
      return await hkcuPoliciesWritable();
    } catch (e) {
      AppLogger.instance.warn('acl_unlock threw: $e');
      return false;
    }
  }

  Future<String?> _resolveCurrentUserSid() async {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final String whoami = p.join(windir, 'System32', 'whoami.exe');
    try {
      final ProcessResult pr = await windowsRunHidden(
        whoami,
        <String>['/user', '/fo', 'csv', '/nh'],
      );
      if (pr.exitCode != 0) return null;
      final String out = '${pr.stdout}'.trim();
      // "RESKTOP\\delig","S-1-5-21-..."
      final RegExp sidRe = RegExp(r'"(S-1-5-21-[0-9-]+)"');
      final RegExpMatch? m = sidRe.firstMatch(out);
      return m?.group(1);
    } catch (_) {
      return null;
    }
  }
}
