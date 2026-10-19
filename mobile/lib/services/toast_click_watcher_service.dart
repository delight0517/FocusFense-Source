import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../router/app_router.dart';
import '../widgets/active_block_detail_dialog.dart';
import 'app_logger.dart';
import 'windows_tray_controller.dart';

/// Watches for the click-signal the branded block toast drops when the user
/// clicks it (`%LOCALAPPDATA%\SixVPNBlocker\toast_click.signal.json`). On a
/// click we bring the app window to the front and open the
/// [ActiveBlockDetailDialog] so the user immediately sees which block /
/// schedule fired the notice they just tapped.
///
/// Event-driven ([Directory.watch]) — no polling, no child processes — so it
/// sits comfortably under the CLAUDE.md background-work budget. Toast clicks
/// are rare and user-initiated, so we never re-scan on a timer.
final class ToastClickWatcherService {
  ToastClickWatcherService._();
  static final ToastClickWatcherService instance = ToastClickWatcherService._();

  static const String _signalName = 'toast_click.signal.json';

  StreamSubscription<FileSystemEvent>? _sub;
  bool _started = false;
  bool _handling = false;

  Directory get _dir => Directory(
    p.join(Platform.environment['LOCALAPPDATA'] ?? '', 'SixVPNBlocker'),
  );

  File get _signalFile => File(p.join(_dir.path, _signalName));

  void start() {
    if (_started || !Platform.isWindows) return;
    _started = true;
    try {
      _dir.createSync(recursive: true);
      // A signal may have been written while we weren't listening (toast
      // clicked before this service came up). Consume it now.
      unawaited(_consumeIfPresent());
      _sub = _dir
          .watch(events: FileSystemEvent.create | FileSystemEvent.modify)
          .listen(_onEvent, onError: (Object e) {
            AppLogger.instance.warn('toast_click watch error: $e');
          });
    } catch (e) {
      AppLogger.instance.warn('toast_click watcher start failed: $e');
    }
  }

  void stop() {
    _started = false;
    _sub?.cancel();
    _sub = null;
  }

  void _onEvent(FileSystemEvent event) {
    if (p.basename(event.path).toLowerCase() == _signalName) {
      unawaited(_consumeIfPresent());
    }
  }

  Future<void> _consumeIfPresent() async {
    if (_handling) return;
    _handling = true;
    try {
      final Map<String, Object?>? payload = await _readAndDelete();
      if (payload == null) return;
      await _present(payload);
    } catch (e) {
      AppLogger.instance.warn('toast_click consume failed: $e');
    } finally {
      _handling = false;
    }
  }

  /// Reads + deletes the signal file. The watch can fire before PowerShell has
  /// finished writing, so retry the read a couple of times on a bad/empty parse.
  Future<Map<String, Object?>?> _readAndDelete() async {
    final File f = _signalFile;
    for (int attempt = 0; attempt < 3; attempt++) {
      if (!await f.exists()) return null;
      try {
        String raw = await f.readAsString();
        // Strip a UTF-8 BOM if one slipped in.
        if (raw.isNotEmpty && raw.codeUnitAt(0) == 0xFEFF) {
          raw = raw.substring(1);
        }
        if (raw.trim().isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 80));
          continue;
        }
        final Object? decoded = jsonDecode(raw);
        // Delete only once we have a good parse so a partial write can be retried.
        await f.delete().catchError((_) => f);
        return decoded is Map ? decoded.cast<String, Object?>() : null;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }
    }
    // Give up but clear the file so it can't wedge future clicks.
    try {
      await f.delete();
    } catch (_) {}
    return null;
  }

  Future<void> _present(Map<String, Object?> payload) async {
    try {
      await WindowsTrayController.instance.showMainWindow();
    } catch (_) {
      /* best-effort — still try to show the dialog */
    }
    // Let the window finish restoring so the dialog lands on the foregrounded
    // window rather than a hidden one.
    await Future<void>.delayed(const Duration(milliseconds: 120));
    final BuildContext? ctx = appRootNavigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    await ActiveBlockDetailDialog.show(ctx, payload);
  }
}
