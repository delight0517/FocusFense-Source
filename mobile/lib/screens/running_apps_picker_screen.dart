import 'dart:async';

import 'package:flutter/material.dart';

import '../models/block_app.dart';
import '../services/windows_game_app_aliases.dart';
import '../services/windows_process_display.dart';
import '../services/windows_process_lister.dart';
import '../theme/app_colors.dart';

/// Returns the picked apps (as [BlockApp] entries) when the user taps Done.
class RunningAppsPickerScreen extends StatefulWidget {
  const RunningAppsPickerScreen({
    super.key,
    required this.alreadyChosenKeys,
  });

  /// Set of [BlockApp] identity strings that are already on the profile, so
  /// the picker can grey them out. Identity is `exeName` for normal apps and
  /// `exeName?app-id=<hash>` for Chrome PWAs (matching
  /// [RunningProcessInfo.groupKey]).
  final Set<String> alreadyChosenKeys;

  @override
  State<RunningAppsPickerScreen> createState() => _RunningAppsPickerScreenState();
}

class _RunningAppsPickerScreenState extends State<RunningAppsPickerScreen> {
  final WindowsProcessLister _lister = WindowsProcessLister.instance;
  final TextEditingController _filterCtrl = TextEditingController();

  bool _onlyWithWindow = true;
  bool _refreshing = false;
  List<RunningProcessInfo> _items = const <RunningProcessInfo>[];

  /// Selection map: groupKey (exe or exe?app-id=…) -> chosen process.
  final Map<String, RunningProcessInfo> _picked = <String, RunningProcessInfo>{};

  @override
  void initState() {
    super.initState();
    _items = _lister.peekCached(onlyWithWindow: _onlyWithWindow);
    _refresh(showSpinner: _items.isEmpty);
  }

  @override
  void dispose() {
    _filterCtrl.dispose();
    super.dispose();
  }

  Future<void> _refresh({bool showSpinner = false}) async {
    if (showSpinner) setState(() => _refreshing = true);
    try {
      final List<RunningProcessInfo> got = await _lister
          .refreshAsync(onlyWithWindow: _onlyWithWindow)
          .timeout(const Duration(seconds: 12));
      if (!mounted) return;
      setState(() {
        _items = got;
        _refreshing = false;
      });
    } on TimeoutException {
      if (!mounted) return;
      setState(() => _refreshing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('목록 불러오기 시간 초과 — 다시 새로고침 해 주세요.'),
        ),
      );
    }
  }

  void _toggle(RunningProcessInfo p) {
    setState(() {
      final String key = p.groupKey;
      if (_picked.containsKey(key)) {
        _picked.remove(key);
      } else {
        _picked[key] = p;
      }
    });
  }

  void _confirm() {
    final List<BlockApp> out =
        WindowsGameAppAliases.fromPickerSelection(_picked.values);
    Navigator.of(context).pop(out);
  }

  String _displayFor(RunningProcessInfo p) =>
      WindowsProcessDisplay.friendlyName(p);

  String _subtitleFor(RunningProcessInfo p, bool already) {
    if (p.isChromePwa) {
      final String tail = already ? ' · 이미 추가됨' : '';
      return 'Chrome 앱 (브라우저는 영향 없음)$tail';
    }
    if (p.isChromiumBrowser) {
      final String tail = already ? ' · 이미 추가됨' : '';
      return '${p.exeName} · 메인 브라우저만 (PWA는 영향 없음)$tail';
    }
    final String base = WindowsProcessDisplay.subtitle(p);
    return already ? '$base · 이미 추가됨' : base;
  }

  int _relatedExtraCount() {
    final int before = _picked.length;
    final int after =
        WindowsGameAppAliases.fromPickerSelection(_picked.values).length;
    return after - before;
  }

  @override
  Widget build(BuildContext context) {
    final String filter = _filterCtrl.text.trim().toLowerCase();
    final List<RunningProcessInfo> visible = filter.isEmpty
        ? _items
        : _items
            .where((RunningProcessInfo p) =>
                p.exeName.contains(filter) ||
                p.windowTitle.toLowerCase().contains(filter) ||
                _displayFor(p).toLowerCase().contains(filter))
            .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('실행 중·백그라운드 앱 고르기'),
        actions: <Widget>[
          IconButton(
            tooltip: '새로 고침',
            onPressed: _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton.icon(
            onPressed: _picked.isEmpty ? null : _confirm,
            icon: const Icon(Icons.check),
            label: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Text(
                _picked.isEmpty
                    ? '선택해 주세요'
                    : () {
                        final int extra = _relatedExtraCount();
                        final String base = '${_picked.length}개 추가';
                        return extra > 0 ? '$base (+관련 exe $extra)' : base;
                      }(),
                style: const TextStyle(fontSize: 16),
              ),
            ),
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: TextField(
                controller: _filterCtrl,
                decoration: const InputDecoration(
                  hintText: '검색: chrome, kakao 등',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Text(
                '게임·런처(배틀넷·SC2 등)는 창이 없어도 목록에 자동 표시됩니다. '
                '추가 시 실제 exe(Agent, SC2_x64 등)도 함께 저장됩니다.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.muted,
                      height: 1.35,
                    ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: SwitchListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                dense: true,
                title: const Text('창이 있는 앱만 보기'),
                subtitle: Text(
                  '끄면 백그라운드 앱·게임 프로세스도 표시 (시스템 프로세스는 숨김).',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.muted),
                ),
                value: _onlyWithWindow,
                onChanged: (bool v) {
                  setState(() {
                    _onlyWithWindow = v;
                    _items = _lister.peekCached(onlyWithWindow: v);
                  });
                  _refresh(showSpinner: _items.isEmpty);
                },
              ),
            ),
            if (_refreshing)
              const LinearProgressIndicator(minHeight: 2)
            else
              const SizedBox(height: 2),
            Expanded(
              child: visible.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            const Icon(Icons.search_off, size: 48, color: AppColors.muted),
                            const SizedBox(height: 8),
                            Text(
                              _refreshing ? '불러오는 중…' : '결과가 없어요',
                              style: TextStyle(color: AppColors.muted),
                            ),
                          ],
                        ),
                      ),
                    )
                  : ListView.separated(
                      itemCount: visible.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (BuildContext ctx, int i) {
                        final RunningProcessInfo p = visible[i];
                        final String key = p.groupKey;
                        final bool already = widget.alreadyChosenKeys.contains(key);
                        final bool selected = _picked.containsKey(key);
                        final IconData icon = p.isChromePwa
                            ? Icons.web_asset
                            : (p.isChromiumBrowser ? Icons.public : Icons.window);
                        return CheckboxListTile(
                          value: already || selected,
                          onChanged: already ? null : (_) => _toggle(p),
                          secondary: Icon(icon),
                          title: Row(
                            children: <Widget>[
                              Flexible(
                                child: Text(
                                  _displayFor(p),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (p.isChromePwa) ...<Widget>[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFE3F2FD),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text(
                                    'Chrome 앱',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFF0D47A1),
                                    ),
                                  ),
                                ),
                              ] else if (p.isChromiumBrowser) ...<Widget>[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFFF3E0),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text(
                                    '브라우저',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      color: Color(0xFFB35900),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          subtitle: Text(
                            _subtitleFor(p, already),
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: AppColors.muted),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
