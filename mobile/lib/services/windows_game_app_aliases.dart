import '../models/block_app.dart';
import 'windows_process_display.dart';
import 'windows_process_lister.dart';

/// Expands friendly game launcher names into the Windows image names that
/// actually run on disk (Battle.net → Agent.exe + SC2_x64.exe, etc.).
abstract final class WindowsGameAppAliases {
  static const Map<String, List<String>> _byDisplayName = <String, List<String>>{
    'battle.net': <String>[
      'battle.net.exe',
      'agent.exe',
      'sc2_x64.exe',
    ],
    'battle.net login': <String>[
      'battle.net.exe',
      'agent.exe',
      'sc2_x64.exe',
    ],
    'battle.net (agent)': <String>[
      'battle.net.exe',
      'agent.exe',
      'sc2_x64.exe',
    ],
    'starcraft ii': <String>['sc2_x64.exe'],
    'starcraft 2': <String>['sc2_x64.exe'],
    'starcraft': <String>['sc2_x64.exe'],
    '스타크래프트': <String>['sc2_x64.exe'],
    '스타크래프트 ii': <String>['sc2_x64.exe'],
    '스타크래프트2': <String>['sc2_x64.exe'],
    'steam': <String>['steam.exe', 'steamwebhelper.exe'],
    'epic games launcher': <String>['epicgameslauncher.exe'],
  };

  static const Map<String, List<String>> _byExe = <String, List<String>>{
    'battle.net.exe': <String>['agent.exe', 'sc2_x64.exe'],
    'sc2_x64.exe': <String>[],
  };

  /// Build [BlockApp] rows from picker selection (friendly names + paths).
  static List<BlockApp> fromPickerSelection(
    Iterable<RunningProcessInfo> picked,
  ) {
    final Map<String, String?> pathByExe = <String, String?>{
      for (final RunningProcessInfo p in picked) p.exeName: p.executablePath,
    };
    final List<BlockApp> raw = picked.map((RunningProcessInfo p) {
      String? chromeAppId;
      if (p.isChromiumBrowser) {
        chromeAppId = p.chromeAppId ?? BlockApp.mainBrowserKey;
      }
      return BlockApp(
        exeName: p.exeName,
        displayName: WindowsProcessDisplay.friendlyName(p),
        chromeAppId: chromeAppId,
      );
    }).toList();
    return expandForStorage(
      raw,
      imagePathForExe: (String exe) => pathByExe[exe],
    );
  }

  /// Rows to persist after the user confirms the picker (includes related exes).
  static List<BlockApp> expandForStorage(
    Iterable<BlockApp> apps, {
    String? Function(String exe)? imagePathForExe,
  }) {
    final Map<String, BlockApp> byExe = <String, BlockApp>{};
    for (final BlockApp app in apps) {
      _addExpanded(
        app,
        byExe,
        imagePath: imagePathForExe?.call(app.exeName),
      );
    }
    return byExe.values.toList();
  }

  /// One [BlockApp] row may become several exe targets at enforcement time.
  static List<BlockApp> expand(Iterable<BlockApp> apps) {
    return expandForStorage(apps);
  }

  static String displayLabelForExe(String exe, {String? fallback}) {
    switch (exe) {
      case 'sc2_x64.exe':
        return 'StarCraft II';
      case 'agent.exe':
        return 'Battle.net (Agent)';
      case 'battle.net.exe':
        return 'Battle.net';
      case 'steamwebhelper.exe':
        return 'Steam (Helper)';
      case 'steam.exe':
        return 'Steam';
      case 'epicgameslauncher.exe':
        return 'Epic Games Launcher';
      default:
        return fallback ?? exe;
    }
  }

  static void _addExpanded(
    BlockApp app,
    Map<String, BlockApp> byExe, {
    String? imagePath,
  }) {
    final String label = app.displayName.trim().toLowerCase();
    final List<String>? presetExes = _byDisplayName[label];
    if (presetExes != null) {
      for (final String exe in presetExes) {
        byExe.putIfAbsent(
          exe,
          () => BlockApp(
            exeName: exe,
            displayName: displayLabelForExe(exe, fallback: app.displayName),
          ),
        );
      }
      return;
    }

    if (app.exeName.isNotEmpty) {
      byExe.putIfAbsent(app.exeName, () => app);
      final bool battleNetAgent = app.exeName == 'agent.exe' &&
          ((imagePath?.toLowerCase().contains('battle.net') ?? false) ||
              label.contains('battle.net'));
      if (battleNetAgent) {
        for (final String extra in <String>['battle.net.exe', 'sc2_x64.exe']) {
          byExe.putIfAbsent(
            extra,
            () => BlockApp(
              exeName: extra,
              displayName: displayLabelForExe(extra, fallback: app.displayName),
            ),
          );
        }
        return;
      }
      final List<String>? related = _byExe[app.exeName];
      if (related != null) {
        for (final String extra in related) {
          byExe.putIfAbsent(
            extra,
            () => BlockApp(
              exeName: extra,
              displayName: displayLabelForExe(extra, fallback: app.displayName),
            ),
          );
        }
      }
      return;
    }

    byExe.putIfAbsent(
      'lt:${(app.windowTitleMatch ?? app.displayName).toLowerCase()}',
      () => app,
    );
  }
}
