import 'dart:io';

import '../../services/universal_browser_block_service.dart';
import '../enforcement_layer.dart';

/// L4 — 네트워크 PAC 계층.
class NetworkPacLayer implements EnforcementLayer {
  NetworkPacLayer._();
  static final NetworkPacLayer instance = NetworkPacLayer._();

  @override
  String get id => 'pac';

  @override
  int get order => 40;

  @override
  String get displayName => 'PAC 프록시';

  @override
  Future<LayerApplyResult> apply(
    RuleSet rules, {
    required String reason,
  }) async {
    try {
      if (Platform.isWindows) {
        UniversalBrowserBlockService.instance.scheduleSync(reason: reason);
      }
      return LayerApplyResult.success();
    } catch (e) {
      return LayerApplyResult.failure('L4: $e');
    }
  }

  @override
  Future<LayerHealth> verify() async => LayerHealth.healthy();

  @override
  Future<LayerHealResult> heal(LayerHealth diagnosis) async =>
      LayerHealResult.success();
}
