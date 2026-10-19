import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../data/browser_extension_asset_manifest.dart';
import 'app_logger.dart';
import 'chrome_extension_identity.dart';
import 'chrome_extension_payload_service.dart';
import 'chrome_extension_state_probe.dart';
import 'chrome_extension_version.dart';
import 'chrome_load_extension_launcher.dart';
import 'universal_browser_block_service.dart';
import 'windows_browser_bypass_closer_service.dart';
import 'windows_chrome_extension_registry_native.dart';
import 'windows_extension_self_heal_service.dart';
import 'windows_hidden_process.dart';

/// Brave 전용 MV3 확장 — Chrome과 동일 ID·payload, Brave 레지스트리·실행기에 설치.
final class BraveExtensionInstallService {
  BraveExtensionInstallService._();
  static final BraveExtensionInstallService instance =
      BraveExtensionInstallService._();

  static const String kBravePolicyForcelist =
      r'HKCU\SOFTWARE\Policies\BraveSoftware\Brave-Browser\ExtensionInstallForcelist';
  static const String kBravePolicyRoot =
      r'HKCU\SOFTWARE\Policies\BraveSoftware\Brave-Browser';
  static const String kBraveUserExtKey =
      r'HKCU\Software\BraveSoftware\Brave-Browser\Extensions';

  static String get stableBraveExtDir =>
      p.join(ChromeLoadExtensionLauncher.sixVpnDir, 'brave_blocker');

  static List<String> get _braveExeCandidates => <String>[
    p.join(
      Platform.environment['ProgramFiles'] ?? r'C:\Program Files',
      'BraveSoftware',
      'Brave-Browser',
      'Application',
      'brave.exe',
    ),
    p.join(
      Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)',
      'BraveSoftware',
      'Brave-Browser',
      'Application',
      'brave.exe',
    ),
    p.join(
      Platform.environment['LOCALAPPDATA'] ?? '',
      'BraveSoftware',
      'Brave-Browser',
      'Application',
      'brave.exe',
    ),
  ];

  Future<bool> isBraveInstalled() async {
    for (final String raw in _braveExeCandidates) {
      if (raw.isEmpty) continue;
      if (await File(raw).exists()) return true;
    }
    return false;
  }

  Future<BraveExtensionVerifyResult> verify() async {
    if (!Platform.isWindows) {
      return const BraveExtensionVerifyResult(
        installed: false,
        extensionReady: false,
        policyReady: false,
        launcherReady: false,
        detail: 'Windows 전용',
      );
    }
    final bool installed = await isBraveInstalled();
    if (!installed) {
      return const BraveExtensionVerifyResult(
        installed: false,
        extensionReady: false,
        policyReady: false,
        launcherReady: false,
        detail: 'Brave 미설치',
      );
    }

    final ChromeExtensionProbeResult probe =
        await ChromeExtensionStateProbe.probe(browser: 'brave');
    final bool policyForcelist = await _regForcelistHasOurId(
      kBravePolicyForcelist,
    );
    final bool policySettings = await _regValueContains(
      kBravePolicyRoot,
      'ExtensionSettings',
      ChromeExtensionIdentity.extensionId,
    );
    final bool userReg = await _regKeyExists(
      '${kBraveUserExtKey}\\${ChromeExtensionIdentity.extensionId}',
    );
    final bool payload = await File(
      p.join(stableBraveExtDir, 'manifest.json'),
    ).exists();
    final bool launcher = await File(
      ChromeLoadExtensionLauncher.braveVbsPath,
    ).exists();

    final bool extensionReady =
        !probe.extensionNotPresent || policyForcelist || userReg;
    final bool policyReady = policyForcelist && policySettings;

    return BraveExtensionVerifyResult(
      installed: true,
      extensionReady: extensionReady && payload,
      policyReady: policyReady,
      launcherReady: launcher && payload,
      inProfile: !probe.extensionNotPresent,
      detail: probe.detail,
    );
  }

  /// Export → 레지스트리 → 정책(derivative) → Brave 보호 실행기.
  Future<BraveExtensionApplyResult> apply({
    String reason = 'auto',
    bool force = false,
  }) async {
    if (!Platform.isWindows) {
      return const BraveExtensionApplyResult(ok: false, message: 'Windows 전용');
    }
    if (!await isBraveInstalled() && !force) {
      return const BraveExtensionApplyResult(
        ok: false,
        skipped: true,
        message: 'Brave 미설치 — 확장 준비만 완료',
      );
    }

    final List<String> actions = <String>[];
    try {
      final String? folder = await _ensurePayload();
      if (folder == null) {
        return const BraveExtensionApplyResult(
          ok: false,
          message: 'Brave 확장 파일 준비 실패',
        );
      }
      actions.add('payload');

      final String extId = ChromeExtensionIdentity.extensionId;
      final String ver = await ChromeExtensionVersion.bundled();
      await _writeUpdatesXml(folder, extId, ver);
      actions.add('updates_xml');

      final bool braveRegOk =
          await WindowsChromeExtensionRegistryNative.registerBrave(
            extensionId: extId,
            extensionFolder: folder,
            version: ver,
          );
      if (braveRegOk) actions.add('brave_user_reg');

      // Chrome self-heal already mirrors policy to BraveSoftware root — refresh.
      await WindowsExtensionSelfHealService.instance.reapplyHkcuOnly(
        sourceFolder: folder,
      );
      actions.add('hkcu_policy_mirror');

      await UniversalBrowserBlockService.instance.syncNow(
        reason: 'brave_ext_$reason',
      );
      actions.add('url_blocklist');
      await WindowsBrowserBypassCloserService.instance.applyAll();
      actions.add('bypass_closer');

      final LoadExtensionLauncherResult launcher =
          await ChromeLoadExtensionLauncher.installBrave(
            extensionFolder: folder,
          );
      if (launcher.ok) actions.add('brave_launcher');

      final BraveExtensionVerifyResult check = await verify();
      AppLogger.instance.info(
        'brave_ext_install: ok=${check.extensionReady} actions=$actions',
      );

      return BraveExtensionApplyResult(
        ok: check.extensionReady,
        message: check.extensionReady
            ? 'Brave 확장·URL 차단 적용됨'
            : 'Brave 확장 일부만 적용 — Brave 완전 종료 후 다시 열기',
        actions: actions,
        verify: check,
      );
    } catch (e, st) {
      AppLogger.instance.warn('brave_ext_install failed: $e\n$st');
      return BraveExtensionApplyResult(
        ok: false,
        message: 'Brave 확장 설치 오류: $e',
        actions: actions,
      );
    }
  }

  Future<String?> _ensurePayload() async {
    final Directory dest = Directory(stableBraveExtDir);
    if (await File(p.join(dest.path, 'manifest.json')).exists()) {
      return dest.path;
    }
    if (await dest.exists()) {
      await dest.delete(recursive: true);
    }
    await dest.create(recursive: true);

    for (final String assetPath in BrowserExtensionAssetManifest.brave) {
      final ByteData data = await rootBundle.load(assetPath);
      final String name = p.basename(assetPath);
      final File f = File(p.join(dest.path, name));
      await f.writeAsBytes(
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        flush: true,
      );
    }
    if (!await File(p.join(dest.path, 'manifest.json')).exists()) {
      final String? chrome =
          await ChromeExtensionPayloadService.resolveValidSource();
      if (chrome == null) return null;
      final Directory src = Directory(chrome);
      await for (final FileSystemEntity e in src.list(recursive: true)) {
        if (e is! File) continue;
        final String rel = p.relative(e.path, from: chrome);
        final File out = File(p.join(dest.path, rel));
        await out.parent.create(recursive: true);
        await e.copy(out.path);
      }
    }
    if (!await File(p.join(dest.path, 'manifest.json')).exists()) {
      return null;
    }
    return dest.path;
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

  static Future<bool> _regKeyExists(String keyPath) async {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final ProcessResult pr = await windowsRunHidden(
      p.join(windir, 'System32', 'reg.exe'),
      <String>['query', keyPath],
    );
    return pr.exitCode == 0;
  }
}

final class BraveExtensionVerifyResult {
  const BraveExtensionVerifyResult({
    required this.installed,
    required this.extensionReady,
    required this.policyReady,
    required this.launcherReady,
    required this.detail,
    this.inProfile = false,
  });

  final bool installed;
  final bool extensionReady;
  final bool policyReady;
  final bool launcherReady;
  final bool inProfile;
  final String detail;

  bool get pluginSupportReady => !installed || extensionReady;
}

final class BraveExtensionApplyResult {
  const BraveExtensionApplyResult({
    required this.ok,
    required this.message,
    this.skipped = false,
    this.actions = const <String>[],
    this.verify,
  });

  final bool ok;
  final bool skipped;
  final String message;
  final List<String> actions;
  final BraveExtensionVerifyResult? verify;
}
