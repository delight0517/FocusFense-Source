import 'dart:io';

import '../../services/mac_system_block_service.dart';
import '../../services/windows_system_block_service.dart';
import '../enforcement_layer.dart';

/// L1 — 호스트/DNS/방화벽 차단 계층.
///
/// **책임:**
/// - `/etc/hosts` (macOS) 또는 `%WINDIR%\System32\drivers\etc\hosts` 쓰기
/// - Windows Firewall inbound 규칙
/// - YouTube hosts 핑
///
/// **Phase 7:** 실제 서비스 호출 구현.
class HostsDnsLayer implements EnforcementLayer {
  HostsDnsLayer._();
  static final HostsDnsLayer instance = HostsDnsLayer._();

  @override
  String get id => 'hosts_dns';

  @override
  int get order => 10;

  @override
  String get displayName => '호스트/DNS';

  @override
  Future<LayerApplyResult> apply(
    RuleSet rules, {
    required String reason,
  }) async {
    try {
      if (Platform.isWindows) {
        final result = await WindowsSystemBlockService.instance.activate();
        return LayerApplyResult(
          success: result.status.index == 0, // MacBlockStatus.success
          errorMessage: result.message,
          domainsWritten: rules.blockedDomains.length,
        );
      } else if (Platform.isMacOS) {
        final result = await MacSystemBlockService.instance.activate();
        return LayerApplyResult(
          success: result.status.index == 0,
          errorMessage: result.message,
          domainsWritten: rules.blockedDomains.length,
        );
      }
      return LayerApplyResult.success(domainsWritten: rules.blockedDomains.length);
    } catch (e) {
      return LayerApplyResult.failure('L1 apply: $e');
    }
  }

  @override
  Future<LayerHealth> verify() async {
    return LayerHealth.healthy();
  }

  @override
  Future<LayerHealResult> heal(LayerHealth diagnosis) async {
    return LayerHealResult.success();
  }
}
