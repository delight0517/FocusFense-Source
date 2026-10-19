import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'blocking_ecosystem_scan_service.dart';
import 'browser_block_health_monitor_service.dart';
import 'browser_enforcement_readiness_service.dart';
import 'browser_live_url_block_gate_service.dart';
import 'chrome_gmail_gemini_allowlist_service.dart';

/// **Single source of truth** for “which browsers can actually block URLs” vs
/// “which browsers the app must kill on sight”.
///
/// Merges registry health ([BrowserBlockHealthReport]) with live headless
/// probes ([BrowserLiveUrlBlockGateService]) so the startup status screen,
/// kill guard, and ecosystem scan never disagree.
final class BrowserProtectionTruthService {
  BrowserProtectionTruthService._();
  static final BrowserProtectionTruthService instance =
      BrowserProtectionTruthService._();

  static const Duration _kTruthCacheTtl = Duration(seconds: 45);

  List<BrowserProtectionTruth>? _cachedTruth;
  BrowserBlockHealthReport? _cachedHealth;
  DateTime? _truthCacheAt;
  DateTime? _lastLiveReadWarnAt;
  Timer? _liveGateNotifyDebounce;

  static String snapshotPath() {
    final String local = Platform.environment['LOCALAPPDATA'] ?? '';
    return p.join(local, 'SixVPNBlocker', 'browser_protection_truth.json');
  }

  /// Merge health + live gate into per-browser truth rows.
  Future<List<BrowserProtectionTruth>> mergeFromHealth(
    BrowserBlockHealthReport health,
  ) async {
    final DateTime now = DateTime.now();
    if (_cachedTruth != null &&
        _cachedHealth != null &&
        _cachedHealth!.checkedAt == health.checkedAt &&
        _truthCacheAt != null &&
        now.difference(_truthCacheAt!) < _kTruthCacheTtl) {
      return _cachedTruth!;
    }

    final Map<String, BrowserLiveGateRow> liveById =
        await _liveRowsByBrowserId();
    final Set<String> hardKill = await BrowserLiveUrlBlockGateService.instance
        .hardKillBrowserIds();
    final bool chromeGmailGeminiOn = await ChromeGmailGeminiAllowlistService
        .instance
        .enabled();
    final Map<String, BrowserEnforcementReadiness> readiness =
        await BrowserEnforcementReadinessService.instance.snapshot();

    final List<BrowserProtectionTruth> out = <BrowserProtectionTruth>[];
    for (final BrowserHealth b in health.browsers) {
      final BrowserLiveGateRow? live = liveById[b.id];
      final bool rawHard = hardKill.contains(b.id) || (live?.hardKill ?? false);
      final bool hard = b.id == 'chrome' && chromeGmailGeminiOn
          ? false
          : rawHard;
      final bool extensionReady = readiness[b.id]?.extensionReady ?? false;
      out.add(
        BrowserProtectionTruth(
          health: b,
          extensionReady: extensionReady,
          liveUrlBlocked: live?.liveBlocked,
          liveRegistryOk: live?.registryOk,
          hardKill: hard,
          chromeGmailGeminiExempt: b.id == 'chrome' && chromeGmailGeminiOn,
          liveDetail: live?.detailKo,
          liveTestedAt: await _liveReportTimestamp(),
        ),
      );
    }

    await _writeSnapshot(health, out);
    _cachedHealth = health;
    _cachedTruth = out;
    _truthCacheAt = now;
    return out;
  }

  void invalidateCache() {
    _cachedTruth = null;
    _cachedHealth = null;
    _truthCacheAt = null;
  }

  Future<BrowserProtectionTruth?> forBrowserId(String id) async {
    final BrowserBlockHealthReport health =
        BrowserBlockHealthMonitorService.instance.latest ??
        await BrowserBlockHealthMonitorService.instance.probe(
          reason: 'truth_lookup',
        );
    final List<BrowserProtectionTruth> rows = await mergeFromHealth(health);
    for (final BrowserProtectionTruth t in rows) {
      if (t.health.id == id) return t;
    }
    return null;
  }

  Future<Set<String>> forceKillBrowserIds() async {
    final BrowserBlockHealthReport health =
        BrowserBlockHealthMonitorService.instance.latest ??
        BrowserBlockHealthReport.empty(reason: 'truth_kill');
    final List<BrowserProtectionTruth> rows = await mergeFromHealth(health);
    return rows
        .where((BrowserProtectionTruth t) => t.shouldForceKillWhenRunning)
        .map((BrowserProtectionTruth t) => t.health.id)
        .toSet();
  }

  Future<Map<String, BrowserLiveGateRow>> _liveRowsByBrowserId() async {
    final Map<String, BrowserLiveGateRow> map = <String, BrowserLiveGateRow>{};
    // Prefer Dart-written roster (atomic). PS report JSON can be partial mid-test.
    for (final String path in <String>[
      BrowserLiveUrlBlockGateService.rosterPath(),
      BrowserLiveUrlBlockGateService.reportPath(),
    ]) {
      try {
        final File f = File(path);
        if (!await f.exists()) continue;
        final String raw = await f.readAsString();
        if (raw.trim().isEmpty) continue;
        final Object? decoded = jsonDecode(raw);
        if (decoded is! Map) continue;
        final Object? bl = decoded['browsers'];
        if (bl is! List) continue;
        for (final Object item in bl) {
          if (item is! Map) continue;
          final BrowserLiveGateRow row = BrowserLiveGateRow.fromJson(
            Map<String, Object?>.from(item),
          );
          if (row.id.isNotEmpty) map[row.id] = row;
        }
        if (map.isNotEmpty) return map;
      } catch (e) {
        if (_shouldWarnLiveRead()) {
          AppLogger.instance.warn(
            'browser_protection_truth live read ($path): $e',
          );
        }
      }
    }
    return map;
  }

  bool _shouldWarnLiveRead() {
    final DateTime now = DateTime.now();
    if (_lastLiveReadWarnAt != null &&
        now.difference(_lastLiveReadWarnAt!) < const Duration(seconds: 60)) {
      return false;
    }
    _lastLiveReadWarnAt = now;
    return true;
  }

  Future<DateTime?> _liveReportTimestamp() async {
    try {
      final File f = File(BrowserLiveUrlBlockGateService.reportPath());
      if (!await f.exists()) return null;
      final Object? decoded = jsonDecode(await f.readAsString());
      if (decoded is! Map) return null;
      return DateTime.tryParse('${decoded['timestamp'] ?? ''}');
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeSnapshot(
    BrowserBlockHealthReport health,
    List<BrowserProtectionTruth> rows,
  ) async {
    try {
      final File f = File(snapshotPath());
      await f.parent.create(recursive: true);
      await f.writeAsString(
        const JsonEncoder.withIndent('  ').convert(<String, Object?>{
          'updatedAt': DateTime.now().toIso8601String(),
          'healthCheckedAt': health.checkedAt.toIso8601String(),
          'hasAnyRule': health.hasAnyRule,
          'urlBlockUsableIds': rows
              .where((BrowserProtectionTruth t) => t.urlBlockUsable)
              .map((BrowserProtectionTruth t) => t.health.id)
              .toList(),
          'forceKillIds': rows
              .where((BrowserProtectionTruth t) => t.shouldForceKillWhenRunning)
              .map((BrowserProtectionTruth t) => t.health.id)
              .toList(),
          'browsers': rows
              .map((BrowserProtectionTruth t) => t.toJson())
              .toList(),
        }),
        flush: true,
      );
    } catch (e) {
      AppLogger.instance.warn('browser_protection_truth snapshot write: $e');
    }
  }

  /// Call after live URL gate test so UI picks up new roster (debounced).
  void notifyLiveGateUpdated() {
    _liveGateNotifyDebounce?.cancel();
    _liveGateNotifyDebounce = Timer(const Duration(seconds: 8), () {
      invalidateCache();
      BrowserEnforcementReadinessService.instance.invalidate();
      BlockingEcosystemScanService.instance.invalidateCache();
      BlockingEcosystemScanService.instance.requestRefresh(
        reason: 'live_gate',
        force: false,
      );
    });
  }
}

/// Per-browser merged verdict — UI, kill guard, and ecosystem scan share this.
final class BrowserProtectionTruth {
  const BrowserProtectionTruth({
    required this.health,
    required this.hardKill,
    this.extensionReady = false,
    this.chromeGmailGeminiExempt = false,
    this.liveUrlBlocked,
    this.liveRegistryOk,
    this.liveDetail,
    this.liveTestedAt,
  });

  final BrowserHealth health;
  final bool hardKill;

  /// Six VPN MV3/XPI extension installed — YouTube는 스케줄 목록만 차단.
  final bool extensionReady;

  /// Chrome Gmail/Gemini-only mode — kill guard must not close Chrome.
  final bool chromeGmailGeminiExempt;
  final bool? liveUrlBlocked;
  final bool? liveRegistryOk;
  final String? liveDetail;
  final DateTime? liveTestedAt;

  /// Registry/file policy looks populated (independent of live headless probe).
  bool get policyLooksApplied =>
      health.policyHasEntries &&
      health.policyEntryCount >= 20 &&
      health.policySampleMatch;

  /// URLBlocklist / WebsiteFilter is active in the running browser.
  bool get urlPolicyWorks =>
      health.blockActive && health.effectivelyBlockActive && policyLooksApplied;

  /// Extension **or** URL policy **or** live headless probe — at least one works.
  bool get hasWorkingProtection {
    if (extensionReady) return true;
    if (liveUrlBlocked == true) return true;
    if (urlPolicyWorks) return true;
    return false;
  }

  /// **현황판 「사용 가능」** — extension list-mode OR URL 차단 실측/정책 OK.
  bool get urlBlockUsable {
    if (!health.installed) return false;
    if (chromeGmailGeminiExempt) return true;
    if (hardKill) return false;
    if (!hasWorkingProtection) return false;
    if (liveUrlBlocked == false) return false;
    if (health.running && !health.effectivelyBlockActive && !extensionReady) {
      return false;
    }
    return true;
  }

  /// 플러그인·URL 차단 둘 다 안 되면 브라우저 통째로 종료.
  /// 6 VPN: NEUTRALIZED 2026-06-12. NEVER true — mid-session kill forbidden.
  /// Launch-time block handled by IFEO Debugger registry hook instead.
  bool get shouldForceKillWhenRunning => false;

  String get statusHeadlineKo {
    if (!health.installed) return '미설치';
    if (chromeGmailGeminiExempt) {
      return 'Gmail·Gemini만 허용 — 일반 Chrome 종료 안 함';
    }
    if (hardKill) {
      return 'OS 레벨 실행 차단 — IFEO Debugger 적용 (사용 중 종료 없음)';
    }
    if (extensionReady && (urlPolicyWorks || liveUrlBlocked == true)) {
      return 'Tier 1 — 확장 + 정책 적용. 사용 가능';
    }
    if (hardKill || liveUrlBlocked == false) {
      return '확장 미설치 — Plugin 작업 후 활성화 예정';
    }
    if (extensionReady && !urlPolicyWorks) {
      return '확장 적용 — YouTube 스케줄 목록만 차단';
    }
    if (liveUrlBlocked == true) {
      return 'URL 차단 사용 가능 (실측 통과)';
    }
    if (urlPolicyWorks) {
      return extensionReady ? '확장 + URL 차단 적용됨' : 'URL 차단 적용됨 (YouTube 전체)';
    }
    if (health.running && !health.effectivelyBlockActive) {
      return '재시작 필요 — 정책 미로드';
    }
    return '일부만 적용';
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'id': health.id,
    'displayName': health.displayName,
    'installed': health.installed,
    'extensionReady': extensionReady,
    'urlBlockUsable': urlBlockUsable,
    'shouldForceKillWhenRunning': shouldForceKillWhenRunning,
    'hardKill': hardKill,
    'liveUrlBlocked': liveUrlBlocked,
    'blockActive': health.blockActive,
    'effectivelyBlockActive': health.effectivelyBlockActive,
    'headlineKo': statusHeadlineKo,
    'liveDetail': liveDetail,
    'liveTestedAt': liveTestedAt?.toIso8601String(),
  };
}
