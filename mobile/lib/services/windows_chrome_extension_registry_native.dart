import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'app_logger.dart';
import 'extension_guard_prefs.dart';

/// Writes Chrome/Edge per-user extension keys via Win32 (no reg.exe subprocess).
abstract final class WindowsChromeExtensionRegistryNative {
  static bool? _policyWriteCache;
  static DateTime? _policyWriteCacheAt;
  static const Duration _policyProbeTtl = Duration(hours: 6);

  /// False when HKCU `Policies\Google\Chrome` is locked (corp GPO / security).
  static Future<bool> canWriteChromePolicies() async {
    if (!Platform.isWindows) return false;
    final DateTime now = DateTime.now();
    if (_policyWriteCache != null &&
        _policyWriteCacheAt != null &&
        now.difference(_policyWriteCacheAt!) < _policyProbeTtl) {
      return _policyWriteCache!;
    }
    final bool ok = _probePolicyKey(
      hive: HKEY_CURRENT_USER,
      subKey: r'Software\Policies\Google\Chrome',
    );
    _policyWriteCache = ok;
    _policyWriteCacheAt = now;
    return ok;
  }

  static bool _probePolicyKey({required int hive, required String subKey}) {
    final Pointer<HKEY> phkResult = calloc<HKEY>();
    try {
      final Pointer<Utf16> subKeyPtr = subKey.toNativeUtf16();
      final int r = RegCreateKeyEx(
        hive,
        subKeyPtr,
        0,
        nullptr,
        REG_OPTION_NON_VOLATILE,
        KEY_SET_VALUE,
        nullptr,
        phkResult,
        nullptr,
      );
      calloc.free(subKeyPtr);
      if (r != ERROR_SUCCESS) return false;
      RegCloseKey(phkResult.value);
      return true;
    } catch (_) {
      return false;
    } finally {
      calloc.free(phkResult);
    }
  }

  static Future<NativeRegistryWriteResult> registerChromeAndEdge({
    required String extensionId,
    required String extensionFolder,
    required String version,
  }) async {
    if (!Platform.isWindows) {
      return const NativeRegistryWriteResult(
        chromeOk: false,
        edgeOk: false,
        detail: 'Windows 전용',
      );
    }
    final String folder = extensionFolder.trim();
    if (!await File('$folder\\manifest.json').exists() &&
        !await File('$folder/manifest.json').exists()) {
      return NativeRegistryWriteResult(
        chromeOk: false,
        edgeOk: false,
        detail: 'manifest.json 없음: $folder',
      );
    }

    final bool chromeOk = _writeExtensionKey(
      hive: HKEY_CURRENT_USER,
      subKey: 'Software\\Google\\Chrome\\Extensions\\$extensionId',
      folderPath: folder,
      version: version,
      label: 'Chrome',
    );
    final bool edgeOk = _writeExtensionKey(
      hive: HKEY_CURRENT_USER,
      subKey: 'Software\\Microsoft\\Edge\\Extensions\\$extensionId',
      folderPath: folder,
      version: version,
      label: 'Edge',
    );
    final bool braveOk = _writeExtensionKey(
      hive: HKEY_CURRENT_USER,
      subKey:
          'Software\\BraveSoftware\\Brave-Browser\\Extensions\\$extensionId',
      folderPath: folder,
      version: version,
      label: 'Brave',
    );

    return NativeRegistryWriteResult(
      chromeOk: chromeOk,
      edgeOk: edgeOk,
      braveOk: braveOk,
      detail: 'Chrome: $chromeOk · Edge: $edgeOk · Brave: $braveOk → $folder',
    );
  }

  static Future<bool> registerBrave({
    required String extensionId,
    required String extensionFolder,
    required String version,
  }) async {
    if (!Platform.isWindows) return false;
    return _writeExtensionKey(
      hive: HKEY_CURRENT_USER,
      subKey:
          'Software\\BraveSoftware\\Brave-Browser\\Extensions\\$extensionId',
      folderPath: extensionFolder,
      version: version,
      label: 'Brave',
    );
  }

  /// Vivaldi · Whale · Opera — per-user Extensions key.
  static Future<bool> registerDerivativeUserKey({
    required String userExtSubKey,
    required String extensionId,
    required String extensionFolder,
    required String version,
    required String label,
  }) async {
    if (!Platform.isWindows) return false;
    return _writeExtensionKey(
      hive: HKEY_CURRENT_USER,
      subKey: '$userExtSubKey\\$extensionId',
      folderPath: extensionFolder,
      version: version,
      label: label,
    );
  }

  static bool _writeExtensionKey({
    required int hive,
    required String subKey,
    required String folderPath,
    required String version,
    required String label,
  }) {
    if (ExtensionGuardPrefs.instance.isRegistryRootExplicitlyDisabled(subKey)) {
      return false;
    }
    final Pointer<HKEY> phkResult = calloc<HKEY>();
    try {
      final Pointer<Utf16> subKeyPtr = subKey.toNativeUtf16();
      int r = RegCreateKeyEx(
        hive,
        subKeyPtr,
        0,
        nullptr,
        REG_OPTION_NON_VOLATILE,
        KEY_SET_VALUE,
        nullptr,
        phkResult,
        nullptr,
      );
      calloc.free(subKeyPtr);
      if (r != ERROR_SUCCESS) {
        AppLogger.instance.warn(
          'native reg $label RegCreateKeyEx failed: $r ($subKey)',
        );
        return false;
      }

      final int hKey = phkResult.value;

      final bool pathOk = _setSz(hKey, nullptr, folderPath);
      final Pointer<Utf16> verName = 'version'.toNativeUtf16();
      final bool verOk = _setSz(hKey, verName, version);
      calloc.free(verName);

      RegCloseKey(hKey);
      return pathOk && verOk;
    } catch (e) {
      AppLogger.instance.warn('native reg $label exception', error: e);
      return false;
    } finally {
      calloc.free(phkResult);
    }
  }

  static bool _setSz(int hKey, Pointer<Utf16>? valueName, String data) {
    final Pointer<Utf16> dataPtr = data.toNativeUtf16();
    final int byteLen = (data.length + 1) * 2;
    final int r = RegSetValueEx(
      hKey,
      valueName ?? nullptr,
      0,
      REG_SZ,
      dataPtr.cast<Uint8>(),
      byteLen,
    );
    calloc.free(dataPtr);
    if (r != ERROR_SUCCESS) {
      AppLogger.instance.warn('native reg RegSetValueEx failed: $r');
      return false;
    }
    return true;
  }
}

final class NativeRegistryWriteResult {
  const NativeRegistryWriteResult({
    required this.chromeOk,
    required this.edgeOk,
    required this.detail,
    this.braveOk = false,
  });

  final bool chromeOk;
  final bool edgeOk;
  final bool braveOk;
  final String detail;

  bool get anyOk => chromeOk || edgeOk || braveOk;
}
