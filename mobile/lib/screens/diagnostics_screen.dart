import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/apply_activation_report.dart';
import '../services/app_logger.dart';
import '../services/app_operation_progress_service.dart';
import '../services/build_identity_service.dart';
import '../services/block_probe_service.dart';
import '../services/blocker_test_service.dart';
import '../services/extension_rules_builder.dart';
import '../services/windows_apply_status_service.dart';
import '../services/chrome_dns_probe_service.dart';
import '../services/firefox_config_service.dart';
import '../services/local_database.dart';
import '../services/mac_system_block_service.dart';
import '../services/recent_site_events.dart';
import '../services/usage_ingest_server.dart';
import '../services/system_log_service.dart';
import '../services/windows_five_layer_experiment_service.dart';
import '../services/windows_five_layer_uac_service.dart';
import '../services/windows_system_block_service.dart';
import '../theme/app_colors.dart';
import '../widgets/apply_activation_dialog.dart';
import '../widgets/cursor_one_tap_diagnostic_card.dart';
import '../widgets/lag_diagnostic_card.dart';
import '../widgets/block_activity_live_panel.dart';
import '../widgets/blocking_pipeline_game_panel.dart';
import '../widgets/blocking_self_heal_card.dart';
import '../widgets/notification_history_panel.dart';
import '../widgets/youtube_proactive_guard_card.dart';
import 'diagnostic_agent_screen.dart';
import 'vpn_bypass_diagnostic_screen.dart';

/// In-app diagnostics. On **macOS** this reads `/etc/hosts`, Firefox DoH,
/// and runs `dscacheutil` probes. On **Windows** it reads
/// `%WINDIR%\System32\drivers\etc\hosts` for the same marker block and uses
/// `InternetAddress.lookup` for DNS smoke tests. The "지금 적용" hosts action
/// uses the platform-specific system block service (admin on Mac, UAC on Windows).
class DiagnosticsScreen extends StatefulWidget {
  const DiagnosticsScreen({super.key});

  @override
  State<DiagnosticsScreen> createState() => _DiagnosticsScreenState();
}

class _DiagnosticsScreenState extends State<DiagnosticsScreen> {
  bool _loading = true;
  String _hostsBlock = '';
  bool _hostsActive = false;
  List<FirefoxProfileStatus> _firefoxProfiles = <FirefoxProfileStatus>[];
  bool _firefoxPolicyInstalled = false;
  List<Map<String, Object?>> _activeNowDomains = <Map<String, Object?>>[];
  String _logSnippet = '';
  String? _logPath;
  BlockerTestReport? _autoReport;
  bool _autoTesting = false;
  FiveLayerExperimentReport? _fiveLayerReport;
  bool _fiveLayerRunning = false;
  bool _fiveLayerUacRunning = false;
  String? _fiveLayerUacMessage;
  String _systemLog = '';
  bool _loadingSystemLog = false;
  bool _hasErrors = false;
  final List<_DnsTest> _dnsTests = <_DnsTest>[];
  BuildIdentity? _identity;
  bool _hostsBlockExpanded = false;
  SiteBlockProbeReport? _siteProbe;
  bool _siteProbing = false;
  final TextEditingController _probeCtrl =
      TextEditingController(text: kDiagnosticBlockSentinelHost);

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _probeCtrl.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    setState(() => _loading = true);
    final String progressId = AppOperationProgressService.instance.begin(
      title: '진단 화면 새로고침',
      step: 'hosts·Firefox·DNS 읽는 중',
      fraction: 0.1,
      estimatedTotal: const Duration(seconds: 25),
      id: 'diagnostics_refresh',
    );
    try {
    bool hostsActive = false;
    String block = '';
    if (Platform.isMacOS) {
      hostsActive = await MacSystemBlockService.instance.isActive();
      try {
        final String all = await File('/etc/hosts').readAsString();
        const String start = MacSystemBlockService.kMarkerStart;
        const String end = MacSystemBlockService.kMarkerEnd;
        final int s = all.indexOf(start);
        final int e = all.indexOf(end);
        if (s >= 0 && e > s) {
          block = all.substring(s, e + end.length);
        }
      } catch (_) {}
    } else if (Platform.isWindows) {
      try {
        final String? all =
            await WindowsSystemBlockService.tryReadSystemHostsNormalized();
        if (all != null) {
          const String start = MacSystemBlockService.kMarkerStart;
          const String end = MacSystemBlockService.kMarkerEnd;
          hostsActive = all.contains(start) && all.contains(end);
          final int s = all.indexOf(start);
          final int e = all.indexOf(end);
          if (s >= 0 && e > s) {
            block = all.substring(s, e + end.length);
          }
        }
      } catch (_) {}
    }

    final List<FirefoxProfileStatus> profiles =
        await FirefoxConfigService.instance.probeProfiles();
    final bool policy =
        FirefoxConfigService.instance.systemPolicyInstalled;
    final List<Map<String, Object?>> domains =
        await LocalDatabase.instance.domainsActiveNow(DateTime.now());

    // Run a couple of canned DNS checks so the user can see whether the
    // resolver is honouring our block. We check both bare and www. forms.
    final List<_DnsTest> tests = <_DnsTest>[];
    for (final String h in <String>[
      'www.naver.com',
      'naver.com',
      kDiagnosticBlockSentinelHost,
    ]) {
      tests.add(await _probe(h));
    }

    AppOperationProgressService.instance.update(
      progressId,
      step: '로그·빌드 정보 수집',
      fraction: 0.75,
    );
    final String logSnippet = await AppLogger.instance.readRecent();
    final String? logPath = await AppLogger.instance.filePath();
    final bool hasErrors = logSnippet.contains('[ERROR]') || logSnippet.contains('FlutterError');
    final BuildIdentity identity = await BuildIdentityService.instance.current();

    if (!mounted) return;
    setState(() {
      _loading = false;
      _identity = identity;
      _hostsActive = hostsActive;
      _hostsBlock = block;
      _firefoxProfiles = profiles;
      _firefoxPolicyInstalled = policy;
      _activeNowDomains = domains;
      _logSnippet = logSnippet;
      _logPath = logPath;
      _hasErrors = hasErrors;
      _dnsTests
        ..clear()
        ..addAll(tests);
    });
    } finally {
      AppOperationProgressService.instance.end(progressId);
    }
  }

  Future<_DnsTest> _probe(String host) async {
    if (Platform.isMacOS) {
      try {
        final ProcessResult r = await Process.run(
          'dscacheutil',
          <String>['-q', 'host', '-a', 'name', host],
        );
        final String out = (r.stdout as String? ?? '');
        final bool blocked = out.contains('0.0.0.0') ||
            out.contains('ip_address: 0.0.0.0');
        final bool safeSearch = out.contains('216.239.38.120');
        final List<String> ips = RegExp(r'ip_address:\s*([0-9a-fA-F.:]+)')
            .allMatches(out)
            .map((Match m) => m.group(1)!)
            .toList();
        final String summary = ips.isEmpty
            ? '응답 없음 (차단되었거나 미해결)'
            : ips.take(3).join(', ');
        return _DnsTest(
          host: host,
          status: summary,
          blocked: blocked,
          safeSearch: safeSearch,
        );
      } catch (e) {
        return _DnsTest(host: host, status: '오류: $e', blocked: false);
      }
    }
    if (Platform.isWindows) {
      try {
        final List<InternetAddress> list =
            await InternetAddress.lookup(host);
        final List<String> ips =
            list.map((InternetAddress a) => a.address).toList();
        final String summary =
            ips.isEmpty ? '응답 없음' : ips.take(4).join(', ');
        final bool blocked = ips.any(
          (String a) => a == '0.0.0.0' || a == '127.0.0.1' || a == '::',
        );
        return _DnsTest(
          host: host,
          status: summary,
          blocked: blocked,
        );
      } catch (e) {
        return _DnsTest(
          host: host,
          status: '조회 실패: $e',
          blocked: false,
        );
      }
    }
    return _DnsTest(host: host, status: '이 OS에서는 DNS 프로브 미구현', blocked: false);
  }

  Future<void> _installFirefoxConfig() async {
    final List<String> profiles =
        await FirefoxConfigService.instance.disableDoHInAllProfiles();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(profiles.isEmpty
            ? 'Firefox 프로필을 찾지 못했어요'
            : '${profiles.length}개 프로필에 DoH 비활성화 설정 적용됨 — Firefox 재시작 필요'),
      ),
    );
    await _refresh();
  }

  Future<void> _runApply() async {
    if (!Platform.isMacOS && !Platform.isWindows) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('이 화면의 즉시 hosts 적용은 macOS·Windows 데스크톱에서만 사용할 수 있습니다.'),
        ),
      );
      return;
    }
    final String verifyHost = MacSystemBlockService.canonicalHost(
      _probeCtrl.text.trim().isEmpty ? 'www.naver.com' : _probeCtrl.text,
    );
    if (Platform.isWindows) {
      await showApplyActivationDialog(
        context,
        runApply: (onPhase) => WindowsApplyStatusService.instance.applyAndVerify(
          verifyHost: verifyHost.isEmpty ? null : verifyHost,
          onPhase: onPhase,
        ),
      );
    } else {
      await showApplyActivationDialog(
        context,
        runApply: (onPhase) async {
          onPhase?.call('macOS hosts 적용 중…');
          final MacBlockResult r =
              await MacSystemBlockService.instance.activate();
          return ApplyActivationReport(
            success: r.status == MacBlockStatus.success,
            steps: <ApplyActivationStep>[
              ApplyActivationStep(
                id: 'hosts',
                label: '/etc/hosts',
                ok: r.status == MacBlockStatus.success,
                detail: r.message ?? r.status.name,
              ),
            ],
            summary: r.status == MacBlockStatus.success
                ? '시스템 차단이 활성화되었습니다.'
                : '적용 실패 또는 취소',
          );
        },
      );
    }
    if (!mounted) return;
    await _refresh();
    if (Platform.isWindows) {
      await _runSiteProbe();
      await _runAutoTest();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('진단'),
        actions: <Widget>[
          IconButton(
            onPressed: _loading ? null : _refresh,
            icon: const Icon(Icons.refresh),
            tooltip: '새로고침',
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: <Widget>[
                if (_hasErrors) ...<Widget>[
                  _errorAlert(context),
                  const SizedBox(height: 12),
                ],
                _identityCard(context),
                const SizedBox(height: 12),
                const CursorOneTapDiagnosticCard(),
                const SizedBox(height: 12),
                const BlockingSelfHealCard(),
                const YoutubeProactiveGuardCard(),
                const BlockingPipelineStatusPanel(),
                LagDiagnosticCard(),
                const SizedBox(height: 12),
                const BlockActivityLivePanel(maxHeight: 260),
                const SizedBox(height: 12),
                const NotificationHistoryPanel(maxHeight: 260),
                const SizedBox(height: 12),
                _siteBlockProbeCard(context),
                const SizedBox(height: 12),
                _browserLiveCard(context),
                const SizedBox(height: 12),
                _vpnBypassAgentCard(context),
                const SizedBox(height: 12),
                _agentHubCard(context),
                const SizedBox(height: 12),
                _hostsCard(context),
                const SizedBox(height: 12),
                _firefoxCard(context),
                const SizedBox(height: 12),
                if (Platform.isWindows) _fiveLayerExperimentCard(context),
                if (Platform.isWindows) const SizedBox(height: 12),
                _autoTestCard(context),
                const SizedBox(height: 12),
                _dnsCard(context),
                const SizedBox(height: 12),
                _activeNowCard(context),
                const SizedBox(height: 12),
                _systemLogCard(context),
                const SizedBox(height: 12),
                _logsCard(context),
              ],
            ),
    );
  }

  Future<void> _runSiteProbe() async {
    final String raw = _probeCtrl.text.trim();
    if (raw.isEmpty) return;
    setState(() => _siteProbing = true);
    final SiteBlockProbeReport rep =
        await BlockProbeService.instance.probeHost(raw);
    if (!mounted) return;
    setState(() {
      _siteProbe = rep;
      _siteProbing = false;
    });
  }

  Future<void> _openChromeDnsSettings() async {
    final bool ok =
        await ChromeDnsProbeService.instance.openSecureDnsSettings();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          ok
              ? 'Chrome 보안 설정을 열었습니다. 「보안 DNS 사용」을 끄거나 「현재 서비스 제공업체」로 바꾸세요.'
              : 'Chrome을 찾지 못했습니다. chrome://settings/security 를 주소창에 입력하세요.',
        ),
      ),
    );
    await _runSiteProbe();
  }

  Future<void> _runFiveLayerUac() async {
    setState(() {
      _fiveLayerUacRunning = true;
      _fiveLayerUacMessage = null;
    });
    final FiveLayerUacResult r =
        await WindowsFiveLayerUacService.instance.applyHostsAndFirewall();
    if (!mounted) return;
    setState(() {
      _fiveLayerUacRunning = false;
      _fiveLayerUacMessage = r.message;
    });
    await Future<void>.delayed(const Duration(seconds: 5));
    if (mounted) await _runFiveLayerExperiment();
  }

  Future<void> _runFiveLayerExperiment() async {
    setState(() => _fiveLayerRunning = true);
    final FiveLayerExperimentReport rep =
        await WindowsFiveLayerExperimentService.instance.run(
      applyFirst: true,
      reason: 'diagnostics_ui',
    );
    if (!mounted) return;
    setState(() {
      _fiveLayerReport = rep;
      _fiveLayerRunning = false;
    });
  }

  Widget _fiveLayerExperimentCard(BuildContext context) {
    final FiveLayerExperimentReport? rep = _fiveLayerReport;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _sectionHeader(
              context,
              icon: Icons.layers_outlined,
              color: AppColors.accent,
              title: '5계층 차단 실험 (Windows)',
              subtitle:
                  'hosts · 확장 · PAC · 창제목 · 방화벽 — 각 레이어 독립 점검',
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.tonalIcon(
                  onPressed: _fiveLayerRunning ? null : _runFiveLayerExperiment,
                  icon: _fiveLayerRunning
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.science_outlined, size: 18),
                  label: Text(_fiveLayerRunning ? '실험 중…' : '5계층 실험'),
                ),
                OutlinedButton.icon(
                  onPressed: (_fiveLayerUacRunning || _fiveLayerRunning)
                      ? null
                      : _runFiveLayerUac,
                  icon: _fiveLayerUacRunning
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.admin_panel_settings_outlined, size: 18),
                  label: Text(_fiveLayerUacRunning ? 'UAC…' : 'UAC (①+⑤)'),
                ),
              ],
            ),
            if (_fiveLayerUacMessage != null) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                _fiveLayerUacMessage!,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.muted,
                    ),
              ),
            ],
            if (rep != null) ...<Widget>[
              const SizedBox(height: 10),
              Text(
                '결과: ${rep.passCount}/${rep.probes.length} 통과 · '
                '${rep.at.toLocal().toString().substring(0, 19)}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 8),
              for (final LayerProbe p in rep.probes)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Icon(
                        p.ok ? Icons.check_circle : Icons.warning_amber,
                        size: 16,
                        color: p.ok ? AppColors.success : AppColors.warning,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${'①②③④⑤'[p.layer - 1]} ${p.name}: ${p.detail}',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                height: 1.35,
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (rep.youtubeApiSample != null) ...<Widget>[
                const SizedBox(height: 6),
                Text(
                  'YouTube API 샘플: ${rep.youtubeApiSample}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontFamily: 'Menlo',
                        color: AppColors.muted,
                      ),
                ),
              ],
              Text(
                '저장: ${WindowsFiveLayerExperimentService.reportPath()}',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.muted,
                      fontSize: 11,
                    ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Future<void> _runAutoTest() async {
    setState(() => _autoTesting = true);
    final String custom = _probeCtrl.text.trim();
    final List<String>? hosts = custom.isNotEmpty
        ? <String>[MacSystemBlockService.canonicalHost(custom), 'www.naver.com']
        : null;
    final BlockerTestReport rep =
        await BlockerTestService.instance.run(hosts: hosts);
    if (!mounted) return;
    setState(() {
      _autoReport = rep;
      _autoTesting = false;
    });
  }

  Future<void> _quitFirefox() async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final bool ok = await BlockerTestService.instance.quitFirefox();
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(content: Text(ok
          ? 'Firefox 종료 완료 — 다시 실행하면 DoH 차단이 적용됩니다'
          : 'Firefox 종료 실패 (수동으로 닫아주세요)')),
    );
    await _runAutoTest();
  }

  Widget _browserLiveCard(BuildContext context) {
    final List<RecentSiteEvent> events = RecentSiteEvents.instance.snapshot();
    final int port = UsageIngestServer.instance.boundPort;
    final bool listening = UsageIngestServer.instance.isRunning;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _sectionHeader(
              context,
              icon: Icons.sensors,
              color: AppColors.accent,
              title: '브라우저 실시간 (확장 연동)',
              subtitle: listening
                  ? '확장이 보고한 최근 사이트 · 규칙 API http://127.0.0.1:$port/rules'
                  : '로컬 서버가 꺼져 있습니다 — 앱을 다시 실행하세요.',
            ),
            const SizedBox(height: 8),
            if (events.isEmpty)
              Text(
                '아직 기록 없음. Chrome/Edge에 확장을 로드하고 페이지를 열면 여기에 표시됩니다.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.muted,
                    ),
              )
            else
              for (final RecentSiteEvent e in events.take(12))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          e.host,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                fontFamily: 'Menlo',
                              ),
                        ),
                      ),
                      Text(
                        '${e.at.hour.toString().padLeft(2, '0')}:'
                        '${e.at.minute.toString().padLeft(2, '0')}',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: AppColors.muted,
                            ),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }

  Widget _siteBlockProbeCard(BuildContext context) {
    final SiteBlockProbeReport? rep = _siteProbe;
    final Color verdictColor = rep == null
        ? AppColors.muted
        : (rep.allOk ? AppColors.success : AppColors.danger);
    return Card(
      elevation: rep != null && !rep.allOk ? 2 : 0,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _sectionHeader(
              context,
              icon: Icons.troubleshoot,
              color: AppColors.accent,
              title: '사이트 차단 점검',
              subtitle: 'DB → hosts → DNS → HTTP → Chrome 보안 DNS 순으로 왜 막히지 않는지 보여줍니다.',
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _probeCtrl,
              decoration: const InputDecoration(
                labelText: '테스트할 주소',
                hintText: '도메인 또는 URL 입력',
                border: OutlineInputBorder(),
                isDense: true,
              ),
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _runSiteProbe(),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: _siteProbing ? null : _runSiteProbe,
                  icon: _siteProbing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.search),
                  label: Text(_siteProbing ? '점검 중…' : '이 주소 점검'),
                ),
                OutlinedButton.icon(
                  onPressed: _openChromeDnsSettings,
                  icon: const Icon(Icons.open_in_browser),
                  label: const Text('Chrome DNS 설정 열기'),
                ),
                if (rep != null)
                  OutlinedButton.icon(
                    onPressed: () async {
                      final StringBuffer buf = StringBuffer()
                        ..writeln('Site probe: ${rep.host}')
                        ..writeln(rep.verdict);
                      for (final SiteBlockLayer l in rep.layers) {
                        buf.writeln('${l.ok ? "OK" : "FAIL"} ${l.title}: ${l.detail}');
                      }
                      await Clipboard.setData(ClipboardData(text: buf.toString()));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('점검 결과를 복사했습니다')),
                      );
                    },
                    icon: const Icon(Icons.copy),
                    label: const Text('결과 복사'),
                  ),
              ],
            ),
            if (rep != null) ...<Widget>[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: verdictColor.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: verdictColor.withValues(alpha: 0.3)),
                ),
                child: SelectableText(
                  rep.verdict,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: verdictColor,
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                      ),
                ),
              ),
              const SizedBox(height: 10),
              for (final SiteBlockLayer layer in rep.layers)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Icon(
                        layer.ok ? Icons.check_circle : Icons.cancel,
                        size: 18,
                        color: layer.ok ? AppColors.success : AppColors.danger,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              layer.title,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    fontWeight: FontWeight.w700,
                                  ),
                            ),
                            SelectableText(
                              layer.detail,
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: AppColors.muted,
                                    height: 1.3,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              if (rep.chromeBypass) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  'Chrome만 여전히 열리면: 설정 → 개인정보 보호 및 보안 → 보안 → '
                  '「보안 DNS 사용」 끔 또는 「현재 서비스 제공업체」 선택 → Chrome 완전 종료 후 재실행.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.warning,
                        height: 1.35,
                      ),
                ),
              ],
            ] else
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '차단이 안 될 때 여기서 원인을 확인하세요.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.muted,
                      ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _autoTestCard(BuildContext context) {
    final BlockerTestReport? rep = _autoReport;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _sectionHeader(
              context,
              icon: Icons.fact_check_outlined,
              color: AppColors.accent,
              title: '브라우저 차단 자동 진단',
              subtitle: '위 「사이트 차단 점검」 주소로 시스템 DNS·Chrome·Edge·Firefox를 각각 검사합니다.',
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: _autoTesting ? null : _runAutoTest,
                  icon: _autoTesting
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.play_arrow),
                  label: Text(_autoTesting ? '진단 중...' : '자동 진단 실행'),
                ),
                OutlinedButton.icon(
                  onPressed: _quitFirefox,
                  icon: const Icon(Icons.power_settings_new),
                  label: const Text('Firefox 강제 종료'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (rep == null)
              Text(
                '아직 결과 없음 — "자동 진단 실행" 누르세요.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.muted,
                    ),
              )
            else
              Column(
                children: <Widget>[
                  for (final BrowserTestResult r in rep.results)
                    _autoTestRow(context, r),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _autoTestRow(BuildContext context, BrowserTestResult r) {
    final Color tint = r.passed ? AppColors.success : AppColors.danger;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: tint.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(r.icon, style: const TextStyle(fontSize: 18)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  r.label,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              if (r.isRunning)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.warning.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '실행 중',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: AppColors.warning,
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
              const SizedBox(width: 6),
              Icon(r.passed ? Icons.check_circle : Icons.cancel,
                  color: tint, size: 18),
            ],
          ),
          const SizedBox(height: 4),
          SelectableText(
            r.summary,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: tint,
                  fontWeight: FontWeight.w600,
                ),
          ),
          if (r.hint != null) ...<Widget>[
            const SizedBox(height: 4),
            SelectableText(
              r.hint!,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.muted,
                    height: 1.3,
                  ),
            ),
          ],
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () async {
                final StringBuffer buf = StringBuffer()
                  ..writeln('${r.label} ${r.passed ? "OK" : "FAIL"}')
                  ..writeln(r.summary);
                if (r.hint != null) buf.writeln(r.hint);
                for (final HostProbe p in r.probes) {
                  buf.writeln('  ${p.host} → ${p.detail} (${p.blocked ? "blocked" : "open"})');
                }
                await Clipboard.setData(ClipboardData(text: buf.toString()));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('이 진단 행을 클립보드에 복사했어요')),
                );
              },
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('이 결과 복사'),
            ),
          ),
          const SizedBox(height: 4),
          for (final HostProbe p in r.probes)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1),
              child: Row(
                children: <Widget>[
                  Icon(
                    p.blocked ? Icons.block : Icons.public,
                    size: 13,
                    color: p.blocked ? AppColors.success : AppColors.danger,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: SelectableText(
                      p.host,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                  Expanded(
                    flex: 2,
                    child: SelectableText(
                      p.detail,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            fontFamily: 'Menlo',
                            color: AppColors.muted,
                          ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _systemLogCard(BuildContext context) {
    final String snippet = _systemLog.isEmpty
        ? '(아직 가져오지 않았어요 — "최근 5분 가져오기" 누르세요)'
        : _systemLog;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _sectionHeader(
              context,
              icon: Icons.terminal,
              color: AppColors.accent,
              title: 'macOS 시스템 로그 (DNS / Firefox / Chrome)',
              subtitle: '`log show` 결과를 그대로 보여줍니다. 차단이 안 될 때 여기에 단서가 남습니다.',
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.tonalIcon(
                  icon: _loadingSystemLog
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.download),
                  label: Text(_loadingSystemLog ? '읽는 중...' : '최근 5분 가져오기'),
                  onPressed: _loadingSystemLog
                      ? null
                      : () async {
                          setState(() => _loadingSystemLog = true);
                          final String s = await SystemLogService.instance
                              .fetch(minutes: 5);
                          if (!mounted) return;
                          setState(() {
                            _systemLog = s;
                            _loadingSystemLog = false;
                          });
                        },
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.copy),
                  label: const Text('복사'),
                  onPressed: () async {
                    final ScaffoldMessengerState messenger =
                        ScaffoldMessenger.of(context);
                    await Clipboard.setData(ClipboardData(text: snippet));
                    if (!mounted) return;
                    messenger.showSnackBar(
                      const SnackBar(content: Text('시스템 로그를 복사했어요')),
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 320),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectionArea(
                child: SingleChildScrollView(
                  reverse: true,
                  child: SelectableText(
                    snippet,
                    style: const TextStyle(
                      fontFamily: 'Menlo',
                      fontSize: 10.5,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _logsCard(BuildContext context) {
    final String snippet =
        _logSnippet.isEmpty ? '(아직 기록된 로그가 없어요)' : _logSnippet;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _sectionHeader(
              context,
              icon: Icons.receipt_long,
              color: AppColors.accent,
              title: '앱 로그 (최근 ~64KB)',
              subtitle: '문제가 생기면 「로그 전체 복사」로 디스크 최신 내용을 클립보드에 넣거나, '
                  '아래에서 드래그로 선택해 주세요. '
                  '파일 위치: ${_logPath ?? "(준비 중)"}',
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.tonalIcon(
                  icon: const Icon(Icons.copy),
                  label: const Text('로그 전체 복사'),
                  onPressed: () async {
                    final ScaffoldMessengerState messenger =
                        ScaffoldMessenger.of(context);
                    final String full = await AppLogger.instance.readRecent(
                      maxBytes: 256 * 1024,
                    );
                    await Clipboard.setData(ClipboardData(text: full));
                    if (!mounted) return;
                    messenger.showSnackBar(
                      const SnackBar(content: Text('디스크에서 읽은 최신 로그를 클립보드에 복사했어요')),
                    );
                  },
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.refresh),
                  label: const Text('새로고침'),
                  onPressed: () async {
                    final String s = await AppLogger.instance.readRecent();
                    if (!mounted) return;
                    setState(() => _logSnippet = s);
                  },
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.delete_outline),
                  label: const Text('비우기'),
                  onPressed: () async {
                    await AppLogger.instance.clear();
                    if (!mounted) return;
                    setState(() => _logSnippet = '');
                  },
                ),
              ],
            ),
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 320),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectionArea(
                child: SingleChildScrollView(
                  reverse: true,
                  child: SelectableText(
                    snippet,
                    style: const TextStyle(
                      fontFamily: 'Menlo',
                      fontSize: 11,
                      height: 1.4,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _identityCard(BuildContext context) {
    final BuildIdentity? i = _identity;
    if (i == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Text(
            '앱 식별 정보를 불러오는 중…',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.muted),
          ),
        ),
      );
    }
    final ThemeData theme = Theme.of(context);
    return Card(
      color: AppColors.success.withValues(alpha: 0.06),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.verified_outlined, color: AppColors.success, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '실행 중인 앱 (버전 확인)',
                        style: theme.textTheme.titleSmall,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '지원·디버깅 시 아래 정보를 붙여넣으면 같은 빌드인지 확인할 수 있어요. '
                        '자율 진단 설계도: 저장소 `docs/AUTONOMOUS_DIAGNOSTIC_AGENT_BLUEPRINT.md`',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppColors.muted,
                          height: 1.45,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _kv(theme, '표시 이름', i.appName),
            _kv(theme, '버전', '${i.version}+${i.buildNumber}'),
            _kv(theme, '패키지 ID', i.packageName),
            _kv(theme, 'OS', '${i.operatingSystem} (${i.operatingSystemVersion})'),
            _kv(theme, '실행 파일', i.executableBaseName),
            const SizedBox(height: 6),
            SelectableText(
              i.executablePath,
              style: TextStyle(
                fontFamily: 'Menlo',
                fontSize: 11,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
              ),
            ),
            const SizedBox(height: 10),
            FilledButton.tonalIcon(
              onPressed: () async {
                final String bundle = '${await BuildIdentityService.instance.summaryLine()}\n'
                    '${i.executablePath}';
                await Clipboard.setData(ClipboardData(text: bundle));
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('식별 정보를 클립보드에 복사했어요')),
                );
              },
              icon: const Icon(Icons.copy_all_outlined, size: 18),
              label: const Text('식별 정보 한 번에 복사'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _vpnBypassAgentCard(BuildContext context) {
    return Card(
      color: AppColors.warning.withValues(alpha: 0.06),
      child: ListTile(
        leading: Icon(Icons.radar, color: AppColors.warning),
        title: const Text('브라우저 우회 자가 진단'),
        subtitle: Text(
          'IPv6 · DoH · QUIC · DNS 우선순위 — Chrome/Edge만 뚫릴 때 원인 찾기',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppColors.muted,
                height: 1.35,
              ),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => VpnBypassDiagnosticScreen(
                initialHost: _probeCtrl.text.trim(),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _agentHubCard(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(Icons.smart_toy_outlined, color: AppColors.accent),
        title: const Text('문제 해결 에이전트'),
        subtitle: const Text(
          '로컬 분석 · 허용된 자동 수정만 · 변경 감사 로그 · 선택적 API 조언',
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          Navigator.of(context).push<void>(
            MaterialPageRoute<void>(
              builder: (_) => DiagnosticAgentScreen(
                initialProbeHost: _probeCtrl.text.trim(),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _kv(ThemeData theme, String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 88,
            child: Text(
              k,
              style: theme.textTheme.bodySmall?.copyWith(color: AppColors.muted),
            ),
          ),
          Expanded(
            child: Text(v, style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _collapsibleHostsBlock(BuildContext context) {
    final List<String> lines = _hostsBlock.split(RegExp(r'\r?\n'));
    final int lineCount = lines.length;
    final String preview = lines.take(8).join('\n');
    final TextStyle mono = const TextStyle(
      fontFamily: 'Menlo',
      fontSize: 11,
      height: 1.4,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        InkWell(
          onTap: () => setState(() => _hostsBlockExpanded = !_hostsBlockExpanded),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              children: <Widget>[
                Icon(
                  _hostsBlockExpanded ? Icons.expand_less : Icons.expand_more,
                  size: 22,
                  color: AppColors.muted,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    _hostsBlockExpanded
                        ? '관리 구간 전체 ($lineCount줄) — 탭하여 접기'
                        : '관리 구간 미리보기 ($lineCount줄) — 탭하여 펼치기',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppColors.muted,
                          fontWeight: FontWeight.w600,
                        ),
                  ),
                ),
              ],
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(8),
          ),
          constraints: _hostsBlockExpanded
              ? null
              : const BoxConstraints(maxHeight: 160),
          child: SingleChildScrollView(
            child: SelectableText(
              _hostsBlockExpanded ? _hostsBlock : preview,
              style: mono,
            ),
          ),
        ),
        if (!_hostsBlockExpanded && lineCount > 8)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '… 외 ${lineCount - 8}줄 (UAC 적용 후에도 여기서 확인)',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.muted,
                  ),
            ),
          ),
      ],
    );
  }

  Widget _hostsCard(BuildContext context) {
    final bool win = Platform.isWindows;
    final String title = win ? r'%WINDIR%\System32\drivers\etc\hosts' : '/etc/hosts';
    final String subtitle = win
        ? (_hostsActive
            ? '관리 구간(마커)이 hosts에 있습니다.'
            : '관리 구간을 찾지 못했습니다. 차단 규칙이 반영됐는지 동기화·권한을 확인하세요.')
        : (_hostsActive
            ? '시스템 차단 활성 — 호스트 파일에 우리 블록이 들어있습니다.'
            : '시스템 차단 꺼짐 — "지금 적용" 눌러서 켜세요.');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _sectionHeader(
              context,
              icon: _hostsActive ? Icons.verified_user : Icons.shield_outlined,
              color: _hostsActive ? AppColors.success : AppColors.muted,
              title: title,
              subtitle: subtitle,
            ),
            const SizedBox(height: 10),
            if (Platform.isMacOS || Platform.isWindows)
              FilledButton.tonalIcon(
                onPressed: _runApply,
                icon: const Icon(Icons.sync),
                label: const Text('지금 적용 / 재적용'),
              ),
            if (Platform.isMacOS || Platform.isWindows) const SizedBox(height: 10),
            if (_hostsBlock.isEmpty)
              Text(
                '(아직 우리 블록이 없습니다)',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.muted,
                    ),
              )
            else
              _collapsibleHostsBlock(context),
          ],
        ),
      ),
    );
  }

  Widget _firefoxCard(BuildContext context) {
    final bool anyOff =
        _firefoxProfiles.any((FirefoxProfileStatus s) => s.dohLikelyOff);
    final bool allOff = _firefoxProfiles.isNotEmpty &&
        _firefoxProfiles.every((FirefoxProfileStatus s) => s.dohLikelyOff);
    final Color color = allOff
        ? AppColors.success
        : (anyOff ? AppColors.warning : AppColors.danger);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _sectionHeader(
              context,
              icon: Icons.public,
              color: color,
              title: 'Firefox — DNS-over-HTTPS',
              subtitle: _firefoxProfiles.isEmpty
                  ? 'Firefox 프로필을 찾지 못했어요. 설치된 Firefox가 있다면 한 번 실행해서 프로필을 만들어주세요.'
                  : allOff
                      ? (Platform.isWindows
                          ? '모든 프로필에서 DoH 꺼짐 — Windows hosts 차단이 Firefox에도 적용됩니다.'
                          : '모든 프로필에서 DoH 꺼짐 — /etc/hosts 차단이 Firefox에도 적용됩니다.')
                      : (Platform.isWindows
                          ? '일부/전부 DoH 켜짐 — Firefox는 시스템 hosts를 우회할 수 있어요. 아래 버튼으로 끄세요.'
                          : '일부/전부 DoH 켜짐 — Firefox는 /etc/hosts를 우회해서 naver.com을 그대로 열 수 있어요. 아래 버튼으로 끄세요.'),
            ),
            const SizedBox(height: 8),
            if (_firefoxPolicyInstalled)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.lock, size: 14, color: AppColors.success),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        '시스템 정책(policies.json) 설치됨 — Firefox 시작 시 DoH 강제 OFF',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AppColors.success,
                            ),
                      ),
                    ),
                  ],
                ),
              ),
            for (final FirefoxProfileStatus p in _firefoxProfiles)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  children: <Widget>[
                    Icon(
                      p.dohLikelyOff
                          ? Icons.check_circle
                          : Icons.warning_amber_outlined,
                      size: 16,
                      color: p.dohLikelyOff
                          ? AppColors.success
                          : AppColors.warning,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        p.displayName(),
                        style: Theme.of(context).textTheme.bodySmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      'user.js: ${p.userJsInstalled ? "있음" : "없음"} · trr.mode: ${p.trrModeInPrefs ?? "default"}',
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: AppColors.muted,
                            fontFamily: 'Menlo',
                          ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.tonalIcon(
                  onPressed: _installFirefoxConfig,
                  icon: const Icon(Icons.shield_outlined),
                  label: const Text('Firefox DoH 끄기 (user.js 작성)'),
                ),
                if (Platform.isMacOS)
                  OutlinedButton.icon(
                    onPressed: () => _runApply(),
                    icon: const Icon(Icons.lock_outline),
                    label: const Text('시스템 정책으로 잠그기 (admin)'),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '※ 적용 후에는 Firefox 종료 후 재실행 필요. 켜져 있는 동안에는 메모리상의 설정이 우선합니다.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.muted,
                    height: 1.35,
                  ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _dnsCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _sectionHeader(
              context,
              icon: Icons.network_check,
              color: AppColors.accent,
              title: 'DNS 확인 (시스템 리졸버)',
              subtitle: Platform.isWindows
                  ? 'Windows에서는 OS 리졸버(lookup)로 확인합니다. '
                      '0.0.0.0 또는 127.0.0.1이면 hosts 차단일 가능성이 큽니다.'
                  : '시스템이 어떤 IP를 돌려주는지 보여줍니다. 0.0.0.0 응답이면 차단된 상태입니다.',
            ),
            const SizedBox(height: 10),
            for (final _DnsTest t in _dnsTests)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  children: <Widget>[
                    Icon(
                      t.blocked
                          ? Icons.block
                          : (t.safeSearch
                              ? Icons.filter_alt_outlined
                              : Icons.public),
                      size: 16,
                      color: t.blocked
                          ? AppColors.success
                          : (t.safeSearch
                              ? AppColors.warning
                              : AppColors.danger),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(t.host,
                          style: Theme.of(context).textTheme.bodySmall),
                    ),
                    Flexible(
                      child: Text(
                        t.status,
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: AppColors.muted,
                              fontFamily: 'Menlo',
                            ),
                        textAlign: TextAlign.right,
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _probeCtrl,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      hintText: '예: www.naver.com',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: () async {
                    final _DnsTest t = await _probe(_probeCtrl.text.trim());
                    if (!mounted) return;
                    setState(() => _dnsTests.insert(0, t));
                  },
                  child: const Text('확인'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _activeNowCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _sectionHeader(
              context,
              icon: Icons.timelapse,
              color: AppColors.accent,
              title: '지금 활성 중인 도메인 (${_activeNowDomains.length})',
              subtitle:
                  '현재 시간/요일 기준으로 실제 차단 목록에 들어갈 도메인입니다. 비어있으면 활성 스케줄이 없습니다.',
            ),
            const SizedBox(height: 8),
            if (_activeNowDomains.isEmpty)
              Text(
                '지금 시간에 활성화된 스케줄이 없어요.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.muted,
                    ),
              )
            else
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _activeNowDomains.map((Map<String, Object?> r) {
                  final String host = (r['host'] as String?) ?? '';
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.block, size: 14, color: AppColors.accent),
                        const SizedBox(width: 4),
                        Text(host, style: Theme.of(context).textTheme.labelSmall),
                      ],
                    ),
                  );
                }).toList(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _errorAlert(BuildContext context) {
    final errorLines = _logSnippet
        .split('\n')
        .where((l) => l.contains('[ERROR]') || l.contains('FlutterError'))
        .toList();
    final fullErrorText = errorLines.join('\n');

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.1),
        border: Border.all(color: AppColors.danger.withValues(alpha: 0.3)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.error_outline, color: AppColors.danger, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '앱에서 에러가 감지되었습니다',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: AppColors.danger,
                      ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 240),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(6),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                fullErrorText.isNotEmpty
                    ? fullErrorText
                    : '(에러 로그를 앱 로그에서 확인하세요)',
                style: const TextStyle(
                  fontFamily: 'Menlo',
                  fontSize: 10,
                  height: 1.4,
                  color: Color(0xFFB71C1C),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton.tonalIcon(
                onPressed: () async {
                  final ScaffoldMessengerState messenger =
                      ScaffoldMessenger.of(context);
                  await Clipboard.setData(ClipboardData(text: fullErrorText));
                  if (!mounted) return;
                  messenger.showSnackBar(
                    const SnackBar(content: Text('전체 에러 로그 복사됨')),
                  );
                },
                icon: const Icon(Icons.copy),
                label: const Text('전체 복사'),
              ),
              OutlinedButton.icon(
                onPressed: () {
                  AppLogger.instance.clear();
                  setState(() => _hasErrors = false);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('에러 로그 초기화됨')),
                  );
                },
                icon: const Icon(Icons.delete_outline),
                label: const Text('초기화'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(
    BuildContext context, {
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Icon(icon, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      )),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.muted,
                      height: 1.35,
                    ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DnsTest {
  const _DnsTest({
    required this.host,
    required this.status,
    required this.blocked,
    this.safeSearch = false,
  });
  final String host;
  final String status;
  final bool blocked;
  final bool safeSearch;
}
