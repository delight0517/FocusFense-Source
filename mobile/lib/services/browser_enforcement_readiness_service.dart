import 'dart:io';

import 'brave_extension_install_service.dart';
import 'chromium_derivative_extension_service.dart';
import 'windows_extension_guard_service.dart';

/// Per-browser extension readiness — drives YouTube apex vs list-only URLBlocklist
/// and kill-guard / 현황판 「사용 가능」 판정.
final class BrowserEnforcementReadiness {
  const BrowserEnforcementReadiness({
    required this.browserId,
    required this.extensionReady,
    required this.policyReady,
  });

  final String browserId;
  final bool extensionReady;
  final bool policyReady;

  /// When true, YouTube site-wide apex rows stay out of URLBlocklist; the MV3
  /// extension + schedule channel/video patterns handle YouTube.
  bool get youtubeListOnlyMode => extensionReady && policyReady;
}

/// Snapshot of which installed browsers have the Six VPN extension active.
final class BrowserEnforcementReadinessService {
  BrowserEnforcementReadinessService._();
  static final BrowserEnforcementReadinessService instance =
      BrowserEnforcementReadinessService._();

  Map<String, BrowserEnforcementReadiness>? _cache;
  DateTime? _cacheAt;
  static const Duration _ttl = Duration(seconds: 45);

  Future<Map<String, BrowserEnforcementReadiness>> snapshot({
    bool force = false,
  }) async {
    if (!force &&
        _cache != null &&
        _cacheAt != null &&
        DateTime.now().difference(_cacheAt!) < _ttl) {
      return _cache!;
    }
    final Map<String, BrowserEnforcementReadiness> out =
        <String, BrowserEnforcementReadiness>{};
    if (!Platform.isWindows) {
      _cache = out;
      _cacheAt = DateTime.now();
      return out;
    }

    final ExtensionPolicyVerifyResult ext =
        await WindowsExtensionGuardService.verifyAllPolicies();
    final BraveExtensionVerifyResult brave = await BraveExtensionInstallService
        .instance
        .verify();
    final Map<String, DerivativeExtensionVerifyResult> derivatives =
        await ChromiumDerivativeExtensionService.instance.verifyInstalled();

    void put(String id, bool extensionReady, {bool? policyReady}) {
      out[id] = BrowserEnforcementReadiness(
        browserId: id,
        extensionReady: extensionReady,
        policyReady: policyReady ?? extensionReady,
      );
    }

    put(
      'chrome',
      ext.chromeEnforcementReady,
      policyReady:
          ext.chromeHklmOk || ext.chromeHkcuOk || ext.chromeUserInstallOk,
    );
    put(
      'edge',
      ext.edgeEnforcementReady,
      policyReady: ext.edgeHklmOk || ext.edgeHkcuOk || ext.edgeUserInstallOk,
    );
    put('firefox', ext.firefoxEnforcementReady);
    put('brave', brave.extensionReady, policyReady: brave.policyReady);
    for (final MapEntry<String, DerivativeExtensionVerifyResult> e
        in derivatives.entries) {
      put(e.key, e.value.extensionReady, policyReady: e.value.policyReady);
    }

    _cache = out;
    _cacheAt = DateTime.now();
    return out;
  }

  Future<bool> extensionReadyFor(String browserId) async {
    final Map<String, BrowserEnforcementReadiness> snap = await snapshot();
    return snap[browserId]?.extensionReady ?? false;
  }

  void invalidate() {
    _cache = null;
    _cacheAt = null;
  }
}
