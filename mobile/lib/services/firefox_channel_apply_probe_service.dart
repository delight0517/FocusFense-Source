import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'chrome_load_extension_launcher.dart';
import 'extension_rules_builder.dart';
import 'extension_rules_snapshot_service.dart';
import 'firefox_config_service.dart';
import 'windows_extension_guard_service.dart';
import 'windows_firefox_extension_install_service.dart';
import 'windows_hidden_process.dart';

/// Per-profile Firefox check: is **Focus Fense** (`sixvpn-blocker@sixvpnblocker.app`)
/// active and does its synced rules include the target YouTube @handle?
///
/// Third-party blockers (AdBlock, Cold Turkey, Unhook, …) are listed for
/// context but do **not** count as 「차단 확장」 — only our extension does.
final class FirefoxChannelApplyProbeService {
  FirefoxChannelApplyProbeService._();
  static final FirefoxChannelApplyProbeService instance =
      FirefoxChannelApplyProbeService._();

  static const String kOurExtensionId = kFirefoxExtensionId;

  Future<FirefoxChannelApplyReport> probeHandle(String rawHandleOrUrl) async {
    if (!Platform.isWindows) {
      return FirefoxChannelApplyReport(
        handle: rawHandleOrUrl,
        searchTerms: <String>[rawHandleOrUrl],
        channelUrl: rawHandleOrUrl,
        overall: FirefoxChannelApplyOverall.unsupported,
        profiles: const <FirefoxChannelProfileProbe>[],
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
    final List<String> websiteFilterHits =
        await _websiteFilterPatternsForHandle(handle);
    final bool policyReady = await _hkcuExtensionPolicyReady();

    final List<Directory> profiles = await FirefoxConfigService.instance
        .profileDirs();
    final List<FirefoxChannelProfileProbe> profileRows =
        <FirefoxChannelProfileProbe>[];

    for (final Directory dir in profiles) {
      profileRows.add(
        await _probeProfile(
          profileDir: dir,
          handle: handle,
          inAppRules: inAppRules,
          websiteFilterHits: websiteFilterHits,
        ),
      );
    }

    final int withOurExt = profileRows
        .where((FirefoxChannelProfileProbe r) => r.ourExtensionActive)
        .length;
    final int withChannel = profileRows
        .where((FirefoxChannelProfileProbe r) => r.channelInExtensionList)
        .length;

    final bool xpiReady = await _programDataXpiReady();
    final FirefoxChannelApplyOverall overall;
    if (profiles.isEmpty) {
      overall = FirefoxChannelApplyOverall.notApplied;
    } else if (handle.isNotEmpty &&
        inAppRules &&
        inPayloadSnapshot &&
        (websiteFilterHits.isNotEmpty ||
            policyReady && xpiReady ||
            withOurExt > 0)) {
      overall = FirefoxChannelApplyOverall.applied;
    } else if (withChannel == profiles.length && withChannel > 0) {
      overall = FirefoxChannelApplyOverall.applied;
    } else if (withOurExt > 0 ||
        websiteFilterHits.isNotEmpty ||
        inAppRules ||
        (policyReady && xpiReady)) {
      overall = FirefoxChannelApplyOverall.partial;
    } else {
      overall = FirefoxChannelApplyOverall.notApplied;
    }

    final List<String> summary = _buildSummary(
      handle: handle,
      channelUrl: channelUrl,
      searchTerms: searchTerms,
      overall: overall,
      inAppRules: inAppRules,
      websiteFilterHits: websiteFilterHits,
      profiles: profileRows,
    );

    return FirefoxChannelApplyReport(
      handle: handle,
      searchTerms: searchTerms,
      channelUrl: channelUrl,
      inAppRules: inAppRules,
      websiteFilterPatternCount: websiteFilterHits.length,
      overall: overall,
      profiles: profileRows,
      summaryLines: summary,
    );
  }

  List<String> _buildSummary({
    required String handle,
    required String channelUrl,
    required List<String> searchTerms,
    required FirefoxChannelApplyOverall overall,
    required bool inAppRules,
    required List<String> websiteFilterHits,
    required List<FirefoxChannelProfileProbe> profiles,
  }) {
    final String title = overall == FirefoxChannelApplyOverall.applied
        ? '적용됨'
        : overall == FirefoxChannelApplyOverall.partial
        ? '부분 적용'
        : '미적용';
    final List<String> out = <String>[
      '### [$title] Firefox',
      if (overall == FirefoxChannelApplyOverall.partial &&
          profiles.any(
            (FirefoxChannelProfileProbe p) =>
                p.otherBlockerNames.isNotEmpty && !p.ourExtensionActive,
          ))
        'Firefox — 차단 확장은 있으나 "@$handle" 채널이 확장 설정에 없습니다. 블로커 리스트를 확인하세요.'
      else if (overall != FirefoxChannelApplyOverall.applied)
        'Firefox — Focus Fense 확장이 프로필에 로드되지 않았거나 채널이 동기화되지 않았습니다.',
      '',
      '- 검색 채널: $channelUrl',
      '- 검색어: ${searchTerms.join(", ")}',
      '-',
      '- 「적용됨」= rules_snapshot + WebsiteFilter/정책 XPI + (가능하면) 확장 활성.',
      '- XPI만 있고 미로드면 Firefox 완전 종료 후 재실행하세요.',
    ];

    for (final FirefoxChannelProfileProbe prof in profiles) {
      out.add(
        '- ▸ ${prof.profileName}: ${prof.statusEmoji} ${prof.statusText}',
      );
      if (prof.otherBlockerNames.isNotEmpty) {
        out.add('-   활성 확장: ${prof.otherBlockerNames.take(6).join(", ")}');
      }
      if (prof.ourExtensionActive &&
          !prof.channelInExtensionList &&
          handle.isNotEmpty) {
        out.add(
          '-   → 확장 설정 → YouTube 채널 목록에 @$handle 없음 (앱 「지금 적용」 후 Firefox 재시작)',
        );
      }
      if (prof.xpiOnDisk && !prof.ourExtensionActive) {
        out.add('-   → XPI 파일은 있으나 미로드 — Firefox 완전 종료 후 재실행');
      }
    }

    if (!inAppRules && handle.isNotEmpty) {
      out.add('');
      out.add('- 앱 차단 목록(DB)에 @$handle 이 없습니다 — 스케줄/키워드에 채널을 추가하세요.');
    }
    if (websiteFilterHits.isEmpty && handle.isNotEmpty) {
      out.add('- Firefox WebsiteFilter(HKCU)에 채널 패턴 없음 — 설정 → 「지금 적용」');
    } else if (websiteFilterHits.isNotEmpty) {
      out.add(
        '- Firefox WebsiteFilter: ${websiteFilterHits.length}개 패턴 (정책만 — 확장 설정과 별개)',
      );
    }

    return out;
  }

  Future<FirefoxChannelProfileProbe> _probeProfile({
    required Directory profileDir,
    required String handle,
    required bool inAppRules,
    required List<String> websiteFilterHits,
  }) async {
    final String profileName = p.basename(profileDir.path);
    final File xpi = File(
      p.join(profileDir.path, 'extensions', '${kOurExtensionId}.xpi'),
    );
    final bool xpiOnDisk = await xpi.exists();

    final _ExtensionScan scan = await _scanExtensionsJson(profileDir);
    final bool channelInExt =
        handle.isNotEmpty &&
        (inAppRules || await _channelInProfileStorage(profileDir, handle)) &&
        (scan.ourExtensionActive || websiteFilterHits.isNotEmpty || xpiOnDisk);

    FirefoxChannelProfileStatus status;
    if (scan.ourExtensionActive && channelInExt) {
      status = FirefoxChannelProfileStatus.applied;
    } else if (scan.ourExtensionActive) {
      status = FirefoxChannelProfileStatus.extensionNoChannel;
    } else if (xpiOnDisk || websiteFilterHits.isNotEmpty) {
      status = FirefoxChannelProfileStatus.partialPolicyOrXpi;
    } else if (scan.otherBlockerNames.isNotEmpty) {
      status = FirefoxChannelProfileStatus.otherBlockersOnly;
    } else {
      status = FirefoxChannelProfileStatus.noBlocker;
    }

    return FirefoxChannelProfileProbe(
      profileName: profileName,
      ourExtensionActive: scan.ourExtensionActive,
      channelInExtensionList: channelInExt,
      xpiOnDisk: xpiOnDisk,
      otherBlockerNames: scan.otherBlockerNames,
      status: status,
    );
  }

  Future<_ExtensionScan> _scanExtensionsJson(Directory profileDir) async {
    final File f = File(p.join(profileDir.path, 'extensions.json'));
    if (!await f.exists()) {
      return const _ExtensionScan(
        ourExtensionActive: false,
        otherBlockerNames: <String>[],
      );
    }
    try {
      final Object? decoded = jsonDecode(await f.readAsString());
      if (decoded is! Map<String, dynamic>) {
        return const _ExtensionScan(
          ourExtensionActive: false,
          otherBlockerNames: <String>[],
        );
      }
      final Object? addons = decoded['addons'];
      if (addons is! List<Object?>) {
        return const _ExtensionScan(
          ourExtensionActive: false,
          otherBlockerNames: <String>[],
        );
      }

      bool ours = false;
      final List<String> others = <String>[];
      final Set<String> seen = <String>{};

      for (final Object? raw in addons) {
        if (raw is! Map<String, dynamic>) continue;
        final String id = (raw['id'] as String? ?? '').trim();
        final bool active = raw['active'] == true;
        final bool userDisabled = raw['userDisabled'] == true;
        if (!active || userDisabled) continue;
        if (id == kOurExtensionId) {
          ours = true;
          continue;
        }
        final String type = (raw['type'] as String? ?? '').toLowerCase();
        if (type != 'extension') continue;
        final Object? loc = raw['defaultLocale'];
        String name = id;
        if (loc is Map<String, dynamic>) {
          name = (loc['name'] as String? ?? name).trim();
        }
        final String key = name.toLowerCase();
        if (seen.add(key) && _looksLikeBlocker(name)) {
          others.add(name);
        }
      }
      return _ExtensionScan(
        ourExtensionActive: ours,
        otherBlockerNames: others,
      );
    } catch (_) {
      return const _ExtensionScan(
        ourExtensionActive: false,
        otherBlockerNames: <String>[],
      );
    }
  }

  bool _looksLikeBlocker(String name) {
    final String n = name.toLowerCase();
    const List<String> hints = <String>[
      'block',
      'adblock',
      'unhook',
      'turkey',
      'focus',
      'leak',
      'one sec',
      '6 vpn',
      'sixvpn',
    ];
    for (final String h in hints) {
      if (n.contains(h)) return true;
    }
    return false;
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

  Future<bool> _hkcuExtensionPolicyReady() async {
    const String key = r'HKCU\SOFTWARE\Policies\Mozilla\Firefox';
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final String reg = p.join(windir, 'System32', 'reg.exe');
    try {
      final ProcessResult r = await windowsRunHidden(reg, <String>[
        'query',
        key,
      ]);
      return r.exitCode == 0 && '$r.stdout'.contains(kOurExtensionId);
    } catch (_) {
      return false;
    }
  }

  Future<bool> _programDataXpiReady() async {
    final String pd = Platform.environment['ProgramData'] ?? r'C:\ProgramData';
    return File(
      p.join(pd, 'SixVPNBlocker', 'firefox', '$kOurExtensionId.xpi'),
    ).existsSync();
  }

  Future<bool> _channelInProfileStorage(
    Directory profileDir,
    String handle,
  ) async {
    final String h = handle.toLowerCase();
    final Directory syncDir = Directory(
      p.join(
        profileDir.path,
        'browser-extension-data',
        kOurExtensionId,
        'storage',
        'sync',
      ),
    );
    if (!await syncDir.exists()) return false;

    try {
      await for (final FileSystemEntity e in syncDir.list(recursive: true)) {
        if (e is! File) continue;
        final String name = p.basename(e.path).toLowerCase();
        if (!name.endsWith('.json') && name != 'data') continue;
        final String raw = await e.readAsString();
        if (raw.toLowerCase().contains(h) ||
            raw.toLowerCase().contains('@$h')) {
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  Future<List<String>> _websiteFilterPatternsForHandle(String handle) async {
    if (handle.isEmpty) return <String>[];
    final List<String> all = await _readWebsiteFilterPatterns();
    final String h = handle.toLowerCase();
    return all.where((String p) => p.toLowerCase().contains(h)).toList();
  }

  Future<List<String>> _readWebsiteFilterPatterns() async {
    const String key =
        r'HKCU\SOFTWARE\Policies\Mozilla\Firefox\WebsiteFilter\Block';
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final String reg = p.join(windir, 'System32', 'reg.exe');
    try {
      final ProcessResult r = await windowsRunHidden(reg, <String>[
        'query',
        key,
        '/s',
      ]);
      if (r.exitCode != 0) return <String>[];
      final List<String> out = <String>[];
      for (final String line in '${r.stdout}'.split('\n')) {
        if (!line.contains('REG_SZ') || line.contains('(Default)')) continue;
        final int idx = line.indexOf('REG_SZ');
        if (idx < 0) continue;
        final String val = line.substring(idx + 'REG_SZ'.length).trim();
        if (val.isNotEmpty) out.add(val);
      }
      return out;
    } catch (_) {
      return <String>[];
    }
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

  /// Re-export + XPI + HKCU ExtensionSettings + WebsiteFilter (no UAC).
  Future<FirefoxChannelRepairResult> repairForHandle(String handleOrUrl) async {
    if (!Platform.isWindows) {
      return const FirefoxChannelRepairResult(ok: false, message: 'Windows 전용');
    }
    try {
      await WindowsFirefoxExtensionInstallService.instance
          .applyHkcuExtensionPolicy();
      final FirefoxInstallVerifyResult v =
          await WindowsFirefoxExtensionInstallService.verify();
      return FirefoxChannelRepairResult(
        ok: v.profileCount > 0 && v.xpiInProgramData,
        message:
            'Firefox XPI ${v.profileCount}/${v.profileTotal} 프로필 · '
            'policies=${v.policiesOk ? "OK" : "없음"} · '
            '채널=$handleOrUrl — Firefox 완전 종료 후 재실행하세요.',
      );
    } catch (e) {
      return FirefoxChannelRepairResult(
        ok: false,
        message: 'Firefox 복구 실패: $e',
      );
    }
  }
}

class _ExtensionScan {
  const _ExtensionScan({
    required this.ourExtensionActive,
    required this.otherBlockerNames,
  });
  final bool ourExtensionActive;
  final List<String> otherBlockerNames;
}

enum FirefoxChannelApplyOverall { applied, partial, notApplied, unsupported }

enum FirefoxChannelProfileStatus {
  applied,
  extensionNoChannel,
  partialPolicyOrXpi,
  otherBlockersOnly,
  noBlocker,
}

class FirefoxChannelProfileProbe {
  const FirefoxChannelProfileProbe({
    required this.profileName,
    required this.ourExtensionActive,
    required this.channelInExtensionList,
    required this.xpiOnDisk,
    required this.otherBlockerNames,
    required this.status,
  });

  final String profileName;
  final bool ourExtensionActive;
  final bool channelInExtensionList;
  final bool xpiOnDisk;
  final List<String> otherBlockerNames;
  final FirefoxChannelProfileStatus status;

  String get statusEmoji => switch (status) {
    FirefoxChannelProfileStatus.applied => '✅',
    FirefoxChannelProfileStatus.extensionNoChannel => '⚠️',
    FirefoxChannelProfileStatus.partialPolicyOrXpi => '⚠️',
    FirefoxChannelProfileStatus.otherBlockersOnly => '⚠️',
    FirefoxChannelProfileStatus.noBlocker => '❌',
  };

  String get statusText => switch (status) {
    FirefoxChannelProfileStatus.applied => 'Focus Fense + 채널 확인됨',
    FirefoxChannelProfileStatus.extensionNoChannel =>
      'Focus Fense 있음, 이 채널은 리스트에 없음',
    FirefoxChannelProfileStatus.partialPolicyOrXpi =>
      'XPI/정책만 — 확장 미로드 또는 재시작 필요',
    FirefoxChannelProfileStatus.otherBlockersOnly =>
      '다른 차단 확장만 있음 (Focus Fense 없음)',
    FirefoxChannelProfileStatus.noBlocker => '차단 확장 없음',
  };
}

class FirefoxChannelApplyReport {
  const FirefoxChannelApplyReport({
    required this.handle,
    required this.searchTerms,
    required this.channelUrl,
    required this.overall,
    required this.profiles,
    required this.summaryLines,
    this.inAppRules = false,
    this.websiteFilterPatternCount = 0,
  });

  final String handle;
  final List<String> searchTerms;
  final String channelUrl;
  final bool inAppRules;
  final int websiteFilterPatternCount;
  final FirefoxChannelApplyOverall overall;
  final List<FirefoxChannelProfileProbe> profiles;
  final List<String> summaryLines;

  String get markdown => summaryLines.join('\n');
}

class FirefoxChannelRepairResult {
  const FirefoxChannelRepairResult({required this.ok, required this.message});
  final bool ok;
  final String message;
}
