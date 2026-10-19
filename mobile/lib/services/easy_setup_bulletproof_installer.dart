import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'chrome_unification_service.dart';
import 'easy_setup_bulletproof_prefs.dart';
import 'extension_guard_prefs.dart';
import 'firefox_xpi_packager.dart';
import 'windows_extension_guard_service.dart';

/// USB·새 PC용 BAT 설치기 내보내기 + 강화 옵션 적용.
final class EasySetupBulletproofInstaller {
  EasySetupBulletproofInstaller._();
  static final EasySetupBulletproofInstaller instance =
      EasySetupBulletproofInstaller._();

  static String get programDataDir {
    final String pd = Platform.environment['ProgramData'] ?? r'C:\ProgramData';
    return p.join(pd, 'SixVPNBlocker');
  }

  static String get batPath =>
      p.join(programDataDir, 'install-6vpn-blocker.bat');
  static String get ps1Path =>
      p.join(programDataDir, 'Install-6VPN-Bulletproof.ps1');

  static String? get desktopBatPath {
    final String? user = Platform.environment['USERPROFILE'];
    if (user == null || user.isEmpty) return null;
    return p.join(user, 'Desktop', '6 VPN Blocker - 설치.bat');
  }

  /// 쉬운 설치 완료 후 강화 단계 + BAT 내보내기.
  Future<BulletproofInstallResult> applyAfterSetup({
    required String chromeExtensionFolder,
    void Function(String status)? onStatus,
  }) async {
    if (!Platform.isWindows) {
      return const BulletproofInstallResult(ok: false, message: 'Windows 전용');
    }
    void status(String s) {
      onStatus?.call(s);
      AppLogger.instance.info('bulletproof: $s');
    }

    final bool enterprise = await EasySetupBulletproofPrefs.instance
        .forceEnterprisePolicies();

    final StringBuffer log = StringBuffer();

    status('⑥ USB용 install-6vpn-blocker.bat 생성…');
    final String exportMsg = await exportPortableInstaller(
      chromeExtensionFolder: chromeExtensionFolder,
    );
    log.writeln(exportMsg);

    if (enterprise) {
      status('⑥-c 기업 정책 재시도 (UAC · Firefox distribution)…');
      if (!await ExtensionGuardPrefs.instance.isElevatedGuardSkipped()) {
        final ExtensionGuardResult guard = await WindowsExtensionGuardService
            .instance
            .runElevatedGuard(chromeExtensionFolder: chromeExtensionFolder);
        log.writeln(guard.message.split('\n').first);
      } else {
        log.writeln('UAC/HKLM 이전 실패 — HKCU·바로가기 모드 유지');
      }
    }

    status('⑥ Chrome/Edge 시스템 통합 (바로가기 하나)…');
    await ChromeUnificationService.instance.ensureUnifiedChrome(
      extensionFolder: chromeExtensionFolder,
      applyPolicies: true,
    );
    log.writeln('Chrome/Edge 바로가기 통합 완료');

    return BulletproofInstallResult(
      ok: true,
      message: log.toString().trim(),
      batPath: batPath,
      desktopBatPath: desktopBatPath,
    );
  }

  /// ProgramData + 바탕화면에 BAT/PS1 복사.
  Future<String> exportPortableInstaller({
    required String chromeExtensionFolder,
  }) async {
    final Directory dir = Directory(programDataDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    final String extEsc = chromeExtensionFolder.replaceAll('\\', '\\\\');
    final String xpiPath = FirefoxXpiPackager.programDataXpiPath.replaceAll(
      '\\',
      '\\\\',
    );
    final String ps1 = _ps1Template
        .replaceAll('__CHROME_EXT__', extEsc)
        .replaceAll('__FIREFOX_XPI__', xpiPath)
        .replaceAll(
          '__FIREFOX_OFF__',
          ExtensionGuardPrefs.instance
              .browserDisabledMarkerPath('firefox')
              .replaceAll("'", "''"),
        )
        .replaceAll(
          '__CHROME_OFF__',
          ExtensionGuardPrefs.instance
              .browserDisabledMarkerPath('chrome')
              .replaceAll("'", "''"),
        )
        .replaceAll(
          '__EDGE_OFF__',
          ExtensionGuardPrefs.instance
              .browserDisabledMarkerPath('edge')
              .replaceAll("'", "''"),
        );
    await File(ps1Path).writeAsString(ps1, flush: true);

    final String bat = _batTemplate.replaceAll('__PS1__', ps1Path);
    await File(batPath).writeAsString(bat, flush: true);

    final String? desktop = desktopBatPath;
    if (desktop != null) {
      await File(batPath).copy(desktop);
    }

    return 'BAT: $batPath'
        '${desktop != null ? '\n바탕화면: $desktop' : ''}';
  }

  /// 관리자 BAT를 숨김 PowerShell로 실행 (앱에서 재설치).
  Future<bool> runElevatedBat() async {
    if (!Platform.isWindows) return false;
    if (!await File(batPath).exists()) {
      await exportPortableInstaller(
        chromeExtensionFolder:
            await ExtensionGuardPrefs.instance.chromeSourcePath() ??
            p.join(
              Platform.environment['LOCALAPPDATA'] ?? '',
              'SixVPNBlocker',
              'chrome_blocker',
            ),
      );
    }
    try {
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      await Process.start(p.join(windir, 'System32', 'cmd.exe'), <String>[
        '/c',
        'start',
        '',
        batPath,
      ], runInShell: true);
      return true;
    } catch (e) {
      AppLogger.instance.error('runElevatedBat failed', error: e);
      return false;
    }
  }

  static const String _batTemplate = r'''@echo off
chcp 65001 >nul
title 6 VPN Blocker — 무결점 설치
>nul 2>&1 "%SYSTEMROOT%\system32\cacls.exe" "%SYSTEMROOT%\system32\config\system"
if '%errorlevel%' NEQ '0' (
    echo 관리자 권한을 요청합니다...
    goto UACPrompt
) else ( goto gotAdmin )
:UACPrompt
    echo Set UAC = CreateObject^("Shell.Application"^) > "%temp%\sixvpn_getadmin.vbs"
    echo UAC.ShellExecute "%~s0", "", "", "runas", 1 >> "%temp%\sixvpn_getadmin.vbs"
    "%temp%\sixvpn_getadmin.vbs"
    exit /B
:gotAdmin
    if exist "%temp%\sixvpn_getadmin.vbs" del "%temp%\sixvpn_getadmin.vbs"
powershell -NoProfile -ExecutionPolicy Bypass -File "__PS1__"
echo.
echo 5초 후 창이 닫힙니다...
timeout /t 5 /nobreak >nul
''';

  static const String _ps1Template =
      r'''# 6 VPN Blocker — bulletproof portable installer
$ErrorActionPreference = 'Stop'
Write-Host '🚀 6 VPN Blocker 강제 설치 시작' -ForegroundColor Cyan

$chromeExt = '__CHROME_EXT__'
$firefoxXpi = '__FIREFOX_XPI__'
$programData = Join-Path $env:ProgramData 'SixVPNBlocker'
$chromeDest = Join-Path $programData 'chrome_ext'
if (-not (Test-Path -LiteralPath $chromeExt)) {
  Write-Host "Chrome 확장 폴더 없음: $chromeExt" -ForegroundColor Red
  exit 1
}
if (-not (Test-Path -LiteralPath $chromeDest)) {
  New-Item -ItemType Directory -Force -Path $chromeDest | Out-Null
  Copy-Item -Path (Join-Path $chromeExt '*') -Destination $chromeDest -Recurse -Force
}

# Firefox distribution policies
if (-not (Test-Path -LiteralPath '__FIREFOX_OFF__')) {
$ffDist = Join-Path $env:ProgramFiles 'Mozilla Firefox\distribution'
if (-not (Test-Path -LiteralPath $ffDist)) {
  New-Item -ItemType Directory -Force -Path $ffDist | Out-Null
}
$xpiUrl = 'file:///' + ($firefoxXpi -replace '\\','/')
$policy = @{
  policies = @{
    DNSOverHTTPS = @{ Enabled = $false; Locked = $true }
    ExtensionSettings = @{
      'sixvpn-blocker@sixvpnblocker.app' = @{
        installation_mode = 'force_installed'
        install_url = $xpiUrl
      }
    }
  }
} | ConvertTo-Json -Depth 6 -Compress
Set-Content -LiteralPath (Join-Path $ffDist 'policies.json') -Value $policy -Encoding UTF8
Write-Host '✅ Firefox policies.json' -ForegroundColor Green
}

# Desktop: patch existing shortcuts (no separate branded icon)
$wsh = New-Object -ComObject WScript.Shell
function Patch-Lnk($path) {
  try {
    $sc = $wsh.CreateShortcut($path)
    if ($sc.TargetPath -match 'chrome\.exe' -and (Test-Path -LiteralPath '__CHROME_OFF__')) { return }
    if ($sc.TargetPath -match 'msedge\.exe' -and (Test-Path -LiteralPath '__EDGE_OFF__')) { return }
    if ($sc.TargetPath -notmatch 'chrome\.exe|msedge\.exe') { return }
    if ($sc.Arguments -match 'load-extension') { return }
    $sc.Arguments = '--load-extension="' + $chromeDest + '"'
    $sc.Save()
    $script:patched++
  } catch {}
}
$patched = 0
$scan = @(
  (Join-Path $env:USERPROFILE 'Desktop'),
  (Join-Path $env:PUBLIC 'Desktop'),
  (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar'),
  (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'),
  (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs')
)
foreach ($root in $scan) {
  if (Test-Path -LiteralPath $root) {
    Get-ChildItem -LiteralPath $root -Filter '*.lnk' -Recurse -EA SilentlyContinue |
      ForEach-Object { Patch-Lnk $_.FullName }
  }
}
Write-Host "✅ Chrome/Edge 바로가기 통합: $patched 개" -ForegroundColor Green
Write-Host '🎉 설치 완료!' -ForegroundColor Cyan
''';
}

final class BulletproofInstallResult {
  const BulletproofInstallResult({
    required this.ok,
    required this.message,
    this.batPath,
    this.desktopBatPath,
  });

  final bool ok;
  final String message;
  final String? batPath;
  final String? desktopBatPath;
}
