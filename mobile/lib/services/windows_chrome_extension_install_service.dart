import 'dart:io';

import 'package:path/path.dart' as p;

import 'chrome_extension_identity.dart';
import 'chrome_extension_version.dart';
import 'extension_guard_prefs.dart';

/// Registry external-extension install for Chrome/Edge (elevated, Windows only).
final class WindowsChromeExtensionInstallService {
  WindowsChromeExtensionInstallService._();
  static final WindowsChromeExtensionInstallService instance =
      WindowsChromeExtensionInstallService._();

  /// Legacy fallback; prefer [ChromeExtensionVersion.bundled].
  static const String kExtensionVersionFallback = '1.0.12';

  /// PowerShell fragment: HKLM external extension keys (path + version).
  static String elevatedRegistryFragment({
    required String extensionFolderPath,
  }) {
    final String pathEsc = extensionFolderPath.replaceAll("'", "''");
    final String id = ChromeExtensionIdentity.extensionId;
    final String ver = kExtensionVersionFallback;
    final String chromeOff = ExtensionGuardPrefs.instance
        .browserDisabledMarkerPath('chrome')
        .replaceAll("'", "''");
    final String edgeOff = ExtensionGuardPrefs.instance
        .browserDisabledMarkerPath('edge')
        .replaceAll("'", "''");
    return '''
  \$extPath = '$pathEsc'
  \$extId = '$id'
  \$extVer = '$ver'
  if ((Test-Path -LiteralPath \$extPath)) {
    \$chromeExt = 'HKLM:\\SOFTWARE\\Google\\Chrome\\Extensions'
    \$edgeExt = 'HKLM:\\SOFTWARE\\Microsoft\\Edge\\Extensions'
    foreach (\$root in @(\$chromeExt, \$edgeExt)) {
      if (\$root -eq \$chromeExt -and (Test-Path -LiteralPath '$chromeOff')) { continue }
      if (\$root -eq \$edgeExt -and (Test-Path -LiteralPath '$edgeOff')) { continue }
      try {
        New-Item -Path \$root -Force -ErrorAction SilentlyContinue | Out-Null
        \$key = Join-Path \$root \$extId
        New-Item -Path \$key -Force -ErrorAction Stop | Out-Null
        Set-ItemProperty -LiteralPath \$key -Name '(default)' -Value \$extPath -Type String -Force
        Set-ItemProperty -LiteralPath \$key -Name 'version' -Value \$extVer -Type String -Force
        Write-Host "[sixvpn] external extension registered at \$key"
      } catch {
        Write-Host "[sixvpn] extension registry skip (\$root): \$(\$_.Exception.Message)"
      }
    }
  }
''';
  }

  /// Default exported Chrome extension folder under Documents.
  static Future<String> defaultChromeExtensionPath() async {
    final String home = Platform.environment['USERPROFILE'] ?? '';
    return p.normalize(
      p.join(home, 'Documents', 'SixVPN_Extensions', 'chrome_blocker'),
    );
  }
}
