import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/cursor_one_tap_diagnostic_pack_service.dart';
import '../theme/app_colors.dart';

/// 설정→진단 — one button collects freeze/lag/block/plugin data for Cursor.
class CursorOneTapDiagnosticCard extends StatefulWidget {
  const CursorOneTapDiagnosticCard({super.key});

  @override
  State<CursorOneTapDiagnosticCard> createState() =>
      _CursorOneTapDiagnosticCardState();
}

class _CursorOneTapDiagnosticCardState extends State<CursorOneTapDiagnosticCard> {
  bool _running = false;
  String? _lastVerdict;
  String _folder = '';

  @override
  void initState() {
    super.initState();
    _folder = CursorOneTapDiagnosticPackService.instance.debugFolder;
    _loadLastVerdict();
  }

  Future<void> _loadLastVerdict() async {
    try {
      final File f = File(
        CursorOneTapDiagnosticPackService.instance.packJsonPath,
      );
      if (!await f.exists()) return;
      final Object? j = jsonDecode(await f.readAsString());
      if (j is! Map) return;
      final Object? v = j['verdict'];
      if (v is! Map) return;
      final int failures = v['failureCount'] is int
          ? v['failureCount'] as int
          : int.tryParse('${v['failureCount']}') ?? 0;
      final bool severe = v['hasSevereFreeze'] == true;
      if (!mounted) return;
      setState(() {
        _lastVerdict = severe
            ? '차단 실패 $failures건 · 30초+ 프리즈 기록 있음'
            : failures > 0
                ? '차단 실패 $failures건'
                : '최근 팩 — 차단·프리즈 이상 없음';
      });
    } catch (_) {}
  }

  Future<void> _run({bool copyAfter = true}) async {
    if (_running) return;
    setState(() => _running = true);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final Map<String, Object?> pack =
          await CursorOneTapDiagnosticPackService.instance.runFullPack(
        reason: 'diagnostics_ui',
      );
      if (copyAfter) {
        final String prompt = await CursorOneTapDiagnosticPackService.instance
            .readPromptForClipboard();
        await Clipboard.setData(ClipboardData(text: prompt));
      }
      if (!mounted) return;
      final Object? verdict = pack['verdict'];
      String msg = 'Cursor 진단 팩 생성 완료';
      if (verdict is Map) {
        final int n = verdict['failureCount'] is int
            ? verdict['failureCount'] as int
            : int.tryParse('${verdict['failureCount']}') ?? 0;
        if (n > 0) msg += ' — 차단 실패 $n건 포함';
        if (verdict['hasSevereFreeze'] == true) {
          msg += ' · 30초+ 프리즈 기록';
        }
      }
      if (copyAfter) msg += ' · 클립보드에 복사됨';
      msg += ' · 하단 진행 표시줄에서 %·남은 시간 확인';
      messenger.showSnackBar(
        SnackBar(
          content: Text(msg),
          duration: const Duration(seconds: 8),
        ),
      );
      await _loadLastVerdict();
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text('진단 팩 실패: $e')),
      );
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: AppColors.accent.withValues(alpha: 0.06),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.accent.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.smart_toy_outlined, color: AppColors.accent, size: 24),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Cursor 원탭 진단 (프리즈 · 차단 · 플러그인)',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '버튼 한 번으로 렉·30초 프리즈·차단 실패·확장/URL 정책 상태를 '
              '파일 + 클립보드에 모읍니다. 진행률·예상 시간은 화면 하단 표시줄에 나옵니다.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.muted,
                  ),
            ),
            if (_lastVerdict != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(
                '마지막 팩: $_lastVerdict',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: AppColors.accent,
                    ),
              ),
            ],
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: _running ? null : () => _run(copyAfter: true),
                  icon: _running
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.play_arrow),
                  label: const Text('Cursor 원탭 진단 실행'),
                ),
                OutlinedButton.icon(
                  onPressed: _running
                      ? null
                      : () async {
                          final String t = await CursorOneTapDiagnosticPackService
                              .instance
                              .readPromptForClipboard();
                          await Clipboard.setData(ClipboardData(text: t));
                          if (!context.mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('저장된 진단 팩을 클립보드에 복사했어요'),
                            ),
                          );
                        },
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('마지막 팩 복사'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText(
              _folder,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontFamily: 'Consolas',
                    fontSize: 10,
                    color: AppColors.muted,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
