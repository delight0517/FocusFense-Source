import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'browser_extension_export_service.dart';
import '../data/browser_extension_asset_manifest.dart';
import 'extension_rules_snapshot_service.dart';
import 'firefox_config_service.dart';
import 'firefox_xpi_packager.dart';
import 'extension_guard_prefs.dart';
import 'windows_extension_guard_service.dart';
import 'windows_hidden_process.dart';
import 'windows_hkcu_policy_service.dart';

/// Firefox: DoH lock + `force_installed` XPI (policies + all profiles).
final class WindowsFirefoxExtensionInstallService {
  WindowsFirefoxExtensionInstallService._()
    : _prepareNativeUpdate = null,
      _validateNativeArtifact = null,
      _findNativeFirefox = null,
      _launchNativeFirefox = null;

  WindowsFirefoxExtensionInstallService.forTesting({
    required Future<FirefoxManagedRepairReport> Function() prepare,
    required Future<bool> Function(File file) validateArtifact,
    required Future<String?> Function() findFirefox,
    required Future<void> Function(String executable, List<String> arguments)
    launch,
  }) : _prepareNativeUpdate = prepare,
       _validateNativeArtifact = validateArtifact,
       _findNativeFirefox = findFirefox,
       _launchNativeFirefox = launch;

  final Future<FirefoxManagedRepairReport> Function()? _prepareNativeUpdate;
  final Future<bool> Function(File)? _validateNativeArtifact;
  final Future<String?> Function()? _findNativeFirefox;
  final Future<void> Function(String, List<String>)? _launchNativeFirefox;
  static final WindowsFirefoxExtensionInstallService instance =
      WindowsFirefoxExtensionInstallService._();

  static const String kExtensionId = kFirefoxExtensionId;

  bool get isSupported => Platform.isWindows;

  /// Explicit user button/CLI action only. Preparation never requests UAC,
  /// overwrites profiles, restarts Firefox, or claims its native dialog is shown.
  Future<FirefoxNativeUpdateReport> requestNativeUpdate({
    required bool userInitiated,
    void Function(String message)? onProgress,
  }) async {
    FirefoxManagedRepairReport? prepared;
    var verified = false;
    FirefoxNativeUpdateReport result(String message, {bool launched = false}) =>
        FirefoxNativeUpdateReport(
          filesPrepared: prepared?.filesPrepared ?? false,
          artifactVerified: verified,
          launchRequested: launched,
          expectedVersion: prepared?.expectedVersion ?? '',
          expectedSha256: prepared?.expectedSha256 ?? '',
          preparedXpiPath: prepared?.preparedXpiPath,
          message: message,
        );
    if (!userInitiated) {
      return result(
        'An explicit user action is required to open the Firefox update.',
      );
    }
    try {
      onProgress?.call('Preparing the approved signed Firefox update.');
      prepared =
          await (_prepareNativeUpdate?.call() ??
              repairManaged(requestElevation: false, onProgress: onProgress));
      final String? path = prepared.preparedXpiPath;
      if (!prepared.filesPrepared || path == null || path.isEmpty) {
        return result(
          prepared.message.isEmpty
              ? 'The signed Firefox update could not be prepared.'
              : prepared.message,
        );
      }
      final File file = File(path);
      final bool approved =
          await file.exists() &&
          await (_validateNativeArtifact?.call(file) ??
              FirefoxXpiPackager.instance.isBundledSignedCopy(file));
      if (!approved ||
          !RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(prepared.expectedSha256) ||
          sha256.convert(await file.readAsBytes()).toString() !=
              prepared.expectedSha256.toLowerCase()) {
        return result(
          'The prepared file does not match the approved signed Firefox update.',
        );
      }
      verified = true;
      if (!await openSignedXpiInFirefox(xpiPath: path)) {
        return result(
          'The verified update is prepared, but opening it in Firefox failed.',
        );
      }
      return result(
        'The Firefox update-open request was sent. Confirm any native Firefox prompt. Dialog visibility and activation have not been verified.',
        launched: true,
      );
    } catch (e) {
      return result('The Firefox update-open request failed: $e');
    }
  }

  // @incident: firefox_work_window_closed — a repair never closes/restarts a
  // browser. Prepared files and observed activation are separate report fields.
  Future<FirefoxManagedRepairReport> repairManaged({
    bool requestElevation = true,
    void Function(String message)? onProgress,
  }) async {
    if (!isSupported || !await isFirefoxInstalled()) {
      return const FirefoxManagedRepairReport(
        message: 'Firefox Windows 설치를 찾지 못했습니다.',
      );
    }
    if (ExtensionGuardPrefs.instance.isBrowserExplicitlyDisabled('firefox')) {
      return const FirefoxManagedRepairReport(message: 'Firefox 보호를 먼저 켜 주세요.');
    }
    try {
      onProgress?.call('서명 확장과 현재 Firefox 규칙을 준비합니다.');
      final export = await BrowserExtensionExportService.exportAssets(
        assetPaths: BrowserExtensionAssetManifest.firefox,
        subdirName: BrowserExtensionExportService.kFirefoxSubdir,
      );
      if (!export.ok || export.path.isEmpty) {
        throw StateError('Firefox 자산 준비 실패');
      }
      final folder = export.path;
      final snapshot = await ExtensionRulesSnapshotService.instance
          .writeToFirefoxPayload(sourceFolder: folder);
      if (!snapshot) throw StateError('현재 규칙 스냅샷 준비 실패');
      final version = await FirefoxXpiPackager.instance.trustedSignedVersion();
      final bytes = await FirefoxXpiPackager.instance.trustedSignedBytes();
      final dir = await Directory(
        p.join(
          Platform.environment['LOCALAPPDATA'] ?? '',
          'SixVPNBlocker',
          'firefox-repair',
          DateTime.now().microsecondsSinceEpoch.toString(),
        ),
      ).create(recursive: true);
      final staged = File(p.join(dir.path, FirefoxXpiPackager.kXpiFileName));
      await staged.writeAsBytes(bytes, flush: true);
      if (!await FirefoxXpiPackager.instance.isBundledSignedCopy(staged)) {
        throw StateError('서명 배포본 바이트 검증 실패');
      }
      final hash = sha256.convert(bytes).toString();
      final target = FirefoxXpiPackager.programDataXpiPath;
      final targets = <String>[];
      for (final root in _firefoxRoots) {
        if (await File(
          p.join(root, 'Mozilla Firefox', 'firefox.exe'),
        ).exists()) {
          targets.add(
            p.join(root, 'Mozilla Firefox', 'distribution', 'policies.json'),
          );
        }
      }
      final exitFile = File(p.join(dir.path, 'exit.txt'));
      final resultFile = File(p.join(dir.path, 'result.txt'));
      final config = File(p.join(dir.path, 'repair.json'));
      await config.writeAsString(
        jsonEncode(<String, Object?>{
          'xpiSource': staged.path,
          'xpiTarget': target,
          'sha256': hash,
          'extensionId': kExtensionId,
          'installUrl': FirefoxXpiPackager.fileUrlForXpi(target),
          'policyTargets': targets,
          'exitFile': exitFile.path,
          'resultFile': resultFile.path,
        }),
        flush: true,
      );
      final script = File(p.join(dir.path, 'repair.ps1'));
      await script.writeAsString(
        '\uFEFF${buildManagedRepairScript(config.path)}',
        flush: true,
      );
      var applied = false;
      var message = '서명 확장과 규칙 준비 완료. 관리자 적용은 아직 실행하지 않았습니다.';
      if (requestElevation) {
        onProgress?.call('Windows 관리자 승인을 요청합니다. 열린 Firefox 창은 유지합니다.');
        final ps = p.join(
          Platform.environment['WINDIR'] ?? r'C:\Windows',
          'System32',
          'WindowsPowerShell',
          'v1.0',
          'powershell.exe',
        );
        // One ordinary UAC request; no retry can display a second prompt.
        final command = buildManagedElevationCommand(
          psExe: ps,
          scriptPath: script.path,
        );
        await windowsRunHidden(ps, <String>[
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          command,
        ]).timeout(const Duration(minutes: 3));
        applied =
            await exitFile.exists() &&
            (await exitFile.readAsString()).trim() == '0';
        if (applied) {
          await installXpiToAllProfiles(xpiFile: File(target));
          message = 'Firefox 설치 정책 적용 완료. 실제 활성화 여부는 아래 프로필 확인 결과를 확인하세요.';
        } else {
          message = '관리자 적용을 완료하지 못했습니다. 열린 Firefox 창은 유지했습니다.';
          if (await resultFile.exists()) {
            message += '\n${await resultFile.readAsString()}';
          }
        }
      }
      return await inspectManaged(
        expectedVersion: version,
        expectedSha256: hash,
        filesPrepared: true,
        rulesSnapshotPrepared: snapshot,
        policiesApplied: applied,
        preparedXpiPath: staged.path,
        message: message,
      );
    } catch (e) {
      return FirefoxManagedRepairReport(message: 'Firefox 복구 오류: $e');
    }
  }

  static List<String> get _firefoxRoots => <String>[
    Platform.environment['ProgramFiles'] ?? r'C:\Program Files',
    Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)',
  ];
  static String _psQuote(String value) => value.replaceAll("'", "''");

  static String buildManagedElevationCommand({
    required String psExe,
    required String scriptPath,
  }) =>
      r'''$p = Start-Process -FilePath '__PS__' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File','"__SCRIPT__"') -Verb RunAs -WindowStyle Hidden -Wait -PassThru; if ($p) { exit $p.ExitCode } else { exit 1 }'''
          .replaceAll('__PS__', _psQuote(psExe))
          .replaceAll('__SCRIPT__', _psQuote(scriptPath));

  /// Firefox-only policy merge: WebsiteFilter and all unrelated keys survive.
  static String buildManagedRepairScript(String configPath) =>
      r'''
$ErrorActionPreference = 'Stop'
$cfg = Get-Content -LiteralPath '__CONFIG__' -Raw -Encoding UTF8 | ConvertFrom-Json
function Get-FFSignedHash([string]$path) {
  $hash = [Security.Cryptography.SHA256]::Create()
  try { return [BitConverter]::ToString($hash.ComputeHash([IO.File]::ReadAllBytes($path))).Replace('-','').ToLowerInvariant() }
  finally { $hash.Dispose() }
}
try {
  if ((Get-FFSignedHash $cfg.xpiSource) -ne $cfg.sha256) { throw 'Signed staging hash mismatch' }
  New-Item -ItemType Directory -Path (Split-Path -Parent $cfg.xpiTarget) -Force | Out-Null
  Copy-Item -LiteralPath $cfg.xpiSource -Destination $cfg.xpiTarget -Force
  if ((Get-FFSignedHash $cfg.xpiTarget) -ne $cfg.sha256) { throw 'Installed signed hash mismatch' }
  foreach ($target in $cfg.policyTargets) {
    $doc = [pscustomobject]@{}
    if (Test-Path -LiteralPath $target) {
      $doc = Get-Content -LiteralPath $target -Raw -Encoding UTF8 | ConvertFrom-Json
      if ($null -eq $doc) { throw 'Existing Firefox policy JSON is empty' }
      Copy-Item -LiteralPath $target -Destination ($target + '.focusfense-before-' + [DateTime]::UtcNow.ToString('yyyyMMddHHmmssfffffff'))
    }
    if (-not $doc.policies) { $doc | Add-Member -MemberType NoteProperty -Name policies -Value ([pscustomobject]@{}) -Force }
    if (-not $doc.policies.ExtensionSettings) { $doc.policies | Add-Member -MemberType NoteProperty -Name ExtensionSettings -Value ([pscustomobject]@{}) -Force }
    $entry = [pscustomobject]@{ installation_mode='force_installed'; install_url=$cfg.installUrl; blocked_install_message='FocusFense protection is locked by policy.' }
    $doc.policies.ExtensionSettings | Add-Member -Name $cfg.extensionId -Value $entry -MemberType NoteProperty -Force
    if (-not $doc.policies.Extensions) { $doc.policies | Add-Member -MemberType NoteProperty -Name Extensions -Value ([pscustomobject]@{}) -Force }
    $install = @($doc.policies.Extensions.Install | Where-Object { $_ -and $_ -notlike ('*' + $cfg.extensionId + '*') -and $_ -notlike '*sixvpn_blocker_signed.xpi*' }) + @($cfg.installUrl)
    $locked = @($doc.policies.Extensions.Locked | Where-Object { $_ }) + @($cfg.extensionId)
    $doc.policies.Extensions | Add-Member -MemberType NoteProperty -Name Install -Value @($install | Select-Object -Unique) -Force
    $doc.policies.Extensions | Add-Member -MemberType NoteProperty -Name Locked -Value @($locked | Select-Object -Unique) -Force
    New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
    $tmp = $target + '.focusfense-staging-' + $PID
    [IO.File]::WriteAllText($tmp, ($doc | ConvertTo-Json -Depth 50), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $target -Force
  }
  [IO.File]::WriteAllText($cfg.resultFile, 'Firefox policy prepared; browser not restarted')
  [IO.File]::WriteAllText($cfg.exitFile, '0')
  exit 0
} catch {
  [IO.File]::WriteAllText($cfg.resultFile, ($_ | Out-String))
  [IO.File]::WriteAllText($cfg.exitFile, '1')
  exit 1
}
'''
          .replaceAll('__CONFIG__', _psQuote(configPath));

  static FirefoxProfileAddonStatus? parseManagedAddon(
    Map<String, dynamic> json, {
    required String profilePath,
  }) {
    final addons = json['addons'];
    if (addons is! List) return null;
    for (final item in addons) {
      if (item is! Map || item['id'] != kExtensionId) continue;
      final locale = item['defaultLocale'];
      return FirefoxProfileAddonStatus(
        profilePath: profilePath,
        name: (item['name'] ?? (locale is Map ? locale['name'] : '') ?? '')
            .toString(),
        version: (item['version'] ?? '').toString(),
        active:
            item['active'] == true &&
            item['appDisabled'] != true &&
            item['userDisabled'] != true,
        signedState: item['signedState'] is int
            ? item['signedState'] as int
            : null,
        xpiPath: item['path'] is String
            ? item['path'] as String
            : p.join(
                profilePath,
                'extensions',
                FirefoxXpiPackager.kXpiFileName,
              ),
      );
    }
    return null;
  }

  Future<FirefoxManagedRepairReport> inspectManaged({
    String expectedVersion = '',
    String expectedSha256 = '',
    bool filesPrepared = false,
    bool rulesSnapshotPrepared = false,
    bool policiesApplied = false,
    String? preparedXpiPath,
    String message = '',
  }) async {
    if (expectedVersion.isEmpty || expectedSha256.isEmpty) {
      expectedVersion = await FirefoxXpiPackager.instance
          .trustedSignedVersion();
      expectedSha256 = sha256
          .convert(await FirefoxXpiPackager.instance.trustedSignedBytes())
          .toString();
    }
    final statuses = <FirefoxProfileAddonStatus>[];
    final profiles = await FirefoxConfigService.instance.profileDirs();
    for (final profile in profiles) {
      try {
        final file = File(p.join(profile.path, 'extensions.json'));
        if (!await file.exists()) continue;
        final addon = parseManagedAddon(
          Map<String, dynamic>.from(
            jsonDecode(await file.readAsString()) as Map,
          ),
          profilePath: profile.path,
        );
        if (addon == null) continue;
        final installed = File(addon.xpiPath);
        statuses.add(
          addon.withSha256(
            await installed.exists()
                ? sha256.convert(await installed.readAsBytes()).toString()
                : null,
          ),
        );
      } catch (_) {
        /* Locked/malformed profiles are not activation proof. */
      }
    }
    var running = false;
    if (Platform.isWindows) {
      final result = await windowsRunHidden('tasklist.exe', <String>[
        '/FI',
        'IMAGENAME eq firefox.exe',
        '/FO',
        'CSV',
        '/NH',
      ]);
      running = result.stdout.toString().toLowerCase().contains(
        '"firefox.exe"',
      );
    }
    return FirefoxManagedRepairReport(
      filesPrepared: filesPrepared,
      rulesSnapshotPrepared: rulesSnapshotPrepared,
      policiesApplied: policiesApplied,
      expectedVersion: expectedVersion,
      expectedSha256: expectedSha256,
      profiles: statuses,
      profileTotal: profiles.length,
      firefoxRunning: running,
      preparedXpiPath: preparedXpiPath,
      message: message,
    );
  }

  /// Explicit user button only. Opens installation without closing any window.
  Future<bool> openMozillaCredentialPageInFirefox() async {
    for (final root in _firefoxRoots) {
      final exe = p.join(root, 'Mozilla Firefox', 'firefox.exe');
      if (!await File(exe).exists()) continue;
      await Process.start(exe, <String>[
        '-new-tab',
        'https://addons.mozilla.org/developers/addon/api/key/',
      ], mode: ProcessStartMode.detached);
      return true;
    }
    return false;
  }

  Future<bool> openSignedXpiInFirefox({String? xpiPath}) async {
    final file = File(xpiPath ?? FirefoxXpiPackager.programDataXpiPath);
    if (!await file.exists() ||
        !await (_validateNativeArtifact?.call(file) ??
                FirefoxXpiPackager.instance.isBundledSignedCopy(file))) {
      return false;
    }
    String? executable;
    if (_findNativeFirefox != null) {
      executable = await _findNativeFirefox();
    } else {
      for (final root in _firefoxRoots) {
        final candidate = p.join(root, 'Mozilla Firefox', 'firefox.exe');
        if (await File(candidate).exists()) {
          executable = candidate;
          break;
        }
      }
    }
    if (executable == null) return false;
    final arguments = <String>[
      '-new-tab',
      Uri.file(file.absolute.path, windows: Platform.isWindows).toString(),
    ];
    if (_launchNativeFirefox != null) {
      await _launchNativeFirefox(executable, arguments);
    } else {
      await Process.start(
        executable,
        arguments,
        mode: ProcessStartMode.detached,
      );
    }
    return true;
  }

  /// Enterprise `distribution/policies.json` (matches Mozilla schema).
  static String buildPoliciesJson({
    required String xpiInstallUrl,
    String? installSourcesParent,
  }) {
    final String pd = Platform.environment['ProgramData'] ?? r'C:\ProgramData';
    final String sourcesRoot =
        installSourcesParent ?? p.join(pd, 'SixVPNBlocker');
    final String src = WindowsExtensionGuardService.fileUrlForFolder(
      sourcesRoot,
    );
    return jsonEncode(<String, Object?>{
      'policies': <String, Object?>{
        'DNSOverHTTPS': <String, Object?>{'Enabled': false, 'Locked': true},
        'NetworkPrediction': false,
        'Preferences': <String, Object?>{
          'network.trr.mode': 5,
          'network.dns.disablePrefetch': true,
          'network.dns.disablePrefetchFromHTTPS': true,
          'doh-rollout.mode': 5,
        },
        'DisablePrivateBrowsing': true,
        // @incident: private-mode-policy-inversion — Mozilla value 2 forces
        // private browsing; value 1 disables it and supersedes the old policy.
        'PrivateBrowsingModeAvailability': 1,
        'DisableDeveloperTools': true,
        'Extensions': <String, Object?>{
          'Install': <String>[xpiInstallUrl],
          'Locked': <String>[kExtensionId],
          'InstallSources': <String>[src, 'file:///*'],
        },
        'ExtensionSettings': <String, Object?>{
          kExtensionId: <String, String>{
            'installation_mode': 'force_installed',
            'install_url': xpiInstallUrl,
            'blocked_install_message':
                '6 VPN Blocker protection is locked by policy.',
          },
        },
      },
    });
  }

  /// Copies XPI into every `Profiles\*\extensions\` (no admin).
  Future<List<String>> installXpiToAllProfiles({File? xpiFile}) async {
    if (!isSupported) return <String>[];
    if (ExtensionGuardPrefs.instance.isBrowserExplicitlyDisabled('firefox')) {
      return <String>[];
    }
    final File xpi = xpiFile ?? File(FirefoxXpiPackager.programDataXpiPath);
    if (!await xpi.exists()) return <String>[];
    if (!await FirefoxXpiPackager.instance.isBundledSignedCopy(xpi)) {
      throw StateError(
        'Firefox profile install rejected: XPI differs from bundled signed artifact',
      );
    }

    final List<Directory> profiles = await FirefoxConfigService.instance
        .profileDirs();
    final List<String> touched = <String>[];
    for (final Directory prof in profiles) {
      try {
        final Directory extDir = Directory(p.join(prof.path, 'extensions'));
        if (!await extDir.exists()) {
          await extDir.create(recursive: true);
        }
        final File dest = File(
          p.join(extDir.path, FirefoxXpiPackager.kXpiFileName),
        );
        await xpi.copy(dest.path);
        touched.add(prof.path);
      } catch (_) {}
    }
    return touched;
  }

  static Future<bool> isFirefoxInstalled() async {
    final String pf =
        Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
    final String pf86 =
        Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';
    for (final String base in <String>[pf, pf86]) {
      if (await File(p.join(base, 'Mozilla Firefox', 'firefox.exe')).exists()) {
        return true;
      }
    }
    return false;
  }

  static Future<FirefoxInstallVerifyResult> verify() async {
    if (!Platform.isWindows) {
      return const FirefoxInstallVerifyResult(
        policiesOk: false,
        xpiInProgramData: false,
        profileCount: 0,
        profileTotal: 0,
        detail: 'Windows 전용',
      );
    }
    final bool policiesOk =
        await WindowsExtensionGuardService.firefoxPolicyFileOk();
    final File xpi = File(FirefoxXpiPackager.programDataXpiPath);
    final bool xpiPd = await xpi.exists();

    int profileHits = 0;
    final List<Directory> profiles = await FirefoxConfigService.instance
        .profileDirs();
    for (final Directory prof in profiles) {
      final File inProf = File(
        p.join(prof.path, 'extensions', FirefoxXpiPackager.kXpiFileName),
      );
      if (await inProf.exists()) profileHits++;
    }

    final StringBuffer detail = StringBuffer();
    detail.writeln(
      'policies.json (force_installed): ${policiesOk ? "있음" : "없음"}',
    );
    detail.writeln('ProgramData XPI: ${xpiPd ? xpi.path : "(없음)"}');
    detail.writeln('프로필 XPI 복사: $profileHits / ${profiles.length}개 프로필');
    if (!policiesOk) {
      detail.writeln(
        '\n→ UAC 「예」로 Firefox 정책 설치가 필요합니다.\n'
        '→ about:debugging 임시 애드온은 제거하세요 (삭제 가능한 복사본).',
      );
    }

    return FirefoxInstallVerifyResult(
      policiesOk: policiesOk,
      xpiInProgramData: xpiPd,
      profileCount: profileHits,
      profileTotal: profiles.length,
      detail: detail.toString().trim(),
    );
  }

  /// Pack XPI → profiles (user) → policies via [runElevatedGuard] path.
  Future<FirefoxConnectResult> runOneClickConnect({
    required String firefoxExtensionFolder,
    required Future<ExtensionGuardResult> Function(String chromeFolder)
    runCombinedGuard,
    required String chromeExtensionFolder,
  }) async {
    if (!isSupported) {
      return const FirefoxConnectResult(ok: false, message: 'Windows 전용입니다.');
    }
    if (!await isFirefoxInstalled()) {
      return const FirefoxConnectResult(
        ok: false,
        message: 'Firefox가 설치되어 있지 않습니다.',
      );
    }

    try {
      final File xpi = await FirefoxXpiPackager.instance.ensureProgramDataXpi(
        sourceFolder: firefoxExtensionFolder,
      );
      final String xpiUrl = FirefoxXpiPackager.fileUrlForXpi(xpi.path);

      final ExtensionGuardResult guard = await runCombinedGuard(
        chromeExtensionFolder,
      );

      final List<String> profiles = await installXpiToAllProfiles(xpiFile: xpi);
      await FirefoxConfigService.instance.disableDoHInAllProfiles();

      final FirefoxInstallVerifyResult v = await verify();
      final StringBuffer msg = StringBuffer();
      msg.writeln('XPI: ${xpi.path}');
      msg.writeln('install_url: $xpiUrl');
      msg.writeln('프로필 복사: ${profiles.length}개');
      msg.writeln(v.detail);
      if (!guard.ok) {
        msg.writeln('\n[Chrome/Edge]\n${guard.message}');
      }
      msg.writeln(
        '\n현재 열린 Firefox 창은 유지합니다. 정책 확장은 Firefox를 다음에 열 때 적용됩니다.\n'
        '다시 시작한 뒤 about:policies에서 설치 정책을 확인하세요.',
      );

      final bool ok = v.policiesOk && v.xpiInProgramData && profiles.isNotEmpty;
      return FirefoxConnectResult(ok: ok, message: msg.toString().trim());
    } catch (e) {
      return FirefoxConnectResult(ok: false, message: 'Firefox 연결 오류: $e');
    }
  }

  /// No-UAC path: pack XPI → every profile → HKCU ExtensionSettings +
  /// WebsiteFilter (via [WindowsHkcuPolicyService]) → DoH off.
  Future<void> applyHkcuExtensionPolicy() async {
    if (ExtensionGuardPrefs.instance.isBrowserExplicitlyDisabled('firefox')) {
      return;
    }
    if (!isSupported) return;

    final BrowserExtensionExportResult export =
        await BrowserExtensionExportService.exportAssets(
          assetPaths: BrowserExtensionAssetManifest.firefox,
          subdirName: BrowserExtensionExportService.kFirefoxSubdir,
        );
    String? folder = export.ok ? export.path : null;
    folder ??= p.join(
      Platform.environment['LOCALAPPDATA'] ?? '',
      'SixVPNBlocker',
      BrowserExtensionExportService.kFirefoxSubdir,
    );
    if (!await File(p.join(folder, 'manifest.json')).exists()) return;

    await ExtensionRulesSnapshotService.instance.writeToFirefoxPayload(
      sourceFolder: folder,
    );

    final File xpi = await FirefoxXpiPackager.instance.ensureProgramDataXpi(
      sourceFolder: folder,
    );
    await installXpiToAllProfiles(xpiFile: xpi);
    await applyHkcuExtensionSettingsRegistry(
      xpiUrl: FirefoxXpiPackager.fileUrlForXpi(xpi.path),
    );
    await WindowsHkcuPolicyService.instance.applyNow();
    await FirefoxConfigService.instance.disableDoHInAllProfiles();
  }

  /// `HKCU\Software\Policies\Mozilla\Firefox` → ExtensionSettings (no admin).
  static Future<void> applyHkcuExtensionSettingsRegistry({
    required String xpiUrl,
  }) async {
    if (!Platform.isWindows) return;
    if (ExtensionGuardPrefs.instance.isBrowserExplicitlyDisabled('firefox')) {
      return;
    }
    final String json = jsonEncode(<String, Object?>{
      kExtensionId: <String, String>{
        'installation_mode': 'force_installed',
        'install_url': xpiUrl,
      },
    });
    final String esc = json.replaceAll("'", "''");
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final String ps =
        '''
\$ErrorActionPreference = 'Stop'
\$firefox = 'HKCU:\\SOFTWARE\\Policies\\Mozilla\\Firefox'
if (-not (Test-Path -LiteralPath \$firefox)) {
  New-Item -Path \$firefox -Force | Out-Null
}
Set-ItemProperty -LiteralPath \$firefox -Name 'ExtensionSettings' -Value '$esc' -Type String -Force
\$extInstall = Join-Path \$firefox 'Extensions\\Install'
\$extLocked = Join-Path \$firefox 'Extensions\\Locked'
if (-not (Test-Path -LiteralPath \$extInstall)) { New-Item -Path \$extInstall -Force | Out-Null }
if (-not (Test-Path -LiteralPath \$extLocked)) { New-Item -Path \$extLocked -Force | Out-Null }
Set-ItemProperty -LiteralPath \$extInstall -Name '1' -Value '$xpiUrl' -Type String -Force
Set-ItemProperty -LiteralPath \$extLocked -Name '1' -Value '$kExtensionId' -Type String -Force
Set-ItemProperty -LiteralPath \$firefox -Name 'DisablePrivateBrowsing' -Value 1 -Type DWord -Force
Set-ItemProperty -LiteralPath \$firefox -Name 'PrivateBrowsingModeAvailability' -Value 1 -Type DWord -Force
Set-ItemProperty -LiteralPath \$firefox -Name 'DisableDeveloperTools' -Value 1 -Type DWord -Force
Write-Output 'Firefox_HKCU_ExtensionSettings_OK'
''';
    try {
      await windowsRunHidden(
        p.join(
          windir,
          'System32',
          'WindowsPowerShell',
          'v1.0',
          'powershell.exe',
        ),
        <String>[
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-WindowStyle',
          'Hidden',
          '-Command',
          ps,
        ],
      );
    } catch (_) {}
  }
}

final class FirefoxInstallVerifyResult {
  const FirefoxInstallVerifyResult({
    required this.policiesOk,
    required this.xpiInProgramData,
    required this.profileCount,
    required this.profileTotal,
    required this.detail,
  });

  final bool policiesOk;
  final bool xpiInProgramData;
  final int profileCount;
  final int profileTotal;
  final String detail;

  bool get allOk => policiesOk && xpiInProgramData && profileCount > 0;
}

final class FirefoxNativeUpdateReport {
  const FirefoxNativeUpdateReport({
    this.filesPrepared = false,
    this.artifactVerified = false,
    this.launchRequested = false,
    this.expectedVersion = '',
    this.expectedSha256 = '',
    this.preparedXpiPath,
    this.message = '',
  });
  final bool filesPrepared, artifactVerified, launchRequested;
  final String expectedVersion, expectedSha256, message;
  final String? preparedXpiPath;
  // Process.start returning is not evidence that Firefox displayed a prompt,
  // accepted the package, or reloaded any existing page's extension code.
  bool get nativeDialogVerified => false;
  bool get activationVerified => false;
  bool get requiresUserConfirmation => launchRequested;
  Map<String, Object?> toJson() => <String, Object?>{
    'ok': launchRequested,
    'filesPrepared': filesPrepared,
    'artifactVerified': artifactVerified,
    'launchRequested': launchRequested,
    'nativeDialogVerified': nativeDialogVerified,
    'activationVerified': activationVerified,
    'requiresUserConfirmation': requiresUserConfirmation,
    'expectedVersion': expectedVersion,
    'expectedSha256': expectedSha256,
    'preparedXpiPath': preparedXpiPath,
    'message': message,
  };
}

final class FirefoxConnectResult {
  const FirefoxConnectResult({required this.ok, required this.message});
  final bool ok;
  final String message;
}

final class FirefoxProfileAddonStatus {
  const FirefoxProfileAddonStatus({
    required this.profilePath,
    required this.name,
    required this.version,
    required this.active,
    required this.signedState,
    required this.xpiPath,
    this.sha256,
  });
  final String profilePath, name, version, xpiPath;
  final bool active;
  final int? signedState;
  final String? sha256;
  FirefoxProfileAddonStatus withSha256(String? hash) =>
      FirefoxProfileAddonStatus(
        profilePath: profilePath,
        name: name,
        version: version,
        active: active,
        signedState: signedState,
        xpiPath: xpiPath,
        sha256: hash,
      );
  bool matches(String expectedVersion, String expectedHash) =>
      expectedVersion.isNotEmpty &&
      expectedHash.isNotEmpty &&
      active &&
      signedState == 2 &&
      version == expectedVersion &&
      sha256 == expectedHash;
}

final class FirefoxManagedRepairReport {
  const FirefoxManagedRepairReport({
    this.filesPrepared = false,
    this.rulesSnapshotPrepared = false,
    this.policiesApplied = false,
    this.expectedVersion = '',
    this.expectedSha256 = '',
    this.profiles = const <FirefoxProfileAddonStatus>[],
    this.profileTotal = 0,
    this.firefoxRunning = false,
    this.preparedXpiPath,
    this.message = '',
  });
  final bool filesPrepared,
      rulesSnapshotPrepared,
      policiesApplied,
      firefoxRunning;
  final String expectedVersion, expectedSha256, message;
  final String? preparedXpiPath;
  final List<FirefoxProfileAddonStatus> profiles;
  final int profileTotal;
  int get activeProfileCount =>
      profiles.where((s) => s.matches(expectedVersion, expectedSha256)).length;
  // This is disk profile metadata plus exact XPI bytes, not a live page probe.
  bool get activationVerified =>
      profileTotal > 0 && activeProfileCount == profileTotal;
  bool get browserConfirmationNeeded => !activationVerified;
  bool get nextRestartNeeded => policiesApplied && !activationVerified;
  bool get ok => filesPrepared && policiesApplied && activationVerified;
}
