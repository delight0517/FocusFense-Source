import 'dart:async';
import 'dart:io';

import '../models/block_app.dart';
import 'app_logger.dart';
import 'extension_rules_builder.dart';
import 'local_database.dart';
import 'quick_block_session_service.dart';
import 'network_url_block_service.dart';
import 'universal_browser_block_service.dart';
import 'windows_emergency_block_service.dart';
import 'windows_firewall_block_service.dart';
import 'windows_system_block_service.dart';
import 'windows_window_title_guard_service.dart';
import 'windows_protection_mode_prefs.dart';

/// Orchestrates all 5 Windows blocking layers (performance-aware).
///
/// 1. OS hosts (DNS) — [WindowsSystemBlockService] via [BlockSyncService]
/// 2. Browser extension (DOM/DNR) — extension assets + rules API
/// 3. Network PAC proxy — [UniversalBrowserBlockService]
/// 4. Window title guard — [WindowsWindowTitleGuardService]
/// 5. Windows Firewall IP — [WindowsFirewallBlockService]
final class FiveLayerStatus {
  const FiveLayerStatus({
    required this.layer1Hosts,
    required this.layer2Extension,
    required this.layer3PacProxy,
    required this.layer4WindowTitle,
    required this.layer5Firewall,
    this.firewallRuleCount = 0,
    this.windowGuardPatterns = 0,
    this.message = '',
  });

  final bool layer1Hosts;
  final bool layer2Extension;
  final bool layer3PacProxy;
  final bool layer4WindowTitle;
  final bool layer5Firewall;
  final int firewallRuleCount;
  final int windowGuardPatterns;
  final String message;

  int get activeCount => <bool>[
    layer1Hosts,
    layer2Extension,
    layer3PacProxy,
    layer4WindowTitle,
    layer5Firewall,
  ].where((bool v) => v).length;

  bool get anyActive => activeCount > 0;
}

final class WindowsFiveLayerBlockService {
  WindowsFiveLayerBlockService._();
  static final WindowsFiveLayerBlockService instance =
      WindowsFiveLayerBlockService._();

  static const Duration _kMinGap = Duration(seconds: 20);

  FiveLayerStatus? _lastStatus;
  DateTime? _lastSyncAt;
  Completer<FiveLayerStatus>? _inFlight;

  FiveLayerStatus? get lastStatus => _lastStatus;

  /// Sync layers 3–5 (hosts layer 1 is handled by BlockSyncService).
  Future<FiveLayerStatus> syncLayers({String reason = 'rules'}) async {
    if (!Platform.isWindows) {
      return const FiveLayerStatus(
        layer1Hosts: false,
        layer2Extension: false,
        layer3PacProxy: false,
        layer4WindowTitle: false,
        layer5Firewall: false,
        message: 'Windows 전용',
      );
    }
    if (WindowsProtectionModePrefs.isProtectionExplicitlyOff) {
      const FiveLayerStatus paused = FiveLayerStatus(
        layer1Hosts: false,
        layer2Extension: false,
        layer3PacProxy: false,
        layer4WindowTitle: false,
        layer5Firewall: false,
        message: '사용자가 Windows 보호를 수동으로 꺼 둠',
      );
      _lastStatus = paused;
      return paused;
    }
    final Completer<FiveLayerStatus>? existing = _inFlight;
    if (existing != null) return existing.future;

    final DateTime? last = _lastSyncAt;
    if (_lastStatus != null &&
        last != null &&
        DateTime.now().difference(last) < _kMinGap &&
        reason != 'manual' &&
        reason != 'one_tap' &&
        reason != 'experiment' &&
        reason != 'diagnostics_ui' &&
        reason != 'boot' &&
        reason != 'hosts_apply') {
      return _lastStatus!;
    }

    final Completer<FiveLayerStatus> completer = Completer<FiveLayerStatus>();
    _inFlight = completer;
    try {
      final ExtensionRulesPayload rules =
          await ExtensionRulesBuilder.buildForBrowserEnforcement();
      final bool hasRules =
          rules.blockedDomains.isNotEmpty ||
          rules.keywords.isNotEmpty ||
          rules.hasYoutubeChannelBlocks ||
          rules.blockedYoutubeVideoIds.isNotEmpty ||
          rules.searchQueries.isNotEmpty;

      if (!hasRules) {
        await WindowsWindowTitleGuardService.instance.stop();
        await WindowsFirewallBlockService.instance.deactivate();
        _lastStatus = const FiveLayerStatus(
          layer1Hosts: false,
          layer2Extension: false,
          layer3PacProxy: false,
          layer4WindowTitle: false,
          layer5Firewall: false,
          message: '활성 규칙 없음',
        );
        _lastSyncAt = DateTime.now();
        completer.complete(_lastStatus!);
        return _lastStatus!;
      }

      // Layer 3: PAC + HKCU — immediate on manual/one_tap, else debounced.
      NetworkUrlBlockResult? netResult;
      if (reason == 'manual' || reason == 'one_tap' || reason == 'experiment') {
        netResult = await NetworkUrlBlockService.instance.enforceNow(
          reason: reason,
        );
      } else {
        UniversalBrowserBlockService.instance.scheduleSync(reason: reason);
      }

      // Layer 4: window title patterns from rules + schedule app blocks.
      final scheduleApps = await LocalDatabase.instance
          .blockedWindowsAppsActiveNow(DateTime.now());
      final quickApps = await QuickBlockSessionService.instance
          .activeBlockApps();
      final Map<String, BlockApp> appsByKey = <String, BlockApp>{};
      for (final BlockApp app in <BlockApp>[...scheduleApps, ...quickApps]) {
        final String key = app.exeName.isEmpty
            ? 't:${app.windowTitleMatch}'
            : app.exeName;
        appsByKey[key] = app;
      }
      await WindowsWindowTitleGuardService.instance.syncPatterns(
        rules: rules,
        extraApps: appsByKey.values.toList(),
      );

      // Layer 5: firewall — always prepare BAT; netsh when not throttled.
      final FirewallBlockResult fw =
          (reason == 'boot' ||
              reason == 'experiment' ||
              reason == 'diagnostics_ui')
          ? await WindowsFirewallBlockService.instance.prepareStateOnly()
          : await WindowsFirewallBlockService.instance.syncFromHosts(
              force: reason == 'manual' || reason == 'hosts_apply',
            );

      final bool hosts = await WindowsSystemBlockService.instance.isActive();
      final WindowTitleGuardResult? wt =
          WindowsWindowTitleGuardService.instance.lastResult;
      final EmergencyBlockResult pacStatus = await WindowsEmergencyBlockService
          .instance
          .readStatus();
      final bool pacOk = netResult?.pacActive ?? pacStatus.pacApplied;
      final bool extRules =
          rules.hasYoutubeChannelBlocks ||
          rules.blockedYoutubeVideoIds.isNotEmpty ||
          rules.keywords.isNotEmpty ||
          rules.blockedDomains.isNotEmpty;

      _lastStatus = FiveLayerStatus(
        layer1Hosts: hosts,
        layer2Extension: extRules,
        layer3PacProxy: pacOk,
        layer4WindowTitle: wt?.active ?? false,
        layer5Firewall: fw.pendingOrActive,
        firewallRuleCount: fw.ruleCount,
        windowGuardPatterns: wt?.patternCount ?? 0,
        message: '5계층 동기화 ($reason)',
      );
      _lastSyncAt = DateTime.now();
      AppLogger.instance.info(
        'five_layer: hosts=$hosts pac=1 wt=${wt?.patternCount} fw=${fw.ruleCount}',
      );
      completer.complete(_lastStatus!);
      return _lastStatus!;
    } catch (e, st) {
      AppLogger.instance.warn('five_layer sync failed', error: e);
      AppLogger.instance.log('DEBUG', 'five_layer stack', stack: st);
      final FiveLayerStatus fallback =
          _lastStatus ??
          FiveLayerStatus(
            layer1Hosts: false,
            layer2Extension: false,
            layer3PacProxy: false,
            layer4WindowTitle: false,
            layer5Firewall: false,
            message: e.toString(),
          );
      if (!completer.isCompleted) completer.complete(fallback);
      return fallback;
    } finally {
      _inFlight = null;
    }
  }
}
