import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'chrome_gmail_gemini_allowlist_service.dart';
import 'windows_hidden_process.dart';

/// Reversibly removes only URLAllowlist entries that conflict with active
/// FocusFense block rules. OFF restores a removed value only while its slot is
/// still empty, so a later administrator/user edit wins.
final class WindowsUrlAllowlistOwnershipService {
  WindowsUrlAllowlistOwnershipService._();
  static final WindowsUrlAllowlistOwnershipService instance =
      WindowsUrlAllowlistOwnershipService._();

  static String get journalPath => p.join(
    Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path,
    'SixVPNBlocker',
    'owned_url_allowlist_v1.json',
  );

  static String get offMarkerPath => p.join(
    Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path,
    'SixVPNBlocker',
    'protection_disabled_v1.json',
  );

  static const List<String> policyRoots = <String>[
    r'HKCU:\SOFTWARE\Policies\Google\Chrome',
    r'HKCU:\SOFTWARE\Policies\Microsoft\Edge',
    r'HKCU:\SOFTWARE\Policies\Mozilla\Firefox',
    r'HKCU:\SOFTWARE\Policies\NAVER\Whale',
    r'HKCU:\SOFTWARE\Policies\BraveSoftware\Brave-Browser',
    r'HKCU:\SOFTWARE\Policies\Vivaldi',
    r'HKCU:\SOFTWARE\Policies\Opera Software\Opera Stable',
    r'HKCU:\SOFTWARE\Policies\Opera Software\Opera GX Stable',
    r'HKCU:\SOFTWARE\Policies\Microsoft\EdgeBeta',
    r'HKCU:\SOFTWARE\Policies\Microsoft\EdgeDev',
    r'HKCU:\SOFTWARE\Policies\Chromium',
    r'HKCU:\SOFTWARE\Policies\TheBrowserCompany\Arc',
  ];

  static String buildRemoveScript({
    required Iterable<String> blockedHosts,
    Iterable<String>? roots,
    String? journal,
    String? offMarker,
    Iterable<String>? allRootsForTesting,
  }) {
    final Set<String> hosts = blockedHosts
        .map(
          (String value) =>
              value.trim().toLowerCase().replaceFirst(RegExp(r'\.$'), ''),
        )
        .where((String value) => value.isNotEmpty && !value.contains('*'))
        .toSet();
    final List<String> selectedRoots = roots?.toList() ?? policyRoots;
    String quote(String value) => "'${value.replaceAll("'", "''")}'";
    final String encodedHosts = base64Encode(
      utf8.encode(jsonEncode(hosts.toList())),
    );
    final String encodedRoots = base64Encode(
      utf8.encode(jsonEncode(selectedRoots)),
    );
    final String encodedAllowedRoots = base64Encode(
      utf8.encode(jsonEncode(allRootsForTesting ?? policyRoots)),
    );
    final String encodedManaged = base64Encode(
      utf8.encode(
        jsonEncode(ChromeGmailGeminiAllowlistService.kManagedAllowPatterns),
      ),
    );
    return _script
        .replaceAll('__JOURNAL__', quote(journal ?? journalPath))
        .replaceAll('__OFF__', quote(offMarker ?? offMarkerPath))
        .replaceAll('__HOSTS__', encodedHosts)
        .replaceAll('__ROOTS__', encodedRoots)
        .replaceAll('__ALLROOTS__', encodedAllowedRoots)
        .replaceAll('__MANAGED__', encodedManaged)
        .replaceAll('__ACTION__', 'Remove');
  }

  static String buildRestoreScript({
    Iterable<String>? roots,
    String? journal,
    Iterable<String>? allRootsForTesting,
  }) {
    String quote(String value) => "'${value.replaceAll("'", "''")}'";
    final String encodedRoots = base64Encode(
      utf8.encode(jsonEncode(roots?.toList() ?? policyRoots)),
    );
    final String encodedAllowedRoots = base64Encode(
      utf8.encode(jsonEncode(allRootsForTesting ?? policyRoots)),
    );
    return _script
        .replaceAll('__JOURNAL__', quote(journal ?? journalPath))
        .replaceAll('__OFF__', quote(offMarkerPath))
        .replaceAll('__HOSTS__', base64Encode(utf8.encode('[]')))
        .replaceAll('__ROOTS__', encodedRoots)
        .replaceAll('__ALLROOTS__', encodedAllowedRoots)
        .replaceAll('__MANAGED__', base64Encode(utf8.encode('[]')))
        .replaceAll('__ACTION__', 'Restore');
  }

  static const String _script = r'''
$ErrorActionPreference = 'Stop'
$journal = __JOURNAL__
$offMarker = __OFF__
$hosts = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__HOSTS__')) | ConvertFrom-Json
$roots = @([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__ROOTS__')) | ConvertFrom-Json)
$allRoots = @([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__ALLROOTS__')) | ConvertFrom-Json)
$managed = @([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__MANAGED__')) | ConvertFrom-Json)
$action = '__ACTION__'
$allowedKeys = @($allRoots | ForEach-Object { Join-Path $_ 'URLAllowlist'; Join-Path $_ 'WebsiteFilter\Exceptions' })
function Open-Lock {
  [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($journal)) | Out-Null
  for ($i=0; $i -lt 40; $i++) {
    try { return [IO.File]::Open($journal+'.lock','OpenOrCreate','ReadWrite','None') }
    catch [IO.IOException] { if ($i -eq 39) { throw }; Start-Sleep -Milliseconds 50 }
  }
}
function Read-Journal {
  if (-not (Test-Path -LiteralPath $journal)) { return @() }
  $doc = Get-Content -LiteralPath $journal -Raw | ConvertFrom-Json
  if ($doc.schema -ne 1 -or $null -eq $doc.entries) { throw 'Invalid URLAllowlist ownership journal' }
  $seen = @{}
  foreach ($e in @($doc.entries)) {
    if ($allowedKeys -inotcontains $e.key -or $e.name -notmatch '^\d+$' -or
        $e.value -isnot [string] -or $e.kind -notin @('String','ExpandString')) {
      throw 'Invalid URLAllowlist ownership record'
    }
    $identity = $e.key.ToLowerInvariant()+'|'+$e.name
    if ($seen.ContainsKey($identity)) { throw 'Duplicate URLAllowlist ownership record' }
    $seen[$identity]=$true
  }
  return @($doc.entries)
}
function Save-Journal($entries) {
  $body = ConvertTo-Json -InputObject @{schema=1;entries=@($entries)} -Depth 10
  $tmp = $journal+'.tmp'
  [IO.File]::WriteAllText($tmp,$body,(New-Object Text.UTF8Encoding($false)))
  if (Test-Path -LiteralPath $journal) { [IO.File]::Replace($tmp,$journal,[NullString]::Value) }
  else { [IO.File]::Move($tmp,$journal) }
}
function Get-HostFromPattern([string]$value) {
  $v = $value.Trim().ToLowerInvariant()
  $v = $v -replace '^[a-z*]+://',''
  $v = ($v -split '[/:?@#]',2)[0]
  $v = $v -replace '^\*\.','' -replace '^\.','' -replace '^www\.',''
  if (-not $v -or $v -eq '*' -or $v.Contains('*')) { return $null }
  return $v.TrimEnd('.')
}
function Test-Conflict([string]$value) {
  $allowHost = Get-HostFromPattern $value
  if (-not $allowHost) { return $false }
  foreach ($blocked in $hosts) {
    if ($allowHost -ceq $blocked -or $allowHost.EndsWith('.'+$blocked)) { return $true }
  }
  return $false
}
$lock = Open-Lock
try {
  $entries = @(Read-Journal)
  if ($action -ceq 'Remove') {
    if (Test-Path -LiteralPath $offMarker) { throw 'Protection is OFF' }
    $removed=0
    foreach ($root in $roots) {
      if (Test-Path -LiteralPath $offMarker) { throw 'Protection is OFF' }
      $key = Join-Path $root 'URLAllowlist'
      if ($root -match '\\Mozilla\\Firefox$') { $key = Join-Path $root 'WebsiteFilter\Exceptions' }
      if (-not (Test-Path -LiteralPath $key)) { continue }
      $item = Get-Item -LiteralPath $key
      foreach ($name in @($item.GetValueNames())) {
        if ($name -notmatch '^\d+$') { continue }
        $value = [string]$item.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if (-not (Test-Conflict $value)) { continue }
        if (@($managed | Where-Object { $_ -ieq $value.Trim() }).Count -gt 0) { continue }
        $old = @($entries | Where-Object { $_.key -ieq $key -and $_.name -ceq $name })
        if ($old.Count -gt 0 -and $old[0].value -cne $value) { continue }
        if ($old.Count -eq 0) {
          $kind = $item.GetValueKind($name).ToString()
          if ($kind -notin @('String','ExpandString')) { continue }
          $entries += [pscustomobject]@{key=$key;name=$name;value=$value;kind=$kind}
        }
        Save-Journal $entries
        if (Test-Path -LiteralPath $offMarker) { throw 'Protection is OFF' }
        Remove-ItemProperty -LiteralPath $key -Name $name -ErrorAction Stop
        $removed++
      }
    }
    Write-Output ('allowlist_removed='+$removed)
  } else {
    $remaining=@()
    foreach ($entry in $entries) {
      $selected = $false
      foreach ($root in $roots) {
        if ($entry.key -ieq (Join-Path $root 'URLAllowlist') -or
            $entry.key -ieq (Join-Path $root 'WebsiteFilter\Exceptions')) {
          $selected = $true
          break
        }
      }
      if (-not $selected) { $remaining += $entry; continue }
      try {
        if (Test-Path -LiteralPath $entry.key) {
          $item=Get-Item -LiteralPath $entry.key
          if ($item.GetValueNames() -icontains $entry.name) { continue }
          New-ItemProperty -LiteralPath $entry.key -Name $entry.name -Value $entry.value -PropertyType $entry.kind -Force -ErrorAction Stop | Out-Null
        } else {
          New-Item -Path $entry.key -Force | Out-Null
          New-ItemProperty -LiteralPath $entry.key -Name $entry.name -Value $entry.value -PropertyType $entry.kind -Force -ErrorAction Stop | Out-Null
        }
      } catch { $remaining += $entry }
    }
    Save-Journal $remaining
    if ($remaining.Count -gt 0) { throw 'URLAllowlist restoration incomplete; retry records retained' }
    Write-Output 'allowlist_restored'
  }
} finally { $lock.Dispose() }
''';

  Future<int> removeConflicts(
    Iterable<String> blockedHosts, {
    Iterable<String>? roots,
  }) async {
    if (!Platform.isWindows || blockedHosts.isEmpty) return 0;
    final Directory directory = await Directory.systemTemp.createTemp(
      'ff-allowlist-',
    );
    try {
      final File script = File(p.join(directory.path, 'remove.ps1'));
      await script.writeAsString(
        buildRemoveScript(blockedHosts: blockedHosts, roots: roots),
      );
      final ProcessResult result = await windowsRunHidden(_powershell, <String>[
        '-NoProfile',
        '-NonInteractive',
        '-File',
        script.path,
      ]);
      if (result.exitCode != 0)
        throw StateError('Allowlist conflict cleanup failed.');
      final RegExpMatch? match = RegExp(
        r'allowlist_removed=(\d+)',
      ).firstMatch('${result.stdout}');
      return int.tryParse(match?.group(1) ?? '') ?? 0;
    } finally {
      await directory.delete(recursive: true);
    }
  }

  Future<void> restoreAll() async {
    if (!Platform.isWindows) return;
    final Directory directory = await Directory.systemTemp.createTemp(
      'ff-allowlist-restore-',
    );
    try {
      final File script = File(p.join(directory.path, 'restore.ps1'));
      await script.writeAsString(buildRestoreScript());
      final ProcessResult result = await windowsRunHidden(_powershell, <String>[
        '-NoProfile',
        '-NonInteractive',
        '-File',
        script.path,
      ]);
      if (result.exitCode != 0)
        throw StateError('Allowlist restoration incomplete.');
    } finally {
      await directory.delete(recursive: true);
    }
  }

  static String get _powershell => p.join(
    Platform.environment['WINDIR'] ?? r'C:\Windows',
    'System32',
    'WindowsPowerShell',
    'v1.0',
    'powershell.exe',
  );
}
