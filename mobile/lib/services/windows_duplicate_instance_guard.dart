import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_block_user_notice_service.dart';
import 'app_logger.dart';
import 'windows_hidden_process.dart';
import 'windows_start_menu_service.dart';

/// Kills extra Focus Fense copies from the same install dir.
///
/// Login autostart (Run + Startup) + watchdog can race the mutex and leave 2–3
/// windows. The survivor should be [keepPid] (this process).
abstract final class WindowsDuplicateInstanceGuard {
  static Future<int> dedupeSiblings({int? keepPid}) async {
    if (!Platform.isWindows) return 0;
    final int self = keepPid ?? pid;
    final String installDir = p.normalize(
      p.join(
        Platform.environment['LOCALAPPDATA'] ?? '',
        'Programs',
        WindowsStartMenuService.kInstallSubdir,
      ),
    );
    if (!await Directory(installDir).exists()) return 0;

    int killed = 0;
    try {
      String psq(String s) => s.replaceAll("'", "''");
      final String cmd =
          "\$install='${psq(installDir)}'; \$keep=$self; \$killed=0; "
          r"foreach ($n in @('FocusFense')) { "
          r"Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object { "
          r"if ($_.Id -eq $keep) { return }; if (-not $_.Path) { return }; "
          r"$dir=[System.IO.Path]::GetDirectoryName($_.Path); "
          r"if ($dir -ine $install) { return }; "
          r"Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue; $killed++ } }; "
          r'Write-Output $killed';
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final ProcessResult pr = await windowsRunHidden(
        p.join(
          windir,
          'System32',
          'WindowsPowerShell',
          'v1.0',
          'powershell.exe',
        ),
        <String>[
          '-NoProfile',
          '-NonInteractive',
          '-WindowStyle',
          'Hidden',
          '-Command',
          cmd,
        ],
      );
      final String out = '${pr.stdout}'.trim();
      killed = int.tryParse(out.split(RegExp(r'\s+')).last) ?? 0;
    } catch (_) {}
    if (killed > 0) {
      AppLogger.instance.warn(
        'duplicate_guard: ended $killed extra app process(es); kept pid=$self',
      );
      AppBlockUserNoticeService.instance.notifyBrowserKilledWithReason(
        browserOrAppDisplayName: 'Focus Fense 중복 창',
        reasonKo: '앱이 중복으로 실행되어 기존 창 $killed개를 정리했습니다.',
        debounceKey: 'duplicate_guard_$self',
      );
    }
    return killed;
  }
}
