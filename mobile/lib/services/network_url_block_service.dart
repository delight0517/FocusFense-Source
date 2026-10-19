import 'dart:io';

import 'app_logger.dart';
import 'block_activity_log_service.dart';
import 'universal_browser_block_service.dart';
import 'windows_emergency_block_service.dart';

/// Layer 0 — block URLs at the **network / proxy / policy** layer (no extension).
///
/// * PAC (`sixvpn_block.pac`) → dead proxy `127.0.0.1:9` (connection refused)
/// * Chrome/Edge `URLBlocklist` (HKCU) → native “관리자가 차단” page
/// * Keyword paths via [ConnectionUrlBlockPatternBuilder] (PAC + URLBlocklist)
/// * Firefox `WebsiteFilter` + PAC in profiles
/// * hosts/NRPT after UAC — **domains only** (not `/path` or `?query`)
final class NetworkUrlBlockService {
  NetworkUrlBlockService._();
  static final NetworkUrlBlockService instance = NetworkUrlBlockService._();

  /// Push active rules into PAC + HKCU URLBlocklist immediately.
  Future<NetworkUrlBlockResult> enforceNow({String reason = 'manual'}) async {
    if (!Platform.isWindows) {
      return const NetworkUrlBlockResult(
        ok: false,
        message: 'Windows 전용',
        pacActive: false,
        hkcuOk: false,
      );
    }
    final UniversalBlockResult u =
        await UniversalBrowserBlockService.instance.syncNow(reason: reason);
    final EmergencyBlockResult pac =
        await WindowsEmergencyBlockService.instance.readStatus();

    final bool ok = u.ok;
    final String msg = ok
        ? '네트워크 차단 적용됨 — PAC·URL목록 (확장 없이도 Chrome/Edge/Firefox)'
        : u.message;

    BlockActivityLogService.instance.record(
      kind: BlockActivityKind.protection,
      message: msg,
      data: <String, Object?>{
        'reason': reason,
        'pac': pac.pacApplied,
        'universal': u.ok,
      },
      debounceKey: 'network_url_block',
    );
    AppLogger.instance.info(
      'network_url_block [$reason] pac=${pac.pacApplied} universal=${u.ok}',
    );

    return NetworkUrlBlockResult(
      ok: ok,
      message: msg,
      pacActive: pac.pacApplied,
      hkcuOk: u.ok,
      hkcuPatternCount: 0,
    );
  }
}

final class NetworkUrlBlockResult {
  const NetworkUrlBlockResult({
    required this.ok,
    required this.message,
    required this.pacActive,
    required this.hkcuOk,
    this.hkcuPatternCount = 0,
  });

  final bool ok;
  final String message;
  final bool pacActive;
  final bool hkcuOk;
  final int hkcuPatternCount;
}
