import 'dart:io';

import '../../services/extension_rules_snapshot_service.dart';
import '../enforcement_layer.dart';

/// L3 — 확장 계층.
class ExtensionLayer implements EnforcementLayer {
  ExtensionLayer._();
  static final ExtensionLayer instance = ExtensionLayer._();

  @override
  String get id => 'extension';

  @override
  int get order => 30;

  @override
  String get displayName => '확장 프로그램';

  @override
  Future<LayerApplyResult> apply(
    RuleSet rules, {
    required String reason,
  }) async {
    try {
      if (Platform.isWindows) {
        await ExtensionRulesSnapshotService.instance.writeToChromePayload();
      }
      return LayerApplyResult.success();
    } catch (e) {
      return LayerApplyResult.failure('L3: $e');
    }
  }

  @override
  Future<LayerHealth> verify() async => LayerHealth.healthy();

  @override
  Future<LayerHealResult> heal(LayerHealth diagnosis) async =>
      LayerHealResult.success();
}
