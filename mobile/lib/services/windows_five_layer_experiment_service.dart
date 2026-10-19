import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'blocker_test_service.dart';
import 'extension_rules_builder.dart';
import 'usage_ingest_server.dart';
import 'windows_emergency_block_service.dart';
import 'windows_firewall_block_service.dart';
import 'windows_five_layer_block_service.dart';
import 'windows_hidden_process.dart';
import 'windows_system_block_service.dart';
import 'windows_window_title_guard_service.dart';

/// One probe result for a single blocking layer.
final class LayerProbe {
  const LayerProbe({
    required this.layer,
    required this.name,
    required this.ok,
    required this.detail,
    this.fixHint,
  });

  final int layer;
  final String name;
  final bool ok;
  final String detail;
  final String? fixHint;

  Map<String, Object?> toJson() => <String, Object?>{
        'layer': layer,
        'name': name,
        'ok': ok,
        'detail': detail,
        if (fixHint != null) 'fixHint': fixHint,
      };
}

/// Full 5-layer experiment report (saved to disk for agents).
final class FiveLayerExperimentReport {
  const FiveLayerExperimentReport({
    required this.probes,
    required this.status,
    required this.at,
    this.youtubeApiSample,
  });

  final List<LayerProbe> probes;
  final FiveLayerStatus status;
  final DateTime at;
  final Map<String, Object?>? youtubeApiSample;

  int get passCount => probes.where((LayerProbe p) => p.ok).length;

  Map<String, Object?> toJson() => <String, Object?>{
        'at': at.toIso8601String(),
        'passCount': passCount,
        'total': probes.length,
        'status': <String, Object?>{
          'layer1Hosts': status.layer1Hosts,
          'layer2Extension': status.layer2Extension,
          'layer3PacProxy': status.layer3PacProxy,
          'layer4WindowTitle': status.layer4WindowTitle,
          'layer5Firewall': status.layer5Firewall,
          'firewallRuleCount': status.firewallRuleCount,
          'windowGuardPatterns': status.windowGuardPatterns,
        },
        'probes': probes.map((LayerProbe p) => p.toJson()).toList(),
        if (youtubeApiSample != null) 'youtubeApiSample': youtubeApiSample,
      };
}

/// Runs read-only + light-write probes for all 5 Windows blocking layers.
final class WindowsFiveLayerExperimentService {
  WindowsFiveLayerExperimentService._();
  static final WindowsFiveLayerExperimentService instance =
      WindowsFiveLayerExperimentService._();

  FiveLayerExperimentReport? _lastReport;

  FiveLayerExperimentReport? get lastReport => _lastReport;

  static String reportPath() {
    final String? la = Platform.environment['LOCALAPPDATA'];
    return p.join(la ?? '', 'SixVPNBlocker', 'five_layer_experiment.json');
  }

  /// Sync layers then probe each one. [applyFirst] runs full sync (manual).
  Future<FiveLayerExperimentReport> run({
    bool applyFirst = true,
    String reason = 'experiment',
  }) async {
    if (!Platform.isWindows) {
      const FiveLayerStatus st = FiveLayerStatus(
        layer1Hosts: false,
        layer2Extension: false,
        layer3PacProxy: false,
        layer4WindowTitle: false,
        layer5Firewall: false,
        message: 'Windows 전용',
      );
      return FiveLayerExperimentReport(
        probes: const <LayerProbe>[],
        status: st,
        at: DateTime.now(),
      );
    }

    if (applyFirst) {
      await WindowsFiveLayerBlockService.instance.syncLayers(
        reason: 'experiment',
      );
      await WindowsFirewallBlockService.instance.prepareStateOnly();
      await WindowsFirewallBlockService.instance.syncFromHosts(force: true);
    }

    final FiveLayerStatus status =
        WindowsFiveLayerBlockService.instance.lastStatus ??
            await WindowsFiveLayerBlockService.instance.syncLayers(
              reason: reason,
            );

    final ExtensionRulesPayload rules =
        await ExtensionRulesBuilder.buildForBrowserEnforcement();
    final List<LayerProbe> probes = <LayerProbe>[
      await _probeHosts(rules),
      await _probeExtension(rules),
      await _probePac(rules),
      await _probeWindowTitle(),
      await _probeFirewall(),
    ];

    Map<String, Object?>? ytSample;
    if (rules.blockedYoutubeVideoIds.isNotEmpty) {
      ytSample = await _probeYoutubeApi(rules.blockedYoutubeVideoIds.first);
    } else if (rules.blockedYoutubeHandles.isNotEmpty) {
      final String h = rules.blockedYoutubeHandles.first;
      ytSample = await _probeYoutubeChannelApi('/@$h');
    }

    final FiveLayerExperimentReport report = FiveLayerExperimentReport(
      probes: probes,
      status: status,
      at: DateTime.now(),
      youtubeApiSample: ytSample,
    );
    _lastReport = report;
    await _persist(report);
    AppLogger.instance.info(
      'five_layer_experiment: ${report.passCount}/${probes.length} pass',
    );
    return report;
  }

  Future<LayerProbe> _probeHosts(ExtensionRulesPayload rules) async {
    final bool marker = await WindowsSystemBlockService.instance.isActive();
    String dnsDetail = '마커 없음';
    bool dnsOk = false;
    if (rules.blockedDomains.isNotEmpty) {
      final String host = rules.blockedDomains.first
          .replaceAll(RegExp(r'^www\.'), '');
      final BrowserTestResult sys =
          await BlockerTestService.instance.systemResolverTest(<String>[host]);
      dnsOk = sys.passed;
      dnsDetail = sys.summary;
    } else if (marker) {
      dnsOk = true;
      dnsDetail = 'hosts 마커만 확인 (도메인 규칙 없음)';
    }
    final bool ok = marker && (rules.blockedDomains.isEmpty || dnsOk);
    return LayerProbe(
      layer: 1,
      name: 'OS hosts (DNS)',
      ok: ok,
      detail: marker ? '마커 OK · $dnsDetail' : 'hosts 미적용',
      fixHint: ok ? null : '진단 → 「지금 적용」UAC 승인',
    );
  }

  Future<LayerProbe> _probeExtension(ExtensionRulesPayload rules) async {
    final int port = UsageIngestServer.instance.boundPort;
    final bool apiUp = UsageIngestServer.instance.isRunning;
    int ytHandles = 0;
    int ytVideos = 0;
    if (apiUp) {
      try {
        final HttpClient client = HttpClient();
        client.connectionTimeout = const Duration(seconds: 3);
        final HttpClientRequest req = await client.get(
          '127.0.0.1',
          port,
          '/rules',
        );
        final HttpClientResponse res = await req.close();
        if (res.statusCode == 200) {
          final String body = await res.transform(utf8.decoder).join();
          final dynamic data = jsonDecode(body);
          if (data is Map) {
            ytHandles = (data['blockedYoutubeHandles'] as List?)?.length ?? 0;
            ytVideos = (data['blockedYoutubeVideoIds'] as List?)?.length ?? 0;
          }
        }
        client.close(force: true);
      } catch (_) {}
    }
    final bool hasRules = rules.hasYoutubeChannelBlocks ||
        rules.blockedYoutubeVideoIds.isNotEmpty ||
        rules.keywords.isNotEmpty;
    final bool ok = apiUp && (!hasRules || ytHandles > 0 || ytVideos > 0);
    return LayerProbe(
      layer: 2,
      name: '브라우저 확장 (DOM/DNR)',
      ok: ok || !hasRules,
      detail: apiUp
          ? 'API :$port · 핸들 $ytHandles · 영상 $ytVideos'
          : '규칙 API 꺼짐',
      fixHint: apiUp ? null : '앱 재실행 · 보호 Chrome 열기',
    );
  }

  Future<LayerProbe> _probePac(ExtensionRulesPayload rules) async {
    final EmergencyBlockResult pac =
        await WindowsEmergencyBlockService.instance.readStatus();
    bool fileOk = false;
    int proxyLines = 0;
    final String? pacFile = pac.pacPath ?? WindowsEmergencyBlockService.pacPath();
    if (pacFile != null && await File(pacFile).exists()) {
      final String content = await File(pacFile).readAsString();
      fileOk = content.contains('PROXY 127.0.0.1:9');
      proxyLines = 'PROXY 127.0.0.1:9'.allMatches(content).length;
    }
    final bool hasYt = rules.hasYoutubeChannelBlocks ||
        rules.blockedYoutubeVideoIds.isNotEmpty;
    final bool ok = pac.pacApplied && fileOk;
    return LayerProbe(
      layer: 3,
      name: '네트워크 PAC (프록시)',
      ok: ok || !hasYt,
      detail: pac.pacApplied
          ? '레지스트리 PAC · 규칙 $proxyLines줄'
          : 'PAC 미등록',
      fixHint: ok ? null : '설정→진단→자동 적용 또는 Chrome 정책 Reload',
    );
  }

  Future<LayerProbe> _probeWindowTitle() async {
    final WindowTitleGuardResult? wt =
        WindowsWindowTitleGuardService.instance.lastResult;
    final int n = wt?.patternCount ?? 0;
    return LayerProbe(
      layer: 4,
      name: '창 제목 감시',
      ok: n > 0,
      detail: n > 0 ? '패턴 $n개 · 5초 주기' : '패턴 없음 (유튜브 규칙 필요)',
      fixHint: n > 0 ? null : '스케줄에 유튜브 채널/영상 추가',
    );
  }

  Future<LayerProbe> _probeFirewall() async {
    final FirewallBlockResult? fw =
        WindowsFirewallBlockService.instance.lastResult;
    int stateRules = 0;
    try {
      final File f = File(p.join(
        Platform.environment['LOCALAPPDATA'] ?? '',
        'SixVPNBlocker',
        'firewall_rules.json',
      ));
      if (await f.exists()) {
        final dynamic raw = jsonDecode(await f.readAsString());
        if (raw is List) stateRules = raw.length;
      }
    } catch (_) {}
    final bool pendingBat = fw?.adminBatPath != null;
    final bool ok =
        (fw?.active ?? false) || stateRules > 0 || pendingBat;
    return LayerProbe(
      layer: 5,
      name: 'Windows 방화벽 (IP)',
      ok: ok,
      detail: fw?.active == true
          ? '규칙 ${fw!.ruleCount}개 (CDN 보조)'
          : pendingBat
              ? 'BAT 준비됨 (관리자 1회) · IP ${stateRules}개'
              : fw?.message ?? '규칙 없음 — hosts/PAC가 주력',
      fixHint: fw?.active == true
          ? null
          : pendingBat
              ? '바탕화면 「firewall 적용 (관리자).bat」 우클릭→관리자'
              : 'hosts/PAC가 주력 — 방화벽은 선택 보조',
    );
  }

  Future<Map<String, Object?>?> _probeYoutubeApi(String videoId) async {
    final int port = UsageIngestServer.instance.boundPort;
    if (!UsageIngestServer.instance.isRunning) return null;
    try {
      final HttpClient client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);
      final HttpClientRequest req = await client.get(
        '127.0.0.1',
        port,
        '/youtube/check?v=${Uri.encodeComponent(videoId)}',
      );
      final HttpClientResponse res = await req.close();
      final String body = await res.transform(utf8.decoder).join();
      client.close(force: true);
      final dynamic data = jsonDecode(body);
      if (data is Map) {
        return <String, Object?>{
          'videoId': videoId,
          'blocked': data['blocked'] == true,
          'matched': data['matched'],
        };
      }
    } catch (_) {}
    return null;
  }

  Future<Map<String, Object?>?> _probeYoutubeChannelApi(String path) async {
    final int port = UsageIngestServer.instance.boundPort;
    if (!UsageIngestServer.instance.isRunning) return null;
    try {
      final HttpClient client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 5);
      final HttpClientRequest req = await client.get(
        '127.0.0.1',
        port,
        '/youtube/channel-check?path=${Uri.encodeComponent(path)}',
      );
      final HttpClientResponse res = await req.close();
      final String body = await res.transform(utf8.decoder).join();
      client.close(force: true);
      final dynamic data = jsonDecode(body);
      if (data is Map) {
        return <String, Object?>{
          'path': path,
          'blocked': data['blocked'] == true,
          'matched': data['matched'],
        };
      }
    } catch (_) {}
    return null;
  }

  Future<void> _persist(FiveLayerExperimentReport report) async {
    try {
      final File f = File(reportPath());
      await f.parent.create(recursive: true);
      await f.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report.toJson()),
        flush: true,
      );
    } catch (e) {
      AppLogger.instance.warn('five_layer_experiment persist failed', error: e);
    }
  }

  /// Headless netsh rule count (for PS script parity).
  Future<int> countFirewallRulesViaNetsh() async {
    if (!Platform.isWindows) return 0;
    try {
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final ProcessResult pr = await windowsRunHidden(
        p.join(windir, 'System32', 'netsh.exe'),
        <String>[
          'advfirewall',
          'firewall',
          'show',
          'rule',
          'name=all',
        ],
      );
      final String out = '${pr.stdout}${pr.stderr}';
      return 'SixVPN_Block_'.allMatches(out).length;
    } catch (_) {
      return 0;
    }
  }
}
