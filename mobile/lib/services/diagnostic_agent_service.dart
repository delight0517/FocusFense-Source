import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/apply_activation_report.dart';
import '../models/diagnostic_agent_models.dart';
import 'app_logger.dart';
import 'backup_service.dart';
import 'block_sync_service.dart';
import 'blocker_test_service.dart';
import 'local_database.dart';
import 'mac_system_block_service.dart';
import 'vpn_bypass_diagnostic_service.dart';
import 'windows_apply_status_service.dart';
import 'windows_hidden_process.dart';
import 'windows_system_block_service.dart';
import '../models/vpn_bypass_diagnostic_models.dart';

/// Rule-based in-app helper. Only [AgentFixKind] actions run — no arbitrary
/// SQL or hosts edits from a remote model. Optional HTTP advisor adds text
/// hints when the user configures an endpoint.
final class DiagnosticAgentService {
  DiagnosticAgentService._();
  static final DiagnosticAgentService instance = DiagnosticAgentService._();

  static const String _kPrefsApiUrl = 'six_diagnostic_agent_api_url';
  static const String _kPrefsApiKey = 'six_diagnostic_agent_api_key';
  static const String _kPrefsProvider = 'six_diagnostic_agent_llm_provider';
  static const String _kPrefsModel = 'six_diagnostic_agent_llm_model';

  /// OpenAI Chat Completions (ChatGPT API). User only needs an API key when
  /// [getLlmProvider] returns `openai`.
  static const String kOpenAiChatCompletionsUrl =
      'https://api.openai.com/v1/chat/completions';

  static const String kSupportSystemPrompt = '''
You are a support assistant for the desktop/mobile app "Focus Fense"
(SixVPN / six_clean_room): system hosts blocking, Firefox DoH, Chrome secure DNS,
schedules, and diagnostics.

Rules:
- Explain steps clearly in the user's language (they may write Korean or English).
- You cannot modify source code, recompile the app, or change the project blueprint.
- Prefer concrete checks: UAC hosts apply, ipconfig /flushdns, Firefox full quit,
  Chrome secure DNS off, use in-app "safe auto-fix" buttons when relevant.
- If unsure, ask one focused question.
''';

  final Uuid _uuid = const Uuid();

  Future<String> getLlmProvider() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    return p.getString(_kPrefsProvider) ?? 'openai';
  }

  Future<void> setLlmProvider(String provider) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    await p.setString(_kPrefsProvider, provider.trim().isEmpty ? 'openai' : provider.trim());
  }

  Future<String> getLlmModel() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    return p.getString(_kPrefsModel) ?? 'gpt-4o-mini';
  }

  Future<void> setLlmModel(String model) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    final String m = model.trim().isEmpty ? 'gpt-4o-mini' : model.trim();
    await p.setString(_kPrefsModel, m);
  }

  Future<Uri?> effectiveChatUri() async {
    final String prov = await getLlmProvider();
    if (prov == 'openai') {
      return Uri.parse(kOpenAiChatCompletionsUrl);
    }
    final String? u = await getAdvisorApiUrl();
    if (u == null || u.trim().isEmpty) return null;
    return Uri.tryParse(u.trim());
  }

  Future<String?> getAdvisorApiUrl() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    final String? v = p.getString(_kPrefsApiUrl);
    if (v == null || v.trim().isEmpty) return null;
    return v.trim();
  }

  Future<String?> getAdvisorApiKey() async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    final String? v = p.getString(_kPrefsApiKey);
    if (v == null || v.trim().isEmpty) return null;
    return v.trim();
  }

  Future<void> saveAdvisorConfig({String? apiUrl, String? apiKey}) async {
    final SharedPreferences p = await SharedPreferences.getInstance();
    if (apiUrl == null || apiUrl.trim().isEmpty) {
      await p.remove(_kPrefsApiUrl);
    } else {
      await p.setString(_kPrefsApiUrl, apiUrl.trim());
    }
    if (apiKey == null || apiKey.trim().isEmpty) {
      await p.remove(_kPrefsApiKey);
    } else {
      await p.setString(_kPrefsApiKey, apiKey.trim());
    }
  }

  Future<bool> _hostsMarkerActive() async {
    if (Platform.isMacOS) {
      return MacSystemBlockService.instance.isActive();
    }
    if (Platform.isWindows) {
      return WindowsSystemBlockService.instance.isActive();
    }
    return false;
  }

  Future<List<String>> _probeHostsForTest({String? primaryHost}) async {
    final Set<String> out = <String>{'www.naver.com'};
    if (primaryHost != null && primaryHost.trim().isNotEmpty) {
      final String c = MacSystemBlockService.canonicalHost(primaryHost);
      if (c.isNotEmpty) out.add(c);
    }
    final List<Map<String, Object?>> rows =
        await LocalDatabase.instance.domainsActiveNow(DateTime.now());
    int added = 0;
    for (final Map<String, Object?> row in rows) {
      if (added >= 4) break;
      final String? host = row['host'] as String?;
      if (host == null) continue;
      final String c = MacSystemBlockService.canonicalHost(host);
      if (c.isNotEmpty) {
        out.add(c);
        added++;
      }
    }
    return out.toList();
  }

  /// Runs blocker self-test (can take several seconds) and heuristics.
  Future<AgentAnalyzeResult> analyze({
    bool runBlockerTest = true,
    String? probeHost,
  }) async {
    final List<AgentFinding> findings = <AgentFinding>[];
    final Set<AgentFixKind> fixes = <AgentFixKind>{};

    final bool hosts = await _hostsMarkerActive();
    final RuleCounts counts = await LocalDatabase.instance.ruleCounts();

    if (counts.domainsEnabled > 0 && !hosts) {
      findings.add(
        const AgentFinding(
          code: 'hosts_missing',
          severity: AgentFindingSeverity.warning,
          title: '시스템 hosts에 차단 블록이 없음',
          body: '도메인 규칙은 켜져 있지만 OS hosts 파일에 SixVPN 마커 블록이 보이지 않습니다. '
              '「시스템 hosts 재적용」을 시도하거나 진단 화면에서 UAC/관리자 적용을 완료하세요.',
        ),
      );
      fixes.add(AgentFixKind.reapplySystemHosts);
    }

    String? logTail;
    try {
      logTail = await AppLogger.instance.readRecent(maxBytes: 4096);
    } catch (_) {}
    if (logTail != null) {
      if (logTail.contains('accessibility_bridge.cc') &&
          logTail.contains('AXTree')) {
        findings.add(
          const AgentFinding(
            code: 'axtree_noise',
            severity: AgentFindingSeverity.info,
            title: 'Flutter Windows 접근성 로그 (무해한 경우가 많음)',
            body: '콘솔의 AXTree 오류는 엔진 측 잡음으로 알려져 있습니다. UI가 정상이면 무시해도 됩니다.',
          ),
        );
      }
    }

    if (Platform.isWindows || Platform.isMacOS) {
      try {
        final VpnBypassDiagnosticReport bypass =
            await VpnBypassDiagnosticService.instance.run(testHost: probeHost);
        for (final VpnBypassDiagnosticStep step in bypass.steps) {
          if (!step.issueDetected) continue;
          findings.add(
            AgentFinding(
              code: 'bypass_${step.id}',
              severity: AgentFindingSeverity.warning,
              title: '우회 진단: ${step.title}',
              body: '${step.detail}\n\n${step.remedy ?? step.cause?.remedy ?? ''}',
            ),
          );
        }
        if (bypass.detectedCauses.contains(VpnBypassCause.hostsNotApplied) ||
            bypass.detectedCauses.contains(VpnBypassCause.routingOrDnsPriority) ||
            bypass.detectedCauses.contains(VpnBypassCause.ipv6Leak)) {
          fixes.add(AgentFixKind.reapplySystemHosts);
        }
        if (Platform.isWindows &&
            (bypass.detectedCauses.contains(VpnBypassCause.dohBypass) ||
                bypass.detectedCauses.contains(VpnBypassCause.routingOrDnsPriority))) {
          fixes.add(AgentFixKind.flushDnsCacheWindows);
        }
      } catch (e, st) {
        AppLogger.instance.warn('VpnBypassDiagnostic in agent failed', error: e);
        AppLogger.instance.log('DEBUG', 'bypass stack', stack: st);
      }
    }

    bool ranTest = false;
    List<BrowserTestResult> browserMatrix = <BrowserTestResult>[];
    if (runBlockerTest) {
      ranTest = true;
      final List<String> probeHosts =
          await _probeHostsForTest(primaryHost: probeHost);
      if (Platform.isWindows) {
        browserMatrix =
            await WindowsApplyStatusService.instance.runBrowserMatrix(probeHosts);
      } else {
        browserMatrix = (await BlockerTestService.instance.run(hosts: probeHosts))
            .results;
      }
      for (final BrowserTestResult r in browserMatrix) {
        final String probeLines = r.probes
            .map((HostProbe p) => '  • ${p.host}: ${p.detail}')
            .join('\n');
        final StringBuffer bodyBuf = StringBuffer()
          ..writeln(r.summary)
          ..writeln('실행 중: ${r.isRunning ? "예" : "아니오"}')
          ..writeln(probeLines);
        if (r.hint != null) bodyBuf.write('\n${r.hint}');
        final String body = bodyBuf.toString();
        findings.add(
          AgentFinding(
            code: 'browser_${r.label.replaceAll(' ', '_')}',
            severity: r.passed ? AgentFindingSeverity.info : AgentFindingSeverity.warning,
            title: '브라우저·DNS: ${r.label}',
            body: body,
          ),
        );
        if (!r.passed) {
          fixes.add(AgentFixKind.reapplySystemHosts);
          if (Platform.isWindows) {
            fixes.add(AgentFixKind.flushDnsCacheWindows);
          }
        }
      }
    }

    fixes.add(AgentFixKind.nudgeBlockSync);

    if (findings.isEmpty) {
      findings.add(
        AgentFinding(
          code: 'all_clear',
          severity: AgentFindingSeverity.info,
          title: '특별한 문제를 찾지 못했습니다',
          body: ranTest
              ? '자동 진단 행이 모두 통과했습니다. 브라우저에서만 통과한다면 DoH·보안 DNS·Firefox 재시작을 확인하세요.'
              : '자동 진단을 끈 상태입니다. 자동 진단을 포함해 다시 분석하면 더 정확합니다.',
        ),
      );
    }

    return AgentAnalyzeResult(
      findings: findings,
      proposedFixKinds: fixes.toList(),
      testReportRan: ranTest,
      browserTests: browserMatrix,
    );
  }

  Future<AgentApplyOutcome> applyFix(
    AgentFixKind kind, {
    required String userReason,
    String? verifyHost,
  }) async {
    final String id = _uuid.v4();
    final String kindWire = kind.wireId;
    AppLogger.instance.info('diagnostic agent: apply $kindWire — $userReason');

    try {
      switch (kind) {
        case AgentFixKind.reapplySystemHosts:
          if (Platform.isWindows) {
            final ApplyActivationReport report =
                await WindowsApplyStatusService.instance.applyAndVerify(
              verifyHost: verifyHost != null && verifyHost.trim().isNotEmpty
                  ? verifyHost
                  : null,
            );
            final bool ok = report.success;
            final String msg = report.summary;
            await LocalDatabase.instance.insertDiagnosticAgentLog(
              id: id,
              actionKind: kindWire,
              status: ok ? 'success' : 'partial',
              reason: userReason,
              detail: <String, Object?>{
                'summary': report.summary,
                'steps': report.steps
                    .map((ApplyActivationStep s) => '${s.label}:${s.ok}')
                    .join(';'),
              },
            );
            return AgentApplyOutcome(ok: ok, message: msg);
          }
          final MacBlockResult r = await BlockSyncService.instance.applyNow();
          final bool ok = r.status == MacBlockStatus.success;
          final String msg = _formatBlockResult(r);
          await LocalDatabase.instance.insertDiagnosticAgentLog(
            id: id,
            actionKind: kindWire,
            status: ok ? 'success' : r.status.name,
            reason: userReason,
            detail: <String, Object?>{
              'blockStatus': r.status.name,
              'blockMessage': r.message,
            },
          );
          AppLogger.instance.info('diagnostic agent log: $kindWire → ${r.status.name}');
          return AgentApplyOutcome(ok: ok, message: msg, detail: <String, Object?>{'status': r.status.name});

        case AgentFixKind.nudgeBlockSync:
          BackupService.instance.scheduleSync();
          BlockSyncService.instance.requestApply();
          await LocalDatabase.instance.insertDiagnosticAgentLog(
            id: id,
            actionKind: kindWire,
            status: 'success',
            reason: userReason,
            detail: const <String, Object?>{'nudge': true},
          );
          AppLogger.instance.info('diagnostic agent log: $kindWire → scheduled');
          return const AgentApplyOutcome(
            ok: true,
            message: '백업 동기화를 예약했고 차단 재적용을 요청했습니다.',
          );

        case AgentFixKind.flushDnsCacheWindows:
          if (!Platform.isWindows) {
            await LocalDatabase.instance.insertDiagnosticAgentLog(
              id: id,
              actionKind: kindWire,
              status: 'skipped',
              reason: userReason,
              detail: const <String, Object?>{'platform': 'non_windows'},
            );
            return const AgentApplyOutcome(ok: false, message: 'Windows에서만 사용할 수 있습니다.');
          }
          final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
          final String ipconfigExe = '$windir\\System32\\ipconfig.exe';
          final ProcessResult pr = await windowsRunHidden(
            ipconfigExe,
            const <String>['/flushdns'],
          );
          final bool ok = pr.exitCode == 0;
          await LocalDatabase.instance.insertDiagnosticAgentLog(
            id: id,
            actionKind: kindWire,
            status: ok ? 'success' : 'failure',
            reason: userReason,
            detail: <String, Object?>{
              'exitCode': pr.exitCode,
              'stderr': pr.stderr.toString().trim(),
            },
          );
          AppLogger.instance.info(
            'diagnostic agent log: $kindWire → exit ${pr.exitCode}',
          );
          return AgentApplyOutcome(
            ok: ok,
            message: ok
                ? 'DNS 캐시를 비웠습니다.'
                : 'ipconfig 실패 (exit ${pr.exitCode})',
          );
      }
    } catch (e, st) {
      await LocalDatabase.instance.insertDiagnosticAgentLog(
        id: id,
        actionKind: kindWire,
        status: 'failure',
        reason: userReason,
        detail: <String, Object?>{'error': e.toString()},
      );
      AppLogger.instance.error('diagnostic agent apply failed', error: e, stack: st);
      return AgentApplyOutcome(ok: false, message: '오류: $e');
    }
  }

  String _formatBlockResult(MacBlockResult r) {
    switch (r.status) {
      case MacBlockStatus.success:
        return '시스템 차단을 다시 적용했습니다.';
      case MacBlockStatus.cancelled:
        return '사용자가 UAC/관리자 승인을 취소했습니다.';
      case MacBlockStatus.unsupported:
        return '이 구성에서는 시스템 차단이 꺼져 있거나 지원되지 않습니다.';
      case MacBlockStatus.failure:
        return '적용 실패: ${r.message ?? "원인 미상"}';
    }
  }

  String _analysisUserPayload(AgentAnalyzeResult analysis) {
    final StringBuffer b = StringBuffer()
      ..writeln('=== Diagnostic bundle ===')
      ..writeln('Platform: ${Platform.operatingSystem} ${Platform.operatingSystemVersion}')
      ..writeln('Blocker self-test was run: ${analysis.testReportRan}')
      ..writeln()
      ..writeln('Findings:');
    for (final AgentFinding f in analysis.findings) {
      b.writeln('- [${f.severity.name}] ${f.code}: ${f.title}\n  ${f.body}');
    }
    b.writeln();
    b.writeln('Proposed in-app fix wire IDs:');
    b.writeln(analysis.proposedFixKinds.map((AgentFixKind k) => k.wireId).join(', '));
    return b.toString();
  }

  Future<String> _appendLogTail(String base, {int maxBytes = 12000}) async {
    try {
      final String tail = await AppLogger.instance.readRecent(maxBytes: maxBytes);
      return '$base\n--- App log tail ---\n$tail';
    } catch (_) {
      return base;
    }
  }

  Future<String> _postOpenAiCompatibleChat({
    required Uri uri,
    required String apiKey,
    required String model,
    required List<Map<String, String>> messages,
  }) async {
    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest req = await client.postUrl(uri);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
      req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $apiKey');
      final String body = jsonEncode(<String, Object?>{
        'model': model,
        'messages': messages,
        'temperature': 0.25,
        'max_tokens': 2048,
      });
      req.write(body);
      final HttpClientResponse res = await req.close();
      final String raw = await utf8.decoder.bind(res).join();
      if (res.statusCode < 200 || res.statusCode >= 300) {
        throw HttpException('HTTP ${res.statusCode}: $raw', uri: uri);
      }
      final Object? dec = jsonDecode(raw);
      if (dec is Map) {
        final Object? choices = dec['choices'];
        if (choices is List && choices.isNotEmpty) {
          final Object? first = choices.first;
          if (first is Map) {
            final Object? msg = first['message'];
            if (msg is Map) {
              final Object? content = msg['content'];
              if (content is String && content.trim().isNotEmpty) {
                return content.trim();
              }
            }
          }
        }
      }
      throw const FormatException('OpenAI-compatible response missing choices[0].message.content');
    } finally {
      client.close(force: true);
    }
  }

  /// One-shot advisor (legacy button). Uses OpenAI when provider is `openai`,
  /// otherwise POSTs the custom JSON bundle to your URL.
  Future<String?> consultRemoteAdvisor(
    AgentAnalyzeResult analysis, {
    bool includeLogTail = false,
  }) async {
    final String prov = await getLlmProvider();
    if (prov == 'openai') {
      final String? key = await getAdvisorApiKey();
      if (key == null || key.isEmpty) {
        return '[안내] OpenAI(ChatGPT API) 사용: 아래 **API 키(sk-...)**만 입력 후 저장하세요. '
            'URL은 자동으로\n$kOpenAiChatCompletionsUrl\n입니다.';
      }
      String userText = _analysisUserPayload(analysis);
      if (includeLogTail) {
        userText = await _appendLogTail(userText);
      }
      final String model = await getLlmModel();
      try {
        return await _postOpenAiCompatibleChat(
          uri: Uri.parse(kOpenAiChatCompletionsUrl),
          apiKey: key,
          model: model,
          messages: <Map<String, String>>[
            <String, String>{'role': 'system', 'content': kSupportSystemPrompt},
            <String, String>{'role': 'user', 'content': userText},
          ],
        );
      } catch (e) {
        AppLogger.instance.warn('OpenAI advisor failed', error: e);
        return 'OpenAI 요청 실패: $e';
      }
    }

    final String? urlStr = await getAdvisorApiUrl();
    if (urlStr == null) {
      return '[안내] 「사용자 지정 URL」 모드입니다. 아래에 HTTPS API 주소를 입력하세요 '
          '(OpenAI 호환 chat/completions POST를 권장). 또는 공급자를 OpenAI로 바꾸면 URL 없이 키만으로 됩니다.';
    }
    final Uri? uri = Uri.tryParse(urlStr);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return null;
    }
    if (uri.scheme != 'https' && uri.scheme != 'http') {
      return null;
    }

    final Map<String, Object?> body = <String, Object?>{
      'platform': Platform.operatingSystem,
      'version': Platform.operatingSystemVersion,
      'findings': analysis.findings
          .map(
            (AgentFinding f) => <String, Object?>{
              'code': f.code,
              'severity': f.severity.name,
              'title': f.title,
              'body': f.body,
            },
          )
          .toList(),
      'proposedFixWireIds':
          analysis.proposedFixKinds.map((AgentFixKind k) => k.wireId).toList(),
    };
    if (includeLogTail) {
      try {
        body['logTail'] = await AppLogger.instance.readRecent(maxBytes: 2048);
      } catch (_) {}
    }

    final HttpClient client = HttpClient();
    try {
      final HttpClientRequest req = await client.postUrl(uri);
      req.headers.set(HttpHeaders.contentTypeHeader, 'application/json; charset=utf-8');
      final String? key = await getAdvisorApiKey();
      if (key != null && key.isNotEmpty) {
        req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $key');
      }
      req.write(jsonEncode(body));
      final HttpClientResponse res = await req.close();
      final String raw = await res.transform(utf8.decoder).join();
      if (res.statusCode < 200 || res.statusCode >= 300) {
        AppLogger.instance.warn('diagnostic agent advisor HTTP ${res.statusCode}');
        return null;
      }
      try {
        final Object? dec = jsonDecode(raw);
        if (dec is Map && dec['reply'] is String) {
          return dec['reply'] as String;
        }
      } catch (_) {/* */}
      return raw.trim().isEmpty ? null : raw.trim();
    } catch (e) {
      AppLogger.instance.warn('diagnostic agent advisor failed', error: e);
      return null;
    } finally {
      client.close(force: true);
    }
  }

  /// Multi-turn chat (OpenAI-compatible). [messages] must include alternating
  /// user/assistant history ending with the latest user message.
  Future<String> sendChatMessages(List<Map<String, String>> messages) async {
    final String? key = await getAdvisorApiKey();
    if (key == null || key.isEmpty) {
      throw StateError('API 키가 비어 있습니다. 저장 후 다시 시도하세요.');
    }
    final Uri? uri = await effectiveChatUri();
    if (uri == null) {
      throw StateError('API URL이 비어 있습니다. 사용자 지정 모드에서는 URL이 필요합니다.');
    }
    final List<Map<String, String>> full = <Map<String, String>>[
      <String, String>{'role': 'system', 'content': kSupportSystemPrompt},
      ...messages,
    ];
    final String model = await getLlmModel();
    return _postOpenAiCompatibleChat(uri: uri, apiKey: key, model: model, messages: full);
  }
}
