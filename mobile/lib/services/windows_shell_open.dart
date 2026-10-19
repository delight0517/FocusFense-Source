import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

/// Opens folders/files with the Windows shell (no console, no CREATE_NO_WINDOW).
abstract final class WindowsShellOpen {
  static Future<void> openFolder(String folderPath) async {
    if (!Platform.isWindows) return;
    final Directory dir = Directory(folderPath);
    if (!await dir.exists()) {
      throw StateError('폴더가 없습니다: $folderPath');
    }
    final int code = _shellExecute(
      operation: 'open',
      file: folderPath,
    );
    if (code <= 32) {
      throw WindowsException(code);
    }
  }

  static Future<void> revealFile(String filePath) async {
    if (!Platform.isWindows) return;
    final File f = File(filePath);
    if (!await f.exists()) {
      throw StateError('파일이 없습니다: $filePath');
    }
    final String explorer = p.join(
      Platform.environment['WINDIR'] ?? r'C:\Windows',
      'explorer.exe',
    );
    final String params = '/select,${filePath.replaceAll('/', r'\')}';
    final int code = _shellExecute(
      operation: 'open',
      file: explorer,
      parameters: params,
    );
    if (code <= 32) {
      throw WindowsException(code);
    }
  }

  /// Launches a GUI `.exe` (Chrome, Edge, Firefox) with [arguments] visible.
  static Future<bool> runGuiExecutable(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    if (!Platform.isWindows) return false;
    if (!await File(executable).exists()) return false;
    final String wd =
        workingDirectory ?? p.dirname(executable);
    final String params = arguments.join(' ');
    final int code = _shellExecute(
      operation: 'open',
      file: executable,
      parameters: params.isEmpty ? null : params,
      directory: wd,
    );
    return code > 32;
  }

  static int _shellExecute({
    required String operation,
    required String file,
    String? parameters,
    String? directory,
  }) {
    final Pointer<Utf16> op = operation.toNativeUtf16();
    final Pointer<Utf16> target = file.toNativeUtf16();
    final Pointer<Utf16>? params =
        parameters != null ? parameters.toNativeUtf16() : nullptr;
    final Pointer<Utf16>? dir =
        directory != null ? directory.toNativeUtf16() : nullptr;
    try {
      return ShellExecute(
        0,
        op,
        target,
        params ?? nullptr,
        dir ?? nullptr,
        SW_SHOWNORMAL,
      );
    } finally {
      calloc.free(op);
      calloc.free(target);
      if (params != null) calloc.free(params);
      if (dir != null) calloc.free(dir);
    }
  }
}
