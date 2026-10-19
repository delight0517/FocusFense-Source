import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'chrome_channel_apply_probe_service.dart';
import 'chrome_extension_identity.dart';
import 'chrome_extension_state_probe.dart';
import 'chrome_extension_version.dart';
import 'chrome_load_extension_launcher.dart';
import 'extension_guard_prefs.dart';
import 'extension_rules_builder.dart';
import 'extension_rules_snapshot_service.dart';
import 'windows_hidden_process.dart';

/// Per-profile Edge check with browser-scoped local/store identity recognition.
final class EdgeChannelApplyProbeService {
  EdgeChannelApplyProbeService._();
  static final EdgeChannelApplyProbeService instance =
      EdgeChannelApplyProbeService._();

  static const String kOurExtensionId = ChromeExtensionIdentity.extensionId;

  Future<EdgeChannelApplyReport> probeHandle(String rawHandleOrUrl) async {
    if (!Platform.isWindows) {
      return EdgeChannelApplyReport(
        handle: rawHandleOrUrl,
        searchTerms: <String>[rawHandleOrUrl],
        channelUrl: rawHandleOrUrl,
        overall: EdgeChannelApplyOverall.unsupported,
        profiles: const <EdgeChannelProfileProbe>[],
        summaryLines: const <String>['Windows 전용'],
      );
    }

    if (!await _isEdgeInstalled()) {
      return EdgeChannelApplyReport(
        handle: _normalizeHandle(rawHandleOrUrl),
        searchTerms: <String>[rawHandleOrUrl],
        channelUrl: rawHandleOrUrl,
        overall: EdgeChannelApplyOverall.notInstalled,
        profiles: const <EdgeChannelProfileProbe>[],
        summaryLines: const <String>[
          '### [정보] Microsoft Edge',
          'Microsoft Edge 미설치 또는 프로필 없음 — 이 브라우저에는 차단이 적용되지 않습니다.',
        ],
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
    final _EdgeRegistryScan registry = await _scanRegistry();

    final String? userData = _edgeUserDataRoot();
    final List<String> profileNames = await _listProfileNames(userData);
    final List<EdgeChannelProfileProbe> profileRows =
        <EdgeChannelProfileProbe>[];

    if (userData != null) {
      for (final String name in profileNames) {
        profileRows.add(
          await _probeProfile(
            userData: userData,
            profileName: name,
            handle: handle,
            inAppRules: inAppRules,
            inPayloadSnapshot: inPayloadSnapshot,
            registry: registry,
          ),
        );
      }
    }

    final bool loadExtReady = await _loadExtensionEnforcementReady();
    final int withOurExt = profileRows
        .where((EdgeChannelProfileProbe r) => r.ourExtensionActive)
        .length;
    final int withChannel = profileRows
        .where((EdgeChannelProfileProbe r) => r.channelInExtensionList)
        .length;

    final EdgeChannelApplyOverall overall;
    if (profileNames.isEmpty) {
      overall = EdgeChannelApplyOverall.notInstalled;
    } else if (loadExtReady &&
        handle.isNotEmpty &&
        inAppRules &&
        inPayloadSnapshot) {
      overall = EdgeChannelApplyOverall.applied;
    } else if (withChannel == profileNames.length && withChannel > 0) {
      overall = EdgeChannelApplyOverall.applied;
    } else if (withOurExt > 0 ||
        registry.policyReady ||
        inAppRules ||
        inPayloadSnapshot) {
      overall = EdgeChannelApplyOverall.partial;
    } else {
      overall = EdgeChannelApplyOverall.notApplied;
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

    return EdgeChannelApplyReport(
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
    required EdgeChannelApplyOverall overall,
    required bool inAppRules,
    required bool inPayloadSnapshot,
    required _EdgeRegistryScan registry,
    required List<EdgeChannelProfileProbe> profiles,
  }) {
    if (overall == EdgeChannelApplyOverall.notInstalled) {
      return const <String>[
        '### [정보] Microsoft Edge',
        'Microsoft Edge 미설치 또는 프로필 없음 — 이 브라우저에는 차단이 적용되지 않습니다.',
      ];
    }

    final String title = overall == EdgeChannelApplyOverall.applied
        ? '적용됨'
        : overall == EdgeChannelApplyOverall.partial
        ? '부분 적용'
        : '미적용';
    final List<String> out = <String>[
      '### [$title] Microsoft Edge',
      if (overall == EdgeChannelApplyOverall.applied)
        'Microsoft Edge — 전 프로필에서 Focus Fense 확장·채널이 확인되었습니다.'
      else if (overall == EdgeChannelApplyOverall.partial &&
          profiles.any(
            (EdgeChannelProfileProbe p) =>
                p.ourExtensionActive && !p.channelInExtensionList,
          ))
        'Microsoft Edge — Focus Fense는 있으나 "@$handle" 채널이 확장 설정에 없습니다.'
      else if (overall == EdgeChannelApplyOverall.partial)
        'Microsoft Edge — 정책/페이로드는 준비됐으나 확장이 프로필에 로드되지 않았습니다.'
      else
        'Microsoft Edge — 차단 확장이 없거나 비활성입니다. 이 브라우저에는 채널 차단이 적용되지 않습니다.',
      '',
      '- 검색 채널: $channelUrl',
      '- 검색어: ${searchTerms.join(", ")}',
      '-',
      '- 「적용됨」은 차단 확장 설정·Extension Settings 에서 채널이 확인될 때만 표시합니다.',
      '- YouTube 시청/검색 기록만 있으면 오탐이므로 「부분 적용」으로 분류합니다.',
    ];

    for (final EdgeChannelProfileProbe prof in profiles) {
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
        out.add('-   → edge://extensions → Focus Fense → 확장 설정에 @$handle 없음');
      }
      if (!prof.ourExtensionActive && registry.policyReady) {
        out.add('-   → HKCU 정책은 있음 — Edge 완전 종료 후 재실행');
      }
    }

    if (!inAppRules && handle.isNotEmpty) {
      out.add('');
      out.add('- 앱 차단 목록(DB)에 @$handle 이 없습니다 — 스케줄/키워드에 채널을 추가하세요.');
    }
    if (registry.registryVersionMismatch || registry.registryPathWrong) {
      out.add('- HKCU 확장 레지스트리 경로/버전 불일치 — 「자동 수정」으로 복구');
    }

    return out;
  }

  Future<EdgeChannelProfileProbe> _probeProfile({
    required String userData,
    required String profileName,
    required String handle,
    required bool inAppRules,
    required bool inPayloadSnapshot,
    required _EdgeRegistryScan registry,
  }) async {
    final String profilePath = p.join(userData, profileName);
    final File prefs = File(p.join(profilePath, 'Preferences'));
    final _EdgePrefsScan prefsScan = await _scanPreferences(prefs);

    final List<String> installedVersions = <String>[];
    for (final String id
        in ChromeExtensionIdentity.recognizedExtensionIdsForBrowser('edge')) {
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

    EdgeChannelProfileStatus status;
    if (extEffective && channelInExt) {
      status = EdgeChannelProfileStatus.applied;
    } else if (extEffective) {
      status = EdgeChannelProfileStatus.extensionNoChannel;
    } else if (registry.policyReady || inPayloadSnapshot || loadExtReady) {
      status = EdgeChannelProfileStatus.partialPolicyOrPayload;
    } else if (versionIssues > 0) {
      status = EdgeChannelProfileStatus.versionIssue;
    } else {
      status = EdgeChannelProfileStatus.noBlocker;
    }

    return EdgeChannelProfileProbe(
      profileName: profileName,
      ourExtensionActive: extEffective,
      channelInExtensionList: channelInExt,
      versionIssueCount: versionIssues,
      installedVersions: installedVersions,
      status: status,
    );
  }

  Future<_EdgePrefsScan> _scanPreferences(File prefs) async {
    final ChromeExtensionProbeResult row =
        await ChromeExtensionStateProbe.readProfilePreferences(
          Directory(p.dirname(prefs.path)),
          browser: 'edge',
        );
    return _EdgePrefsScan(
      referencedInPrefs: !row.extensionNotPresent,
      ourExtensionActive: row.hasEnabledCopy,
    );
  }

  Future<_EdgeRegistryScan> _scanRegistry() async {
    const String key =
        r'HKCU\SOFTWARE\Microsoft\Edge\Extensions\popjkofklmidngceakpcokopghehjngo';
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
        r'HKCU\SOFTWARE\Policies\Microsoft\Edge\ExtensionInstallForcelist',
      ]);
      policyReady =
          pr.exitCode == 0 &&
          ChromeExtensionIdentity.recognizedExtensionIdsForBrowser(
            'edge',
          ).any((String id) => '${pr.stdout}'.contains(id));
    } catch (_) {}

    return _EdgeRegistryScan(
      folderPath: folderPath,
      registryVersion: regVersion,
      registryPathWrong: pathWrong,
      registryVersionMismatch: verMismatch,
      policyReady: policyReady,
    );
  }

  Future<bool> _isEdgeInstalled() async {
    final String pf =
        Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
    final String pf86 =
        Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';
    for (final String base in <String>[pf, pf86]) {
      if (File(
        p.join(base, 'Microsoft', 'Edge', 'Application', 'msedge.exe'),
      ).existsSync()) {
        return true;
      }
    }
    final String? local = Platform.environment['LOCALAPPDATA'];
    if (local == null || local.isEmpty) return false;
    final File localState = File(
      p.join(local, 'Microsoft', 'Edge', 'User Data', 'Local State'),
    );
    if (await localState.exists()) return true;
    final Directory userData = Directory(
      p.join(local, 'Microsoft', 'Edge', 'User Data'),
    );
    return userData.existsSync();
  }

  Future<bool> _loadExtensionEnforcementReady() async {
    if (!Platform.isWindows) return false;
    if (!await ChromeLoadExtensionLauncher.isInstalled()) return false;
    if (await ExtensionGuardPrefs.instance.isLoadExtensionFallback()) {
      return true;
    }
    return File(ChromeLoadExtensionLauncher.edgeVbsPath).existsSync();
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
    final Set<String> names = <String>{};

    final File localState = File(p.join(userData, 'Local State'));
    if (await localState.exists()) {
      try {
        final Object? decoded = jsonDecode(await localState.readAsString());
        if (decoded is Map<String, dynamic>) {
          final Object? profile = decoded['profile'];
          if (profile is Map<String, dynamic>) {
            final Object? cache = profile['info_cache'];
            if (cache is Map<String, dynamic>) {
              names.addAll(cache.keys.map((Object k) => k.toString()));
            }
          }
        }
      } catch (_) {}
    }

    if (names.isEmpty) {
      if (await Directory(p.join(userData, 'Default')).exists()) {
        names.add('Default');
      }
      try {
        await for (final FileSystemEntity e in Directory(userData).list()) {
          if (e is Directory) {
            final String name = p.basename(e.path);
            if (name.startsWith('Profile ')) names.add(name);
          }
        }
      } catch (_) {}
    }

    final List<String> sorted = names.toList();
    sorted.sort((String a, String b) {
      if (a == 'Default') return -1;
      if (b == 'Default') return 1;
      return a.compareTo(b);
    });
    return sorted;
  }

  String? _edgeUserDataRoot() {
    final String? local = Platform.environment['LOCALAPPDATA'];
    if (local == null || local.isEmpty) return null;
    final Directory d = Directory(
      p.join(local, 'Microsoft', 'Edge', 'User Data'),
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

  /// Chrome repair path also registers Edge HKCU keys + forcelist.
  Future<EdgeChannelRepairResult> repairForHandle(String handleOrUrl) async {
    final ChromeChannelRepairResult chrome =
        await ChromeChannelApplyProbeService.instance.repairForHandle(
          handleOrUrl,
        );
    return EdgeChannelRepairResult(
      ok: chrome.ok,
      message: chrome.message
          .replaceAll('Chrome', 'Chrome/Edge')
          .replaceAll('chrome://extensions', 'edge://extensions'),
    );
  }
}

class _EdgePrefsScan {
  const _EdgePrefsScan({
    required this.referencedInPrefs,
    required this.ourExtensionActive,
  });
  final bool referencedInPrefs;
  final bool ourExtensionActive;
}

class _EdgeRegistryScan {
  const _EdgeRegistryScan({
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

enum EdgeChannelApplyOverall {
  applied,
  partial,
  notApplied,
  notInstalled,
  unsupported,
}

enum EdgeChannelProfileStatus {
  applied,
  extensionNoChannel,
  partialPolicyOrPayload,
  versionIssue,
  noBlocker,
}

class EdgeChannelProfileProbe {
  const EdgeChannelProfileProbe({
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
  final EdgeChannelProfileStatus status;

  String get statusEmoji => switch (status) {
    EdgeChannelProfileStatus.applied => '✅',
    EdgeChannelProfileStatus.extensionNoChannel => '⚠️',
    EdgeChannelProfileStatus.partialPolicyOrPayload => '⚠️',
    EdgeChannelProfileStatus.versionIssue => '⚠️',
    EdgeChannelProfileStatus.noBlocker => '❌',
  };

  String get statusText => switch (status) {
    EdgeChannelProfileStatus.applied => 'Focus Fense + 채널 확인됨',
    EdgeChannelProfileStatus.extensionNoChannel =>
      'Focus Fense 있음, 이 채널은 리스트에 없음',
    EdgeChannelProfileStatus.partialPolicyOrPayload =>
      '정책/페이로드만 — 확장 미로드 또는 재시작 필요',
    EdgeChannelProfileStatus.versionIssue => '확장 버전/잔존 문제',
    EdgeChannelProfileStatus.noBlocker => '차단 확장 없음',
  };
}

class EdgeChannelApplyReport {
  const EdgeChannelApplyReport({
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
  final EdgeChannelApplyOverall overall;
  final List<EdgeChannelProfileProbe> profiles;
  final List<String> summaryLines;

  String get markdown => summaryLines.join('\n');

  /// Informational only — Edge not on this PC.
  bool get isInformational =>
      overall == EdgeChannelApplyOverall.notInstalled ||
      overall == EdgeChannelApplyOverall.unsupported;
}

class EdgeChannelRepairResult {
  const EdgeChannelRepairResult({required this.ok, required this.message});
  final bool ok;
  final String message;
}
