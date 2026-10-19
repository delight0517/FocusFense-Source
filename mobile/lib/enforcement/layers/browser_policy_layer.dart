import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart' as p;

import '../../services/chrome_core_principles_service.dart';
import '../enforcement_layer.dart';

/// L2 — 브라우저 정책 계층.
class BrowserPolicyLayer implements EnforcementLayer {
  BrowserPolicyLayer._();
  static final BrowserPolicyLayer instance = BrowserPolicyLayer._();

  static String get ownedListsJournalPath => p.join(
    Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path,
    'SixVPNBlocker',
    'owned_browser_lists_v1.json',
  );

  static String get ownedPacJournalPath => p.join(
    Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path,
    'SixVPNBlocker',
    'owned_pac_values_v1.json',
  );

  /// PAC scalar ownership shares one lock across apply/OFF. Record typed
  /// baselines before mutation; preserve later edits and retry failed restores.
  static String ownedPacPowerShell({
    required String journalPath,
    required String offMarkerPath,
    required List<Map<String, Object>> values,
  }) {
    String quote(String value) => "'${value.replaceAll("'", "''")}'";
    final specs = base64Encode(utf8.encode(jsonEncode(values)));
    return r'''
$ErrorActionPreference = 'Stop'
$ffPacJournal = __JOURNAL__
$ffPacOff = __OFF__
$ffPacSpecs = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__SPECS__')) | ConvertFrom-Json
function Resolve-FFPacKey([string]$key) {
  if ($key -like 'HKCU:\*') {
    return 'Registry::HKEY_USERS\' + [Security.Principal.WindowsIdentity]::GetCurrent().User.Value + '\' + $key.Substring(6)
  }
  return $key
}
foreach ($spec in $ffPacSpecs) { $spec.key = Resolve-FFPacKey $spec.key }
function Open-FFPacLock {
  [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($ffPacJournal)) | Out-Null
  for ($attempt=0; $attempt -lt 40; $attempt++) {
    try { return [IO.File]::Open($ffPacJournal+'.lock', 'OpenOrCreate', 'ReadWrite', 'None') }
    catch [IO.IOException] { if ($attempt -eq 39) { throw }; Start-Sleep -Milliseconds 50 }
  }
}
function Save-FFPac($records) {
  $text = ConvertTo-Json -InputObject @{schema=1;entries=@($records)} -Depth 20
  [IO.File]::WriteAllText($ffPacJournal+'.tmp', $text, (New-Object Text.UTF8Encoding($false)))
  # Atomic replacement keeps the old intent journal valid if the process stops.
  if (Test-Path -LiteralPath $ffPacJournal) {
    [IO.File]::Replace($ffPacJournal+'.tmp', $ffPacJournal, [NullString]::Value)
  } else {
    [IO.File]::Move($ffPacJournal+'.tmp', $ffPacJournal)
  }
}
function Read-FFPac {
  if (-not (Test-Path -LiteralPath $ffPacJournal)) { return @() }
  $doc = Get-Content -LiteralPath $ffPacJournal -Raw | ConvertFrom-Json
  if ($doc.schema -ne 1 -or $null -eq $doc.entries) { throw 'Invalid PAC ownership journal' }
  $seen = @{}
  foreach ($entry in @($doc.entries)) {
    $allowed = @($ffPacSpecs | Where-Object { $_.key -ieq $entry.key -and $_.name -ceq $entry.name })
    if ($allowed.Count -ne 1 -or $entry.after.kind -cne $allowed[0].kind -or
        $entry.before.exists -isnot [bool] -or $entry.after.exists -cne $true) { throw 'Invalid PAC ownership target' }
    foreach ($state in @($entry.before,$entry.after,$entry.pendingPrevious)) {
      if ($null -eq $state) { continue }
      if ($state.exists -isnot [bool]) { throw 'Invalid PAC value state' }
      if ($state.exists -and $state.kind -notin @('String','ExpandString','DWord','QWord')) { throw 'Unsupported PAC value kind' }
      if ($state.exists -and $null -eq $state.value) { throw 'Missing PAC value' }
      if ($state.exists -and $state.kind -ceq 'DWord') { $null = [int]$state.value }
      if ($state.exists -and $state.kind -ceq 'QWord') { $null = [long]$state.value }
    }
    $identity = $entry.key.ToLowerInvariant()+'|'+$entry.name
    if ($seen.ContainsKey($identity)) { throw 'Duplicate PAC ownership entry' }
    $seen[$identity] = $true
  }
  return @($doc.entries)
}
function Get-FFPacState([string]$key,[string]$name) {
  if (-not (Test-Path -LiteralPath $key)) { return @{exists=$false} }
  $item = Get-Item -LiteralPath $key
  if ($item.GetValueNames() -inotcontains $name) { return @{exists=$false} }
  $kind = $item.GetValueKind($name).ToString()
  $value = $item.GetValue($name,$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
  # Store numerics as strings so JSON cannot round a 64-bit registry baseline.
  return @{exists=$true;kind=$kind;value=[string]$value}
}
function Test-FFPacEqual($left,$right) {
  return ($null -ne $right -and $left.exists -and $right.exists -and
    $left.kind -ceq $right.kind -and [string]$left.value -ceq [string]$right.value)
}
function Write-FFPacState([string]$key,[string]$name,$state) {
  if (-not $state.exists) {
    if (Test-Path -LiteralPath $key) { Remove-ItemProperty -LiteralPath $key -Name $name -ErrorAction Stop }
    return
  }
  if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
  $value = $state.value
  if ($state.kind -ceq 'DWord') { $value = [int]$value }
  if ($state.kind -ceq 'QWord') { $value = [long]$value }
  Set-ItemProperty -LiteralPath $key -Name $name -Value $value -Type $state.kind -ErrorAction Stop
}
function Invoke-FFPacApply {
  $lock = Open-FFPacLock
  try {
    $records = @(Read-FFPac)
    foreach ($spec in $ffPacSpecs) {
      if ($spec.PSObject.Properties['disabledMarkerPath'] -and
          (Test-Path -LiteralPath $spec.disabledMarkerPath)) {
        Restore-FFPac -selectedKeys @($spec.key) -LockHeld
        $records = @(Read-FFPac)
        continue
      }
      if ($spec.PSObject.Properties['enabled'] -and $spec.enabled -eq $false) { continue }
      if (Test-Path -LiteralPath $ffPacOff) { return $false }
      $current = Get-FFPacState $spec.key $spec.name
      if ($current.exists -and $current.kind -notin @('String','ExpandString','DWord','QWord')) { throw 'Unsupported original PAC value kind' }
      $old = @($records | Where-Object { $_.key -ieq $spec.key -and $_.name -ceq $spec.name })
      $before = $current
      $previous = $null
      if ($old.Count -eq 1 -and ((Test-FFPacEqual $current $old[0].after) -or
          (Test-FFPacEqual $current $old[0].pendingPrevious))) {
        $before = $old[0].before; $previous = $current
      }
      $entry = [pscustomobject]@{key=$spec.key;name=$spec.name;before=$before;
        after=@{exists=$true;kind=$spec.kind;value=[string]$spec.value};pendingPrevious=$previous}
      $records = @($records | Where-Object { $_.key -ine $spec.key -or $_.name -cne $spec.name }) + @($entry)
      # Intent plus prior owned value makes interruption before/after write reversible.
      Save-FFPac $records
      if (Test-Path -LiteralPath $ffPacOff) { return $false }
      if ($spec.PSObject.Properties['disabledMarkerPath'] -and
          (Test-Path -LiteralPath $spec.disabledMarkerPath)) {
        Restore-FFPac -selectedKeys @($spec.key) -LockHeld
        $records = @(Read-FFPac)
        continue
      }
      Write-FFPacState $spec.key $spec.name $entry.after
      $entry.pendingPrevious = $null
      Save-FFPac $records
      if ($spec.PSObject.Properties['disabledMarkerPath'] -and
          (Test-Path -LiteralPath $spec.disabledMarkerPath)) {
        Restore-FFPac -selectedKeys @($spec.key) -LockHeld
        $records = @(Read-FFPac)
      }
    }
    return -not (Test-Path -LiteralPath $ffPacOff)
  } finally { $lock.Dispose() }
}
function Restore-FFPac([string[]]$selectedKeys,[switch]$LockHeld) {
  $restoreLock = $null
  if (-not $LockHeld) { $restoreLock = Open-FFPacLock }
  try {
    $selectedKeys = @($selectedKeys | ForEach-Object { Resolve-FFPacKey $_ })
    $records = @(Read-FFPac); $remaining = @(); $failures = 0
    foreach ($entry in $records) {
      if ($selectedKeys -inotcontains $entry.key) { $remaining += $entry; continue }
      try {
        $current = Get-FFPacState $entry.key $entry.name
        if ((Test-FFPacEqual $current $entry.after) -or (Test-FFPacEqual $current $entry.pendingPrevious)) {
          Write-FFPacState $entry.key $entry.name $entry.before
        }
      } catch { $remaining += $entry; $failures++ }
    }
    Save-FFPac $remaining
    if ($failures -gt 0) { throw 'PAC baseline restoration incomplete; retained retry records' }
  } finally { if ($null -ne $restoreLock) { $restoreLock.Dispose() } }
}
'''
        .replaceAll('__JOURNAL__', quote(journalPath))
        .replaceAll('__OFF__', quote(offMarkerPath))
        .replaceAll('__SPECS__', specs);
  }

  /// List ownership is recorded before mutation. Never overwrite a preexisting
  /// policy entry, and remove a recorded value only while it still matches.
  /// The lock serializes apply/OFF writers; failures leave retryable entries.
  static String ownedListsPowerShell({
    String? journalPath,
    List<String>? policyRoots,
    String? stateDirectoryForTesting,
  }) =>
      r'''
$ffOwnedListsPath = '__JOURNAL__'
$ffOwnedPolicyRoots = @(__ROOTS__)
$ffOwnedStateDirectory = '__STATE__'
function Read-FFOwnedLists {
  if (-not (Test-Path -LiteralPath $ffOwnedListsPath)) { return @() }
  $document = Get-Content -LiteralPath $ffOwnedListsPath -Raw | ConvertFrom-Json
  if ($document.schema -ne 1 -or $null -eq $document.entries) { throw 'Invalid FocusFense policy ownership journal' }
  return @($document.entries)
}
function Write-FFOwnedLists($entries) {
  $body = ConvertTo-Json -InputObject @{schema=1; entries=@($entries)} -Depth 20
  $temporary = $ffOwnedListsPath + '.tmp'
  [IO.File]::WriteAllText($temporary, $body, (New-Object Text.UTF8Encoding($false)))
  Move-Item -LiteralPath $temporary -Destination $ffOwnedListsPath -Force
}
function Open-FFOwnedListsLock {
  [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($ffOwnedListsPath)) | Out-Null
  for ($attempt=0; $attempt -lt 40; $attempt++) {
    try { return [IO.File]::Open($ffOwnedListsPath + '.lock', 'OpenOrCreate', 'ReadWrite', 'None') }
    catch [IO.IOException] { if ($attempt -eq 39) { throw }; Start-Sleep -Milliseconds 50 }
  }
}
function Assert-FFOwnedListEntry($entry) {
  $validKey = $false
  $validationKey = $entry.key -replace '^Registry::HKEY_USERS\\S-1-5-\d+(?:-\d+)+\\', 'HKCU:\'
  foreach ($root in $ffOwnedPolicyRoots) {
    if ($validationKey -ieq (Join-Path $root 'URLBlocklist') -or
        $validationKey -ieq (Join-Path $root 'WebsiteFilter\Block')) { $validKey = $true; break }
  }
  if ($entry.name -notmatch '^\d+$' -or
      -not $validKey -or
      $entry.value -isnot [string]) { throw 'Invalid FocusFense list ownership entry' }
}
function Set-FFOwnedList([string]$key, $patterns, [string[]]$offMarkers = @()) {
  # HKCU must not change meaning when OFF later runs under a different admin.
  if ($key -like 'HKCU:\*') {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $key = 'Registry::HKEY_USERS\' + $sid + '\' + $key.Substring(6)
  }
  $lock = Open-FFOwnedListsLock
  try {
    # Resolve requested state in the native writer, including already-running
    # batches. Never rely only on the Dart-side state captured before launch.
    if ($key -match '\\SOFTWARE\\Policies\\') {
      $offMarkers += Join-Path $ffOwnedStateDirectory 'protection_disabled_v1.json'
      $browser = if ($key -match '\\Google\\Chrome\\') { 'chrome' }
        elseif ($key -match '\\Microsoft\\Edge(?:Beta|Dev)?\\') { 'edge' }
        elseif ($key -match '\\Mozilla\\Firefox\\') { 'firefox' }
        elseif ($key -match '\\Chromium\\') { 'aside' } else { $null }
      if ($browser) { $offMarkers += Join-Path $ffOwnedStateDirectory ('extension_disabled_'+$browser+'_v1.json') }
    }
    $policyRoot = $key.Substring(0, $key.LastIndexOf('\'))
    if ($policyRoot.EndsWith('\WebsiteFilter')) { $policyRoot = $policyRoot.Substring(0, $policyRoot.LastIndexOf('\')) }
    function Assert-FFListStillEnabled {
      foreach ($marker in $offMarkers) {
        if (Test-Path -LiteralPath $marker) {
          Restore-FFOwnedLists -onlyRoots @($policyRoot) -LockHeld
          throw 'Browser list apply stopped by OFF; owned entries restored'
        }
      }
    }
    Assert-FFListStillEnabled
    $records = @(Read-FFOwnedLists)
    foreach ($entry in $records) { Assert-FFOwnedListEntry $entry }
    Assert-FFOwnedListEntry ([pscustomobject]@{key=$key; name='1'; value=''})
    if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
    $values = @{}
    foreach ($property in (Get-ItemProperty -LiteralPath $key).PSObject.Properties) {
      if ($property.Name -match '^\d+$') { $values[$property.Name] = $property.Value }
    }
    $previous = @($records | Where-Object { $_.key -ieq $key })
    $remove = @()
    foreach ($entry in $previous) {
      if ($values.ContainsKey($entry.name) -and
          (Get-Item -LiteralPath $key).GetValueKind($entry.name).ToString() -eq 'String' -and
          $values[$entry.name] -ceq $entry.value) {
        $remove += $entry
        $values.Remove($entry.name)
      }
    }
    $added = @()
    foreach ($pattern in @($patterns | Where-Object { $_ -is [string] -and $_.Length -gt 0 })) {
      if (@($values.Values | Where-Object { $_ -ceq $pattern }).Count -gt 0) { continue }
      $slot = 1
      while ($values.ContainsKey([string]$slot)) { $slot++ }
      if ($slot -gt 1000) { throw 'Browser list policy limit exceeded; preserving existing entries' }
      $entry = [pscustomobject]@{key=$key; name=[string]$slot; value=[string]$pattern}
      $added += $entry
      $values[$entry.name] = $entry.value
    }
    $unrelated = @($records | Where-Object { $_.key -ine $key })
    # Retain both versions until mutation completes: interruption remains reversible.
    Write-FFOwnedLists @($unrelated + $previous + $added)
    Assert-FFListStillEnabled
    foreach ($entry in $remove) { Remove-ItemProperty -LiteralPath $key -Name $entry.name -ErrorAction Stop }
    foreach ($entry in $added) {
      Assert-FFListStillEnabled
      Set-ItemProperty -LiteralPath $key -Name $entry.name -Value $entry.value -Type String -ErrorAction Stop
      Assert-FFListStillEnabled
    }
    Write-FFOwnedLists @($unrelated + $added)
    Assert-FFListStillEnabled
  } finally { $lock.Dispose() }
}
function Restore-FFOwnedLists($onlyRoots = $null, [switch]$LockHeld) {
  $lock = $null
  if (-not $LockHeld) { $lock = Open-FFOwnedListsLock }
  try {
    $records = @(Read-FFOwnedLists)
    foreach ($entry in $records) { Assert-FFOwnedListEntry $entry }
    $remaining = @()
    $failed = 0
    foreach ($entry in $records) {
      if ($null -ne $onlyRoots) {
        $selected = $false
        $normalizedKey = $entry.key -replace '^Registry::HKEY_USERS\\S-1-5-\d+(?:-\d+)+\\', 'HKCU:\'
        foreach ($selectedRoot in @($onlyRoots)) {
          $normalizedRoot = $selectedRoot -replace '^Registry::HKEY_USERS\\S-1-5-\d+(?:-\d+)+\\', 'HKCU:\'
          if ($normalizedKey -ieq (Join-Path $normalizedRoot 'URLBlocklist') -or
              $normalizedKey -ieq (Join-Path $normalizedRoot 'WebsiteFilter\Block')) { $selected = $true; break }
        }
        # Single-browser OFF must retain ownership and policies for other browsers.
        if (-not $selected) { $remaining += $entry; continue }
      }
      try {
        if (-not (Test-Path -LiteralPath $entry.key)) { continue }
        $properties = Get-ItemProperty -LiteralPath $entry.key
        $current = $properties.PSObject.Properties[$entry.name]
        # @incident: full-off-policy-ownership — preserve a later admin/user edit.
        if ($null -ne $current -and
            (Get-Item -LiteralPath $entry.key).GetValueKind($entry.name).ToString() -eq 'String' -and
            $current.Value -ceq $entry.value) {
          Remove-ItemProperty -LiteralPath $entry.key -Name $entry.name -ErrorAction Stop
        }
      } catch { $remaining += $entry; $failed++ }
    }
    Write-FFOwnedLists $remaining
    if ($failed -gt 0) { throw 'Some owned browser list policies could not be removed; retry with administrator access' }
  } finally { if ($null -ne $lock) { $lock.Dispose() } }
}
'''
          .replaceAll(
            '__STATE__',
            (stateDirectoryForTesting ??
                    p.join(
                      Platform.environment['LOCALAPPDATA'] ??
                          Directory.systemTemp.path,
                      'SixVPNBlocker',
                    ))
                .replaceAll("'", "''"),
          )
          .replaceAll(
            '__JOURNAL__',
            (journalPath ?? ownedListsJournalPath).replaceAll("'", "''"),
          )
          .replaceAll(
            '__ROOTS__',
            (policyRoots ??
                    <String>[
                      for (final hive in <String>['HKCU', 'HKLM'])
                        for (final root in <String>[
                          r'Google\Chrome',
                          r'Microsoft\Edge',
                          r'Microsoft\EdgeBeta',
                          r'Microsoft\EdgeDev',
                          r'Chromium',
                          r'Mozilla\Firefox',
                          r'NAVER\Whale',
                          r'BraveSoftware\Brave-Browser',
                          r'Vivaldi',
                          r'TheBrowserCompany\Arc',
                          r'Opera Software\Opera Stable',
                          r'Opera Software\Opera GX',
                          r'Opera Software\Opera GX Stable',
                        ])
                          '$hive:\\SOFTWARE\\Policies\\$root',
                    ])
                .map((root) => "'${root.replaceAll("'", "''")}'")
                .join(','),
          );

  @override
  String get id => 'policy';

  @override
  int get order => 20;

  @override
  String get displayName => '브라우저 정책';

  @override
  Future<LayerApplyResult> apply(
    RuleSet rules, {
    required String reason,
  }) async {
    try {
      if (Platform.isWindows) {
        await ChromeCorePrinciplesService.instance.applyNow(reason: reason);
      }
      return LayerApplyResult.success();
    } catch (e) {
      return LayerApplyResult.failure('L2: $e');
    }
  }

  @override
  Future<LayerHealth> verify() async => LayerHealth.healthy();

  @override
  Future<LayerHealResult> heal(LayerHealth diagnosis) async =>
      LayerHealResult.success();
}
