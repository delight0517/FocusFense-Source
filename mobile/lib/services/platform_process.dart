import 'dart:io';

import 'windows_hidden_process.dart';
import 'windows_shell_open.dart';

/// Cross-platform process helpers. On Windows, console tools use
/// [windowsRunHidden] / [windowsStartDetachedHidden] — no black CMD flash.
abstract final class PlatformProcess {
  static Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
  }) async {
    if (Platform.isWindows) {
      return windowsRunHidden(
        executable,
        arguments,
        workingDirectory: workingDirectory,
      );
    }
    return Process.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
    );
  }

  static Future<void> openFolder(String path) async {
    if (Platform.isMacOS) {
      await Process.run('open', <String>[path]);
      return;
    }
    if (Platform.isWindows) {
      await WindowsShellOpen.openFolder(path);
    }
  }

  static Future<void> revealFileInFolder(String filePath) async {
    if (Platform.isMacOS) {
      await Process.run('open', <String>['-R', filePath]);
      return;
    }
    if (Platform.isWindows) {
      await WindowsShellOpen.revealFile(filePath);
    }
  }
}
