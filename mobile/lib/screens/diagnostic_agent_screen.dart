import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/diagnostic_agent_models.dart';
import '../services/app_logger.dart';
import '../services/blocker_test_service.dart';
import '../services/diagnostic_agent_service.dart';
import '../services/extension_rules_builder.dart';
import '../services/local_database.dart';
import '../services/mac_system_block_service.dart';
import '../services/windows_apply_status_service.dart';
import '../widgets/apply_activation_dialog.dart';
import '../theme/app_colors.dart';
import 'vpn_bypass_diagnostic_screen.dart';

/// In-app diagnostic agent: rule-based analysis, allow-listed auto-fixes,
/// audit log in SQLite, optional HTTP advisor (user-provided URL).
class DiagnosticAgentScreen extends StatefulWidget {
  const DiagnosticAgentScreen({super.key, this.initialProbeHost});

  /// Site to test (e.g. from 진단 화면 probe field).
  final String? initialProbeHost;

  @override
  State<DiagnosticAgentScreen> createState() => _DiagnosticAgentScreenState();
}

class _ChatTurn {
  _ChatTurn.user(this.text) : isUser = true;
  _ChatTurn.assistant(this.text) : isUser = false;
  final bool isUser;
  final String text;
}

class _DiagnosticAgentScreenState extends State<DiagnosticAgentScreen> {
  final DiagnosticAgentService _agent = DiagnosticAgentService.instance;
  final TextEditingController _apiUrlCtrl = TextEditingController();
  final TextEditingController _apiKeyCtrl = TextEditingController();
  final TextEditingController _modelCtrl = TextEditingController();
  final TextEditingController _chatInputCtrl = TextEditingController();
  final TextEditingController _probeHostCtrl = TextEditingController();
  final ScrollController _chatScroll = ScrollController();

  String _llmProvider = 'openai';
  final List<_ChatTurn> _chatTurns = <_ChatTurn>[];

  bool _busy = false;
  bool _includeBlockerTest = true;
  bool _includeLogInAdvisor = false;
  AgentAnalyzeResult? _lastAnalysis;
  String? _advisorReply;
  List<DiagnosticAgentLogRow> _logs = <DiagnosticAgentLogRow>[];
  String? _logsError;

  @override
  void initState() {
    super.initState();
    _probeHostCtrl.text = widget.initialProbeHost?.trim().isNotEmpty == true
        ? widget.initialProbeHost!.trim()
        : kDiagnosticBlockSentinelHost;
    _loadPrefs();
    _reloadLogs();
  }

  Future<void> _loadPrefs() async {
    final String prov = await _agent.getLlmProvider();
    final String model = await _agent.getLlmModel();
    final String? u = await _agent.getAdvisorApiUrl();
    final String? k = await _agent.getAdvisorApiKey();
    if (!mounted) return;
    setState(() {
      _llmProvider = prov;
      _modelCtrl.text = model;
      _apiUrlCtrl.text = prov == 'openai' ? '' : (u ?? '');
      _apiKeyCtrl.text = k ?? '';
    });
  }

  void _scrollChatToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_chatScroll.hasClients) return;
      _chatScroll.animateTo(
        _chatScroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    });
  }

  @override
  void dispose() {
    _apiUrlCtrl.dispose();
    _apiKeyCtrl.dispose();
    _modelCtrl.dispose();
    _chatInputCtrl.dispose();
    _probeHostCtrl.dispose();
    _chatScroll.dispose();
    super.dispose();
  }

  Future<void> _reloadLogs() async {
    try {
      final List<DiagnosticAgentLogRow> rows =
          await LocalDatabase.instance.diagnosticAgentLogs(limit: 60);
      if (!mounted) return;
      setState(() {
        _logs = rows;
        _logsError = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _logsError = '$e';
      });
    }
  }

  Future<void> _runAnalyze() async {
    setState(() {
      _busy = true;
      _advisorReply = null;
    });
    try {
      final String probe = MacSystemBlockService.canonicalHost(_probeHostCtrl.text);
      final AgentAnalyzeResult r = await _agent.analyze(
        runBlockerTest: _includeBlockerTest,
        probeHost: probe.isEmpty ? null : probe,
      );
      if (!mounted) return;
      setState(() => _lastAnalysis = r);
      final List<AgentFixKind> kinds = _orderedFixes(r);
      if (kinds.isNotEmpty) {
        await _applyFixKindsNow(
          kinds,
          batchReason: '문제 해결 에이전트: 분석 직후 제안된 자동 수정을 확인 창 없이 실행',
          verifyHost: probe.isEmpty ? null : probe,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Runs allow-listed fixes without a confirmation dialog; each call is
  /// still written to `diagnostic_agent_log` with [batchReason].
  Future<void> _applyFixKindsNow(
    List<AgentFixKind> kinds, {
    required String batchReason,
    String? verifyHost,
  }) async {
    int ok = 0;
    final List<String> lines = <String>[];
    for (final AgentFixKind k in kinds) {
      if (k == AgentFixKind.reapplySystemHosts &&
          Platform.isWindows &&
          verifyHost != null) {
        if (!mounted) return;
        await showApplyActivationDialog(
          context,
          runApply: (onPhase) => WindowsApplyStatusService.instance.applyAndVerify(
            verifyHost: verifyHost,
            onPhase: onPhase,
          ),
        );
        ok++;
        lines.add('${k.label}: UAC 적용·검증 다이얼로그 완료');
        continue;
      }
      final AgentApplyOutcome out = await _agent.applyFix(
        k,
        userReason: batchReason,
        verifyHost: verifyHost,
      );
      if (out.ok) {
        ok++;
      }
      lines.add('${k.label}: ${out.message}');
    }
    if (!mounted) return;
    await _reloadLogs();
    if (!mounted) return;
    await _showApplyResultDialog(
      title: '자동 수정 $ok/${kinds.length} 성공',
      detail: lines.join('\n'),
    );
  }

  /// Selectable, copyable apply-fix result dialog.
  ///
  /// Replaces the legacy SnackBar (non-selectable Text) so users can copy
  /// failure messages — especially `result.txt 없음`, transcript paths, and
  /// PowerShell stderr — to paste back when debugging.
  Future<void> _showApplyResultDialog({
    required String title,
    required String detail,
  }) async {
    final String full = detail.isEmpty ? title : '$title\n\n$detail';
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: SelectableText(
              detail.isEmpty ? '(추가 정보 없음)' : detail,
              style: const TextStyle(
                fontFamily: 'Menlo',
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ),
        actions: <Widget>[
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: full));
              if (!ctx.mounted) return;
              ScaffoldMessenger.of(ctx).showSnackBar(
                const SnackBar(content: Text('결과 전체를 클립보드에 복사했습니다.')),
              );
            },
            icon: const Icon(Icons.copy, size: 18),
            label: const Text('전체 복사'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveLlmSettings() async {
    await _agent.setLlmProvider(_llmProvider);
    await _agent.setLlmModel(_modelCtrl.text);
    final String url = _apiUrlCtrl.text.trim();
    final String key = _apiKeyCtrl.text.trim();
    await _agent.saveAdvisorConfig(
      apiUrl: _llmProvider == 'openai' ? null : (url.isEmpty ? null : url),
      apiKey: key.isEmpty ? null : key,
    );
    if (!mounted) return;
    if (_llmProvider == 'openai') {
      _apiUrlCtrl.clear();
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('연결 설정을 저장했습니다.')),
    );
  }

  Future<void> _askAdvisor() async {
    final AgentAnalyzeResult? a = _lastAnalysis;
    if (a == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('먼저 「분석 실행」을 해 주세요.')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final String? reply = await _agent.consultRemoteAdvisor(
        a,
        includeLogTail: _includeLogInAdvisor,
      );
      if (!mounted) return;
      final String message = (reply == null || reply.trim().isEmpty)
          ? '응답이 비었습니다. (사용자 URL 모드는 서버가 JSON reply 필드 또는 본문 텍스트를 반환해야 합니다.)'
          : reply.trim();
      setState(() => _advisorReply = message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _injectAnalysisAndLogsIntoChat() async {
    final AgentAnalyzeResult? a = _lastAnalysis;
    if (a == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('먼저 「분석 실행」을 해 주세요.')),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final String findings = _findingsPlainText(a);
      final String log = await AppLogger.instance.readRecent(maxBytes: 20000);
      final String block =
          '$findings\n\n--- App log (최근 일부) ---\n$log';
      if (!mounted) return;
      setState(() {
        final String cur = _chatInputCtrl.text.trim();
        _chatInputCtrl.text = cur.isEmpty ? block : '$cur\n\n$block';
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('입력창에 분석+로그를 넣었습니다. 필요하면 줄이고 전송하세요.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('붙여넣기 실패: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendChat() async {
    final String text = _chatInputCtrl.text.trim();
    if (text.isEmpty) return;
    setState(() {
      _chatTurns.add(_ChatTurn.user(text));
      _chatInputCtrl.clear();
      _busy = true;
    });
    _scrollChatToBottom();
    try {
      final List<_ChatTurn> slice = _chatTurns.length > 24
          ? _chatTurns.sublist(_chatTurns.length - 24)
          : List<_ChatTurn>.from(_chatTurns);
      final List<Map<String, String>> history = <Map<String, String>>[];
      for (final _ChatTurn t in slice) {
        history.add(<String, String>{
          'role': t.isUser ? 'user' : 'assistant',
          'content': t.text,
        });
      }
      final String reply = await _agent.sendChatMessages(history);
      if (!mounted) return;
      setState(() => _chatTurns.add(_ChatTurn.assistant(reply)));
    } catch (e) {
      if (!mounted) return;
      setState(() => _chatTurns.add(_ChatTurn.assistant('오류: $e')));
    } finally {
      if (mounted) setState(() => _busy = false);
      _scrollChatToBottom();
    }
  }

  Future<void> _applyOneFixFromButton(AgentFixKind kind) async {
    setState(() => _busy = true);
    try {
      final String probe = MacSystemBlockService.canonicalHost(_probeHostCtrl.text);
      await _applyFixKindsNow(
        <AgentFixKind>[kind],
        batchReason: '사용자가 진단 에이전트에서 「${kind.label}」 버튼 탭',
        verifyHost: probe.isEmpty ? null : probe,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  IconData _iconForSeverity(AgentFindingSeverity s) {
    switch (s) {
      case AgentFindingSeverity.info:
        return Icons.info_outline;
      case AgentFindingSeverity.warning:
        return Icons.warning_amber_outlined;
      case AgentFindingSeverity.error:
        return Icons.error_outline;
    }
  }

  Color _colorForSeverity(AgentFindingSeverity s) {
    switch (s) {
      case AgentFindingSeverity.info:
        return AppColors.accent;
      case AgentFindingSeverity.warning:
        return Colors.amber.shade700;
      case AgentFindingSeverity.error:
        return Colors.redAccent;
    }
  }

  static const List<AgentFixKind> _kFixApplyOrder = <AgentFixKind>[
    AgentFixKind.nudgeBlockSync,
    AgentFixKind.reapplySystemHosts,
    AgentFixKind.flushDnsCacheWindows,
  ];

  List<AgentFixKind> _orderedFixes(AgentAnalyzeResult r) {
    final List<AgentFixKind> out = <AgentFixKind>[];
    for (final AgentFixKind k in _kFixApplyOrder) {
      if (!r.proposedFixKinds.contains(k)) continue;
      if (k == AgentFixKind.flushDnsCacheWindows && !Platform.isWindows) {
        continue;
      }
      out.add(k);
    }
    return out;
  }

  String _severityLabel(AgentFindingSeverity s) {
    switch (s) {
      case AgentFindingSeverity.info:
        return '정보';
      case AgentFindingSeverity.warning:
        return '경고';
      case AgentFindingSeverity.error:
        return '오류';
    }
  }

  String _findingsPlainText(AgentAnalyzeResult r) {
    final StringBuffer b = StringBuffer()
      ..writeln('=== Focus Fense · 문제 해결 에이전트 · 분석 결과 ===')
      ..writeln('자동진단 포함: ${r.testReportRan ? "예" : "아니오"}')
      ..writeln();
    for (final AgentFinding f in r.findings) {
      b.writeln('[${_severityLabel(f.severity)}] ${f.code}');
      b.writeln(f.title);
      b.writeln(f.body);
      b.writeln();
    }
    return b.toString().trimRight();
  }

  Future<void> _copyFindingsToClipboard(BuildContext context, AgentAnalyzeResult r) async {
    await Clipboard.setData(ClipboardData(text: _findingsPlainText(r)));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('분석 결과 전체를 클립보드에 복사했습니다.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('문제 해결 에이전트'),
        actions: <Widget>[
          IconButton(
            tooltip: '변경 기록 새로고침',
            onPressed: _busy ? null : _reloadLogs,
            icon: const Icon(Icons.history),
          ),
        ],
      ),
      body: Stack(
        children: <Widget>[
          ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 48),
            children: <Widget>[
              Card(
                child: ListTile(
                  leading: Icon(Icons.radar, color: AppColors.warning),
                  title: const Text('브라우저 우회 4단계 진단'),
                  subtitle: const Text('IPv6 · DoH · QUIC · DNS — Chrome/Edge만 뚫릴 때'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => const VpnBypassDiagnosticScreen(),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '로컬 규칙 + 허용된 수정만',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '원격 LLM이 데이터를 마음대로 바꾸지 않습니다. '
                        '「분석 실행」 직후에는 제안된 「백업 동기화」「hosts 재적용(UAC)」「DNS 캐시 비우기」가 '
                        '확인 창 없이 순서대로 시도되며, 각 실행은 DB와 앱 로그에 사유가 남습니다. '
                        'UAC/관리자 창은 OS가 표시합니다.',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _probeHostCtrl,
                        decoration: const InputDecoration(
                          labelText: '점검할 사이트',
                          hintText: '도메인 입력 (예: blocked-test.example)',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        enabled: !_busy,
                      ),
                      const SizedBox(height: 10),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Chrome·Edge·Firefox 자동 진단 (수 초)'),
                        subtitle: const Text('각 브라우저별 DNS 조회 + HTTP + DoH 프로필'),
                        value: _includeBlockerTest,
                        onChanged: _busy
                            ? null
                            : (bool v) => setState(() => _includeBlockerTest = v),
                      ),
                      FilledButton.icon(
                        onPressed: _busy ? null : _runAnalyze,
                        icon: const Icon(Icons.psychology_outlined),
                        label: const Text('분석 실행'),
                      ),
                    ],
                  ),
                ),
              ),
              if (_lastAnalysis != null) ...<Widget>[
                const SizedBox(height: 12),
                if (_lastAnalysis!.browserTests.isNotEmpty) ...<Widget>[
                  _browserTestsCard(context, _lastAnalysis!.browserTests),
                  const SizedBox(height: 12),
                ],
                _findingsCard(context, _lastAnalysis!),
                const SizedBox(height: 12),
                _fixesCard(context, _lastAnalysis!),
              ],
              const SizedBox(height: 12),
              _llmAndChatCard(context),
              const SizedBox(height: 12),
              _logsCard(context),
            ],
          ),
          if (_busy)
            const Positioned.fill(
              child: IgnorePointer(
                child: ModalBarrier(dismissible: false, color: Colors.black26),
              ),
            ),
          if (_busy)
            const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }

  Widget _browserTestsCard(BuildContext context, List<BrowserTestResult> tests) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '브라우저별 차단 테스트',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 6),
            Text(
              '시스템 DNS·Chrome·Edge·Firefox — 호스트마다 DNS(0.0.0.0)와 HTTP(연결 실패)를 표시합니다.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 12),
            for (final BrowserTestResult b in tests) ...<Widget>[
              Row(
                children: <Widget>[
                  Text(b.icon, style: const TextStyle(fontSize: 18)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      b.label,
                      style: const TextStyle(fontWeight: FontWeight.w700),
                    ),
                  ),
                  Icon(
                    b.passed ? Icons.check_circle : Icons.error_outline,
                    color: b.passed ? AppColors.success : AppColors.danger,
                    size: 22,
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.only(left: 26, top: 2, bottom: 4),
                child: Text(
                  b.summary + (b.isRunning ? ' · 실행 중' : ''),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              for (final HostProbe p in b.probes)
                Padding(
                  padding: const EdgeInsets.only(left: 26, bottom: 2),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Icon(
                        p.blocked ? Icons.lock : Icons.lock_open,
                        size: 14,
                        color: p.blocked ? AppColors.success : AppColors.danger,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '${p.host} — ${p.detail}',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                height: 1.25,
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
              if (b.hint != null && b.hint!.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 26, bottom: 8, top: 2),
                  child: Text(
                    b.hint!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppColors.warning,
                          height: 1.3,
                        ),
                  ),
                ),
              const Divider(height: 20),
            ],
          ],
        ),
      ),
    );
  }

  Widget _findingsCard(BuildContext context, AgentAnalyzeResult r) {
    final TextStyle small = Theme.of(context).textTheme.bodySmall ?? const TextStyle();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  child: Text('분석 결과', style: Theme.of(context).textTheme.titleMedium),
                ),
                FilledButton.tonalIcon(
                  onPressed: _busy ? null : () => _copyFindingsToClipboard(context, r),
                  icon: const Icon(Icons.copy_all_outlined, size: 18),
                  label: const Text('전체 복사'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '아래 블록은 드래그로 선택해 복사할 수 있습니다. Windows에서는 「전체 복사」가 더 확실합니다.',
              style: small.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            SelectionArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: r.findings.map((AgentFinding f) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Icon(
                          _iconForSeverity(f.severity),
                          color: _colorForSeverity(f.severity),
                          size: 22,
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: SelectableText(
                            '[${_severityLabel(f.severity)}] ${f.code}\n${f.title}\n${f.body}',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.35),
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _fixesCard(BuildContext context, AgentAnalyzeResult r) {
    final List<AgentFixKind> kinds = _orderedFixes(r);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('안전한 자동 수정', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              '「분석 실행」에서 이미 순서대로 시도됩니다. 아래는 같은 작업을 다시 실행할 때 사용합니다.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: kinds
                  .map(
                    (AgentFixKind k) => OutlinedButton(
                      onPressed: _busy ? null : () => _applyOneFixFromButton(k),
                      child: Text(k.label),
                    ),
                  )
                  .toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _llmAndChatCard(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('AI 조언 · 채팅', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'OpenAI: API 키(sk-...)만 저장하면 됩니다. URL은 '
              '${DiagnosticAgentService.kOpenAiChatCompletionsUrl} 로 고정됩니다.\n'
              '채팅은 앱을 대신 수정·빌드하지 않습니다. 단계 안내용입니다.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            SegmentedButton<String>(
              segments: const <ButtonSegment<String>>[
                ButtonSegment<String>(
                  value: 'openai',
                  label: Text('OpenAI'),
                  tooltip: 'ChatGPT API — URL 자동',
                ),
                ButtonSegment<String>(
                  value: 'custom',
                  label: Text('직접 URL'),
                  tooltip: 'OpenAI 호환 chat/completions',
                ),
              ],
              selected: <String>{_llmProvider},
              onSelectionChanged: _busy
                  ? null
                  : (Set<String> selection) {
                      if (selection.isEmpty) return;
                      setState(() {
                        _llmProvider = selection.first;
                        if (_llmProvider == 'openai') {
                          _apiUrlCtrl.clear();
                        }
                      });
                    },
            ),
            const SizedBox(height: 10),
            if (_llmProvider == 'openai')
              SelectionArea(
                child: SelectableText(
                  '엔드포인트: ${DiagnosticAgentService.kOpenAiChatCompletionsUrl}',
                  style: theme.textTheme.labelSmall?.copyWith(fontFamily: 'Menlo'),
                ),
              )
            else
              TextField(
                controller: _apiUrlCtrl,
                decoration: const InputDecoration(
                  labelText: 'API URL (https://…/v1/chat/completions 등)',
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.url,
              ),
            const SizedBox(height: 10),
            TextField(
              controller: _apiKeyCtrl,
              decoration: const InputDecoration(
                labelText: 'API 키 (Bearer, OpenAI는 sk-…)',
                border: OutlineInputBorder(),
              ),
              obscureText: true,
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _modelCtrl,
              decoration: const InputDecoration(
                labelText: '모델 ID (OpenAI 예: gpt-4o-mini)',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('「한 번에 조언」에 앱 로그 포함 (~12KB)'),
              value: _includeLogInAdvisor,
              onChanged: _busy ? null : (bool v) => setState(() => _includeLogInAdvisor = v),
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton(
                  onPressed: _busy ? null : _saveLlmSettings,
                  child: const Text('연결 저장'),
                ),
                FilledButton.tonal(
                  onPressed: _busy ? null : _askAdvisor,
                  child: const Text('한 번에 조언'),
                ),
                OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () {
                          setState(() {
                            _chatTurns.clear();
                            _advisorReply = null;
                          });
                        },
                  child: const Text('대화 비우기'),
                ),
              ],
            ),
            if (_advisorReply != null) ...<Widget>[
              const SizedBox(height: 12),
              Text('한 번에 조언 결과', style: theme.textTheme.titleSmall),
              const SizedBox(height: 6),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: SelectionArea(
                      child: SelectableText(
                        _advisorReply!,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '복사',
                    onPressed: () async {
                      await Clipboard.setData(ClipboardData(text: _advisorReply!));
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('복사했습니다.')),
                      );
                    },
                    icon: const Icon(Icons.copy_outlined),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 14),
            Text('채팅', style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            SizedBox(
              height: 240,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border.all(color: theme.colorScheme.outlineVariant),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: _chatTurns.isEmpty
                    ? Center(
                        child: Text(
                          '아래 입력창에서 질문하거나\n「분석+로그 넣기」로 컨텍스트를 채우세요.',
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: _chatScroll,
                        padding: const EdgeInsets.all(10),
                        itemCount: _chatTurns.length,
                        itemBuilder: (BuildContext context, int i) {
                          final _ChatTurn t = _chatTurns[i];
                          return Align(
                            alignment:
                                t.isUser ? Alignment.centerRight : Alignment.centerLeft,
                            child: Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                              constraints: const BoxConstraints(maxWidth: 520),
                              decoration: BoxDecoration(
                                color: t.isUser
                                    ? AppColors.accent.withValues(alpha: 0.15)
                                    : theme.colorScheme.surfaceContainerHighest,
                                borderRadius: BorderRadius.circular(10),
                              ),
                              child: SelectableText(
                                t.text,
                                style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _chatInputCtrl,
                    minLines: 1,
                    maxLines: 5,
                    decoration: const InputDecoration(
                      labelText: '메시지',
                      border: OutlineInputBorder(),
                    ),
                    textInputAction: TextInputAction.newline,
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _busy ? null : _sendChat,
                  child: const Text('전송'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _busy ? null : _injectAnalysisAndLogsIntoChat,
              icon: const Icon(Icons.playlist_add, size: 18),
              label: const Text('분석 + 앱 로그 → 입력창에 넣기'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _logsCard(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Text('에이전트 변경 기록', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                TextButton.icon(
                  onPressed: _logs.isEmpty
                      ? null
                      : () async {
                          final StringBuffer sb = StringBuffer();
                          sb.writeln('=== Focus Fense · 에이전트 변경 기록 ===');
                          for (final DiagnosticAgentLogRow row in _logs) {
                            sb.writeln(
                              '${DateTime.fromMillisecondsSinceEpoch(row.createdAtMs).toIso8601String()} | '
                              '${row.actionKind} | ${row.status}',
                            );
                            sb.writeln('reason: ${row.reason}');
                            sb.writeln('detail: ${row.detailJson}');
                            sb.writeln();
                          }
                          await Clipboard.setData(ClipboardData(text: sb.toString()));
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('기록 전체를 클립보드에 복사했습니다.')),
                          );
                        },
                  icon: const Icon(Icons.copy_all_outlined, size: 18),
                  label: const Text('전체 복사'),
                ),
              ],
            ),
            if (_logsError != null) Text(_logsError!, style: TextStyle(color: Colors.red.shade700)),
            if (_logs.isEmpty && _logsError == null)
              Text(
                '아직 기록이 없습니다. 자동 수정을 한 번 실행해 보세요.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            SelectionArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: _logs.map((DiagnosticAgentLogRow row) {
                  final DateTime when =
                      DateTime.fromMillisecondsSinceEpoch(row.createdAtMs);
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        SelectableText(
                          '${row.actionKind} · ${row.status}',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        SelectableText(
                          '${when.toLocal().toIso8601String()}\n${row.reason}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 4),
                        SelectableText(
                          row.detailJson,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                fontFamily: 'Menlo',
                                height: 1.3,
                              ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
