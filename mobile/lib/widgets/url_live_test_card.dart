import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../services/app_logger.dart';
import '../services/chrome_extension_payload_service.dart';
import '../services/chromium_policy_service.dart';
import '../services/extension_rules_builder.dart';
import '../services/local_database.dart';
import '../services/universal_browser_block_service.dart';
import '../services/windows_hidden_process.dart';
import '../services/chrome_channel_apply_probe_service.dart';
import '../services/edge_channel_apply_probe_service.dart';
import '../services/firefox_channel_apply_probe_service.dart';
import '../services/youtube_channel_videos_fetcher_service.dart';
import '../theme/app_colors.dart';

/// "Paste a URL, get the verdict + reason." Surface for the user's plea
/// that they want to *know* whether a specific item they added is actually
/// blocked, and if not, *why*. Each test walks 4 independent layers and
/// reports each one separately so the user knows exactly where the chain
/// breaks for that URL.
///
/// Layers checked:
///   1. DB match — is there ANY enabled keyword whose pattern, if expanded,
///      would target this URL's video / channel / domain?
///   2. URLBlocklist pattern emit — does ChromiumPolicyService generate
///      patterns from the current DB that should match this URL?
///   3. Registry presence — are those patterns actually written into
///      HKCU\…\URLBlocklist right now?
///   4. Pattern→URL match — does any registered pattern actually match the
///      pasted URL byte-by-byte (Chrome's URLBlocklist matching rule)?
///
/// On failure, the reason is specific:
///   - "DB에 추가되지 않았습니다 — 다시 추가하세요" (layer 1 fail)
///   - "패턴 추출이 안 됨 — 잘못된 URL 형식" (layer 2 fail)
///   - "URLBlocklist에 안 적혀있음 — 자동 수정 누르세요" (layer 3 fail)
///   - "case-sensitivity 미스매치 — 정확한 case로 다시 추가" (layer 4 fail)
class UrlLiveTestCard extends StatefulWidget {
  const UrlLiveTestCard({super.key});

  @override
  State<UrlLiveTestCard> createState() => _UrlLiveTestCardState();
}

class _UrlLiveTestCardState extends State<UrlLiveTestCard> {
  final TextEditingController _ctrl = TextEditingController();
  _TestResult? _result;
  bool _running = false;
  bool _autoFixing = false;
  String _autoFixPhase = '';

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    final String raw = _ctrl.text.trim();
    if (raw.isEmpty) return;
    setState(() {
      _running = true;
      _result = null;
    });
    try {
      final _TestResult r = await _runChecks(raw);
      if (!mounted) return;
      setState(() => _result = r);
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  Future<_TestResult> _runChecks(String urlRaw) async {
    final String url = _normalizeUrl(urlRaw);
    final String? videoId = _extractVideoId(url);
    final String? handle = _extractHandle(url);
    final String? host = _extractHost(url);
    final List<_LayerResult> layers = <_LayerResult>[];

    // ─── Layer 1: DB lookup ────────────────────────────────────────────
    final List<Map<String, Object?>> dbKeywords =
        await LocalDatabase.instance.keywordsAllEnabled();
    final List<String> dbMatches = <String>[];
    for (final Map<String, Object?> kw in dbKeywords) {
      final String pat = (kw['pattern'] as String? ?? '').toLowerCase();
      bool hit = false;
      if (videoId != null && pat.contains(videoId.toLowerCase())) hit = true;
      if (!hit && handle != null && pat.contains(handle.toLowerCase())) {
        hit = true;
      }
      if (!hit && host != null && pat.contains(host.toLowerCase())) hit = true;
      if (hit) dbMatches.add(kw['pattern'] as String);
    }
    layers.add(_LayerResult(
      title: '1. DB에 추가됨?',
      ok: dbMatches.isNotEmpty,
      detail: dbMatches.isNotEmpty
          ? '활성 키워드 ${dbMatches.length}개 매칭:\n${dbMatches.take(5).map((String s) => '  • $s').join('\n')}'
          : '활성화된 키워드 중 이 URL과 관련된 항목이 0개입니다. '
              '먼저 앱에서 이 URL을 차단 목록에 추가하세요.',
    ));

    // ─── Layer 2: pattern generation ───────────────────────────────────
    final ExtensionRulesPayload payload =
        await ExtensionRulesBuilder.buildForBrowserEnforcement();
    final List<String> allPatterns =
        await ChromiumPolicyService.activeBlocklistPatterns();
    final List<String> generated = <String>[];
    for (final String pat in allPatterns) {
      if (_patternMentionsTarget(pat,
          videoId: videoId, handle: handle, host: host)) {
        generated.add(pat);
      }
    }
    layers.add(_LayerResult(
      title: '2. URLBlocklist 패턴 생성됨?',
      ok: generated.isNotEmpty,
      detail: generated.isNotEmpty
          ? '${generated.length}개 패턴 생성됨 (전체 ${allPatterns.length}개 중):\n'
              '${generated.take(5).map((String s) => '  • $s').join('\n')}'
          : '활성 키워드에서 이 URL과 매칭되는 패턴이 만들어지지 않았습니다. '
              '비디오 ID/채널 핸들 추출 로직이 URL 형식을 인식하지 못했을 가능성. '
              '(rawKeywords=${payload.rawKeywords.length})',
    ));

    // ─── Layer 3: registry presence ────────────────────────────────────
    final List<String> regChrome = await _readRegistryEntries(
      r'HKCU\SOFTWARE\Policies\Google\Chrome\URLBlocklist',
    );
    final List<String> regEdge = await _readRegistryEntries(
      r'HKCU\SOFTWARE\Policies\Microsoft\Edge\URLBlocklist',
    );
    final List<String> regChromeMatch = regChrome
        .where((String p) =>
            _patternMentionsTarget(p,
                videoId: videoId, handle: handle, host: host))
        .toList();
    final List<String> regEdgeMatch = regEdge
        .where((String p) =>
            _patternMentionsTarget(p,
                videoId: videoId, handle: handle, host: host))
        .toList();
    final bool regOk = regChromeMatch.isNotEmpty && regEdgeMatch.isNotEmpty;
    layers.add(_LayerResult(
      title: '3. 레지스트리에 적혀있음?',
      ok: regOk,
      detail: regOk
          ? 'Chrome: ${regChromeMatch.length}개 / Edge: ${regEdgeMatch.length}개 적용됨 (총 ${regChrome.length}/${regEdge.length})'
          : 'Chrome: ${regChromeMatch.length}개 / Edge: ${regEdgeMatch.length}개. '
              '${regChromeMatch.isEmpty && regEdgeMatch.isEmpty ? "둘 다 없음 — ACL 잠금 또는 cap 초과. 「자동 수정」 누르세요." : "한쪽만 있음 — 부분 적용"}',
    ));

    // ─── Layer 4: actual URL match ─────────────────────────────────────
    final List<String> matched = <String>[];
    for (final String pat in regChrome) {
      if (_chromePatternMatchesUrl(pat, url)) matched.add(pat);
    }
    layers.add(_LayerResult(
      title: '4. URL이 실제로 패턴과 매칭됨?',
      ok: matched.isNotEmpty,
      detail: matched.isNotEmpty
          ? '${matched.length}개 패턴이 이 URL을 잡습니다 (Chrome이 차단함):\n'
              '${matched.take(5).map((String s) => '  • $s').join('\n')}'
          : '레지스트리에 패턴은 있지만 byte-by-byte로 이 URL과 일치하는 게 없습니다. '
              '가능한 원인: case 불일치(YouTube 채널의 실제 case와 입력 case가 다름), '
              'percent-encoding 누락, m./music. 등 subdomain 미커버. '
              '입력 URL을 그대로 (case 포함) 차단 목록에 다시 추가하세요.',
    ));

    if (Platform.isWindows && handle != null && handle.isNotEmpty) {
      final FirefoxChannelApplyReport ff =
          await FirefoxChannelApplyProbeService.instance.probeHandle(handle);
      final int ffApplied = ff.profiles
          .where((FirefoxChannelProfileProbe p) => p.channelInExtensionList)
          .length;
      final bool ffOk = ff.overall == FirefoxChannelApplyOverall.applied;
      layers.add(_LayerResult(
        title: '5. Firefox Focus Fense + 채널?',
        ok: ffOk,
        detail: ffOk
            ? '전 프로필($ffApplied/${ff.profiles.length})에서 확장·채널 확인됨'
            : '${ff.summaryLines.take(12).join('\n')}\n'
                '→ 「자동 수정」 후 Firefox 완전 종료·재실행 · about:addons → 확장 설정',
      ));

      final ChromeChannelApplyReport cr =
          await ChromeChannelApplyProbeService.instance.probeHandle(handle);
      final int crApplied = cr.profiles
          .where((ChromeChannelProfileProbe p) => p.channelInExtensionList)
          .length;
      final bool crOk = cr.overall == ChromeChannelApplyOverall.applied;
      layers.add(_LayerResult(
        title: '6. Chrome Focus Fense + 채널?',
        ok: crOk,
        detail: crOk
            ? '전 프로필($crApplied/${cr.profiles.length})에서 확장·채널 확인됨'
            : '${cr.summaryLines.take(14).join('\n')}\n'
                '→ 「자동 수정」 후 Chrome 완전 종료·재실행 · chrome://extensions',
      ));

      final EdgeChannelApplyReport ed =
          await EdgeChannelApplyProbeService.instance.probeHandle(handle);
      if (ed.isInformational) {
        layers.add(_LayerResult(
          title: '7. Edge Focus Fense + 채널?',
          ok: true,
          detail: ed.summaryLines.join('\n'),
        ));
      } else {
        final int edApplied = ed.profiles
            .where((EdgeChannelProfileProbe p) => p.channelInExtensionList)
            .length;
        final bool edOk = ed.overall == EdgeChannelApplyOverall.applied;
        layers.add(_LayerResult(
          title: '7. Edge Focus Fense + 채널?',
          ok: edOk,
          detail: edOk
              ? '전 프로필($edApplied/${ed.profiles.length})에서 확장·채널 확인됨'
              : '${ed.summaryLines.take(14).join('\n')}\n'
                  '→ 「자동 수정」 후 Edge 완전 종료·재실행 · edge://extensions',
        ));
      }
    }

    final bool overall = layers.every((_LayerResult l) => l.ok);
    return _TestResult(
      url: url,
      videoId: videoId,
      handle: handle,
      host: host,
      layers: layers,
      overall: overall,
    );
  }

  Future<List<String>> _readRegistryEntries(String key) async {
    if (!Platform.isWindows) return <String>[];
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final String reg = p.join(windir, 'System32', 'reg.exe');
    try {
      final ProcessResult r = await windowsRunHidden(
        reg,
        <String>['query', key, '/s'],
      );
      if (r.exitCode != 0) return <String>[];
      final List<String> out = <String>[];
      for (final String line in '${r.stdout}'.split('\n')) {
        if (!line.contains('REG_SZ')) continue;
        if (line.contains('(Default)')) continue;
        final int idx = line.indexOf('REG_SZ');
        if (idx < 0) continue;
        final String val = line.substring(idx + 'REG_SZ'.length).trim();
        if (val.isNotEmpty) out.add(val);
      }
      return out;
    } catch (_) {
      return <String>[];
    }
  }

  String _normalizeUrl(String raw) {
    String s = raw.trim();
    if (!s.startsWith('http')) {
      if (s.startsWith('youtube.com') ||
          s.startsWith('m.youtube.com') ||
          s.startsWith('www.youtube.com') ||
          s.startsWith('music.youtube.com') ||
          s.startsWith('youtu.be')) {
        s = 'https://$s';
      }
    }
    return s;
  }

  String? _extractVideoId(String url) {
    RegExpMatch? m = RegExp(r'[?&]v=([\w-]{6,})', caseSensitive: false)
        .firstMatch(url);
    m ??= RegExp(r'youtu\.be/([\w-]{6,})', caseSensitive: false).firstMatch(url);
    m ??= RegExp(r'/shorts/([\w-]{6,})', caseSensitive: false).firstMatch(url);
    m ??= RegExp(r'/embed/([\w-]{6,})', caseSensitive: false).firstMatch(url);
    return m?.group(1);
  }

  String? _extractHandle(String url) {
    final RegExpMatch? m =
        RegExp(r'youtube\.com/@([^/?#\s]+)', caseSensitive: false)
            .firstMatch(url);
    if (m != null) return m.group(1);
    final RegExpMatch? m2 =
        RegExp(r'youtube\.com/c/([^/?#\s]+)', caseSensitive: false)
            .firstMatch(url);
    return m2?.group(1);
  }

  String? _extractHost(String url) {
    try {
      final Uri u = Uri.parse(url);
      return u.host.isEmpty ? null : u.host;
    } catch (_) {
      return null;
    }
  }

  bool _patternMentionsTarget(String pat,
      {String? videoId, String? handle, String? host}) {
    final String low = pat.toLowerCase();
    if (videoId != null && low.contains(videoId.toLowerCase())) return true;
    if (handle != null && low.contains(handle.toLowerCase())) return true;
    if (host != null && low.contains(host.toLowerCase())) return true;
    return false;
  }

  /// Approximate Chrome's URL match-pattern rules:
  ///   `*`         matches any string (including /)
  ///   `*://`      matches any scheme
  ///   path is case-sensitive byte-by-byte (this is the key gotcha)
  bool _chromePatternMatchesUrl(String pattern, String url) {
    String regex = RegExp.escape(pattern);
    // Un-escape our wildcards.
    regex = regex
        .replaceAll(r'\*', '.*')
        .replaceAll(RegExp(r'\\\?'), r'\?');
    try {
      return RegExp('^$regex\$').hasMatch(url);
    } catch (_) {
      return false;
    }
  }

  /// One-click auto-fix for whatever layer failed for THIS URL. Does the
  /// minimum work needed to make the test pass next time:
  ///   * If URL has a handle (channel), fetch that channel's videos from
  ///     YouTube and insert each as a `watch?v=…` keyword in the schedule
  ///     that already owns the handle (or any active schedule as fallback).
  ///   * If URL has only a videoId (no handle), insert that single watch
  ///     URL as a keyword.
  ///   * If URL is a plain host, insert it as a `youtube.com/host` pattern.
  ///   * Then re-apply policies (`syncNow`) so URLBlocklist updates.
  ///   * Then re-run the test so the user sees the new green ticks.
  /// All in one button — no jumping between screens.
  Future<void> _runAutoFix() async {
    final _TestResult? r = _result;
    if (r == null || _autoFixing) return;
    setState(() {
      _autoFixing = true;
      _autoFixPhase = '시작...';
    });
    try {
      int insertedTotal = 0;
      // 1. If we have a handle, fetch the channel's videos.
      if (r.handle != null && r.handle!.isNotEmpty) {
        setState(() => _autoFixPhase = '채널 ${r.handle} 의 비디오 가져오는 중...');
        final List<String> videoIds = await YoutubeChannelVideosFetcherService
            .instance
            .fetchVideoIdsForHandle(r.handle!);
        // Resolve schedule_id: prefer the one that already owns this handle.
        String? scheduleId = await _findScheduleForHandle(r.handle!);
        scheduleId ??= await _anyEnabledScheduleId();
        // Add the channel keyword itself if missing.
        await LocalDatabase.instance.insertKeyword(
          id: 'yt_urltest_handle_${r.handle}_${DateTime.now().millisecondsSinceEpoch}',
          pattern: 'youtube.com/@${r.handle}',
          scheduleId: scheduleId,
        );
        // Add each fetched video as a keyword.
        for (final String vid in videoIds) {
          await LocalDatabase.instance.insertKeyword(
            id: 'yt_urltest_${r.handle}_$vid',
            pattern: 'https://www.youtube.com/watch?v=$vid',
            scheduleId: scheduleId,
          );
          insertedTotal++;
        }
        // Always include the pasted URL itself in case the channel page
        // doesn't list this specific video (older / unlisted-but-known).
        if (r.videoId != null) {
          await LocalDatabase.instance.insertKeyword(
            id: 'yt_urltest_explicit_${r.videoId}_${DateTime.now().millisecondsSinceEpoch}',
            pattern: 'https://www.youtube.com/watch?v=${r.videoId}',
            scheduleId: scheduleId,
          );
          insertedTotal++;
        }
      } else if (r.videoId != null) {
        // 2. Pure video URL — insert just this one.
        setState(() => _autoFixPhase = '비디오 ${r.videoId} 추가 중...');
        final String? scheduleId = await _anyEnabledScheduleId();
        await LocalDatabase.instance.insertKeyword(
          id: 'yt_urltest_video_${r.videoId}_${DateTime.now().millisecondsSinceEpoch}',
          pattern: 'https://www.youtube.com/watch?v=${r.videoId}',
          scheduleId: scheduleId,
        );
        insertedTotal++;
      } else if (r.host != null && !r.host!.contains('youtube')) {
        // 3. Generic host — insert as a domain rule (hosts + PAC + extension).
        setState(() => _autoFixPhase = '도메인 ${r.host} 추가 중...');
        await LocalDatabase.instance.insertDomain(
          id: 'host_urltest_${r.host}_${DateTime.now().millisecondsSinceEpoch}',
          host: r.host!,
          scheduleId: null,
        );
        insertedTotal++;
      }
      // 4. Re-apply policies so URLBlocklist picks up the new keywords.
      setState(
          () => _autoFixPhase = '정책 동기화 중 (+$insertedTotal 키워드)...');
      await UniversalBrowserBlockService.instance.syncNow(reason: 'url_test');
      if (r.handle != null && r.handle!.isNotEmpty) {
        setState(() => _autoFixPhase = 'Chrome/Firefox 확장 복구 중...');
        try {
          await ChromeChannelApplyProbeService.instance
              .repairForHandle(r.handle!);
        } catch (_) {}
        try {
          await FirefoxChannelApplyProbeService.instance
              .repairForHandle(r.handle!);
        } catch (_) {}
      } else {
        await ChromeExtensionPayloadService.ensureStablePayload();
      }
      // 6. Re-run the test to refresh layer verdicts.
      setState(() => _autoFixPhase = '재점검 중...');
      final _TestResult fresh = await _runChecks(r.url);
      if (!mounted) return;
      setState(() => _result = fresh);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(fresh.overall
              ? '✅ 차단 적용됨! 브라우저 완전 종료 후 다시 열어주세요.'
              : '일부 단계는 아직 미적용 — 다시 「자동 적용」을 누르거나 ACL 잠금을 풀어주세요.'),
          duration: const Duration(seconds: 5),
        ),
      );
    } catch (e) {
      AppLogger.instance.warn('url_test auto_fix failed: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('자동 수정 오류: $e')),
      );
    } finally {
      if (mounted) {
        setState(() {
          _autoFixing = false;
          _autoFixPhase = '';
        });
      }
    }
  }

  Future<String?> _findScheduleForHandle(String handle) async {
    final List<Map<String, Object?>> kws =
        await LocalDatabase.instance.keywordsAllEnabled();
    final String hLow = handle.toLowerCase();
    for (final Map<String, Object?> kw in kws) {
      final String pat = (kw['pattern'] as String? ?? '').toLowerCase();
      if (pat.contains('@$hLow') || pat.contains('/$hLow')) {
        return kw['schedule_id'] as String?;
      }
    }
    return null;
  }

  Future<String?> _anyEnabledScheduleId() async {
    final List<Map<String, Object?>> kws =
        await LocalDatabase.instance.keywordsAllEnabled();
    for (final Map<String, Object?> kw in kws) {
      final String? sid = kw['schedule_id'] as String?;
      if (sid != null && sid.isNotEmpty) return sid;
    }
    return null;
  }

  Future<void> _copyResult() async {
    final _TestResult? r = _result;
    if (r == null) return;
    final StringBuffer sb = StringBuffer();
    sb.writeln('# URL 점검 결과: ${r.url}');
    sb.writeln('Video ID: ${r.videoId ?? "(없음)"}');
    sb.writeln('Handle: ${r.handle ?? "(없음)"}');
    sb.writeln('Host: ${r.host ?? "(없음)"}');
    sb.writeln('Overall: ${r.overall ? "BLOCKED" : "NOT BLOCKED"}');
    sb.writeln();
    for (final _LayerResult l in r.layers) {
      sb.writeln('${l.ok ? "[OK]" : "[FAIL]"} ${l.title}');
      sb.writeln('  ${l.detail}');
    }
    await Clipboard.setData(ClipboardData(text: sb.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('점검 결과 복사됨')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(
          color: AppColors.accent.withValues(alpha: 0.3),
          width: 1.5,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.search, color: AppColors.accent),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'URL 차단 즉시 점검',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'YouTube URL이나 사이트 주소를 붙여넣으면 — DB → 패턴 → 레지스트리 → '
              '실제 매칭 4단계를 검사해서 어디서 막혔는지 알려줍니다.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _ctrl,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'https://www.youtube.com/watch?v=...',
                hintStyle: const TextStyle(fontSize: 13),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.paste, size: 18),
                  tooltip: '클립보드에서 붙여넣기',
                  onPressed: () async {
                    final ClipboardData? d =
                        await Clipboard.getData(Clipboard.kTextPlain);
                    if (d?.text != null) _ctrl.text = d!.text!.trim();
                  },
                ),
              ),
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              onSubmitted: (_) => _run(),
            ),
            const SizedBox(height: 8),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.icon(
                    icon: _running
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.play_arrow, size: 18),
                    label: Text(_running ? '점검 중...' : '지금 점검'),
                    onPressed: _running ? null : _run,
                  ),
                ),
                if (_result != null) ...<Widget>[
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('결과 복사'),
                    onPressed: _copyResult,
                  ),
                ],
              ],
            ),
            if (_result != null) ...<Widget>[
              const SizedBox(height: 12),
              _buildResult(_result!),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildResult(_TestResult r) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: r.overall
                ? AppColors.accent.withValues(alpha: 0.12)
                : AppColors.danger.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: <Widget>[
              Icon(
                r.overall ? Icons.check_circle : Icons.cancel,
                color: r.overall ? AppColors.accent : AppColors.danger,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  r.overall ? '✅ 이 URL은 차단됩니다' : '❌ 이 URL은 차단되지 않습니다',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: r.overall ? AppColors.accent : AppColors.danger,
                  ),
                ),
              ),
            ],
          ),
        ),
        // INLINE auto-fix button — when test fails, show the action right
        // here. The user explicitly demanded this: "여기에 전부 적용 자동
        // 적용 버튼이 여기 있기를 원한다고!! 여기에 아무 버튼이 없고 유저가
        // 다른 곳에 직접 가서 그 버튼들을 일일히 찾아야 되잖아 미쳤냐?"
        if (!r.overall) ...<Widget>[
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              icon: _autoFixing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.auto_fix_high),
              label: Text(
                _autoFixing
                    ? (_autoFixPhase.isEmpty
                        ? '자동 적용 중...'
                        : _autoFixPhase)
                    : '이 URL 차단 즉시 적용 (한 번 클릭)',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.danger,
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              onPressed: _autoFixing ? null : _runAutoFix,
            ),
          ),
          const SizedBox(height: 4),
          const Text(
            '한 번 누르면 — 채널 비디오 자동 가져오기 → DB 추가 → 정책 동기화 → '
            '재점검을 모두 자동으로 수행합니다.',
            style: TextStyle(fontSize: 11, color: Colors.grey),
          ),
        ],
        const SizedBox(height: 8),
        Text(
          '추출된 정보: '
          'video=${r.videoId ?? "(없음)"}, '
          'handle=${r.handle ?? "(없음)"}, '
          'host=${r.host ?? "(없음)"}',
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
        const SizedBox(height: 6),
        for (final _LayerResult l in r.layers)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  l.ok ? Icons.check_circle : Icons.cancel,
                  size: 18,
                  color: l.ok ? AppColors.accent : AppColors.danger,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        l.title,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 12),
                      ),
                      SelectableText(
                        l.detail,
                        style: TextStyle(
                          fontSize: 11,
                          color: l.ok ? Colors.grey.shade700 : AppColors.danger,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _LayerResult {
  const _LayerResult(
      {required this.title, required this.ok, required this.detail});
  final String title;
  final bool ok;
  final String detail;
}

class _TestResult {
  const _TestResult({
    required this.url,
    required this.videoId,
    required this.handle,
    required this.host,
    required this.layers,
    required this.overall,
  });
  final String url;
  final String? videoId;
  final String? handle;
  final String? host;
  final List<_LayerResult> layers;
  final bool overall;
}
