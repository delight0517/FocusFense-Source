import 'dart:io' show Platform;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../services/app_logger.dart';
import '../services/import_service.dart';
import '../theme/app_colors.dart';
import '../utils/cold_turkey_rule_parser.dart';

/// Result of [BulkAddDomainsDialog].
class BulkAddDomainsResult {
  const BulkAddDomainsResult(this.lines, {required this.asStem});

  final List<String> lines;
  final bool asStem;
}

/// Paste-many-or-pick-file dialog (same as schedule edit).
class BulkAddDomainsDialog extends StatefulWidget {
  const BulkAddDomainsDialog({super.key});

  @override
  State<BulkAddDomainsDialog> createState() => _BulkAddDomainsDialogState();
}

class _BulkAddDomainsDialogState extends State<BulkAddDomainsDialog> {
  final TextEditingController _ctrl = TextEditingController();
  bool _asStem = false;
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _pickFile() async {
    try {
      final FilePickerResult? r = await FilePicker.pickFiles(
        type: FileType.any,
        allowMultiple: false,
      );
      if (r == null) return;
      final batch =
          await ImportService.instance.parseColdTurkeyFile(r.files.single.path!);
      if (!mounted) return;
      final List<String> lines =
          batch.rules.map((ColdTurkeyParsedRule rule) => rule.raw).toList();
      setState(() {
        final String existing = _ctrl.text.trim();
        _ctrl.text =
            existing.isEmpty ? lines.join('\n') : '$existing\n${lines.join('\n')}';
        _error = lines.isEmpty ? '파일에서 규칙을 찾지 못했습니다.' : null;
      });
    } catch (e) {
      AppLogger.instance.error('bulk file pick failed', error: e);
      if (!mounted) return;
      setState(() => _error = '파일 가져오기 실패: $e');
    }
  }

  void _submit() {
    final List<String> lines = _ctrl.text
        .split(RegExp(r'[\r\n,;]+'))
        .map((String s) => s.trim())
        .where((String s) => s.isNotEmpty && !s.startsWith('#'))
        .toList();
    Navigator.of(context).pop(BulkAddDomainsResult(lines, asStem: _asStem));
  }

  @override
  Widget build(BuildContext context) {
    final Color muted =
        Platform.isMacOS ? MacColors.mutedInk : AppColors.muted;
    return AlertDialog(
      title: const Text('여러 사이트 한 번에 추가'),
      content: SizedBox(
        width: 540,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '한 줄에 도메인·경로·URL 패턴을 붙여넣거나 파일을 가져오세요.',
              style: TextStyle(color: muted, fontSize: 12, height: 1.4),
            ),
            const SizedBox(height: 10),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 220),
              child: TextField(
                controller: _ctrl,
                maxLines: null,
                minLines: 6,
                autocorrect: false,
                style: const TextStyle(fontFamily: 'Menlo', fontSize: 12),
                decoration: const InputDecoration(
                  hintText: 'example.com\nads.example.com',
                  border: OutlineInputBorder(),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Switch(
                  value: _asStem,
                  onChanged: (bool v) => setState(() => _asStem = v),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    _asStem
                        ? '패턴 모드 — 회전 도메인(.com/.net …) 확장'
                        : '패턴 모드 끄기',
                    style: TextStyle(
                      color: _asStem ? AppColors.warning : muted,
                      fontSize: 11,
                      height: 1.35,
                    ),
                  ),
                ),
              ],
            ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(_error!, style: const TextStyle(color: AppColors.danger)),
              ),
          ],
        ),
      ),
      actions: <Widget>[
        OutlinedButton.icon(
          onPressed: _pickFile,
          icon: const Icon(Icons.folder_open, size: 18),
          label: const Text('파일'),
        ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('취소')),
        FilledButton(onPressed: _submit, child: const Text('추가')),
      ],
    );
  }
}
