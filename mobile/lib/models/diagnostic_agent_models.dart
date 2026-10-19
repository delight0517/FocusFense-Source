import 'dart:convert';

import '../services/blocker_test_service.dart';

/// Severity for UI ordering / icons.
enum AgentFindingSeverity {
  info,
  warning,
  error,
}

/// One heuristic finding from [DiagnosticAgentService.analyze].
final class AgentFinding {
  const AgentFinding({
    required this.code,
    required this.severity,
    required this.title,
    required this.body,
  });

  final String code;
  final AgentFindingSeverity severity;
  final String title;
  final String body;
}

/// Built-in fix identifiers — only these may run from the agent UI.
enum AgentFixKind {
  reapplySystemHosts,
  nudgeBlockSync,
  flushDnsCacheWindows,
}

extension AgentFixKindWire on AgentFixKind {
  String get wireId {
    switch (this) {
      case AgentFixKind.reapplySystemHosts:
        return 'reapply_system_hosts';
      case AgentFixKind.nudgeBlockSync:
        return 'nudge_block_sync';
      case AgentFixKind.flushDnsCacheWindows:
        return 'flush_dns_cache_windows';
    }
  }

  String get label {
    switch (this) {
      case AgentFixKind.reapplySystemHosts:
        return '시스템 hosts 재적용 (UAC/관리자)';
      case AgentFixKind.nudgeBlockSync:
        return '백업 동기화 + 차단 재스케줄';
      case AgentFixKind.flushDnsCacheWindows:
        return 'Windows DNS 캐시 비우기 (ipconfig)';
    }
  }

  String get rationale {
    switch (this) {
      case AgentFixKind.reapplySystemHosts:
        return '마커 블록이 없거나 자동 진단이 실패할 때, UAC/관리자 승인으로 hosts·Firefox 정책을 다시 씁니다.';
      case AgentFixKind.nudgeBlockSync:
        return '규칙은 저장됐지만 OS 반영이 밀렸을 수 있어 백업 스냅샷을 예약하고 차단 적용을 다시 요청합니다.';
      case AgentFixKind.flushDnsCacheWindows:
        return 'hosts는 있는데 OS DNS 캐시가 오래됐을 때 0.0.0.0이 바로 안 보일 수 있어 캐시만 비웁니다.';
    }
  }

  static AgentFixKind? parse(String? raw) {
    if (raw == null) return null;
    for (final AgentFixKind k in AgentFixKind.values) {
      if (k.wireId == raw) return k;
    }
    return null;
  }
}

/// Row in `diagnostic_agent_log`.
final class DiagnosticAgentLogRow {
  const DiagnosticAgentLogRow({
    required this.id,
    required this.createdAtMs,
    required this.actionKind,
    required this.status,
    required this.reason,
    required this.detailJson,
  });

  final String id;
  final int createdAtMs;
  final String actionKind;
  final String status;
  final String reason;
  final String detailJson;

  factory DiagnosticAgentLogRow.fromMap(Map<String, Object?> m) {
    return DiagnosticAgentLogRow(
      id: m['id']! as String,
      createdAtMs: (m['created_at_ms'] as num?)?.toInt() ?? 0,
      actionKind: m['action_kind']! as String,
      status: m['status']! as String,
      reason: m['reason']! as String,
      detailJson: m['detail_json'] as String? ?? '{}',
    );
  }

  Map<String, Object?> detailMap() {
    try {
      final Object? d = jsonDecode(detailJson);
      if (d is Map) {
        return d.map(
          (Object? k, Object? v) => MapEntry<String, Object?>(k.toString(), v),
        );
      }
    } catch (_) {/* */}
    return const <String, Object?>{};
  }
}

/// Result of [DiagnosticAgentService.analyze].
final class AgentAnalyzeResult {
  const AgentAnalyzeResult({
    required this.findings,
    required this.proposedFixKinds,
    required this.testReportRan,
    this.browserTests = const <BrowserTestResult>[],
  });

  final List<AgentFinding> findings;
  final List<AgentFixKind> proposedFixKinds;
  final bool testReportRan;
  final List<BrowserTestResult> browserTests;
}

/// Outcome of applying a fix.
final class AgentApplyOutcome {
  const AgentApplyOutcome({
    required this.ok,
    required this.message,
    this.detail = const <String, Object?>{},
  });

  final bool ok;
  final String message;
  final Map<String, Object?> detail;
}
