import 'dart:io' show Platform;
import 'dart:ffi';

import 'package:flutter/services.dart';
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'app_logger.dart';

/// Snapshot of [NSWorkspace.frontmostApplication] (macOS only).
final class FrontmostAppSnapshot {
  const FrontmostAppSnapshot({
    required this.bundleId,
    required this.localizedName,
    required this.processIdentifier,
    this.executablePath,
  });

  final String bundleId;
  final String localizedName;
  final int processIdentifier;

  /// Ephemeral Windows path used for local game classification only.
  final String? executablePath;
}

/// Native bridge for reading the frontmost app — used by [UsageTrackingService].
final class FrontmostAppChannel {
  FrontmostAppChannel._();
  static final FrontmostAppChannel instance = FrontmostAppChannel._();

  static const MethodChannel _channel = MethodChannel(
    'com.sixvpnblocker.app/frontmost',
  );

  Future<FrontmostAppSnapshot?> getFrontmost() async {
    if (Platform.isWindows) return _windowsFrontmost();
    if (!Platform.isMacOS) return null;
    try {
      final Object? raw = await _channel.invokeMethod<Object?>('getFrontmost');
      if (raw is! Map) return null;
      final Map<Object?, Object?> m = raw;
      return FrontmostAppSnapshot(
        bundleId: '${m['bundleId'] ?? ''}',
        localizedName: '${m['localizedName'] ?? ''}',
        processIdentifier: (m['processIdentifier'] as int?) ?? 0,
      );
    } on MissingPluginException catch (e) {
      AppLogger.instance.warn('frontmost channel missing: $e');
      return null;
    } catch (e) {
      AppLogger.instance.warn('frontmost get failed: $e');
      return null;
    }
  }

  FrontmostAppSnapshot? _windowsFrontmost() {
    final hwnd = GetForegroundWindow();
    if (hwnd == 0) return null;
    final pid = calloc<Uint32>();
    final size = calloc<Uint32>()..value = 32768;
    final buffer = calloc<Uint16>(32768).cast<Utf16>();
    int process = 0;
    try {
      GetWindowThreadProcessId(hwnd, pid);
      if (pid.value == 0) return null;
      process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid.value);
      if (process == 0 ||
          QueryFullProcessImageName(process, 0, buffer, size) == 0) {
        return null;
      }
      final path = buffer.toDartString(length: size.value);
      final exe = path.replaceAll('\\', '/').split('/').last.toLowerCase();
      if (exe.isEmpty) return null;
      return FrontmostAppSnapshot(
        bundleId: 'win|$exe',
        localizedName: exe,
        processIdentifier: pid.value,
        executablePath: path,
      );
    } finally {
      if (process != 0) CloseHandle(process);
      calloc.free(buffer);
      calloc.free(size);
      calloc.free(pid);
    }
  }
}
