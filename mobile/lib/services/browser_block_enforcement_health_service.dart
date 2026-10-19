import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'automated_browser_handoff_service.dart';
import 'block_activity_log_service.dart';
import 'chrome_block_autonomy_service.dart';
import 'chrome_load_extension_launcher.dart';
import 'extension_rules_builder.dart';
import 'usage_ingest_server.dart';
import 'windows_extension_guard_service.dart';
import 'windows_firefox_extension_install_service.dart';

/// Whether configured YouTube/browser rules are actually firing in the browser.
enum BrowserEnforcementPhase {
  /// No YouTube/channel keywords in active schedules — nothing to enforce in-browser.
  noYoutubeRules,

  /// recentBlocks or live rulesFetch proves the extension pipeline works.
  enforcing,

  /// Rules exist but the browser never reported a block / rules fetch (user sees videos).
  rulesReadyNotEnforcing,

  /// App-side extension install / rules API missing.
  notConnected,
}

final class BrowserEnforcementHealth {
  const BrowserEnforcementHealth({
    required this.phase,
    required this.youtubeRuleCount,
    required this.recentBlockCount,
    required this.rulesFetchSeen,
    required this.browserInstallOk,
    required this.rulesApiRunning,
    this.sampleRule,
    this.chromeUnprotectedRunning = false,
    this.chromeStatusMessage,
  });

  final BrowserEnforcementPhase phase;
  final int youtubeRuleCount;
  final int recentBlockCount;
  final bool rulesFetchSeen;
  final bool browserInstallOk;
  final bool rulesApiRunning;
  final String? sampleRule;
  /// True when a main Chrome window is running without load-extension / policy protection.
  final bool chromeUnprotectedRunning;
  final String? chromeStatusMessage;

  /// Snackbars / auto-handoff only when plain Chrome is up or extensions missing.
  bool get needsUserAction =>
      chromeUnprotectedRunning ||
      phase == BrowserEnforcementPhase.notConnected;

  String get headline {
    if (chromeUnprotectedRunning) {
      return 'Chrome이 보호 없이 열려 있습니다';
    }
    switch (phase) {
      case BrowserEnforcementPhase.enforcing:
        return '브라우저 차단이 동작 중입니다';
      case BrowserEnforcementPhase.noYoutubeRules:
        return '유튜브·채널 규칙 없음';
      case BrowserEnforcementPhase.rulesReadyNotEnforcing:
        return '확장 동기화 확인 중';
      case BrowserEnforcementPhase.notConnected:
        return '앱이 브라우저 보호를 자동 설정 중';
    }
  }

  String get explanation {
    if (chromeUnprotectedRunning) {
      return '일반 Chrome에는 차단 확장이 없어서 유튜브 watch?v= 영상이 그대로 보입니다. '
          '앱 규칙은 이미 등록되어 있으니, 보호 Chrome으로 바꾸면 막힙니다. '
          '아래 「보호 Chrome 열기」를 누르거나 1~2분 기다리면 자동 전환됩니다.';
    }
    switch (phase) {
      case BrowserEnforcementPhase.enforcing:
        return '최근 차단 기록이 있습니다. LowkoTV 같은 채널·영상 URL은 보호 Chrome에서 열리지 않아야 합니다.';
      case BrowserEnforcementPhase.noYoutubeRules:
        return '스케줄에 유튜브 채널·영상 URL이 켜져 있어야 watch 페이지가 막힙니다.';
      case BrowserEnforcementPhase.rulesReadyNotEnforcing:
        return '규칙은 적용되어 있습니다. 유튜브를 열어 차단이 되는지 확인하거나, '
            '일반 Chrome이 떠 있으면 상단 배너에서 전환하세요.';
      case BrowserEnforcementPhase.notConnected:
        return '앱이 확장·PAC·바로가기를 자동 복구 중입니다.';
    }
  }

  List<String> get steps => const <String>[];
}

final class BrowserBlockEnforcementHealthService {
  BrowserBlockEnforcementHealthService._();
  static final BrowserBlockEnforcementHealthService instance =
      BrowserBlockEnforcementHealthService._();

  final ValueNotifier<BrowserEnforcementHealth?> latest =
      ValueNotifier<BrowserEnforcementHealth?>(null);

  static const Duration _kCacheTtl = Duration(seconds: 30);
  BrowserEnforcementHealth? _cache;
  DateTime? _cacheAt;

  static bool _isYoutubeKeyword(String pattern) {
    final String s = pattern.trim().toLowerCase();
    if (s.isEmpty) return false;
    if (s.contains('youtube.com') || s.contains('youtu.be')) return true;
    if (RegExp(r'^@[^/?#\s]+').hasMatch(s)) return true;
    if (RegExp(r'^/(@[^/?#\s]+|c/[^/?#\s]+)').hasMatch(s)) return true;
    if (RegExp(r'watch\?v=[\w-]{6,}').hasMatch(s)) return true;
    return false;
  }

  Future<BrowserEnforcementHealth> analyze({bool force = false}) async {
    if (!force && _cache != null && _cacheAt != null &&
        DateTime.now().difference(_cacheAt!) < _kCacheTtl) {
      return _cache!;
    }
    if (!Platform.isWindows && !Platform.isMacOS) {
      const BrowserEnforcementHealth h = BrowserEnforcementHealth(
        phase: BrowserEnforcementPhase.noYoutubeRules,
        youtubeRuleCount: 0,
        recentBlockCount: 0,
        rulesFetchSeen: false,
        browserInstallOk: false,
        rulesApiRunning: false,
      );
      latest.value = h;
      return h;
    }

    final ExtensionRulesPayload rules =
        await ExtensionRulesBuilder.buildActiveNow();
    final List<String> ytKeys = rules.keywords
        .where(_isYoutubeKeyword)
        .toList();
    final int ytCount = ytKeys.length;

    if (ytCount == 0) {
      final BrowserEnforcementHealth h = BrowserEnforcementHealth(
        phase: BrowserEnforcementPhase.noYoutubeRules,
        youtubeRuleCount: 0,
        recentBlockCount: 0,
        rulesFetchSeen: false,
        browserInstallOk: false,
        rulesApiRunning: UsageIngestServer.instance.isRunning,
        sampleRule: null,
      );
      latest.value = h;
      return h;
    }

    bool rulesApiRunning = UsageIngestServer.instance.isRunning;
    bool browserInstallOk = false;
    if (Platform.isWindows) {
      final ExtensionPolicyVerifyResult v =
          await WindowsExtensionGuardService.verifyAllPolicies();
      browserInstallOk = v.chromeEnforcementReady &&
          v.edgeEnforcementReady &&
          (v.firefoxPolicyOk ||
              !await WindowsFirefoxExtensionInstallService.isFirefoxInstalled());
      if (!browserInstallOk) {
        browserInstallOk = await ChromeLoadExtensionLauncher.isInstalled();
      }
    }

    int recentBlockCount = 0;
    bool rulesFetchSeen = false;
    try {
      final File sum = File(BlockActivityLogService.instance.summaryPath);
      if (await sum.exists()) {
        final Object? decoded = jsonDecode(await sum.readAsString());
        if (decoded is Map) {
          final List<dynamic> blocks =
              decoded['recentBlocks'] as List<dynamic>? ?? <dynamic>[];
          recentBlockCount = blocks.length;
          final List<dynamic> events =
              decoded['recentEvents'] as List<dynamic>? ?? <dynamic>[];
          for (final dynamic e in events) {
            if (e is! Map) continue;
            if (e['kind'] == 'rulesFetch') {
              rulesFetchSeen = true;
              break;
            }
          }
        }
      }
    } catch (_) {}

    if (!rulesFetchSeen) {
      rulesFetchSeen = BlockActivityLogService.instance.events.any(
        (BlockActivityEvent e) => e.kind == BlockActivityKind.rulesFetch,
      );
    }

    bool chromeReady = false;
    String? chromeStatusMessage;
    bool chromeUnprotectedRunning = false;
    if (Platform.isWindows) {
      final BrowserProcessProbe probe =
          await AutomatedBrowserHandoffService.probeBrowsers();
      chromeUnprotectedRunning =
          probe.chromeRunning && probe.chromeUnprotected;
      final ChromeBlockStatus chrome =
          await ChromeBlockAutonomyService.instance.runOnce(repair: false);
      chromeStatusMessage = chrome.userMessage;
      chromeReady = chrome.blockingOk;
      if (chromeUnprotectedRunning && !chrome.blockingOk) {
        chromeReady = false;
      }
    } else {
      chromeReady = browserInstallOk && rulesApiRunning;
    }

    BrowserEnforcementPhase phase;
    if (chromeUnprotectedRunning) {
      phase = BrowserEnforcementPhase.rulesReadyNotEnforcing;
    } else if (chromeReady && (recentBlockCount > 0 || rulesFetchSeen)) {
      phase = BrowserEnforcementPhase.enforcing;
    } else if (chromeReady) {
      phase = BrowserEnforcementPhase.enforcing;
    } else if (!rulesApiRunning || !browserInstallOk) {
      phase = BrowserEnforcementPhase.notConnected;
    } else {
      phase = BrowserEnforcementPhase.rulesReadyNotEnforcing;
    }

    final BrowserEnforcementHealth h = BrowserEnforcementHealth(
      phase: phase,
      youtubeRuleCount: ytCount,
      recentBlockCount: recentBlockCount,
      rulesFetchSeen: rulesFetchSeen,
      browserInstallOk: browserInstallOk,
      rulesApiRunning: rulesApiRunning,
      sampleRule: ytKeys.isNotEmpty ? ytKeys.first : null,
      chromeUnprotectedRunning: chromeUnprotectedRunning,
      chromeStatusMessage: chromeStatusMessage,
    );
    _cache = h;
    _cacheAt = DateTime.now();
    latest.value = h;
    return h;
  }
}
