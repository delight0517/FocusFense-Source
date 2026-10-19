import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'chrome_channel_apply_probe_service.dart';
import 'crash_journal_service.dart';
import 'edge_channel_apply_probe_service.dart';
import 'firefox_channel_apply_probe_service.dart';
import 'hosts_health_probe_service.dart';
import 'mandatory_youtube_block_service.dart';
import 'universal_browser_block_service.dart';
import 'usage_ingest_server.dart';
import 'windows_hidden_process.dart';
import 'youtube_video_block_resolver.dart';

/// Direct disk/registry verification (+227 channel-probe style).
///
/// Reads HKCU URLBlocklist subkeys, rules snapshot, hosts health, and
/// per-browser profile probes — then optionally re-syncs policies.
final class BrowserApplyDirectVerifyService {
  BrowserApplyDirectVerifyService._();
  static final BrowserApplyDirectVerifyService instance =
      BrowserApplyDirectVerifyService._();

  static const List<String> kDefaultVideoIds = <String>[
    'wCrc7vy_Tmk',
    'lDRT5e6JsY4',
    'so-Rv8RlCUc',
  ];
  static const List<String> kDefaultHandles = <String>['winterstarcraft'];

  String get reportPath => p.join(
        CrashJournalService.instance.debugFolderPath,
        'verify_browser_apply_direct.json',
      );

  /// Full verify pass for mandatory + DB targets.
  Future<BrowserApplyDirectReport> verifyAll({
    String reason = 'manual',
  }) async {
    if (!Platform.isWindows) {
      return BrowserApplyDirectReport.skipped('Windows 전용');
    }

    final List<String> videos = List<String>.from(kDefaultVideoIds);
    final List<String> handles = List<String>.from(kDefaultHandles);
    for (final String line in await MandatoryYoutubeBlockService.instance.patterns()) {
      final String? vid = _videoIdFromUrl(line);
      if (vid != null && !videos.contains(vid)) videos.add(vid);
      final String? h = _handleFromUrl(line);
      if (h != null && !handles.contains(h.toLowerCase())) handles.add(h.toLowerCase());
    }

    final List<String> chromeReg = await readUrlBlocklistEntries(
      r'HKCU\SOFTWARE\Policies\Google\Chrome\URLBlocklist',
    );
    final List<String> edgeReg = await readUrlBlocklistEntries(
      r'HKCU\SOFTWARE\Policies\Microsoft\Edge\URLBlocklist',
    );
    final HostsHealthStatus hosts = await HostsHealthProbeService.instance.probe();

    final List<DirectTargetResult> targets = <DirectTargetResult>[];
    for (final String vid in videos) {
      targets.add(await _verifyVideo(vid, chromeReg, edgeReg));
    }
    for (final String handle in handles) {
      targets.add(await _verifyHandle(handle, chromeReg, edgeReg));
    }

    final bool ok = hosts.ok &&
        targets.every((DirectTargetResult t) => t.ok);

    final BrowserApplyDirectReport report = BrowserApplyDirectReport(
      at: DateTime.now(),
      reason: reason,
      ok: ok,
      hosts: hosts,
      chromeBlocklistCount: chromeReg.length,
      edgeBlocklistCount: edgeReg.length,
      targets: targets,
    );
    await _persist(report);
    return report;
  }

  /// Re-sync policies then verify again (no extra UAC unless hosts broken).
  Future<BrowserApplyDirectReport> verifyAndRepair({
    String reason = 'boot_verify',
  }) async {
    BrowserApplyDirectReport first = await verifyAll(reason: '$reason:pre');
    if (first.ok) return first;

    AppLogger.instance.warn(
      'browser_apply_direct: failures=${first.failures.join("; ")} — repairing',
    );

    await UniversalBrowserBlockService.instance.syncNow(reason: reason);

    if (!first.hosts.ok) {
      await HostsHealthProbeService.instance.repairIfNeeded(reason: reason);
    }

    for (final String handle in kDefaultHandles) {
      await ChromeChannelApplyProbeService.instance.repairForHandle(handle);
      await EdgeChannelApplyProbeService.instance.repairForHandle(handle);
      await FirefoxChannelApplyProbeService.instance.repairForHandle(handle);
    }

    final BrowserApplyDirectReport after =
        await verifyAll(reason: '$reason:post');
    AppLogger.instance.info(
      'browser_apply_direct: post-repair ok=${after.ok} '
      'chrome=${after.chromeBlocklistCount} edge=${after.edgeBlocklistCount}',
    );
    return after;
  }

  Future<DirectTargetResult> _verifyVideo(
    String videoId,
    List<String> chromeReg,
    List<String> edgeReg,
  ) async {
    final String low = videoId.toLowerCase();
    final bool inChrome = chromeReg.any(
      (String p) => p.toLowerCase().contains(low),
    );
    final bool inEdge = edgeReg.any(
      (String p) => p.toLowerCase().contains(low),
    );
    bool apiBlocked = false;
    try {
      if (!UsageIngestServer.instance.isRunning) {
        UsageIngestServer.instance.start();
      }
      final YoutubeBlockCheckResult yt =
          await YoutubeVideoBlockResolver.instance.checkVideo(videoId);
      apiBlocked = yt.blocked;
    } catch (_) {}

    final List<String> issues = <String>[];
    if (!inChrome) issues.add('chrome_urlblocklist');
    if (!inEdge) issues.add('edge_urlblocklist');
    if (!apiBlocked) issues.add('rules_api');

    return DirectTargetResult(
      kind: 'video',
      id: videoId,
      ok: inChrome && inEdge && apiBlocked,
      inChromeBlocklist: inChrome,
      inEdgeBlocklist: inEdge,
      apiBlocked: apiBlocked,
      issues: issues,
    );
  }

  Future<DirectTargetResult> _verifyHandle(
    String handle,
    List<String> chromeReg,
    List<String> edgeReg,
  ) async {
    final String h = handle.toLowerCase();
    final bool inChrome = chromeReg.any(
      (String p) => p.toLowerCase().contains('/@$h'),
    );
    final bool inEdge = edgeReg.any(
      (String p) => p.toLowerCase().contains('/@$h'),
    );

    final ChromeChannelApplyReport cr =
        await ChromeChannelApplyProbeService.instance.probeHandle(handle);
    final EdgeChannelApplyReport ed =
        await EdgeChannelApplyProbeService.instance.probeHandle(handle);
    final FirefoxChannelApplyReport ff =
        await FirefoxChannelApplyProbeService.instance.probeHandle(handle);

    final bool chromeOk = inChrome ||
        cr.overall == ChromeChannelApplyOverall.applied ||
        cr.overall == ChromeChannelApplyOverall.partial;
    final bool edgeOk = inEdge ||
        ed.overall == EdgeChannelApplyOverall.applied ||
        ed.overall == EdgeChannelApplyOverall.partial ||
        ed.overall == EdgeChannelApplyOverall.notInstalled;
    final bool ffOk = ff.overall == FirefoxChannelApplyOverall.applied ||
        ff.overall == FirefoxChannelApplyOverall.partial;

    final List<String> issues = <String>[];
    if (!inChrome) issues.add('chrome_urlblocklist');
    if (!inEdge && ed.overall != EdgeChannelApplyOverall.notInstalled) {
      issues.add('edge_urlblocklist');
    }
    if (cr.overall == ChromeChannelApplyOverall.notApplied) {
      issues.add('chrome_channel_probe');
    }
    if (ed.overall == EdgeChannelApplyOverall.notApplied) {
      issues.add('edge_channel_probe');
    }
    if (ff.overall == FirefoxChannelApplyOverall.notApplied) {
      issues.add('firefox_channel_probe');
    }

    return DirectTargetResult(
      kind: 'handle',
      id: handle,
      ok: chromeOk && edgeOk && ffOk,
      inChromeBlocklist: inChrome,
      inEdgeBlocklist: inEdge,
      apiBlocked: false,
      issues: issues,
      chromeProbe: cr.overall.name,
      edgeProbe: ed.overall.name,
      firefoxProbe: ff.overall.name,
    );
  }

  static Future<List<String>> readUrlBlocklistEntries(String key) async {
    if (!Platform.isWindows) return <String>[];
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final String reg = p.join(windir, 'System32', 'reg.exe');
    try {
      final ProcessResult r = await windowsRunHidden(
        reg,
        <String>['query', key, '/s'],
      );
      if (r.exitCode != 0) return <String>[];
      final List<String> out = <String>[];
      for (final String line in '${r.stdout}'.split('\n')) {
        if (!line.contains('REG_SZ')) continue;
        if (line.contains('(Default)')) continue;
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

  static String? _videoIdFromUrl(String raw) {
    final RegExpMatch? m =
        RegExp(r'[?&]v=([\w-]{6,})', caseSensitive: false).firstMatch(raw);
    return m?.group(1);
  }

  static String? _handleFromUrl(String raw) {
    final RegExpMatch? m =
        RegExp(r'youtube\.com/@([^/?#\s]+)', caseSensitive: false).firstMatch(raw);
    return m?.group(1);
  }

  Future<void> _persist(BrowserApplyDirectReport report) async {
    try {
      final File f = File(reportPath);
      await f.parent.create(recursive: true);
      await f.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report.toJson()),
        flush: true,
      );
      final File local = File(p.join(
        Platform.environment['LOCALAPPDATA'] ?? '',
        'SixVPNBlocker',
        'verify_browser_apply_direct.json',
      ));
      await local.parent.create(recursive: true);
      await local.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report.toJson()),
        flush: true,
      );
    } catch (_) {}
  }
}

final class DirectTargetResult {
  const DirectTargetResult({
    required this.kind,
    required this.id,
    required this.ok,
    required this.inChromeBlocklist,
    required this.inEdgeBlocklist,
    required this.apiBlocked,
    required this.issues,
    this.chromeProbe,
    this.edgeProbe,
    this.firefoxProbe,
  });

  final String kind;
  final String id;
  final bool ok;
  final bool inChromeBlocklist;
  final bool inEdgeBlocklist;
  final bool apiBlocked;
  final List<String> issues;
  final String? chromeProbe;
  final String? edgeProbe;
  final String? firefoxProbe;

  Map<String, Object?> toJson() => <String, Object?>{
        'kind': kind,
        'id': id,
        'ok': ok,
        'inChromeBlocklist': inChromeBlocklist,
        'inEdgeBlocklist': inEdgeBlocklist,
        'apiBlocked': apiBlocked,
        'issues': issues,
        if (chromeProbe != null) 'chromeProbe': chromeProbe,
        if (edgeProbe != null) 'edgeProbe': edgeProbe,
        if (firefoxProbe != null) 'firefoxProbe': firefoxProbe,
      };
}

final class BrowserApplyDirectReport {
  BrowserApplyDirectReport({
    required this.at,
    required this.reason,
    required this.ok,
    required this.hosts,
    required this.chromeBlocklistCount,
    required this.edgeBlocklistCount,
    required this.targets,
  });

  factory BrowserApplyDirectReport.skipped(String message) =>
      BrowserApplyDirectReport(
        at: DateTime.now(),
        reason: message,
        ok: true,
        hosts: const HostsHealthStatus(
          ok: true,
          managedSinkholeLines: 0,
          expectedHostCount: 0,
          hasMarkers: true,
          rescueMergedBytes: 0,
        ),
        chromeBlocklistCount: 0,
        edgeBlocklistCount: 0,
        targets: <DirectTargetResult>[],
      );

  final DateTime at;
  final String reason;
  final bool ok;
  final HostsHealthStatus hosts;
  final int chromeBlocklistCount;
  final int edgeBlocklistCount;
  final List<DirectTargetResult> targets;

  List<String> get failures => targets
      .where((DirectTargetResult t) => !t.ok)
      .map((DirectTargetResult t) => '${t.kind}:${t.id}(${t.issues.join(",")})')
      .toList();

  Map<String, Object?> toJson() => <String, Object?>{
        'at': at.toIso8601String(),
        'reason': reason,
        'ok': ok,
        'hosts': hosts.toJson(),
        'chromeBlocklistCount': chromeBlocklistCount,
        'edgeBlocklistCount': edgeBlocklistCount,
        'failures': failures,
        'targets': targets.map((DirectTargetResult t) => t.toJson()).toList(),
      };
}
