import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/preset_share_bundle.dart';
import '../services/local_database.dart';
import '../services/preset_share_service.dart';
import '../theme/app_colors.dart';

/// "나만의 프리셋 공유" — export a schedule as a file/code a friend can import,
/// or import one they sent. No server: a code is just base64(JSON), a file
/// is plain JSON written to Downloads.
class PresetShareScreen extends StatefulWidget {
  const PresetShareScreen({super.key});

  @override
  State<PresetShareScreen> createState() => _PresetShareScreenState();
}

class _PresetShareScreenState extends State<PresetShareScreen> {
  final PresetShareService _service = PresetShareService.instance;
  final TextEditingController _importController = TextEditingController();

  List<Map<String, Object?>> _schedules = <Map<String, Object?>>[];
  String? _selectedScheduleId;
  bool _includeSchedule = true;
  bool _busy = false;
  String? _status;

  @override
  void initState() {
    super.initState();
    _loadSchedules();
  }

  @override
  void dispose() {
    _importController.dispose();
    super.dispose();
  }

  Future<void> _loadSchedules() async {
    final List<Map<String, Object?>> rows = await LocalDatabase.instance
        .schedules();
    if (!mounted) return;
    setState(() {
      _schedules = rows;
      _selectedScheduleId = rows.isEmpty ? null : '${rows.first['id']}';
    });
  }

  Future<void> _exportCode() async {
    if (_selectedScheduleId == null) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final PresetShareBundle bundle = await _service.buildFromSchedule(
        _selectedScheduleId!,
        includeSchedule: _includeSchedule,
      );
      final String code = await _service.exportToClipboardCode(bundle);
      if (!mounted) return;
      setState(() {
        _status =
            '프리셋 코드가 클립보드에 복사됐습니다 (${code.length}자) — 카카오톡/문자로 '
            '친구에게 붙여넣어 보내주세요.';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '내보내기 실패: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportFile() async {
    if (_selectedScheduleId == null) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final PresetShareBundle bundle = await _service.buildFromSchedule(
        _selectedScheduleId!,
        includeSchedule: _includeSchedule,
      );
      final String path = await _service.exportToFile(bundle);
      if (!mounted) return;
      setState(() => _status = '파일로 저장됨: $path');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '내보내기 실패: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importFromText() async {
    final String raw = _importController.text.trim();
    if (raw.isEmpty) return;
    await _runImport(raw);
  }

  Future<void> _importFromFile() async {
    final FilePickerResult? pick = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: <String>['json'],
      dialogTitle: '프리셋 파일 (.json) 선택',
    );
    final String? path = pick?.files.single.path;
    if (path == null) return;
    final String raw = await File(path).readAsString();
    await _runImport(raw);
  }

  Future<void> _runImport(String codeOrJson) async {
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      final PresetShareBundle? bundle = _service.decode(codeOrJson);
      if (bundle == null) {
        setState(() => _status = '알 수 없는 형식입니다. 코드나 .json 파일이 맞는지 확인해주세요.');
        return;
      }
      final PresetImportResult result = await _service.importBundle(bundle);
      if (!mounted) return;
      setState(() {
        _status = result.asSchedule
            ? '"${result.name}" 스케줄로 가져왔습니다 (도메인 ${result.domainsImported}·'
                  '키워드 ${result.keywordsImported}·앱 ${result.appsImported}개) — '
                  '안전을 위해 꺼진 상태로 추가했으니 스케줄 화면에서 확인 후 켜주세요.'
            : '"${result.name}" 퀵 블록으로 가져왔습니다 (도메인 ${result.domainsImported}·'
                  '키워드 ${result.keywordsImported}·앱 ${result.appsImported}개).';
        _importController.clear();
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '가져오기 실패: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('나만의 프리셋 공유')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          Text('내보내기', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_schedules.isEmpty)
            const Text('내보낼 스케줄이 없습니다. 먼저 스케줄을 하나 만들어주세요.')
          else
            DropdownButtonFormField<String>(
              initialValue: _selectedScheduleId,
              items: _schedules
                  .map(
                    (Map<String, Object?> s) => DropdownMenuItem<String>(
                      value: '${s['id']}',
                      child: Text('${s['name'] ?? s['id']}'),
                    ),
                  )
                  .toList(),
              onChanged: (String? v) => setState(() => _selectedScheduleId = v),
              decoration: const InputDecoration(labelText: '내보낼 스케줄'),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('시간(요일·시각)까지 포함'),
            subtitle: const Text('끄면 URL/앱 목록만 공유되고, 친구가 시간은 직접 정합니다.'),
            value: _includeSchedule,
            onChanged: (bool v) => setState(() => _includeSchedule = v),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton.icon(
                onPressed: (_busy || _selectedScheduleId == null)
                    ? null
                    : _exportCode,
                icon: const Icon(Icons.copy_outlined, size: 18),
                label: const Text('프리셋 코드 복사'),
              ),
              OutlinedButton.icon(
                onPressed: (_busy || _selectedScheduleId == null)
                    ? null
                    : _exportFile,
                icon: const Icon(Icons.save_alt_outlined, size: 18),
                label: const Text('파일로 저장'),
              ),
            ],
          ),
          const SizedBox(height: 28),
          const Divider(),
          const SizedBox(height: 12),
          Text('가져오기', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          TextField(
            controller: _importController,
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              isDense: true,
              border: OutlineInputBorder(),
              hintText: '친구가 보낸 프리셋 코드를 여기에 붙여넣기',
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton.icon(
                onPressed: _busy ? null : _importFromText,
                icon: const Icon(Icons.download_outlined, size: 18),
                label: const Text('코드로 가져오기'),
              ),
              OutlinedButton.icon(
                onPressed: _busy ? null : _importFromFile,
                icon: const Icon(Icons.folder_open_outlined, size: 18),
                label: const Text('파일에서 가져오기'),
              ),
            ],
          ),
          if (_status != null) ...<Widget>[
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.accent.withValues(alpha: 0.24)),
              ),
              child: Text(_status!),
            ),
          ],
        ],
      ),
    );
  }
}
