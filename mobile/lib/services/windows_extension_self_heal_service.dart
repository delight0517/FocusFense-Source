import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/browser_extension_asset_manifest.dart';
import 'app_logger.dart';
import 'browser_extension_export_service.dart';
import 'chrome_extension_identity.dart';
import 'extension_guard_prefs.dart';
import 'silent_bootstrap_context.dart';
import 'chrome_extension_version.dart';
import 'chrome_load_extension_launcher.dart';
import 'windows_chrome_extension_install_service.dart';
import 'windows_chrome_extension_registry_native.dart';
import '../data/chromium_derivative_browsers.dart';
import 'windows_browser_bypass_closer_service.dart';
import 'windows_extension_guard_service.dart';
import 'windows_hidden_process.dart';
import 'windows_policy_acl_unlock_service.dart';

enum ExtensionProtectionTier {
  fullHklm,
  hkcuChromeEdge,
  partial,
  firefoxOnly,
  failed,
  unsupported,
  unknown,
}

final class ExtensionSelfHealResult {
  const ExtensionSelfHealResult({
    required this.tier,
    required this.message,
    this.verify,
    this.hkcuApplied = false,
  });

  final ExtensionProtectionTier tier;
  final String message;
  final ExtensionPolicyVerifyResult? verify;
  final bool hkcuApplied;

  bool get isAcceptable =>
      tier == ExtensionProtectionTier.fullHklm ||
      tier == ExtensionProtectionTier.hkcuChromeEdge ||
      tier == ExtensionProtectionTier.partial;
}

final class HkcuExtensionApplyResult {
  const HkcuExtensionApplyResult({
    required this.ok,
    required this.message,
    this.extensionPath,
  });

  final bool ok;
  final String message;
  final String? extensionPath;
}

/// Chrome/Edge extension self-heal: HKCU policies (no UAC) then elevated HKLM retry.
final class WindowsExtensionSelfHealService {
  WindowsExtensionSelfHealService._();
  static final WindowsExtensionSelfHealService instance =
      WindowsExtensionSelfHealService._();

  static const Duration kBackgroundCooldown = Duration(seconds: 90);

  DateTime? _lastBackgroundRun;
  bool _running = false;

  static String get localChromeBlockerDir {
    final String la =
        Platform.environment['LOCALAPPDATA'] ?? r'C:\Users\Public';
    return p.join(la, 'SixVPNBlocker', 'chrome_blocker');
  }

  void clearCooldown() => _lastBackgroundRun = null;

  Future<ExtensionSelfHealResult> runIfNeeded({
    bool attemptElevated = false,
    void Function(String status)? onStatus,
  }) async {
    if (!Platform.isWindows) {
      return const ExtensionSelfHealResult(
        tier: ExtensionProtectionTier.unsupported,
        message: 'Windows 전용',
      );
    }
    final ExtensionPolicyVerifyResult before =
        await WindowsExtensionGuardService.verifyAllPolicies();

    if (before.requestedStateSatisfied()) {
      return ExtensionSelfHealResult(
        tier: _tierFromVerify(before),
        message: '선택한 확장 상태가 충족되었습니다. 앱에서 끈 확장은 복구하지 않습니다.',
        verify: before,
      );
    }
    final DateTime now = DateTime.now();
    if (_lastBackgroundRun != null &&
        now.difference(_lastBackgroundRun!) < kBackgroundCooldown) {
      return ExtensionSelfHealResult(
        tier: ExtensionProtectionTier.unknown,
        message: '백그라운드 복구 대기 중 — 설정에서 「Chrome 열기」를 누르면 즉시 재시도됩니다.',
        verify: before,
      );
    }
    return runSelfHeal(
      attemptElevated: attemptElevated,
      onStatus: onStatus,
      verifyBefore: before,
      userInitiated: attemptElevated,
    );
  }

  /// [userInitiated] true = 쉬운 설치·수동 복구 (쿨다운 없음).
  Future<ExtensionSelfHealResult> runSelfHeal({
    bool attemptElevated = true,
    void Function(String status)? onStatus,
    ExtensionPolicyVerifyResult? verifyBefore,
    String? chromeSourceOverride,
    bool userInitiated = true,
  }) async {
    if (!Platform.isWindows) {
      return const ExtensionSelfHealResult(
        tier: ExtensionProtectionTier.unsupported,
        message: 'Windows 전용',
      );
    }
    if (_running) {
      return ExtensionSelfHealResult(
        tier: ExtensionProtectionTier.unknown,
        message: '이미 복구 실행 중',
        verify: verifyBefore,
      );
    }

    if (ExtensionGuardPrefs.instance.areManagedBrowsersExplicitlyDisabled) {
      return const ExtensionSelfHealResult(
        tier: ExtensionProtectionTier.unknown,
        message: '관리 대상 확장을 앱에서 모두 껐습니다. 자동 재설치를 실행하지 않습니다.',
      );
    }

    _running = true;
    if (!userInitiated) {
      _lastBackgroundRun = DateTime.now();
    }
    void status(String s) {
      onStatus?.call(s);
      AppLogger.instance.info('extension_self_heal: $s');
    }

    bool hkcuApplied = false;
    try {
      ExtensionPolicyVerifyResult v =
          verifyBefore ??
          await WindowsExtensionGuardService.verifyAllPolicies();

      // ── ACL preflight ──────────────────────────────────────────────────
      // Some machines have `HKCU\SOFTWARE\Policies\Google\Chrome` ACL-locked
      // (owner=SYSTEM, user=ReadKey). Every `reg add` then fails silently and
      // the force-install policy never lands → user can delete the plugin and
      // URLBlocklist stays empty. Probe + one-shot UAC unlock fixes it.
      final bool aclWritable = await WindowsPolicyAclUnlockService.instance
          .hkcuPoliciesWritable();
      if (!aclWritable && (userInitiated || attemptElevated)) {
        status('① HKCU 정책 키 잠금 감지 — UAC로 잠금 해제 시도…');
        final bool unlocked = await WindowsPolicyAclUnlockService.instance
            .runElevatedUnlockIfNeeded();
        status(
          unlocked ? '① HKCU 정책 키 잠금 해제됨' : '① 잠금 해제 실패/거부 — 정책 일부 미적용 가능',
        );
      }

      // The old gate was `!v.chromeOk || !v.edgeOk`. But chromeOk is satisfied
      // by HKCU\Software\Google\Chrome\Extensions\<id> existing — which is the
      // EXTENSION key, not the force-install policy. With the gate as-is, a
      // user who has the extension folder registered but no forcelist sees
      // chromeOk=true and we skip writing `ExtensionInstallForcelist` → the
      // plugin stays deletable AND the URLBlocklist policy keys are never
      // refreshed. Apply HKCU whenever ANY required policy piece is missing.
      //
      // @incident: BROWSER_BLOCK_PIPELINE_POSTMORTEM §2.4 — this is a
      // recurring regression. Do NOT fold `forcelistMissing` back into
      // `chromeOk`. Their independence is the safety property.
      final bool chromeWanted = !ExtensionGuardPrefs.instance
          .isBrowserExplicitlyDisabled('chrome');
      final bool edgeWanted = !ExtensionGuardPrefs.instance
          .isBrowserExplicitlyDisabled('edge');
      final bool forcelistMissing =
          chromeWanted && !v.chromeForcelistOk && !v.chromeHkcuForcelistOk ||
          edgeWanted && !v.edgeForcelistOk && !v.edgeHkcuForcelistOk;
      if ((chromeWanted && !v.chromeOk) ||
          (edgeWanted && !v.edgeOk) ||
          forcelistMissing) {
        status('① Chrome/Edge — HKCU 정책 (관리자 권한 불필요)…');
        final String? source =
            chromeSourceOverride ??
            await _resolveChromeSource(exportIfMissing: true);
        if (source == null) {
          status('① 확장 폴더를 찾지 못해 에셋에서 다시보냅니다…');
        }
        final String? resolved =
            source ?? await _resolveChromeSource(exportIfMissing: true);
        if (resolved != null) {
          final HkcuExtensionApplyResult hkcu = await _applyHkcuChromeEdge(
            sourceFolder: resolved,
          );
          hkcuApplied = hkcu.ok;
          if (!hkcu.ok) {
            status('① HKCU 실패: ${hkcu.message}');
            AppLogger.instance.warn(
              'extension_self_heal HKCU: ${hkcu.message}',
            );
          } else {
            status('① HKCU 적용됨 → ${hkcu.extensionPath}');
          }
        } else {
          status('① Chrome 확장 소스 없음 — 먼저 ① 폴더 준비 실행');
        }
        v = await WindowsExtensionGuardService.verifyAllPolicies();
      }

      if (attemptElevated &&
          userInitiated &&
          !SilentBootstrapContext.suppressElevated &&
          !v.requestedStateSatisfied() &&
          !await ExtensionGuardPrefs.instance.isElevatedGuardSkipped()) {
        final String? source =
            chromeSourceOverride ??
            await _resolveChromeSource(exportIfMissing: false);
        if (source != null) {
          status('② UAC (선택) — HKLM 정책 시도…');
          final ExtensionGuardResult guard = await WindowsExtensionGuardService
              .instance
              .runElevatedGuard(chromeExtensionFolder: source);
          v = await WindowsExtensionGuardService.verifyAllPolicies();
          if (!v.requestedStateSatisfied() &&
              (guard.message.contains('UAC 취소') ||
                  guard.message.contains('exit 2'))) {
            await ExtensionGuardPrefs.instance.setElevatedGuardSkipped(true);
            status('② UAC/HKLM 막힘 — 바로가기 모드로 계속');
          }
        }
      }

      final ExtensionProtectionTier tier = _tierFromVerify(v);
      String message = _summaryMessage(v, tier);
      if (!v.chromeOk &&
          userInitiated &&
          tier == ExtensionProtectionTier.firefoxOnly) {
        message =
            'Chrome/Edge 레지스트리가 막혀 있습니다.\n'
            '로그: ${p.join(ChromeLoadExtensionLauncher.sixVpnDir, "hkcu_heal.log")}\n'
            '앱 **관리자 권한** 또는 IT 예외 후 쉬운 설치 재시도.\n\n$message';
      }

      if (v.chromeOk || v.firefoxPolicyOk) {
        await ExtensionGuardPrefs.instance.setWatchdogEnabled(true);
        final String? src =
            chromeSourceOverride ??
            await _resolveChromeSource(exportIfMissing: false);
        if (src != null) {
          await ExtensionGuardPrefs.instance.setChromeSourcePath(src);
        }
      }

      return ExtensionSelfHealResult(
        tier: tier,
        message: message,
        verify: v,
        hkcuApplied: hkcuApplied,
      );
    } finally {
      _running = false;
    }
  }

  static ExtensionProtectionTier _tierFromVerify(
    ExtensionPolicyVerifyResult v,
  ) {
    if (v.allOk) {
      return v.usesHkcuFallback
          ? ExtensionProtectionTier.hkcuChromeEdge
          : ExtensionProtectionTier.fullHklm;
    }
    if (v.firefoxPolicyOk && v.chromeOk && v.edgeOk) {
      return v.usesHkcuFallback
          ? ExtensionProtectionTier.hkcuChromeEdge
          : ExtensionProtectionTier.fullHklm;
    }
    if (v.firefoxPolicyOk && (v.chromeOk || v.edgeOk)) {
      return ExtensionProtectionTier.partial;
    }
    if (v.firefoxPolicyOk) return ExtensionProtectionTier.firefoxOnly;
    return ExtensionProtectionTier.failed;
  }

  static String _summaryMessage(
    ExtensionPolicyVerifyResult v,
    ExtensionProtectionTier tier,
  ) {
    final StringBuffer sb = StringBuffer();
    switch (tier) {
      case ExtensionProtectionTier.fullHklm:
        sb.writeln('✅ Chrome · Edge · Firefox — 관리자 설치 완료');
      case ExtensionProtectionTier.hkcuChromeEdge:
        if (v.chromeLoadExtensionFallbackOk) {
          sb.writeln('✅ Firefox · Chrome/Edge — 시스템 바로가기 통합');
        } else {
          sb.writeln('✅ Firefox · Chrome/Edge — 레지스트리로 확장 연결됨');
          sb.writeln('Chrome 완전 종료 후 재실행.');
        }
        sb.writeln('개발자 모드 「압축 해제됨」 복사본은 제거.');
      case ExtensionProtectionTier.partial:
        sb.writeln('⚠️ Firefox ✅ · Chrome/Edge 일부만 적용');
      case ExtensionProtectionTier.firefoxOnly:
        sb.writeln('⚠️ Firefox만 OK — Chrome/Edge는 UAC 「예」 또는 관리자 실행 필요');
      case ExtensionProtectionTier.failed:
        sb.writeln('❌ 브라우저 보호 미완료');
      case ExtensionProtectionTier.unsupported:
      case ExtensionProtectionTier.unknown:
        break;
    }
    sb.writeln('\n${v.userFacingDetail}');
    return sb.toString().trim();
  }

  Future<String?> _resolveChromeSource({required bool exportIfMissing}) async {
    final String? saved = await ExtensionGuardPrefs.instance.chromeSourcePath();
    if (saved != null && await File(p.join(saved, 'manifest.json')).exists()) {
      return saved;
    }

    final String local = localChromeBlockerDir;
    if (await File(p.join(local, 'manifest.json')).exists()) return local;

    final String docs =
        await WindowsChromeExtensionInstallService.defaultChromeExtensionPath();
    if (await File(p.join(docs, 'manifest.json')).exists()) return docs;

    final String programData = p.join(
      Platform.environment['ProgramData'] ?? r'C:\ProgramData',
      'SixVPNBlocker',
      'chrome_blocker',
    );
    if (await File(p.join(programData, 'manifest.json')).exists()) {
      return programData;
    }

    if (!exportIfMissing) return null;

    final BrowserExtensionExportResult export =
        await BrowserExtensionExportService.exportAssets(
          assetPaths: BrowserExtensionAssetManifest.chrome,
          subdirName: BrowserExtensionExportService.kChromeSubdir,
        );
    if (export.ok) {
      await ExtensionGuardPrefs.instance.setChromeSourcePath(export.path);
      return export.path;
    }
    return null;
  }

  /// Cheap HKCU policy-only refresh — re-writes ExtensionInstallForcelist +
  /// ExtensionSettings + dev-mode lock without copying files or restarting
  /// browsers. Used inside the watchdog's cooldown to keep the force-install
  /// policy "sticky" even if the user deletes it from regedit.
  ///
  /// Idempotent and fast: just a handful of `reg.exe add` calls. Returns
  /// silently on failure so the cooldown branch never blocks the UI.
  Future<void> reapplyHkcuOnly({required String sourceFolder}) async {
    if (!Platform.isWindows) return;
    try {
      final String dest = localChromeBlockerDir;
      // Prefer the live deployed folder if present — its updates.xml is the
      // real one Chrome polls. Fall back to the source folder.
      String folder = await File(p.join(dest, 'manifest.json')).exists()
          ? dest
          : sourceFolder;
      if (!await File(p.join(folder, 'manifest.json')).exists()) {
        AppLogger.instance.warn(
          'reapplyHkcuOnly: no manifest in $folder — skipped',
        );
        return;
      }

      await _ensureUpdatesXml(folder);

      final String extId = ChromeExtensionIdentity.extensionId;
      final String folderUrl = _fileUrlForFolder(folder);
      final String updateUrl = '${folderUrl}updates.xml';
      final String forcelistVal = '$extId;$updateUrl';
      final String settingsJson = jsonEncode(<String, Object?>{
        extId: <String, Object?>{
          'installation_mode': 'force_installed',
          'toolbar_pin': 'force_pinned',
          'update_url': updateUrl,
          'override_update_url': true,
        },
      });
      final bool ok = await _importHkcuReg(
        settingsJson: settingsJson,
        forcelistVal: forcelistVal,
      );
      if (!ok) {
        AppLogger.instance.warn(
          'reapplyHkcuOnly: HKCU policy import incomplete (ACL or reg.exe)',
        );
      }
      // Bust the cache so the next verify sees what we just wrote.
      WindowsExtensionGuardService.invalidateVerifyCache();
    } catch (e, st) {
      AppLogger.instance.warn('reapplyHkcuOnly failed', error: e);
      AppLogger.instance.log('DEBUG', 'reapplyHkcuOnly stack', stack: st);
    }
  }

  /// Chrome force-install requires updates.xml beside manifest.json.
  /// codebase MUST point at packaged .crx (Rebuild step packs <folder>.crx);
  /// manifest.json codebase silently fails forcelist install.
  Future<void> _ensureUpdatesXml(String folder) async {
    final File manifest = File(p.join(folder, 'manifest.json'));
    if (!await manifest.exists()) return;
    final File updates = File(p.join(folder, 'updates.xml'));
    final String extId = ChromeExtensionIdentity.extensionId;
    final String ver = await ChromeExtensionVersion.bundled();
    final File crx = File(
      p.join(p.dirname(folder), '${p.basename(folder)}.crx'),
    );
    final String codebase = await crx.exists()
        ? 'file:///${crx.path.replaceAll(r'\', '/').replaceAll(' ', '%20')}'
        : '${_fileUrlForFolder(folder)}manifest.json';
    // Skip rewrite if the file already references the CRX (rebuild script
    // may have stamped a hash_sha256 variant we want to preserve).
    if (await updates.exists()) {
      try {
        final String existing = await updates.readAsString();
        if (await crx.exists() && existing.contains('.crx')) return;
      } catch (_) {}
    }
    final String updatesXml =
        "<?xml version='1.0' encoding='UTF-8'?>"
        "<gupdate xmlns='http://www.google.com/update2/response' protocol='2.0'>"
        "<app appid='$extId'>"
        "<updatecheck codebase='$codebase' version='$ver' />"
        '</app></gupdate>';
    await updates.writeAsString(updatesXml, flush: true);
    AppLogger.instance.info(
      'reapplyHkcuOnly: wrote updates.xml -> ${updates.path}',
    );
  }

  Future<HkcuExtensionApplyResult> _applyHkcuChromeEdge({
    required String sourceFolder,
  }) async {
    final Directory src = Directory(sourceFolder);
    if (!await src.exists()) {
      return HkcuExtensionApplyResult(
        ok: false,
        message: '확장 폴더 없음: $sourceFolder',
      );
    }

    final String dest = localChromeBlockerDir;
    try {
      final Directory destDir = Directory(dest);
      if (await destDir.exists()) {
        await destDir.delete(recursive: true);
      }
      await destDir.create(recursive: true);
      await for (final FileSystemEntity e in src.list(recursive: true)) {
        if (e is! File) continue;
        final String rel = p.relative(e.path, from: sourceFolder);
        final File out = File(p.join(dest, rel));
        await out.parent.create(recursive: true);
        await e.copy(out.path);
      }
    } catch (e) {
      return HkcuExtensionApplyResult(
        ok: false,
        message: 'LocalAppData 복사 실패: $e',
      );
    }

    final String extId = ChromeExtensionIdentity.extensionId;
    final String ver = await ChromeExtensionVersion.bundled();
    final String folderUrl = _fileUrlForFolder(dest);
    final String updateUrl = '${folderUrl}updates.xml';
    final String forcelistVal = '$extId;$updateUrl';
    // Codebase must point at packaged .crx (rebuild script packs it as
    // sibling). Falling back to manifest.json silently fails forcelist
    // install — that was the silent break in builds <=232.
    final File crx = File('$dest.crx');
    final String codebase = await crx.exists()
        ? 'file:///${crx.path.replaceAll(r'\', '/').replaceAll(' ', '%20')}'
        : '${folderUrl}manifest.json';
    final String updatesXml =
        "<?xml version='1.0' encoding='UTF-8'?>"
        "<gupdate xmlns='http://www.google.com/update2/response' protocol='2.0'>"
        "<app appid='$extId'>"
        "<updatecheck codebase='$codebase' version='$ver' />"
        '</app></gupdate>';
    await File(p.join(dest, 'updates.xml')).writeAsString(updatesXml);

    final String settingsJson = jsonEncode(<String, Object?>{
      extId: <String, Object?>{
        'installation_mode': 'force_installed',
        'toolbar_pin': 'force_pinned',
        'update_url': updateUrl,
        'override_update_url': true,
      },
    });

    await _healLog('dest=$dest');

    final NativeRegistryWriteResult native =
        await WindowsChromeExtensionRegistryNative.registerChromeAndEdge(
          extensionId: extId,
          extensionFolder: dest,
          version: ver,
        );
    await _healLog('native: ${native.detail}');

    bool policyImported = false;
    // Always attempt HKCU policy writes (ExtensionInstallForcelist + ExtensionSettings).
    // Some machines incorrectly report policy write denied, but reg.exe still succeeds.
    policyImported = await _importHkcuReg(
      settingsJson: settingsJson,
      forcelistVal: forcelistVal,
    );
    await _healLog('reg.exe policy: $policyImported');

    final bool userRegExe = await _registerUserExtensionKeys(
      extensionPath: dest,
      version: ver,
    );
    await _healLog('reg.exe user ext: $userRegExe');

    ExtensionPolicyVerifyResult check =
        await WindowsExtensionGuardService.verifyAllPolicies();
    if (!check.chromeOk && !check.edgeOk) {
      await _healLog(
        'registry paths failed — installing load-extension launcher',
      );
      final LoadExtensionLauncherResult launcher =
          await ChromeLoadExtensionLauncher.install(extensionFolder: dest);
      await _healLog('launcher: ${launcher.message}');
      check = await WindowsExtensionGuardService.verifyAllPolicies();
      if (!check.chromeOk && !check.edgeOk) {
        return HkcuExtensionApplyResult(
          ok: false,
          message:
              'Chrome/Edge 복구 실패\n'
              'native=${native.anyOk} policy=$policyImported reg.exe=$userRegExe\n'
              'launcher=${launcher.ok}\n'
              '${check.detail}\n'
              '로그: ${_healLogPath()}',
        );
      }
      await ExtensionGuardPrefs.instance.setChromeSourcePath(dest);
      return HkcuExtensionApplyResult(
        ok: true,
        message: '${launcher.message}\n\n${check.detail}',
        extensionPath: dest,
      );
    }

    await ExtensionGuardPrefs.instance.setChromeSourcePath(dest);
    String mode = '복구됨';
    if (check.chromeHkcuOk) {
      mode = 'HKCU 정책';
    } else if (check.chromeUserInstallOk || native.anyOk) {
      mode = '사용자 레지스트리';
    } else if (check.chromeLoadExtensionFallbackOk) {
      mode = '바로가기(--load-extension)';
    }
    return HkcuExtensionApplyResult(
      ok: true,
      message: 'Chrome/Edge $mode → $dest',
      extensionPath: dest,
    );
  }

  static String _healLogPath() =>
      p.join(ChromeLoadExtensionLauncher.sixVpnDir, 'hkcu_heal.log');

  static Future<void> _healLog(String line) async {
    try {
      final File f = File(_healLogPath());
      await f.parent.create(recursive: true);
      await f.writeAsString(
        '${DateTime.now().toIso8601String()} $line\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
  }

  static Future<bool> _registerUserExtensionKeys({
    required String extensionPath,
    required String version,
  }) async {
    final String extId = ChromeExtensionIdentity.extensionId;
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final String regExe = p.join(windir, 'System32', 'reg.exe');
    final String pathEsc = extensionPath;

    Future<bool> regKey(String key) async {
      if (ExtensionGuardPrefs.instance.isRegistryRootExplicitlyDisabled(key)) {
        return false;
      }
      final ProcessResult d = await windowsRunHidden(regExe, <String>[
        'add',
        key,
        '/ve',
        '/t',
        'REG_SZ',
        '/d',
        pathEsc,
        '/f',
      ]);
      final ProcessResult v = await windowsRunHidden(regExe, <String>[
        'add',
        key,
        '/v',
        'version',
        '/t',
        'REG_SZ',
        '/d',
        version,
        '/f',
      ]);
      return d.exitCode == 0 && v.exitCode == 0;
    }

    final bool chromeOk = await regKey(
      'HKCU\\Software\\Google\\Chrome\\Extensions\\$extId',
    );
    final bool edgeOk = await regKey(
      'HKCU\\Software\\Microsoft\\Edge\\Extensions\\$extId',
    );
    final bool braveOk = await regKey(
      'HKCU\\Software\\BraveSoftware\\Brave-Browser\\Extensions\\$extId',
    );
    bool derivativeOk = false;
    for (final ChromiumDerivativeBrowserDef def
        in kChromiumDerivativeBrowsers) {
      final bool ok = await regKey('HKCU\\${def.userExtRegSubKey}\\$extId');
      if (ok) derivativeOk = true;
    }
    return chromeOk || edgeOk || braveOk || derivativeOk;
  }

  static String _fileUrlForFolder(String folderPath) {
    String norm = p.normalize(folderPath).replaceAll(r'\', '/');
    if (norm.length >= 2 && norm[1] == ':') {
      return 'file:///$norm/';
    }
    return 'file:///$norm/';
  }

  static Future<bool> _importHkcuReg({
    required String settingsJson,
    required String forcelistVal,
  }) async {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final String regExe = p.join(windir, 'System32', 'reg.exe');

    Future<bool> add(
      String key,
      String valueName,
      String data, {
      String type = 'REG_SZ',
    }) async {
      final ProcessResult pr = await windowsRunHidden(regExe, <String>[
        'add',
        key,
        '/v',
        valueName,
        '/t',
        type,
        '/d',
        data,
        '/f',
      ]);
      if (pr.exitCode != 0) {
        AppLogger.instance.warn(
          'hkcu reg add failed $key\\$valueName exit ${pr.exitCode}: ${pr.stderr}',
        );
      }
      return pr.exitCode == 0;
    }

    // Cover every Chromium-based browser variant the user might have. Chrome
    // Beta/Dev/Canary on Windows actually share the same `Google\Chrome` policy
    // path, but Edge Beta/Dev/Canary use distinct keys. Writing all of them
    // makes the force-install survive a Chrome -> Edge Beta switch.
    final List<String> chromiumPolicyRoots = <String>[
      r'HKCU\SOFTWARE\Policies\Google\Chrome',
      r'HKCU\SOFTWARE\Policies\Microsoft\Edge',
      r'HKCU\SOFTWARE\Policies\Microsoft\EdgeBeta',
      r'HKCU\SOFTWARE\Policies\Microsoft\EdgeDev',
      r'HKCU\SOFTWARE\Policies\Chromium',
      ...WindowsBrowserBypassCloserService.derivativeHkcuRoots,
    ];

    final List<bool> ok = <bool>[];
    for (final String root in chromiumPolicyRoots) {
      if (ExtensionGuardPrefs.instance.isRegistryRootExplicitlyDisabled(root)) {
        continue;
      }
      ok.add(await add(root, 'ExtensionSettings', settingsJson));
      ok.add(await add('$root\\ExtensionInstallForcelist', '1', forcelistVal));
    }
    // User-installable extensions KEPT OPEN.
    //
    // Removed 2026-06-19 at user request ("새 확장을 깔지 못하게 한 것 같거든
    // ? 이거 바꿔줘 제발"):
    //   - `ExtensionDeveloperModeAvailability=0` blocked Chrome's Developer
    //     mode entirely (no "Load unpacked", no in-DevTools extension reload).
    //   - `BlockExternalExtensions=1` blocked .crx drag-drop installs.
    //   - `ExtensionInstallAllowlist` listing only our ID was redundant —
    //     `installation_mode: force_installed` already guarantees survival.
    //
    // Protection still holds: 6VPN ext is `force_installed` (un-removable),
    // `ExtensionInstallForcelist` re-delivers it, and URLBlocklist + hosts +
    // PAC enforce below the extension layer. A sideloaded extension cannot
    // disable a force_installed one — Chrome enterprise guarantee.
    return ok.every((bool b) => b);
  }
}
