import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/chromium_derivative_browsers.dart';
import '../enforcement/layers/browser_policy_layer.dart';

import 'chrome_extension_identity.dart';
import 'firefox_config_service.dart';
import 'chrome_extension_state_probe.dart';
import 'extension_guard_prefs.dart';
import 'chrome_extension_payload_service.dart';
import 'chrome_load_extension_launcher.dart';
import 'firefox_xpi_packager.dart';
import 'windows_chrome_extension_install_service.dart';
import 'windows_elevate_retry_helper.dart';
import 'windows_firefox_extension_install_service.dart';
import 'windows_hidden_process.dart';
import 'windows_browser_bypass_closer_service.dart';

/// Firefox gecko id from `assets/browser_extensions/firefox/manifest.json`.
///
/// Was `sixvpn-blocker@local` — that exact GUID was already registered by a
/// different AMO account (AMO API returned 403 "You do not have permission"
/// for both GET and version-submit on that id, which for AMO means "exists,
/// but you don't own it" — a 404 would mean truly unclaimed). `@local` is a
/// generic suffix, easy to collide with. Renamed to a distinctive,
/// domain-qualified id before the first AMO submission.
const String kFirefoxExtensionId = 'sixvpn-blocker@sixvpnblocker.app';

/// UAC: register Chrome/Edge extension + enterprise policy (harder to remove).
final class WindowsExtensionGuardService {
  WindowsExtensionGuardService._();
  static final WindowsExtensionGuardService instance =
      WindowsExtensionGuardService._();

  static String get kExtensionVersion =>
      WindowsChromeExtensionInstallService.kExtensionVersionFallback;

  /// `file:///C:/Users/.../SixVPN_Extensions/` for Firefox InstallSources.
  static String fileUrlForFolder(String folderPath) {
    final String norm = p.normalize(folderPath).replaceAll(r'\', '/');
    if (norm.length >= 2 && norm[1] == ':') {
      return 'file:///$norm';
    }
    return 'file:///$norm';
  }

  static String buildFirefoxGuardPolicyJson({
    required String installSourcesParent,
    required String xpiInstallUrl,
  }) => WindowsFirefoxExtensionInstallService.buildPoliciesJson(
    xpiInstallUrl: xpiInstallUrl,
    installSourcesParent: installSourcesParent,
  );

  /// JSON for `HKLM\...\Policies\Mozilla\Firefox` → ExtensionSettings (REG_SZ).
  static String buildFirefoxRegistryExtensionSettingsJson({
    required String xpiInstallUrl,
  }) {
    return jsonEncode(<String, Object?>{
      kFirefoxExtensionId: <String, String>{
        'installation_mode': 'force_installed',
        'install_url': xpiInstallUrl,
        'blocked_install_message':
            '6 VPN Blocker protection is locked by policy.',
      },
    });
  }

  static const String kProgramDataSubdir = r'SixVPNBlocker\chrome_blocker';

  static const Map<String, String> managedBrowserPolicyRoots = <String, String>{
    'chrome': r'SOFTWARE\Policies\Google\Chrome',
    'edge': r'SOFTWARE\Policies\Microsoft\Edge',
    'firefox': r'SOFTWARE\Policies\Mozilla\Firefox',
    'aside': r'SOFTWARE\Policies\Chromium',
  };

  /// Changes only our extension entry; browser URL rules and other add-ons stay.
  static String disableBrowserExtensionScript({
    required String browserId,
    required String resultPath,
    List<String>? registryRoots,
    List<String> firefoxPolicyFiles = const <String>[],
  }) {
    final String? policyRoot = managedBrowserPolicyRoots[browserId];
    if (policyRoot == null) throw ArgumentError.value(browserId, 'browserId');
    final String id = browserId == 'firefox'
        ? kFirefoxExtensionId
        : ChromeExtensionIdentity.extensionId;
    String quoted(String value) => "'${value.replaceAll("'", "''")}'";
    final List<String> roots =
        registryRoots ?? <String>['HKLM:\\$policyRoot', 'HKCU:\\$policyRoot'];
    return r'''
$ErrorActionPreference = 'Stop'
$id = __ID__
$mode = __MODE__
$isFirefox = __FIREFOX__
$xpiName = __XPI__
$result = __RESULT__
function Remove-OwnValues([string]$key, [bool]$matchXpi) {
  if (-not (Test-Path -LiteralPath $key)) { return }
  $values = Get-ItemProperty -LiteralPath $key
  foreach ($property in @($values.PSObject.Properties)) {
    if ($property.Name -notmatch '^\d+$') { continue }
    $value = [string]$property.Value
    if ($value -eq $id -or $value.StartsWith($id + ';') -or
        ($matchXpi -and ($value -like ('*' + $xpiName) -or $value -like '*sixvpn_blocker_signed.xpi'))) {
      Remove-ItemProperty -LiteralPath $key -Name $property.Name
    }
  }
}
try {
  foreach ($id in @(__OWNED_IDS__)) {
  foreach ($root in @(__ROOTS__)) {
    if (-not (Test-Path -LiteralPath $root)) { New-Item -Path $root -Force | Out-Null }
    $raw = (Get-ItemProperty -LiteralPath $root -Name ExtensionSettings -ErrorAction SilentlyContinue).ExtensionSettings
    $settings = if ($raw) { ConvertFrom-Json -InputObject ($raw -join '') } else { New-Object PSObject }
    $settings | Add-Member -MemberType NoteProperty -Name $id -Value @{installation_mode=$mode} -Force
    $nested = Join-Path $root ('ExtensionSettings\' + $id)
    if (Test-Path -LiteralPath $nested) { Remove-Item -LiteralPath $nested -Recurse -Force }
    $json = ConvertTo-Json -InputObject $settings -Depth 50 -Compress
    if ($isFirefox) {
      Set-ItemProperty -LiteralPath $root -Name ExtensionSettings -Value @($json) -Type MultiString
      Remove-OwnValues (Join-Path $root 'Extensions\Install') $true
      Remove-OwnValues (Join-Path $root 'Extensions\Locked') $false
    } else {
      Set-ItemProperty -LiteralPath $root -Name ExtensionSettings -Value $json -Type String
      Remove-OwnValues (Join-Path $root 'ExtensionInstallForcelist') $false
    }
  }
  foreach ($file in @(__POLICY_FILES__)) {
    if (-not (Test-Path -LiteralPath $file)) { continue }
    $document = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json
    if (-not $document.policies) { $document | Add-Member -Name policies -MemberType NoteProperty -Value (New-Object PSObject) }
    $policies = $document.policies
    if (-not $policies.ExtensionSettings) { $policies | Add-Member -Name ExtensionSettings -MemberType NoteProperty -Value (New-Object PSObject) }
    $policies.ExtensionSettings | Add-Member -Name $id -MemberType NoteProperty -Value @{installation_mode='blocked'} -Force
    if ($policies.Extensions) {
      foreach ($name in @('Install','Locked')) {
        if ($null -ne $policies.Extensions.$name) {
          $remaining = @($policies.Extensions.$name | Where-Object {
            $_ -ne $id -and $_ -notlike ('*' + $xpiName) -and $_ -notlike '*sixvpn_blocker_signed.xpi'
          })
          $policies.Extensions | Add-Member -Name $name -MemberType NoteProperty -Value $remaining -Force
        }
      }
    }
    $document | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $file -Encoding UTF8
  }
  }
  Set-Content -LiteralPath $result -Value '0' -Encoding ASCII
  exit 0
} catch {
  Set-Content -LiteralPath ($result + '.error') -Value $_.Exception.Message -Encoding UTF8
  Set-Content -LiteralPath $result -Value '1' -Encoding ASCII
  exit 1
}
'''
        .replaceAll('__ID__', quoted(id))
        .replaceAll(
          '__OWNED_IDS__',
          <String>[
            id,
            if (browserId != 'firefox')
              ChromeExtensionIdentity.legacyExtensionId,
          ].map(quoted).join(','),
        )
        .replaceAll(
          '__MODE__',
          quoted(browserId == 'firefox' ? 'blocked' : 'removed'),
        )
        .replaceAll(
          '__FIREFOX__',
          browserId == 'firefox' ? r'$true' : r'$false',
        )
        .replaceAll('__XPI__', quoted(FirefoxXpiPackager.kXpiFileName))
        .replaceAll('__RESULT__', quoted(resultPath))
        .replaceAll('__ROOTS__', roots.map(quoted).join(','))
        .replaceAll(
          '__POLICY_FILES__',
          firefoxPolicyFiles.map(quoted).join(','),
        );
  }

  /// One elevation for the full OFF action; each browser is attempted even if
  /// another browser's policy is inaccessible. Per-browser sentinels preserve
  /// partial failures instead of reporting a preference change as success.
  static String disableBrowserExtensionsScript({
    required List<String> browserIds,
    required String resultPath,
    Map<String, List<String>>? registryRoots,
    List<String> firefoxPolicyFiles = const <String>[],
    String? ownedListsJournalPath,
    List<String>? ownedPolicyRootsForTesting,
    String? ownedHardeningJournalPath,
    List<Map<String, Object>>? hardeningValuesForTesting,
  }) {
    String quote(String value) => "'${value.replaceAll("'", "''")}'";
    final StringBuffer script = StringBuffer();
    script.writeln(r'$failedBrowsers = @()');
    for (final String browser in browserIds) {
      final String childResult = '$resultPath.$browser';
      final String child = disableBrowserExtensionScript(
        browserId: browser,
        resultPath: childResult,
        registryRoots: registryRoots?[browser],
        firefoxPolicyFiles: browser == 'firefox'
            ? firefoxPolicyFiles
            : const <String>[],
      ).replaceAll('exit 0', 'return').replaceAll('exit 1', 'return');
      script.writeln(
        'Remove-Item -LiteralPath ${quote(childResult)} -Force -ErrorAction SilentlyContinue',
      );
      script.writeln('& {\n$child\n}');
      script.writeln('''
if (-not (Test-Path -LiteralPath ${quote(childResult)}) -or
    (Get-Content -LiteralPath ${quote(childResult)} -Raw).Trim() -ne '0') {
  \$failedBrowsers += ${quote(browser)}
}
''');
    }
    if (ownedListsJournalPath != null || ownedHardeningJournalPath != null) {
      if (ownedListsJournalPath != null) {
        script.writeln(
          BrowserPolicyLayer.ownedListsPowerShell(
            journalPath: ownedListsJournalPath,
            policyRoots: ownedPolicyRootsForTesting,
          ),
        );
      }
      final allBrowsers = ExtensionGuardPrefs.managedBrowserIds.every(
        browserIds.contains,
      );
      final selectedRoots = <String>[
        for (final browser in browserIds)
          ...(registryRoots?[browser] ??
              <String>[
                'HKLM:\\${managedBrowserPolicyRoots[browser]}',
                'HKCU:\\${managedBrowserPolicyRoots[browser]}',
              ]),
      ];
      if (browserIds.contains('edge')) {
        selectedRoots.addAll([
          for (final root in List<String>.of(selectedRoots))
            if (root.endsWith(r'\Microsoft\Edge')) ...[
              for (final suffix in ['Beta', 'Dev']) '$root$suffix',
            ],
        ]);
      }
      final restore = allBrowsers
          ? 'Restore-FFOwnedLists'
          : 'Restore-FFOwnedLists -onlyRoots @(${selectedRoots.map(quote).join(',')})';
      if (ownedListsJournalPath != null)
        script.writeln(
          'try { $restore } catch { \$failedBrowsers += \'owned_site_policies\' }',
        );
      if (ownedHardeningJournalPath != null) {
        final hardening =
            WindowsBrowserBypassCloserService.buildOwnedHardeningRestoreScript(
              journalPath: ownedHardeningJournalPath,
              selectedRoots: allBrowsers ? null : selectedRoots,
              valuesForTesting: hardeningValuesForTesting,
            );
        script.writeln(
          '& { try {\n$hardening\n} catch { \$script:failedBrowsers += \'owned_browser_hardening\' } }',
        );
      }
    }
    script.writeln('''
if (\$failedBrowsers.Count -gt 0) {
  Set-Content -LiteralPath ${quote('$resultPath.error')} -Value (\$failedBrowsers -join ',') -Encoding UTF8
  Set-Content -LiteralPath ${quote(resultPath)} -Value '1' -Encoding ASCII
  exit 1
}
Set-Content -LiteralPath ${quote(resultPath)} -Value '0' -Encoding ASCII
exit 0
''');
    return script.toString();
  }

  Future<ExtensionGuardResult> disableBrowserExtension(String browserId) =>
      _disableBrowserExtensions(<String>[browserId]);

  Future<ExtensionGuardResult> disableAllBrowserExtensions() =>
      _disableBrowserExtensions(ExtensionGuardPrefs.managedBrowserIds);

  Future<ExtensionGuardResult> _disableBrowserExtensions(
    List<String> browserIds,
  ) async {
    if (!Platform.isWindows) {
      return const ExtensionGuardResult(ok: false, message: 'Windows 전용');
    }
    for (final String browserId in browserIds) {
      if (!managedBrowserPolicyRoots.containsKey(browserId)) {
        throw ArgumentError.value(browserId, 'browserId');
      }
    }
    // Persist intent before UAC: a cancelled policy write must not allow the
    // background installer to undo the user's request to stop this extension.
    for (final String browserId in browserIds) {
      await ExtensionGuardPrefs.instance.setBrowserEnabled(browserId, false);
    }
    bool profilesCleaned = true;
    if (browserIds.contains('firefox')) {
      try {
        await FirefoxConfigService.instance
            .removeManagedNetworkPrefsInAllProfiles();
      } catch (_) {
        // A malformed/read-only profile must not prevent the policy OFF attempt.
        profilesCleaned = false;
      }
    }
    final String selection = browserIds.join('_');
    final Directory state = Directory(
      p.join(
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path,
        'SixVPNBlocker',
      ),
    );
    await state.create(recursive: true);
    final File script = File(
      p.join(state.path, 'extension_disable_$selection.ps1'),
    );
    final File result = File(
      p.join(state.path, 'extension_disable_$selection.exit'),
    );
    final ProcessResult identity = await windowsRunHidden(
      p.join(
        Platform.environment['WINDIR'] ?? r'C:\Windows',
        'System32',
        'whoami.exe',
      ),
      <String>['/user', '/fo', 'csv', '/nh'],
    );
    final String? sid = RegExp(
      r'S-1-5-\d+(?:-\d+)+',
    ).firstMatch('${identity.stdout}')?.group(0);
    if (identity.exitCode != 0 || sid == null) {
      return const ExtensionGuardResult(
        ok: false,
        message: '자동 재설치는 중지했습니다. 현재 사용자의 정책 경로를 확인하지 못해 관리자 정책은 변경하지 않았습니다.',
      );
    }
    final List<String> policies = <String>[];
    if (browserIds.contains('firefox')) {
      for (final String variable in <String>[
        'ProgramFiles',
        'ProgramFiles(x86)',
      ]) {
        final String? root = Platform.environment[variable];
        if (root != null) {
          policies.add(
            p.join(root, 'Mozilla Firefox', 'distribution', 'policies.json'),
          );
        }
      }
    }
    final String body = disableBrowserExtensionsScript(
      browserIds: browserIds,
      ownedListsJournalPath: BrowserPolicyLayer.ownedListsJournalPath,
      ownedHardeningJournalPath:
          WindowsBrowserBypassCloserService.ownedHardeningJournalPath,
      resultPath: result.path,
      firefoxPolicyFiles: policies,
      registryRoots: <String, List<String>>{
        for (final String browserId in browserIds)
          browserId: <String>[
            'HKLM:\\${managedBrowserPolicyRoots[browserId]}',
            'Registry::HKEY_USERS\\$sid\\${managedBrowserPolicyRoots[browserId]}',
          ],
      },
    );
    await script.writeAsString('\uFEFF$body', flush: true);
    final int? exit = await WindowsElevateRetryHelper.runElevated(
      ps64Exe: _nativePowerShellExe(),
      scriptPath: script.path,
      exitSentinelFile: result,
    );
    invalidateVerifyCache();
    return ExtensionGuardResult(
      ok: exit == 0 && profilesCleaned,
      message: exit == 0 && !profilesCleaned
          ? '확장 정책은 해제했지만 Firefox 관리 설정 일부를 정리하지 못했습니다. 원본을 보존했으며 다시 시도해 주세요.'
          : exit == 0
          ? '${browserIds.join(', ')} 확장 비활성화 정책 적용됨. 브라우저가 정책을 새로 읽으면 반영됩니다. 사이트 차단 규칙은 별도로 유지됩니다.'
          : '자동 재설치는 중지했습니다. 관리자 정책 변경은 완료되지 않아 브라우저 확장이 아직 활성일 수 있습니다.',
    );
  }

  static String elevatedGuardScript({
    required String chromeExtensionPath,
    required String firefoxExtensionPath,
    required String firefoxXpiPath,
    required String firefoxPolicyJson,
    required String firefoxRegistryExtensionSettingsJson,
    String? onlyBrowserId,
    ExtensionGuardPrefs? prefsForTesting,
  }) {
    if (onlyBrowserId != null &&
        !managedBrowserPolicyRoots.containsKey(onlyBrowserId)) {
      throw ArgumentError.value(onlyBrowserId, 'onlyBrowserId');
    }
    final String srcEsc = chromeExtensionPath.replaceAll("'", "''");
    final String ffEsc = firefoxExtensionPath.replaceAll("'", "''");
    final String ffXpiEsc = firefoxXpiPath.replaceAll("'", "''");
    final String extId = ChromeExtensionIdentity.extensionId;
    final String legacyId = ChromeExtensionIdentity.legacyExtensionId;
    final String destinationName = onlyBrowserId == 'aside'
        ? 'aside_blocker'
        : 'chrome_blocker';
    // settingsJson is built dynamically inside the PS script after $dest is set,
    // so update_url always resolves to ProgramData regardless of source path.
    final String policyEsc = firefoxPolicyJson.replaceAll("'", "''");
    final String ffRegEsc = firefoxRegistryExtensionSettingsJson.replaceAll(
      "'",
      "''",
    );
    final ExtensionGuardPrefs prefs =
        prefsForTesting ?? ExtensionGuardPrefs.instance;
    final String eligibility =
        r'''
$managedExtensionMarkers = @{ __MARKERS__ }
$selectedBrowser = '__SELECTED__'
function CanInstallBrowser([string]$browser) {
  if ($selectedBrowser -and $browser -ne $selectedBrowser) { return $false }
  if ($managedExtensionMarkers.ContainsKey($browser)) {
    return -not (Test-Path -LiteralPath $managedExtensionMarkers[$browser])
  }
  return $true
}
function CanInstallRoot([string]$root) {
  if ($root -like '*Google\Chrome*') { return (CanInstallBrowser 'chrome') }
  if ($root -like '*Microsoft\Edge*') { return (CanInstallBrowser 'edge') }
  if ($root -like '*\Chromium*') { return (CanInstallBrowser 'aside') }
  if ($root -like '*Mozilla\Firefox*') { return (CanInstallBrowser 'firefox') }
  return $true
}
function Set-ManagedListEntry([string]$key, [string]$value, [string]$identity) {
  if (-not (Test-Path -LiteralPath $key)) { New-Item -Path $key -Force | Out-Null }
  $properties = (Get-ItemProperty -LiteralPath $key).PSObject.Properties
  $slot = $null
  $nextSlot = 1
  foreach ($property in $properties) {
    if ($property.Name -notmatch '^\d+$') { continue }
    $old = [string]$property.Value
    if ($old -eq $identity -or $old.StartsWith($identity + ';') -or $old -like ('*' + $identity)) {
      $slot = $property.Name
      Set-ItemProperty -LiteralPath $key -Name $slot -Value $value -Type String -Force
    }
    if ([int]$property.Name -ge $nextSlot) { $nextSlot = [int]$property.Name + 1 }
  }
  if (-not $slot) { $slot = [string]$nextSlot }
  Set-ItemProperty -LiteralPath $key -Name $slot -Value $value -Type String -Force
}
'''
            .replaceAll(
              '__MARKERS__',
              ExtensionGuardPrefs.managedBrowserIds
                  .map(
                    (String id) =>
                        "'$id'='${prefs.browserDisabledMarkerPath(id).replaceAll("'", "''")}'",
                  )
                  .join(';'),
            )
            .replaceAll('__SELECTED__', onlyBrowserId ?? '');
    return '''
\$ErrorActionPreference = 'Continue'
$eligibility
\$log = Join-Path \$env:ProgramData 'SixVPNBlocker\\guard_last.log'
\$exitFile = Join-Path \$env:ProgramData 'SixVPNBlocker\\guard_last_exit.txt'
New-Item -ItemType Directory -Force -Path (Split-Path \$log) | Out-Null
function Log([string]\$m) { "\$(Get-Date -Format o) \$m" | Tee-Object -FilePath \$log -Append }
\$script:WroteChromeExt = \$false
\$script:SelectedPolicyWritten = \$false
\$extId = '$extId'
try {
  \$testKey = 'HKLM:\\SOFTWARE\\SixVPNBlockerGuardTest'
  New-Item -Path \$testKey -Force -ErrorAction Stop | Out-Null
  Remove-Item -LiteralPath \$testKey -Force -ErrorAction Stop
  Log 'HKLM write test OK'
} catch {
  Log "HKLM write test FAILED: \$(\$_.Exception.Message)"
  Set-Content -LiteralPath \$exitFile -Value '2' -Encoding ASCII -Force
  exit 2
}
\$src = '$srcEsc'
\$dest = Join-Path \$env:ProgramData 'SixVPNBlocker\\$destinationName'
\$ffDest = Join-Path \$env:ProgramData 'SixVPNBlocker\\firefox_blocker'
\$ffSrc = '$ffEsc'
try {
  if (Test-Path -LiteralPath \$dest) { Remove-Item -LiteralPath \$dest -Recurse -Force -ErrorAction SilentlyContinue }
  New-Item -ItemType Directory -Force -Path \$dest | Out-Null
  Copy-Item -Path (Join-Path \$src '*') -Destination \$dest -Recurse -Force
  Log "copied extension -> \$dest"
  if (-not (Test-Path -LiteralPath (Join-Path \$dest 'manifest.json'))) {
    Log "FATAL: manifest.json missing after copy from \$src"
    Set-Content -LiteralPath \$exitFile -Value '3' -Encoding ASCII -Force
    exit 3
  }
} catch {
  Log "copy failed: \$(\$_.Exception.Message)"
  Set-Content -LiteralPath \$exitFile -Value '3' -Encoding ASCII -Force
  exit 3
}
\$srcCrx = "\${src}.crx"
\$destCrx = "\${dest}.crx"
\$crxReady = \$false
\$crxHash = ''
try {
  if (Test-Path -LiteralPath \$srcCrx) {
    Copy-Item -LiteralPath \$srcCrx -Destination \$destCrx -Force
    \$hasher = [Security.Cryptography.SHA256]::Create()
    try {
      \$crxHash = ([BitConverter]::ToString(\$hasher.ComputeHash([IO.File]::ReadAllBytes(\$destCrx)))).Replace('-','').ToLowerInvariant()
    } finally { \$hasher.Dispose() }
    \$crxReady = \$true
    Log "copied signed CRX -> \$destCrx (sha256=\$crxHash)"
  } else {
    Log "FATAL: signed CRX package missing beside source: \$srcCrx"
  }
} catch {
  Log "CRX copy failed: \$(\$_.Exception.Message)"
}
try {
  if (Test-Path -LiteralPath \$ffDest) { Remove-Item -LiteralPath \$ffDest -Recurse -Force -ErrorAction SilentlyContinue }
  if (Test-Path -LiteralPath \$ffSrc) {
    New-Item -ItemType Directory -Force -Path \$ffDest | Out-Null
    Copy-Item -Path (Join-Path \$ffSrc '*') -Destination \$ffDest -Recurse -Force
    Log "copied firefox -> \$ffDest"
  }
} catch {
  Log "firefox copy skip: \$(\$_.Exception.Message)"
}
\$script:WroteFirefoxPolicy = \$false
\$ffXpi = '$ffXpiEsc'
# Keep the AMO-signed XPI byte-for-byte; locally repacking removes its signature.
\$ffPackageReady = \$false
if (Test-Path -LiteralPath \$ffXpi) {
  \$xpiText = [Text.Encoding]::GetEncoding('ISO-8859-1').GetString([IO.File]::ReadAllBytes(\$ffXpi))
  \$ffPackageReady = \$xpiText.Contains('META-INF/mozilla.rsa') -or \$xpiText.Contains('META-INF/cose.sig')
}
if (-not \$ffPackageReady) { Log 'Signed Firefox XPI is unavailable; refusing unsigned replacement.' }
try {
  \$profParent = Join-Path \$env:APPDATA 'Mozilla\\Firefox\\Profiles'
  if ((CanInstallBrowser 'firefox') -and \$ffPackageReady -and (Test-Path -LiteralPath \$profParent)) {
    Get-ChildItem -LiteralPath \$profParent -Directory | ForEach-Object {
      \$extDir = Join-Path \$_.FullName 'extensions'
      New-Item -ItemType Directory -Force -Path \$extDir | Out-Null
      Copy-Item -LiteralPath \$ffXpi -Destination (Join-Path \$extDir '${FirefoxXpiPackager.kXpiFileName}') -Force
      Log "profile XPI -> \$extDir"
    }
  }
} catch {
  Log "profile XPI copy skip: \$(\$_.Exception.Message)"
}
\$extPath = \$dest
\$extensionVersion = (Get-Content -LiteralPath (Join-Path \$dest 'manifest.json') -Raw | ConvertFrom-Json).version
\$updateXml = Join-Path \$dest 'updates.xml'
\$updateUrl = 'file:///' + (\$dest -replace '\\\\','/') + '/updates.xml'
\$forcelistVal = "\$extId;\$updateUrl"
\$settingsJson = '{"$extId":{"installation_mode":"force_installed","toolbar_pin":"force_pinned","update_url":"' + \$updateUrl + '","override_update_url":true}}'
\$crxPath = \$dest + '.crx'
\$codebase = if (\$crxReady) { 'file:///' + (\$crxPath -replace '\\\\','/') } else { '' }
\$updatesBody = "<?xml version='1.0' encoding='UTF-8'?><gupdate xmlns='http://www.google.com/update2/response' protocol='2.0'><app appid='\$extId'><updatecheck codebase='\$codebase' version='\$extensionVersion' hash_sha256='\$crxHash' /></app></gupdate>"
try {
  if (\$crxReady) {
    Set-Content -LiteralPath \$updateXml -Value \$updatesBody -Encoding UTF8 -Force
    Log "wrote signed-CRX updates.xml -> \$updateXml"
  } else {
    Log 'skipped force-install update manifest because signed CRX is missing'
  }
} catch {
  Log "updates.xml skip: \$(\$_.Exception.Message)"
}
\$chromeExt = 'HKLM:\\SOFTWARE\\Google\\Chrome\\Extensions'
\$edgeExt = 'HKLM:\\SOFTWARE\\Microsoft\\Edge\\Extensions'
\$chromiumExt = 'HKLM:\\SOFTWARE\\Chromium\\Extensions'
foreach (\$root in @(\$chromeExt, \$edgeExt, \$chromiumExt)) {
  if (-not (CanInstallRoot \$root)) { continue }
  try {
    if (-not \$crxReady) { throw 'Signed CRX package unavailable; external install cannot be registered.' }
    if (-not (Test-Path -LiteralPath \$root)) { New-Item -Path \$root -Force -ErrorAction Stop | Out-Null }
    \$key = Join-Path \$root \$extId
    New-Item -Path \$key -Force -ErrorAction Stop | Out-Null
    Set-ItemProperty -LiteralPath \$key -Name 'path' -Value \$destCrx -Type String -Force
    Set-ItemProperty -LiteralPath \$key -Name 'version' -Value \$extensionVersion -Type String -Force
    Log "registry external ext -> \$key = \$extPath"
    if (\$root -eq \$chromeExt) { \$script:WroteChromeExt = \$true }
  } catch {
    Log "registry skip (\$root): \$(\$_.Exception.Message)"
  }
}
\$policyTargets = @(
  'HKLM:\\SOFTWARE\\Policies\\Google\\Chrome',
  'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge',
  'HKLM:\\SOFTWARE\\Policies\\Chromium',
  'HKCU:\\SOFTWARE\\Policies\\Google\\Chrome',
  'HKCU:\\SOFTWARE\\Policies\\Microsoft\\Edge',
  'HKCU:\\SOFTWARE\\Policies\\Chromium'
)
\$forcelistRoots = @(
  'HKLM:\\SOFTWARE\\Policies\\Google\\Chrome\\ExtensionInstallForcelist',
  'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge\\ExtensionInstallForcelist',
  'HKLM:\\SOFTWARE\\Policies\\Chromium\\ExtensionInstallForcelist',
  'HKCU:\\SOFTWARE\\Policies\\Google\\Chrome\\ExtensionInstallForcelist',
  'HKCU:\\SOFTWARE\\Policies\\Microsoft\\Edge\\ExtensionInstallForcelist',
  'HKCU:\\SOFTWARE\\Policies\\Chromium\\ExtensionInstallForcelist'
)
\$script:WroteHkcuChromePolicy = \$false
foreach (\$fl in \$forcelistRoots) {
  if (-not (CanInstallRoot \$fl)) { continue }
  try {
    if (-not \$crxReady) { throw 'Signed CRX package unavailable; refusing to set a nonfunctional force-install policy.' }
    if (-not (Test-Path -LiteralPath \$fl)) { New-Item -Path \$fl -Force -ErrorAction Stop | Out-Null }
    \$values = Get-ItemProperty -LiteralPath \$fl
    \$slot = \$null
    \$nextSlot = 1
    foreach (\$property in \$values.PSObject.Properties) {
      if (\$property.Name -notmatch '^\\d+\$') { continue }
      # Retire only the previous FocusFense signing identity.
      if (([string]\$property.Value).StartsWith('$legacyId;')) {
        Remove-ItemProperty -LiteralPath \$fl -Name \$property.Name -Force
        continue
      }
      if (([string]\$property.Value).StartsWith(\$extId + ';')) {
        \$slot = \$property.Name
        Set-ItemProperty -LiteralPath \$fl -Name \$slot -Value \$forcelistVal -Type String -Force
      }
      if ([int]\$property.Name -ge \$nextSlot) { \$nextSlot = [int]\$property.Name + 1 }
    }
    if (-not \$slot) { \$slot = [string]\$nextSlot }
    Set-ItemProperty -LiteralPath \$fl -Name \$slot -Value \$forcelistVal -Type String -Force
    Log "ExtensionInstallForcelist -> \$fl = \$forcelistVal"
    if (\$fl -like 'HKCU:*Chrome*') { \$script:WroteHkcuChromePolicy = \$true }
  } catch {
    Log "forcelist skip (\$fl): \$(\$_.Exception.Message)"
  }
}
foreach (\$root in \$policyTargets) {
  if (-not (CanInstallRoot \$root)) { continue }
  try {
    if (-not \$crxReady) { throw 'Signed CRX package unavailable; refusing to set a nonfunctional force-install policy.' }
    if (-not (Test-Path -LiteralPath \$root)) { New-Item -Path \$root -Force -ErrorAction Stop | Out-Null }
    \$previous = (Get-ItemProperty -LiteralPath \$root -Name ExtensionSettings -ErrorAction SilentlyContinue).ExtensionSettings
    \$mergedSettings = if (\$previous) { ConvertFrom-Json -InputObject \$previous } else { New-Object PSObject }
    \$ourSettings = (ConvertFrom-Json -InputObject \$settingsJson).\$extId
    \$mergedSettings | Add-Member -Name '$legacyId' -MemberType NoteProperty -Value @{installation_mode='removed'} -Force
    \$mergedSettings | Add-Member -Name \$extId -MemberType NoteProperty -Value \$ourSettings -Force
    Set-ItemProperty -LiteralPath \$root -Name 'ExtensionSettings' -Value (ConvertTo-Json -InputObject \$mergedSettings -Depth 50 -Compress) -Type String -Force
    if (\$root -like 'HKLM:*') { \$script:SelectedPolicyWritten = \$true }
    if (-not \$selectedBrowser) { Set-ItemProperty -LiteralPath \$root -Name 'ExtensionDeveloperModeAvailability' -Value 0 -Type DWord -Force }
    Log "policy ExtensionSettings + dev-mode lock -> \$root"
  } catch {
    Log "policy skip (\$root): \$(\$_.Exception.Message)"
  }
}
if ((CanInstallBrowser 'firefox') -and \$ffPackageReady) { try {
  \$mozPolicy = 'HKLM:\\SOFTWARE\\Policies\\Mozilla\\Firefox'
  \$ffSettings = '$ffRegEsc'
  if (-not (Test-Path -LiteralPath \$mozPolicy)) { New-Item -Path \$mozPolicy -Force -ErrorAction Stop | Out-Null }
  \$previous = (Get-ItemProperty -LiteralPath \$mozPolicy -Name ExtensionSettings -ErrorAction SilentlyContinue).ExtensionSettings
  \$mergedSettings = if (\$previous) { ConvertFrom-Json -InputObject (\$previous -join '') } else { New-Object PSObject }
  \$ourSettings = (ConvertFrom-Json -InputObject \$ffSettings).'$kFirefoxExtensionId'
  \$mergedSettings | Add-Member -Name '$kFirefoxExtensionId' -MemberType NoteProperty -Value \$ourSettings -Force
  Set-ItemProperty -LiteralPath \$mozPolicy -Name 'ExtensionSettings' -Value (ConvertTo-Json -InputObject \$mergedSettings -Depth 50 -Compress) -Type String -Force
  \$script:SelectedPolicyWritten = \$true
  if (-not \$selectedBrowser) {
    Set-ItemProperty -LiteralPath \$mozPolicy -Name 'DisablePrivateBrowsing' -Value 1 -Type DWord -Force
    Set-ItemProperty -LiteralPath \$mozPolicy -Name 'PrivateBrowsingModeAvailability' -Value 1 -Type DWord -Force
    Set-ItemProperty -LiteralPath \$mozPolicy -Name 'DisableDeveloperTools' -Value 1 -Type DWord -Force
  }
  \$ffInstall = Join-Path \$mozPolicy 'Extensions\\Install'
  \$ffLocked = Join-Path \$mozPolicy 'Extensions\\Locked'
  Set-ManagedListEntry \$ffInstall ('file:///' + (\$ffXpi -replace '\\\\','/')) '${FirefoxXpiPackager.kXpiFileName}'
  Set-ManagedListEntry \$ffLocked '$kFirefoxExtensionId' '$kFirefoxExtensionId'
  Log "Firefox registry ExtensionSettings + locked install -> \$mozPolicy"
} catch {
  Log "Firefox registry skip: \$(\$_.Exception.Message)"
} }
if ((CanInstallBrowser 'firefox') -and \$ffPackageReady) { try {
  \$policyJson = @'
$policyEsc
'@
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
      \$policyFile = Join-Path \$dist 'policies.json'
      \$incoming = ConvertFrom-Json -InputObject \$policyJson
      \$document = if (Test-Path -LiteralPath \$policyFile) { Get-Content -LiteralPath \$policyFile -Raw | ConvertFrom-Json } else { New-Object PSObject }
      if (-not \$document.policies) { \$document | Add-Member -Name policies -MemberType NoteProperty -Value (New-Object PSObject) }
      foreach (\$property in \$incoming.policies.PSObject.Properties) {
        \$name = \$property.Name
        if (\$selectedBrowser -and \$name -notin @('ExtensionSettings','Extensions')) { continue }
        if (-not \$document.policies.PSObject.Properties[\$name]) {
          \$document.policies | Add-Member -Name \$name -MemberType NoteProperty -Value \$property.Value
        } elseif (\$name -eq 'ExtensionSettings') {
          \$document.policies.ExtensionSettings | Add-Member -Name '$kFirefoxExtensionId' -MemberType NoteProperty -Value \$property.Value.'$kFirefoxExtensionId' -Force
        } elseif (\$name -eq 'Extensions') {
          foreach (\$list in \$property.Value.PSObject.Properties) {
            \$values = @(\$document.policies.Extensions.\$(\$list.Name)) + @(\$list.Value)
            \$document.policies.Extensions | Add-Member -Name \$list.Name -MemberType NoteProperty -Value @(\$values | Where-Object { \$null -ne \$_ } | Select-Object -Unique) -Force
          }
        }
      }
      if (\$document.policies.Extensions.Uninstall) {
        \$remaining = @(\$document.policies.Extensions.Uninstall | Where-Object { \$_ -ne '$kFirefoxExtensionId' })
        \$document.policies.Extensions | Add-Member -Name Uninstall -MemberType NoteProperty -Value \$remaining -Force
      }
      \$document | ConvertTo-Json -Depth 50 | Set-Content -LiteralPath \$policyFile -Encoding UTF8 -Force
      \$script:WroteFirefoxPolicy = \$true
      Log "Firefox policies.json -> \$dist"
    } catch {
      Log "Firefox policy skip (\$dist): \$(\$_.Exception.Message)"
    }
  }
} catch {
  Log "Firefox policy block skip: \$(\$_.Exception.Message)"
} }
if (\$selectedBrowser) {
  if (\$script:SelectedPolicyWritten -and (\$selectedBrowser -ne 'firefox' -or \$script:WroteFirefoxPolicy)) {
    Set-Content -LiteralPath \$exitFile -Value '0' -Encoding ASCII -Force
    exit 0
  }
  Set-Content -LiteralPath \$exitFile -Value '1' -Encoding ASCII -Force
  exit 1
}
if ((CanInstallBrowser 'chrome') -and -not \$script:WroteChromeExt) {
  if (\$script:WroteHkcuChromePolicy) {
    Log 'HKLM Chrome ext missing — HKCU policy fallback (no admin)'
    Set-Content -LiteralPath \$exitFile -Value '3' -Encoding ASCII -Force
    exit 3
  }
  Log 'FAILED: Chrome HKLM extension key was not written'
  Set-Content -LiteralPath \$exitFile -Value '1' -Encoding ASCII -Force
  exit 1
}
Log 'extension guard done OK'
Set-Content -LiteralPath \$exitFile -Value '0' -Encoding ASCII -Force
exit 0
''';
  }

  static Future<bool> _regValueContains(
    String policyPath,
    String valueName,
    String needle,
  ) async {
    try {
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final ProcessResult pr = await windowsRunHidden(
        p.join(windir, 'System32', 'reg.exe'),
        <String>['query', policyPath, '/v', valueName],
      );
      return pr.exitCode == 0 && '${pr.stdout}'.contains(needle);
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _regForcelistHasExtension(String forcelistPath) async {
    try {
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final ProcessResult pr = await windowsRunHidden(
        p.join(windir, 'System32', 'reg.exe'),
        <String>['query', forcelistPath],
      );
      if (pr.exitCode != 0) return false;
      return '${pr.stdout}'.contains(ChromeExtensionIdentity.extensionId);
    } catch (_) {
      return false;
    }
  }

  static Future<bool> firefoxPolicyFileOk() async {
    final String pf =
        Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
    final String pf86 =
        Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';
    for (final String base in <String>[pf, pf86]) {
      final File f = File(
        p.join(base, 'Mozilla Firefox', 'distribution', 'policies.json'),
      );
      if (!await f.exists()) continue;
      final String raw = await f.readAsString();
      if (raw.contains(kFirefoxExtensionId) &&
          raw.contains('force_installed') &&
          raw.contains('"Install"') &&
          raw.contains('"Locked"') &&
          raw.contains('DisablePrivateBrowsing')) {
        return true;
      }
    }
    return false;
  }

  /// HKLM policies + external extension keys (read-only).
  static ExtensionPolicyVerifyResult? _verifyCache;
  static DateTime? _verifyCacheAt;
  static const Duration _verifyCacheTtl = Duration(seconds: 300);

  static void invalidateVerifyCache() {
    _verifyCache = null;
    _verifyCacheAt = null;
  }

  static Future<ExtensionPolicyVerifyResult> verifyAllPolicies({
    bool force = false,
  }) async {
    if (!force &&
        _verifyCache != null &&
        _verifyCacheAt != null &&
        DateTime.now().difference(_verifyCacheAt!) < _verifyCacheTtl) {
      return _verifyCache!;
    }
    if (!Platform.isWindows) {
      return const ExtensionPolicyVerifyResult(
        registryOk: false,
        policyHklmOk: false,
        forcelistOk: false,
        chromeForcelistOk: false,
        edgeForcelistOk: false,
        chromeHkcuForcelistOk: false,
        edgeHkcuForcelistOk: false,
        chromeHkcuPolicyOk: false,
        edgeHkcuPolicyOk: false,
        chromeUserInstallOk: false,
        edgeUserInstallOk: false,
        chromeHklmInstallOk: false,
        edgeHklmInstallOk: false,
        chromeLoadExtensionFallbackOk: false,
        chromeExtensionInProfile: false,
        chromeInstallOk: false,
        edgeInstallOk: false,
        firefoxPolicyOk: false,
        programDataPath: null,
        detail: 'Windows 전용',
      );
    }
    final ExtensionGuardVerifyResult base = await verifyChromeEdgeRegistry();
    final String extId = ChromeExtensionIdentity.extensionId;
    final ChromiumDerivativeBrowserDef? asideDef = chromiumDerivativeById(
      'aside',
    );
    bool asideInstalled = false;
    if (asideDef != null) {
      for (final String exe in asideDef.exeCandidates) {
        if (await File(exe).exists()) {
          asideInstalled = true;
          break;
        }
      }
    }
    final String asidePolicyRoot =
        asideDef?.policyRootHklm ?? r'HKLM\SOFTWARE\Policies\Chromium';
    final bool asideForcelist =
        asideInstalled &&
        await _regForcelistHasExtension(
          asidePolicyRoot + r'\ExtensionInstallForcelist',
        );
    final bool asideSettings =
        asideInstalled &&
        await _regValueContains(asidePolicyRoot, 'ExtensionSettings', extId);
    final String? chromePath = await _readRegDefault(
      r'HKLM\SOFTWARE\Google\Chrome\Extensions',
      extId,
    );
    final String? edgePath = await _readRegDefault(
      r'HKLM\SOFTWARE\Microsoft\Edge\Extensions',
      extId,
    );
    final String? chromeUserPath = await _readRegDefault(
      r'HKCU\Software\Google\Chrome\Extensions',
      extId,
    );
    final String? edgeUserPath = await _readRegDefault(
      r'HKCU\Software\Microsoft\Edge\Extensions',
      extId,
    );
    final bool chromeHklmInstall =
        chromePath != null &&
        await File(p.join(chromePath, 'manifest.json')).exists();
    final bool edgeHklmInstall =
        edgePath != null &&
        await File(p.join(edgePath, 'manifest.json')).exists();
    final bool chromeUserInstall =
        chromeUserPath != null &&
        await File(p.join(chromeUserPath, 'manifest.json')).exists();
    final bool edgeUserInstall =
        edgeUserPath != null &&
        await File(p.join(edgeUserPath, 'manifest.json')).exists();
    final bool chromeInstallOk = chromeHklmInstall || chromeUserInstall;
    final bool edgeInstallOk = edgeHklmInstall || edgeUserInstall;
    final bool chromeForcelist = await _regForcelistHasExtension(
      r'HKLM\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist',
    );
    final bool edgeForcelist = await _regForcelistHasExtension(
      r'HKLM\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist',
    );
    final bool chromeHkcuForcelist = await _regForcelistHasExtension(
      r'HKCU\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist',
    );
    final bool edgeHkcuForcelist = await _regForcelistHasExtension(
      r'HKCU\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist',
    );
    final bool chromeHkcuPolicy = await _regValueContains(
      r'HKCU\SOFTWARE\Policies\Google\Chrome',
      'ExtensionSettings',
      extId,
    );
    final bool edgeHkcuPolicy = await _regValueContains(
      r'HKCU\SOFTWARE\Policies\Microsoft\Edge',
      'ExtensionSettings',
      extId,
    );
    final bool mozReg = await _regValueContains(
      r'HKLM\SOFTWARE\Policies\Mozilla\Firefox',
      'ExtensionSettings',
      kFirefoxExtensionId,
    );
    final bool ffFile = await firefoxPolicyFileOk();
    final bool ffXpi = await File(
      FirefoxXpiPackager.programDataXpiPath,
    ).exists();
    final FirefoxInstallVerifyResult ffProf =
        await WindowsFirefoxExtensionInstallService.verify();
    final bool ffRequired = await _firefoxInstalledOnMachine();
    final StringBuffer detail = StringBuffer(base.detail);
    detail.writeln(
      'ExtensionInstallForcelist Chrome: ${chromeForcelist ? "있음" : "없음"}',
    );
    detail.writeln(
      'ExtensionInstallForcelist Edge: ${edgeForcelist ? "있음" : "없음"}',
    );
    detail.writeln(
      'HKCU Chrome 정책: ${chromeHkcuForcelist && chromeHkcuPolicy ? "있음 (UAC 없이)" : "없음"}',
    );
    detail.writeln(
      'HKCU Edge 정책: ${edgeHkcuForcelist && edgeHkcuPolicy ? "있음 (UAC 없이)" : "없음"}',
    );
    detail.writeln(
      'Chrome 사용자 레지스트리: ${chromeUserInstall ? "있음 → $chromeUserPath" : "없음"}',
    );
    detail.writeln('Edge 사용자 레지스트리: ${edgeUserInstall ? "있음" : "없음"}');
    detail.writeln(
      'Firefox policies.json: ${ffFile ? "있음" : "없음"} · 레지스트리: ${mozReg ? "있음" : "없음"}',
    );
    detail.writeln(
      'Firefox XPI: ${ffXpi ? "있음" : "없음"} · 프로필: ${ffProf.profileCount}/${ffProf.profileTotal}',
    );
    // Firefox: policy preferred; profile XPI sideload also counts as ready.
    final bool firefoxOk = !ffRequired || (ffXpi && ffProf.profileCount > 0);
    final bool loadExtFallback =
        await ChromeLoadExtensionLauncher.isInstalled();
    final ChromeExtensionProbeResult chromeProfileProbe =
        await ChromeExtensionStateProbe.probe(browser: 'chrome');
    final bool chromeExtensionInProfile =
        !chromeProfileProbe.extensionNotPresent;
    final bool payloadOk =
        await ChromeExtensionPayloadService.stablePayloadReady();
    detail.writeln(
      'Chrome 프로필 확장: ${chromeExtensionInProfile ? "로드됨" : "없음 — Chrome 완전 종료 후 재실행"}',
    );
    detail.writeln(
      'Chrome 확장 파일(manifest): ${payloadOk ? "있음" : "없음 — 앱이 자동 복구 시도"}',
    );
    detail.writeln(
      'Chrome --load-extension: ${loadExtFallback ? "있음 (바탕화면 「6 VPN Blocker (Chrome)」)" : "없음"}',
    );
    if (asideInstalled) {
      detail.writeln(
        'Aside AI Browser HKLM force-install: ${asideForcelist && asideSettings ? "있음" : "없음"}',
      );
    }
    if (loadExtFallback) {
      detail.writeln(
        '3단계 우회: 바로가기 통합 + tier3 감시(순정 Chrome 종료) + sixvpn-open: 링크 (레지스트리 없이)',
      );
    }
    final ExtensionPolicyVerifyResult result = ExtensionPolicyVerifyResult(
      registryOk: base.registryOk,
      policyHklmOk: base.policyHklmOk,
      forcelistOk: chromeForcelist && edgeForcelist,
      chromeForcelistOk: chromeForcelist,
      edgeForcelistOk: edgeForcelist,
      chromeHkcuForcelistOk: chromeHkcuForcelist,
      edgeHkcuForcelistOk: edgeHkcuForcelist,
      chromeHkcuPolicyOk: chromeHkcuPolicy,
      edgeHkcuPolicyOk: edgeHkcuPolicy,
      chromeUserInstallOk: chromeUserInstall,
      edgeUserInstallOk: edgeUserInstall,
      chromeHklmInstallOk: chromeHklmInstall,
      edgeHklmInstallOk: edgeHklmInstall,
      asideRequired: asideInstalled,
      asideForcelistOk: asideForcelist,
      asidePolicyOk: asideSettings,
      chromeLoadExtensionFallbackOk: loadExtFallback,
      chromeExtensionInProfile: chromeExtensionInProfile,
      chromeInstallOk: chromeInstallOk,
      edgeInstallOk: edgeInstallOk,
      firefoxPolicyOk: firefoxOk,
      programDataPath: base.programDataPath,
      detail: detail.toString().trim(),
    );
    _verifyCache = result;
    _verifyCacheAt = DateTime.now();
    return result;
  }

  static Future<bool> _firefoxInstalledOnMachine() async {
    final String pf =
        Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
    final String pf86 =
        Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';
    for (final String base in <String>[pf, pf86]) {
      if (await Directory(p.join(base, 'Mozilla Firefox')).exists()) {
        return true;
      }
    }
    return false;
  }

  /// After UAC guard: checks HKLM external-extension keys (no admin needed to read).
  static Future<ExtensionGuardVerifyResult> verifyChromeEdgeRegistry() async {
    if (!Platform.isWindows) {
      return const ExtensionGuardVerifyResult(
        registryOk: false,
        policyHklmOk: false,
        programDataPath: null,
        detail: 'Windows 전용',
      );
    }
    final String extId = ChromeExtensionIdentity.extensionId;
    final String programData = p.join(
      Platform.environment['ProgramData'] ?? r'C:\ProgramData',
      kProgramDataSubdir,
    );
    final String? chromePath = await _readRegDefault(
      r'HKLM\SOFTWARE\Google\Chrome\Extensions',
      extId,
    );
    final String? edgePath = await _readRegDefault(
      r'HKLM\SOFTWARE\Microsoft\Edge\Extensions',
      extId,
    );
    final bool regOk =
        chromePath != null &&
        edgePath != null &&
        await File(p.join(chromePath, 'manifest.json')).exists();
    final bool policyOk = await _regHasExtensionSettings(
      r'HKLM\SOFTWARE\Policies\Google\Chrome',
    );
    final StringBuffer detail = StringBuffer();
    detail.writeln('Chrome HKLM 경로: ${chromePath ?? "(없음)"}');
    detail.writeln('Edge HKLM 경로: ${edgePath ?? "(없음)"}');
    detail.writeln('정책(ExtensionSettings) HKLM: ${policyOk ? "있음" : "없음"}');
    if (!regOk) {
      detail.writeln(
        '\n→ UAC가 거부되었거나 회사 PC가 레지스트리 쓰기를 막았을 수 있습니다.\n'
        '→ 개발자 모드 확장만 있으면 계속 「제거」가 보입니다.',
      );
    } else {
      detail.writeln(
        '\n→ chrome://extensions 에서 개발자 모드로 넣은 복사본을 지우고\n'
        '   Chrome을 완전히 종료 후 다시 켜면 「관리자가 설치」만 남아야 합니다.',
      );
    }
    return ExtensionGuardVerifyResult(
      registryOk: regOk,
      policyHklmOk: policyOk,
      programDataPath: await Directory(programData).exists()
          ? programData
          : chromePath,
      detail: detail.toString().trim(),
    );
  }

  static Future<String?> _readRegDefault(String hivePath, String extId) async {
    try {
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final ProcessResult pr = await windowsRunHidden(
        p.join(windir, 'System32', 'reg.exe'),
        <String>['query', '$hivePath\\$extId', '/ve'],
      );
      if (pr.exitCode != 0) return null;
      final RegExp re = RegExp(
        r'REG_\w+\s+REG_\w+\s+(.+)\s*$',
        multiLine: true,
      );
      final RegExpMatch? m = re.firstMatch('${pr.stdout}');
      if (m == null) return null;
      final String path = m.group(1)!.trim();
      return path.isEmpty ? null : path;
    } catch (_) {
      return null;
    }
  }

  static Future<bool> _regHasExtensionSettings(String policyPath) async {
    try {
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final ProcessResult pr = await windowsRunHidden(
        p.join(windir, 'System32', 'reg.exe'),
        <String>['query', policyPath, '/v', 'ExtensionSettings'],
      );
      return pr.exitCode == 0 && '${pr.stdout}'.contains('ExtensionSettings');
    } catch (_) {
      return false;
    }
  }

  static Future<int?> readGuardLastExitCode() async {
    try {
      final File f = File(
        p.join(
          Platform.environment['ProgramData'] ?? r'C:\ProgramData',
          'SixVPNBlocker',
          'guard_last_exit.txt',
        ),
      );
      if (!await f.exists()) return null;
      final String raw = (await f.readAsString()).trim();
      return int.tryParse(raw);
    } catch (_) {
      return null;
    }
  }

  static Future<String?> readGuardLogTail({int maxLines = 12}) async {
    try {
      final File f = File(
        p.join(
          Platform.environment['ProgramData'] ?? r'C:\ProgramData',
          'SixVPNBlocker',
          'guard_last.log',
        ),
      );
      if (!await f.exists()) return null;
      final List<String> lines = await f.readAsLines();
      if (lines.isEmpty) return null;
      final int start = lines.length > maxLines ? lines.length - maxLines : 0;
      return lines.sublist(start).join('\n');
    } catch (_) {
      return null;
    }
  }

  Future<ExtensionGuardResult> runElevatedGuard({
    required String chromeExtensionFolder,
    String? onlyBrowserId,
  }) async {
    if (!Platform.isWindows) {
      return const ExtensionGuardResult(ok: false, message: 'Windows 전용입니다.');
    }
    final String chromePath = p.normalize(chromeExtensionFolder);
    if (!await Directory(chromePath).exists()) {
      return ExtensionGuardResult(
        ok: false,
        message: '확장 폴더가 없습니다. 먼저 ① Chrome/Edge 폴더 준비를 누르세요.\n$chromePath',
      );
    }
    if (onlyBrowserId != 'firefox') {
      final File crx = File('$chromePath.crx');
      try {
        if (!await crx.exists()) {
          return const ExtensionGuardResult(
            ok: false,
            message: '서명된 CRX 설치 패키지가 없습니다. 설치 패키지를 먼저 준비해야 합니다.',
          );
        }
        if (ChromeExtensionIdentity.readCrx3Identity(await crx.readAsBytes()) !=
            ChromeExtensionIdentity.extensionId) {
          return const ExtensionGuardResult(
            ok: false,
            message: '설치 패키지가 앱과 다른 확장 ID로 서명되어 있습니다. 일치하는 설치 패키지를 재생성해야 합니다.',
          );
        }
      } catch (_) {
        return const ExtensionGuardResult(
          ok: false,
          message: 'CRX 설치 패키지의 형식·확장 ID를 확인하지 못했습니다. 정책은 변경하지 않았습니다.',
        );
      }
    }
    final String parent = p.dirname(chromePath);
    final String firefoxPath = p.join(parent, 'firefox_blocker');
    final Directory ffDir = Directory(firefoxPath);
    final bool hasFirefox = await ffDir.exists();
    final String? ffPathForPolicy = hasFirefox ? firefoxPath : null;
    String xpiInstallUrl = '';
    String firefoxXpiPath = FirefoxXpiPackager.programDataXpiPath;
    if (ffPathForPolicy != null) {
      final File xpi = await FirefoxXpiPackager.instance.ensureProgramDataXpi(
        sourceFolder: ffPathForPolicy,
      );
      firefoxXpiPath = xpi.path;
      xpiInstallUrl = FirefoxXpiPackager.fileUrlForXpi(xpi.path);
    }
    final String policyJson = ffPathForPolicy != null
        ? buildFirefoxGuardPolicyJson(
            installSourcesParent: parent,
            xpiInstallUrl: xpiInstallUrl,
          )
        : buildFirefoxGuardPolicyJson(
            installSourcesParent: parent,
            xpiInstallUrl: 'file:///',
          );
    final String ffRegJson = buildFirefoxRegistryExtensionSettingsJson(
      xpiInstallUrl: xpiInstallUrl.isEmpty ? 'file:///' : xpiInstallUrl,
    );

    try {
      final String programData =
          Platform.environment['ProgramData'] ?? r'C:\ProgramData';
      final Directory guardDir = Directory(
        p.join(programData, 'SixVPNBlocker'),
      );
      if (!await guardDir.exists()) {
        await guardDir.create(recursive: true);
      }
      final File script = File(p.join(guardDir.path, 'guard_run.ps1'));
      final String body = elevatedGuardScript(
        chromeExtensionPath: chromePath,
        firefoxExtensionPath: ffPathForPolicy ?? firefoxPath,
        firefoxXpiPath: firefoxXpiPath,
        firefoxPolicyJson: policyJson,
        firefoxRegistryExtensionSettingsJson: ffRegJson,
        onlyBrowserId: onlyBrowserId,
      );
      await script.writeAsString('\uFEFF$body', flush: true);

      final String ps64 = _nativePowerShellExe();
      final File exitFile = File(
        p.join(programData, 'SixVPNBlocker', 'guard_last_exit.txt'),
      );

      // Primary Start-Process/RunAs attempt, with a VBS ShellExecute
      // fallback if AV/EDR silently swallows the nested elevation request
      // before Windows ever shows the UAC dialog (confirmed on this
      // machine with AhnLab V3 Lite installed — the previous unbounded
      // wait here just hung until the one-tap orchestrator's 90s
      // stale-lock timer force-failed the whole run).
      final int? scriptExit = await WindowsElevateRetryHelper.runElevated(
        ps64Exe: ps64,
        scriptPath: script.path,
        exitSentinelFile: exitFile,
      );

      if (scriptExit == null) {
        return const ExtensionGuardResult(
          ok: false,
          message:
              'UAC 승인 창이 뜨지 않았거나 응답이 없습니다. '
              '보안 프로그램(백신)이 관리자 권한 요청을 막았을 수 있습니다. '
              '「지금 모두 적용」을 다시 눌러 재시도하세요.',
        );
      }

      if (scriptExit == 2) {
        final String? logTail = await readGuardLogTail();
        return ExtensionGuardResult(
          ok: false,
          message:
              '관리자 권한으로 레지스트리(HKLM)에 쓸 수 없습니다.\n'
              '학교·회사 PC이거나 보안 프로그램이 막았을 수 있습니다.\n'
              '${logTail ?? ""}',
        );
      }
      if (scriptExit == 1) {
        final String? logTail = await readGuardLogTail();
        if (logTail?.contains('CRX') ?? false) {
          return ExtensionGuardResult(
            ok: false,
            message:
                '${onlyBrowserId ?? '브라우저'} 서명 설치 패키지를 준비하지 못해 설치 정책을 완료하지 못했습니다.\n${logTail ?? ''}',
          );
        }
        return ExtensionGuardResult(
          ok: false,
          message:
              'UAC는 통과했지만 ${onlyBrowserId ?? 'Chrome'} 확장 정책 등록에 실패했습니다.\n'
              '앱을 탐색기에서 우클릭 → **관리자 권한으로 실행** 후 다시 시도하세요.\n'
              '${logTail ?? ""}',
        );
      }

      if (onlyBrowserId != null) {
        invalidateVerifyCache();
        return ExtensionGuardResult(
          ok: scriptExit == 0,
          message: scriptExit == 0
              ? '$onlyBrowserId 관리자 설치 정책을 기록했습니다. 실제 확장 설치·차단은 브라우저가 정책을 새로 읽은 뒤 확인해야 합니다.'
              : '$onlyBrowserId 설치 정책을 확인하지 못했습니다.',
        );
      }

      if (scriptExit == 3) {
        final ExtensionPolicyVerifyResult verify = await verifyAllPolicies();
        final String? logTail = await readGuardLogTail();
        await ExtensionGuardPrefs.instance.setChromeSourcePath(chromePath);
        await ExtensionGuardPrefs.instance.setWatchdogEnabled(true);
        return ExtensionGuardResult(
          ok: verify.chromeOk,
          message:
              'HKLM 관리자 키는 없지만 **HKCU 정책**으로 Chrome/Edge 확장을 강제합니다.\n'
              'Firefox는 정상입니다. chrome://policy → 새로고침 후 Chrome 재시작.\n'
              '${verify.detail}'
              '${logTail != null && logTail.isNotEmpty ? "\n\n[로그]\n$logTail" : ""}',
        );
      }

      final ExtensionPolicyVerifyResult verify = await verifyAllPolicies();
      final String? logTail = await readGuardLogTail();
      final StringBuffer msg = StringBuffer();
      if (verify.allOk) {
        await ExtensionGuardPrefs.instance.setChromeSourcePath(chromePath);
        await ExtensionGuardPrefs.instance.setWatchdogEnabled(true);
        msg.writeln('관리자 설치 + 삭제 방지 정책 등록 완료');
        msg.writeln('경로: ${verify.programDataPath}');
        msg.writeln('백그라운드 정책 감시(자동 복구) 켜짐');
      } else if (verify.registryOk) {
        await ExtensionGuardPrefs.instance.setChromeSourcePath(chromePath);
        await ExtensionGuardPrefs.instance.setWatchdogEnabled(true);
        msg.writeln('확장 등록은 됐지만 일부 정책이 빠졌습니다. 감시가 재시도합니다.');
        msg.writeln(verify.detail);
      } else {
        msg.writeln('Chrome 레지스트리 등록이 확인되지 않습니다.');
        msg.writeln('회사 PC·백신·UAC 거부가 흔한 원인입니다.');
        msg.writeln(verify.detail);
      }
      msg.writeln(
        '\n다음:\n'
        '1) chrome://extensions → 개발자 모드로 넣은 6 VPN Blocker 가 있으면 **제거**\n'
        '2) Chrome 작업 표시줄 아이콘 우클릭 → **모든 Chrome 창 닫기**\n'
        '3) Chrome 다시 실행 → 확장에 **「관리자가 설치」** 만 보이는지 확인\n'
        '   (「압축 해제됨」이면 아직 개발자 모드 복사본입니다)\n'
        '4) 제거·끄기 버튼이 없어야 정상 (ExtensionInstallForcelist + force_installed)',
      );
      if (logTail != null && logTail.isNotEmpty) {
        msg.writeln('\n[관리자 로그]\n$logTail');
      }
      return ExtensionGuardResult(
        ok: verify.registryOk,
        message: msg.toString().trim(),
      );
    } catch (e) {
      return ExtensionGuardResult(ok: false, message: '적용 오류: $e');
    }
  }

  static String _nativePowerShellExe() {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return p.join(
      windir,
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
  }
}

final class ExtensionGuardResult {
  const ExtensionGuardResult({required this.ok, required this.message});
  final bool ok;
  final String message;
}

final class ExtensionGuardVerifyResult {
  const ExtensionGuardVerifyResult({
    required this.registryOk,
    required this.policyHklmOk,
    required this.programDataPath,
    required this.detail,
  });

  final bool registryOk;
  final bool policyHklmOk;
  final String? programDataPath;
  final String detail;
}

final class ExtensionPolicyVerifyResult {
  const ExtensionPolicyVerifyResult({
    required this.registryOk,
    required this.policyHklmOk,
    required this.forcelistOk,
    required this.chromeForcelistOk,
    required this.edgeForcelistOk,
    required this.chromeHkcuForcelistOk,
    required this.edgeHkcuForcelistOk,
    required this.chromeHkcuPolicyOk,
    required this.edgeHkcuPolicyOk,
    required this.chromeUserInstallOk,
    required this.edgeUserInstallOk,
    required this.chromeHklmInstallOk,
    required this.edgeHklmInstallOk,
    required this.chromeLoadExtensionFallbackOk,
    this.chromeExtensionInProfile = false,
    required this.chromeInstallOk,
    required this.edgeInstallOk,
    required this.firefoxPolicyOk,
    this.asideRequired = false,
    this.asideForcelistOk = false,
    this.asidePolicyOk = false,
    required this.programDataPath,
    required this.detail,
  });

  final bool registryOk;
  final bool policyHklmOk;
  final bool forcelistOk;
  final bool chromeForcelistOk;
  final bool edgeForcelistOk;
  final bool chromeHkcuForcelistOk;
  final bool edgeHkcuForcelistOk;
  final bool chromeHkcuPolicyOk;
  final bool edgeHkcuPolicyOk;
  final bool chromeUserInstallOk;
  final bool edgeUserInstallOk;
  final bool chromeHklmInstallOk;
  final bool edgeHklmInstallOk;
  final bool chromeLoadExtensionFallbackOk;
  final bool chromeExtensionInProfile;
  final bool chromeInstallOk;
  final bool edgeInstallOk;
  final bool firefoxPolicyOk;
  final bool asideRequired;
  final bool asideForcelistOk;
  final bool asidePolicyOk;
  final String? programDataPath;
  final String detail;

  bool get chromeHklmOk => chromeHklmInstallOk && chromeForcelistOk;

  bool get edgeHklmOk => edgeHklmInstallOk && edgeForcelistOk;

  bool get chromeHkcuOk => chromeHkcuForcelistOk && chromeHkcuPolicyOk;

  bool get edgeHkcuOk => edgeHkcuForcelistOk && edgeHkcuPolicyOk;

  bool get chromeOk =>
      chromeHklmOk ||
      chromeHkcuOk ||
      chromeUserInstallOk ||
      chromeLoadExtensionFallbackOk;

  /// Chrome MV3 extension is in a profile, load-extension shortcut, or HKLM path.
  bool get chromeEnforcementReady =>
      chromeExtensionInProfile ||
      chromeLoadExtensionFallbackOk ||
      chromeHklmOk ||
      chromeUserInstallOk;

  bool get edgeEnforcementReady =>
      edgeHklmOk ||
      edgeHkcuOk ||
      edgeUserInstallOk ||
      chromeLoadExtensionFallbackOk;

  /// Firefox extension reachable (policy and/or profile XPI sideload).
  bool get firefoxEnforcementReady => firefoxPolicyOk;

  bool get asideEnforcementReady =>
      !asideRequired || (asideForcelistOk && asidePolicyOk);

  bool get edgeOk =>
      edgeHklmOk ||
      edgeHkcuOk ||
      edgeUserInstallOk ||
      chromeLoadExtensionFallbackOk;

  bool get usesHkcuFallback =>
      chromeOk &&
      !chromeHklmOk &&
      (chromeHkcuOk || chromeUserInstallOk || chromeLoadExtensionFallbackOk);

  bool get allOk =>
      protectionOk &&
      (registryOk ||
          chromeHkcuOk ||
          chromeUserInstallOk ||
          chromeLoadExtensionFallbackOk);

  /// Browser blocking satisfied (Firefox + Chrome + Edge), including shortcut mode.
  bool get protectionOk =>
      firefoxEnforcementReady &&
      chromeEnforcementReady &&
      edgeEnforcementReady &&
      asideEnforcementReady;

  /// Repair decisions respect an intentional OFF without reporting protection.
  bool requestedStateSatisfied({ExtensionGuardPrefs? preferences}) {
    final ExtensionGuardPrefs prefs =
        preferences ?? ExtensionGuardPrefs.instance;
    return (prefs.isBrowserExplicitlyDisabled('chrome') ||
            chromeEnforcementReady) &&
        (prefs.isBrowserExplicitlyDisabled('edge') || edgeEnforcementReady) &&
        (prefs.isBrowserExplicitlyDisabled('firefox') ||
            firefoxEnforcementReady) &&
        (prefs.isBrowserExplicitlyDisabled('aside') || asideEnforcementReady);
  }

  /// Shorter diagnostics when desktop `--load-extension` shortcut is the active path.
  String get userFacingDetail {
    if (chromeLoadExtensionFallbackOk) {
      final StringBuffer sb = StringBuffer();
      sb.writeln(
        firefoxPolicyOk
            ? '✅ Firefox: policies.json + XPI + 프로필'
            : '⚠ Firefox: policies/XPI 일부 미완료',
      );
      sb.writeln('✅ Chrome/Edge: 시스템 바로가기에 보호 확장 연결됨');
      if (edgeOk && !edgeHklmOk && !edgeHkcuOk) {
        sb.writeln('Edge: Chrome과 동일하게 보호 모드');
      }
      return sb.toString().trim();
    }
    return detail;
  }
}
