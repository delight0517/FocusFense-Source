import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

import '../models/block_app.dart';
import '../models/quick_block_rule_entries.dart';
import '../screens/running_apps_picker_screen.dart';
import '../services/schedule_rule_validation.dart';
import '../theme/app_colors.dart';

/// In-memory app list editor — same UX as schedule edit「차단할 앱」.
class ScheduleAppsRulesCard extends StatefulWidget {
  const ScheduleAppsRulesCard({
    super.key,
    required this.apps,
    required this.onChanged,
    this.subtitle,
  });

  final List<QuickBlockAppRule> apps;
  final ValueChanged<List<QuickBlockAppRule>> onChanged;
  final String? subtitle;

  @override
  State<ScheduleAppsRulesCard> createState() => _ScheduleAppsRulesCardState();
}

class _ScheduleAppsRulesCardState extends State<ScheduleAppsRulesCard> {
  final TextEditingController _appCtrl = TextEditingController();
  String? _appWarning;

  @override
  void dispose() {
    _appCtrl.dispose();
    super.dispose();
  }

  void _emit(List<QuickBlockAppRule> next) => widget.onChanged(next);

  Set<String> _pickerKeys() {
    final Set<String> keys = <String>{};
    for (final QuickBlockAppRule r in widget.apps) {
      final String? k = ScheduleRuleValidation.pickerKeyFromBundleId(r.bundleId);
      if (k != null) keys.add(k);
      keys.add(r.displayName.toLowerCase());
    }
    return keys;
  }

  void _addApp({String? presetName, String? bundleId}) {
    final String raw = (presetName ?? _appCtrl.text).trim();
    final String? err = ScheduleRuleValidation.validateAppName(raw);
    if (err != null) {
      setState(() => _appWarning = err);
      return;
    }
    final Set<String> existing = widget.apps
        .map((QuickBlockAppRule r) => r.displayName.toLowerCase())
        .toSet();
    if (existing.contains(raw.toLowerCase())) {
      setState(() => _appWarning = '이미 목록에 있어요.');
      return;
    }
    final List<QuickBlockAppRule> next = <QuickBlockAppRule>[
      ...widget.apps,
      QuickBlockAppRule(displayName: raw, bundleId: bundleId),
    ];
    _appCtrl.clear();
    _emit(next);
    setState(() => _appWarning = null);
  }

  Future<void> _pickRunningWindowsApps() async {
    if (!Platform.isWindows) return;
    final List<BlockApp>? picked = await Navigator.of(context).push<List<BlockApp>>(
      MaterialPageRoute<List<BlockApp>>(
        builder: (_) => RunningAppsPickerScreen(alreadyChosenKeys: _pickerKeys()),
      ),
    );
    if (picked == null || picked.isEmpty) return;

    final Set<String> keyScratch = _pickerKeys();
    int added = 0;
    int skipped = 0;
    final List<QuickBlockAppRule> next = <QuickBlockAppRule>[...widget.apps];
    for (final BlockApp app in picked) {
      final String key = ScheduleRuleValidation.pickerKeyForBlockApp(app);
      if (keyScratch.contains(key)) {
        skipped++;
        continue;
      }
      final String? err = ScheduleRuleValidation.validateAppName(app.displayName);
      if (err != null) {
        skipped++;
        if (mounted) setState(() => _appWarning = err);
        continue;
      }
      next.add(
        QuickBlockAppRule(
          displayName: app.displayName,
          bundleId: ScheduleRuleValidation.winBundlePayload(app),
        ),
      );
      keyScratch.add(key);
      keyScratch.add(app.displayName.toLowerCase());
      added++;
    }
    _emit(next);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          added == 0 && skipped > 0
              ? '추가할 새 앱이 없었어요.'
              : '실행 중 목록에서 $added개 추가${skipped > 0 ? ' · 건너뜀 $skipped' : ''}',
        ),
      ),
    );
  }

  void _remove(QuickBlockAppRule r) {
    _emit(widget.apps.where((QuickBlockAppRule x) => x != r).toList());
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool mac = Platform.isMacOS;
    final bool win = Platform.isWindows;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  Icons.apps,
                  size: 18,
                  color: mac ? MacColors.primary : AppColors.accent,
                ),
                const SizedBox(width: 8),
                Text(
                  '차단할 앱 (${widget.apps.length})',
                  style: theme.textTheme.titleSmall,
                ),
                const Spacer(),
                if (mac)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: MacColors.primaryDim,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      'Mac · 자동 종료',
                      style: TextStyle(
                        color: MacColors.secondary,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  )
                else if (win)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE3F2FD),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      'Windows · 자동 종료',
                      style: TextStyle(
                        color: Color(0xFF0D47A1),
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              widget.subtitle ??
                  (mac
                      ? '스케줄과 같이 메뉴바·Dock에 보이는 앱 이름으로 추가합니다.'
                      : win
                          ? '스케줄과 같습니다. 「실행 중인 앱에서 추가」로 지금 떠 있는 창을 고를 수 있어요.'
                          : '앱 이름을 추가합니다.'),
              style: theme.textTheme.bodySmall?.copyWith(
                color: mac ? MacColors.mutedInk : AppColors.muted,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _appCtrl,
                    autocorrect: false,
                    decoration: const InputDecoration(
                      hintText: '예: Discord',
                      prefixIcon: Icon(Icons.add_circle_outline, size: 18),
                    ),
                    onChanged: (_) {
                      if (_appWarning != null) {
                        setState(() => _appWarning = null);
                      }
                    },
                    onSubmitted: (_) => _addApp(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(onPressed: () => _addApp(), child: const Text('추가')),
              ],
            ),
            if (win) ...<Widget>[
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  onPressed: () => unawaited(_pickRunningWindowsApps()),
                  icon: const Icon(Icons.playlist_add_check_outlined, size: 20),
                  label: const Text('실행 중인 앱에서 추가'),
                ),
              ),
            ],
            if (_appWarning != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _appWarning!,
                  style: const TextStyle(color: AppColors.danger, fontSize: 12),
                ),
              ),
            const SizedBox(height: 12),
            Text(
              '빠른 추가',
              style: theme.textTheme.labelSmall?.copyWith(
                color: mac ? MacColors.mutedInk : AppColors.muted,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: ScheduleRuleValidation.appPresets
                  .map(
                    (String n) => ActionChip(
                      avatar: const Icon(Icons.add, size: 14),
                      label: Text(n),
                      onPressed: () => _addApp(presetName: n),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 12),
            if (widget.apps.isEmpty)
              Text(
                '아직 추가된 앱이 없어요.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: mac ? MacColors.mutedInk : AppColors.muted,
                ),
              )
            else
              ...widget.apps.map((QuickBlockAppRule r) {
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.apps_outage),
                  title: Text(r.displayName, overflow: TextOverflow.ellipsis),
                  subtitle: r.bundleId != null && r.bundleId!.startsWith('win|')
                      ? Text(
                          r.bundleId!.split('|').length > 1
                              ? r.bundleId!.split('|')[1]
                              : '',
                          style: theme.textTheme.bodySmall?.copyWith(fontSize: 11),
                        )
                      : null,
                  trailing: IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => _remove(r),
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }
}
