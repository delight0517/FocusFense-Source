import 'enforcement_controller.dart';
import 'layers/hosts_dns_layer.dart';
import 'layers/browser_policy_layer.dart';
import 'layers/extension_layer.dart';
import 'layers/network_pac_layer.dart';
import 'layers/process_layer.dart';

/// EnforcementController 초기화 및 계층 등록.
/// 앱 부팅 시 한 번 호출.
Future<void> bootstrapEnforcementController() async {
  final EnforcementController controller = EnforcementController.instance;

  // 5개 계층 등록 (order 순서대로 정렬됨)
  controller.registerLayer(HostsDnsLayer.instance);
  controller.registerLayer(BrowserPolicyLayer.instance);
  controller.registerLayer(ExtensionLayer.instance);
  controller.registerLayer(NetworkPacLayer.instance);
  controller.registerLayer(ProcessLayer.instance);
}
