import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../data/browser_extension_asset_manifest.dart';
import '../data/chromium_derivative_browsers.dart';
import 'app_logger.dart';
import 'browser_extension_export_service.dart';
import 'windows_extension_guard_service.dart';
import 'chrome_extension_identity.dart';
import 'chrome_extension_payload_service.dart';
import 'chrome_extension_state_probe.dart';
import 'chrome_extension_version.dart';
import 'chrome_load_extension_launcher.dart';
import 'extension_guard_prefs.dart';
import 'universal_browser_block_service.dart';
import 'windows_browser_bypass_closer_service.dart';
import 'windows_chrome_extension_registry_native.dart';
import 'windows_extension_self_heal_service.dart';
import 'windows_hidden_process.dart';
import 'windows_elevate_retry_helper.dart';

/// Aside · Vivaldi · Whale · Opera — Chromium MV3 배포 및 차단 연동.
final class ChromiumDerivativeExtensionService {
  ChromiumDerivativeExtensionService._();
  static final ChromiumDerivativeExtensionService instance =
      ChromiumDerivativeExtensionService._();

  static String sixVpnDir() => ChromeLoadExtensionLauncher.sixVpnDir;

  static String payloadDir(ChromiumDerivativeBrowserDef def) =>
      p.join(sixVpnDir(), def.payloadDirName);

  static String vbsPath(ChromiumDerivativeBrowserDef def) =>
      p.join(sixVpnDir(), def.vbsFileName);

  Future<bool> isInstalled(String browserId) async {
    final ChromiumDerivativeBrowserDef? def = chromiumDerivativeById(browserId);
    if (def == null) return false;
    for (final String path in def.exeCandidates) {
      if (path.isNotEmpty && await File(path).exists()) return true;
    }
    return false;
  }

  Future<DerivativeExtensionVerifyResult> verify(String browserId) async {
    final ChromiumDerivativeBrowserDef? def = chromiumDerivativeById(browserId);
    if (def == null) {
      return DerivativeExtensionVerifyResult(
        browserId: browserId,
        displayName: browserId,
        installed: false,
        extensionReady: false,
        policyReady: false,
        detail: '지원 목록에 없음',
      );
    }
    if (!Platform.isWindows) {
      return DerivativeExtensionVerifyResult(
        browserId: def.id,
        displayName: def.displayName,
        installed: false,
        extensionReady: false,
        policyReady: false,
        detail: 'Windows 전용',
      );
    }

    final bool installed = await isInstalled(def.id);
    if (!installed) {
      return DerivativeExtensionVerifyResult(
        browserId: def.id,
        displayName: def.displayName,
        installed: false,
        extensionReady: false,
        policyReady: false,
        detail: '${def.displayName} 미설치',
      );
    }

    final ChromeExtensionProbeResult probe =
        await ChromeExtensionStateProbe.probe(browser: def.id);
    final String extId = ChromeExtensionIdentity.extensionId;
    final bool userPolicyForcelist = await _regForcelistHasOurId(
      '${def.policyRootHkcu}\\ExtensionInstallForcelist',
    );
    final bool userPolicySettings = await _regValueContains(
      def.policyRootHkcu,
      'ExtensionSettings',
      extId,
    );
    final bool machinePolicyForcelist =
        def.id == 'aside' &&
        await _regForcelistHasOurId(
          def.policyRootHklm + r'\ExtensionInstallForcelist',
        );
    final bool machinePolicySettings =
        def.id == 'aside' &&
        await _regValueContains(def.policyRootHklm, 'ExtensionSettings', extId);
    final bool policyForcelist = machinePolicyForcelist || userPolicyForcelist;
    final bool policySettings = machinePolicySettings || userPolicySettings;
    final String effectiveFolder = def.id == 'aside'
        ? p.join(
            Platform.environment['ProgramData'] ?? r'C:\ProgramData',
            'SixVPNBlocker',
            'aside_blocker',
          )
        : payloadDir(def);
    bool payload = false;
    try {
      final document = jsonDecode(
        await File(p.join(effectiveFolder, 'manifest.json')).readAsString(),
      );
      payload =
          document['key'] == ChromeExtensionIdentity.manifestPublicKeyBase64;
    } catch (_) {}
    final bool launcher = await File(vbsPath(def)).exists();

    final bool asideMachinePolicyReady =
        def.id != 'aside' || (machinePolicyForcelist && machinePolicySettings);
    final bool extensionReady =
        asideMachinePolicyReady && !probe.extensionNotPresent && payload;

    return DerivativeExtensionVerifyResult(
      browserId: def.id,
      displayName: def.displayName,
      installed: true,
      extensionReady: extensionReady,
      policyReady: policyForcelist && policySettings,
      launcherReady: launcher && payload,
      inProfile: !probe.extensionNotPresent,
      detail: def.id == 'aside'
          ? "${probe.detail}; HKLM force-install is ${machinePolicyForcelist && machinePolicySettings ? 'ready' : 'missing'}"
          : probe.detail,
    );
  }

  Future<Map<String, DerivativeExtensionVerifyResult>> verifyInstalled() async {
    final Map<String, DerivativeExtensionVerifyResult> out =
        <String, DerivativeExtensionVerifyResult>{};
    for (final ChromiumDerivativeBrowserDef def
        in kChromiumDerivativeBrowsers) {
      if (!await isInstalled(def.id)) continue;
      out[def.id] = await verify(def.id);
    }
    return out;
  }

  Future<List<DerivativeExtensionApplyResult>> applyAllInstalled({
    String reason = 'auto',
    bool force = false,
  }) async {
    final List<DerivativeExtensionApplyResult> results =
        <DerivativeExtensionApplyResult>[];
    for (final ChromiumDerivativeBrowserDef def
        in kChromiumDerivativeBrowsers) {
      if (!await isInstalled(def.id) && !force) continue;
      results.add(await apply(def.id, reason: reason, force: force));
    }
    return results;
  }

  Future<DerivativeExtensionApplyResult> apply(
    String browserId, {
    String reason = 'auto',
    bool force = false,
  }) async {
    final ChromiumDerivativeBrowserDef? def = chromiumDerivativeById(browserId);
    if (def == null) {
      return DerivativeExtensionApplyResult(
        browserId: browserId,
        ok: false,
        message: '지원하지 않는 브라우저',
      );
    }
    if (!Platform.isWindows) {
      return DerivativeExtensionApplyResult(
        browserId: def.id,
        ok: false,
        message: 'Windows 전용',
      );
    }
    if (ExtensionGuardPrefs.instance.isBrowserExplicitlyDisabled(def.id)) {
      return DerivativeExtensionApplyResult(
        browserId: def.id,
        ok: false,
        skipped: true,
        message: '${def.displayName} 확장은 앱에서 비활성화했습니다.',
      );
    }
    if (!await isInstalled(def.id) && !force) {
      return DerivativeExtensionApplyResult(
        browserId: def.id,
        ok: false,
        skipped: true,
        message: '${def.displayName} 미설치',
      );
    }

    final List<String> actions = <String>[];
    try {
      final String? folder = await _ensurePayload(def);
      if (folder == null) {
        return DerivativeExtensionApplyResult(
          browserId: def.id,
          ok: false,
          message: '${def.displayName} 확장 파일 준비 실패',
        );
      }
      actions.add('payload');

      final String extId = ChromeExtensionIdentity.extensionId;
      final String ver = await ChromeExtensionVersion.bundled();
      await _writeUpdatesXml(folder, extId, ver);
      actions.add('updates_xml');

      final bool regOk =
          await WindowsChromeExtensionRegistryNative.registerDerivativeUserKey(
            userExtSubKey: def.userExtRegSubKey,
            extensionId: extId,
            extensionFolder: folder,
            version: ver,
            label: def.displayName,
          );
      if (regOk) actions.add('user_reg');

      await WindowsExtensionSelfHealService.instance.reapplyHkcuOnly(
        sourceFolder: folder,
      );
      actions.add('hkcu_policy_mirror');

      await UniversalBrowserBlockService.instance.syncNow(
        reason: 'derivative_${def.id}_$reason',
      );
      actions.add('url_blocklist');
      await WindowsBrowserBypassCloserService.instance.applyAll();
      actions.add('bypass_closer');

      final bool launcherOk =
          await ChromeLoadExtensionLauncher.installDerivative(
            def: def,
            extensionFolder: folder,
          );
      if (launcherOk) actions.add('launcher_vbs');

      final DerivativeExtensionVerifyResult check = await verify(def.id);
      AppLogger.instance.info(
        'derivative_ext ${def.id}: ok=${check.extensionReady} $actions',
      );

      return DerivativeExtensionApplyResult(
        browserId: def.id,
        ok: check.extensionReady,
        message: check.extensionReady
            ? '${def.displayName} 확장·URL 차단·삭제 방지 적용됨'
            : '${def.displayName} 일부 적용 — 브라우저 완전 종료 후 재실행',
        actions: actions,
        verify: check,
      );
    } catch (e, st) {
      AppLogger.instance.warn('derivative_ext ${def.id} failed: $e\n$st');
      return DerivativeExtensionApplyResult(
        browserId: def.id,
        ok: false,
        message: '${def.displayName} 확장 오류: $e',
        actions: actions,
      );
    }
  }

  /// Installs the Aside extension under the machine policy after validating
  /// the signed CRX/update manifest that Chromium consumes.
  Future<DerivativeExtensionApplyResult> installAside({
    String reason = 'user',
  }) async {
    final BrowserExtensionExportResult payload =
        await BrowserExtensionExportService.exportAssets(
          assetPaths: BrowserExtensionAssetManifest.aside,
          subdirName: 'aside_blocker',
        );
    if (!payload.ok) {
      return DerivativeExtensionApplyResult(
        browserId: 'aside',
        ok: false,
        message: 'Aside 서명 패키지 준비 실패: ${payload.error}',
      );
    }
    // Explicit app action only: automatic repair must retain the OFF marker.
    await ExtensionGuardPrefs.instance.setBrowserEnabled('aside', true);
    final ExtensionGuardResult applied = await WindowsExtensionGuardService
        .instance
        .runElevatedGuard(
          chromeExtensionFolder: payload.path,
          onlyBrowserId: 'aside',
        );
    if (!applied.ok) {
      return DerivativeExtensionApplyResult(
        browserId: 'aside',
        ok: false,
        message: applied.message,
      );
    }
    final DerivativeExtensionVerifyResult check = await verify('aside');
    return DerivativeExtensionApplyResult(
      browserId: 'aside',
      ok: check.extensionReady,
      message: check.extensionReady
          ? 'Aside 확장 파일과 정책 확인됨. 실제 URL 차단은 별도 검증이 필요합니다.'
          : '관리자 설치 정책은 기록했지만 Aside의 확장 수락은 확인되지 않았습니다.',
      actions: <String>['signed_package_exported', 'hklm_force_installed'],
      verify: check,
    );
  }

  static String asideInstallScript(
    String extId, {
    required String updateUrl,
    String registryRoot = r'HKLM:\SOFTWARE\Policies\Chromium',
  }) =>
      r'''
$ErrorActionPreference = 'Stop'
$id = '__FOCUSFENSE_EXTENSION_ID__'
$root = '__FOCUSFENSE_REGISTRY_ROOT__'
$url = '__FOCUSFENSE_UPDATE_URL__'
$forcelist = Join-Path $root 'ExtensionInstallForcelist'
try {
  if (-not (Test-Path -LiteralPath $forcelist)) {
    New-Item -Path $forcelist -Force | Out-Null
  }
  $found = $false
  $values = Get-ItemProperty -LiteralPath $forcelist
  foreach ($property in $values.PSObject.Properties) {
    $name = $property.Name
    if ($name -match '^\d+$' -and [string]$property.Value -match ('^' + [regex]::Escape($id) + '(;|$)')) {
      Set-ItemProperty -LiteralPath $forcelist -Name $name -Value ($id + ';' + $url) -Type String
      $found = $true
    }
  }
  if (-not $found) {
    $n = 1
    foreach ($property in $values.PSObject.Properties) {
      if ($property.Name -match '^\d+$' -and [int]$property.Name -ge $n) {
        $n = [int]$property.Name + 1
      }
    }
    Set-ItemProperty -LiteralPath $forcelist -Name ([string]$n) -Value ($id + ';' + $url) -Type String
  }
  $raw = (Get-ItemProperty -LiteralPath $root -Name ExtensionSettings -ErrorAction SilentlyContinue).ExtensionSettings
  $settings = if ($raw) { ConvertFrom-Json -InputObject $raw } else { New-Object PSObject }
  $settings | Add-Member -MemberType NoteProperty -Name $id -Value @{ installation_mode='force_installed'; update_url=$url; override_update_url=$true; toolbar_pin='force_pinned' } -Force
  Set-ItemProperty -LiteralPath $root -Name ExtensionSettings -Value (ConvertTo-Json $settings -Compress) -Type String
  Set-Content -LiteralPath '__FOCUSFENSE_EXIT_PATH__' -Value '0' -Encoding ASCII
  exit 0
} catch {
  Set-Content -LiteralPath '__FOCUSFENSE_EXIT_PATH__' -Value '1' -Encoding ASCII
  exit 1
}
'''
          .replaceAll('__FOCUSFENSE_EXTENSION_ID__', extId)
          .replaceAll(
            '__FOCUSFENSE_UPDATE_URL__',
            updateUrl.replaceAll("'", "''"),
          )
          .replaceAll(
            '__FOCUSFENSE_REGISTRY_ROOT__',
            registryRoot.replaceAll("'", "''"),
          );

  /// Removes only FocusFense's Aside force-install registration. URLBlocklist
  /// values and other Chromium policies are deliberately preserved.
  Future<DerivativeExtensionApplyResult> uninstallAside() async {
    const String browserId = 'aside';
    const String extId = ChromeExtensionIdentity.extensionId;
    if (!Platform.isWindows) {
      return const DerivativeExtensionApplyResult(
        browserId: browserId,
        ok: false,
        message: 'Windows 전용',
      );
    }
    await ExtensionGuardPrefs.instance.setBrowserEnabled('aside', false);
    final ChromiumDerivativeBrowserDef def = chromiumDerivativeById(browserId)!;
    final String programData =
        Platform.environment['ProgramData'] ?? r'C:\ProgramData';
    final Directory work = Directory(p.join(programData, 'SixVPNBlocker'));
    await work.create(recursive: true);
    final String scriptPath = p.join(
      work.path,
      'aside_extension_uninstall.ps1',
    );
    final String resultPath = p.join(
      work.path,
      'aside_extension_uninstall.exit',
    );
    final File script = File(scriptPath);
    await script.writeAsString(
      asideUninstallScript(extId, resultPath: resultPath),
      flush: true,
    );

    // HKLM policy removal is performed only after an explicit in-app action
    // and Windows' normal UAC consent. No browser process is stopped.
    final int? exit = await WindowsElevateRetryHelper.runElevated(
      ps64Exe: p.join(
        Platform.environment['WINDIR'] ?? r'C:\Windows',
        'System32',
        'WindowsPowerShell',
        'v1.0',
        'powershell.exe',
      ),
      scriptPath: scriptPath,
      exitSentinelFile: File(resultPath),
    );
    if (exit != 0) {
      return DerivativeExtensionApplyResult(
        browserId: browserId,
        ok: false,
        message: exit == null
            ? '관리자 승인 또는 정책 수정이 완료되지 않았습니다.'
            : 'Aside 강제 설치 정책 제거 실패 (exit $exit)',
      );
    }

    final String? user = Platform.environment['LOCALAPPDATA'];
    final String userPolicy = def.policyRootHkcu;
    await _removeUserForceInstall(userPolicy, extId);
    if (user != null) {
      final Directory appData = Directory(p.join(user, 'SixVPNBlocker'));
      for (final String name in <String>[
        def.vbsFileName,
        def.vbsFileName.replaceAll('.vbs', '.bat'),
      ]) {
        final File launcher = File(p.join(appData.path, name));
        if (await launcher.exists()) await launcher.delete();
      }
      // The shared payload is retained for rollback and other Chromium apps.
    }
    await _removeAsideExternalRegistryRegistration(def, extId);
    return const DerivativeExtensionApplyResult(
      browserId: browserId,
      ok: true,
      message: 'Aside 확장 강제 설치 해제됨. URL 차단 규칙은 유지됩니다.',
      actions: <String>[
        'hklm_force_install_removed',
        'hkcu_force_install_removed',
      ],
    );
  }

  static String asideUninstallScript(
    String extId, {
    required String resultPath,
    String registryRoot = r'HKLM:\SOFTWARE\Policies\Chromium',
  }) =>
      r'''
$ErrorActionPreference = 'Stop'
$id = '__FOCUSFENSE_EXTENSION_ID__'
$root = '__FOCUSFENSE_REGISTRY_ROOT__'
$fl = Join-Path $root 'ExtensionInstallForcelist'
try {
  if (Test-Path -LiteralPath $fl) {
    $values = Get-ItemProperty -LiteralPath $fl
    foreach ($property in @($values.PSObject.Properties)) {
      $name = $property.Name
      if ($name -match '^\d+$' -and [string]$property.Value -match ('^' + [regex]::Escape($id) + '(;|$)')) {
        Remove-ItemProperty -LiteralPath $fl -Name $name -Force
      }
    }
  }
  if (Test-Path -LiteralPath $root) {
    $raw = (Get-ItemProperty -LiteralPath $root -Name ExtensionSettings -ErrorAction SilentlyContinue).ExtensionSettings
    if ($raw) {
      $settings = ConvertFrom-Json -InputObject $raw
      $settings.PSObject.Properties.Remove($id)
      if ($settings.PSObject.Properties.Count) {
        Set-ItemProperty -LiteralPath $root -Name ExtensionSettings -Value (ConvertTo-Json $settings -Compress) -Type String
      } else {
        Remove-ItemProperty -LiteralPath $root -Name ExtensionSettings -ErrorAction SilentlyContinue
      }
    }
  }
  Set-Content -LiteralPath '__FOCUSFENSE_EXIT_PATH__' -Value '0' -Encoding ASCII
  exit 0
} catch {
  Set-Content -LiteralPath '__FOCUSFENSE_EXIT_PATH__' -Value '1' -Encoding ASCII
  exit 1
}
'''
          .replaceAll('__FOCUSFENSE_EXTENSION_ID__', extId)
          .replaceAll(
            '__FOCUSFENSE_REGISTRY_ROOT__',
            registryRoot.replaceAll("'", "''"),
          )
          .replaceAll(
            '__FOCUSFENSE_EXIT_PATH__',
            resultPath.replaceAll("'", "''"),
          );

  static Future<void> _removeUserForceInstall(
    String policyRoot,
    String extId,
  ) async {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final ProcessResult result = await windowsRunHidden(
      p.join(windir, 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe'),
      <String>[
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        "\$id='$extId'; \$root='${policyRoot.replaceAll("'", "''")}'; "
            r"$fl=Join-Path $root 'ExtensionInstallForcelist'; if(Test-Path $fl){$k=Get-Item $fl; foreach($n in $k.GetValueNames()){if(([string]$k.GetValue($n)) -match ('^'+[regex]::Escape($id)+'(;|$)')){Remove-ItemProperty $fl -Name $n -Force}}}; "
            r"$raw=(Get-ItemProperty $root -Name ExtensionSettings -ErrorAction SilentlyContinue).ExtensionSettings; if($raw){$s=ConvertFrom-Json $raw; $s.PSObject.Properties.Remove($id); if($s.PSObject.Properties.Count){Set-ItemProperty $root -Name ExtensionSettings -Value (ConvertTo-Json $s -Compress)}else{Remove-ItemProperty $root -Name ExtensionSettings -ErrorAction SilentlyContinue}}",
      ],
    );
    if (result.exitCode != 0) {
      throw StateError('Remove HKCU force-install policy failed');
    }
  }

  static Future<void> _removeAsideExternalRegistryRegistration(
    ChromiumDerivativeBrowserDef def,
    String extId,
  ) async {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final String reg = p.join(windir, 'System32', 'reg.exe');
    final String key = def.userExtKeyHkcu(extId);
    final ProcessResult query = await windowsRunHidden(reg, <String>[
      'query',
      key,
    ]);
    if (query.exitCode != 0 ||
        !'${query.stdout}'.toLowerCase().contains('aside_blocker')) {
      return;
    }
    final ProcessResult removed = await windowsRunHidden(reg, <String>[
      'delete',
      key,
      '/f',
    ]);
    if (removed.exitCode != 0) {
      throw StateError('Remove Aside external extension registration failed');
    }
  }

  Future<String?> _ensurePayload(ChromiumDerivativeBrowserDef def) async {
    final String dest = payloadDir(def);
    final List<String> assetPaths = switch (def.id) {
      'aside' => BrowserExtensionAssetManifest.aside,
      'opera' || 'opera_gx' => BrowserExtensionAssetManifest.opera,
      _ => BrowserExtensionAssetManifest.chrome,
    };
    if (await _payloadComplete(dest, assetPaths)) {
      return dest;
    }
    final Directory dir = Directory(dest);
    if (await dir.exists()) {
      await dir.delete(recursive: true);
    }
    await dir.create(recursive: true);

    for (final String assetPath in assetPaths) {
      final ByteData data = await rootBundle.load(assetPath);
      final String name = p.basename(assetPath);
      final File f = File(p.join(dest, name));
      await f.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
    if (!await File(p.join(dest, 'manifest.json')).exists()) {
      final String? chrome =
          await ChromeExtensionPayloadService.resolveValidSource();
      if (chrome == null) return null;
      await for (final FileSystemEntity e in Directory(
        chrome,
      ).list(recursive: true)) {
        if (e is! File) continue;
        final String rel = p.relative(e.path, from: chrome);
        final File out = File(p.join(dest, rel));
        await out.parent.create(recursive: true);
        await e.copy(out.path);
      }
    }
    if (!await File(p.join(dest, 'manifest.json')).exists()) {
      return null;
    }
    return dest;
  }

  static Future<bool> _payloadComplete(
    String folder,
    List<String> assetPaths,
  ) async {
    for (final String assetPath in assetPaths) {
      final File file = File(p.join(folder, p.basename(assetPath)));
      if (!await file.exists()) {
        return false;
      }
      final ByteData expected = await rootBundle.load(assetPath);
      if (!listEquals(
        await file.readAsBytes(),
        expected.buffer.asUint8List(
          expected.offsetInBytes,
          expected.lengthInBytes,
        ),
      )) {
        return false;
      }
    }
    return true;
  }

  static Future<void> _writeUpdatesXml(
    String folder,
    String extId,
    String ver,
  ) async {
    final String norm = p.normalize(folder).replaceAll(r'\', '/');
    final String folderUrl = norm.length >= 2 && norm[1] == ':'
        ? 'file:///$norm/'
        : 'file:///$norm/';
    final File crx = File('$folder.crx');
    final String codebase = await crx.exists()
        ? 'file:///${crx.path.replaceAll(r'\', '/').replaceAll(' ', '%20')}'
        : '${folderUrl}manifest.json';
    final String xml =
        "<?xml version='1.0' encoding='UTF-8'?>"
        "<gupdate xmlns='http://www.google.com/update2/response' protocol='2.0'>"
        "<app appid='$extId'>"
        "<updatecheck codebase='$codebase' version='$ver' />"
        '</app></gupdate>';
    await File(p.join(folder, 'updates.xml')).writeAsString(xml);
  }

  static Future<bool> _regForcelistHasOurId(String keyPath) async {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final ProcessResult pr = await windowsRunHidden(
      p.join(windir, 'System32', 'reg.exe'),
      <String>['query', keyPath],
    );
    if (pr.exitCode != 0) return false;
    return '${pr.stdout}'.contains(ChromeExtensionIdentity.extensionId);
  }

  static Future<bool> _regValueContains(
    String keyPath,
    String valueName,
    String needle,
  ) async {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final ProcessResult pr = await windowsRunHidden(
      p.join(windir, 'System32', 'reg.exe'),
      <String>['query', keyPath, '/v', valueName],
    );
    if (pr.exitCode != 0) return false;
    return '${pr.stdout}'.contains(needle);
  }
}

final class DerivativeExtensionVerifyResult {
  const DerivativeExtensionVerifyResult({
    required this.browserId,
    required this.displayName,
    required this.installed,
    required this.extensionReady,
    required this.policyReady,
    required this.detail,
    this.launcherReady = false,
    this.inProfile = false,
  });

  final String browserId;
  final String displayName;
  final bool installed;
  final bool extensionReady;
  final bool policyReady;
  final bool launcherReady;
  final bool inProfile;
  final String detail;

  bool get pluginSupportReady => !installed || extensionReady;
}

final class DerivativeExtensionApplyResult {
  const DerivativeExtensionApplyResult({
    required this.browserId,
    required this.ok,
    required this.message,
    this.skipped = false,
    this.actions = const <String>[],
    this.verify,
  });

  final String browserId;
  final bool ok;
  final bool skipped;
  final String message;
  final List<String> actions;
  final DerivativeExtensionVerifyResult? verify;
}
