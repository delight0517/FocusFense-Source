import 'dart:async';

import 'package:flutter/material.dart';

import '../constants/support_constants.dart';
import '../services/browser_block_enforcement_health_service.dart';
import '../services/build_identity_service.dart';
import '../services/platform_process.dart';
import '../services/user_feedback_service.dart';
import '../theme/app_colors.dart';
import '../widgets/copyable_snackbar.dart';

/// Send issue reports with bundled crash / block / app logs.
class UserFeedbackScreen extends StatefulWidget {
  const UserFeedbackScreen({
    super.key,
    this.initialCategory,
    this.initialMessage,
  });

  final FeedbackCategory? initialCategory;
  final String? initialMessage;

  @override
  State<UserFeedbackScreen> createState() => _UserFeedbackScreenState();
}

class _UserFeedbackScreenState extends State<UserFeedbackScreen> {
  final TextEditingController _messageCtrl = TextEditingController();
  FeedbackCategory _category = FeedbackCategory.blockNotWorking;
  bool _includeLogs = true;
  bool _busy = false;
  String? _buildLine;
  BrowserEnforcementHealth? _health;
  UserFeedbackBundleResult? _lastBundle;

  @override
  void initState() {
    super.initState();
    _category = widget.initialCategory ?? FeedbackCategory.blockNotWorking;
    if (widget.initialMessage != null) {
      _messageCtrl.text = widget.initialMessage!;
    }
    unawaited(_loadContext());
  }

  @override
  void dispose() {
    _messageCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadContext() async {
    final String line = await BuildIdentityService.instance.summaryLine();
    final BrowserEnforcementHealth h =
        await BrowserBlockEnforcementHealthService.instance.analyze();
    if (!mounted) return;
    setState(() {
      _buildLine = line;
      _health = h;
    });
  }

  Future<void> _submit({required bool openMail}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final UserFeedbackBundleResult bundle =
          await UserFeedbackService.instance.createBundle(
        category: _category,
        userMessage: _messageCtrl.text,
        includeLogs: _includeLogs,
      );
      _lastBundle = bundle;
      if (!mounted) return;
      if (!bundle.ok) {
        showCopyableSnackBar(context, bundle.message);
        if (bundle.stagingDir != null) {
          await PlatformProcess.openFolder(bundle.stagingDir!);
        }
        return;
      }

      if (openMail) {
        await UserFeedbackService.instance.sendWithMailAndReveal(
          bundle: bundle,
          category: _category,
        );
      } else if (bundle.zipPath != null) {
        await PlatformProcess.revealFileInFolder(bundle.zipPath!);
      } else if (bundle.stagingDir != null) {
        await PlatformProcess.openFolder(bundle.stagingDir!);
      }

      if (!mounted) return;
      final String email = kDeveloperFeedbackEmail.trim();
      final String tail = email.isEmpty
          ? 'ZIP 파일을 카카오·디스코드·메일에 첨부해 보내 주세요.'
          : '메일 앱이 열리면 ZIP을 첨부해 보내 주세요.';
      showCopyableSnackBar(
        context,
        '${bundle.message}\n$tail',
        duration: const Duration(seconds: 12),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copySummary() async {
    if (_lastBundle == null) {
      final UserFeedbackBundleResult bundle =
          await UserFeedbackService.instance.createBundle(
        category: _category,
        userMessage: _messageCtrl.text,
        includeLogs: false,
      );
      _lastBundle = bundle;
      if (!bundle.ok) {
        if (mounted) showCopyableSnackBar(context, bundle.message);
        return;
      }
    }
    await UserFeedbackService.instance.copySummary(_lastBundle!);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('요약이 클립보드에 복사되었습니다.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final BrowserEnforcementHealth? h = _health;

    return Scaffold(
      appBar: AppBar(
        title: const Text('문제 신고 · 피드백'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: <Widget>[
          Card(
            color: AppColors.accent.withValues(alpha: 0.08),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '앱이 망가진 게 아닐 수도 있어요',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '차단이 안 되거나 오류가 나면, 아래에서 증상을 적고 '
                    '「진단 로그와 함께 보내기」를 누르세요. '
                    '개발자가 원인을 바로 볼 수 있는 ZIP이 만들어집니다.',
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.45),
                  ),
                  if (_buildLine != null) ...<Widget>[
                    const SizedBox(height: 8),
                    SelectableText(
                      _buildLine!,
                      style: theme.textTheme.labelSmall?.copyWith(
                        fontFamily: 'Menlo',
                        color: AppColors.muted,
                      ),
                    ),
                  ],
                  if (h != null && h.youtubeRuleCount > 0) ...<Widget>[
                    const SizedBox(height: 6),
                    Text(
                      '유튜브 규칙 ${h.youtubeRuleCount}개 · 최근 차단 ${h.recentBlockCount}건 · ${h.phase.name}',
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: AppColors.muted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Text('무엇이 문제인가요?', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: FeedbackCategory.values.map((FeedbackCategory c) {
              final bool sel = _category == c;
              return ChoiceChip(
                label: Text(c.label),
                selected: sel,
                onSelected: (_) => setState(() => _category = c),
              );
            }).toList(),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _messageCtrl,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: '증상 설명 (선택)',
              hintText:
                  '예: LowkoTV 영상이 Chrome에서 그대로 재생됨. 쉬운 설치는 했음.',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('진단 로그 첨부 (권장)'),
            subtitle: const Text(
              'crash_journal · block_activity · app.log — 개인 메모·비밀번호는 포함되지 않습니다.',
            ),
            value: _includeLogs,
            onChanged: _busy ? null : (bool v) => setState(() => _includeLogs = v),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _busy ? null : () => _submit(openMail: true),
            icon: _busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.send_outlined),
            label: Text(_busy ? 'ZIP 만드는 중…' : '진단 로그와 함께 보내기'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : () => _submit(openMail: false),
            icon: const Icon(Icons.folder_zip_outlined),
            label: const Text('ZIP만 만들고 폴더 열기'),
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _busy ? null : _copySummary,
            icon: const Icon(Icons.copy_all_outlined, size: 18),
            label: const Text('요약만 클립보드에 복사'),
          ),
          const SizedBox(height: 20),
          Text('ZIP에 들어가는 것', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          ...<String>[
            'feedback_report.json — 빌드·차단 상태·보호 요약',
            'crash_journal.jsonl — 앱 오류 타임라인',
            'block_activity_summary.json — 실시간 차단·규칙',
            'app.log — 최근 앱 로그',
            'user_message.txt — 위에 적은 증상',
          ].map(
            (String line) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text('· '),
                  Expanded(
                    child: Text(
                      line,
                      style: theme.textTheme.bodySmall?.copyWith(height: 1.35),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (kDeveloperFeedbackEmail.trim().isEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Text(
              '개발자 메일 주소가 아직 설정되지 않았습니다. '
              'ZIP을 메신저나 메일에 직접 첨부해 보내 주세요.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.muted,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
