import 'dart:async';

import 'enforcement_layer.dart';
import '../services/windows_protection_mode_prefs.dart';

/// 차단 엔진의 유일한 진입점. 모든 차단 적용·검증·치유는 여기를 통한다.
///
/// **역할:**
/// - 5개 계층을 단일 오케스트레이터로 관리
/// - requestApply() 디바운스·중복실행 방지 (기존 block_sync의 책임)
/// - 모든 프로브 통합 (verify)
/// - 자가 치유 통합 (heal)
///
/// **현재 상태 (Phase 1):** 얇은 파사드. 기존 서비스를 호출하기만 함.
/// Phase 2부터 각 계층을 구체 구현으로 교체.
final class EnforcementController {
  EnforcementController._();
  static final EnforcementController instance = EnforcementController._();

  /// 등록된 5개 계층 (order 순서로 정렬).
  final List<EnforcementLayer> _layers = <EnforcementLayer>[];

  /// 현재 규칙셋 (마지막 apply에 사용된 것).
  RuleSet? _currentRules;

  /// 마지막 apply 결과.
  EnforcementReport? _lastReport;

  /// 최근 verify 결과 (캐시, TTL 관리).
  EnforcementHealth? _lastHealth;
  DateTime? _lastHealthCheckAt;
  static const Duration _healthCheckTtl = Duration(seconds: 90);

  /// 진행 중인 apply 작업 (중복실행 방지).
  Future<EnforcementReport>? _applyInProgress;

  /// requestApply() 디바운스 타이머.
  Timer? _debounceTimer;
  static const Duration _debounceDelay = Duration(milliseconds: 1500);

  /// 컨트롤러 활성화 여부. false면 requestApply 무시.
  bool _enabled = !WindowsProtectionModePrefs.isProtectionExplicitlyOff;

  bool get enabled =>
      _enabled && !WindowsProtectionModePrefs.isProtectionExplicitlyOff;
  set enabled(bool value) => _enabled = value;

  /// 등록된 계층 목록 (order 순).
  List<EnforcementLayer> get layers => List.unmodifiable(_layers);

  /// 마지막 apply 결과.
  EnforcementReport? get lastReport => _lastReport;

  /// 캐시된 건강 상태 (TTL 내).
  EnforcementHealth? get cachedHealth => _lastHealth;

  /// 계층 등록 (한 번만, 초기화 시).
  void registerLayer(EnforcementLayer layer) {
    if (_layers.any((l) => l.id == layer.id)) {
      throw ArgumentError('Duplicate layer: ${layer.id}');
    }
    _layers.add(layer);
    _layers.sort((a, b) => a.order.compareTo(b.order));
  }

  /// 규칙셋 업데이트 (DB 변경 후 호출).
  Future<void> updateRules(RuleSet newRules) async {
    _currentRules = newRules;
  }

  /// 규칙 변경 감지 → 디바운스된 apply 예약.
  /// (기존 block_sync.requestApply()의 정신을 유지.)
  void requestApply({String reason = 'rules'}) {
    if (!enabled) return;

    _debounceTimer?.cancel();
    _debounceTimer = Timer(_debounceDelay, () {
      unawaited(applyNow(reason: reason));
    });
  }

  /// 즉시 적용 (디바운스 우회, 유저가 명시 요청했을 때).
  /// 반환: 전체 적용 결과.
  Future<EnforcementReport> applyNow({String reason = 'manual'}) async {
    if (!enabled) {
      return EnforcementReport(
        overallSuccess: false,
        layerResults: {},
        failureReason: 'controller disabled',
      );
    }

    // 중복 apply 방지.
    if (_applyInProgress != null) {
      return _applyInProgress!;
    }

    final Completer<EnforcementReport> completer =
        Completer<EnforcementReport>();
    _applyInProgress = completer.future;

    try {
      final RuleSet rules =
          _currentRules ??
          RuleSet(
            blockedDomains: <String>[],
            allowedDomains: <String>[],
            blockedApps: <String>[],
            blockedYoutubeChannels: <String>[],
            blockedYoutubeVideos: <String>[],
          );

      final Map<String, LayerApplyResult> results =
          <String, LayerApplyResult>{};
      bool overallSuccess = true;

      for (final EnforcementLayer layer in _layers) {
        try {
          final LayerApplyResult result = await layer.apply(
            rules,
            reason: reason,
          );
          results[layer.id] = result;
          if (!result.success) {
            overallSuccess = false;
          }
        } catch (e) {
          results[layer.id] = LayerApplyResult.failure(
            'Layer ${layer.id} apply failed: $e',
          );
          overallSuccess = false;
        }
      }

      final EnforcementReport report = EnforcementReport(
        overallSuccess: overallSuccess,
        layerResults: results,
        failureReason: overallSuccess ? null : 'one or more layers failed',
      );
      _lastReport = report;
      _lastHealthCheckAt = null; // 캐시 무효화 (규칙 변경됐으니)
      return report;
    } finally {
      _applyInProgress = null;
      if (!completer.isCompleted) {
        completer.complete(
          _lastReport ??
              EnforcementReport(
                overallSuccess: false,
                layerResults: {},
                failureReason: 'unknown error',
              ),
        );
      }
    }
  }

  /// 모든 계층 건강 검사 (프로브 통합).
  /// 캐시 활용 (TTL 90초).
  Future<EnforcementHealth> verifyAll({bool forceRefresh = false}) async {
    if (!forceRefresh) {
      final DateTime? lastCheck = _lastHealthCheckAt;
      if (lastCheck != null &&
          DateTime.now().difference(lastCheck) < _healthCheckTtl) {
        return _lastHealth ?? EnforcementHealth(layerStates: {});
      }
    }

    final Map<String, LayerHealth> states = <String, LayerHealth>{};

    for (final EnforcementLayer layer in _layers) {
      try {
        final LayerHealth health = await layer.verify();
        states[layer.id] = health;
      } catch (e) {
        states[layer.id] = LayerHealth.failed(
          'Layer ${layer.id} verify failed: $e',
        );
      }
    }

    final EnforcementHealth health = EnforcementHealth(layerStates: states);
    _lastHealth = health;
    _lastHealthCheckAt = DateTime.now();
    return health;
  }

  /// 저하된 계층들의 자가 치유 시도.
  Future<bool> healDegraded() async {
    final EnforcementHealth health = await verifyAll();

    bool anyHealed = false;
    for (final String layerId in health.degradedLayers) {
      final EnforcementLayer layer = _layers.firstWhere((l) => l.id == layerId);

      final LayerHealth diagnosis = health.layerStates[layerId]!;
      try {
        final LayerHealResult result = await layer.heal(diagnosis);
        if (result.success) {
          anyHealed = true;
          _lastHealthCheckAt = null; // 캐시 무효화
        }
      } catch (e) {
        // 치유 실패는 silent (graceful degradation).
      }
    }

    return anyHealed;
  }

  /// 정리 (앱 종료 시).
  void dispose() {
    _debounceTimer?.cancel();
  }
}
