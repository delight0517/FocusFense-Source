import 'package:flutter/material.dart';
import '../localization/app_i18n.dart';
import '../services/browser_performance_prefs.dart';
import '../services/backup_service.dart';
import '../services/extension_rules_snapshot_service.dart';
import '../services/local_database.dart';
import '../services/lock_policy_service.dart';

/// A cosmetic feed-filter preference, not a second protection/enforcement path.
class FirefoxPerformanceCard extends StatefulWidget {
  const FirefoxPerformanceCard({
    super.key,
    required this.locale,
    this.readFiltering,
    this.writeFiltering,
    this.publishSnapshot,
    this.settingsLocked,
    this.scheduleBackup,
  });
  final Locale locale;
  final Future<bool> Function()? readFiltering;
  final Future<void> Function(bool enabled)? writeFiltering;
  final Future<bool> Function()? publishSnapshot;
  final Future<bool> Function()? settingsLocked;
  final VoidCallback? scheduleBackup;
  @override
  State<FirefoxPerformanceCard> createState() => _FirefoxPerformanceCardState();
}

class _FirefoxPerformanceCardState extends State<FirefoxPerformanceCard> {
  bool _light = false, _busy = true, _locked = false;
  String? _message;
  static const _words = <String, Map<String, String>>{
    'en': {
      'title': 'Firefox performance',
      'mode': 'Light mode',
      'description':
          'Skip costly hiding of YouTube feed and search-result cards. Website, channel, adult-site blocking and viewing limits continue.',
      'saved': 'Preference saved and Firefox rules prepared.',
      'pending':
          'Preference saved. Firefox receives it when connected to FocusFense.',
      'error': 'Could not save this setting.',
      'locked': 'Unlock protection settings before changing this option.',
    },
    'ko': {
      'title': 'Firefox 성능',
      'mode': '가벼운 모드',
      'description':
          '비용이 큰 YouTube 피드·검색 결과 카드 숨김을 생략합니다. 사이트·채널·성인 사이트 차단과 시청 시간 제한은 계속 적용됩니다.',
      'saved': '설정을 저장하고 Firefox 규칙을 준비했습니다.',
      'pending': '설정을 저장했습니다. Firefox가 FocusFense에 연결되면 반영됩니다.',
      'error': '설정을 저장하지 못했습니다.',
      'locked': '보호 설정 잠금을 해제한 뒤 변경해 주세요.',
    },
    'ja': {
      'title': 'Firefoxのパフォーマンス',
      'mode': '軽量モード',
      'description':
          '負荷の高いYouTubeフィード・検索結果カードの非表示を省略します。サイト・チャンネル・成人向けサイトの遮断と視聴時間制限は継続します。',
      'saved': '設定を保存し、Firefoxのルールを準備しました。',
      'pending': '設定を保存しました。FirefoxがFocusFenseに接続すると反映されます。',
      'error': '設定を保存できませんでした。',
      'locked': '保護設定のロックを解除してから変更してください。',
    },
    'zh': {
      'title': 'Firefox 性能',
      'mode': '轻量模式',
      'description': '跳过高负载的YouTube推荐和搜索结果卡片隐藏。网站、频道、成人网站拦截和观看时长限制仍然有效。',
      'saved': '已保存设置并准备好Firefox规则。',
      'pending': '已保存设置。Firefox连接到FocusFense时会应用。',
      'error': '无法保存设置。',
      'locked': '请先解除保护设置锁定。',
    },
    'he': {
      'title': 'ביצועי Firefox',
      'mode': 'מצב קל',
      'description':
          'דילוג על הסתרת כרטיסי פיד ותוצאות חיפוש ב-YouTube. חסימת אתרים, ערוצים ותוכן למבוגרים והגבלות צפייה ממשיכות לפעול.',
      'saved': 'ההעדפה נשמרה וכללי Firefox הוכנו.',
      'pending': 'ההעדפה נשמרה ותוחל כש-Firefox יתחבר ל-FocusFense.',
      'error': 'לא ניתן לשמור את ההגדרה.',
      'locked': 'יש לפתוח את נעילת הגדרות ההגנה לפני השינוי.',
    },
    'ar': {
      'title': 'أداء Firefox',
      'mode': 'الوضع الخفيف',
      'description':
          'تجاوز إخفاء بطاقات اقتراحات YouTube ونتائج البحث المكلف. يستمر حظر المواقع والقنوات ومواقع البالغين وحدود المشاهدة.',
      'saved': 'حُفظ الإعداد وجُهزت قواعد Firefox.',
      'pending': 'حُفظ الإعداد ويُطبق عندما يتصل Firefox بتطبيق FocusFense.',
      'error': 'تعذر حفظ الإعداد.',
      'locked': 'افتح قفل إعدادات الحماية قبل تغيير هذا الخيار.',
    },
  };
  String _t(String key) {
    final code =
        AppI18n.supportedLocales.any(
          (l) => l.languageCode == widget.locale.languageCode,
        )
        ? widget.locale.languageCode
        : 'en';
    return _words[code]?[key] ?? _words['en']![key]!;
  }

  Future<bool> _isLocked() async =>
      widget.settingsLocked?.call() ??
      LockPolicyService.instance.isEffectivelyLocked(
        await LocalDatabase.instance.rulesMeta(),
      );
  Future<bool> _read() =>
      widget.readFiltering?.call() ??
      BrowserPerformancePrefs.instance.youtubeFeedFiltering();
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final filtering = await _read(), locked = await _isLocked();
      if (mounted) {
        setState(() {
          _light = !filtering;
          _locked = locked;
          _busy = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _message = 'error';
          _busy = false;
        });
      }
    }
  }

  Future<void> _change(bool light) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (await _isLocked()) {
        if (mounted) {
          setState(() {
            _locked = true;
            _message = 'locked';
          });
        }
        return;
      }
      final write =
          widget.writeFiltering ??
          BrowserPerformancePrefs.instance.setYoutubeFeedFiltering;
      await write(!light);
      (widget.scheduleBackup ?? BackupService.instance.scheduleSync)();
      if (mounted) setState(() => _light = light);
      // Firefox snapshots have no throttle; this call always prepares current rules.
      final prepared =
          await (widget.publishSnapshot?.call() ??
              ExtensionRulesSnapshotService.instance.writeToFirefoxPayload());
      if (mounted) setState(() => _message = prepared ? 'saved' : 'pending');
    } catch (_) {
      if (mounted) setState(() => _message = 'error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(_t('title'), style: Theme.of(context).textTheme.titleMedium),
          SwitchListTile(
            key: const Key('firefox-light-mode'),
            contentPadding: EdgeInsets.zero,
            title: Text(_t('mode')),
            value: _light,
            onChanged: _busy || _locked ? null : _change,
          ),
          Text(_t('description')),
          if (_busy)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: LinearProgressIndicator(),
            ),
          if (_locked)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_t('locked')),
            ),
          if (_message != null && !(_locked && _message == 'locked'))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Semantics(liveRegion: true, child: Text(_t(_message!))),
            ),
        ],
      ),
    ),
  );
}
