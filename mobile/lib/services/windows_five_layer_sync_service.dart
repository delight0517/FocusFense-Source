import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'windows_desktop_rebuild_service.dart';
import 'windows_firewall_block_service.dart';
import 'windows_hidden_process.dart';

/// Keeps layer-5 artifacts (state JSON + admin BAT) in sync without UAC.
final class WindowsFiveLayerSyncService {
  WindowsFiveLayerSyncService._();
  static final WindowsFiveLayerSyncService instance =
      WindowsFiveLayerSyncService._();

  DateTime? _lastAt;
  static const Duration _kGap = Duration(minutes: 10);

  /// Debounced: prepare firewall state + optional PS sync script.
  Future<void> syncArtifacts({String reason = 'rules'}) async {
    if (!Platform.isWindows) return;
    final DateTime now = DateTime.now();
    if (_lastAt != null && now.difference(_lastAt!) < _kGap) return;
    _lastAt = now;
    try {
      await WindowsFirewallBlockService.instance.prepareStateOnly();
      await _runSyncScriptIfPresent();
      AppLogger.instance.info('five_layer_sync: artifacts ($reason)');
    } catch (e) {
      AppLogger.instance.warn('five_layer_sync failed', error: e);
    }
  }

  Future<void> _runSyncScriptIfPresent() async {
    String? root = await WindowsDesktopRebuildPrefs.getMobileRoot();
    root ??= await WindowsDesktopRebuildService.tryInferMobileRoot();
    if (root == null || root.isEmpty) return;
    final String script = p.join(root, 'tools', 'Sync-FiveLayerFirewall.ps1');
    if (!await File(script).exists()) return;
    final String ps = p.join(
      Platform.environment['WINDIR'] ?? r'C:\Windows',
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
    await windowsRunHidden(
      ps,
      <String>[
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        script,
        '-Quiet',
      ],
    );
  }
}
