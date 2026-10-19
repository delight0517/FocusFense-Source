import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

import '../../services/block_sync_service.dart';
import '../../services/windows_hidden_process.dart';
import '../enforcement_layer.dart';

/// L5 — 프로세스/앱 차단 계층.
class ProcessLayer implements EnforcementLayer {
  ProcessLayer._();
  static final ProcessLayer instance = ProcessLayer._();

  static const String _kIfeoSubKeyPrefix =
      r'SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\';

  @override
  String get id => 'process';

  @override
  int get order => 50;

  @override
  String get displayName => '앱/프로세스';

  @override
  Future<LayerApplyResult> apply(
    RuleSet rules, {
    required String reason,
  }) async {
    try {
      if (Platform.isWindows || Platform.isMacOS) {
        BlockSyncService.instance.syncAppTargetsNow();
      }
      return LayerApplyResult.success(appsWritten: rules.blockedApps.length);
    } catch (e) {
      return LayerApplyResult.failure('L5: $e');
    }
  }

  /// Phase 6: on top of the always-on 30s poll+kill, exes that qualify are
  /// also hijacked at launch via IFEO (see `WindowsAppBlockService`). This
  /// verifies the registry actually reflects the sidecar it wrote — a
  /// mismatch means the elevated maintain task hasn't caught up yet (or
  /// failed), but the poll+kill loop still protects in the meantime, so a
  /// mismatch is `degraded`, never `failed`.
  @override
  Future<LayerHealth> verify() async {
    if (!Platform.isWindows) return LayerHealth.healthy();
    try {
      final String sidecarPath = p.join(
        Platform.environment['LOCALAPPDATA'] ?? '',
        'SixVPNBlocker',
        'process_layer_active_exes.json',
      );
      final File sidecar = File(sidecarPath);
      if (!await sidecar.exists()) return LayerHealth.healthy();

      Map<String, dynamic> parsed;
      try {
        parsed = jsonDecode(await sidecar.readAsString()) as Map<String, dynamic>;
      } catch (e) {
        return LayerHealth.degraded(message: 'IFEO sidecar JSON 파싱 실패: $e');
      }
      final Map<String, dynamic> activeExes =
          (parsed['activeExes'] as Map<String, dynamic>?) ?? <String, dynamic>{};
      if (activeExes.isEmpty) return LayerHealth.healthy();

      final List<String> missing = <String>[];
      for (final String exe in activeExes.keys) {
        final String? dbg = _readHklmString('$_kIfeoSubKeyPrefix$exe', 'Debugger');
        if (dbg == null || !dbg.contains('BlockedBrowserToastLauncher')) {
          missing.add(exe);
        }
      }
      if (missing.isEmpty) return LayerHealth.healthy();
      return LayerHealth.degraded(
        message: 'IFEO 실행-차단 미등록(30초 폴링+kill 안전망은 계속 동작): ${missing.join(", ")}',
        missingDomains: missing,
      );
    } catch (e) {
      return LayerHealth.degraded(message: 'L5 verify 오류: $e');
    }
  }

  @override
  Future<LayerHealResult> heal(LayerHealth diagnosis) async {
    if (!Platform.isWindows) return LayerHealResult.success();
    try {
      // The registry write itself needs admin rights; this just nudges the
      // already-elevated maintain task (no new UAC prompt — it was granted
      // Highest RunLevel once at first apply) to re-sync from the sidecar.
      final String schtasks = p.join(
        Platform.environment['WINDIR'] ?? r'C:\Windows',
        'System32',
        'schtasks.exe',
      );
      final ProcessResult r = await windowsRunHidden(schtasks, <String>[
        '/Run',
        '/TN',
        'SixVPNBlockerElevatedMaintain',
      ]);
      if (r.exitCode == 0) {
        return LayerHealResult.success('elevated maintain task triggered');
      }
      return LayerHealResult.failed(
        'schtasks /Run 실패 (exit ${r.exitCode}) — 30초 폴링+kill 안전망은 계속 동작',
      );
    } catch (e) {
      return LayerHealResult.failed('L5 heal 오류: $e — 30초 폴링+kill 안전망은 계속 동작');
    }
  }

  /// Reads a REG_SZ value from HKLM without spawning `reg.exe` — this key is
  /// world-readable (no elevation needed for KEY_QUERY_VALUE), unlike writing
  /// it. Returns null on any failure (missing key/value, wrong type, etc.).
  static String? _readHklmString(String subKey, String valueName) {
    final Pointer<HKEY> phk = calloc<HKEY>();
    try {
      final Pointer<Utf16> subKeyPtr = subKey.toNativeUtf16();
      final int opened = RegOpenKeyEx(
        HKEY_LOCAL_MACHINE,
        subKeyPtr,
        0,
        KEY_QUERY_VALUE,
        phk,
      );
      calloc.free(subKeyPtr);
      if (opened != ERROR_SUCCESS) return null;

      final int hKey = phk.value;
      try {
        final Pointer<Uint32> typePtr = calloc<Uint32>();
        final Pointer<Uint32> sizePtr = calloc<Uint32>();
        final Pointer<Utf16> valueNamePtr = valueName.toNativeUtf16();
        try {
          int rc = RegQueryValueEx(
            hKey,
            valueNamePtr,
            nullptr,
            typePtr,
            nullptr,
            sizePtr,
          );
          if (rc != ERROR_SUCCESS || sizePtr.value == 0) return null;
          final Pointer<Uint8> dataPtr = calloc<Uint8>(sizePtr.value);
          try {
            rc = RegQueryValueEx(
              hKey,
              valueNamePtr,
              nullptr,
              typePtr,
              dataPtr,
              sizePtr,
            );
            if (rc != ERROR_SUCCESS) return null;
            return dataPtr.cast<Utf16>().toDartString();
          } finally {
            calloc.free(dataPtr);
          }
        } finally {
          calloc.free(valueNamePtr);
          calloc.free(typePtr);
          calloc.free(sizePtr);
        }
      } finally {
        RegCloseKey(hKey);
      }
    } catch (_) {
      return null;
    } finally {
      calloc.free(phk);
    }
  }
}
