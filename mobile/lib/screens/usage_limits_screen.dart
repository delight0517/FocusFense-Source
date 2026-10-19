import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../services/frontmost_app_channel.dart';
import '../services/local_database.dart';
import '../services/global_usage_cap_service.dart';
import '../services/usage_bucket_config_service.dart';
import '../services/usage_ingest_server.dart';
import '../services/usage_limit_policy_service.dart';
import '../services/usage_quota_enforcer_service.dart';
import '../theme/app_colors.dart';
import '../widgets/usage_quota_limit_dialog.dart';

/// Foreground usage caps + hourly breakdown (macOS). iOS shows an explainer.
class UsageLimitsScreen extends StatefulWidget {
  const UsageLimitsScreen({super.key});

  @override
  State<UsageLimitsScreen> createState() => _UsageLimitsScreenState();
}

class _UsageLimitsScreenState extends State<UsageLimitsScreen> {
  final LocalDatabase _db = LocalDatabase.instance;
  final UsageLimitPolicyService _policy = UsageLimitPolicyService.instance;

  List<Map<String, Object?>> _limits = <Map<String, Object?>>[];
  String? _selectedSubject;
  bool _busy = true;
  int _periodHours = 1;
  bool _globalCapEnabled = false;
  int _globalCapSeconds = 7200;
  int _globalUsedToday = 0;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final List<Map<String, Object?>> rows = await _db.usageLimits();
    final int ph = await UsageBucketConfigService.instance.getPeriodHours();
    final bool gOn = await GlobalUsageCapService.instance.isEnabled();
    final int gCap = await GlobalUsageCapService.instance.maxSecondsPerDay();
    final int gUsed =
        await _db.usageDailyGrandTotal(DateTime.now());
    if (!mounted) return;
    setState(() {
      _limits = rows;
      _periodHours = ph;
      _globalCapEnabled = gOn;
      _globalCapSeconds = gCap;
      _globalUsedToday = gUsed;
      _busy = false;
      if (_selectedSubject == null && rows.isNotEmpty) {
        _selectedSubject = rows.first['subject']! as String;
      }
    });
  }

  String _fmtDur(int sec) {
    final int m = sec ~/ 60;
    final int s = sec % 60;
    return '$m분 ${s.toString().padLeft(2, '0')}초';
  }

  String _fmtClock(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  String _bucketRangeLabel(int periodStartMs) {
    final DateTime t = DateTime.fromMillisecondsSinceEpoch(periodStartMs);
    if (_periodHours >= 24) return '하루 통합';
    final DateTime end = t.add(Duration(hours: _periodHours));
    return '${_fmtClock(t)}–${_fmtClock(end)}';
  }

  Future<void> _addWebHostLimit() async {
    final bool ok = await _policy.canEditLimitsNow();
    if (!mounted) return;
    if (!ok) {
      await _explainLocked();
      return;
    }
    final UsageQuotaLimitDialogResult? r = await showUsageQuotaLimitDialog(
      context,
      title: '웹사이트 시간 제한 추가',
      showHostFields: true,
    );
    if (r == null) return;
    String host = (r.host ?? '').trim().toLowerCase();
    host = host.replaceFirst(RegExp('^https?://'), '').split('/').first;
    if (host.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('호스트를 입력하세요.')),
        );
      }
      return;
    }
    final String label =
        (r.displayLabel ?? '').trim().isEmpty ? host : r.displayLabel!.trim();
    final String subject = LocalDatabase.usageSubjectForWebHost(host);
    await _db.upsertUsageLimit(
      id: const Uuid().v4(),
      subject: subject,
      displayLabel: label,
      maxSecondsPerDay: r.maxSeconds,
      quotaMode: r.quotaMode,
      windowSeconds: r.windowSeconds,
      sessionMaxSeconds: r.sessionMaxSeconds,
      sessionPeriodSeconds: r.sessionPeriodSeconds,
    );
    await UsageQuotaEnforcerService.instance.evaluateAndApply();
    await _reload();
  }

  Future<void> _addFromFrontmost() async {
    final bool ok = await _policy.canEditLimitsNow();
    if (!mounted) return;
    if (!ok) {
      await _explainLocked();
      return;
    }
    final snap = await FrontmostAppChannel.instance.getFrontmost();
    if (!mounted) return;
    if (snap == null || snap.bundleId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('전면 앱을 읽지 못했습니다.')),
      );
      return;
    }
    final String subject =
        LocalDatabase.usageSubjectForApp(snap.bundleId, snap.localizedName);
    final UsageQuotaLimitDialogResult? r = await showUsageQuotaLimitDialog(
      context,
      title: '앱 시간 제한 — ${snap.localizedName}',
      showHostFields: false,
      initialLabel: snap.localizedName,
      initialMode: UsageQuotaMode.daily,
      initialAllowMinutes: 60,
    );
    if (r == null) return;
    await _db.upsertUsageLimit(
      id: const Uuid().v4(),
      subject: subject,
      displayLabel: (r.displayLabel ?? '').trim().isEmpty
          ? snap.localizedName
          : r.displayLabel!.trim(),
      maxSecondsPerDay: r.maxSeconds,
      quotaMode: r.quotaMode,
      windowSeconds: r.windowSeconds,
      sessionMaxSeconds: r.sessionMaxSeconds,
      sessionPeriodSeconds: r.sessionPeriodSeconds,
    );
    await UsageQuotaEnforcerService.instance.evaluateAndApply();
    await _reload();
  }

  Future<void> _editLimit(Map<String, Object?> row) async {
    final bool ok = await _policy.canEditLimitsNow();
    if (!mounted) return;
    if (!ok) {
      await _explainLocked();
      return;
    }
    final UsageQuotaMode modeCheck =
        UsageQuotaEnforcerService.modeFromDb(row['quota_mode']);
    if (modeCheck == UsageQuotaMode.hourlyForegroundWindow) {
      await _editNightlyForegroundLimit(row);
      return;
    }
    final String id = row['id']! as String;
    final String subject = row['subject']! as String;
    final String label = row['display_label']! as String;
    final int maxSec = (row['max_seconds_per_day'] as int?) ?? 900;
    final UsageQuotaMode mode =
        UsageQuotaEnforcerService.modeFromDb(row['quota_mode']);
    final UsageQuotaLimitDialogResult? r = await showUsageQuotaLimitDialog(
      context,
      title: '시간 제한 수정',
      initialHost: UsageQuotaEnforcerService.hostFromSubject(subject),
      initialLabel: label,
      showHostFields: false,
      initialMode: mode,
      initialAllowMinutes: maxSec ~/ 60,
      initialWindowHours:
          ((row['window_seconds'] as int?) ?? 10800) ~/ 3600,
      initialSessionMinutes:
          ((row['session_max_seconds'] as int?) ?? 0) > 0
              ? ((row['session_max_seconds'] as int) ~/ 60)
              : maxSec ~/ 60,
      initialResetMinutes:
          ((row['session_period_seconds'] as int?) ?? 1800) ~/ 60,
    );
    if (r == null) return;
    await _db.upsertUsageLimit(
      id: id,
      subject: subject,
      displayLabel: (r.displayLabel ?? '').trim().isEmpty ? label : r.displayLabel!.trim(),
      maxSecondsPerDay: r.maxSeconds,
      quotaMode: r.quotaMode,
      windowSeconds: r.windowSeconds,
      sessionMaxSeconds: r.sessionMaxSeconds,
      sessionPeriodSeconds: r.sessionPeriodSeconds,
    );
    await UsageQuotaEnforcerService.instance.evaluateAndApply();
    await _reload();
  }

  /// Dedicated editor for [UsageQuotaMode.hourlyForegroundWindow] rows (e.g.
  /// "YouTube Music 야간 포그라운드") — the generic [showUsageQuotaLimitDialog]
  /// only knows daily/rolling/session and would crash on this mode's
  /// SegmentedButton, so this mode gets its own small dialog instead.
  Future<void> _editNightlyForegroundLimit(Map<String, Object?> row) async {
    final String id = row['id']! as String;
    final String subject = row['subject']! as String;
    int startHour = (row['window_start_hour'] as int?) ?? 23;
    int endHour = (row['window_end_hour'] as int?) ?? 11;
    int perHourMinutes = ((row['max_seconds_per_hour'] as int?) ?? 900) ~/ 60;
    bool enabled = (row['enabled'] as int? ?? 1) == 1;

    final bool? save = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setSt) => AlertDialog(
          title: Text(row['display_label']! as String),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('활성화'),
                  value: enabled,
                  onChanged: (bool v) => setSt(() => enabled = v),
                ),
                const SizedBox(height: 4),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Text('시작 시각',
                              style: TextStyle(
                                  fontSize: 12, color: AppColors.muted)),
                          DropdownButton<int>(
                            isExpanded: true,
                            value: startHour,
                            items: List<DropdownMenuItem<int>>.generate(
                              24,
                              (int h) => DropdownMenuItem<int>(
                                value: h,
                                child:
                                    Text('${h.toString().padLeft(2, '0')}:00'),
                              ),
                            ),
                            onChanged: (int? v) {
                              if (v != null) setSt(() => startHour = v);
                            },
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          const Text('종료 시각',
                              style: TextStyle(
                                  fontSize: 12, color: AppColors.muted)),
                          DropdownButton<int>(
                            isExpanded: true,
                            value: endHour,
                            items: List<DropdownMenuItem<int>>.generate(
                              24,
                              (int h) => DropdownMenuItem<int>(
                                value: h,
                                child:
                                    Text('${h.toString().padLeft(2, '0')}:00'),
                              ),
                            ),
                            onChanged: (int? v) {
                              if (v != null) setSt(() => endHour = v);
                            },
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Slider(
                        value: perHourMinutes.clamp(1, 60).toDouble(),
                        min: 1,
                        max: 60,
                        divisions: 59,
                        label: '$perHourMinutes분/시간',
                        onChanged: (double v) =>
                            setSt(() => perHourMinutes = v.round()),
                      ),
                    ),
                    Text('$perHourMinutes분/시간'),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '위 시간대 동안 이 사이트가 화면에 보이는(활성 창/탭) 시간만 시간당 '
                  '$perHourMinutes분으로 제한됩니다. 최소화하거나 다른 탭/창으로 넘기면 '
                  '재생은 백그라운드로 계속되며 제한이 없습니다. 시간대 밖에서는 제한이 없습니다.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.muted,
                        height: 1.4,
                      ),
                ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('저장'),
            ),
          ],
        ),
      ),
    );
    if (save != true) return;
    await _db.upsertUsageLimit(
      id: id,
      subject: subject,
      displayLabel: row['display_label']! as String,
      maxSecondsPerDay: (row['max_seconds_per_day'] as int?) ?? 900,
      quotaMode: 'hourly_fg_window',
      windowStartHour: startHour,
      windowEndHour: endHour,
      maxSecondsPerHour: perHourMinutes * 60,
      enabled: enabled,
    );
    await UsageQuotaEnforcerService.instance.evaluateAndApply();
    await _reload();
  }

  Future<void> _deleteLimit(String id) async {
    final bool ok = await _policy.canEditLimitsNow();
    if (!mounted) return;
    if (!ok) {
      await _explainLocked();
      return;
    }
    await _db.deleteUsageLimit(id);
    await UsageQuotaEnforcerService.instance.evaluateAndApply();
    await _reload();
  }

  Future<void> _explainLocked() async {
    final DateTime? u = await _policy.editUnlockUntil();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('상한 설정이 잠겨 있음'),
        content: Text(
          u == null
              ? '편집 잠금 시간이 설정되어 있습니다.'
              : '${u.year}-${u.month.toString().padLeft(2, '0')}-${u.day.toString().padLeft(2, '0')} '
                  '${u.hour.toString().padLeft(2, '0')}:${u.minute.toString().padLeft(2, '0')} 이후에 '
                  '상한을 바꾸거나 지울 수 있어요.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }

  Future<void> _requestTomorrowUnlock() async {
    await _policy.unlockTomorrowMorning(hour: 6, minute: 0);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('내일 06:00 이후에 상한 편집이 가능합니다.'),
        duration: Duration(seconds: 4),
      ),
    );
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('사이트 이용 시간 제한'),
        actions: <Widget>[
          if (Platform.isMacOS || Platform.isWindows)
            IconButton(
              tooltip: '새로고침',
              onPressed: () async {
                await UsageQuotaEnforcerService.instance.evaluateAndApply();
                await _reload();
              },
              icon: const Icon(Icons.refresh),
            ),
        ],
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
              children: <Widget>[
                if (!Platform.isMacOS && !Platform.isWindows)
                  Card(
                    color: AppColors.warning.withValues(alpha: 0.12),
                    child: const Padding(
                      padding: EdgeInsets.all(14),
                      child: Text(
                        'iOS에서는 다른 앱의 전면 사용 시간을 OS가 막아 두어 '
                        '자동 측정·상한은 macOS/Windows 전용입니다.',
                        style: TextStyle(height: 1.4),
                      ),
                    ),
                  )
                else if (Platform.isWindows)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Text(
                        'Windows: Chrome/Edge/Firefox 확장이 탭이 보이는 동안 '
                        '약 20초마다 호스트·초를 이 앱으로 보냅니다. '
                        '허용 시간이 끝나면 youtube.com 등이 **hosts(DNS)로 완전 잠금**됩니다.\n\n'
                        '• **하루** — 오늘 N분까지\n'
                        '• **구간** — 최근 N시간 안에서 M분까지 (예: 3시간마다 1시간)\n'
                        '• **세션** — M분 쓰면 잠금, N분마다 다시 허용 (예: 50분/30분 주기)',
                        style: const TextStyle(height: 1.45, color: AppColors.muted),
                      ),
                    ),
                  )
                else
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Text(
                        '15초마다 macOS 전면 앱을 샘플링해 시간을 쌓습니다(연속 세션이 아님). '
                        '아래에서 집계 구간(N시간)을 바꾸면 앱·웹 사용량이 같은 규칙으로 버킷에 합산됩니다.\n\n'
                        'Chrome/Firefox 확장은 탭이 보이는 동안 약 20초마다 '
                        '루프백 http://127.0.0.1:${UsageIngestServer.kPort}/ingest 로 호스트·초를 보냅니다. '
                        '이 앱이 실행 중일 때만 수신됩니다.',
                        style: const TextStyle(height: 1.4, color: AppColors.muted),
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                if (Platform.isMacOS || Platform.isWindows) ...<Widget>[
                  Card(
                    color: _globalCapEnabled && _globalUsedToday >= _globalCapSeconds
                        ? AppColors.danger.withValues(alpha: 0.08)
                        : null,
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              const Icon(Icons.public, color: AppColors.muted),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  '전역 하루 총 상한 (앱+웹)',
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleSmall
                                      ?.copyWith(fontWeight: FontWeight.w700),
                                ),
                              ),
                              Switch(
                                value: _globalCapEnabled,
                                onChanged: (bool v) async {
                                  await GlobalUsageCapService.instance
                                      .setEnabled(v);
                                  await UsageQuotaEnforcerService.instance
                                      .evaluateAndApply();
                                  await _reload();
                                },
                              ),
                            ],
                          ),
                          Text(
                            '오늘 합산 ${_fmtDur(_globalUsedToday)} / '
                            '${_globalCapEnabled ? _fmtDur(_globalCapSeconds) : "꺼짐"} · '
                            '개별 사이트 상한과 별도로, **모든** 추적 대상 시간을 이 한도 안에 둡니다.',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: AppColors.muted, height: 1.35),
                          ),
                          if (_globalCapEnabled) ...<Widget>[
                            const SizedBox(height: 10),
                            Row(
                              children: <Widget>[
                                Expanded(
                                  child: Slider(
                                    value: (_globalCapSeconds / 60)
                                        .clamp(15, 1440)
                                        .toDouble(),
                                    min: 15,
                                    max: 240,
                                    divisions: 45,
                                    label:
                                        '${(_globalCapSeconds / 60).round()}분',
                                    onChanged: (double v) async {
                                      await GlobalUsageCapService.instance
                                          .setMaxMinutes(v.round());
                                      await UsageQuotaEnforcerService.instance
                                          .evaluateAndApply();
                                      await _reload();
                                    },
                                  ),
                                ),
                                Text('${(_globalCapSeconds / 60).round()}분'),
                              ],
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Row(
                        children: <Widget>[
                          const Icon(Icons.schedule, color: AppColors.muted),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              '집계 구간 (자정 기준)',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                          DropdownButton<int>(
                            value: _periodHours.clamp(1, 24),
                            items: List<DropdownMenuItem<int>>.generate(
                              24,
                              (int i) {
                                final int h = i + 1;
                                return DropdownMenuItem<int>(
                                  value: h,
                                  child: Text(
                                    h >= 24 ? '24시간 (하루)' : '$h시간',
                                  ),
                                );
                              },
                            ),
                            onChanged: (int? v) async {
                              if (v == null) return;
                              await UsageBucketConfigService.instance
                                  .setPeriodHours(v);
                              await _reload();
                            },
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                FutureBuilder<bool>(
                  future: _policy.canEditLimitsNow(),
                  builder: (BuildContext _, AsyncSnapshot<bool> snap) {
                    final bool can = snap.data ?? true;
                    final Color tone =
                        can ? AppColors.success : AppColors.warning;
                    return Card(
                      color: tone.withValues(alpha: 0.08),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: <Widget>[
                            Row(
                              children: <Widget>[
                                Icon(
                                  can ? Icons.edit : Icons.lock_clock,
                                  color: tone,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    can
                                        ? '상한 편집 가능 (스케줄 잠금과 별도)'
                                        : '상한 약화/삭제 잠금 — 예약된 시각까지 대기',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: tone,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            if (!can)
                              FilledButton.tonal(
                                onPressed: _requestTomorrowUnlock,
                                child: const Text('내일 아침(06:00)부터 풀기 예약'),
                              ),
                            if (can)
                              TextButton(
                                onPressed: () async {
                                  await _policy.clearScheduledUnlock();
                                  setState(() {});
                                },
                                child: const Text('예약된 편집 잠금 제거'),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    if (Platform.isMacOS)
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: _addFromFrontmost,
                          icon: const Icon(Icons.add),
                          label: const Text('전면 앱'),
                        ),
                      ),
                    if (Platform.isMacOS) const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: (Platform.isMacOS || Platform.isWindows)
                            ? _addWebHostLimit
                            : null,
                        icon: const Icon(Icons.language),
                        label: const Text('웹사이트 제한'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text('상한 목록',
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                if (_limits.isEmpty)
                  const Text('아직 상한이 없습니다.',
                      style: TextStyle(color: AppColors.muted))
                else
                  ..._limits.map((Map<String, Object?> r) {
                    final String sid = r['subject']! as String;
                    return FutureBuilder<QuotaStatus?>(
                      future: UsageQuotaEnforcerService.instance
                          .statusForLimit(r),
                      builder: (BuildContext _, AsyncSnapshot<QuotaStatus?> u) {
                        final QuotaStatus? st = u.data;
                        final int used = st?.usedSeconds ?? 0;
                        final int cap = st?.capSeconds ??
                            ((r['max_seconds_per_day'] as int?) ?? 0);
                        final bool locked = st?.locked ?? false;
                        final UsageQuotaMode modeVal =
                            UsageQuotaEnforcerService.modeFromDb(
                                r['quota_mode']);
                        final String modeLabel = switch (modeVal) {
                          UsageQuotaMode.rolling => '구간',
                          UsageQuotaMode.session => '세션',
                          UsageQuotaMode.hourlyForegroundWindow => '야간 포그라운드',
                          UsageQuotaMode.daily => '하루',
                        };
                        final bool isFgWindow =
                            modeVal == UsageQuotaMode.hourlyForegroundWindow;
                        final int startH = (r['window_start_hour'] as int?) ?? -1;
                        final int endH = (r['window_end_hour'] as int?) ?? -1;
                        return Card(
                          color: locked
                              ? AppColors.danger.withValues(alpha: 0.08)
                              : null,
                          child: ListTile(
                            title: Text(r['display_label']! as String),
                            subtitle: Text(
                              isFgWindow
                                  ? (locked
                                      ? '🔒 화면 시청 잠김 (${_fmtClock(DateTime(0, 1, 1, startH))}–${_fmtClock(DateTime(0, 1, 1, endH))}) — 백그라운드 재생은 계속 가능'
                                      : '야간(${_fmtClock(DateTime(0, 1, 1, startH))}–${_fmtClock(DateTime(0, 1, 1, endH))}) 시간당 ${_fmtDur(cap)} · 이번 시간 ${_fmtDur(used)} · 백그라운드 무제한')
                                  : (locked
                                      ? '🔒 잠김 ($modeLabel) — DNS 차단 중'
                                      : '$modeLabel · ${_fmtDur(used)} / ${_fmtDur(cap)} · 남음 ${_fmtDur(st?.remainingSeconds ?? 0)}'),
                              style: TextStyle(
                                color: locked ? AppColors.danger : AppColors.muted,
                                fontWeight:
                                    locked ? FontWeight.w700 : FontWeight.w400,
                              ),
                            ),
                            trailing: PopupMenuButton<String>(
                              onSelected: (String v) {
                                if (v == 'edit') _editLimit(r);
                                if (v == 'del') _deleteLimit(r['id']! as String);
                                if (v == 'pick') {
                                  setState(() => _selectedSubject = sid);
                                }
                              },
                              itemBuilder: (_) => const <PopupMenuEntry<String>>[
                                PopupMenuItem<String>(
                                  value: 'pick',
                                  child: Text('시간표 보기'),
                                ),
                                PopupMenuItem<String>(
                                  value: 'edit',
                                  child: Text('수정'),
                                ),
                                PopupMenuItem<String>(
                                  value: 'del',
                                  child: Text('삭제'),
                                ),
                              ],
                            ),
                            onTap: () => setState(() => _selectedSubject = sid),
                          ),
                        );
                      },
                    );
                  }),
                if (_selectedSubject != null) ...<Widget>[
                  const SizedBox(height: 20),
                  Text('구간별 사용 (선택한 항목)',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  FutureBuilder<List<Map<String, Object?>>>(
                    future: _db.usageHourlyForSubjectOnDay(
                      _selectedSubject!,
                      DateTime.now(),
                    ),
                    builder: (BuildContext _,
                        AsyncSnapshot<List<Map<String, Object?>>> snap) {
                      final List<Map<String, Object?>> rows =
                          snap.data ?? const <Map<String, Object?>>[];
                      if (rows.isEmpty) {
                        return const Text(
                          '오늘 아직 기록이 없습니다.',
                          style: TextStyle(color: AppColors.muted),
                        );
                      }
                      return Column(
                        children: rows.map((Map<String, Object?> h) {
                          final int ms = h['hour_start_ms']! as int;
                          final int sec = (h['seconds'] as int?) ?? 0;
                          final int fg = (h['fg_seconds'] as int?) ?? sec;
                          final int bg = (h['bg_seconds'] as int?) ?? 0;
                          final String trail = bg > 0
                              ? '${_fmtDur(sec)} (화면 ${_fmtDur(fg)} · 백그라운드 ${_fmtDur(bg)})'
                              : _fmtDur(sec);
                          return ListTile(
                            dense: true,
                            title: Text(_bucketRangeLabel(ms)),
                            trailing: Text(
                              trail,
                              style: const TextStyle(fontSize: 12),
                            ),
                          );
                        }).toList(),
                      );
                    },
                  ),
                ],
              ],
            ),
    );
  }
}
