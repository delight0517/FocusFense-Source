import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../services/app_logger.dart';
import '../services/export_service.dart';
import '../services/import_service.dart';
import '../theme/app_colors.dart';

/// Dialog for importing blocklists or exporting rules.
///
/// Wording is intentionally generic ("차단 목록 파일") so the surface does not
/// position itself as a Cold Turkey transfer tool. A small footnote mentions
/// that common third-party exports are auto-detected.
class ImportExportDialog extends StatefulWidget {
  const ImportExportDialog({super.key, required this.onScheduleImported});

  final VoidCallback onScheduleImported;

  @override
  State<ImportExportDialog> createState() => _ImportExportDialogState();
}

class _ImportExportDialogState extends State<ImportExportDialog> {
  bool _isLoading = false;
  String? _error;

  bool get _isMac => Platform.isMacOS;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('차단 목록 가져오기 / 내보내기'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '가져오기',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Cold Turkey·일반 차단 목록(.txt)을 고르세요.\n'
                    '도메인(chess.com), 경로(duolingo.com/chess), '
                    '검색·URL 패턴(*.*/*q=*체스*)을 자동 분류해 적용합니다.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: _mutedColor(),
                          height: 1.4,
                        ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '※ 다른 차단 도구에서 내보낸 일반 텍스트 목록도 그대로 읽힙니다. '
                    '가져온 데이터는 이 기기 안에서만 사용되며, 원본 서비스의 약관을 따릅니다.',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: _mutedColor().withValues(alpha: 0.75),
                          fontSize: 10.5,
                          height: 1.35,
                        ),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      onPressed: _isLoading ? null : _importFromFile,
                      icon: const Icon(Icons.upload_file),
                      label: const Text('파일 고르기'),
                    ),
                  ),
                ],
              ),
            ),

            const Divider(),

            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '내보내기',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    '현재 모든 규칙을 JSON 또는 일반 텍스트로 저장합니다. '
                    '백업·이사용으로 사용하세요.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: _mutedColor(),
                          height: 1.4,
                        ),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: <Widget>[
                      FilledButton.tonalIcon(
                        onPressed: _isLoading ? null : _exportAsJson,
                        icon: const Icon(Icons.data_object),
                        label: const Text('JSON'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: _isLoading ? null : _exportAsText,
                        icon: const Icon(Icons.note),
                        label: const Text('텍스트'),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            if (_error != null) ...<Widget>[
              const SizedBox(height: 12),
              _ErrorPanel(
                text: _error!,
                onClear: () => setState(() => _error = null),
              ),
            ],

            if (_isLoading) ...<Widget>[
              const SizedBox(height: 12),
              const Center(child: CircularProgressIndicator()),
            ],
          ],
        ),
      ),
      actions: <Widget>[
        TextButton.icon(
          onPressed: _showLog,
          icon: const Icon(Icons.receipt_long, size: 16),
          label: const Text('앱 로그 보기'),
        ),
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.pop(context),
          child: const Text('닫기'),
        ),
      ],
    );
  }

  Color _mutedColor() => _isMac ? MacColors.mutedInk : AppColors.muted;

  Future<void> _showLog() async {
    final String log = await AppLogger.instance.readRecent();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => _LogViewerDialog(text: log),
    );
  }

  Future<void> _importFromFile() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final FilePickerResult? result = await FilePicker.pickFiles(
        type: FileType.any,
        allowMultiple: false,
      );

      if (result == null) {
        setState(() => _isLoading = false);
        return;
      }

      final String filePath = result.files.single.path!;

      final batch =
          await ImportService.instance.parseColdTurkeyFile(filePath);

      if (batch.rules.isEmpty) {
        setState(() {
          _isLoading = false;
          _error = '파일에서 유효한 규칙을 찾지 못했습니다.\n'
              '한 줄에 도메인·경로·URL 패턴을 적은 목록인지 확인해 주세요.';
        });
        return;
      }

      if (!mounted) return;

      final String? scheduleName = await _showNameDialog();
      if (scheduleName == null) {
        setState(() => _isLoading = false);
        return;
      }

      final ColdTurkeyImportResult imported =
          await ImportService.instance.importBatchToDB(
        batch: batch,
        scheduleName: scheduleName,
      );

      AppLogger.instance.info(
          'import: ${result.files.single.name} → "$scheduleName" '
          'domains=${imported.domainsImported} keywords=${imported.keywordsImported}');
      if (!mounted) return;
      setState(() => _isLoading = false);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '완료! "$scheduleName"\n'
            '· 사이트(도메인) ${imported.domainsImported}개 → DNS 차단\n'
            '· 경로·검색 패턴 ${imported.keywordsImported}개 → 브라우저 확장',
          ),
          duration: const Duration(seconds: 4),
        ),
      );

      widget.onScheduleImported();
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e, st) {
      AppLogger.instance.error('import failed', error: e, stack: st);
      setState(() {
        _isLoading = false;
        _error = '가져오기 실패: $e';
      });
    }
  }

  Future<void> _exportAsJson() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final String content =
          await ExportService.instance.exportSchedulesToJson();
      final Directory docDir = await getApplicationDocumentsDirectory();
      final String fileName =
          'schedules_${DateTime.now().toString().split('.')[0].replaceAll(':', '-')}.json';
      final File file = File('${docDir.path}/$fileName');
      await file.writeAsString(content);
      AppLogger.instance.info('export json → ${file.path}');

      if (!mounted) return;
      setState(() => _isLoading = false);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('저장됨: $fileName'),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e, st) {
      AppLogger.instance.error('export json failed', error: e, stack: st);
      setState(() {
        _isLoading = false;
        _error = '내보내기 실패: $e';
      });
    }
  }

  Future<void> _exportAsText() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final String content =
          await ExportService.instance.exportAllDomainsAsText();
      final Directory docDir = await getApplicationDocumentsDirectory();
      final String fileName =
          'domains_${DateTime.now().toString().split('.')[0].replaceAll(':', '-')}.txt';
      final File file = File('${docDir.path}/$fileName');
      await file.writeAsString(content);
      AppLogger.instance.info('export text → ${file.path}');

      if (!mounted) return;
      setState(() => _isLoading = false);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('저장됨: $fileName'),
          duration: const Duration(seconds: 3),
        ),
      );
    } catch (e, st) {
      AppLogger.instance.error('export text failed', error: e, stack: st);
      setState(() {
        _isLoading = false;
        _error = '내보내기 실패: $e';
      });
    }
  }

  Future<String?> _showNameDialog() async {
    final TextEditingController controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('스케줄 이름'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: '예: 야간 차단, 공부 시간',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('만들기'),
          ),
        ],
      ),
    );
  }
}

/// Copyable, dismissible error panel. Shown inline so the user can paste the
/// reason to us instead of having to screenshot.
class _ErrorPanel extends StatelessWidget {
  const _ErrorPanel({required this.text, required this.onClear});
  final String text;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final Color danger =
        Platform.isMacOS ? MacColors.danger : AppColors.danger;
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 6),
      decoration: BoxDecoration(
        color: danger.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: danger.withValues(alpha: 0.40)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SelectableText(
            text,
            style: TextStyle(fontSize: 12, color: danger),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: <Widget>[
              TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: text));
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('오류 메시지가 클립보드에 복사되었습니다.'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                },
                icon: const Icon(Icons.copy, size: 14),
                label: const Text('복사', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                  foregroundColor: danger,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: const Size(0, 28),
                ),
              ),
              TextButton.icon(
                onPressed: onClear,
                icon: const Icon(Icons.close, size: 14),
                label: const Text('숨기기', style: TextStyle(fontSize: 12)),
                style: TextButton.styleFrom(
                  foregroundColor: danger,
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: const Size(0, 28),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Modal sheet showing the recent app log with copy + clear actions.
class _LogViewerDialog extends StatelessWidget {
  const _LogViewerDialog({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('앱 로그'),
      content: SizedBox(
        width: 640,
        height: 420,
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: Platform.isMacOS
                ? MacColors.background
                : const Color(0xFFF1F4F8),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: Platform.isMacOS
                  ? MacColors.hairline
                  : Colors.black12,
            ),
          ),
          child: Scrollbar(
            child: SingleChildScrollView(
              child: SelectableText(
                text.isEmpty ? '(로그 없음)' : text,
                style: const TextStyle(
                  fontFamily: 'Menlo',
                  fontSize: 11,
                  height: 1.4,
                ),
              ),
            ),
          ),
        ),
      ),
      actions: <Widget>[
        TextButton.icon(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: text));
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('전체 로그가 클립보드에 복사되었습니다.'),
              ),
            );
          },
          icon: const Icon(Icons.copy, size: 16),
          label: const Text('전체 복사'),
        ),
        TextButton.icon(
          onPressed: () async {
            await AppLogger.instance.clear();
            if (!context.mounted) return;
            Navigator.of(context).pop();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('로그를 비웠습니다.')),
            );
          },
          icon: const Icon(Icons.delete_outline, size: 16),
          label: const Text('비우기'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('닫기'),
        ),
      ],
    );
  }
}
