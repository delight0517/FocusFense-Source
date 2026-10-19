import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_logger.dart';
import '../theme/app_colors.dart';
import 'copyable_snackbar.dart';

/// In-app tail of [AppLogger] — updates every second while visible.
class AppLiveLogPanel extends StatefulWidget {
  const AppLiveLogPanel({
    super.key,
    this.maxHeight = 220,
    this.title = '실시간 앱 로그',
  });

  final double maxHeight;
  final String title;

  @override
  State<AppLiveLogPanel> createState() => _AppLiveLogPanelState();
}

class _AppLiveLogPanelState extends State<AppLiveLogPanel> {
  Timer? _timer;
  String _text = '';
  bool _paused = false;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    AppLogger.instance.liveRevision.addListener(_onLive);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _pull());
    unawaited(_pull());
  }

  @override
  void dispose() {
    _timer?.cancel();
    AppLogger.instance.liveRevision.removeListener(_onLive);
    super.dispose();
  }

  void _onLive() {
    if (_paused || !mounted) return;
    setState(() => _text = AppLogger.instance.liveText);
  }

  Future<void> _pull() async {
    if (_paused || !mounted) return;
    final String disk = await AppLogger.instance.readRecent(maxBytes: 96 * 1024);
    if (!mounted) return;
    setState(() {
      _text = AppLogger.instance.liveText.isNotEmpty
          ? AppLogger.instance.liveText
          : disk;
    });
  }

  Future<void> _copyAll() async {
    if (_text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: _text));
    if (!mounted) return;
    showCopyableSnackBar(context, '로그 전체가 복사되었습니다.');
  }

  Future<void> _clear() async {
    setState(() => _busy = true);
    await AppLogger.instance.clear();
    if (mounted) {
      setState(() {
        _busy = false;
        _text = '';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.terminal, size: 20, color: AppColors.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.title,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  _paused ? '일시정지' : '1초 갱신',
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: AppColors.muted,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '에러가 나면 아래를 길게 선택하거나 「전체 복사」로 채팅에 붙여넣으세요.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.muted,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              height: widget.maxHeight,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: theme.brightness == Brightness.dark
                      ? const Color(0xFF1A1F1C)
                      : const Color(0xFFF4F6FA),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.black12),
                ),
                child: _busy
                    ? const Center(child: CircularProgressIndicator())
                    : Scrollbar(
                        child: SingleChildScrollView(
                          reverse: true,
                          padding: const EdgeInsets.all(8),
                          child: SelectableText(
                            _text.isEmpty
                                ? '(아직 로그 없음 — 버튼을 눌러 보세요)'
                                : _text,
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 10.5,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ),
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: _text.isEmpty ? null : _copyAll,
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('전체 복사'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _pull,
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('새로고침'),
                ),
                OutlinedButton.icon(
                  onPressed: () => setState(() => _paused = !_paused),
                  icon: Icon(_paused ? Icons.play_arrow : Icons.pause, size: 16),
                  label: Text(_paused ? '실시간 켜기' : '일시정지'),
                ),
                if (Platform.isWindows || Platform.isMacOS)
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () async {
                            setState(() => _busy = true);
                            await AppLogger.instance.revealLogFolder();
                            if (mounted) setState(() => _busy = false);
                          },
                    icon: const Icon(Icons.folder_open, size: 16),
                    label: const Text('로그 폴더'),
                  ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _clear,
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text('비우기'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
