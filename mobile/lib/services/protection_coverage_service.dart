import 'dart:io';

import '../models/unified_rule_kind.dart';
import '../utils/url_rule_detector.dart';
import 'block_sync_service.dart';
import 'browser_block_enforcement_health_service.dart';
import 'chrome_extension_state_probe.dart';
import 'extension_rules_builder.dart';
import 'local_database.dart';
import 'mac_system_block_service.dart';
import 'usage_ingest_server.dart';
import 'windows_extension_guard_service.dart';
import 'windows_firefox_extension_install_service.dart';
import 'windows_system_block_service.dart';

/// What rule types the user has enabled right now.
final class RuleInventory {
  const RuleInventory({
    required this.keywordCount,
    required this.youtubeChannelCount,
    required this.youtubeVideoCount,
    required this.hostDomainCount,
    required this.wildcardCount,
    required this.searchQueryCount,
    required this.hasYoutubeFullSiteDns,
  });

  final int keywordCount;
  final int youtubeChannelCount;
  final int youtubeVideoCount;
  final int hostDomainCount;
  final int wildcardCount;
  final int searchQueryCount;
  final bool hasYoutubeFullSiteDns;

  int get extensionRuleCount =>
      keywordCount +
      youtubeChannelCount +
      youtubeVideoCount +
      searchQueryCount;

  int get hostsRuleCount =>
      hostDomainCount + wildcardCount + (hasYoutubeFullSiteDns ? 1 : 0);

  bool get needsExtension => extensionRuleCount > 0;

  bool get needsHosts => hostsRuleCount > 0;
}

enum ProtectionGapFix {
  easySetup,
  browserExtensions,
  applyHosts,
  settings,
  diagnostics,
  youtubeRules,
  connectBrowsers,
}

/// One gap between configured rules and what the OS/browser can enforce.
final class ProtectionGap {
  const ProtectionGap({
    required this.id,
    required this.title,
    required this.detail,
    required this.fix,
    this.browsers = const <String>[],
    this.severity = ProtectionGapSeverity.warning,
  });

  final String id;
  final String title;
  final String detail;
  final ProtectionGapFix fix;
  final List<String> browsers;
  final ProtectionGapSeverity severity;
}

enum ProtectionGapSeverity { info, warning, critical }

final class ProtectionCoverageReport {
  const ProtectionCoverageReport({
    required this.inventory,
    required this.gaps,
    required this.analyzedAt,
    this.chromeExtensionOk = false,
    this.edgeExtensionOk = false,
    this.firefoxExtensionOk = false,
    this.hostsActive = false,
    this.rulesApiRunning = false,
  });

  final RuleInventory inventory;
  final List<ProtectionGap> gaps;
  final DateTime analyzedAt;
  final bool chromeExtensionOk;
  final bool edgeExtensionOk;
  final bool firefoxExtensionOk;
  final bool hostsActive;
  final bool rulesApiRunning;

  bool get allClear => gaps.isEmpty;
}

/// Audits DB rules vs hosts / extension / rules API — surfaces what cannot block yet.
final class ProtectionCoverageService {
  ProtectionCoverageService._();
  static final ProtectionCoverageService instance = ProtectionCoverageService._();

  ProtectionCoverageReport? _cache;
  DateTime? _cacheAt;
  static const Duration _cacheTtl = Duration(seconds: 180);

  void invalidateCache() => _cache = null;

  Future<ProtectionCoverageReport> analyze({bool force = false}) async {
    if (!force &&
        _cache != null &&
        _cacheAt != null &&
        DateTime.now().difference(_cacheAt!) < _cacheTtl) {
      return _cache!;
    }
    final ProtectionCoverageReport report = await _analyzeFresh();
    _cache = report;
    _cacheAt = DateTime.now();
    return report;
  }

  Future<ProtectionCoverageReport> _analyzeFresh() async {
    final RuleInventory inventory = await _buildInventory();
    if (!Platform.isWindows && !Platform.isMacOS) {
      return ProtectionCoverageReport(
        inventory: inventory,
        gaps: const <ProtectionGap>[],
        analyzedAt: DateTime.now(),
      );
    }

    final List<ProtectionGap> gaps = <ProtectionGap>[];
    bool hostsActive = false;
    bool chromeOk = false;
    bool edgeOk = false;
    bool firefoxOk = false;
    bool rulesRunning = UsageIngestServer.instance.isRunning;

    if (Platform.isWindows) {
      hostsActive = await WindowsSystemBlockService.instance.isActive();
    } else {
      hostsActive = await MacSystemBlockService.instance.isActive();
    }

    if (Platform.isWindows && inventory.needsExtension) {
      final ExtensionPolicyVerifyResult v =
          await WindowsExtensionGuardService.verifyAllPolicies();
      chromeOk = v.chromeOk;
      edgeOk = v.edgeOk;
      firefoxOk = v.firefoxEnforcementReady;
      final FirefoxInstallVerifyResult ffVerify =
          await WindowsFirefoxExtensionInstallService.verify();
      if (firefoxOk && ffVerify.profileCount == 0) {
        firefoxOk = false;
      }

      if (!rulesRunning) {
        gaps.add(
          ProtectionGap(
            id: 'rules_api_down',
            title: '규칙 서버 꺼짐',
            detail:
                '키워드·유튜브·검색어 차단은 브라우저 확장이 '
                '127.0.0.1:${UsageIngestServer.kPort}/rules 를 읽어야 합니다. '
                '앱을 다시 실행하거나 진단 화면에서 상태를 확인하세요.',
            fix: ProtectionGapFix.diagnostics,
            severity: ProtectionGapSeverity.critical,
          ),
        );
      }

      if (!chromeOk) {
        gaps.addAll(
          _extensionGapsForBrowser(
            browserLabel: 'Chrome',
            browserKey: 'chrome',
            inventory: inventory,
            fix: ProtectionGapFix.easySetup,
          ),
        );
      }
      if (!edgeOk) {
        gaps.addAll(
          _extensionGapsForBrowser(
            browserLabel: 'Edge',
            browserKey: 'edge',
            inventory: inventory,
            fix: ProtectionGapFix.easySetup,
          ),
        );
      }
      if (!firefoxOk) {
        gaps.addAll(
          _extensionGapsForBrowser(
            browserLabel: 'Firefox',
            browserKey: 'firefox',
            inventory: inventory,
            fix: ProtectionGapFix.easySetup,
            severity: ProtectionGapSeverity.critical,
          ),
        );
      }

      if (chromeOk) {
        final bool devCopy =
            await ChromeExtensionStateProbe.hasDeveloperModeCopy();
        if (devCopy) {
          gaps.add(
            const ProtectionGap(
              id: 'chrome_dev_copy',
              title: 'Chrome 개발자 모드 복사본',
              detail:
                  '「압축 해제됨」 확장이 남아 있으면 정책 설치와 충돌할 수 있습니다. '
                  'chrome://extensions 에서 제거한 뒤 설정 → 쉬운 설치를 다시 실행하세요.',
              fix: ProtectionGapFix.browserExtensions,
              browsers: <String>['chrome'],
              severity: ProtectionGapSeverity.warning,
            ),
          );
        }
      }
    } else if (Platform.isMacOS && inventory.needsExtension) {
      gaps.add(
        ProtectionGap(
          id: 'mac_extension_manual',
          title: '키워드·유튜브 정밀 차단',
          detail:
              'Mac에서는 ${inventory.extensionRuleCount}개 규칙이 **브라우저 확장**으로만 적용됩니다. '
              '설정 → 브라우저 확장에서 Chrome·Firefox 안내를 따르세요.',
          fix: ProtectionGapFix.browserExtensions,
          severity: ProtectionGapSeverity.warning,
        ),
      );
    }

    if (inventory.needsHosts) {
      final bool pending = BlockSyncService.instance.hostsApplyPending.value;
      final bool browserCoversDomains = Platform.isWindows &&
          chromeOk &&
          edgeOk &&
          firefoxOk &&
          rulesRunning;
      if (browserCoversDomains && !hostsActive) {
        BlockSyncService.instance.hostsApplyPending.value = false;
      }
      if ((!hostsActive || pending) && !browserCoversDomains) {
        gaps.add(
          ProtectionGap(
            id: 'hosts_not_applied',
            title: pending ? 'hosts 적용 대기' : 'hosts 미적용',
            detail: pending
                ? '${inventory.hostsRuleCount}개 도메인 규칙이 아직 시스템에 반영되지 않았습니다. '
                    '「지금 적용」을 누르면 UAC 창이 뜹니다 — 「예」를 선택하세요.'
                : '도메인·와일드카드·youtube.com 전체 차단은 hosts 파일이 켜져 있어야 합니다. '
                    '「지금 적용」 또는 쉬운 설치를 실행하세요.',
            fix: ProtectionGapFix.applyHosts,
            severity: ProtectionGapSeverity.critical,
          ),
        );
      } else if (!hostsActive && browserCoversDomains) {
        gaps.add(
          const ProtectionGap(
            id: 'hosts_optional',
            title: '시스템 hosts (선택)',
            detail:
                '브라우저 확장으로 도메인·키워드 차단이 이미 연결되어 있습니다. '
                '앱·게임 등 모든 프로그램 DNS까지 막으려면 hosts 적용(UAC)을 추가하세요.',
            fix: ProtectionGapFix.applyHosts,
            severity: ProtectionGapSeverity.info,
          ),
        );
      }
    }

    if (Platform.isWindows && inventory.needsExtension) {
      final BrowserEnforcementHealth enforce =
          await BrowserBlockEnforcementHealthService.instance.analyze();
      if (enforce.phase == BrowserEnforcementPhase.rulesReadyNotEnforcing &&
          (enforce.chromeUnprotectedRunning || !enforce.browserInstallOk)) {
        gaps.insert(
          0,
          ProtectionGap(
            id: 'youtube_rules_not_blocking',
            title: '유튜브 규칙 — 브라우저 미차단',
            detail:
                '${enforce.youtubeRuleCount}개 유튜브·채널 규칙이 켜져 있지만 '
                '최근 차단 기록이 없습니다. Chrome·Edge·**Firefox** 확장이 '
                '없으면 watch·채널(@핸들) 페이지가 그대로 열립니다. '
                '홈 상단 배너에서 Firefox·브라우저 연결을 확인하세요.',
            fix: ProtectionGapFix.connectBrowsers,
            severity: ProtectionGapSeverity.critical,
          ),
        );
      }
    }

    if (inventory.hasYoutubeFullSiteDns && hostsActive) {
      gaps.add(
        const ProtectionGap(
          id: 'youtube_dns_note',
          title: 'youtube.com 전체 = DNS만',
          detail:
              '사이트에 youtube.com 만 넣으면 **모든 브라우저**에서 유튜브 전체가 막힙니다. '
              '특정 채널·영상만 막으려면 채널 URL을 규칙에 넣고 Firefox·Chrome 확장 설치가 필요합니다.',
          fix: ProtectionGapFix.youtubeRules,
          severity: ProtectionGapSeverity.info,
        ),
      );
    }

    return ProtectionCoverageReport(
      inventory: inventory,
      gaps: gaps,
      analyzedAt: DateTime.now(),
      chromeExtensionOk: chromeOk,
      edgeExtensionOk: edgeOk,
      firefoxExtensionOk: firefoxOk,
      hostsActive: hostsActive,
      rulesApiRunning: rulesRunning,
    );
  }

  static List<ProtectionGap> _extensionGapsForBrowser({
    required String browserLabel,
    required String browserKey,
    required RuleInventory inventory,
    required ProtectionGapFix fix,
    ProtectionGapSeverity severity = ProtectionGapSeverity.warning,
  }) {
    if (!inventory.needsExtension) return const <ProtectionGap>[];

    final List<String> ruleBits = <String>[];
    if (inventory.keywordCount > 0) {
      ruleBits.add('키워드 ${inventory.keywordCount}');
    }
    if (inventory.searchQueryCount > 0) {
      ruleBits.add('검색어 ${inventory.searchQueryCount}');
    }
    final int yt = inventory.youtubeChannelCount + inventory.youtubeVideoCount;
    if (yt > 0) ruleBits.add('유튜브 채널·영상 $yt');

    final String rulesSummary =
        ruleBits.isEmpty ? '확장 규칙' : ruleBits.join(' · ');

    final StringBuffer detail = StringBuffer()
      ..writeln(
        '$browserLabel 에서는 아래 규칙이 **브라우저 확장**으로만 적용됩니다 (hosts/DNS 아님).',
      )
      ..writeln('• $rulesSummary');
    if (browserKey == 'firefox') {
      detail.writeln(
        'Firefox: policies.json + XPI + 프로필 복사가 없으면 '
        '유튜브·키워드 차단이 **전혀** 작동하지 않습니다.',
      );
    } else {
      detail.writeln(
        '설정 → 「브라우저 보호 · 쉬운 설치」 후 $browserLabel 완전 종료·재실행.',
      );
    }

    return <ProtectionGap>[
      ProtectionGap(
        id: '${browserKey}_extension_bundle',
        title: '$browserLabel · $rulesSummary 미적용',
        detail: detail.toString().trim(),
        fix: fix,
        browsers: <String>[browserKey],
        severity: severity,
      ),
    ];
  }

  static Future<RuleInventory> _buildInventory() async {
    final DateTime now = DateTime.now();
    final List<Map<String, Object?>> kws =
        await LocalDatabase.instance.keywordsActiveNow(now);
    final List<Map<String, Object?>> doms =
        await LocalDatabase.instance.domainsActiveNow(now);
    final List<Map<String, Object?>> sq =
        await LocalDatabase.instance.searchQueryBlocksActiveNow(now);

    int keywords = 0;
    int channels = 0;
    int videos = 0;
    int hosts = 0;
    int wildcards = 0;
    bool ytFull = false;

    for (final Map<String, Object?> row in kws) {
      if ((row['enabled'] as int? ?? 0) != 1) continue;
      final String pattern = (row['pattern'] as String? ?? '').trim();
      if (pattern.isEmpty) continue;
      switch (UrlRuleDetector.detect(pattern).kind) {
        case UnifiedRuleKind.keyword:
          keywords++;
        case UnifiedRuleKind.searchQuery:
          keywords++;
        case UnifiedRuleKind.channelURL:
          channels++;
        case UnifiedRuleKind.videoURL:
          videos++;
        case UnifiedRuleKind.host:
          hosts++;
        case UnifiedRuleKind.wildcard:
          wildcards++;
      }
    }

    for (final Map<String, Object?> row in doms) {
      if ((row['enabled'] as int? ?? 0) != 1) continue;
      final String? raw = row['host'] as String?;
      if (raw == null) continue;
      final String host = MacSystemBlockService.canonicalHost(raw);
      if (host == 'youtube.com') {
        ytFull = true;
      } else if (raw.trim().startsWith('*.')) {
        wildcards++;
      } else {
        hosts++;
      }
    }

    final int searchCount = sq
        .where((Map<String, Object?> r) => (r['enabled'] as int? ?? 0) == 1)
        .length;

    // Count only active, explicitly enabled rules; the adult preset is opt-in.
    final ExtensionRulesPayload payload = await ExtensionRulesBuilder.buildActiveNow();

    return RuleInventory(
      keywordCount: keywords,
      youtubeChannelCount: channels,
      youtubeVideoCount: videos,
      hostDomainCount: hosts,
      wildcardCount: wildcards,
      searchQueryCount: searchCount > 0 ? searchCount : payload.searchQueries.length,
      hasYoutubeFullSiteDns: ytFull,
    );
  }
}
