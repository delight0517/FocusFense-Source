import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../data/allowed_browser_app_catalog.dart';
import 'app_logger.dart';
import 'chrome_load_extension_launcher.dart';
import 'windows_process_lister.dart';

/// Runtime guard that decides whether a browser may be process-killed.
///
/// Rule (see [AllowedBrowserAppCatalog]): if any allow-listed in-browser app
/// (Gemini / Gmail / Google 로그인 / YouTube Music) currently has a window
/// open in a browser, that browser MUST NOT be process-killed — doing so would
/// take the allowed app down with it. Blocked URLs are handled per-tab by the
/// extension instead.
///
/// Also writes a sidecar file that the out-of-process PowerShell guards
/// (`browser_realtime_guard.ps1`, run both in-app and by the
/// `SixVPNBrowserGuard` scheduled task) read so they obey the same rule.
final class BrowserAppAllowlistService {
  BrowserAppAllowlistService._();
  static final BrowserAppAllowlistService instance =
      BrowserAppAllowlistService._();

  /// Sidecar consumed by the generated PowerShell guard scripts.
  static String sidecarPath() =>
      p.join(ChromeLoadExtensionLauncher.sixVpnDir, 'browser_app_allowlist.json');

  /// Returns the set of browser exe names (lower-case, e.g. `chrome.exe`) that
  /// currently have at least one allow-listed app window open. Killing any of
  /// these would close the allowed app, so callers must skip them.
  Future<Set<String>> browsersHostingAllowedApps() async {
    if (!Platform.isWindows) return const <String>{};
    try {
      final List<RunningProcessInfo> windows =
          await WindowsProcessLister.instance.list(onlyWithWindow: true);
      final Set<String> out = <String>{};
      for (final RunningProcessInfo w in windows) {
        if (!w.isChromiumBrowser && w.exeName != 'firefox.exe') continue;
        if (!w.hasWindow) continue;
        if (AllowedBrowserAppCatalog.isAllowedWindowTitle(w.windowTitle)) {
          out.add(w.exeName.toLowerCase());
        }
      }
      return out;
    } catch (e, st) {
      AppLogger.instance.warn('allowlist browsersHostingAllowedApps: $e\n$st');
      return const <String>{};
    }
  }

  /// True if [exeName] currently hosts an allow-listed app window.
  Future<bool> hostsAllowedApp(String exeName) async {
    final Set<String> set = await browsersHostingAllowedApps();
    return set.contains(exeName.toLowerCase());
  }

  /// Writes the allow-list sidecar (title tokens + domains) so the PowerShell
  /// guard scripts can honour the same allow-list. Best-effort.
  Future<void> syncSidecar() async {
    if (!Platform.isWindows) return;
    try {
      final File f = File(sidecarPath());
      await f.parent.create(recursive: true);
      await f.writeAsString(
        jsonEncode(<String, Object?>{
          'titleTokens': AllowedBrowserAppCatalog.allTitleTokens(),
          'domains': AllowedBrowserAppCatalog.allDomains(),
          'at': DateTime.now().toIso8601String(),
        }),
        flush: true,
      );
    } catch (_) {/* best-effort */}
  }
}
