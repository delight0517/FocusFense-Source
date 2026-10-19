import '../models/block_app.dart';
import 'windows_process_lister.dart';

/// Human-readable labels for Windows process picker rows.
abstract final class WindowsProcessDisplay {
  static String friendlyName(RunningProcessInfo p) {
    final String path = p.executablePath?.toLowerCase() ?? '';
    final String raw = p.hasWindow ? p.windowTitle : p.exeName;

    if (p.exeName == 'sc2_x64.exe' || path.contains(r'starcraft ii')) {
      return 'StarCraft II';
    }
    if (p.exeName == 'battle.net.exe' || path.contains(r'battle.net')) {
      if (p.exeName == 'agent.exe') return 'Battle.net (Agent)';
      if (p.exeName == 'battle.net.exe') return 'Battle.net';
    }
    if (p.exeName == 'agent.exe' && path.contains('battle.net')) {
      return 'Battle.net (Agent)';
    }
    if (p.exeName == 'steamwebhelper.exe') return 'Steam (Helper)';
    if (p.exeName == 'epicgameslauncher.exe') return 'Epic Games Launcher';

    return BlockApp.prettyDisplayName(exeName: p.exeName, raw: raw);
  }

  static String subtitle(RunningProcessInfo p) {
    final String label = friendlyName(p);
    final String path = p.executablePath?.trim() ?? '';
    if (path.isNotEmpty) {
      return '$label · ${p.exeName}\n$path';
    }
    if (p.hasWindow && p.windowTitle.isNotEmpty && p.windowTitle != label) {
      return '${p.exeName} · ${p.windowTitle}';
    }
    return p.exeName;
  }
}
