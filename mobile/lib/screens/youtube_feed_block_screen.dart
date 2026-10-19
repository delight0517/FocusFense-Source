import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/youtube_blocklist_import_service.dart';
import '../theme/app_colors.dart';
import 'browser_extensions_screen.dart';

/// Import YouTube channel/video blocklists and guide extension setup for
/// feed + Google search hiding (not DNS-wide youtube.com unless user adds it).
class YouTubeFeedBlockScreen extends StatefulWidget {
  const YouTubeFeedBlockScreen({super.key});

  @override
  State<YouTubeFeedBlockScreen> createState() => _YouTubeFeedBlockScreenState();
}

class _YouTubeFeedBlockScreenState extends State<YouTubeFeedBlockScreen> {
  bool _importing = false;
  String? _lastResult;

  Future<void> _importTxt() async {
    final FilePickerResult? pick = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: <String>['txt'],
      dialogTitle: 'YouTube 차단 목록 (.txt)',
    );
    if (pick == null || pick.files.single.path == null) return;
    setState(() {
      _importing = true;
      _lastResult = null;
    });
    try {
      final YouTubeBlocklistImportResult r =
          await YouTubeBlocklistImportService.instance.importFromFile(
        pick.files.single.path!,
      );
      if (!mounted) return;
      setState(() {
        _lastResult =
            '가져옴: 원본 ${r.sourceLines}줄 → 키워드 ${r.keywordsImported}개 '
            '(패턴 ${r.patternCount}개) · 스케줄「${YouTubeBlocklistImportService.defaultScheduleName}」켜짐';
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_lastResult!),
          action: SnackBarAction(
            label: '확장 설치',
            onPressed: () {
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const BrowserExtensionsScreen(),
                ),
              );
            },
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _lastResult = '오류: $e');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('YouTube · 검색·피드 차단')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          _howItWorksCard(theme),
          const SizedBox(height: 14),
          _stepsCard(theme),
          const SizedBox(height: 14),
          _importCard(theme),
          if (_lastResult != null) ...<Widget>[
            const SizedBox(height: 12),
            Card(
              color: AppColors.success.withValues(alpha: 0.1),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(_lastResult!, style: theme.textTheme.bodyMedium),
              ),
            ),
          ],
          const SizedBox(height: 14),
          _sampleFormatCard(theme),
        ],
      ),
    );
  }

  Widget _howItWorksCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('무엇이 실제로 막히나요?', style: theme.textTheme.titleSmall),
            const SizedBox(height: 10),
            _row(
              theme,
              'YouTube 홈·구독 피드의 해당 채널/영상 카드',
              '브라우저 확장 (키워드)',
              true,
            ),
            _row(theme, 'Google/Bing 검색 결과에 뜨는 링크', '브라우저 확장', true),
            _row(theme, '채널 URL로 직접 들어가기', '브라우저 확장 (오버레이)', true),
            _row(
              theme,
              'YouTube 앱 · 시크릿 없이 hosts만',
              '이 목록만으로는 안 됨',
              false,
            ),
            _row(
              theme,
              'youtube.com 전체 차단',
              '도메인에 youtube.com을 넣었을 때만',
              false,
            ),
            const SizedBox(height: 8),
            Text(
              '지금 가져오는 목록은 youtube.com 전체를 DNS로 막지 않습니다. '
              'Chrome/Edge/Firefox에 확장을 로드하고「규칙 동기화」해야 피드·검색에서 숨겨집니다.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.muted,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _row(
    ThemeData theme,
    String what,
    String how,
    bool yes,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            yes ? Icons.check_circle_outline : Icons.cancel_outlined,
            size: 18,
            color: yes ? AppColors.success : AppColors.muted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: RichText(
              text: TextSpan(
                style: theme.textTheme.bodySmall?.copyWith(height: 1.35),
                children: <TextSpan>[
                  TextSpan(text: what, style: const TextStyle(fontWeight: FontWeight.w600)),
                  TextSpan(text: ' — $how'),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stepsCard(ThemeData theme) {
    const String syncHint =
        '설정 → 브라우저 확장 → ①보내기 ②「규칙 동기화」③브라우저에서 확장 로드';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('설정 순서 (처음 한 번)', style: theme.textTheme.titleSmall),
            const SizedBox(height: 10),
            const _Step(n: 1, text: '아래에서 .txt 목록 가져오기 (채널·영상 URL 한 줄에 하나)'),
            const _Step(
              n: 2,
              text: '「브라우저 확장 설치 마법사」열기 → Chrome/Edge/Firefox용 폴더보내기',
            ),
            const _Step(n: 3, text: '같은 화면에서「규칙 동기화」→ sixvpn_sync.json 생성'),
            const _Step(
              n: 4,
              text: '브라우저 확장 관리에서「압축해제된 확장 프로그램」으로보낸 chrome 폴더 선택',
            ),
            const _Step(
              n: 5,
              text: '확장 옵션에서 JSON 불러오기 또는 동기화 파일이 있으면 자동 반영',
            ),
            const _Step(n: 6, text: 'youtube.com 을 연 뒤 홈/구독 피드에서 카드가 사라지는지 확인'),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () {
                      Navigator.of(context).push<void>(
                        MaterialPageRoute<void>(
                          builder: (_) => const BrowserExtensionsScreen(),
                        ),
                      );
                    },
                    icon: const Icon(Icons.extension),
                    label: const Text('브라우저 확장 설치 마법사'),
                  ),
                ),
                IconButton(
                  tooltip: '안내 복사',
                  onPressed: () {
                    Clipboard.setData(const ClipboardData(text: syncHint));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('설정 순서를 복사했습니다.')),
                    );
                  },
                  icon: const Icon(Icons.copy_outlined),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _importCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('목록 가져오기', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            Text(
              '예: `youtube.com/채널핸들`, `youtube.com/watch?v=…` 한 줄에 하나. '
              '앱이 채널별로 여러 URL 패턴으로 바꿔 저장합니다.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.muted,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _importing ? null : _importTxt,
              icon: _importing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.upload_file),
              label: Text(_importing ? '가져오는 중…' : '.txt 파일 고르기'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sampleFormatCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('파일 형식 예시', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            SelectableText(
              'youtube.com/bomulsum_g\n'
              'youtube.com/enjoycouple\n'
              'youtube.com/watch?v=14atrfg4dh4\n'
              'youtube.com/동네놈들',
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.n, required this.text});
  final int n;
  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          CircleAvatar(
            radius: 12,
            backgroundColor: AppColors.accent.withValues(alpha: 0.2),
            child: Text('$n', style: const TextStyle(fontSize: 11)),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: Theme.of(context).textTheme.bodySmall)),
        ],
      ),
    );
  }
}
