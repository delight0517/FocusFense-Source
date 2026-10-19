import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'windows_firewall_block_service.dart';
import 'windows_hidden_process.dart';

/// Launches one UAC prompt for hosts (①) + firewall netsh (⑤).
final class FiveLayerUacResult {
  const FiveLayerUacResult({
    required this.launched,
    required this.message,
    this.vbsPath,
    this.cmdPath,
  });

  final bool launched;
  final String message;
  final String? vbsPath;
  final String? cmdPath;
}

final class WindowsFiveLayerUacService {
  WindowsFiveLayerUacService._();
  static final WindowsFiveLayerUacService instance =
      WindowsFiveLayerUacService._();

  static String programDataDir() =>
      WindowsFirewallBlockService.programDataDir();

  /// Prepare firewall state, ensure hosts CMD includes layer 5, launch UAC.
  Future<FiveLayerUacResult> applyHostsAndFirewall() async {
    if (!Platform.isWindows) {
      return const FiveLayerUacResult(
        launched: false,
        message: 'Windows 전용',
      );
    }

    await WindowsFirewallBlockService.instance.prepareStateOnly();

    final String dir = programDataDir();
    final String vbsPath = p.join(dir, 'sixvpn_elevate_hosts.vbs');
    final String cmdPath = p.join(dir, 'apply_hosts_admin.cmd');

    if (!await File(vbsPath).exists() && !await File(cmdPath).exists()) {
      return FiveLayerUacResult(
        launched: false,
        message: '관리자 스크립트 없음 — 먼저 「지금 적용」으로 hosts BAT 생성',
        cmdPath: cmdPath,
      );
    }

    await _patchHostsCmdIfNeeded(cmdPath);

    try {
      if (await File(vbsPath).exists()) {
        final String cscript = p.join(
          Platform.environment['WINDIR'] ?? r'C:\Windows',
          'System32',
          'cscript.exe',
        );
        await windowsRunHidden(
          cscript,
          <String>['//nologo', vbsPath],
        );
        AppLogger.instance.info('five_layer_uac: launched vbs $vbsPath');
        return FiveLayerUacResult(
          launched: true,
          message: 'UAC 창에서 [예] — hosts(①)+방화벽(⑤) 적용',
          vbsPath: vbsPath,
          cmdPath: cmdPath,
        );
      }
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
          '-Command',
          // -WindowStyle Hidden so the elevated CMD console doesn't flash on
          // screen during apply — the .cmd is non-interactive (hosts+firewall).
          "Start-Process -FilePath '${cmdPath.replaceAll("'", "''")}' -Verb RunAs -WindowStyle Hidden",
        ],
      );
      return FiveLayerUacResult(
        launched: true,
        message: 'UAC 요청됨 (CMD RunAs)',
        cmdPath: cmdPath,
      );
    } catch (e) {
      AppLogger.instance.warn('five_layer_uac failed', error: e);
      return FiveLayerUacResult(
        launched: false,
        message: e.toString(),
        cmdPath: cmdPath,
      );
    }
  }

  Future<void> _patchHostsCmdIfNeeded(String cmdPath) async {
    if (!await File(cmdPath).exists()) return;
    final String content = await File(cmdPath).readAsString();
    if (content.contains('firewall layer 5')) return;
    final String fwBat = p.join(programDataDir(), 'apply_firewall_admin.cmd');
    final String insert = '''

echo [6 VPN Blocker] firewall layer 5...
if exist "$fwBat" call "$fwBat"
''';
    final String patched = content.replaceFirst(
      RegExp(r'exit /b 0\s*$'),
      '$insert\r\nexit /b 0\r\n',
    );
    await File(cmdPath).writeAsString(patched, flush: true);
  }
}
