import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'autonomous_apply_uac_prompt_service.dart';
import 'block_activity_log_service.dart';
import 'cursor_agent_fix_log_service.dart';
import 'cursor_agent_snapshot_service.dart';
import 'crash_journal_service.dart';
import 'local_database.dart';
import 'mac_system_block_service.dart';
import 'network_url_block_service.dart';
import 'usage_quota_enforcer_service.dart';
import 'windows_system_block_service.dart';

/// Boot-time fix: **youtube.com must stay reachable** when the user only blocks
/// channels/videos (PAC + URLBlocklist), not the whole site via hosts DNS.
///
/// Why this exists:
/// Older or external hosts rules can accidentally sinkhole youtube.com even
/// when the user only asked to block specific channels/videos. This check keeps
/// YouTube reachable in that split mode, but automatic repair must not launch
/// UAC; it only records that admin repair is needed.
final class YoutubeHostsAutofixService {
  YoutubeHostsAutofixService._();
  static final YoutubeHostsAutofixService instance =
      YoutubeHostsAutofixService._();

  bool _running = false;

  String get reportPath => p.join(
    CrashJournalService.instance.debugFolderPath,
    'youtube_hosts_autofix_last.json',
  );

  Future<YoutubeHostsAutofixReport> runAutofix({
    required String reason,
    bool forceHostsApply = false,
  }) async {
    if (!Platform.isWindows) {
      return YoutubeHostsAutofixReport.skipped('Windows ì „ìš©');
    }
    if (_running) {
      return YoutubeHostsAutofixReport.skipped(
        'ì´ì „ YouTube hosts ë³µêµ¬ ì‹¤í–‰ ì¤‘',
      );
    }
    _running = true;
    final List<String> steps = <String>[];
    try {
      final YoutubeDnsProbe before = await _probeDns();
      final bool hostsApex = await _hostsBlocksYoutubeApex();
      final bool explicit = await _userExplicitlyBlocksYoutubeSite();
      steps.add('probe_dns=${before.sinkholed}');
      steps.add('hosts_apex=$hostsApex');
      steps.add('explicit_yt_block=$explicit');

      if (!before.sinkholed && !hostsApex) {
        final YoutubeHostsAutofixReport ok = YoutubeHostsAutofixReport(
          at: DateTime.now(),
          reason: reason,
          ok: true,
          verdict: 'YouTube DNS ì •ìƒ â€” hosts apex ì°¨ë‹¨ ì—†ìŒ',
          before: before,
          after: before,
          steps: steps,
        );
        await _persist(ok);
        await _logFix(ok, skipped: true);
        return ok;
      }

      // @incident: project_youtube_block_pipeline — don't auto-heal YouTube
      // DNS/hosts entries if the user deliberately blocked the whole site;
      // auto-repair previously fought the user's own site-level block.
      if (explicit) {
        final YoutubeHostsAutofixReport intentional = YoutubeHostsAutofixReport(
          at: DateTime.now(),
          reason: reason,
          ok: true,
          verdict:
              'ì˜ë„ì  YouTube ì „ì²´ ì°¨ë‹¨(ë„ë©”ì¸ ê·œì¹™Â·ì´ìš©í•œë„) â€” ìžë™ ë³µêµ¬ ì•ˆ í•¨',
          before: before,
          after: before,
          steps: steps,
        );
        await _persist(intentional);
        await _logFix(intentional, skipped: true);
        return intentional;
      }

      // PAC/URLBlocklist â€” no UAC; refresh channel/video rules first.
      await NetworkUrlBlockService.instance.enforceNow(
        reason: 'youtube_hosts_autofix',
      );
      steps.add('pac_urlblocklist_refresh');

      // Regenerate managed hosts (v235+ excludes youtube.com apex unless explicit).
      steps.add('hosts_apply_start');
      await _persist(
        YoutubeHostsAutofixReport(
          at: DateTime.now(),
          reason: reason,
          ok: false,
          verdict:
              'YouTube DNS ë³µêµ¬ â€” ì ìš© ì°½ì—ì„œ UAC ã€Œì˜ˆã€ë¥¼ ëˆŒëŸ¬ ì£¼ì„¸ìš”',
          before: before,
          after: before,
          steps: List<String>.from(steps),
        ),
      );
      final MacBlockResult apply =
          await AutonomousApplyUacPromptService.instance
              .promptForYoutubeDnsRepair(reason: reason) ??
          MacBlockResult.failure(
            'Admin repair needed - automatic UAC suppressed',
          );
      final bool applyOk = apply.status == MacBlockStatus.success;
      steps.add(
        applyOk ? 'hosts_apply_ok' : 'hosts_apply_fail:${apply.status.name}',
      );

      if (applyOk) {
        steps.add('hosts_regenerated');
      }

      await Future<void>.delayed(const Duration(seconds: 2));
      final YoutubeDnsProbe after = await _probeDns();
      steps.add('probe_after=${after.sinkholed}');

      final bool fixed = !after.sinkholed;
      final String verdict = fixed
          ? 'YouTube DNS ë³µêµ¬ë¨ â€” ì±„ë„/ì˜ìƒë§Œ PACÂ·URLBlocklistë¡œ ì°¨ë‹¨'
          : applyOk
          ? 'hosts ìž¬ì ìš©í–ˆìœ¼ë‚˜ YouTube DNS ì—¬ì „ížˆ sinkhole â€” DNS ìºì‹œÂ·hosts ìˆ˜ë™ í™•ì¸'
          : apply.status == MacBlockStatus.cancelled
          ? 'UAC ì·¨ì†Œë¨ â€” YouTube ì—´ë¦¬ë ¤ë©´ hosts ì ìš© ì‹œ ã€Œì˜ˆã€ í•„ìš” (ì„¤ì •â†’ì‹œìŠ¤í…œ ì°¨ë‹¨ ì ìš©)'
          : 'hosts ìž¬ì ìš© ì‹¤íŒ¨(${apply.message ?? apply.status.name}) â€” UAC ã€Œì˜ˆã€ í•„ìš”';

      final YoutubeHostsAutofixReport report = YoutubeHostsAutofixReport(
        at: DateTime.now(),
        reason: reason,
        ok: fixed,
        verdict: verdict,
        before: before,
        after: after,
        steps: steps,
        applyStatus: apply.status.name,
        applyMessage: apply.message,
      );
      await _persist(report);
      await _logFix(report, skipped: false);

      unawaited(
        CursorAgentSnapshotService.instance.refresh(
          reason: 'youtube_hosts_autofix',
          light: true,
        ),
      );

      BlockActivityLogService.instance.record(
        kind: BlockActivityKind.hostsApply,
        message: verdict,
        data: report.toJson(),
        level: fixed ? 'info' : 'warn',
        debounceKey: 'youtube_hosts_autofix',
      );

      return report;
    } catch (e, st) {
      AppLogger.instance.error(
        'youtube_hosts_autofix failed',
        error: e,
        stack: st,
      );
      final YoutubeHostsAutofixReport fail = YoutubeHostsAutofixReport(
        at: DateTime.now(),
        reason: reason,
        ok: false,
        verdict: 'YouTube hosts ìžë™ ë³µêµ¬ ì˜¤ë¥˜: $e',
        before: const YoutubeDnsProbe(sinkholed: true),
        after: const YoutubeDnsProbe(sinkholed: true),
        steps: steps,
      );
      await _persist(fail);
      await _logFix(fail, skipped: false);
      return fail;
    } finally {
      _running = false;
    }
  }

  Future<void> _logFix(
    YoutubeHostsAutofixReport report, {
    required bool skipped,
  }) async {
    final List<String> failed = <String>[];
    final List<String> applied = <String>[];
    if (report.before.sinkholed) failed.add('dns:youtube.comâ†’0.0.0.0');
    if (!report.ok && report.after.sinkholed) {
      failed.add('dns:youtube.com_still_sinkholed');
    }
    if (report.steps.contains('hosts_apply_ok')) {
      applied.add('hosts_regenerate');
    }
    if (report.steps.contains('pac_urlblocklist_refresh')) {
      applied.add('pac+urlblocklist');
    }

    await CursorAgentFixLogService.instance.record(
      CursorAgentFixEntry(
        component: 'youtube_hosts_autofix',
        action: skipped ? 'probe_only' : 'repair_hosts',
        ok: report.ok,
        verdict: report.verdict,
        reason: report.reason,
        details: report.toJson(),
        failedLayers: failed,
        appliedLayers: applied,
        fixesAttempted: report.steps,
      ),
    );
  }

  Future<void> _persist(YoutubeHostsAutofixReport report) async {
    try {
      await CrashJournalService.instance.warmup();
      await File(reportPath).writeAsString(report.toJsonString(), flush: true);
    } catch (_) {}
  }

  Future<YoutubeDnsProbe> _probeDns() async {
    try {
      final List<InternetAddress> addrs = await InternetAddress.lookup(
        'www.youtube.com',
      );
      final String? ip = addrs.isNotEmpty ? addrs.first.address : null;
      final bool sinkholed =
          ip == '0.0.0.0' ||
          ip == '::' ||
          ip == '127.0.0.1' ||
          (ip != null && ip.startsWith('0.'));
      return YoutubeDnsProbe(
        sinkholed: sinkholed,
        resolvedIp: ip,
        host: 'www.youtube.com',
      );
    } catch (e) {
      return YoutubeDnsProbe(
        sinkholed: true,
        resolvedIp: null,
        host: 'www.youtube.com',
        error: '$e',
      );
    }
  }

  Future<bool> _hostsBlocksYoutubeApex() async {
    final String? all =
        await WindowsSystemBlockService.tryReadSystemHostsNormalized();
    if (all == null) return false;
    const String start = MacSystemBlockService.kMarkerStart;
    const String end = MacSystemBlockService.kMarkerEnd;
    final int i = all.indexOf(start);
    final int j = all.indexOf(end);
    if (i < 0 || j <= i) return false;
    final String region = all.substring(i, j).toLowerCase();
    return region.contains('0.0.0.0 youtube.com') ||
        region.contains('0.0.0.0 www.youtube.com');
  }

  Future<bool> _userExplicitlyBlocksYoutubeSite() async {
    final DateTime now = DateTime.now();
    final List<Map<String, Object?>> doms = await LocalDatabase.instance
        .domainsActiveNow(now);
    for (final Map<String, Object?> row in doms) {
      if ((row['enabled'] as int? ?? 0) != 1) continue;
      final String host = MacSystemBlockService.canonicalHost(
        row['host'] as String? ?? '',
      );
      if (host == 'youtube.com' || host == 'youtu.be') return true;
    }
    for (final String h in UsageQuotaEnforcerService.instance.lockedHosts) {
      if (h.contains('youtube') || h.contains('youtu.be')) return true;
    }
    return false;
  }
}

final class YoutubeDnsProbe {
  const YoutubeDnsProbe({
    required this.sinkholed,
    this.resolvedIp,
    this.host = 'www.youtube.com',
    this.error,
  });

  final bool sinkholed;
  final String? resolvedIp;
  final String host;
  final String? error;

  Map<String, Object?> toJson() => <String, Object?>{
    'host': host,
    'sinkholed': sinkholed,
    'resolvedIp': resolvedIp,
    if (error != null) 'error': error,
  };
}

final class YoutubeHostsAutofixReport {
  YoutubeHostsAutofixReport({
    required this.at,
    required this.reason,
    required this.ok,
    required this.verdict,
    required this.before,
    required this.after,
    this.steps = const <String>[],
    this.applyStatus,
    this.applyMessage,
  });

  factory YoutubeHostsAutofixReport.skipped(String msg) =>
      YoutubeHostsAutofixReport(
        at: DateTime.now(),
        reason: 'skip',
        ok: true,
        verdict: msg,
        before: const YoutubeDnsProbe(sinkholed: false),
        after: const YoutubeDnsProbe(sinkholed: false),
      );

  final DateTime at;
  final String reason;
  final bool ok;
  final String verdict;
  final YoutubeDnsProbe before;
  final YoutubeDnsProbe after;
  final List<String> steps;
  final String? applyStatus;
  final String? applyMessage;

  Map<String, Object?> toJson() => <String, Object?>{
    'at': at.toIso8601String(),
    'reason': reason,
    'ok': ok,
    'verdict': verdict,
    'before': before.toJson(),
    'after': after.toJson(),
    'steps': steps,
    if (applyStatus != null) 'applyStatus': applyStatus,
    if (applyMessage != null) 'applyMessage': applyMessage,
  };

  String toJsonString() => const JsonEncoder.withIndent('  ').convert(toJson());
}
