import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/ecosystem_scan_models.dart';
import 'app_logger.dart';
import 'blocking_ecosystem_scan_service.dart';
import 'silent_bootstrap_context.dart';
import 'windows_default_browser_service.dart';
import 'windows_hidden_process.dart';

/// When Windows' default HTTP/HTTPS browser is one this app cannot enforce
/// (extension missing, killed on launch, or unrecognized), open the Default
/// Apps Settings page so the user can pick a 6VPN-protected browser.
///
/// Why: a user click on `https://…` opens the OS default. If that default is
/// an unprotected browser, the URL either escapes our policy or triggers the
/// hard-kill guard (= "엉덩이 풀 본드"). Steering Windows' default at the
/// `UrlAssociations\http` registry to a browser this app already certifies
/// fixes both at once.
///
/// Selection of the "safe" candidate reuses
/// [WindowsDefaultBrowserService.detect], which scores against
/// [BlockingEcosystemScanService] — the same in-app scanner the user already
/// sees in the diagnostics screen. We do not reimplement "is this browser
/// safe?" logic here.
final class DefaultBrowserPromoterService {
  DefaultBrowserPromoterService._();
  static final DefaultBrowserPromoterService instance =
      DefaultBrowserPromoterService._();

  // Performance budget — meets CLAUDE.md hard rules: ≥30 s tick, single
  // child process per tick (reg.exe inside detect() + maybe one Start-Process
  // when promoting). 30 min interval keeps total cost ~2 ticks/hr.
  // @incident: post_rebuild_silent_window — must fire before the 75s
  // post-rebuild silent-notification window closes, or this prompt is
  // silently swallowed.
  static const Duration _kFirstCheckDelay = Duration(seconds: 18);
  static const Duration _kInterval = Duration(minutes: 30);

  // 다른 알람과 마찬가지로 사용자가 한번 본 직후 같은 페이지가 또 떠
  // 짜증나지 않도록 25분간 같은 advisory 는 재발생 안 함.
  static const Duration _kPromoteCooldown = Duration(minutes: 25);

  Timer? _timer;
  bool _started = false;
  DateTime? _lastPromoteAt;
  String? _lastPromotedBrowserId;

  void start() {
    if (_started || !Platform.isWindows) return;
    _started = true;
    // First check waits 18 s; if suppressed (post-rebuild silent window lasts
    // ~75 s, see post_rebuild_bootstrap_service.dart:220), re-poll every 30 s
    // until prompts are allowed. Without this, the first user-facing prompt
    // would only fire 30 min after launch — invisible to the user that day.
    unawaited(_initialPromptLoop());
    _timer = Timer.periodic(_kInterval, (_) => _safeRun());
  }

  Future<void> _initialPromptLoop() async {
    await Future<void>.delayed(_kFirstCheckDelay);
    for (int i = 0; i < 8; i++) {
      // Up to 8 × 30s = 4 min cap so we never spin forever.
      if (!SilentBootstrapContext.suppressUserPrompts) {
        await _safeRun();
        return;
      }
      await Future<void>.delayed(const Duration(seconds: 30));
    }
    // After 4 min still suppressed — let the 30 min Timer.periodic pick it up.
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _started = false;
  }

  Future<void> _safeRun() async {
    try {
      await runOnce();
    } catch (e, st) {
      AppLogger.instance.error('default_browser_promoter run failed', error: e);
      AppLogger.instance.log('DEBUG', 'promoter stack', stack: st);
    }
  }

  /// Force a check now. Used by the diagnostics screen "지금 확인" button.
  ///
  /// [force] bypasses the 25-min cooldown. Use it from kill-time reactions
  /// where the user just lost a browser tab and needs settings opened NOW,
  /// not 25 minutes from now.
  /// [reason] is recorded so we can tell scheduled checks apart from
  /// reactive kill-driven calls in the activity log.
  Future<DefaultBrowserAdvisory?> runOnce({
    bool force = false,
    String reason = 'periodic',
  }) async {
    if (!Platform.isWindows) return null;
    // `force=true` is reactive — the user JUST clicked a link / lost a tab
    // and the default browser is blocked. They need Settings open NOW even
    // if post-rebuild bootstrap is still running. Only the periodic path
    // honours the silent-bootstrap guard.
    if (!force && SilentBootstrapContext.suppressUserPrompts) return null;

    final BlockingEcosystemReport report = await BlockingEcosystemScanService
        .instance
        .scan();
    final DefaultBrowserAdvisory? advisory = report.defaultBrowser;
    if (advisory == null || !advisory.isProblem) return advisory;

    final DateTime now = DateTime.now();
    if (!force &&
        _lastPromoteAt != null &&
        _lastPromotedBrowserId == advisory.browserId &&
        now.difference(_lastPromoteAt!) < _kPromoteCooldown) {
      AppLogger.instance.info(
        'default_browser_promoter: skipped (cooldown) reason=$reason '
        'current=${advisory.displayName}',
      );
      return advisory;
    }
    _lastPromoteAt = now;
    _lastPromotedBrowserId = advisory.browserId;

    await _showGuideAndOpen(advisory);
    await _writeBannerSentinel(advisory);
    AppLogger.instance.info(
      'default_browser_promoter: opened ms-settings:defaultapps — '
      'reason=$reason force=$force '
      'current=${advisory.displayName}/${advisory.browserId}, '
      'suggest=${advisory.suggestSwitchTo ?? "(none)"}',
    );
    return advisory;
  }

  /// Called by [windows_app_block_service] every time we terminate a
  /// browser. If that browser is the OS default, fire the picker
  /// immediately — the user's next click would otherwise hit the same
  /// kill loop ("Firefox 열림 → 50초 뒤 죽음 → 페이지 사라짐"). The check
  /// is cheap (one reg.exe per call) and gated on a 60-second per-image
  /// cooldown so a kill-storm doesn't spawn 12 Settings windows.
  Future<void> reactToBrowserKill({
    required String imageName,
    required String reasonKo,
  }) async {
    if (!Platform.isWindows) return;
    final String key = imageName.toLowerCase();
    final DateTime now = DateTime.now();
    final DateTime? last = _lastReactAt[key];
    if (last != null && now.difference(last) < _kReactCooldown) return;
    _lastReactAt[key] = now;

    if (key == 'aside.exe') {
      await guideAfterBlockedMainBrowser(
        blockedBrowserName: 'Aside',
        reasonKo: reasonKo,
      );
      return;
    }

    try {
      final BlockingEcosystemReport report = await BlockingEcosystemScanService
          .instance
          .scan();
      final DefaultBrowserAdvisory? advisory = report.defaultBrowser;
      if (advisory == null) return;
      final String? expectedExe = _browserIdToExe[advisory.browserId];
      if (expectedExe == null || expectedExe != key) {
        // The killed browser isn't the default — no escalation needed.
        return;
      }
      AppLogger.instance.warn(
        'default_browser_promoter: REACTIVE trigger — default=$key was '
        'just killed (reason=$reasonKo). Opening settings popup directly.',
      );
      _lastPromoteAt = DateTime.now();
      _lastPromotedBrowserId = advisory.browserId;
      // Skip runOnce's isProblem gate — we observed the kill ourselves,
      // so the user definitely needs the picker NOW. runOnce's gate is
      // for the proactive periodic path where false positives are a
      // bigger concern.
      await _showGuideAndOpen(advisory);
      await _writeBannerSentinel(advisory);
      AppLogger.instance.info(
        'default_browser_promoter: opened ms-settings:defaultapps — '
        'reason=kill_default:$reasonKo (reactive direct) '
        'current=${advisory.displayName}/${advisory.browserId}, '
        'suggest=${advisory.suggestSwitchTo ?? "(none)"}',
      );
    } catch (e) {
      AppLogger.instance.warn(
        'default_browser_promoter.reactToBrowserKill: $e',
      );
    }
  }

  /// Gives an actionable default-browser switch guide when FocusFense itself
  /// terminated the user's main browser, even if that browser is not currently
  /// registered as Windows' HTTP default (for example, a pinned Aside window).
  Future<void> guideAfterBlockedMainBrowser({
    required String blockedBrowserName,
    required String reasonKo,
  }) async {
    if (!Platform.isWindows) return;
    final String key = 'main-browser:${blockedBrowserName.toLowerCase()}';
    final DateTime now = DateTime.now();
    final DateTime? last = _lastReactAt[key];
    if (last != null && now.difference(last) < _kReactCooldown) return;
    _lastReactAt[key] = now;

    try {
      final BlockingEcosystemReport report = await BlockingEcosystemScanService
          .instance
          .scan();
      EcosystemTargetRow? candidate;
      for (final EcosystemTargetRow target in report.targets) {
        if (target.id != 'aside' && target.installed && target.urlBlockUsable) {
          candidate = target;
          break;
        }
      }
      final String suggestion = candidate?.displayName ?? '다른 브라우저';
      final DefaultBrowserAdvisory advisory = DefaultBrowserAdvisory(
        browserId: 'aside',
        displayName: blockedBrowserName,
        blockActive: true,
        isProblem: true,
        messageKo: '$blockedBrowserName 종료 사유: $reasonKo',
        suggestSwitchTo: suggestion,
        settingsUri: 'ms-settings:defaultapps',
      );
      _lastPromoteAt = now;
      _lastPromotedBrowserId = 'aside';
      await _showGuideAndOpen(
        advisory,
        titleOverride: 'Aside 차단으로 종료됨',
        bodyOverride: candidate == null
            ? 'FocusFense 차단 규칙 때문에 $blockedBrowserName이 종료되었습니다. '
                  '기본 브라우저를 바꾸려면 Windows 기본 앱 설정에서 선택하세요. '
                  '안전하게 사용할 브라우저는 FocusFense에서 차단 준비 상태를 먼저 확인해 주세요.'
            : 'FocusFense 차단 규칙 때문에 $blockedBrowserName이 종료되었습니다 '
                  '($reasonKo). 계속 웹을 쓰려면 $suggestion을 기본 브라우저로 설정하세요.',
      );
      await _writeBannerSentinel(advisory);
      AppLogger.instance.info(
        'default_browser_promoter: guided switch after app-owned main browser '
        'block; browser=$blockedBrowserName suggestion=$suggestion reason=$reasonKo',
      );
    } catch (e) {
      AppLogger.instance.warn(
        'default_browser_promoter.guideAfterBlockedMainBrowser: $e',
      );
    }
  }

  /// Generic "a browser just died" hook for paths that don't know the
  /// exact image (window-title kill, exit-watcher external detection).
  /// Same single-cooldown semantics as [reactToBrowserKill], but always
  /// scans the current default and only acts if it's currently blocked.
  Future<void> reactToAnyKill({required String reasonKo}) async {
    if (!Platform.isWindows) return;
    final DateTime now = DateTime.now();
    final DateTime? last = _lastReactAt['__any__'];
    if (last != null && now.difference(last) < _kReactCooldown) return;
    _lastReactAt['__any__'] = now;
    try {
      final BlockingEcosystemReport report = await BlockingEcosystemScanService
          .instance
          .scan();
      final DefaultBrowserAdvisory? advisory = report.defaultBrowser;
      if (advisory == null || !advisory.isProblem) return;
      AppLogger.instance.warn(
        'default_browser_promoter: REACTIVE trigger (generic) — '
        'default=${advisory.displayName} is in trouble (reason=$reasonKo). '
        'Opening settings popup directly.',
      );
      _lastPromoteAt = DateTime.now();
      _lastPromotedBrowserId = advisory.browserId;
      // Same rationale as reactToBrowserKill — caller already detected
      // the kill, skip runOnce's isProblem re-check race.
      await _showGuideAndOpen(advisory);
      await _writeBannerSentinel(advisory);
      AppLogger.instance.info(
        'default_browser_promoter: opened ms-settings:defaultapps — '
        'reason=kill_generic:$reasonKo (reactive direct) '
        'current=${advisory.displayName}/${advisory.browserId}, '
        'suggest=${advisory.suggestSwitchTo ?? "(none)"}',
      );
    } catch (e) {
      AppLogger.instance.warn('default_browser_promoter.reactToAnyKill: $e');
    }
  }

  // @incident: kill_storm_prompt_spam — prevents ms-settings:defaultapps
  // prompt spam when multiple browser kills fire in a burst.
  static const Duration _kReactCooldown = Duration(seconds: 60);
  final Map<String, DateTime> _lastReactAt = <String, DateTime>{};

  static const Map<String, String> _browserIdToExe = <String, String>{
    'chrome': 'chrome.exe',
    'edge': 'msedge.exe',
    'firefox': 'firefox.exe',
    'whale': 'whale.exe',
    'brave': 'brave.exe',
    'vivaldi': 'vivaldi.exe',
    'opera': 'opera.exe',
    'opera_gx': 'opera.exe',
  };

  /// Shows the 6VPN branded WinForms guide toast with a "설정 열기" button.
  /// Same dark-card style as the kill-notice toast in AppBlockUserNoticeService
  /// — frameless, rounded, teal stripe, fade-in — so it never looks like a
  /// generic Windows dialog. The user can click the button or wait 12 s for
  /// auto-dismiss.
  Future<void> _showGuideAndOpen(
    DefaultBrowserAdvisory advisory, {
    String? titleOverride,
    String? bodyOverride,
  }) async {
    if (!Platform.isWindows) return;
    if (await _shouldSkipRecentGuide(advisory)) return;

    final String suggest = advisory.suggestSwitchTo ?? 'Microsoft Edge';
    final String current = advisory.displayName;
    final bool isBlocked = advisory.blockActive;
    final String actionUri =
        'ms-settings:defaultapps?registeredAppUser=${Uri.encodeComponent(suggest)}';

    final String title =
        titleOverride ?? (isBlocked ? '기본 브라우저 변경 필요' : '기본 브라우저 확인 필요');
    final String body =
        bodyOverride ??
        (isBlocked
            ? '$current이(가) 차단 스케줄에 포함되어 있습니다. '
                  '$suggest를 기본 브라우저로 설정하면 링크가 항상 자동으로 열립니다.'
            : '$current(으)로 링크가 열리지 않습니다. '
                  '$suggest를 기본 브라우저로 설정해 주세요.');

    try {
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final String psExe = p.join(
        windir,
        'System32',
        'WindowsPowerShell',
        'v1.0',
        'powershell.exe',
      );
      final String dir = p.join(
        Platform.environment['LOCALAPPDATA'] ?? '',
        'SixVPNBlocker',
      );
      await Directory(dir).create(recursive: true);

      final String scriptPath = p.join(dir, 'ShowSixVpnBrowserGuide.ps1');
      await File(scriptPath).writeAsString(_kGuideToastScript, flush: true);

      final String payloadPath = p.join(
        dir,
        'guide_${DateTime.now().microsecondsSinceEpoch}.json',
      );
      await File(payloadPath).writeAsString(
        jsonEncode(<String, String>{
          'title': title,
          'body': body,
          'suggest': suggest,
          'actionUri': actionUri,
        }),
        flush: true,
      );

      await windowsRunHidden(psExe, <String>[
        '-NoProfile',
        '-NonInteractive',
        '-STA',
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        scriptPath,
        '-Payload',
        payloadPath,
      ]);
    } catch (e) {
      AppLogger.instance.warn(
        'guide_toast failed: $e — falling back to settings open',
      );
      await _openDefaultAppsSettings(advisory);
    }
  }

  Future<bool> _shouldSkipRecentGuide(DefaultBrowserAdvisory advisory) async {
    try {
      final String local = Platform.environment['LOCALAPPDATA'] ?? '';
      if (local.isEmpty) return false;
      final File f = File(
        p.join(local, 'SixVPNBlocker', 'default_browser_last_prompt.json'),
      );
      if (!await f.exists()) return false;
      final Object? decoded = jsonDecode(await f.readAsString());
      if (decoded is! Map) return false;
      if ('${decoded['currentBrowserId'] ?? ''}' != advisory.browserId) {
        return false;
      }
      final DateTime? at = DateTime.tryParse('${decoded['at'] ?? ''}');
      if (at == null) return false;
      return DateTime.now().difference(at) < const Duration(hours: 24);
    } catch (_) {
      return false;
    }
  }

  Future<void> _openDefaultAppsSettings(DefaultBrowserAdvisory advisory) async {
    // `ms-settings:defaultapps?registeredAppUser=<displayName>` jumps straight
    // to that app's per-handler defaults panel in Windows 11. The query is
    // ignored on Windows 10 (just lands on Default Apps root) — both
    // outcomes surface the change UI.
    final String suggest = advisory.suggestSwitchTo ?? 'Chrome';
    final String uri =
        'ms-settings:defaultapps?registeredAppUser=${Uri.encodeComponent(suggest)}';
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final String cmdExe = p.join(windir, 'System32', 'cmd.exe');
    await windowsRunHidden(cmdExe, <String>['/c', 'start', '', uri]);
  }

  /// Branded WinForms guide toast — dark card, teal stripe, action button.
  ///
  /// JSON payload keys: title, body, suggest (browser name), actionUri
  /// (ms-settings URI). When actionUri is present the card grows taller and
  /// shows "① → ② → ③" steps + "설정 열기" button + "나중에" dismiss.
  /// Auto-dismisses after 12 s (with button) or 8 s (without).
  static const String _kGuideToastScript = r'''
param([string]$Payload)
$ErrorActionPreference='SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
$tt='기본 브라우저 변경 필요';$bb='';$sg='';$au=''
try{
  if($Payload-and(Test-Path -LiteralPath $Payload)){
    $j=Get-Content -LiteralPath $Payload -Raw -Encoding UTF8|ConvertFrom-Json
    if($j.title){$tt=[string]$j.title}
    if($j.body){$bb=[string]$j.body}
    if($j.suggest){$sg=[string]$j.suggest}
    if($j.actionUri){$au=[string]$j.actionUri}
    Remove-Item -LiteralPath $Payload -Force -ErrorAction SilentlyContinue
  }
}catch{}
$ha=($au-ne'')
$ac=[System.Drawing.Color]::FromArgb(20,199,184)
$bg=[System.Drawing.Color]::FromArgb(26,27,32)
$mu=[System.Drawing.Color]::FromArgb(178,180,190)
$fh=if($ha){210}else{132};$fw=450
$f=New-Object System.Windows.Forms.Form
$f.FormBorderStyle='None';$f.StartPosition='Manual';$f.TopMost=$true;$f.ShowInTaskbar=$false
$f.Width=$fw;$f.Height=$fh;$f.BackColor=$bg
$wa=[System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
$f.Left=$wa.Right-$fw-20;$f.Top=$wa.Bottom-$fh-20
$r=14;$gp=New-Object System.Drawing.Drawing2D.GraphicsPath
$gp.AddArc(0,0,$r,$r,180,90);$gp.AddArc($fw-$r-1,0,$r,$r,270,90)
$gp.AddArc($fw-$r-1,$fh-$r-1,$r,$r,0,90);$gp.AddArc(0,$fh-$r-1,$r,$r,90,90)
$gp.CloseAllFigures();$f.Region=New-Object System.Drawing.Region($gp)
$f.Add_Paint({param($s,$e)$e.Graphics.SmoothingMode='AntiAlias';$e.Graphics.FillRectangle((New-Object System.Drawing.SolidBrush($ac)),0,0,5,$f.Height)})
$l0=New-Object System.Windows.Forms.Label;$l0.Text=[char]9679+' FOCUS FENSE';$l0.ForeColor=$ac;$l0.BackColor=$bg;$l0.Font=New-Object System.Drawing.Font('Segoe UI',8,[System.Drawing.FontStyle]::Bold);$l0.AutoSize=$true;$l0.Left=22;$l0.Top=12
$l1=New-Object System.Windows.Forms.Label;$l1.Text=$tt;$l1.ForeColor=[System.Drawing.Color]::White;$l1.BackColor=$bg;$l1.Font=New-Object System.Drawing.Font('Segoe UI Semibold',12,[System.Drawing.FontStyle]::Bold);$l1.AutoSize=$false;$l1.Left=22;$l1.Top=34;$l1.Width=$fw-30;$l1.Height=24
$l2=New-Object System.Windows.Forms.Label;$l2.Text=$bb;$l2.ForeColor=$mu;$l2.BackColor=$bg;$l2.Font=New-Object System.Drawing.Font('Segoe UI',9);$l2.AutoSize=$false;$l2.Left=22;$l2.Top=62;$l2.Width=$fw-30;$l2.Height=if($ha){40}else{58}
$f.Controls.AddRange(@($l0,$l1,$l2))
if($ha){
  $step='① "설정 열기" 클릭  →  ② "'+$sg+'" 항목 클릭  →  ③ "기본값으로 설정" 클릭'
  $l3=New-Object System.Windows.Forms.Label;$l3.Text=$step;$l3.ForeColor=$ac;$l3.BackColor=$bg;$l3.Font=New-Object System.Drawing.Font('Segoe UI',8);$l3.AutoSize=$false;$l3.Left=22;$l3.Top=106;$l3.Width=$fw-30;$l3.Height=20
  $bb2=[System.Drawing.Color]::FromArgb(36,38,46)
  $b1=New-Object System.Windows.Forms.Button;$b1.Text='설정 열기 →';$b1.ForeColor=$ac;$b1.BackColor=$bb2;$b1.FlatStyle='Flat';$b1.FlatAppearance.BorderColor=$ac;$b1.FlatAppearance.BorderSize=1;$b1.Font=New-Object System.Drawing.Font('Segoe UI',9,[System.Drawing.FontStyle]::Bold);$b1.Left=22;$b1.Top=132;$b1.Width=120;$b1.Height=32
  $b1.Add_Click({try{Start-Process $au}catch{};$f.Close()})
  $b2=New-Object System.Windows.Forms.Button;$b2.Text='나중에';$b2.ForeColor=$mu;$b2.BackColor=$bg;$b2.FlatStyle='Flat';$b2.FlatAppearance.BorderColor=[System.Drawing.Color]::FromArgb(70,72,80);$b2.FlatAppearance.BorderSize=1;$b2.Font=New-Object System.Drawing.Font('Segoe UI',9);$b2.Left=150;$b2.Top=132;$b2.Width=75;$b2.Height=32;$b2.Add_Click({$f.Close()})
  $f.Controls.AddRange(@($l3,$b1,$b2))
}else{
  $cx={try{$f.Close()}catch{}}
  $f.Add_Click($cx);$l0.Add_Click($cx);$l1.Add_Click($cx);$l2.Add_Click($cx)
}
$td=if($ha){12000}else{8000}
$tm=New-Object System.Windows.Forms.Timer;$tm.Interval=$td;$tm.Add_Tick({$f.Close()});$tm.Start()
$f.Opacity=0
$fi=New-Object System.Windows.Forms.Timer;$fi.Interval=16;$fi.Add_Tick({if($f.Opacity -lt 0.96){$f.Opacity=$f.Opacity+0.08}else{$fi.Stop()}});$fi.Start()
[System.Media.SystemSounds]::Asterisk.Play()
$f.Add_Shown({$f.Activate();$f.BringToFront()})
[System.Windows.Forms.Application]::Run($f)
''';

  /// Drops a sentinel the next-render of the diagnostics screen reads to
  /// surface an in-app banner "기본 브라우저 변경 권장 — {message}" alongside
  /// the Settings page that just popped open. The diagnostics card already
  /// renders `advisory.messageKo`; this sentinel just records "we did show
  /// the prompt at `ts` so the UI can dim the alert once acted on.
  Future<void> _writeBannerSentinel(DefaultBrowserAdvisory advisory) async {
    try {
      final String local = Platform.environment['LOCALAPPDATA'] ?? '';
      if (local.isEmpty) return;
      final File f = File(
        p.join(local, 'SixVPNBlocker', 'default_browser_last_prompt.json'),
      );
      await f.writeAsString(
        '{"at":"${DateTime.now().toIso8601String()}",'
        '"currentBrowserId":"${advisory.browserId}",'
        '"suggested":"${advisory.suggestSwitchTo ?? ""}"}\n',
        flush: true,
      );
    } catch (_) {
      /* sentinel best-effort */
    }
  }
}
