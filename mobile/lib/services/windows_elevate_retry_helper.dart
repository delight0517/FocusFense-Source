import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'windows_hidden_process.dart';

/// Shared UAC-elevation retry logic for every "run this PS1 as admin" call
/// in the app.
///
/// **Why this exists.** Multiple services (extension guard, ACL unlock,
/// hosts apply) each hand-rolled `Start-Process -Verb RunAs -Wait -PassThru`.
/// On machines with an aggressive AV/EDR (confirmed: AhnLab V3 Lite), that
/// nested elevation request is sometimes silently swallowed **before**
/// Windows ever shows the UAC secure-desktop dialog — the user never sees
/// anything to click, and the call either hangs forever (if uncapped) or
/// times out and gets reported as "UAC declined" even though the user was
/// never actually asked.
///
/// [windows_system_block_service.dart]'s hosts-apply path already solved
/// this for itself with a `Shell.Application.ShellExecute("runas")` fallback
/// via `cscript` — that path routes around some nested-RunAs interception
/// because it isn't a direct child-process spawn. This helper generalizes
/// that fix so every elevate call gets it, not just hosts-apply.
final class WindowsElevateRetryHelper {
  WindowsElevateRetryHelper._();

  /// Runs [scriptPath] elevated. Tries the direct `Start-Process -Verb
  /// RunAs` first (bounded by [primaryTimeout]); if that doesn't produce a
  /// sentinel result within the timeout, retries via VBS `ShellExecute`
  /// (bounded by [fallbackTimeout]). Returns the exit code the elevated
  /// script wrote to [exitSentinelFile], or null if both attempts failed to
  /// produce one (UAC declined, or genuinely blocked by policy).
  ///
  /// [exitSentinelFile] must be the file the elevated PS1 script itself
  /// writes its exit code to (last line `0`/`1`/etc.) — this is how we
  /// detect completion since neither elevation method reliably propagates
  /// the child's real exit code back to us.
  ///
  /// Defaults total 50s (25+25) — this MUST stay under
  /// `OneTapBlockEverythingService._kStepTimeout` (60s), which wraps the
  /// entire calling step. Bumping these defaults without also bumping that
  /// outer timeout silently guarantees the fallback never gets to run to
  /// completion — that mismatch (was 75s+45s inside a 60s wrapper) is
  /// exactly what made the fallback added here never actually help until
  /// this was caught.
  static Future<int?> runElevated({
    required String ps64Exe,
    required String scriptPath,
    required File exitSentinelFile,
    Duration primaryTimeout = const Duration(seconds: 25),
    Duration fallbackTimeout = const Duration(seconds: 25),
  }) async {
    try {
      if (await exitSentinelFile.exists()) {
        await exitSentinelFile.delete();
      }
    } catch (_) {}

    final String scriptEsc = scriptPath.replaceAll("'", "''");
    final String cmd = "\$ErrorActionPreference = 'Stop'; "
        "\$p = Start-Process -FilePath '$ps64Exe' "
        "-ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File','$scriptEsc') "
        "-Verb RunAs -Wait -PassThru; "
        r"if ($null -eq $p) { exit 1 } "
        r"elseif ($null -ne $p.ExitCode) { exit [int]$p.ExitCode } "
        r'else { exit 0 }';

    try {
      await windowsRunHidden(
        ps64Exe,
        <String>[
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-NoLogo',
          '-NonInteractive',
          '-Command',
          cmd,
        ],
      ).timeout(
        primaryTimeout,
        onTimeout: () {
          AppLogger.instance.warn(
            'elevate_retry: primary Start-Process/RunAs timed out after '
            '${primaryTimeout.inSeconds}s — UAC dialog likely never reached '
            'the user (AV/EDR interception or hidden window). Trying VBS '
            'ShellExecute fallback.',
          );
          return ProcessResult(0, -1, '', 'timeout');
        },
      );
    } catch (e) {
      AppLogger.instance.warn('elevate_retry: primary attempt threw: $e');
    }

    int? sentinel = await _readSentinelExitCode(exitSentinelFile);
    if (sentinel != null) return sentinel;

    AppLogger.instance.info(
      'elevate_retry: primary produced no sentinel — retrying via VBS ShellExecute',
    );
    sentinel = await _tryElevateViaShellExecute(
      ps64Exe: ps64Exe,
      scriptPath: scriptPath,
      exitSentinelFile: exitSentinelFile,
      timeout: fallbackTimeout,
    );
    return sentinel;
  }

  static Future<int?> _tryElevateViaShellExecute({
    required String ps64Exe,
    required String scriptPath,
    required File exitSentinelFile,
    required Duration timeout,
  }) async {
    final Directory tmp =
        Directory.systemTemp.createTempSync('sixvpn_elev_retry_');
    final String scriptEsc = scriptPath.replaceAll('"', '""');
    final String argList =
        '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "$scriptEsc"';
    final File vbs = File(p.join(tmp.path, 'sixvpn_elev_retry.vbs'));
    final String vbsBody = '''
Set sh = CreateObject("Shell.Application")
sh.ShellExecute "${ps64Exe.replaceAll('\\', '\\\\')}", "$argList", "", "runas", 0
''';
    try {
      await vbs.writeAsString(vbsBody, flush: true);
      await windowsStartDetachedHidden(
        p.join(
          Platform.environment['WINDIR'] ?? r'C:\Windows',
          'System32',
          'cscript.exe',
        ),
        <String>['//nologo', vbs.path],
      );
    } catch (e) {
      AppLogger.instance.warn('elevate_retry: VBS launch failed: $e');
      return null;
    }
    final int ticks = (timeout.inMilliseconds / 500).ceil();
    for (int i = 0; i < ticks; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final int? code = await _readSentinelExitCode(exitSentinelFile);
      if (code != null) return code;
    }
    return null;
  }

  static Future<int?> _readSentinelExitCode(File exitSentinelFile) async {
    if (!await exitSentinelFile.exists()) return null;
    try {
      final String raw = await exitSentinelFile.readAsString();
      final List<String> lines = raw
          .split(RegExp(r'\r?\n'))
          .map((String l) => l.trim())
          .where((String l) => l.isNotEmpty)
          .toList();
      if (lines.isEmpty) return null;
      return int.tryParse(lines.last);
    } catch (_) {
      return null;
    }
  }
}
