import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_logger.dart';
import '../services/build_identity_service.dart';
import '../services/crash_journal_service.dart';
import '../theme/app_colors.dart';
import '../widgets/copyable_snackbar.dart';
import 'user_feedback_screen.dart';

/// Log + crash journal viewer: copy bundles for AI support, survive restarts.
class LogViewerScreen extends StatefulWidget {
  const LogViewerScreen({super.key});

  @override
  State<LogViewerScreen> createState() => _LogViewerScreenState();
}

class _LogViewerScreenState extends State<LogViewerScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs =
      TabController(length: 2, vsync: this);
  String _appLog = '';
  String _crashText = '';
  String? _appPath;
  String _debugFolder = '';
  String? _headerTag;
  bool _busy = false;
  bool _live = true;
  Timer? _liveTimer;

  @override
  void initState() {
    super.initState();
    AppLogger.instance.liveRevision.addListener(_onLiveTick);
    _liveTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_live) unawaited(_refreshAppLogOnly());
    });
    _refresh();
  }

  @override
  void dispose() {
    _liveTimer?.cancel();
    AppLogger.instance.liveRevision.removeListener(_onLiveTick);
    _tabs.dispose();
    super.dispose();
  }

  void _onLiveTick() {
    if (!_live || !mounted) return;
    setState(() {
      _appLog = AppLogger.instance.liveText;
    });
  }

  Future<void> _refreshAppLogOnly() async {
    if (!_live || !mounted) return;
    final String live = AppLogger.instance.liveText;
    final String disk =
        await AppLogger.instance.readRecent(maxBytes: 96 * 1024);
    if (!mounted) return;
    setState(() {
      _appLog = live.isNotEmpty ? live : disk;
    });
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    String? tag;
    try {
      tag = await BuildIdentityService.instance.summaryLine();
    } catch (_) {
      tag = null;
    }
    final String live = AppLogger.instance.liveText;
    final String disk = await AppLogger.instance.readRecent(maxBytes: 96 * 1024);
    final String app = live.isNotEmpty ? live : disk;
    final String? p = await AppLogger.instance.filePath();
    final List<String> lines =
        await CrashJournalService.instance.readTailLines(maxLines: 500);
    await CrashJournalService.instance.warmup();
    final String folder = CrashJournalService.instance.debugFolderPath;
    final String crash = lines.isEmpty
        ? '(크래시 저널 비어 있음 — 오류가 나면 여기 JSON 줄이 쌓입니다.)'
        : lines.reversed.join('\n');
    if (!mounted) return;
    setState(() {
      _headerTag = tag;
      _appLog = app;
      _appPath = p;
      _crashText = crash;
      _debugFolder = folder;
      _busy = false;
    });
  }

  Future<String> _buildDiagnosticsBundle() async {
    final StringBuffer sb = StringBuffer();
    sb.writeln('=== Focus Fense · diagnostic bundle ===');
    sb.writeln('exportedLocal: ${DateTime.now().toIso8601String()}');
    sb.writeln('exportedUtc: ${DateTime.now().toUtc().toIso8601String()}');
    sb.writeln('debugFolder: $_debugFolder');
    try {
      final BuildIdentity id = await BuildIdentityService.instance.current();
      sb.writeln(
        'build: ${id.appName} ${id.version}+${id.buildNumber} · '
        '${id.operatingSystem} ${id.operatingSystemVersion}',
      );
      sb.writeln('exe: ${id.executablePath}');
    } catch (e) {
      sb.writeln('build identity: (failed: $e)');
    }
    sb.writeln();
    sb.writeln('--- app.log (tail) ---');
    sb.writeln(_appLog.isEmpty ? '(empty)' : _appLog);
    sb.writeln();
    sb.writeln(await CrashJournalService.instance.readRawForExport());
    return sb.toString();
  }

  Future<void> _copyDiagnosticsBundle() async {
    final String s = await _buildDiagnosticsBundle();
    await Clipboard.setData(ClipboardData(text: s));
    if (!mounted) return;
    showCopyableSnackBar(
      context,
      '진단 번들(빌드 정보 + 앱 로그 + 크래시 저널)이 복사되었습니다.',
      duration: const Duration(seconds: 4),
    );
  }

  Future<void> _copyAppLog() async {
    await Clipboard.setData(ClipboardData(text: _appLog));
    if (!mounted) return;
    showCopyableSnackBar(context, '앱 로그가 복사되었습니다.');
  }

  Future<void> _copyCrash() async {
    await Clipboard.setData(ClipboardData(text: _crashText));
    if (!mounted) return;
    showCopyableSnackBar(context, '크래시 저널 화면 텍스트가 복사되었습니다.');
  }

  Future<void> _copyPath() async {
    if (_appPath == null) return;
    await Clipboard.setData(ClipboardData(text: _appPath!));
    if (!mounted) return;
    showCopyableSnackBar(context, '앱 로그 파일 경로가 복사되었습니다.');
  }

  Future<void> _copyDebugFolder() async {
    await Clipboard.setData(ClipboardData(text: _debugFolder));
    if (!mounted) return;
    showCopyableSnackBar(context, '디버그 폴더 경로가 복사되었습니다.');
  }

  Future<void> _clearAppLog() async {
    await AppLogger.instance.clear();
    AppLogger.instance.info('user cleared app log');
    await _refresh();
  }

  Future<void> _clearCrashJournal() async {
    await CrashJournalService.instance.clear();
    AppLogger.instance.info('user cleared crash journal');
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final bool mac = Platform.isMacOS;
    final Color muted = mac ? MacColors.mutedInk : AppColors.muted;
    final Color bg = mac ? MacColors.surface : const Color(0xFFF1F4F8);
    final Color border = mac ? MacColors.hairline : Colors.black12;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text('디버그 · 로그'),
            if (_headerTag != null && _headerTag!.isNotEmpty)
              Text(
                _headerTag!,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w400,
                  fontFamily: 'Menlo',
                ),
              ),
          ],
        ),
        bottom: TabBar(
          controller: _tabs,
          tabs: const <Widget>[
            Tab(text: '앱 로그 (실시간)'),
            Tab(text: '크래시 저널'),
          ],
        ),
        actions: <Widget>[
          IconButton(
            tooltip: '문제 신고 · 피드백',
            onPressed: () {
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const UserFeedbackScreen(),
                ),
              );
            },
            icon: const Icon(Icons.support_agent_outlined),
          ),
          IconButton(
            tooltip: '디버그 폴더 열기',
            onPressed: () =>
                CrashJournalService.instance.revealDebugFolder(),
            icon: const Icon(Icons.folder_open),
          ),
          IconButton(
            tooltip: '진단 번들 복사 (AI용)',
            onPressed: _busy ? null : _copyDiagnosticsBundle,
            icon: const Icon(Icons.copy_all),
          ),
          IconButton(
            tooltip: '새로고침',
            onPressed: _busy ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: TabBarView(
        controller: _tabs,
        children: <Widget>[
          _logPanel(
            muted: muted,
            bg: bg,
            border: border,
            body: _appLog,
            emptyHint: '(로그 없음)',
            onCopy: _copyAppLog,
            onClear: _clearAppLog,
            footer: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('실시간 갱신 (1초)'),
                  subtitle: const Text('끄면 수동 새로고침만'),
                  value: _live,
                  onChanged: (bool v) {
                    setState(() => _live = v);
                    if (v) unawaited(_refreshAppLogOnly());
                  },
                ),
                _pathFooter(muted),
              ],
            ),
          ),
          _logPanel(
            muted: muted,
            bg: bg,
            border: border,
            body: _crashText,
            emptyHint: '(저널 없음)',
            onCopy: _copyCrash,
            onClear: _clearCrashJournal,
            footer: _debugFolderFooter(muted),
          ),
        ],
      ),
    );
  }

  Widget _pathFooter(Color muted) {
    if (_appPath == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: <Widget>[
          Icon(Icons.description_outlined, size: 14, color: muted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _appPath!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: muted,
                fontSize: 11,
                fontFamily: 'Menlo',
              ),
            ),
          ),
          TextButton.icon(
            onPressed: _copyPath,
            icon: const Icon(Icons.link, size: 14),
            label: const Text('경로 복사', style: TextStyle(fontSize: 11)),
          ),
        ],
      ),
    );
  }

  Widget _debugFolderFooter(Color muted) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: <Widget>[
          Icon(Icons.folder_special_outlined, size: 14, color: muted),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              _debugFolder.isEmpty ? '(경로 준비 중)' : _debugFolder,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: muted,
                fontSize: 11,
                fontFamily: 'Menlo',
              ),
            ),
          ),
          TextButton.icon(
            onPressed: _debugFolder.isEmpty ? null : _copyDebugFolder,
            icon: const Icon(Icons.link, size: 14),
            label: const Text('폴더 경로 복사', style: TextStyle(fontSize: 11)),
          ),
        ],
      ),
    );
  }

  Widget _logPanel({
    required Color muted,
    required Color bg,
    required Color border,
    required String body,
    required String emptyHint,
    required Future<void> Function() onCopy,
    required Future<void> Function() onClear,
    required Widget footer,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            '아래를 통째로 복사해 채팅(AI)에 붙여넣으면 원인 파악이 빨라집니다. '
            '비밀번호는 로그에 넣지 마세요.',
            style: TextStyle(color: muted, fontSize: 12, height: 1.4),
          ),
          const SizedBox(height: 10),
          footer,
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: border),
              ),
              child: _busy
                  ? const Center(child: CircularProgressIndicator())
                  : Scrollbar(
                      child: SingleChildScrollView(
                        reverse: true,
                        child: SelectableText(
                          body.isEmpty ? emptyHint : body,
                          style: const TextStyle(
                            fontFamily: 'Menlo',
                            fontSize: 11,
                            height: 1.45,
                          ),
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: <Widget>[
              Expanded(
                child: FilledButton.icon(
                  onPressed: _busy || body.isEmpty ? null : onCopy,
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('이 탭 전체 복사'),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _busy ? null : onClear,
                icon: const Icon(Icons.delete_outline, size: 16),
                label: const Text('비우기'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
