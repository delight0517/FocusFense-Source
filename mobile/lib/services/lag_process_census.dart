import 'dart:io';

import 'package:path/path.dart' as p;

import 'windows_hidden_process.dart';

/// Counts common child processes that indicate a spawn-storm (reg/ps/conhost).
/// Shared by CPU spike, UI stall, and freeze detectors — one implementation.
final class LagProcessCensus {
  LagProcessCensus._();

  static Future<Map<String, int>> countWindows() async {
    if (!Platform.isWindows) return const <String, int>{};
    try {
      return await _count();
    } catch (_) {
      return const <String, int>{};
    }
  }

  static Future<Map<String, int>> _count() async {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final String tasklist = p.join(windir, 'System32', 'tasklist.exe');
    try {
      final ProcessResult r = await windowsRunHidden(
        tasklist,
        <String>['/fo', 'csv', '/nh'],
      );
      if (r.exitCode != 0) return const <String, int>{};
      int reg = 0, ps = 0, conhost = 0, whoami = 0, tasklistCount = 0;
      for (final String line in '${r.stdout}'.split('\n')) {
        final String low = line.toLowerCase();
        if (low.startsWith('"reg.exe"')) {
          reg++;
        } else if (low.startsWith('"powershell.exe"')) {
          ps++;
        } else if (low.startsWith('"conhost.exe"')) {
          conhost++;
        } else if (low.startsWith('"whoami.exe"')) {
          whoami++;
        } else if (low.startsWith('"tasklist.exe"')) {
          tasklistCount++;
        }
      }
      return <String, int>{
        'reg': reg,
        'powershell': ps,
        'conhost': conhost,
        'whoami': whoami,
        'tasklist': tasklistCount,
      };
    } catch (_) {
      return const <String, int>{};
    }
  }
}
