import 'package:flutter/material.dart';
import '../localization/app_i18n.dart';
import '../services/game_daily_budget_service.dart';

typedef GameDailyBudgetConfigure =
    Future<Map<String, Object?>> Function({
      required bool enabled,
      required int maxMinutes,
      required int warningMinutes,
      required List<String> targets,
    });

/// Edits the existing shared game allowance; never starts another enforcer.
class GameDailyBudgetCard extends StatefulWidget {
  const GameDailyBudgetCard({
    super.key,
    required this.locale,
    this.readStatus,
    this.configure,
  });
  final Locale locale;
  final Future<Map<String, Object?>> Function()? readStatus;
  final GameDailyBudgetConfigure? configure;
  @override
  State<GameDailyBudgetCard> createState() => _GameDailyBudgetCardState();
}

class _GameDailyBudgetCardState extends State<GameDailyBudgetCard> {
  final _minutes = TextEditingController(text: '30');
  final _warning = TextEditingController(text: '10');
  Map<String, Object?>? _status;
  bool _enabled = false, _busy = true;
  String? _notice;
  bool _noticeError = false;

  static const _words = <String, Map<String, String>>{
    'en': {
      'exhausted':
          'Today’s game allowance is exhausted. It resets at local midnight.',
      'title': 'Daily game allowance',
      'description':
          'All listed games share one daily allowance. The warning appears when the configured time remains.',
      'enabled': 'Limit game time',
      'max': 'Daily limit (minutes)',
      'warning': 'Warn with this many minutes left',
      'used': 'Used',
      'remaining': 'Remaining',
      'reset': 'Resets',
      'targets': 'Games sharing this allowance',
      'empty':
          'No game executables are configured. Existing game targets are preserved when saving.',
      'save': 'Save',
      'refresh': 'Refresh usage',
      'saved': 'Game allowance saved.',
      'error':
          'Could not update the allowance. Check Lock Mode and the values.',
      'invalid':
          'Enter a daily limit of 1–1440 minutes and a warning between 0 and the limit.',
      'locked':
          'Lock Mode prevents disabling or weakening the current allowance.',
      'minute': 'min',
      'second': 's',
    },
    'ko': {
      'exhausted': '오늘 게임 시간을 모두 사용했습니다. 자정에 초기화됩니다.',
      'title': '게임 하루 공통 시간',
      'description': '아래 게임들이 하루 한도를 함께 사용합니다. 설정한 시간이 남으면 경고합니다.',
      'enabled': '게임 시간 제한',
      'max': '하루 한도 (분)',
      'warning': '경고할 남은 시간 (분)',
      'used': '사용',
      'remaining': '남음',
      'reset': '초기화',
      'targets': '시간을 함께 사용하는 게임',
      'empty': '등록된 게임 실행 파일이 없습니다. 저장할 때 기존 게임 대상은 그대로 유지합니다.',
      'save': '저장',
      'refresh': '사용량 새로고침',
      'saved': '게임 시간 설정을 저장했습니다.',
      'error': '설정을 적용하지 못했습니다. 잠금 상태와 입력값을 확인해 주세요.',
      'invalid': '하루 한도는 1~1440분, 경고 시간은 0분부터 하루 한도 사이로 입력해 주세요.',
      'locked': '잠금 중에는 현재 제한을 끄거나 약하게 바꿀 수 없습니다.',
      'minute': '분',
      'second': '초',
    },
    'ja': {
      'exhausted': '今日のゲーム上限に達しました。午前0時にリセットします。',
      'title': 'ゲーム共通の1日上限',
      'description': '一覧のゲームで1日の上限を共有します。設定した残り時間で警告します。',
      'enabled': 'ゲーム時間を制限',
      'max': '1日の上限（分）',
      'warning': '警告する残り時間（分）',
      'used': '使用済み',
      'remaining': '残り',
      'reset': 'リセット',
      'targets': '上限を共有するゲーム',
      'empty': 'ゲームの実行ファイルが未登録です。保存時は既存の対象を維持します。',
      'save': '保存',
      'refresh': '使用量を更新',
      'saved': 'ゲーム時間の設定を保存しました。',
      'error': '設定できませんでした。ロックと入力値を確認してください。',
      'invalid': '上限は1～1440分、警告は0分から上限の間で入力してください。',
      'locked': 'ロック中は制限の解除や緩和ができません。',
      'minute': '分',
      'second': '秒',
    },
    'zh': {
      'exhausted': '今日游戏限额已用完，将于本地午夜重置。',
      'title': '游戏每日共用时长',
      'description': '下列游戏共用每日限额。剩余时间达到设置值时提醒。',
      'enabled': '限制游戏时间',
      'max': '每日限额（分钟）',
      'warning': '提醒时的剩余分钟数',
      'used': '已用',
      'remaining': '剩余',
      'reset': '重置',
      'targets': '共用限额的游戏',
      'empty': '尚未设置游戏执行文件。保存时会保留现有游戏目标。',
      'save': '保存',
      'refresh': '刷新使用量',
      'saved': '已保存游戏时间设置。',
      'error': '无法应用设置。请检查锁定状态和输入值。',
      'invalid': '每日限额为1至1440分钟，提醒值为0至每日限额。',
      'locked': '锁定期间无法关闭或放宽现有限额。',
      'minute': '分钟',
      'second': '秒',
    },
    'he': {
      'exhausted': 'מכסת המשחק להיום נוצלה. האיפוס בחצות המקומית.',
      'title': 'מכסת משחק יומית משותפת',
      'description':
          'המשחקים ברשימה חולקים מכסה יומית. האזהרה מופיעה כשנותר הזמן שהוגדר.',
      'enabled': 'הגבלת זמן משחק',
      'max': 'מכסה יומית בדקות',
      'warning': 'התרעה כשנותרו דקות',
      'used': 'נוצלו',
      'remaining': 'נותרו',
      'reset': 'איפוס',
      'targets': 'משחקים שחולקים את המכסה',
      'empty': 'לא הוגדרו קובצי משחק. שמירה משמרת את המשחקים הקיימים.',
      'save': 'שמירה',
      'refresh': 'רענון השימוש',
      'saved': 'מכסת המשחק נשמרה.',
      'error': 'לא ניתן לעדכן. יש לבדוק את מצב הנעילה והערכים.',
      'invalid': 'יש להזין מכסה של 1–1440 דקות ואזהרה בין 0 למכסה.',
      'locked': 'מצב נעילה מונע ביטול או החלשה של המכסה.',
      'minute': 'דק׳',
      'second': 'שנ׳',
    },
    'ar': {
      'exhausted': 'انتهى وقت اللعب اليومي. يُعاد ضبطه عند منتصف الليل المحلي.',
      'title': 'وقت ألعاب يومي مشترك',
      'description':
          'تشترك الألعاب المدرجة في حد يومي واحد. يظهر التنبيه عند بلوغ الوقت المتبقي المحدد.',
      'enabled': 'تحديد وقت اللعب',
      'max': 'الحد اليومي بالدقائق',
      'warning': 'التنبيه عند بقاء هذا العدد من الدقائق',
      'used': 'المستخدم',
      'remaining': 'المتبقي',
      'reset': 'إعادة الضبط',
      'targets': 'الألعاب المشتركة في الحد',
      'empty': 'لم تُحدد ملفات ألعاب. يحافظ الحفظ على الألعاب الحالية.',
      'save': 'حفظ',
      'refresh': 'تحديث الاستخدام',
      'saved': 'تم حفظ وقت اللعب.',
      'error': 'تعذر التحديث. تحقق من القفل والقيم.',
      'invalid': 'أدخل حداً من 1 إلى 1440 دقيقة وتنبيهاً بين 0 والحد.',
      'locked': 'يمنع القفل تعطيل الحد الحالي أو تخفيفه.',
      'minute': 'د',
      'second': 'ث',
    },
  };

  String _t(String key) {
    final language =
        AppI18n.supportedLocales.any(
          (l) => l.languageCode == widget.locale.languageCode,
        )
        ? widget.locale.languageCode
        : 'en';
    return _words[language]?[key] ?? _words['en']![key]!;
  }

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _minutes.dispose();
    _warning.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final value =
          await (widget.readStatus?.call() ??
              GameDailyBudgetService.instance.status());
      if (!mounted) return;
      setState(() {
        _status = value;
        _enabled = value['enabled'] == true;
        _minutes.text = '${value['maxMinutes'] ?? 30}';
        _warning.text = '${value['warningMinutes'] ?? 10}';
        _busy = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _notice = 'error';
          _noticeError = true;
          _busy = false;
        });
      }
    }
  }

  List<String> get _targets =>
      ((_status?['targets'] as List?) ?? const []).whereType<String>().toList();

  Future<void> _save() async {
    final minutes = int.tryParse(_minutes.text.trim()),
        warning = int.tryParse(_warning.text.trim());
    if (minutes == null ||
        minutes < 1 ||
        minutes > 1440 ||
        warning == null ||
        warning < 0 ||
        warning >= minutes) {
      setState(() {
        _notice = 'invalid';
        _noticeError = true;
      });
      return;
    }
    setState(() {
      _busy = true;
      _notice = null;
    });
    try {
      final configure =
          widget.configure ?? GameDailyBudgetService.instance.configure;
      final value = await configure(
        enabled: _enabled,
        maxMinutes: minutes,
        warningMinutes: warning,
        targets: _targets,
      );
      if (value['ok'] == false) throw StateError('Configuration rejected');
      await _refresh();
      if (mounted) {
        setState(() {
          _notice = 'saved';
          _noticeError = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _notice = 'error';
          _noticeError = true;
          _busy = false;
        });
      }
    }
  }

  String _duration(Object? value) {
    final seconds = (value is num ? value.toInt() : 0).clamp(0, 86400);
    return '${seconds ~/ 60} ${_t('minute')} ${seconds % 60} ${_t('second')}';
  }

  String? _reset(BuildContext context) {
    final date = DateTime.tryParse('${_status?['resetAt'] ?? ''}')?.toLocal();
    if (date == null) return null;
    final localization = MaterialLocalizations.of(context);
    return '${localization.formatCompactDate(date)} ${localization.formatTimeOfDay(TimeOfDay.fromDateTime(date))}';
  }

  @override
  Widget build(BuildContext context) {
    final targets = _targets, reset = _reset(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.sports_esports_outlined),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _t('title'),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: _t('refresh'),
                  onPressed: _busy
                      ? null
                      : () {
                          setState(() => _busy = true);
                          _refresh();
                        },
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            Text(_t('description')),
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: LinearProgressIndicator(),
              ),
            if (_status != null) ...[
              const SizedBox(height: 12),
              Text(
                '${_t('used')}: ${_duration(_status!['usedSeconds'])}  ·  ${_t('remaining')}: ${_duration(_status!['remainingSeconds'])}',
              ),
              if (reset != null) Text('${_t('reset')}: $reset'),
              if (_status!['locked'] == true)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_t('exhausted')),
                ),
              if (_status!['settingsLocked'] == true)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(_t('locked')),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_t('enabled')),
                value: _enabled,
                onChanged: _busy || _status!['settingsLocked'] == true
                    ? null
                    : (value) => setState(() => _enabled = value),
              ),
              Wrap(
                spacing: 16,
                runSpacing: 12,
                children: [
                  SizedBox(
                    width: 240,
                    child: TextField(
                      key: const Key('game-budget-limit'),
                      controller: _minutes,
                      enabled: !_busy,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(labelText: _t('max')),
                    ),
                  ),
                  SizedBox(
                    width: 300,
                    child: TextField(
                      key: const Key('game-budget-warning'),
                      controller: _warning,
                      enabled: !_busy,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(labelText: _t('warning')),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                _t('targets'),
                style: Theme.of(context).textTheme.labelLarge,
              ),
              const SizedBox(height: 6),
              if (targets.isEmpty)
                Text(_t('empty'))
              else
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final target in targets)
                      Chip(
                        label: Text(target),
                        visualDensity: VisualDensity.compact,
                      ),
                  ],
                ),
              const SizedBox(height: 12),
              FilledButton(
                key: const Key('game-budget-save'),
                onPressed: _busy ? null : _save,
                child: Text(_t('save')),
              ),
            ],
            if (_notice != null)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    _t(_notice!),
                    style: TextStyle(
                      color: _noticeError
                          ? Theme.of(context).colorScheme.error
                          : null,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
