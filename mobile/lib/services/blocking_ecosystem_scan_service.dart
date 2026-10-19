import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../data/builtin_adult_apex_domains.dart';
import '../data/browser_ecosystem_catalog.dart';
import '../models/ecosystem_scan_models.dart';
import 'agent_tamper_watchdog_service.dart';
import 'app_logger.dart';
import 'browser_block_health_monitor_service.dart';
import 'browser_live_url_block_gate_service.dart';
import 'browser_protection_truth_service.dart';
import 'build_identity_service.dart';
import 'builtin_block_domains.dart';
import 'chrome_gmail_gemini_allowlist_service.dart';
import 'crash_journal_service.dart';
import 'extension_guard_prefs.dart';
import 'extension_rules_builder.dart';
import 'local_database.dart';
import 'brave_extension_install_service.dart';
import 'chromium_derivative_extension_service.dart';
import 'unprotected_browser_kill_guard_prefs.dart';
import 'windows_default_browser_service.dart';
import 'windows_extension_guard_service.dart';

/// Scans blocking + extension-delete protection and builds a **friendly**
/// per-browser report (Chrome / Edge / Firefox / Safari / …).
final class BlockingEcosystemScanService {
  BlockingEcosystemScanService._();
  static final BlockingEcosystemScanService instance =
      BlockingEcosystemScanService._();

  static const String _kLastBuildKey = 'ecosystem_scan_last_build_v1';

  BlockingEcosystemReport? _cache;
  DateTime? _cacheAt;
  static const Duration _cacheTtl = Duration(minutes: 30);
  static const Duration _diskCacheMaxAge = Duration(hours: 48);
  static const Duration _healthReuseTtl = Duration(minutes: 8);

  /// Bumped after every successful scan — UI strips/cards listen and refresh.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);
  Future<void>? _refreshInFlight;

  String get reportPath => p.join(
        CrashJournalService.instance.debugFolderPath,
        'ecosystem_scan_last.json',
      );

  void invalidateCache() {
    _cache = null;
    _cacheAt = null;
    try {
      final File f = File(reportPath);
      if (f.existsSync()) {
        f.deleteSync();
      }
    } catch (_) {}
  }

  /// Health/truth/live-gate changed — debounced ecosystem rescan for 현황판.
  void notifyProtectionTruthUpdated() {
    requestRefresh(reason: 'protection_truth', force: false);
  }

  /// Coalesced refresh (build bump, truth merge, live gate, manual).
  void requestRefresh({required String reason, bool force = true}) {
    if (_refreshInFlight != null && !force) return;
    final Future<void> run =
        _runRefresh(reason: reason, force: force);
    _refreshInFlight = run;
    unawaited(
      run.whenComplete(() {
        if (identical(_refreshInFlight, run)) {
          _refreshInFlight = null;
        }
      }),
    );
  }

  Future<void> _runRefresh({
    required String reason,
    required bool force,
  }) async {
    try {
      await scan(force: force, postUpdate: false);
    } catch (e, st) {
      AppLogger.instance.warn('ecosystem_scan refresh ($reason): $e\n$st');
    }
  }

  Future<bool> needsPostUpdateScan() async {
    final BuildIdentity build = await BuildIdentityService.instance.current();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? last = prefs.getString(_kLastBuildKey);
    return last == null || last.trim() != build.buildNumber.trim();
  }

  Future<void> markBuildScanned() async {
    final BuildIdentity build = await BuildIdentityService.instance.current();
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kLastBuildKey, build.buildNumber.trim());
  }

  /// Last saved report from disk — instant UI without re-probing browsers.
  Future<BlockingEcosystemReport?> readDiskCache({
    Duration maxAge = _diskCacheMaxAge,
  }) async {
    try {
      final File f = File(reportPath);
      if (!await f.exists()) return null;
      final Object? decoded = jsonDecode(await f.readAsString());
      if (decoded is! Map) return null;
      final BlockingEcosystemReport? report =
          BlockingEcosystemReport.tryFromJson(
        Map<String, Object?>.from(decoded),
      );
      if (report == null) return null;
      if (DateTime.now().difference(report.scannedAt) > maxAge) return null;
      return report;
    } catch (_) {
      return null;
    }
  }

  Future<BlockingEcosystemReport> scan({
    bool force = false,
    bool postUpdate = false,
  }) async {
    if (!force && !BrowserBlockHealthMonitorService.instance.firstProbeCompleted) {
      final BlockingEcosystemReport? existing = _cache ?? await readDiskCache();
      final bool looksNeedsApply = existing == null ||
          existing.targets.any(
            (EcosystemTargetRow t) =>
                t.installed && t.level != EcosystemScanLevel.ready,
          );
      if (looksNeedsApply) {
        // A cached/disk report saying "needs apply" is indistinguishable from
        // a stale one persisted before the boot health probe ever ran once —
        // main.dart's staggered magic delays don't guarantee this scan runs
        // after that probe. Wait for the one real readiness signal instead of
        // trusting the cache blind; bounded so a stuck probe can't hang the UI.
        await BrowserBlockHealthMonitorService.instance.firstProbeDone
            .timeout(const Duration(seconds: 20), onTimeout: () {});
        force = true;
      }
    }

    if (!force &&
        _cache != null &&
        _cacheAt != null &&
        DateTime.now().difference(_cacheAt!) < _cacheTtl) {
      return _cache!;
    }

    if (!force) {
      final BlockingEcosystemReport? disk = await readDiskCache();
      if (disk != null) {
        _cache = disk;
        _cacheAt = disk.scannedAt;
        if (DateTime.now().difference(disk.scannedAt) < _cacheTtl) {
          return disk;
        }
      }
    }

    try {
      return await _scanOnce(force: force, postUpdate: postUpdate);
    } catch (e, st) {
      AppLogger.instance.warn('ecosystem_scan failed: $e\n$st');
      final BlockingEcosystemReport? stale =
          _cache ?? await readDiskCache(maxAge: const Duration(days: 7));
      if (stale != null) {
        return stale;
      }
      return _fallbackReportAfterScanError(e);
    }
  }

  Future<BlockingEcosystemReport> _scanOnce({
    required bool force,
    required bool postUpdate,
  }) async {
    final BuildIdentity build = await BuildIdentityService.instance.current();
    final String buildLabel = 'v${build.version}+${build.buildNumber}';
    // Heavy "post update" scan only when caller explicitly requests it
    // (post-rebuild bootstrap) — not on every app launch / build +N bump.
    final bool isPostUpdate = postUpdate;
    final bool buildChanged = await needsPostUpdateScan();
    if (buildChanged || isPostUpdate) {
      invalidateCache();
    }

    final List<EcosystemTargetRow> targets = <EcosystemTargetRow>[];
    final List<EcosystemFeatureRow> features = <EcosystemFeatureRow>[];
    bool killGuardActive = false;

    final bool adultSitesBlocked =
        (await LocalDatabase.instance.rulesMeta()).adultSitesBlocked;
    final int adultCount = adultSitesBlocked ? kBuiltinAdultApexCount : 0;

    int ruleCount = 0;
    try {
      final ExtensionRulesPayload rules =
          await ExtensionRulesBuilder.buildForBrowserEnforcement();
      ruleCount = rules.blockedDomains.length +
          rules.keywords.length +
          rules.blockedYoutubeHandles.length +
          rules.blockedYoutubeVideoIds.length;
    } catch (_) {}

    if (Platform.isWindows) {
      BrowserBlockHealthReport health =
          BrowserBlockHealthMonitorService.instance.latest ??
              BrowserBlockHealthReport.empty(reason: 'ecosystem_scan');
      final bool healthFresh =
          DateTime.now().difference(health.checkedAt) < _healthReuseTtl &&
              health.browsers.isNotEmpty;
      if (!healthFresh || force || buildChanged || isPostUpdate) {
        health = await BrowserBlockHealthMonitorService.instance.probe(
          reason: force
              ? 'ecosystem_scan_force'
              : buildChanged
                  ? 'ecosystem_scan_build'
                  : 'ecosystem_scan',
        );
      }
      if (buildChanged || isPostUpdate || force) {
        await BrowserLiveUrlBlockGateService.instance.runLiveTest(
          applyPolicyFirst: false,
          reason: buildChanged ? 'post_update' : 'ecosystem_scan',
          // @incident: firefox_work_window_closed — a scan/update must honor
          // automatic-live-test opt-in, never force a browser experiment.
          force: false,
        );
      }
      if (health.browsers.isEmpty) {
        final BrowserBlockHealthReport? cached =
            BrowserBlockHealthMonitorService.instance.latest;
        if (cached != null && cached.browsers.isNotEmpty) {
          health = cached;
        }
      }
      final ExtensionPolicyVerifyResult ext =
          await WindowsExtensionGuardService.verifyAllPolicies();
      final bool gmailOnly =
          await ChromeGmailGeminiAllowlistService.instance.enabled();
      final bool killGuard =
          await UnprotectedBrowserKillGuardPrefs.instance.enabled();
      killGuardActive = killGuard;
      final bool extWatchdog =
          await ExtensionGuardPrefs.instance.isWatchdogEnabled();
      final AgentTamperReport? tamper =
          await AgentTamperWatchdogService.instance.loadLastReport();

      final BraveExtensionVerifyResult braveExt =
          await BraveExtensionInstallService.instance.verify();
      final Map<String, DerivativeExtensionVerifyResult> derivativeExt =
          await ChromiumDerivativeExtensionService.instance.verifyInstalled();

      final List<BrowserProtectionTruth> truths =
          await BrowserProtectionTruthService.instance.mergeFromHealth(health);
      final Map<String, BrowserProtectionTruth> truthById =
          <String, BrowserProtectionTruth>{
        for (final BrowserProtectionTruth t in truths) t.health.id: t,
      };

      for (final BrowserHealth b in health.browsers) {
        targets.add(_mapBrowserHealth(
          b,
          ext,
          truth: truthById[b.id],
          gmailOnly: gmailOnly,
          killGuard: killGuard,
          braveExt: b.id == 'brave' ? braveExt : null,
          derivativeExt: derivativeExt[b.id],
        ));
      }

      targets.add(_safariRowForWindows());
      targets.add(_iosSafariRow());

      features.addAll(<EcosystemFeatureRow>[
        EcosystemFeatureRow(
          id: 'adult_builtin',
          title: '성인 사이트 기본 목록 차단',
          level: adultSitesBlocked && health.hasAnyRule
              ? EcosystemScanLevel.ready
              : EcosystemScanLevel.partial,
          summary: adultSitesBlocked
              ? '내장 도메인 $adultCount개 — URLBlocklist + PAC + 확장'
              : '꺼짐 — 설정에서 직접 켜면 적용됩니다.',
          detail: adultSitesBlocked
              ? '활성 규칙 $ruleCount건과 함께 브라우저 정책에 반영됩니다.'
              : '성인 기본 목록은 설치하거나 앱을 시작해도 자동 적용되지 않습니다. 스케줄에 직접 추가한 도메인은 별도로 유지됩니다.',
        ),
        EcosystemFeatureRow(
          id: 'extension_delete_guard',
          title: '확장 삭제·비활성화 방지',
          level: ext.protectionOk && extWatchdog
              ? EcosystemScanLevel.ready
              : EcosystemScanLevel.partial,
          summary: ext.protectionOk
              ? 'Chrome/Edge/Firefox 강제 설치 + 90초 keepalive'
              : '일부 브라우저 확장 정책 미완 — 「원탭 차단 적용」 권장',
          detail: ext.detail,
        ),
        EcosystemFeatureRow(
          id: 'unprotected_kill',
          title: 'URL 차단 없는 브라우저 자동 종료',
          level: killGuard
              ? EcosystemScanLevel.ready
              : EcosystemScanLevel.partial,
          summary: killGuard
              ? 'Whale·Brave·Opera 등 정책 없으면 프로세스 종료'
              : '설정 → 진단에서 끄신 상태',
          detail: '음란물 사이트가 정책 없는 브라우저로 뚫리는 것을 막습니다.',
        ),
        EcosystemFeatureRow(
          id: 'ai_tamper_guard',
          title: 'AI 파괴 명령 방어 (Cursor 등)',
          level: tamper != null && tamper.allPass
              ? EcosystemScanLevel.ready
              : EcosystemScanLevel.partial,
          summary: tamper != null
              ? '${tamper.passCount}/${tamper.totalCount} 시나리오 방어'
              : '아직 점검 안 함 — 진단 카드에서 실행',
          detail: '앱 삭제·차단코드 제거·가드 중지 등 5종 차단',
        ),
      ]);
    } else if (Platform.isMacOS) {
      targets.addAll(<EcosystemTargetRow>[
        const EcosystemTargetRow(
          id: 'safari',
          displayName: 'Safari (Mac)',
          level: EcosystemScanLevel.ready,
          headline: 'hosts + Safari 웹 확장',
          detailLines: <String>[
            '시스템 DNS(/etc/hosts) + Safari 확장으로 차단',
            'YouTube — 채널·영상 규칙 (확장)',
          ],
        ),
        const EcosystemTargetRow(
          id: 'chrome_mac',
          displayName: 'Chrome (Mac)',
          level: EcosystemScanLevel.partial,
          headline: '확장 + hosts 보조',
          detailLines: <String>[
            'Windows만큼 URLBlocklist 정책은 없음',
            'hosts + 확장 규칙으로 차단',
          ],
        ),
        const EcosystemTargetRow(
          id: 'firefox_mac',
          displayName: 'Firefox (Mac)',
          level: EcosystemScanLevel.partial,
          headline: '확장 + hosts 보조',
          detailLines: <String>[
            'DoH 끄기(user.js) + 확장',
            'YouTube 채널·영상 차단',
          ],
        ),
      ]);
      features.add(
        const EcosystemFeatureRow(
          id: 'adult_builtin',
          title: '내장 음란물 사이트',
          level: EcosystemScanLevel.ready,
          summary: 'hosts DNS 차단 + 확장',
        ),
      );
    } else if (Platform.isIOS) {
      targets.add(
        const EcosystemTargetRow(
          id: 'safari_ios',
          displayName: 'Safari (iPhone)',
          level: EcosystemScanLevel.ready,
          headline: 'Safari 웹 확장 + 앱 규칙',
          detailLines: <String>[
            '설정 → Safari → 확장에서 Focus Fense 켜기',
            'YouTube 채널·영상·이미지 숨김',
          ],
        ),
      );
    } else {
      targets.add(
        const EcosystemTargetRow(
          id: 'platform',
          displayName: '이 기기',
          level: EcosystemScanLevel.unavailable,
          headline: 'Windows / Mac / iPhone 전용',
          detailLines: <String>['현재 OS에서는 데스크톱 차단 스택이 없습니다.'],
        ),
      );
    }

    final String platformLabel = Platform.isWindows
        ? 'Windows'
        : Platform.isMacOS
            ? 'macOS'
            : Platform.isIOS
                ? 'iPhone / iOS'
                : build.operatingSystem;

    final List<EcosystemTargetRow> enriched = _attachCatalog(targets);

    final DefaultBrowserAdvisory? defaultBrowser = Platform.isWindows
        ? await WindowsDefaultBrowserService.instance.detect(
            targets: enriched,
          )
        : null;

    final String summaryKo = _buildSummaryKo(
      targets: enriched,
      buildLabel: buildLabel,
      platformLabel: platformLabel,
      defaultBrowser: defaultBrowser,
    );

    final BlockingEcosystemReport report = BlockingEcosystemReport(
      buildLabel: buildLabel,
      scannedAt: DateTime.now(),
      isPostUpdateScan: isPostUpdate,
      platformLabel: platformLabel,
      summaryKo: summaryKo,
      targets: enriched,
      features: features,
      defaultBrowser: defaultBrowser,
      builtinAdultCount: adultCount,
      activeRuleCount: ruleCount,
      killGuardActive: killGuardActive,
    );

    final bool windowsBrowserRowsMissing = Platform.isWindows &&
        enriched.where((EcosystemTargetRow t) =>
            t.id != 'safari' && t.id != 'safari_ios').isEmpty;
    if (!windowsBrowserRowsMissing) {
      _cache = report;
      _cacheAt = DateTime.now();
      await markBuildScanned();
    } else {
      AppLogger.instance.warn(
        'ecosystem_scan: no Windows browser rows — skip cache',
      );
    }
    await _writeJson(report);
    revision.value++;
    return report;
  }

  Future<BlockingEcosystemReport> _fallbackReportAfterScanError(
    Object error,
  ) async {
    final BuildIdentity build = await BuildIdentityService.instance.current();
    final String buildLabel = 'v${build.version}+${build.buildNumber}';
    final String platformLabel = Platform.isWindows
        ? 'Windows'
        : Platform.isMacOS
            ? 'macOS'
            : Platform.isIOS
                ? 'iPhone / iOS'
                : build.operatingSystem;
    final List<EcosystemTargetRow> targets = <EcosystemTargetRow>[];
    if (Platform.isWindows) {
      final BrowserBlockHealthReport? health =
          BrowserBlockHealthMonitorService.instance.latest;
      if (health != null) {
        for (final BrowserHealth b in health.browsers) {
          targets.add(
            EcosystemTargetRow(
              id: b.id,
              displayName: b.displayName,
              level: b.blockActive
                  ? EcosystemScanLevel.partial
                  : EcosystemScanLevel.off,
              headline: b.blockActive ? 'URL 정책 감지됨' : 'URL 차단 미적용',
              detailLines: <String>[
                '전체 스캔 오류 — 마지막 헬스 스냅샷만 표시',
                '$error',
              ],
              installed: b.installed,
              running: b.running,
              urlBlockUsable: b.effectivelyBlockActive,
            ),
          );
        }
      }
    }
    return BlockingEcosystemReport(
      buildLabel: buildLabel,
      scannedAt: DateTime.now(),
      isPostUpdateScan: false,
      platformLabel: platformLabel,
      summaryKo:
          '$buildLabel · $platformLabel — 현황 스캔 오류. 「다시 스캔」을 눌러 주세요.',
      targets: targets,
      features: const <EcosystemFeatureRow>[],
      builtinAdultCount: 0,
      activeRuleCount: 0,
    );
  }

  @visibleForTesting
  EcosystemTargetRow mapBrowserHealthForTest(
    BrowserHealth b,
    ExtensionPolicyVerifyResult ext, {
    BrowserProtectionTruth? truth,
    required bool gmailOnly,
    required bool killGuard,
    BraveExtensionVerifyResult? braveExt,
    DerivativeExtensionVerifyResult? derivativeExt,
  }) =>
      _mapBrowserHealth(
        b,
        ext,
        truth: truth,
        gmailOnly: gmailOnly,
        killGuard: killGuard,
        braveExt: braveExt,
        derivativeExt: derivativeExt,
      );

  EcosystemTargetRow _mapBrowserHealth(
    BrowserHealth b,
    ExtensionPolicyVerifyResult ext, {
    BrowserProtectionTruth? truth,
    required bool gmailOnly,
    required bool killGuard,
    BraveExtensionVerifyResult? braveExt,
    DerivativeExtensionVerifyResult? derivativeExt,
  }) {
    if (!b.installed) {
      final BrowserCatalogEntry? cat = BrowserCatalogEntry.forId(b.id);
      final bool ready = cat?.pluginSupportReady ?? false;
      return EcosystemTargetRow(
        id: b.id,
        displayName: b.displayName,
        level: ready
            ? EcosystemScanLevel.partial
            : EcosystemScanLevel.unavailable,
        headline: ready
            ? '설치하면 앱이 자동으로 맞춰 줍니다'
            : '이 PC에 없음',
        detailLines: cat?.ifYouInstallKo != null
            ? <String>[cat!.ifYouInstallKo]
            : const <String>['Windows 앱 범위 밖 (Mac·iPhone 별도)'],
        installed: false,
        pluginSupportReady: ready,
        pluginSupportLabel: ready
            ? cat!.pluginReadyBadgeKo
            : '아직 플러그인 준비 안 됨',
        ifYouInstallKo: cat?.ifYouInstallKo,
        killOnNoBlock: killGuard && _isKillGuardTarget(b.id),
      );
    }

    final List<String> lines = <String>[];
    // Mutable — truth overlay may downgrade level/headline after the switch.
    late EcosystemScanLevel level;
    late String headline;

    switch (b.id) {
      case 'chrome':
        if (b.running && !b.effectivelyBlockActive) {
          headline = killGuard
              ? 'URL 차단 미로드 → Chrome 자체 종료'
              : 'URL 차단 미로드 — Chrome 완전 종료 후 재실행';
          lines.add('정책은 디스크에 있으나 지금 Chrome이 읽지 않음');
          if (b.processOlderThanPolicy) {
            lines.add('Chrome을 완전히 닫았다가 다시 열어주세요');
          }
        } else if (b.blockActive &&
            b.policyEntryCount < 20 &&
            gmailOnly) {
          headline = 'Chrome URL 목록 부족 — 원탭 적용 필요';
          lines.add('Gmail 허용은 켜져 있으나 URLBlocklist가 비어 있거나 <*>만 있음');
          lines.add('진단 → 「원탭 차단 적용」 후 Chrome 완전 종료·재실행');
        } else if (gmailOnly && b.blockActive) {
          headline = 'URL 차단 + Gmail·Gemini만 허용';
          lines.add(
            'URLBlocklist ${b.policyEntryCount}개 · mail.google.com · gemini.google.com OK',
          );
        } else if (b.blockActive) {
          headline = 'URL 차단 적용됨';
          if (ext.chromeEnforcementReady) {
            lines.add(
              'URLBlocklist ${b.policyEntryCount}개 · YouTube는 스케줄 목록만 (확장)',
            );
          } else {
            lines.add('URLBlocklist ${b.policyEntryCount}개 · YouTube 전체 + 성인 사이트');
          }
        } else {
          headline = killGuard
              ? 'URL 차단 없음 → Chrome 자체 종료'
              : 'URL 차단 미적용';
          lines.add(killGuard
              ? 'chrome.exe가 열리면 즉시 종료됩니다 (kill guard)'
              : '진단 → 원탭 차단 적용 필요');
        }
        if (ext.chromeEnforcementReady) {
          lines.add('확장: Focus Fense 강제 설치 · 삭제 방지 ON');
        } else {
          lines.add('확장: 미적용 — load-extension 또는 정책 설치 필요');
        }
        final bool chromeFullList =
            b.policyEntryCount >= 20 && b.policySampleMatch;
        level = b.effectivelyBlockActive &&
                ext.chromeEnforcementReady &&
                chromeFullList
            ? EcosystemScanLevel.ready
            : b.effectivelyBlockActive || ext.chromeEnforcementReady
                ? EcosystemScanLevel.partial
                : EcosystemScanLevel.off;
      case 'edge':
        if (b.blockActive) {
          headline = 'URL 차단 적용됨';
          if (ext.edgeEnforcementReady) {
            lines.add('YouTube — 스케줄 목록만 차단 (확장 · 홈은 열림)');
          } else {
            lines.add('YouTube 전체 차단 + 음란물 URLBlocklist');
          }
        } else {
          headline = killGuard
              ? 'URL 차단 없음 → Edge 자체 종료'
              : 'URL 차단 미적용';
          if (killGuard) {
            lines.add('msedge.exe가 열리면 즉시 종료됩니다');
          }
        }
        if (ext.edgeEnforcementReady) {
          lines.add('확장: Edge 강제 설치 · 삭제 방지 ON');
        } else {
          lines.add('확장: 미적용');
        }
        level = b.blockActive && ext.edgeEnforcementReady
            ? EcosystemScanLevel.ready
            : b.blockActive
                ? EcosystemScanLevel.partial
                : EcosystemScanLevel.off;
      case 'firefox':
        if (b.blockActive) {
          headline = 'URL 차단 (채널·영상)';
          lines.add('YouTube 홈·다른 채널은 열림 — 등록한 채널/영상만 차단');
          lines.add('유튜브 전체 차단 ✗ (Firefox 전용 정책)');
        } else {
          headline = killGuard
              ? 'URL 차단 없음 → Firefox 자체 종료'
              : 'URL 차단 미적용';
          lines.add(killGuard
              ? 'firefox.exe가 열리면 즉시 종료됩니다'
              : '자동 종료 대상 — 정책 적용 후 Firefox 재시작');
        }
        if (ext.firefoxEnforcementReady) {
          lines.add('확장: sixvpn-blocker XPI · WebsiteFilter');
        } else {
          lines.add('확장: XPI 미설치 — 원탭 적용 권장');
        }
        level = b.blockActive && ext.firefoxEnforcementReady
            ? EcosystemScanLevel.ready
            : b.blockActive
                ? EcosystemScanLevel.partial
                : EcosystemScanLevel.off;
      case 'brave':
        if (b.blockActive && (braveExt?.extensionReady ?? false)) {
          headline = 'URL 차단 + Brave 확장 적용됨';
          lines.add('YouTube — 스케줄 목록만 (확장) · 음란물 URLBlocklist');
        } else if (b.blockActive) {
          headline = 'URL 정책만 — Brave 확장 미적용';
          lines.add('원탭 차단 적용 후 Brave 완전 종료·재실행');
          lines.add('Launch-6VPN-Brave.vbs 로 열면 확장 로드');
        } else {
          headline = killGuard
              ? 'URL 차단 없음 → brave.exe 자체 종료'
              : 'URL 차단 미적용';
          lines.add(killGuard
              ? 'brave.exe가 열리면 즉시 종료됩니다'
              : '원탭 차단 적용 필요');
        }
        if (braveExt != null && !braveExt.extensionReady) {
          lines.add('Brave 전용 확장 — 「원탭 차단 적용」으로 설치');
        }
        level = b.blockActive && (braveExt?.extensionReady ?? false)
            ? EcosystemScanLevel.ready
            : b.blockActive
                ? EcosystemScanLevel.partial
                : EcosystemScanLevel.off;
      case 'whale':
      case 'vivaldi':
      case 'opera':
        _mapDerivativeBrowserRow(
          b: b,
          derivativeExt: derivativeExt,
          killGuard: killGuard,
          lines: lines,
          setHeadline: (String h) => headline = h,
          setLevel: (EcosystemScanLevel l) => level = l,
        );
      default:
        if (derivativeExt != null) {
          _mapDerivativeBrowserRow(
            b: b,
            derivativeExt: derivativeExt,
            killGuard: killGuard,
            lines: lines,
            setHeadline: (String h) => headline = h,
            setLevel: (EcosystemScanLevel l) => level = l,
          );
        } else if (b.blockActive) {
          headline = 'URL 차단 적용됨';
          lines.add('YouTube 전체 차단 (Chromium 파생 · 확장 없음)');
          lines.add('확장 없음 — URL 정책만');
          level = EcosystemScanLevel.ready;
        } else {
          headline = killGuard
              ? 'URL 차단 없음 → ${_processLabel(b.id)} 자체 종료'
              : 'URL 차단 미적용';
          lines.add(killGuard
              ? '${_processLabel(b.id)}.exe가 열리면 즉시 종료됩니다'
              : '원탭 차단 적용 후 사용하세요');
          level = EcosystemScanLevel.off;
        }
    }

    if (b.running && !b.effectivelyBlockActive) {
      lines.add('⚠ 지금 실행 중 — 차단이 안 먹는 상태');
    }
    if (b.processOlderThanPolicy && b.running && b.blockActive) {
      lines.add('브라우저를 완전히 닫았다가 다시 열어주세요 (정책 갱신)');
    }

    final bool urlUsable = truth?.urlBlockUsable ??
        (b.installed && b.blockActive && b.effectivelyBlockActive);
    if (b.installed && truth != null) {
      if (truth.urlBlockUsable) {
        level = truth.extensionReady
            ? EcosystemScanLevel.ready
            : (truth.liveUrlBlocked == true
                ? EcosystemScanLevel.ready
                : EcosystemScanLevel.partial);
        headline = truth.statusHeadlineKo;
        lines
          ..clear()
          ..addAll(
            _usableBrowserDetailLines(
              b: b,
              truth: truth,
              ext: ext,
              braveExt: braveExt,
              derivativeExt: derivativeExt,
            ),
          );
      } else {
        level = EcosystemScanLevel.off;
        headline = truth.statusHeadlineKo;
        lines
          ..clear()
          ..addAll(_blockedBrowserDetailLines(b: b, truth: truth, killGuard: killGuard));
      }
    } else if (urlUsable) {
      lines.removeWhere(_isKillGuardDetailLine);
    }

    final bool killOnNoBlock = killGuard &&
        _isKillGuardTarget(b.id) &&
        !urlUsable &&
        (truth?.shouldForceKillWhenRunning ??
            (!b.effectivelyBlockActive && b.installed));

    return EcosystemTargetRow(
      id: b.id,
      displayName: b.displayName,
      level: level,
      headline: headline,
      detailLines: lines,
      installed: b.installed,
      running: b.running,
      killOnNoBlock: killOnNoBlock,
      urlBlockUsable: urlUsable,
    );
  }

  void _mapDerivativeBrowserRow({
    required BrowserHealth b,
    required DerivativeExtensionVerifyResult? derivativeExt,
    required bool killGuard,
    required List<String> lines,
    required void Function(String) setHeadline,
    required void Function(EcosystemScanLevel) setLevel,
  }) {
    final bool extReady = derivativeExt?.extensionReady ?? false;
    final String proc = _processLabel(b.id);
    if (b.blockActive && extReady) {
      setHeadline('URL 차단 + ${b.displayName} 확장 적용됨');
      lines.add('YouTube — 스케줄 목록만 (확장) · 음란물 URLBlocklist');
      lines.add('확장 삭제 방지 ON');
    } else if (b.blockActive) {
      setHeadline('URL 정책만 — ${b.displayName} 확장 미적용');
      lines.add('YouTube 전체 차단 (확장 없음 — URLBlocklist)');
      lines.add('원탭 차단 적용 후 ${b.displayName} 완전 종료·재실행');
    } else {
      setHeadline(
        killGuard
            ? 'URL 차단 없음 → $proc.exe 자체 종료'
            : 'URL 차단 미적용',
      );
      lines.add(
        killGuard
            ? '$proc.exe가 열리면 즉시 종료됩니다'
            : '원탭 차단 적용 필요',
      );
    }
    if (derivativeExt != null && !derivativeExt.extensionReady) {
      lines.add('${b.displayName} 확장 — 「원탭 차단 적용」으로 자동 설치');
    } else if (derivativeExt?.policyReady ?? false) {
      lines.add('확장: 강제 설치 · 삭제 방지 ON');
    }
    setLevel(
      b.blockActive && extReady
          ? EcosystemScanLevel.ready
          : b.blockActive
              ? EcosystemScanLevel.partial
              : EcosystemScanLevel.off,
    );
  }

  static bool _isKillGuardDetailLine(String line) {
    final String t = line.trim();
    return t.contains('즉시 종료') ||
        t.contains('자체 종료') ||
        t.contains('kill guard') ||
        t.contains('통째로');
  }

  static List<String> _usableBrowserDetailLines({
    required BrowserHealth b,
    required BrowserProtectionTruth truth,
    required ExtensionPolicyVerifyResult ext,
    required BraveExtensionVerifyResult? braveExt,
    required DerivativeExtensionVerifyResult? derivativeExt,
  }) {
    final List<String> out = <String>[];
    if (truth.extensionReady) {
      out.add('확장으로 스케줄·음란물 차단 · 브라우저 사용 가능');
      out.add('YouTube는 등록한 채널·영상만 허용 (목록 모드)');
    } else if (b.blockActive) {
      out.add('URLBlocklist 적용됨 · YouTube 전체 차단 포함');
      if (b.policyEntryCount >= 20) {
        out.add('정책 ${b.policyEntryCount}개 디스크 반영');
      }
    }
    if (truth.liveUrlBlocked == true) {
      out.add('실측 차단 테스트 통과');
    } else if (truth.liveDetail != null && truth.liveDetail!.isNotEmpty) {
      out.add('실측: ${truth.liveDetail}');
    }
    if (b.running) {
      out.add('지금 실행 중 — 보호 정상');
    }
    if (out.isEmpty) {
      out.add('차단 정책이 적용되어 있습니다');
    }
    _appendExtensionHintLines(
      b: b,
      ext: ext,
      braveExt: braveExt,
      derivativeExt: derivativeExt,
      lines: out,
      extensionReady: truth.extensionReady,
    );
    return out;
  }

  static List<String> _blockedBrowserDetailLines({
    required BrowserHealth b,
    required BrowserProtectionTruth truth,
    required bool killGuard,
  }) {
    final List<String> out = <String>[];
    if (truth.liveDetail != null && truth.liveDetail!.isNotEmpty) {
      out.add('실측: ${truth.liveDetail}');
    }
    final String proc = _processLabel(b.id);
    if (truth.shouldForceKillWhenRunning || truth.hardKill) {
      if (killGuard) {
        out.add('$proc.exe가 열리면 앱이 즉시 종료합니다');
      } else {
        out.add('원탭 차단 적용 후 다시 확인하세요');
      }
    } else if (out.isEmpty) {
      out.add('URL 차단이 아직 적용되지 않았습니다');
    }
    return out;
  }

  static void _appendExtensionHintLines({
    required BrowserHealth b,
    required ExtensionPolicyVerifyResult ext,
    required BraveExtensionVerifyResult? braveExt,
    required DerivativeExtensionVerifyResult? derivativeExt,
    required List<String> lines,
    required bool extensionReady,
  }) {
    if (extensionReady) return;
    switch (b.id) {
      case 'chrome':
        if (!ext.chromeEnforcementReady) {
          lines.add('원탭 차단 적용 시 Chrome 확장 자동 설치');
        }
      case 'edge':
        if (!ext.edgeEnforcementReady) {
          lines.add('원탭 차단 적용 시 Edge 확장 자동 설치');
        }
      case 'firefox':
        if (!ext.firefoxEnforcementReady) {
          lines.add('원탭 차단 적용 시 Firefox 확장 설치');
        }
      case 'brave':
        if (braveExt != null && !braveExt.extensionReady) {
          lines.add('Brave 확장 — 원탭 차단 적용으로 설치');
        }
      case 'whale':
      case 'vivaldi':
      case 'opera':
        if (derivativeExt != null && !derivativeExt.extensionReady) {
          lines.add('${b.displayName} 확장 — 원탭 차단 적용으로 설치');
        }
      default:
        break;
    }
  }

  static bool _isKillGuardTarget(String id) =>
      id == 'firefox' ||
      id == 'whale' ||
      id == 'brave' ||
      id == 'vivaldi' ||
      id == 'opera' ||
      id == 'chrome' ||
      id == 'edge';

  static String _processLabel(String id) {
    switch (id) {
      case 'brave':
        return 'brave';
      case 'whale':
        return 'whale';
      case 'vivaldi':
        return 'vivaldi';
      case 'opera':
        return 'opera';
      case 'firefox':
        return 'firefox';
      case 'edge':
        return 'msedge';
      case 'chrome':
        return 'chrome';
      default:
        return id;
    }
  }

  EcosystemTargetRow _safariRowForWindows() {
    return const EcosystemTargetRow(
      id: 'safari',
      displayName: 'Safari',
      level: EcosystemScanLevel.unavailable,
      headline: 'Windows PC — 해당 없음',
      detailLines: <String>[
        'Mac·iPhone용 Focus Fense에서 hosts + Safari 확장으로 차단',
      ],
      installed: false,
      pluginSupportReady: false,
      pluginSupportLabel: '플러그인 준비 안 됨 (Windows)',
    );
  }

  EcosystemTargetRow _iosSafariRow() {
    return const EcosystemTargetRow(
      id: 'safari_ios',
      displayName: 'Safari (iPhone)',
      level: EcosystemScanLevel.unavailable,
      headline: '별도 iOS 앱',
      detailLines: <String>[
        'iPhone용 Focus Fense + Safari 웹 확장',
      ],
      installed: false,
      pluginSupportReady: false,
      pluginSupportLabel: '플러그인 준비 안 됨 (Windows)',
    );
  }

  List<EcosystemTargetRow> _attachCatalog(List<EcosystemTargetRow> rows) {
    return rows.map((EcosystemTargetRow t) {
      final BrowserCatalogEntry? cat = BrowserCatalogEntry.forId(t.id);
      if (cat == null) return t;
      return t.withCatalog(
        installUrl: cat.installUrl,
        uninstallHintKo: cat.uninstallHintKo,
        appsSearchName: cat.appsSearchName,
        pluginSupportReady: cat.pluginSupportReady,
        pluginSupportLabel: cat.pluginReadyBadgeKo,
        ifYouInstallKo: t.ifYouInstallKo ?? cat.ifYouInstallKo,
      );
    }).toList();
  }

  String _buildSummaryKo({
    required List<EcosystemTargetRow> targets,
    required String buildLabel,
    required String platformLabel,
    DefaultBrowserAdvisory? defaultBrowser,
  }) {
    final List<String> usable = targets
        .where((EcosystemTargetRow t) => t.installed && t.urlBlockUsable)
        .map((EcosystemTargetRow t) => t.displayName)
        .toList();
    final List<String> off = targets
        .where((EcosystemTargetRow t) =>
            t.installed && !t.urlBlockUsable)
        .map((EcosystemTargetRow t) => t.displayName)
        .toList();
    if (defaultBrowser?.isProblem == true) {
      return '$buildLabel · $platformLabel — 기본 브라우저(${defaultBrowser!.displayName}) '
          '주의: ${defaultBrowser.suggestSwitchTo ?? "차단 OK 브라우저"}(으)로 기본 앱 변경 권장.';
    }
    if (off.isNotEmpty) {
      return '$buildLabel · $platformLabel — ${off.join(", ")} URL 차단 미적용. '
          '「원탭 차단 적용」을 실행하세요.';
    }
    if (usable.isNotEmpty) {
      final String def = defaultBrowser != null && defaultBrowser.blockActive
          ? ' · 기본 브라우저 ${defaultBrowser.displayName} OK'
          : '';
      return '$buildLabel · $platformLabel — 지금 URL 차단 가능: ${usable.join(", ")}$def.';
    }
    return '$buildLabel · $platformLabel — 브라우저를 설치하고 원탭 적용을 실행하세요.';
  }

  Future<void> _writeJson(BlockingEcosystemReport report) async {
    try {
      final File f = File(reportPath);
      await f.parent.create(recursive: true);
      await f.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report.toJson()),
        flush: true,
      );
    } catch (e) {
      AppLogger.instance.warn('ecosystem_scan json write failed: $e');
    }
  }
}
