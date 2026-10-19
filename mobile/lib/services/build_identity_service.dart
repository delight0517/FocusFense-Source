import 'dart:async';
import 'dart:io';

import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;

import 'windows_hidden_process.dart';

/// Runtime identity so the user (and support) can confirm **which build** of
/// the app is running — matches the “외부 관찰” spirit of the autonomous
/// diagnostic blueprint (`docs/AUTONOMOUS_DIAGNOSTIC_AGENT_BLUEPRINT.md`).
final class BuildIdentityService {
  BuildIdentityService._();
  static final BuildIdentityService instance = BuildIdentityService._();

  /// Human-facing product name; Windows executable is `FocusFense.exe`.
  static const String kProductDisplayName = 'Focus Fense';

  BuildIdentity? _cache;

  Future<BuildIdentity> current() async {
    if (_cache != null) return _cache!;
    final PackageInfo info = await PackageInfo.fromPlatform();
    final String exe = Platform.resolvedExecutable;
    final _ExeVersion? exeVersion = Platform.isWindows
        ? await _readWindowsExeVersion(exe)
        : null;
    final String version = exeVersion?.version ?? info.version;
    final String buildNumber = exeVersion?.buildNumber ?? info.buildNumber;
    _cache = BuildIdentity(
      appName: info.appName,
      packageName: info.packageName,
      version: version,
      buildNumber: buildNumber,
      executablePath: exe,
      executableBaseName: p.basename(exe),
      operatingSystem: Platform.operatingSystem,
      operatingSystemVersion: Platform.operatingSystemVersion,
    );
    return _cache!;
  }

  Future<_ExeVersion?> _readWindowsExeVersion(String exe) async {
    try {
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final String powershell = p.join(
        windir,
        'System32',
        'WindowsPowerShell',
        'v1.0',
        'powershell.exe',
      );
      final ProcessResult pr = await windowsRunHidden(powershell, <String>[
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        r"param($p) (Get-Item -LiteralPath $p).VersionInfo.ProductVersion",
        exe,
      ]).timeout(const Duration(seconds: 2));
      if (pr.exitCode != 0) return null;
      final String raw = '${pr.stdout}'.trim();
      if (raw.isEmpty || !raw.contains('+')) return null;
      final int plus = raw.lastIndexOf('+');
      final String version = raw.substring(0, plus).trim();
      final String build = raw.substring(plus + 1).trim();
      if (version.isEmpty || build.isEmpty) return null;
      return _ExeVersion(version: version, buildNumber: build);
    } catch (_) {
      return null;
    }
  }

  /// One-line label for logs / clipboard bundles / AI session footers.
  /// Always includes [kProductDisplayName] and `version+buildNumber`.
  Future<String> summaryLine() async {
    final BuildIdentity i = await current();
    return '$kProductDisplayName | ${i.appName} ${i.version}+${i.buildNumber} · '
        '${i.operatingSystem} · ${i.executableBaseName}';
  }

  /// Short line for always-on UI (footer strip).
  Future<String> shortUiLine() async {
    final BuildIdentity i = await current();
    return '$kProductDisplayName · v${i.version}+${i.buildNumber} · ${i.executableBaseName}';
  }
}

final class BuildIdentity {
  const BuildIdentity({
    required this.appName,
    required this.packageName,
    required this.version,
    required this.buildNumber,
    required this.executablePath,
    required this.executableBaseName,
    required this.operatingSystem,
    required this.operatingSystemVersion,
  });

  final String appName;
  final String packageName;
  final String version;
  final String buildNumber;
  final String executablePath;
  final String executableBaseName;
  final String operatingSystem;
  final String operatingSystemVersion;

  String get displayVersion => '$version ($buildNumber)';
}

final class _ExeVersion {
  const _ExeVersion({required this.version, required this.buildNumber});

  final String version;
  final String buildNumber;
}
