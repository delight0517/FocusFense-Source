import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'chrome_load_extension_launcher.dart';
import 'windows_hidden_process.dart';

/// Replaces Chrome / Edge / Firefox `.lnk` targets with silent VBS launchers.
final class ChromeShortcutHijackService {
  ChromeShortcutHijackService._();
  static final ChromeShortcutHijackService instance =
      ChromeShortcutHijackService._();

  static const Duration kReapplyCooldown = Duration(minutes: 8);
  DateTime? _lastApplyAt;

  static String get _scriptFile =>
      p.join(ChromeLoadExtensionLauncher.sixVpnDir, 'shortcut_hijack.ps1');

  static String _psExe() {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return p.join(
      windir,
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
  }

  Future<ShortcutHijackResult> apply({
    required String extensionFolder,
    bool force = false,
  }) async {
    if (!Platform.isWindows) {
      return const ShortcutHijackResult(ok: false, message: 'Windows 전용');
    }
    if (!await ChromeLoadExtensionLauncher.isInstalled()) {
      return const ShortcutHijackResult(
        ok: false,
        message: '보호 브라우저 실행기가 아직 없습니다. 앱에서 쉬운 설치를 실행하세요.',
      );
    }
    final DateTime now = DateTime.now();
    if (!force &&
        _lastApplyAt != null &&
        now.difference(_lastApplyAt!) < kReapplyCooldown) {
      return const ShortcutHijackResult(
        ok: true,
        message: '바로가기 통합 — 최근 적용됨',
        patchedCount: 0,
      );
    }

    await _writeScript(extensionFolder: extensionFolder);

    try {
      final ProcessResult r = await windowsRunHidden(
        _psExe(),
        <String>[
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-WindowStyle',
          'Hidden',
          '-File',
          _scriptFile,
        ],
      );
      final String out = '${r.stdout}'.trim();
      AppLogger.instance.info('shortcut_hijack: $out exit=${r.exitCode}');
      final RegExpMatch? m = RegExp(r'patched=(\d+)').firstMatch(out);
      final int patched = int.tryParse(m?.group(1) ?? '') ?? 0;
      _lastApplyAt = now;
      return ShortcutHijackResult(
        ok: r.exitCode == 0,
        patchedCount: patched,
        message: patched > 0
            ? 'Chrome·Edge·Firefox 바로가기 $patched개 → 보호 실행기로 연결 (깜빡임 없음).'
            : '바로가기가 이미 보호 실행기를 가리키거나, 수정할 항목이 없습니다.',
      );
    } catch (e) {
      return ShortcutHijackResult(ok: false, message: '바로가기 교체 실패: $e');
    }
  }

  Future<void> runPersistedScriptIfPresent() async {
    if (!Platform.isWindows) return;
    final File f = File(_scriptFile);
    if (!await f.exists()) return;
    try {
      await windowsRunHidden(
        _psExe(),
        <String>[
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-WindowStyle',
          'Hidden',
          '-File',
          f.path,
        ],
      );
    } catch (e) {
      AppLogger.instance.warn('shortcut_hijack persisted run failed', error: e);
    }
  }

  Future<void> _writeScript({required String extensionFolder}) async {
    final Directory dir = Directory(ChromeLoadExtensionLauncher.sixVpnDir);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }

    String esc(String s) => s.replaceAll("'", "''");
    final String chromeLauncher = esc(ChromeLoadExtensionLauncher.chromeVbsPath);
    final String edgeLauncher = esc(ChromeLoadExtensionLauncher.edgeVbsPath);
    final String firefoxLauncher =
        esc(ChromeLoadExtensionLauncher.firefoxVbsPath);
    final String workDir = esc(ChromeLoadExtensionLauncher.sixVpnDir);
    final String ext = esc(extensionFolder);

    final String body = r'''
$ErrorActionPreference = 'SilentlyContinue'
$chromeLauncher = 'CHROME_VBS'
$edgeLauncher = 'EDGE_VBS'
$firefoxLauncher = 'FIREFOX_VBS'
$workDir = 'WORK_DIR'
$ext = 'EXT_PATH'
$patched = 0
$skipped = 0

function Find-BrowserExe([string]$kind) {
  if ($kind -eq 'firefox') {
    $candidates = @(
      (Join-Path $env:ProgramFiles 'Mozilla Firefox\firefox.exe'),
      (Join-Path ${env:ProgramFiles(x86)} 'Mozilla Firefox\firefox.exe')
    )
  } elseif ($kind -eq 'edge') {
    $candidates = @(
      (Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'),
      (Join-Path ${env:ProgramFiles(x86)} 'Microsoft\Edge\Application\msedge.exe')
    )
  } else {
    $candidates = @(
      (Join-Path $env:ProgramFiles 'Google\Chrome\Application\chrome.exe'),
      (Join-Path ${env:ProgramFiles(x86)} 'Google\Chrome\Application\chrome.exe'),
      (Join-Path $env:LOCALAPPDATA 'Google\Chrome\Application\chrome.exe')
    )
  }
  foreach ($p in $candidates) {
    if ($p -and (Test-Path -LiteralPath $p)) { return $p }
  }
  return $null
}

function Resolve-Kind([string]$targetPath) {
  $tl = ($targetPath -replace '/', '\').ToLowerInvariant()
  if ($tl -match '\\chrome\.exe$' -or $tl -match 'launch-6vpn-chrome\.(vbs|bat)$') { return 'chrome' }
  if ($tl -match '\\msedge\.exe$' -or $tl -match 'launch-6vpn-edge\.(vbs|bat)$') { return 'edge' }
  if ($tl -match '\\firefox\.exe$' -or $tl -match 'launch-6vpn-firefox\.(vbs|bat)$') { return 'firefox' }
  return $null
}

function Patch-Lnk([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return }
  try {
    $sh = New-Object -ComObject WScript.Shell
    $sc = $sh.CreateShortcut($path)
    $kind = Resolve-Kind $sc.TargetPath
    if (-not $kind) { return }

    $launcher = switch ($kind) {
      'edge' { $edgeLauncher }
      'firefox' { $firefoxLauncher }
      default { $chromeLauncher }
    }
    if (-not (Test-Path -LiteralPath $launcher)) { return }

    $launcherNorm = (Resolve-Path -LiteralPath $launcher).Path.ToLowerInvariant()
    $targetNorm = ($sc.TargetPath -replace '/', '\').ToLowerInvariant()
    if ($targetNorm -eq $launcherNorm -and $sc.WorkingDirectory -eq $workDir -and [string]::IsNullOrWhiteSpace($sc.Arguments)) {
      $script:skipped++
      return
    }

    $iconExe = Find-BrowserExe $kind
    $sc.TargetPath = $launcher
    $sc.Arguments = ''
    $sc.WorkingDirectory = $workDir
    if ($iconExe) { $sc.IconLocation = "$iconExe,0" }
    $sc.Save()
    $script:patched++
  } catch {
    if ($path -match [regex]::Escape($env:ProgramData)) {
      [void]$script:elevateNeeded.Add($path)
    }
  }
}

function Ensure-UserChromeOverride {
  param([string]$launcher, [string]$workDir, [string]$iconExe)
  if (-not (Test-Path -LiteralPath $launcher)) { return }
  $userLnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Google Chrome.lnk'
  try {
    $parent = Split-Path -Parent $userLnk
    if (-not (Test-Path -LiteralPath $parent)) {
      New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $sh = New-Object -ComObject WScript.Shell
    $sc = $sh.CreateShortcut($userLnk)
    $launcherNorm = (Resolve-Path -LiteralPath $launcher).Path.ToLowerInvariant()
    $targetNorm = ($sc.TargetPath -replace '/', '\').ToLowerInvariant()
    if ($targetNorm -eq $launcherNorm -and $sc.WorkingDirectory -eq $workDir -and [string]::IsNullOrWhiteSpace($sc.Arguments)) {
      $script:skipped++
      return
    }
    $sc.TargetPath = $launcher
    $sc.Arguments = ''
    $sc.WorkingDirectory = $workDir
    if ($iconExe) { $sc.IconLocation = "$iconExe,0" }
    $sc.Save()
    $script:patched++
  } catch {}
}

function Invoke-ProgramDataElevatedPatch {
  param([string[]]$paths, [string]$launcher, [string]$workDir, [string]$iconExe)
  if (-not $paths -or $paths.Count -eq 0) { return }
  $elevScript = Join-Path $workDir 'shortcut_hijack_elevate.ps1'
  $pathList = ($paths | ForEach-Object { "'$($_ -replace "'","''")'" }) -join ",`n"
  $body = @"
`$ErrorActionPreference = 'SilentlyContinue'
`$paths = @(
$pathList
)
`$launcher = '$($launcher -replace "'","''")'
`$workDir = '$($workDir -replace "'","''")'
`$iconExe = '$($iconExe -replace "'","''")'
`$patched = 0
foreach (`$path in `$paths) {
  try {
    `$sh = New-Object -ComObject WScript.Shell
    `$sc = `$sh.CreateShortcut(`$path)
    `$sc.TargetPath = `$launcher
    `$sc.Arguments = ''
    `$sc.WorkingDirectory = `$workDir
    if (`$iconExe) { `$sc.IconLocation = "`$iconExe,0" }
    `$sc.Save()
    `$patched++
  } catch {}
}
Set-Content -LiteralPath (Join-Path '$($workDir -replace "'","''")' 'shortcut_hijack_elevate_result.txt') -Value "patched=`$patched" -Encoding ASCII
"@
  Set-Content -LiteralPath $elevScript -Value $body -Encoding ASCII
  try {
    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
      '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $elevScript
    ) -Verb RunAs -WindowStyle Hidden
  } catch {}
}

$elevateNeeded = New-Object System.Collections.Generic.List[string]
$roots = New-Object System.Collections.Generic.HashSet[string]
function Add-Root([string]$r) {
  if ($r -and (Test-Path -LiteralPath $r)) { [void]$roots.Add($r) }
}
Add-Root (Join-Path $env:USERPROFILE 'Desktop')
Add-Root (Join-Path $env:PUBLIC 'Desktop')
Add-Root (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs')
Add-Root (Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs')
Add-Root (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar')
Add-Root (Join-Path $env:APPDATA 'Microsoft\Internet Explorer\Quick Launch')
Add-Root (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup')
Add-Root (Join-Path $env:APPDATA 'Microsoft\Windows\Recent')
$taskDir = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
if (Test-Path -LiteralPath $taskDir) {
  Get-ChildItem -LiteralPath $taskDir -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue |
    ForEach-Object { [void]$roots.Add($_.DirectoryName) }
}
$od = Join-Path $env:USERPROFILE 'OneDrive'
if (Test-Path -LiteralPath $od) { Add-Root (Join-Path $od 'Desktop') }
Get-ChildItem -LiteralPath $env:USERPROFILE -Directory -Filter 'OneDrive*' -ErrorAction SilentlyContinue |
  ForEach-Object { Add-Root (Join-Path $_.FullName 'Desktop') }

foreach ($root in $roots) {
  Get-ChildItem -LiteralPath $root -Filter '*.lnk' -Recurse -ErrorAction SilentlyContinue |
    ForEach-Object { Patch-Lnk $_.FullName }
}

foreach ($root in $roots) {
  foreach ($pat in @('*chrome*.lnk', '*edge*.lnk', '*firefox*.lnk', '*mozilla*.lnk')) {
    Get-ChildItem -LiteralPath $root -Filter $pat -Recurse -ErrorAction SilentlyContinue |
      ForEach-Object { Patch-Lnk $_.FullName }
  }
}

$chromeIcon = Find-BrowserExe 'chrome'
Ensure-UserChromeOverride -launcher $chromeLauncher -workDir $workDir -iconExe $chromeIcon
if ($elevateNeeded.Count -gt 0) {
  Invoke-ProgramDataElevatedPatch -paths $elevateNeeded.ToArray() -launcher $chromeLauncher -workDir $workDir -iconExe $chromeIcon
}

Write-Output "patched=$patched skipped=$skipped elevate_needed=$($elevateNeeded.Count) ext=$ext"
''';

    final String script = body
        .replaceAll('CHROME_VBS', chromeLauncher)
        .replaceAll('EDGE_VBS', edgeLauncher)
        .replaceAll('FIREFOX_VBS', firefoxLauncher)
        .replaceAll('WORK_DIR', workDir)
        .replaceAll('EXT_PATH', ext);

    await File(_scriptFile).writeAsString(script, flush: true);
  }
}

final class ShortcutHijackResult {
  const ShortcutHijackResult({
    required this.ok,
    required this.message,
    this.patchedCount = 0,
  });

  final bool ok;
  final String message;
  final int patchedCount;
}
