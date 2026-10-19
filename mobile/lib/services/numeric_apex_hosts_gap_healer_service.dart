import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../utils/numeric_suffix_evasion.dart';
import 'app_logger.dart';
import 'autonomous_apply_uac_prompt_service.dart';
import 'block_activity_log_service.dart';
import 'block_sync_service.dart';
import 'blocking_repair_failure_tracker_service.dart';
import 'blocker_test_service.dart';
import 'crash_journal_service.dart';
import 'extension_rules_builder.dart';
import 'mac_system_block_service.dart';
import 'windows_hidden_process.dart';
import 'windows_system_block_service.dart';

/// Detects numeric-evasion apex hosts (e.g. `mingky01.live`) that still resolve
/// to a real IP and triggers a hosts/DNS re-apply â€” no manual Chrome restart.
/// Why this exists:
/// Some blocked adult/mirror sites rotate numbered hostnames that URLBlocklist
/// may not fully cover, so the app probes a small priority set for drift. It
/// should repair only user-space layers automatically; hosts/admin repair is
/// allowed only when the user explicitly starts an apply flow.
final class NumericApexHostsGapHealerService {
  NumericApexHostsGapHealerService._();
  static final NumericApexHostsGapHealerService instance =
      NumericApexHostsGapHealerService._();

  static const Duration _minHealGap = Duration(minutes: 4);

  bool _busy = false;
  DateTime? _lastHealAt;

  String get reportPath => p.join(
    CrashJournalService.instance.debugFolderPath,
    'numeric_apex_hosts_gap_heal_last.json',
  );

  /// Priority apex hosts that must sinkhole via `hosts` (URLBlocklist alone leaks).
  Future<List<String>> priorityProbeHosts({int maxHosts = 6}) async {
    final ExtensionRulesPayload payload =
        await ExtensionRulesBuilder.buildForBrowserEnforcement();
    final List<String> hosts = <String>[];
    final Set<String> seen = <String>{};
    void addProbeHost(String raw) {
      final String c = MacSystemBlockService.canonicalHost(raw);
      if (c.isEmpty || !seen.add(c)) return;
      hosts.add(c);
    }

    for (final String h in rotatingNumericChildProbeHosts(
      payload.blockedDomains,
      maxHosts: maxHosts,
    )) {
      addProbeHost(h);
      if (hosts.length >= maxHosts) break;
    }

    for (final String stem in <String>[
      ...payload.numericStemHosts,
    ]) {
      for (final String h in NumericSuffixEvasion.priorityConcreteApexForStem(
        stem,
        maxHosts: 2,
      )) {
        addProbeHost(h);
        if (hosts.length >= maxHosts) break;
      }
      if (hosts.length >= maxHosts) break;
    }
    // @incident: adult-default-on — an empty user list must not probe or
    // re-apply the bundled adult canaries as implicit blocking rules.
    return hosts.take(maxHosts).toList();
  }

  /// Finds domains like `14.xbbg.tv` when `xbbg.tv` is also blocked, then
  /// probes the commonly rotated sibling (`16.xbbg.tv`) before lower-priority
  /// numeric apex checks.
  static List<String> rotatingNumericChildProbeHosts(
    Iterable<String> rawHosts, {
    int maxHosts = 6,
  }) {
    final Set<String> explicitHosts = <String>{};
    for (final String raw in rawHosts) {
      final String host = MacSystemBlockService.canonicalHost(raw);
      if (host.isNotEmpty) explicitHosts.add(host);
    }

    final Map<String, Set<int>> childrenByParent = <String, Set<int>>{};
    final RegExp numericPrefix = RegExp(r'^\d{1,3}$');
    for (final String host in explicitHosts) {
      final int dot = host.indexOf('.');
      if (dot <= 0 || dot == host.length - 1) continue;
      final String prefix = host.substring(0, dot);
      if (!numericPrefix.hasMatch(prefix)) continue;
      final String parent = host.substring(dot + 1);
      if (!explicitHosts.contains(parent)) continue;
      childrenByParent
          .putIfAbsent(parent, () => <int>{})
          .add(int.parse(prefix));
    }

    final List<String> out = <String>[];
    final Set<String> seen = <String>{};
    void add(String host) {
      if (out.length >= maxHosts) return;
      if (seen.add(host)) out.add(host);
    }

    for (final MapEntry<String, Set<int>> entry in childrenByParent.entries) {
      add('16.${entry.key}');
      final List<int> childNumbers = entry.value.toList()..sort();
      for (final int n in childNumbers) {
        add('$n.${entry.key}');
      }
    }
    return out;
  }

  Future<List<String>> findDnsLeaks({List<String>? hosts}) async {
    final List<String> probe = hosts ?? await priorityProbeHosts();
    final List<String> leaks = <String>[];
    for (final String host in probe) {
      final HostProbe r = await BlockerTestService.instance.systemProbe(host);
      if (!r.blocked) leaks.add(host);
    }
    return leaks;
  }

  /// Hosts file must contain `0.0.0.0 mingky01.live` â€” HKCU-only apply is not enough.
  Future<List<String>> findHostsFileLeaks({List<String>? hosts}) async {
    final List<String> probe = hosts ?? await priorityProbeHosts();
    final String? all =
        await WindowsSystemBlockService.tryReadSystemHostsNormalized();
    if (all == null) return probe;
    final List<String> leaks = <String>[];
    for (final String host in probe) {
      final RegExp line = RegExp(
        r'0\.0\.0\.0\s+' + RegExp.escape(host) + r'(\s|$)',
        caseSensitive: false,
      );
      if (!line.hasMatch(all)) leaks.add(host);
    }
    return leaks;
  }

  static bool _isHkcuOnlySuccess(MacBlockResult r) {
    if (r.status != MacBlockStatus.success) return false;
    final String m = (r.message ?? '').toLowerCase();
    return m.contains('ì‹œìŠ¤í…œ hosts') && m.contains('ì ìš©ë˜ì§€ ì•Šì•˜');
  }

  Future<void> _flushDnsCache() async {
    try {
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      await windowsRunHidden(
        p.join(windir, 'System32', 'ipconfig.exe'),
        const <String>['/flushdns'],
      );
    } catch (e) {
      AppLogger.instance.warn('numeric_apex_hosts_heal flushdns: $e');
    }
  }

  Future<MacBlockResult> _applyElevatedHosts() async {
    final WindowsBrowserLayersPrep prep = await WindowsSystemBlockService
        .instance
        .prepareBrowserLayers();
    final MacBlockResult r = await WindowsSystemBlockService.instance
        .applyElevatedHosts(
          prep.managedPayload,
          hkcu: prep.hkcu,
          emergency: prep.emergency,
        );
    BlockSyncService.instance.lastResult = r;
    if (r.status == MacBlockStatus.success && !_isHkcuOnlySuccess(r)) {
      BlockSyncService.instance.hostsApplyPending.value = false;
    }
    return r;
  }

  Future<bool> _verifySinkhole(List<String> probeHosts) async {
    final List<String> hostsLeaks = await findHostsFileLeaks(hosts: probeHosts);
    if (hostsLeaks.isNotEmpty) return false;
    final List<String> dnsLeaks = await findDnsLeaks(hosts: probeHosts);
    return dnsLeaks.isEmpty;
  }

  /// Returns healed host count (0 = already OK or skipped).
  Future<NumericApexHostsHealReport> healIfNeeded({
    String reason = 'manual',
    bool force = false,
    bool allowElevatedHosts = false,
  }) async {
    if (!Platform.isWindows) {
      return NumericApexHostsHealReport.skipped('Windows ì „ìš©');
    }
    if (_busy) {
      return NumericApexHostsHealReport.skipped('ì‹¤í–‰ ì¤‘');
    }
    final DateTime? last = _lastHealAt;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < _minHealGap) {
      return NumericApexHostsHealReport.skipped('ì¿¨ë‹¤ìš´');
    }

    _busy = true;
    try {
      final List<String> probeHosts = await priorityProbeHosts();
      if (await _verifySinkhole(probeHosts)) {
        final NumericApexHostsHealReport ok = NumericApexHostsHealReport(
          at: DateTime.now(),
          reason: reason,
          ok: true,
          probeHosts: probeHosts,
          leaksBefore: const <String>[],
          leaksAfter: const <String>[],
          actions: const <String>['dns_ok'],
          message: 'ìˆ«ìž ìš°íšŒ apex DNS sinkhole ì •ìƒ',
        );
        await _persist(ok);
        return ok;
      }

      final List<String> leaksBefore = await findDnsLeaks(hosts: probeHosts);
      final List<String> hostsLeaksBefore = await findHostsFileLeaks(
        hosts: probeHosts,
      );
      final List<String> actions = <String>[
        if (leaksBefore.isNotEmpty) 'dns_leak:${leaksBefore.join(",")}',
        if (hostsLeaksBefore.isNotEmpty)
          'hosts_missing:${hostsLeaksBefore.join(",")}',
      ];

      MacBlockResult finalApply;
      if (allowElevatedHosts) {
        actions.add('elevated_hosts_start');
        finalApply = await _applyElevatedHosts().timeout(
          const Duration(minutes: 4, seconds: 30),
          onTimeout: () => MacBlockResult.failure(
            'hosts UAC timeout - approve the Windows admin prompt to finish system DNS repair',
          ),
        );
        actions.add(
          _isHkcuOnlySuccess(finalApply)
              ? 'elevated_hkcu_only'
              : 'elevated_${finalApply.status.name}',
        );
      } else {
        finalApply = MacBlockResult.failure(
          'Admin repair needed - automatic UAC suppressed',
        );
        actions.add('elevated_hosts_deferred_no_auto_uac');
      }
      await Future<void>.delayed(const Duration(seconds: 2));
      await _flushDnsCache();
      await Future<void>.delayed(const Duration(seconds: 1));

      bool fixed = await _verifySinkhole(probeHosts);

      if (!fixed &&
          allowElevatedHosts &&
          (finalApply.status != MacBlockStatus.success ||
              _isHkcuOnlySuccess(finalApply))) {
        final MacBlockResult? prompted = await AutonomousApplyUacPromptService
            .instance
            .promptForNumericApexDnsRepair(reason: reason);
        if (prompted != null) {
          finalApply = prompted;
          actions.add(
            _isHkcuOnlySuccess(prompted)
                ? 'dialog_hkcu_only'
                : 'dialog_${prompted.status.name}',
          );
          await _flushDnsCache();
          await Future<void>.delayed(const Duration(seconds: 2));
          fixed = await _verifySinkhole(probeHosts);
        }
      }

      final List<String> leaksAfter = await findDnsLeaks(hosts: probeHosts);
      final List<String> hostsLeaksAfter = await findHostsFileLeaks(
        hosts: probeHosts,
      );

      final String message = fixed
          ? 'âœ… ìˆ«ìž ìš°íšŒ DNS sinkhole ìžë™ ë³µêµ¬ (${probeHosts.join(", ")} â†’ 0.0.0.0)'
          : finalApply.status == MacBlockStatus.cancelled
          ? 'âš ï¸ mingky01.live ë“± DNS ë¯¸ì°¨ë‹¨ â€” hosts ì ìš© UAC ã€Œì˜ˆã€ í•„ìš”'
          : hostsLeaksAfter.isNotEmpty
          ? 'âš ï¸ hostsì— ${hostsLeaksAfter.first} ì¤„ ì—†ìŒ â€” UAC ã€Œì˜ˆã€ í›„ ìž¬ì‹œë„'
          : 'âš ï¸ hosts ì ìš© í›„ DNS ìºì‹œ â€” ${leaksAfter.join(", ")} ì—¬ì „ížˆ ì‹¤ IP';

      final NumericApexHostsHealReport report = NumericApexHostsHealReport(
        at: DateTime.now(),
        reason: reason,
        ok: fixed,
        probeHosts: probeHosts,
        leaksBefore: leaksBefore,
        leaksAfter: leaksAfter,
        hostsLeaksBefore: hostsLeaksBefore,
        hostsLeaksAfter: hostsLeaksAfter,
        actions: actions,
        message: message,
        hostsApplyStatus: finalApply.status.name,
        hkcuOnlySuccess: _isHkcuOnlySuccess(finalApply),
      );
      _lastHealAt = DateTime.now();
      await _persist(report);

      BlockActivityLogService.instance.record(
        kind: BlockActivityKind.selfHeal,
        message: message,
        data: report.toJson(),
        level: fixed ? 'info' : 'warn',
        debounceKey: 'numeric_apex_hosts_heal',
      );
      await BlockingRepairFailureTrackerService.instance.record(
        component: 'numeric_apex_dns',
        action: 'gap_heal',
        ok: fixed,
        verdict: message,
        reason: reason,
        details: report.toJson(),
        failedLayers: fixed
            ? const <String>[]
            : <String>[
                if (hostsLeaksAfter.isNotEmpty) 'hosts_missing',
                if (leaksAfter.isNotEmpty) 'dns_leak',
                if (report.hkcuOnlySuccess) 'hkcu_only_false_success',
              ],
        appliedLayers: fixed ? <String>['dns_sinkhole'] : const <String>[],
        fixesAttempted: actions,
      );
      AppLogger.instance.info(
        'numeric_apex_hosts_heal [$reason] ok=$fixed dns=$leaksAfter hosts=$hostsLeaksAfter',
      );
      return report;
    } catch (e, st) {
      AppLogger.instance.warn('numeric_apex_hosts_heal failed: $e\n$st');
      return NumericApexHostsHealReport(
        at: DateTime.now(),
        reason: reason,
        ok: false,
        probeHosts: const <String>[],
        leaksBefore: const <String>[],
        leaksAfter: const <String>[],
        actions: const <String>['error'],
        message: 'ìˆ«ìž ìš°íšŒ DNS ë³µêµ¬ ì˜¤ë¥˜: $e',
      );
    } finally {
      _busy = false;
    }
  }

  Future<void> _persist(NumericApexHostsHealReport report) async {
    try {
      await CrashJournalService.instance.warmup();
      await File(reportPath).writeAsString(
        const JsonEncoder.withIndent('  ').convert(report.toJson()),
        flush: true,
      );
    } catch (_) {}
  }
}

final class NumericApexHostsHealReport {
  const NumericApexHostsHealReport({
    required this.at,
    required this.reason,
    required this.ok,
    required this.probeHosts,
    required this.leaksBefore,
    required this.leaksAfter,
    required this.actions,
    required this.message,
    this.hostsLeaksBefore = const <String>[],
    this.hostsLeaksAfter = const <String>[],
    this.hostsApplyStatus,
    this.hkcuOnlySuccess = false,
  });

  factory NumericApexHostsHealReport.skipped(String message) {
    return NumericApexHostsHealReport(
      at: DateTime.now(),
      reason: 'skipped',
      ok: true,
      probeHosts: const <String>[],
      leaksBefore: const <String>[],
      leaksAfter: const <String>[],
      actions: const <String>[],
      message: message,
    );
  }

  final DateTime at;
  final String reason;
  final bool ok;
  final List<String> probeHosts;
  final List<String> leaksBefore;
  final List<String> leaksAfter;
  final List<String> hostsLeaksBefore;
  final List<String> hostsLeaksAfter;
  final List<String> actions;
  final String message;
  final String? hostsApplyStatus;
  final bool hkcuOnlySuccess;

  Map<String, Object?> toJson() => <String, Object?>{
    'at': at.toIso8601String(),
    'reason': reason,
    'ok': ok,
    'probeHosts': probeHosts,
    'leaksBefore': leaksBefore,
    'leaksAfter': leaksAfter,
    'hostsLeaksBefore': hostsLeaksBefore,
    'hostsLeaksAfter': hostsLeaksAfter,
    'actions': actions,
    'message': message,
    if (hostsApplyStatus != null) 'hostsApplyStatus': hostsApplyStatus,
    'hkcuOnlySuccess': hkcuOnlySuccess,
  };
}
