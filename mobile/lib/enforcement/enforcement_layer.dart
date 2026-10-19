import 'package:flutter/foundation.dart';

/// 하나의 차단 계층 (L1 hosts, L2 policy, L3 extension, L4 PAC, L5 process).
/// 모든 계층은 이 계약을 구현한다.
///
/// **핵심 규칙:** 한 계층의 apply·verify·heal은 반드시 같은 파일/패키지에 산다.
/// 분산 금지.
abstract interface class EnforcementLayer {
  /// 이 계층의 유일한 식별자 ('hosts', 'policy', 'extension', 'pac', 'process').
  String get id;

  /// 적용 순서 (호출 시 이것으로 정렬). L1=10, L2=20, ... L5=50.
  int get order;

  /// 사람이 읽을 수 있는 이름 ('호스트/DNS', '브라우저 정책' 등).
  String get displayName;

  /// 규칙셋을 이 계층에 적용. 멱등성 필수.
  /// 같은 규칙으로 여러 번 호출해도 상태가 변하지 않아야 함.
  Future<LayerApplyResult> apply(
    RuleSet rules, {
    required String reason,
  });

  /// read-only 건강 프로브. 프로세스 스폰 ≤2, TTL 캐시 필수.
  /// 실패해도 예외 throw하지 않음 (graceful degradation).
  Future<LayerHealth> verify();

  /// verify()가 degraded/failed를 반환했을 때만 호출.
  /// 자가 치유 시도. 실패하면 false 반환.
  Future<LayerHealResult> heal(LayerHealth diagnosis);
}

/// 규칙셋 스냅샷 (DB → 계층에 전달).
class RuleSet {
  final List<String> blockedDomains;           // 차단 호스트/도메인
  final List<String> allowedDomains;           // 예외 목록
  final List<String> blockedApps;              // 차단 앱 EXE
  final List<String> blockedYoutubeChannels;   // YouTube 채널 ID
  final List<String> blockedYoutubeVideos;     // YouTube 영상 ID
  final DateTime appliedAt;

  RuleSet({
    required this.blockedDomains,
    required this.allowedDomains,
    required this.blockedApps,
    required this.blockedYoutubeChannels,
    required this.blockedYoutubeVideos,
    DateTime? appliedAt,
  }) : appliedAt = appliedAt ?? DateTime.now();
}

/// 계층 적용 결과.
class LayerApplyResult {
  final bool success;
  final String? errorMessage;
  final int? domainsWritten;
  final int? appsWritten;
  final DateTime appliedAt;

  LayerApplyResult({
    required this.success,
    this.errorMessage,
    this.domainsWritten,
    this.appsWritten,
    DateTime? appliedAt,
  }) : appliedAt = appliedAt ?? DateTime.now();

  factory LayerApplyResult.success({
    int? domainsWritten,
    int? appsWritten,
  }) =>
      LayerApplyResult(
        success: true,
        domainsWritten: domainsWritten,
        appsWritten: appsWritten,
      );

  factory LayerApplyResult.failure(String message) => LayerApplyResult(
        success: false,
        errorMessage: message,
      );
}

/// 계층 건강 상태.
enum LayerHealthStatus {
  healthy,  // 차단 정상 작동
  degraded, // 부분 고장 (한두 도메인만 누락, 등)
  failed,   // 완전 고장
}

class LayerHealth {
  final LayerHealthStatus status;
  final String? message;
  final List<String>? missingDomains;      // degraded일 때 누락 항목
  final bool? requiresHealing;
  final DateTime checkedAt;

  LayerHealth({
    required this.status,
    this.message,
    this.missingDomains,
    bool? requiresHealing,
    DateTime? checkedAt,
  })  : requiresHealing = requiresHealing ?? (status != LayerHealthStatus.healthy),
        checkedAt = checkedAt ?? DateTime.now();

  factory LayerHealth.healthy() => LayerHealth(
        status: LayerHealthStatus.healthy,
      );

  factory LayerHealth.degraded({
    required String message,
    List<String>? missingDomains,
  }) =>
      LayerHealth(
        status: LayerHealthStatus.degraded,
        message: message,
        missingDomains: missingDomains,
      );

  factory LayerHealth.failed(String message) => LayerHealth(
        status: LayerHealthStatus.failed,
        message: message,
      );
}

/// 계층 치유 결과.
class LayerHealResult {
  final bool success;
  final String? message;
  final DateTime healedAt;

  LayerHealResult({
    required this.success,
    this.message,
    DateTime? healedAt,
  }) : healedAt = healedAt ?? DateTime.now();

  factory LayerHealResult.success([String? message]) => LayerHealResult(
        success: true,
        message: message,
      );

  factory LayerHealResult.failed(String message) => LayerHealResult(
        success: false,
        message: message,
      );
}

/// 모든 계층의 종합 건강 상태.
class EnforcementHealth {
  final Map<String, LayerHealth> layerStates; // layer.id → health
  final bool allHealthy;
  final List<String> degradedLayers;
  final DateTime checkedAt;

  EnforcementHealth({
    required this.layerStates,
    DateTime? checkedAt,
  })  : checkedAt = checkedAt ?? DateTime.now(),
        allHealthy = !layerStates.values
            .any((h) => h.status != LayerHealthStatus.healthy),
        degradedLayers = layerStates.entries
            .where((e) => e.value.status != LayerHealthStatus.healthy)
            .map((e) => e.key)
            .toList();

  bool isHealthyForLayer(String layerId) =>
      layerStates[layerId]?.status == LayerHealthStatus.healthy ?? false;
}

/// 전체 적용/검증 보고서.
@immutable
class EnforcementReport {
  final bool overallSuccess;
  final Map<String, LayerApplyResult> layerResults; // layer.id → result
  final DateTime appliedAt;
  final String? failureReason;

  EnforcementReport({
    required this.overallSuccess,
    required this.layerResults,
    this.failureReason,
    DateTime? appliedAt,
  }) : appliedAt = appliedAt ?? DateTime.now();
}
