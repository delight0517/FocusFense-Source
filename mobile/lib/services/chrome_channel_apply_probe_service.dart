import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'chrome_extension_auto_sync_service.dart';
import 'chrome_extension_identity.dart';
import 'chrome_extension_state_probe.dart';
import 'chrome_extension_payload_service.dart';
import 'chrome_extension_version.dart';
import 'chrome_load_extension_launcher.dart';
import 'extension_guard_prefs.dart';
import 'extension_rules_builder.dart';
import 'extension_rules_snapshot_service.dart';
import 'windows_chrome_extension_registry_native.dart';
import 'windows_extension_self_heal_service.dart';
import 'windows_hidden_process.dart';
import 'chrome_extension_install_verifier.dart';

/// Per-profile Chrome check: is **Focus Fense** (`popjkofklmidngceakpcokopghehjngo`,
/// a..p mapping of SHA-256(SubjectPublicKeyInfo)[0..15] of the bundled manifest key)
/// active and does its synced rules include the target YouTube @handle?
final class ChromeChannelApplyProbeService {
  ChromeChannelApplyProbeService._();
  static final ChromeChannelApplyProbeService instance =
      ChromeChannelApplyProbeService._();

  static const String kOurExtensionId = ChromeExtensionIdentity.extensionId;

  Future<ChromeChannelApplyReport> probeHandle(String rawHandleOrUrl) async {
    if (!Platform.isWindows) {
      return ChromeChannelApplyReport(
        handle: rawHandleOrUrl,
        searchTerms: <String>[rawHandleOrUrl],
        channelUrl: rawHandleOrUrl,
        overall: ChromeChannelApplyOverall.unsupported,
        profiles: const <ChromeChannelProfileProbe>[],
        summaryLines: const <String>['Windows 전용'],
      );
    }

    final String handle = _normalizeHandle(rawHandleOrUrl);
    final String channelUrl = handle.isEmpty
        ? rawHandleOrUrl
        : 'https://www.youtube.com/@$handle';
    final List<String> searchTerms = <String>[
      if (handle.isNotEmpty) handle,
      if (handle.isNotEmpty) '@$handle',
      channelUrl,
    ];

    final ExtensionRulesPayload rules =
        await ExtensionRulesBuilder.buildForBrowserEnforcement();
    final bool inAppRules = _handleInRules(handle, rules);
    final bool inPayloadSnapshot = await _handleInPayloadSnapshot(handle);
    final _RegistryScan registry = await _scanRegistry();

    final String? userData = _chromeUserDataRoot();
    final List<String> profileNames = await _listProfileNames(userData);
    final List<ChromeChannelProfileProbe> profileRows =
        <ChromeChannelProfileProbe>[];

    for (final String name in profileNames) {
      profileRows.add(
        await _probeProfile(
          userData: userData!,
          profileName: name,
          handle: handle,
          inAppRules: inAppRules,
          inPayloadSnapshot: inPayloadSnapshot,
          registry: registry,
        ),
      );
    }

    final bool loadExtReady = await _loadExtensionEnforcementReady();
    final int withOurExt = profileRows
        .where((ChromeChannelProfileProbe r) => r.ourExtensionActive)
        .length;
    final int withChannel = profileRows
        .where((ChromeChannelProfileProbe r) => r.channelInExtensionList)
        .length;

    final ChromeChannelApplyOverall overall;
    if (profileNames.isEmpty) {
      overall = ChromeChannelApplyOverall.notApplied;
    } else if (loadExtReady &&
        handle.isNotEmpty &&
        inAppRules &&
        inPayloadSnapshot) {
      // Consumer Chrome: extension loads via VBS --load-extension, not profile CRX.
      overall = ChromeChannelApplyOverall.applied;
    } else if (withChannel == profileNames.length && withChannel > 0) {
      overall = ChromeChannelApplyOverall.applied;
    } else if (withOurExt > 0 ||
        registry.policyReady ||
        inAppRules ||
        inPayloadSnapshot) {
      overall = ChromeChannelApplyOverall.partial;
    } else {
      overall = ChromeChannelApplyOverall.notApplied;
    }

    final List<String> summary = _buildSummary(
      handle: handle,
      channelUrl: channelUrl,
      searchTerms: searchTerms,
      overall: overall,
      inAppRules: inAppRules,
      inPayloadSnapshot: inPayloadSnapshot,
      registry: registry,
      profiles: profileRows,
    );

    return ChromeChannelApplyReport(
      handle: handle,
      searchTerms: searchTerms,
      channelUrl: channelUrl,
      inAppRules: inAppRules,
      inPayloadSnapshot: inPayloadSnapshot,
      overall: overall,
      profiles: profileRows,
      summaryLines: summary,
    );
  }

  List<String> _buildSummary({
    required String handle,
    required String channelUrl,
    required List<String> searchTerms,
    required ChromeChannelApplyOverall overall,
    required bool inAppRules,
    required bool inPayloadSnapshot,
    required _RegistryScan registry,
    required List<ChromeChannelProfileProbe> profiles,
  }) {
    final String title = overall == ChromeChannelApplyOverall.applied
        ? '적용됨'
        : overall == ChromeChannelApplyOverall.partial
        ? '부분 적용'
        : '미적용';
    final List<String> out = <String>[
      '### [$title] Google Chrome',
      if (overall == ChromeChannelApplyOverall.applied)
        'Google Chrome — 전 프로필에서 Focus Fense 확장·채널이 확인되었습니다.'
      else if (overall == ChromeChannelApplyOverall.partial &&
          profiles.any(
            (ChromeChannelProfileProbe p) =>
                p.ourExtensionActive && !p.channelInExtensionList,
          ))
        'Google Chrome — Focus Fense는 있으나 "@$handle" 채널이 확장 설정에 없습니다.'
      else if (overall == ChromeChannelApplyOverall.partial)
        'Google Chrome — 정책/페이로드는 준비됐으나 확장이 프로필에 로드되지 않았습니다.'
      else
        'Google Chrome — 차단 확장이 없거나 비활성입니다. 이 브라우저에는 채널 차단이 적용되지 않습니다.',
      '',
      '- 검색 채널: $channelUrl',
      '- 검색어: ${searchTerms.join(", ")}',
      '-',
      '- 「적용됨」= rules_snapshot·URLBlocklist·보호 Chrome(--load-extension) 경로 확인.',
      '- chrome://extensions 에 안 보여도 VBS 바로가기 실행 시 확장은 로드됩니다.',
    ];

    for (final ChromeChannelProfileProbe prof in profiles) {
      out.add(
        '- ▸ ${prof.profileName}: ${prof.statusEmoji} ${prof.statusText}',
      );
      if (prof.versionIssueCount > 0) {
        out.add(
          '-   ⚠️ 확장 버전 문제 ${prof.versionIssueCount}건 — '
          '플러그인 설치 실패/구버전 잔존 가능',
        );
      }
      if (prof.ourExtensionActive &&
          !prof.channelInExtensionList &&
          handle.isNotEmpty) {
        out.add('-   → chrome://extensions → Focus Fense → 확장 설정에 @$handle 없음');
      }
      if (!prof.ourExtensionActive && registry.policyReady) {
        out.add('-   → HKCU 정책은 있음 — Chrome 완전 종료 후 재실행');
      }
    }

    if (!inAppRules && handle.isNotEmpty) {
      out.add('');
      out.add('- 앱 차단 목록(DB)에 @$handle 이 없습니다 — 스케줄/키워드에 채널을 추가하세요.');
    }
    if (registry.registryVersionMismatch || registry.registryPathWrong) {
      out.add('- HKCU 확장 레지스트리 경로/버전 불일치 — 「자동 수정」으로 복구');
    }
    if (inPayloadSnapshot &&
        !profiles.any((ChromeChannelProfileProbe p) => p.ourExtensionActive)) {
      out.add('- chrome_blocker/rules_snapshot.json 에 채널 있음 — 확장만 미로드');
    }

    return out;
  }

  Future<ChromeChannelProfileProbe> _probeProfile({
    required String userData,
    required String profileName,
    required String handle,
    required bool inAppRules,
    required bool inPayloadSnapshot,
    required _RegistryScan registry,
  }) async {
    final String profilePath = p.join(userData, profileName);
    final File prefs = File(p.join(profilePath, 'Preferences'));
    final _PrefsScan prefsScan = await _scanPreferences(prefs);

    final List<String> installedVersions = <String>[];
    for (final String id
        in ChromeExtensionIdentity.recognizedExtensionIdsForBrowser('chrome')) {
      final Directory extRoot = Directory(
        p.join(profilePath, 'Extensions', id),
      );
      if (!await extRoot.exists()) continue;
      await for (final FileSystemEntity e in extRoot.list()) {
        if (e is Directory) {
          final String folder = p.basename(e.path);
          if (folder.isNotEmpty && folder != '_metadata') {
            installedVersions.add(folder.split('_').first);
          }
        }
      }
    }

    int versionIssues = 0;
    if (prefsScan.referencedInPrefs && installedVersions.isEmpty) {
      versionIssues++;
    }
    final String bundledVer = await ChromeExtensionVersion.bundled();
    for (final String v in installedVersions) {
      if (v != bundledVer) versionIssues++;
    }
    if (registry.registryPathWrong) versionIssues++;
    if (registry.registryVersionMismatch) versionIssues++;

    final bool loadExtReady = await _loadExtensionEnforcementReady();
    // @incident: store-identity-detection — policy/launcher readiness cannot
    // override a disabled or absent extension in this profile.
    final bool extEffective = prefsScan.ourExtensionActive;
    final bool channelInExt =
        handle.isNotEmpty && (inAppRules || inPayloadSnapshot) && extEffective;

    ChromeChannelProfileStatus status;
    if (extEffective && channelInExt) {
      status = ChromeChannelProfileStatus.applied;
    } else if (extEffective) {
      status = ChromeChannelProfileStatus.extensionNoChannel;
    } else if (registry.policyReady || inPayloadSnapshot || loadExtReady) {
      status = ChromeChannelProfileStatus.partialPolicyOrPayload;
    } else if (versionIssues > 0) {
      status = ChromeChannelProfileStatus.versionIssue;
    } else {
      status = ChromeChannelProfileStatus.noBlocker;
    }

    return ChromeChannelProfileProbe(
      profileName: profileName,
      ourExtensionActive: extEffective,
      channelInExtensionList: channelInExt,
      versionIssueCount: versionIssues,
      installedVersions: installedVersions,
      status: status,
    );
  }

  Future<_PrefsScan> _scanPreferences(File prefs) async {
    final ChromeExtensionProbeResult row =
        await ChromeExtensionStateProbe.readProfilePreferences(
          Directory(p.dirname(prefs.path)),
          browser: 'chrome',
        );
    return _PrefsScan(
      referencedInPrefs: !row.extensionNotPresent,
      ourExtensionActive: row.hasEnabledCopy,
    );
  }

  Future<_RegistryScan> _scanRegistry() async {
    const String key =
        r'HKCU\SOFTWARE\Google\Chrome\Extensions\popjkofklmidngceakpcokopghehjngo';
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final String reg = p.join(windir, 'System32', 'reg.exe');
    String? folderPath;
    String? regVersion;
    try {
      final ProcessResult r = await windowsRunHidden(reg, <String>[
        'query',
        key,
      ]);
      if (r.exitCode == 0) {
        for (final String line in '${r.stdout}'.split('\n')) {
          final String t = line.trim();
          if (t.contains('REG_SZ') && !t.contains('version')) {
            final int idx = t.indexOf('REG_SZ');
            folderPath = t.substring(idx + 'REG_SZ'.length).trim();
          }
          if (t.contains('version') && t.contains('REG_SZ')) {
            final int idx = t.indexOf('REG_SZ');
            regVersion = t.substring(idx + 'REG_SZ'.length).trim();
          }
        }
      }
    } catch (_) {}

    final String bundledVer = await ChromeExtensionVersion.bundled();
    final bool pathWrong =
        folderPath != null &&
        folderPath.toLowerCase().endsWith('manifest.json');
    final bool verMismatch =
        regVersion != null && regVersion.isNotEmpty && regVersion != bundledVer;

    bool policyReady = false;
    try {
      final ProcessResult pr = await windowsRunHidden(reg, <String>[
        'query',
        r'HKCU\SOFTWARE\Policies\Google\Chrome\ExtensionInstallForcelist',
      ]);
      policyReady =
          pr.exitCode == 0 &&
          ChromeExtensionIdentity.recognizedExtensionIdsForBrowser(
            'chrome',
          ).any((String id) => '${pr.stdout}'.contains(id));
    } catch (_) {}

    return _RegistryScan(
      folderPath: folderPath,
      registryVersion: regVersion,
      registryPathWrong: pathWrong,
      registryVersionMismatch: verMismatch,
      policyReady: policyReady,
    );
  }

  Future<bool> _loadExtensionEnforcementReady() async {
    if (!Platform.isWindows) return false;
    if (!await ChromeLoadExtensionLauncher.isInstalled()) return false;
    if (await ExtensionGuardPrefs.instance.isLoadExtensionFallback()) {
      return true;
    }
    return File(ChromeLoadExtensionLauncher.chromeVbsPath).existsSync();
  }

  Future<bool> _handleInPayloadSnapshot(String handle) async {
    if (handle.isEmpty) return false;
    final String folder = ChromeLoadExtensionLauncher.stableChromeExtDir;
    final File snap = File(
      p.join(folder, ExtensionRulesSnapshotService.kSnapshotFileName),
    );
    if (!await snap.exists()) return false;
    try {
      final Object? decoded = jsonDecode(await snap.readAsString());
      if (decoded is! Map<String, dynamic>) return false;
      final Object? handles = decoded['blockedYoutubeHandles'];
      if (handles is! List<Object?>) return false;
      final String h = handle.toLowerCase();
      for (final Object? raw in handles) {
        final String s = (raw as String? ?? '').trim().toLowerCase();
        if (s == h || s == '@$h') return true;
      }
    } catch (_) {}
    return false;
  }

  Future<List<String>> _listProfileNames(String? userData) async {
    if (userData == null) return <String>[];
    final List<String> names = <String>['Default'];
    try {
      await for (final FileSystemEntity e in Directory(userData).list()) {
        if (e is Directory) {
          final String name = p.basename(e.path);
          if (name.startsWith('Profile ')) names.add(name);
        }
      }
    } catch (_) {}
    names.sort((String a, String b) {
      if (a == 'Default') return -1;
      if (b == 'Default') return 1;
      return a.compareTo(b);
    });
    return names;
  }

  String? _chromeUserDataRoot() {
    final String? local = Platform.environment['LOCALAPPDATA'];
    if (local == null || local.isEmpty) return null;
    final Directory d = Directory(
      p.join(local, 'Google', 'Chrome', 'User Data'),
    );
    return d.existsSync() ? d.path : null;
  }

  bool _handleInRules(String handle, ExtensionRulesPayload rules) {
    if (handle.isEmpty) return false;
    final String h = handle.toLowerCase();
    for (final String raw in rules.blockedYoutubeHandles) {
      if (raw.toLowerCase() == h || raw.toLowerCase() == '@$h') return true;
    }
    for (final String kw in rules.keywords) {
      final String k = kw.toLowerCase();
      if (k.contains('/@$h') || k.contains('@$h')) return true;
    }
    for (final String raw in rules.rawKeywords) {
      final String k = raw.toLowerCase();
      if (k.contains('/@$h') || k.contains('@$h')) return true;
    }
    return false;
  }

  String _normalizeHandle(String raw) {
    String s = raw.trim();
    if (s.isEmpty) return '';
    try {
      if (s.contains('youtube.com')) {
        final Uri? u = Uri.tryParse(s.startsWith('http') ? s : 'https://$s');
        if (u != null) {
          final RegExpMatch? m = RegExp(r'/@([^/?#]+)').firstMatch(u.path);
          if (m != null) s = m.group(1)!;
        }
      }
    } catch (_) {}
    if (s.startsWith('@')) s = s.substring(1);
    try {
      s = Uri.decodeComponent(s);
    } catch (_) {}
    return s.trim().toLowerCase();
  }

  /// Export payload + HKCU registry + forcelist + shortcut launchers.
  Future<ChromeChannelRepairResult> repairForHandle(String handleOrUrl) async {
    if (!Platform.isWindows) {
      return const ChromeChannelRepairResult(ok: false, message: 'Windows 전용');
    }
    try {
      final ChromeExtensionSyncResult sync =
          await ChromeExtensionAutoSyncService.instance.syncIfNeeded(
            force: true,
            reason: 'chrome_channel_repair',
          );
      final String? folder =
          await ChromeExtensionPayloadService.ensureStablePayload();
      if (folder != null && folder.isNotEmpty) {
        await ExtensionRulesSnapshotService.instance.writeToChromePayload(
          sourceFolder: folder,
        );
        final String ver = await ChromeExtensionVersion.bundled();
        await WindowsChromeExtensionRegistryNative.registerChromeAndEdge(
          extensionId: kOurExtensionId,
          extensionFolder: folder,
          version: ver,
        );
        await WindowsExtensionSelfHealService.instance.reapplyHkcuOnly(
          sourceFolder: folder,
        );
      }
      final ChromeInstallVerifyReport verify =
          await ChromeExtensionInstallVerifier.instance.verifyAndRepair(
            force: true,
            reason: 'chrome_channel_repair',
          );
      return ChromeChannelRepairResult(
        ok: sync.ok || verify.ok,
        message:
            '${verify.verdict} · 채널=$handleOrUrl — '
            'Chrome 완전 종료 후 재실행 · chrome://extensions 확인',
      );
    } catch (e) {
      return ChromeChannelRepairResult(ok: false, message: 'Chrome 복구 실패: $e');
    }
  }
}

class _PrefsScan {
  const _PrefsScan({
    required this.referencedInPrefs,
    required this.ourExtensionActive,
  });
  final bool referencedInPrefs;
  final bool ourExtensionActive;
}

class _RegistryScan {
  const _RegistryScan({
    this.folderPath,
    this.registryVersion,
    this.registryPathWrong = false,
    this.registryVersionMismatch = false,
    this.policyReady = false,
  });
  final String? folderPath;
  final String? registryVersion;
  final bool registryPathWrong;
  final bool registryVersionMismatch;
  final bool policyReady;
}

enum ChromeChannelApplyOverall { applied, partial, notApplied, unsupported }

enum ChromeChannelProfileStatus {
  applied,
  extensionNoChannel,
  partialPolicyOrPayload,
  versionIssue,
  noBlocker,
}

class ChromeChannelProfileProbe {
  const ChromeChannelProfileProbe({
    required this.profileName,
    required this.ourExtensionActive,
    required this.channelInExtensionList,
    required this.versionIssueCount,
    required this.installedVersions,
    required this.status,
  });

  final String profileName;
  final bool ourExtensionActive;
  final bool channelInExtensionList;
  final int versionIssueCount;
  final List<String> installedVersions;
  final ChromeChannelProfileStatus status;

  String get statusEmoji => switch (status) {
    ChromeChannelProfileStatus.applied => '✅',
    ChromeChannelProfileStatus.extensionNoChannel => '⚠️',
    ChromeChannelProfileStatus.partialPolicyOrPayload => '⚠️',
    ChromeChannelProfileStatus.versionIssue => '⚠️',
    ChromeChannelProfileStatus.noBlocker => '❌',
  };

  String get statusText => switch (status) {
    ChromeChannelProfileStatus.applied => 'Focus Fense + 채널 확인됨',
    ChromeChannelProfileStatus.extensionNoChannel =>
      'Focus Fense 있음, 이 채널은 리스트에 없음',
    ChromeChannelProfileStatus.partialPolicyOrPayload =>
      '정책/페이로드만 — 확장 미로드 또는 재시작 필요',
    ChromeChannelProfileStatus.versionIssue => '확장 버전/잔존 문제',
    ChromeChannelProfileStatus.noBlocker => '차단 확장 없음',
  };
}

class ChromeChannelApplyReport {
  const ChromeChannelApplyReport({
    required this.handle,
    required this.searchTerms,
    required this.channelUrl,
    required this.overall,
    required this.profiles,
    required this.summaryLines,
    this.inAppRules = false,
    this.inPayloadSnapshot = false,
  });

  final String handle;
  final List<String> searchTerms;
  final String channelUrl;
  final bool inAppRules;
  final bool inPayloadSnapshot;
  final ChromeChannelApplyOverall overall;
  final List<ChromeChannelProfileProbe> profiles;
  final List<String> summaryLines;

  String get markdown => summaryLines.join('\n');
}

class ChromeChannelRepairResult {
  const ChromeChannelRepairResult({required this.ok, required this.message});
  final bool ok;
  final String message;
}
