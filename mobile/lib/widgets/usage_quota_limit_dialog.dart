import 'package:flutter/material.dart';

import '../services/usage_quota_enforcer_service.dart';
import '../theme/app_colors.dart';

/// Result from [showUsageQuotaLimitDialog].
final class UsageQuotaLimitDialogResult {
  const UsageQuotaLimitDialogResult({
    this.host,
    this.displayLabel,
    required this.maxSeconds,
    required this.quotaMode,
    required this.windowSeconds,
    required this.sessionMaxSeconds,
    required this.sessionPeriodSeconds,
  });

  final String? host;
  final String? displayLabel;
  final int maxSeconds;
  final String quotaMode;
  final int windowSeconds;
  final int sessionMaxSeconds;
  final int sessionPeriodSeconds;
}

Future<UsageQuotaLimitDialogResult?> showUsageQuotaLimitDialog(
  BuildContext context, {
  String title = '사이트 시간 제한',
  String? initialHost,
  String? initialLabel,
  bool showHostFields = true,
  UsageQuotaMode initialMode = UsageQuotaMode.daily,
  int initialAllowMinutes = 60,
  int initialWindowHours = 3,
  int initialSessionMinutes = 50,
  int initialResetMinutes = 30,
}) {
  final TextEditingController hostCtrl =
      TextEditingController(text: initialHost ?? '');
  final TextEditingController labelCtrl =
      TextEditingController(text: initialLabel ?? '');
  final TextEditingController allowMinCtrl =
      TextEditingController(text: '$initialAllowMinutes');
  final TextEditingController windowHrCtrl =
      TextEditingController(text: '$initialWindowHours');
  final TextEditingController resetMinCtrl =
      TextEditingController(text: '$initialResetMinutes');

  UsageQuotaMode mode = initialMode;

  return showDialog<UsageQuotaLimitDialogResult>(
    context: context,
    builder: (BuildContext ctx) {
      return StatefulBuilder(
        builder: (BuildContext context, StateSetter setSt) {
          return AlertDialog(
            title: Text(title),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (showHostFields) ...<Widget>[
                    TextField(
                      controller: hostCtrl,
                      autocorrect: false,
                      decoration: const InputDecoration(
                        labelText: '사이트 (호스트)',
                        hintText: 'youtube.com',
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextField(
                      controller: labelCtrl,
                      decoration: const InputDecoration(labelText: '표시 이름'),
                    ),
                    const SizedBox(height: 12),
                  ],
                  const Text(
                    '빠른 설정',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: <Widget>[
                      ActionChip(
                        label: const Text('하루 2시간'),
                        onPressed: () {
                          setSt(() {
                            mode = UsageQuotaMode.daily;
                            allowMinCtrl.text = '120';
                          });
                        },
                      ),
                      ActionChip(
                        label: const Text('하루 1시간'),
                        onPressed: () {
                          setSt(() {
                            mode = UsageQuotaMode.daily;
                            allowMinCtrl.text = '60';
                          });
                        },
                      ),
                      ActionChip(
                        label: const Text('1시간당 15분'),
                        onPressed: () {
                          setSt(() {
                            mode = UsageQuotaMode.rolling;
                            allowMinCtrl.text = '15';
                            windowHrCtrl.text = '1';
                          });
                        },
                      ),
                      ActionChip(
                        label: const Text('3시간당 1시간'),
                        onPressed: () {
                          setSt(() {
                            mode = UsageQuotaMode.rolling;
                            allowMinCtrl.text = '60';
                            windowHrCtrl.text = '3';
                          });
                        },
                      ),
                      ActionChip(
                        label: const Text('50분/30분 주기'),
                        onPressed: () {
                          setSt(() {
                            mode = UsageQuotaMode.session;
                            allowMinCtrl.text = '50';
                            resetMinCtrl.text = '30';
                          });
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    '제한 방식',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                  ),
                  const SizedBox(height: 6),
                  SegmentedButton<UsageQuotaMode>(
                    segments: const <ButtonSegment<UsageQuotaMode>>[
                      ButtonSegment<UsageQuotaMode>(
                        value: UsageQuotaMode.daily,
                        label: Text('하루'),
                        icon: Icon(Icons.today_outlined, size: 16),
                      ),
                      ButtonSegment<UsageQuotaMode>(
                        value: UsageQuotaMode.rolling,
                        label: Text('구간'),
                        icon: Icon(Icons.timelapse, size: 16),
                      ),
                      ButtonSegment<UsageQuotaMode>(
                        value: UsageQuotaMode.session,
                        label: Text('세션'),
                        icon: Icon(Icons.replay, size: 16),
                      ),
                    ],
                    selected: <UsageQuotaMode>{mode},
                    onSelectionChanged: (Set<UsageQuotaMode> v) {
                      setSt(() => mode = v.first);
                    },
                  ),
                  const SizedBox(height: 10),
                  TextField(
                    controller: allowMinCtrl,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: mode == UsageQuotaMode.session
                          ? '세션당 허용 (분)'
                          : '허용 시간 (분)',
                      helperText: mode == UsageQuotaMode.daily
                          ? '오늘 이 시간까지 이용 가능. 초과 시 DNS로 완전 차단.'
                          : mode == UsageQuotaMode.rolling
                              ? '아래 구간 안에서만 허용.'
                              : '한 주기 안에서 이 시간까지. 초과 시 차단 후 주기가 끝나면 다시 풀림.',
                    ),
                  ),
                  if (mode == UsageQuotaMode.rolling) ...<Widget>[
                    const SizedBox(height: 8),
                    TextField(
                      controller: windowHrCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '구간 길이 (시간)',
                        helperText: '예: 3 → 최근 3시간 동안의 사용량만 합산',
                      ),
                    ),
                  ],
                  if (mode == UsageQuotaMode.session) ...<Widget>[
                    const SizedBox(height: 8),
                    TextField(
                      controller: resetMinCtrl,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: '주기마다 리셋 (분)',
                        helperText: '예: 30 → 30분마다 허용 시간이 다시 채워짐',
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  Text(
                    '시간이 다 차면 hosts(DNS)로 해당 사이트가 완전히 잠깁니다. '
                    '이 앱이 켜져 있어야 하며, 웹은 Chrome/Edge 확장으로 시간이 측정됩니다.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppColors.muted,
                          height: 1.35,
                        ),
                  ),
                ],
              ),
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('취소'),
              ),
              FilledButton(
                onPressed: () {
                  final int allowMin =
                      int.tryParse(allowMinCtrl.text.trim()) ?? 60;
                  final int windowHr =
                      int.tryParse(windowHrCtrl.text.trim()) ?? 3;
                  final int resetMin =
                      int.tryParse(resetMinCtrl.text.trim()) ?? 30;
                  final String modeStr = switch (mode) {
                    UsageQuotaMode.daily => 'daily',
                    UsageQuotaMode.rolling => 'rolling',
                    UsageQuotaMode.session => 'session',
                    UsageQuotaMode.hourlyForegroundWindow => 'hourly_fg_window',
                  };
                  Navigator.pop(
                    ctx,
                    UsageQuotaLimitDialogResult(
                      host: showHostFields ? hostCtrl.text.trim() : initialHost,
                      displayLabel: showHostFields
                          ? labelCtrl.text.trim()
                          : initialLabel,
                      maxSeconds: (allowMin.clamp(1, 24 * 60)) * 60,
                      quotaMode: modeStr,
                      windowSeconds:
                          (windowHr.clamp(1, 48)) * 3600,
                      sessionMaxSeconds:
                          (allowMin.clamp(1, 24 * 60)) * 60,
                      sessionPeriodSeconds:
                          (resetMin.clamp(5, 24 * 60)) * 60,
                    ),
                  );
                },
                child: const Text('저장'),
              ),
            ],
          );
        },
      );
    },
  );
}
