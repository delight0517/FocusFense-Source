import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../models/active_app_block_entry.dart';
import '../router/app_router.dart';
import 'app_block_notice_builder.dart';
import 'block_activity_log_service.dart';
import 'notification_history_log_service.dart';
import 'silent_bootstrap_context.dart';
import 'windows_hidden_process.dart';
import 'locale_controller.dart';

/// Surfaces snackbars when **this app** blocks, kills, or turns something off
/// so the user is not surprised ("Chrome suddenly closed").
final class AppBlockUserNoticeService {
  AppBlockUserNoticeService._();
  static final AppBlockUserNoticeService instance =
      AppBlockUserNoticeService._();

  static const String badge = '【Focus Fense】';

  Future<void> notifyGameBudgetWarning({
    required int remainingSeconds,
    required int usedSeconds,
    required int maxSeconds,
  }) async {
    final remaining = (remainingSeconds / 60).ceil();
    final max = (maxSeconds / 60).ceil();
    final locale = LocaleController.instance.locale.languageCode;
    final copy = <String, String>{
      'en':
          'Game time: $remaining minutes left today (daily limit: $max minutes). Save your progress before time runs out.',
      'ko':
          '오늘 게임 시간이 $remaining분 남았습니다(하루 한도 $max분). 시간이 끝나기 전에 진행 상황을 저장하세요.',
      'ja': '本日のゲーム時間は残り$remaining分です（1日$max分まで）。終了前に進行状況を保存してください。',
      'zh': '今天的游戏时间还剩$remaining分钟（每日上限$max分钟）。请在时间结束前保存进度。',
      'he':
          'נותרו היום $remaining דקות משחק (מגבלה יומית: $max דקות). יש לשמור את ההתקדמות לפני סיום הזמן.',
      'ar':
          'تبقى اليوم $remaining دقيقة للعب (الحد اليومي $max دقيقة). احفظ تقدمك قبل انتهاء الوقت.',
    };
    final body = copy[locale] ?? copy['en']!;
    await NotificationHistoryLogService.instance.record(
      kind: 'game_budget_warning',
      target: 'games',
      reason: body,
      shown: Platform.isWindows,
    );
    await _windowsBalloon(
      title: 'FocusFense',
      body: body,
      detail: {
        'kind': 'game_budget_warning',
        'target': 'games',
        'remainingSeconds': remainingSeconds,
        'usedSeconds': usedSeconds,
        'maxSeconds': maxSeconds,
      },
    );
  }

  Future<void> notifyGameBudgetExhausted({
    required int usedSeconds,
    required int maxSeconds,
  }) async {
    final int max = (maxSeconds / 60).ceil();
    final String locale = LocaleController.instance.locale.languageCode;
    final Map<String, String> copy = <String, String>{
      'en':
          'Today’s $max-minute game limit is used up. Games in your limit list are blocked until midnight.',
      'ko': '오늘 게임 시간 $max분을 모두 사용했습니다. 제한 목록의 게임은 자정까지 차단됩니다.',
      'ja': '本日のゲーム時間（$max分）を使い切りました。対象のゲームは午前0時までブロックされます。',
      'zh': '今天的$max分钟游戏时间已用完。限时列表中的游戏将于午夜前保持阻止。',
      'he':
          'מגבלת המשחק היומית של $max דקות נוצלה. המשחקים ברשימה ייחסמו עד חצות.',
      'ar':
          'انتهى حد اللعب اليومي البالغ $max دقيقة. ستُحظر الألعاب المحددة حتى منتصف الليل.',
    };
    final String body = copy[locale] ?? copy['en']!;
    await NotificationHistoryLogService.instance.record(
      kind: 'game_budget_exhausted',
      target: 'games',
      reason: body,
      shown: Platform.isWindows,
    );
    await _windowsBalloon(
      title: 'FocusFense',
      body: body,
      blockingNotice: true,
      detail: <String, Object?>{
        'kind': 'game_budget_exhausted',
        'target': 'games',
        'usedSeconds': usedSeconds,
        'maxSeconds': maxSeconds,
      },
    );
  }

  static const Duration _forceCloseCooldown = Duration(seconds: 15);
  static const Duration _siteBlockCooldown = Duration(minutes: 3);
  static const Duration _policyCooldown = Duration(seconds: 20);

  int _seenRevision = 0;
  final Map<String, DateTime> _lastShown = <String, DateTime>{};

  /// Global floor between desktop popups so a burst (e.g. the self-test probe
  /// closing dozens of browsers at once - cause #3) can't spawn dozens of
  /// windows. The activity log still records every event; only the popup is
  /// throttled.
  final Queue<_ToastRequest> _popupQueue = Queue<_ToastRequest>();
  bool _popupDrainRunning = false;
  static const Duration _popupMinGap = Duration(seconds: 6);
  VoidCallback? _listener;
  bool _started = false;

  // 2026-07-06: per-key cooldowns (15s~3min) stop the SAME event repeating,
  // but nothing capped TOTAL volume across many DIFFERENT keys (one browser
  // migrate, one policy resync, one game kill, …) — each passes its own
  // cooldown independently and they all queue up, draining one every 6s.
  // User-reported "알림이 시도때도 없이 뜬다" was this: a steady stream of
  // distinct, individually-legitimate toasts with no ceiling on how many
  // per minute. Hard global cap: once this many have shown in the rolling
  // window, further toasts are recorded to history (still auditable) but
  // not popped, until the window rolls forward.
  static const int _maxToastsPerWindow = 5;
  static const Duration _toastRateWindow = Duration(minutes: 5);
  final Queue<DateTime> _recentToastTimes = Queue<DateTime>();

  bool _globalRateLimited() {
    final DateTime now = DateTime.now();
    while (_recentToastTimes.isNotEmpty &&
        now.difference(_recentToastTimes.first) > _toastRateWindow) {
      _recentToastTimes.removeFirst();
    }
    return _recentToastTimes.length >= _maxToastsPerWindow;
  }

  void start() {
    if (_started) return;
    _started = true;
    _seenRevision = BlockActivityLogService.instance.revision.value;
    _listener = _onActivity;
    BlockActivityLogService.instance.revision.addListener(_listener!);
  }

  void stop() {
    if (!_started) return;
    _started = false;
    if (_listener != null) {
      BlockActivityLogService.instance.revision.removeListener(_listener!);
      _listener = null;
    }
  }

  /// Schedule / quick-block app launch - explain which rule and until when.
  void notifyAppLaunchBlocked({
    required String appDisplayName,
    required AppBlockContext context,
    String? debounceKey,
  }) {
    final ({String headline, String detail}) copy = AppBlockNoticeBuilder.build(
      appDisplayName: appDisplayName,
      context: context,
    );
    final String key =
        debounceKey ?? 'app_launch_${context.source.name}_$appDisplayName';
    final DateTime now = DateTime.now();
    final DateTime? last = _lastShown[key];
    if (last != null && now.difference(last) < _forceCloseCooldown) {
      unawaited(
        NotificationHistoryLogService.instance.record(
          kind: 'appLaunchBlocked',
          target: appDisplayName,
          reason: copy.detail,
          shown: false,
          suppressReason: 'cooldown',
        ),
      );
      return;
    }
    _lastShown[key] = now;
    unawaited(
      NotificationHistoryLogService.instance.record(
        kind: 'appLaunchBlocked',
        target: appDisplayName,
        reason: copy.detail,
        shown: true,
      ),
    );

    final String body = '${copy.headline}\n${copy.detail}';
    BlockActivityLogService.instance.record(
      kind: BlockActivityKind.protection,
      message: '앱 차단: $body',
      debounceKey: key,
      data: <String, Object?>{
        'app': appDisplayName,
        'source': context.source.name,
        'blockTags': context.tagKeys,
        'blockTagLabelsKo': context.tags
            .map((AppBlockTag tag) => tag.labelKo)
            .toList(),
        'endsAt': context.endsAt?.toIso8601String(),
        'schedules': context.scheduleLabels,
      },
    );

    if (!SilentBootstrapContext.suppressUserPrompts) {
      _showSnack(body, durationSeconds: 12);
    }
    Future<void>.microtask(
      () => _windowsBalloon(
        title: copy.headline,
        body: copy.detail,
        blockingNotice: true,
        detail: <String, Object?>{
          'kind': 'appBlock',
          'target': appDisplayName,
          'source': context.source.name,
          'schedules': context.scheduleLabels,
          'endsAt': context.endsAt?.toIso8601String(),
          'tags': context.tags.map((AppBlockTag tag) => tag.labelKo).toList(),
        },
      ),
    );
  }

  /// Kill guard / launch block - always explain that **this app** did it.
  void notifyBrowserLaunchBlocked({
    required String browserDisplayName,
    required String detailKo,
  }) {
    final String message = '$browserDisplayName — $detailKo';
    final String key = 'launch_block_$browserDisplayName';
    final DateTime now = DateTime.now();
    final DateTime? last = _lastShown[key];
    if (last != null && now.difference(last) < _forceCloseCooldown) {
      unawaited(
        NotificationHistoryLogService.instance.record(
          kind: 'browserLaunchBlocked',
          target: browserDisplayName,
          reason: detailKo,
          shown: false,
          suppressReason: 'cooldown',
        ),
      );
      return;
    }
    _lastShown[key] = now;

    BlockActivityLogService.instance.record(
      kind: BlockActivityKind.protection,
      message: message,
      debounceKey: key,
    );

    final bool suppressed = SilentBootstrapContext.suppressUserPrompts;
    unawaited(
      NotificationHistoryLogService.instance.record(
        kind: 'browserLaunchBlocked',
        target: browserDisplayName,
        reason: detailKo,
        shown: !suppressed,
        suppressReason: suppressed ? 'silent_bootstrap' : null,
      ),
    );
    if (!suppressed) {
      _showSnack(message, durationSeconds: 12);
    }
    Future<void>.microtask(
      () => _windowsBalloon(
        title: '$browserDisplayName 실행 차단',
        body: detailKo,
        blockingNotice: true,
        detail: <String, Object?>{
          'kind': 'browserLaunchBlock',
          'target': browserDisplayName,
          'reason': detailKo,
          'tags': <String>[
            AppBlockTag.appLaunch.labelKo,
            AppBlockTag.osGuard.labelKo,
          ],
        },
      ),
    );
  }

  /// This app just killed [browserOrAppDisplayName]. Always explain WHY
  /// (which schedule, policy reload, extension install, etc.) so the user
  /// is never surprised by a sudden close. Emits both an in-app snackbar
  /// and a Windows balloon.
  ///
  /// [reasonKo] is the human-readable cause shown to the user, e.g.
  /// "스케줄 평일 14:00-18:00 — 자녀 보호" or "차단 정책 적용을 위해 reload".
  void notifyBrowserKilledWithReason({
    required String browserOrAppDisplayName,
    required String reasonKo,
    String? debounceKey,
  }) {
    final String key =
        debounceKey ?? 'killed_${browserOrAppDisplayName}_${reasonKo.hashCode}';
    final DateTime now = DateTime.now();
    final DateTime? last = _lastShown[key];
    if (last != null && now.difference(last) < _forceCloseCooldown) {
      unawaited(
        NotificationHistoryLogService.instance.record(
          kind: 'browserKilled',
          target: browserOrAppDisplayName,
          reason: reasonKo,
          shown: false,
          suppressReason: 'cooldown',
        ),
      );
      return;
    }
    _lastShown[key] = now;

    final String message = '$badge $browserOrAppDisplayName 종료 — $reasonKo';

    BlockActivityLogService.instance.record(
      kind: BlockActivityKind.protection,
      message: '$browserOrAppDisplayName 종료 — $reasonKo',
      debounceKey: key,
      data: <String, Object?>{
        'target': browserOrAppDisplayName,
        'reason': reasonKo,
      },
    );

    final bool suppressed = SilentBootstrapContext.suppressUserPrompts;
    unawaited(
      NotificationHistoryLogService.instance.record(
        kind: 'browserKilled',
        target: browserOrAppDisplayName,
        reason: reasonKo,
        shown: !suppressed,
        suppressReason: suppressed ? 'silent_bootstrap' : null,
      ),
    );
    if (!suppressed) {
      _showSnack(message, durationSeconds: 10);
    }
    Future<void>.microtask(
      () => _windowsBalloon(
        title: '$browserOrAppDisplayName 종료됨',
        body: reasonKo,
        blockingNotice: true,
        detail: <String, Object?>{
          'kind': 'browserKilled',
          'target': browserOrAppDisplayName,
          'reason': reasonKo,
          'tags': <String>[
            AppBlockTag.osGuard.labelKo,
            AppBlockTag.schedule.labelKo,
          ],
        },
      ),
    );
  }

  /// The watcher noticed [browserDisplayName] (pid [pid]) exited and the
  /// ledger has no matching record - i.e. it was NOT us. Surface a softer
  /// notice so the user knows their browser dying wasn't caused by this app.
  ///
  /// The **activity-log entry always writes** so the audit trail is
  /// complete (even during post-rebuild bootstrap). The snackbar + Windows
  /// balloon honour [SilentBootstrapContext.suppressUserPrompts] so we
  /// don't pile UI on top of the bootstrap progress overlay.
  void notifyExternalBrowserExit({
    required String browserDisplayName,
    required int pid,
    required DateTime detectedAt,
  }) {
    final String key = 'ext_exit_${browserDisplayName}_$pid';
    final DateTime now = DateTime.now();
    final DateTime? last = _lastShown[key];
    if (last != null && now.difference(last) < _forceCloseCooldown) {
      unawaited(
        NotificationHistoryLogService.instance.record(
          kind: 'externalExit',
          target: browserDisplayName,
          reason: '외부 원인 종료 감지 (pid=$pid)',
          shown: false,
          suppressReason: 'cooldown',
        ),
      );
      return;
    }
    _lastShown[key] = now;

    final String timeHm =
        '${detectedAt.hour.toString().padLeft(2, '0')}:${detectedAt.minute.toString().padLeft(2, '0')}';
    // Firefox is never process-killed by this app (protection there is the
    // force-installed WebsiteFilter/extension policy, not termination) — say
    // so explicitly so a Firefox exit never reads as "Focus Fense did
    // something to Firefox and won't tell me what".
    final bool isFirefox = browserDisplayName.toLowerCase() == 'firefox';
    final String causeNote = isFirefox
        ? 'Focus Fense는 Firefox 프로세스를 직접 종료시키지 않습니다 (차단은 정책/확장 방식). '
              '원인: 사용자 직접 닫음 · OS 업데이트 재시작 · 다른 프로그램 등.'
        : '원인: 사용자 직접 닫음 · OS · 다른 프로그램 등.';
    final String snack =
        '$badge $browserDisplayName이(가) Focus Fense 외부 원인으로 종료됨 '
        '($timeHm, PID $pid). $causeNote';

    BlockActivityLogService.instance.record(
      kind: BlockActivityKind.protection,
      message: '$browserDisplayName 외부 원인 종료 감지 (pid=$pid, $timeHm)',
      level: 'warn',
      data: <String, Object?>{
        'target': browserDisplayName,
        'pid': pid,
        'externalCause': true,
        'detectedAt': detectedAt.toIso8601String(),
      },
      debounceKey: key,
    );

    final bool suppressed = SilentBootstrapContext.suppressUserPrompts;
    unawaited(
      NotificationHistoryLogService.instance.record(
        kind: 'externalExit',
        target: browserDisplayName,
        reason: '외부 원인 종료 감지 (pid=$pid, $timeHm)',
        shown: !suppressed,
        suppressReason: suppressed ? 'silent_bootstrap' : null,
      ),
    );
    if (suppressed) return;

    _showSnack(snack, durationSeconds: 9);
    Future<void>.microtask(
      () => _windowsBalloon(
        title: badge,
        body: '$browserDisplayName이(가) 외부 원인으로 종료되었습니다 ($timeHm).',
        detail: <String, Object?>{
          'kind': 'externalExit',
          'target': browserDisplayName,
          'reason':
              'Focus Fense가 아닌 외부 원인으로 $timeHm에 종료됨 (PID $pid). $causeNote',
        },
      ),
    );
  }

  void _showSnack(String message, {int durationSeconds = 7}) {
    final BuildContext? ctx = appRootNavigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
        content: Text('$badge $message'),
        duration: Duration(seconds: durationSeconds),
        behavior: SnackBarBehavior.floating,
        showCloseIcon: true,
      ),
    );
  }

  /// Branded, always-on-top desktop toast - the Focus Fense close-notice.
  ///
  /// 2026-06-22: verified on screen that `NotifyIcon.ShowBalloonTip` does NOT
  /// appear on this Win11 box (balloons are suppressed / routed to Action
  /// Center). The user must SEE which browser closed and why, every time - and
  /// it must NOT look like a generic Windows dialog. So we render a custom
  /// frameless, rounded, dark card with the 6VPN accent stripe (hosted via a
  /// tiny PS WinForms script - a true second Flutter window would need
  /// experimental multi-window plumbing that risks the single-window build).
  /// Cannot be suppressed by notification settings; auto-dismisses; click to
  /// close.
  /// [detail] is an optional structured payload describing WHAT is blocking
  /// (schedules, endsAt, tags, source…). It rides along inside the toast so
  /// that, when the user clicks the toast, the click-signal carries it back
  /// into the app and the "지금 무엇이 차단 중" dialog can render the specifics.
  Future<void> _windowsBalloon({
    required String title,
    required String body,
    Map<String, Object?>? detail,
    bool blockingNotice = false,
  }) async {
    if (!Platform.isWindows) return;
    // A real app/game block must be explained immediately. General activity
    // toasts remain rate-limited, but this explicit enforcement notice must
    // not disappear behind that unrelated queue or its five-per-window cap.
    if (blockingNotice) {
      await _showWindowsBalloonNow(
        title: title,
        body: body,
        detail: detail,
        blockingNotice: true,
      );
      return;
    }
    if (_globalRateLimited()) {
      unawaited(
        NotificationHistoryLogService.instance.record(
          kind: 'toast_${detail?['kind'] ?? 'unknown'}',
          target: '${detail?['target'] ?? title}',
          reason: body,
          shown: false,
          suppressReason: 'global_rate_limit',
        ),
      );
      return;
    }
    _popupQueue.add(_ToastRequest(title: title, body: body, detail: detail));
    while (_popupQueue.length > 40) {
      _popupQueue.removeFirst();
    }
    await _drainPopupQueue();
  }

  Future<void> _drainPopupQueue() async {
    if (_popupDrainRunning) return;
    _popupDrainRunning = true;
    try {
      while (_popupQueue.isNotEmpty) {
        final _ToastRequest next = _popupQueue.removeFirst();
        _recentToastTimes.addLast(DateTime.now());
        await _showWindowsBalloonNow(
          title: next.title,
          body: next.body,
          detail: next.detail,
        );
        if (_popupQueue.isNotEmpty) {
          await Future<void>.delayed(_popupMinGap);
        }
      }
    } finally {
      _popupDrainRunning = false;
      if (_popupQueue.isNotEmpty) {
        unawaited(_drainPopupQueue());
      }
    }
  }

  Future<void> _showWindowsBalloonNow({
    required String title,
    required String body,
    Map<String, Object?>? detail,
    bool blockingNotice = false,
  }) async {
    try {
      final DateTime now = DateTime.now();
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
      // Rewrite the script every time so the design stays in sync with the
      // app version (cheap; few hundred bytes).
      final String scriptPath = p.join(dir, 'ShowSixVpnToast.ps1');
      await File(scriptPath).writeAsString(_kToastScript, flush: true);
      // Pass title/body via a JSON sidecar (unique per toast) so Korean/quotes
      // never need shell escaping. The script reads then deletes it.
      final String payloadPath = p.join(
        dir,
        'toast_${now.microsecondsSinceEpoch}.json',
      );
      await File(payloadPath).writeAsString(
        jsonEncode(<String, Object?>{
          'title': title,
          'body': body,
          'detail': ?detail,
          'blockingNotice': blockingNotice,
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
    } catch (_) {}
  }

  /// The branded toast renderer (WinForms). Frameless rounded dark card with a
  /// teal accent stripe, brand line, title and body. Reads {title,body} from a
  /// JSON payload file (arg `-Payload`). Click anywhere or wait 8 s to dismiss.
  static const String _kToastScript = r'''
param([string]$Payload)
$ErrorActionPreference='SilentlyContinue'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
public class FocusFensePassiveToast : System.Windows.Forms.Form {
  protected override bool ShowWithoutActivation { get { return true; } }
  protected override System.Windows.Forms.CreateParams CreateParams {
    get { var p = base.CreateParams; p.ExStyle |= 0x08000000; return p; }
  }
}
'@ -ReferencedAssemblies System.Windows.Forms
$title='Focus Fense'; $body=''; $detail=$null; $blockingNotice=$false
try {
  if ($Payload -and (Test-Path -LiteralPath $Payload)) {
    $j = Get-Content -LiteralPath $Payload -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($j.title) { $title = [string]$j.title }
    if ($j.body)  { $body  = [string]$j.body }
    if ($j.PSObject.Properties.Name -contains 'detail') { $detail = $j.detail }
    if ($j.PSObject.Properties.Name -contains 'blockingNotice') { $blockingNotice = [bool]$j.blockingNotice }
    Remove-Item -LiteralPath $Payload -Force -ErrorAction SilentlyContinue
  }
} catch {}
# When the user CLICKS the card (not the auto-dismiss timer), drop a signal
# file the running app watches for. The app then brings itself to the front and
# opens the "지금 무엇이 차단 중" dialog with these exact details. Timer-close
# must never write this file, or the popup would appear without a user click.
$emitClickSignal = {
  try {
    $sigDir = Join-Path $env:LOCALAPPDATA 'SixVPNBlocker'
    if (-not (Test-Path -LiteralPath $sigDir)) { New-Item -ItemType Directory -Path $sigDir -Force | Out-Null }
    $sig = New-Object psobject
    $sig | Add-Member NoteProperty title  $title
    $sig | Add-Member NoteProperty body   $body
    $sig | Add-Member NoteProperty detail $detail
    $sig | Add-Member NoteProperty clickedAt ((Get-Date).ToString('o'))
    $json = $sig | ConvertTo-Json -Depth 8 -Compress
    $sigPath = Join-Path $sigDir 'toast_click.signal.json'
    [System.IO.File]::WriteAllText($sigPath, $json, (New-Object System.Text.UTF8Encoding($false)))
  } catch {}
}
$accent=[System.Drawing.Color]::FromArgb(56,209,159)
$bg=[System.Drawing.Color]::FromArgb(26,27,32)
$sub=[System.Drawing.Color]::FromArgb(178,180,190)
$f=New-Object FocusFensePassiveToast
$f.FormBorderStyle='None'; $f.StartPosition='Manual'; $f.TopMost=$true; $f.ShowInTaskbar=$false
$f.Width=420; $f.Height=144; $f.BackColor=$bg
$wa=[System.Windows.Forms.Screen]::FromPoint([System.Windows.Forms.Cursor]::Position).WorkingArea
$f.Left=$wa.Right-$f.Width-20; $f.Top=$wa.Bottom-$f.Height-20
$r=14
$gp=New-Object System.Drawing.Drawing2D.GraphicsPath
$gp.AddArc(0,0,$r,$r,180,90)
$gp.AddArc($f.Width-$r-1,0,$r,$r,270,90)
$gp.AddArc($f.Width-$r-1,$f.Height-$r-1,$r,$r,0,90)
$gp.AddArc(0,$f.Height-$r-1,$r,$r,90,90)
$gp.CloseAllFigures()
$f.Region=New-Object System.Drawing.Region($gp)
$f.Add_Paint({ param($s,$e) $e.Graphics.SmoothingMode='AntiAlias'; $e.Graphics.FillRectangle((New-Object System.Drawing.SolidBrush($accent)),0,0,5,$f.Height) })
$brand=New-Object System.Windows.Forms.Label
$brand.Text=[char]9679 + ' FOCUS FENSE'; $brand.ForeColor=$accent; $brand.BackColor=$bg
$brand.Font=New-Object System.Drawing.Font('Segoe UI',8,[System.Drawing.FontStyle]::Bold)
$brand.AutoSize=$true; $brand.Left=22; $brand.Top=14
$lt=New-Object System.Windows.Forms.Label
$lt.Text=$title; $lt.ForeColor=[System.Drawing.Color]::White; $lt.BackColor=$bg
$lt.Font=New-Object System.Drawing.Font('Segoe UI Semibold',12,[System.Drawing.FontStyle]::Bold)
$lt.AutoSize=$false; $lt.Left=22; $lt.Top=36; $lt.Width=360; $lt.Height=24
$lb=New-Object System.Windows.Forms.Label
$lb.Text=$body; $lb.ForeColor=$sub; $lb.BackColor=$bg
$lb.Font=New-Object System.Drawing.Font('Segoe UI',9.5)
$lb.AutoSize=$false; $lb.Left=22; $lb.Top=63; $lb.Width=382; $lb.Height=68
$f.Controls.Add($brand); $f.Controls.Add($lt); $f.Controls.Add($lb)
$close={ & $emitClickSignal; try { $f.Close() } catch {} }
$f.Add_Click($close); $brand.Add_Click($close); $lt.Add_Click($close); $lb.Add_Click($close)
$t=New-Object System.Windows.Forms.Timer; $t.Interval=if ($blockingNotice) { 12000 } else { 8000 }; $t.Add_Tick({ $f.Close() }); $t.Start()
# 2026-07-06 fix: do NOT touch $f.Opacity. Setting Opacity<1 forces WinForms
# into WS_EX_LAYERED (UpdateLayeredWindow) rendering, and the very first
# composited frame — before the dark BackColor + labels have painted into the
# layered bitmap — showed as a plain white rounded square. That flash was the
# "흰색 네모" the user saw on every single browser-close toast. No Opacity =
# no layered window = normal GDI paint via the Region (SetWindowRgn) only,
# which was never the buggy part.
[System.Media.SystemSounds]::Asterisk.Play()
[System.Windows.Forms.Application]::Run($f)
''';

  void _onActivity() {
    final int rev = BlockActivityLogService.instance.revision.value;
    if (rev <= _seenRevision) return;
    _seenRevision = rev;
    final List<BlockActivityEvent> events =
        BlockActivityLogService.instance.events;
    if (events.isEmpty) return;
    _maybeShow(events.first);
  }

  void _maybeShow(BlockActivityEvent ev) {
    if (SilentBootstrapContext.suppressUserPrompts) return;

    final _NoticeClass? cls = _classify(ev);
    if (cls == null) return;

    final String key =
        ev.debounceKey ?? '${ev.kind.name}:${ev.message.hashCode}';
    final Duration cooldown = switch (cls) {
      _NoticeClass.forceClose => _forceCloseCooldown,
      _NoticeClass.siteBlock => _siteBlockCooldown,
      _NoticeClass.appBlock => _forceCloseCooldown,
      _NoticeClass.policyAction => _policyCooldown,
    };
    final DateTime now = DateTime.now();
    final DateTime? last = _lastShown[key];
    if (last != null && now.difference(last) < cooldown) {
      unawaited(
        NotificationHistoryLogService.instance.record(
          kind: 'activityToast_${cls.name}',
          target: '${ev.data?['target'] ?? ev.data?['app'] ?? ''}',
          reason: ev.message,
          shown: false,
          suppressReason: 'cooldown',
        ),
      );
      return;
    }
    _lastShown[key] = now;
    unawaited(
      NotificationHistoryLogService.instance.record(
        kind: 'activityToast_${cls.name}',
        target: '${ev.data?['target'] ?? ev.data?['app'] ?? ''}',
        reason: ev.message,
        shown: true,
      ),
    );
    if (_lastShown.length > 80) {
      _lastShown.removeWhere(
        (String k, DateTime t) => now.difference(t) > const Duration(hours: 2),
      );
    }

    // Every activity-log-driven notice gets the clickable branded toast too —
    // not just the explicit notify* calls above. For forceClose/appBlock
    // events raised BY those calls this is a no-op: they share the same
    // debounceKey, so the cooldown check above already caught them (that
    // call's own _windowsBalloon already fired a moment earlier). This only
    // actually fires new toasts for classes that had no explicit call site —
    // today that's siteBlock (사이트 차단) and policyAction (자동 보호 동작).
    Future<void>.microtask(
      () => _windowsBalloon(
        title: _toastTitle(cls),
        body: ev.message,
        detail: <String, Object?>{
          'kind': cls.name,
          'target': ev.data?['url'] ?? ev.data?['rule'],
          'reason': ev.message,
          'tags': _tagLineForNoticeClass(cls).split(' · '),
        },
      ),
    );

    final BuildContext? ctx = appRootNavigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;

    ScaffoldMessenger.of(ctx).showSnackBar(
      SnackBar(
        content: Text(_format(ev, cls)),
        duration: Duration(seconds: cls == _NoticeClass.forceClose ? 10 : 7),
        behavior: SnackBarBehavior.floating,
        showCloseIcon: true,
      ),
    );
  }

  static String _toastTitle(_NoticeClass cls) => switch (cls) {
    _NoticeClass.forceClose => '이 앱 설정으로 종료',
    _NoticeClass.appBlock => '스케줄 앱 차단',
    _NoticeClass.siteBlock => '차단 규칙 적용',
    _NoticeClass.policyAction => '자동 보호 동작',
  };

  static _NoticeClass? _classify(BlockActivityEvent ev) {
    switch (ev.kind) {
      case BlockActivityKind.protection:
        return _NoticeClass.forceClose;
      case BlockActivityKind.blockHit:
        if (ev.message.contains('앱 차단')) {
          return _NoticeClass.appBlock;
        }
        if (ev.message.startsWith('창 제목 차단')) {
          return _NoticeClass.forceClose;
        }
        if (ev.message.startsWith('차단됨:')) {
          return _NoticeClass.siteBlock;
        }
        return null;
      case BlockActivityKind.selfHeal:
        if (_policyKeywords.any(ev.message.contains)) {
          return _NoticeClass.policyAction;
        }
        return null;
      default:
        return null;
    }
  }

  // 2026-07-06: '종료'/'끄'/'전환'/'재적용'/'자동 검증' used to be in this
  // list. They're the exact words routine, silent self-heal maintenance
  // logs (policy resync, browser handoff, periodic verification) — none
  // of it novel to the user, and the events that DO deserve a popup already
  // fire their own explicit notifyBrowserKilledWithReason/etc. call. Keeping
  // those words here meant near-constant background chatter got promoted to
  // desktop toasts on top of the real ones (user-reported "알림이 시도때도
  // 없이 뜬다"). Only keep words that mean something is actually broken.
  static const List<String> _policyKeywords = <String>['차단 미적용', '프리즈', '멈춘'];

  static String _format(BlockActivityEvent ev, _NoticeClass cls) {
    final String lead = switch (cls) {
      _NoticeClass.forceClose => '$badge 이 앱 설정으로 종료 — ',
      _NoticeClass.appBlock => '$badge 스케줄 앱 차단 — ',
      _NoticeClass.siteBlock => '$badge 차단 규칙 적용 — ',
      _NoticeClass.policyAction => '$badge 자동 보호 동작 — ',
    };
    final String tagLine = _tagLineForNoticeClass(cls);
    if (tagLine.isEmpty || ev.message.contains('원인 태그:')) {
      return '$lead${ev.message}';
    }
    return '$lead${ev.message}\n원인 태그: $tagLine';
  }

  static String _tagLineForNoticeClass(_NoticeClass cls) {
    final List<AppBlockTag> tags = switch (cls) {
      _NoticeClass.forceClose => <AppBlockTag>[
        AppBlockTag.osGuard,
        AppBlockTag.appLaunch,
      ],
      _NoticeClass.appBlock => <AppBlockTag>[
        AppBlockTag.appLaunch,
        AppBlockTag.schedule,
      ],
      _NoticeClass.siteBlock => <AppBlockTag>[
        AppBlockTag.urlPolicy,
        AppBlockTag.browserExtension,
        AppBlockTag.dnsHosts,
      ],
      _NoticeClass.policyAction => <AppBlockTag>[
        AppBlockTag.maintenance,
        AppBlockTag.urlPolicy,
      ],
    };
    return tags.map((AppBlockTag tag) => tag.labelKo).join(' · ');
  }
}

enum _NoticeClass { forceClose, appBlock, siteBlock, policyAction }

final class _ToastRequest {
  const _ToastRequest({required this.title, required this.body, this.detail});

  final String title;
  final String body;
  final Map<String, Object?>? detail;
}
