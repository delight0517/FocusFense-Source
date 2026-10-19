import 'dart:io' show Platform;

import 'package:flutter/services.dart';

import 'app_logger.dart';

/// Shows the read-only game countdown as a non-activating, click-through HUD.
final class GameBudgetOverlayService {
  GameBudgetOverlayService._();
  static final GameBudgetOverlayService instance = GameBudgetOverlayService._();

  static const MethodChannel _channel = MethodChannel(
    'com.sixvpnblocker.app/game_budget_overlay',
  );

  Future<void> show({
    required int processId,
    required int remainingSeconds,
    required String label,
  }) async {
    if (!Platform.isWindows) return;
    try {
      final Object? state = await _channel
          .invokeMethod<Object?>('show', <String, Object>{
            'processId': processId,
            'remainingSeconds': remainingSeconds,
            'label': label,
          });
      AppLogger.instance.info(
        'game_budget_overlay: show pid=$processId native=$state',
      );
    } on MissingPluginException {
      // The native overlay is Windows-only; older/non-Windows runners omit it.
    } catch (error) {
      // A HUD failure must never interrupt foreground accounting.
      AppLogger.instance.warn('game_budget_overlay: show failed: $error');
    }
  }

  Future<void> hide() async {
    if (!Platform.isWindows) return;
    try {
      await _channel.invokeMethod<void>('hide');
    } on MissingPluginException {
      // The native overlay is Windows-only.
    } catch (_) {
      // Hiding is best-effort; the native window also hides on focus change.
    }
  }
}
