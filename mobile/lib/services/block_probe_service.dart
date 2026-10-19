import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'blocker_test_service.dart';
import 'chrome_dns_probe_service.dart';
import 'local_database.dart';
import 'mac_system_block_service.dart';
import 'usage_ingest_server.dart';
import 'windows_system_block_service.dart';

/// Layered checklist: is this host blocked end-to-end (DB → hosts → DNS → HTTP)?
final class BlockProbeService {
  BlockProbeService._();
  static final BlockProbeService instance = BlockProbeService._();

  Future<SiteBlockProbeReport> probeHost(String rawInput) async {
    final String host = MacSystemBlockService.canonicalHost(
      rawInput.replaceFirst(RegExp(r'^https?://'), '').split('/').first,
    );
    if (host.isEmpty) {
      return SiteBlockProbeReport(
        host: rawInput,
        layers: const <SiteBlockLayer>[],
        verdict: '호스트를 파싱하지 못했습니다.',
        allOk: false,
      );
    }

    final List<SiteBlockLayer> layers = <SiteBlockLayer>[];

    final List<Map<String, Object?>> active =
        await LocalDatabase.instance.domainsActiveNow(DateTime.now());
    final bool inDb = active.any((Map<String, Object?> r) {
      final String? h = r['host'] as String?;
      if (h == null) return false;
      final String c = MacSystemBlockService.canonicalHost(h);
      return c == host || host.endsWith('.$c') || c.endsWith('.$host');
    });
    layers.add(SiteBlockLayer(
      id: 'db',
      title: '앱 규칙 (지금 활성)',
      ok: inDb,
      detail: inDb ? '목록에 있음' : '활성 스케줄/전역 규칙에 없음 — 스케줄 시간·홈 추가 확인',
    ));

    bool hostsMarker = false;
    bool hostsLists = false;
    if (Platform.isMacOS) {
      hostsMarker = await MacSystemBlockService.instance.isActive();
      if (hostsMarker) {
        try {
          final String all = await File('/etc/hosts').readAsString();
          hostsLists = hostsTextContains(all, host);
        } catch (_) {}
      }
    } else if (Platform.isWindows) {
      final String? all =
          await WindowsSystemBlockService.tryReadSystemHostsNormalized();
      if (all != null) {
        hostsMarker = all.contains(MacSystemBlockService.kMarkerStart) &&
            all.contains(MacSystemBlockService.kMarkerEnd);
        hostsLists = hostsMarker && hostsTextContains(all, host);
      }
    }
    layers.add(SiteBlockLayer(
      id: 'hosts_marker',
      title: Platform.isWindows ? 'Windows hosts 마커' : '/etc/hosts 마커',
      ok: hostsMarker,
      detail: hostsMarker
          ? '관리 구간 있음 (UAC 적용됨)'
          : '없음 — 진단에서 「지금 적용」+ UAC 「예」',
    ));
    layers.add(SiteBlockLayer(
      id: 'hosts_line',
      title: 'hosts에 이 도메인',
      ok: hostsLists,
      detail: hostsLists
          ? '$host (또는 www.$host 등) 줄 있음'
          : '줄 없음 — 적용 대기 또는 호스트 철자 확인',
    ));

    final HostProbe dns = await BlockerTestService.instance.systemProbe(host);
    layers.add(SiteBlockLayer(
      id: 'dns',
      title: '시스템 DNS 조회',
      ok: dns.blocked,
      detail: dns.detail,
    ));

    final HostProbe http = await BlockerTestService.instance.httpProbe(host);
    layers.add(SiteBlockLayer(
      id: 'http',
      title: 'HTTP 연결 (curl)',
      ok: http.blocked,
      detail: http.detail,
    ));

    bool snapshotFileOk = false;
    bool snapshotListsHost = false;
    if (Platform.isWindows) {
      try {
        final String snap = p.join(
          Platform.environment['LOCALAPPDATA'] ?? '',
          'SixVPNBlocker',
          'chrome_blocker',
          'rules_snapshot.json',
        );
        final File f = File(snap);
        if (await f.exists()) {
          final Object? decoded = jsonDecode(await f.readAsString());
          if (decoded is Map<String, dynamic>) {
            snapshotFileOk = true;
            final List<dynamic>? doms = decoded['blockedDomains'] as List<dynamic>?;
            if (doms != null) {
              snapshotListsHost = doms.any((dynamic d) {
                final String h = MacSystemBlockService.canonicalHost('$d');
                return h == host || host.endsWith('.$h');
              });
            }
          }
        }
      } catch (_) {}
    }
    layers.add(SiteBlockLayer(
      id: 'chrome_snapshot',
      title: 'Chrome 규칙 파일 (오프라인)',
      ok: snapshotFileOk && snapshotListsHost,
      detail: snapshotFileOk
          ? (snapshotListsHost
              ? '$host 가 rules_snapshot.json 에 있음'
              : '스냅샷 있으나 이 도메인 없음')
          : '없음 — 앱이 자동 생성 시도 중',
    ));

    bool extensionApiOk = false;
    bool extensionListsHost = false;
    String extensionDetail = '앱이 꺼져 있거나 확장 미연동';
    if (UsageIngestServer.instance.isRunning) {
      try {
        final HttpClient client = HttpClient();
        final int port = UsageIngestServer.instance.boundPort;
        final HttpClientRequest req = await client.get(
          '127.0.0.1',
          port,
          '/rules',
        );
        final HttpClientResponse res = await req.close().timeout(
          const Duration(seconds: 2),
        );
        if (res.statusCode == 200) {
          final String body = await utf8.decoder.bind(res).join();
          final Object? decoded = jsonDecode(body);
          if (decoded is Map<String, dynamic>) {
            extensionApiOk = true;
            final List<dynamic>? doms = decoded['blockedDomains'] as List<dynamic>?;
            if (doms != null) {
              extensionListsHost = doms.any((dynamic d) {
                final String h = MacSystemBlockService.canonicalHost('$d');
                return h == host || host.endsWith('.$h');
              });
            }
            extensionDetail = extensionListsHost
                ? '확장 API에 $host 포함 (${doms?.length ?? 0}개 도메인)'
                : 'API 동작 중이나 목록에 $host 없음 — 홈에서 도메인 추가';
          }
        }
        client.close(force: true);
      } catch (e) {
        extensionDetail = 'API 조회 실패: $e';
      }
    }
    layers.add(SiteBlockLayer(
      id: 'extension_api',
      title: 'Chrome/Edge 확장 API',
      ok: extensionApiOk && extensionListsHost,
      detail: extensionDetail,
    ));

    final List<BrowserDnsProfileStatus> browsers =
        await ChromeDnsProbeService.instance.probeInstalledBrowsers();
    final List<BrowserDnsProfileStatus> risky =
        browsers.where((BrowserDnsProfileStatus b) => b.secureDnsLikelyOn).toList();
    layers.add(SiteBlockLayer(
      id: 'chrome_doh',
      title: 'Chrome / Edge 보안 DNS',
      ok: risky.isEmpty,
      detail: risky.isEmpty
          ? (browsers.isEmpty
              ? '브라우저 프로필 없음'
              : browsers.map((BrowserDnsProfileStatus b) => '${b.browser}: ${b.detail}').join(' · '))
          : '${risky.map((BrowserDnsProfileStatus b) => b.browser).join(", ")} — 보안 DNS 켜짐 → hosts 무시 가능',
    ));

    final bool allOk = layers.every((SiteBlockLayer l) => l.ok);
    String verdict;
    if (allOk) {
      verdict = '✅ $host — 시스템·HTTP 기준 차단됨. Chrome에서도 안 열리면 캐시/시크릿 탭을 닫고 다시 시도하세요.';
    } else if (!hostsMarker) {
      verdict = '❌ hosts 파일이 아직 적용되지 않았습니다. UAC 「예」가 필요합니다.';
    } else if (!dns.blocked) {
      verdict = '❌ DNS가 여전히 실제 IP를 돌려줍니다. ipconfig /flushdns 후 「지금 적용」을 다시 하세요.';
    } else if (!extensionApiOk || !extensionListsHost) {
      verdict =
          '⚠️ Chrome/Edge는 **브라우저 확장**이 필요합니다. 브라우저 확장 화면에서 Chrome 폴더를 다시보내고 '
          '「압축 해제된 확장 프로그램으로 로드」하세요. 앱이 켜져 있어야 실시간 목록이 갱신됩니다.';
    } else if (risky.isNotEmpty) {
      verdict =
          '⚠️ OS DNS는 막히지만 Chrome「보안 DNS」가 켜져 있으면 사이트가 열릴 수 있습니다. 아래 버튼으로 설정을 여세요.';
    } else if (!inDb) {
      verdict = '⚠️ hosts는 있지만 이 도메인이 지금 활성 규칙에 없습니다. 홈/스케줄에 추가하세요.';
    } else {
      verdict = '⚠️ 일부 단계 실패 — 아래 빨간 항목을 순서대로 해결하세요.';
    }

    return SiteBlockProbeReport(
      host: host,
      layers: layers,
      verdict: verdict,
      allOk: allOk,
      chromeBypass: risky.isNotEmpty,
    );
  }

  static bool hostsTextContains(String hostsText, String host) {
    final String h = host.toLowerCase();
    final RegExp line = RegExp(
      r'^\s*(?:0\.0\.0\.0|::|127\.0\.0\.1)\s+(\S+)',
      multiLine: true,
    );
    for (final RegExpMatch m in line.allMatches(hostsText.toLowerCase())) {
      final String listed = m.group(1) ?? '';
      if (listed == h || listed == 'www.$h' || listed.endsWith('.$h')) {
        return true;
      }
    }
    return hostsText.toLowerCase().contains(' $h') ||
        hostsText.toLowerCase().contains(' www.$h');
  }
}

class SiteBlockProbeReport {
  const SiteBlockProbeReport({
    required this.host,
    required this.layers,
    required this.verdict,
    required this.allOk,
    this.chromeBypass = false,
  });

  final String host;
  final List<SiteBlockLayer> layers;
  final String verdict;
  final bool allOk;
  final bool chromeBypass;
}

class SiteBlockLayer {
  const SiteBlockLayer({
    required this.id,
    required this.title,
    required this.ok,
    required this.detail,
  });

  final String id;
  final String title;
  final bool ok;
  final String detail;
}
