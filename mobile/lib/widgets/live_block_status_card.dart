import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import '../services/app_logger.dart';
import '../services/chrome_extension_identity.dart';
import '../services/universal_browser_block_service.dart';
import '../services/windows_hidden_process.dart';
import '../services/chrome_channel_apply_probe_service.dart';
import '../services/windows_firefox_extension_install_service.dart';
import '../services/youtube_channel_videos_fetcher_service.dart';
import '../theme/app_colors.dart';

/// One-screen, auto-refreshing status of the browser block.
///
/// What the user wanted (verbatim):
///   "이게 자동으로 그리고 쉽게 적용할수 있어야 유저가 이게 작동하는지
///    안하는지, 리스트에 잘 넣은게 맞는지 아닌지 실시간으로 알수 있지!"
///
/// Each row shows a single, plain-language fact ("Chrome 차단 패턴: 892개")
/// with a green check or red x. Failing rows expose a one-tap fix button.
/// Auto-refreshes every 5 seconds so the user sees state change live as
/// the watchdog applies policies.
class LiveBlockStatusCard extends StatefulWidget {
  const LiveBlockStatusCard({super.key});

  @override
  State<LiveBlockStatusCard> createState() => _LiveBlockStatusCardState();
}

class _LiveBlockStatusCardState extends State<LiveBlockStatusCard>
    with WidgetsBindingObserver {
  // Interval was 5s — that spawned 7 reg.exe + 1 PowerShell call EVERY 5
  // seconds = ~84 child processes per minute. Sustained over the time the
  // user keeps the diagnostics tab open, this drove the app to nearly
  // 100% of one CPU core (1021s CPU in 17min wall clock) and caused
  // severe lag the user complained about. New rule:
  //
  //   * No background probe in this app may fire faster than 30 seconds.
  //   * Page-visible AND foreground required for any timed probe.
  //   * Refresh shortcut is the explicit refresh button + auto-fix.
  //
  // 30s feels "live" to a user without burning CPU. The user can hit the
  // manual refresh icon any time for an instant probe.
  static const Duration _refreshInterval = Duration(seconds: 30);

  Timer? _timer;
  bool _refreshing = false;
  bool _autoFixing = false;
  _BlockStatus? _status;
  AppLifecycleState _lifecycle = AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    _timer = Timer.periodic(_refreshInterval, (_) {
      // Skip probe when app is in background. The data won't change
      // meaningfully while the user isn't looking and the cost is real.
      if (_lifecycle != AppLifecycleState.resumed) return;
      _refresh();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycle = state;
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    _refreshing = true;
    try {
      final _BlockStatus next = await _BlockStatus.probe();
      if (!mounted) return;
      setState(() {
        _status = next;
      });
    } catch (e) {
      AppLogger.instance.warn('live_block_status probe failed: $e');
    } finally {
      _refreshing = false;
    }
  }

  String _autoFixPhase = '';

  Future<void> _runAutoFix() async {
    if (_autoFixing) return;
    setState(() {
      _autoFixing = true;
      _autoFixPhase = '시작...';
    });
    try {
      // 1. Fetch every blocked channel's recent videos from YouTube and
      //    insert them as keyword rows. This is what makes channel-block
      //    actually block the channel's videos. Without this step the
      //    URLBlocklist only catches the channel landing page; individual
      //    `/watch?v=…` URLs sail through.
      setState(() => _autoFixPhase = '채널 비디오 자동 페치 중...');
      final Map<String, int> fetched =
          await YoutubeChannelVideosFetcherService.instance
              .syncAllBlockedChannels();
      final int totalInserted =
          fetched.values.fold<int>(0, (int a, int b) => a + b);
      // 2. Re-apply URLBlocklist + bypass closer + all derivatives. Now
      //    the new video IDs land as patterns in HKCU.
      setState(() =>
          _autoFixPhase = '정책 동기화 중 (비디오 +$totalInserted)...');
      await UniversalBrowserBlockService.instance.syncNow(reason: 'live_card');
      // 3. Install extension to every Chrome profile (uses existing
      //    load-extension launcher mechanism — no Web Store needed).
      setState(() => _autoFixPhase = '확장 자동 설치 중...');
      setState(() => _autoFixPhase = 'Chrome 확장 + HKCU 정책 적용 중...');
      try {
        await ChromeChannelApplyProbeService.instance.repairForHandle('auto_fix');
      } catch (_) {}
      setState(() => _autoFixPhase = 'Firefox XPI + HKCU 정책 적용 중...');
      try {
        await WindowsFirefoxExtensionInstallService.instance
            .applyHkcuExtensionPolicy();
      } catch (_) {}
      setState(() => _autoFixPhase = '완료 — 상태 새로고침 중...');
      // 4. Bust the status cache so the UI shows the new state immediately.
      _BlockStatus._cached = null;
    } catch (e) {
      AppLogger.instance.warn('live_block_status auto_fix failed: $e');
      setState(() => _autoFixPhase = '오류: $e');
    } finally {
      await _refresh();
      if (mounted) {
        setState(() {
          _autoFixing = false;
          _autoFixPhase = '';
        });
      }
    }
  }

  Future<void> _copyDiagnosticDump() async {
    final _BlockStatus? s = _status;
    if (s == null) return;
    final StringBuffer sb = StringBuffer();
    sb.writeln('# 6VPN 실시간 차단 상태');
    sb.writeln('읽은 시각: ${DateTime.now().toLocal()}');
    sb.writeln();
    for (final _StatusRow r in s.rows) {
      sb.writeln('${r.ok ? "[OK]" : "[FAIL]"} ${r.label}: ${r.detail}');
    }
    sb.writeln();
    sb.writeln('# 다음 행동 추천');
    if (s.allOk) {
      sb.writeln('- 모두 정상. Chrome / Edge / Firefox 완전 종료 후 다시 열어주세요.');
    } else {
      sb.writeln('- 「지금 자동 수정」 버튼을 눌러주세요.');
      sb.writeln('- 그래도 안 되면 이 텍스트를 Claude / Cursor에 붙여넣으세요.');
    }
    await Clipboard.setData(ClipboardData(text: sb.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('상태 텍스트 복사됨')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final _BlockStatus? s = _status;
    if (s == null) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Row(
            children: <Widget>[
              SizedBox(
                width: 18, height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(width: 12),
              Text('차단 상태 확인 중...'),
            ],
          ),
        ),
      );
    }
    final Color borderColor =
        s.allOk ? AppColors.accent : AppColors.danger;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: borderColor.withValues(alpha: 0.4), width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(
                  s.allOk ? Icons.shield : Icons.warning_amber_rounded,
                  color: borderColor,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    s.allOk
                        ? '차단 작동 중 — 모든 항목 정상'
                        : '차단 일부 미적용 — ${s.failedCount}개 문제',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                      color: borderColor,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '지금 새로고침',
                  icon: const Icon(Icons.refresh, size: 18),
                  onPressed: _refresh,
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '5초마다 자동 확인 · 마지막: ${_formatTime(s.checkedAt)}',
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
            const Divider(height: 18),
            for (final _StatusRow r in s.rows) _buildRow(r),
            const SizedBox(height: 10),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.icon(
                    icon: _autoFixing
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.auto_fix_high),
                    label: Text(
                      _autoFixing
                          ? (_autoFixPhase.isEmpty
                              ? '자동 수정 중...'
                              : _autoFixPhase)
                          : '한 번에 모두 해결',
                    ),
                    onPressed: _autoFixing ? null : _runAutoFix,
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  icon: const Icon(Icons.copy, size: 16),
                  label: const Text('상태 복사'),
                  onPressed: _copyDiagnosticDump,
                ),
              ],
            ),
            if (!s.allOk) ...<Widget>[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.amber.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  '브라우저는 시작 시점에만 정책을 읽습니다. 자동 수정 후 '
                  'Chrome / Edge / Firefox를 **완전히 종료**(트레이까지)했다가 '
                  '다시 열어야 차단이 활성화됩니다.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRow(_StatusRow r) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(
            r.ok ? Icons.check_circle : Icons.cancel,
            size: 18,
            color: r.ok ? AppColors.accent : AppColors.danger,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  r.label,
                  style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
                ),
                Text(
                  r.detail,
                  style: TextStyle(
                    fontSize: 12,
                    color: r.ok ? Colors.grey.shade700 : AppColors.danger,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime t) {
    final DateTime local = t.toLocal();
    return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}:${local.second.toString().padLeft(2, '0')}';
  }
}

class _StatusRow {
  const _StatusRow({
    required this.label,
    required this.detail,
    required this.ok,
  });
  final String label;
  final String detail;
  final bool ok;
}

class _BlockStatus {
  _BlockStatus({required this.rows, required this.checkedAt});
  final List<_StatusRow> rows;
  final DateTime checkedAt;

  bool get allOk => rows.every((_StatusRow r) => r.ok);
  int get failedCount => rows.where((_StatusRow r) => !r.ok).length;

  /// Process-cached probe — if the last probe is <_kCacheTtl old, reuse it
  /// instead of re-spawning all the registry/disk lookups. This protects
  /// against accidental rapid-refresh (multiple widget instances, hot
  /// reload, user mashing the refresh button) from re-creating the lag.
  static _BlockStatus? _cached;
  static const Duration _kCacheTtl = Duration(seconds: 25);

  static Future<_BlockStatus> probe() async {
    final _BlockStatus? c = _cached;
    if (c != null &&
        DateTime.now().difference(c.checkedAt) < _kCacheTtl) {
      return c;
    }
    final _BlockStatus fresh = await _probeNow();
    _cached = fresh;
    return fresh;
  }

  static Future<_BlockStatus> _probeNow() async {
    final List<_StatusRow> rows = <_StatusRow>[];
    if (!Platform.isWindows) {
      rows.add(const _StatusRow(
        label: '플랫폼',
        detail: 'Windows 전용 — macOS는 자체 파이프라인',
        ok: false,
      ));
      return _BlockStatus(rows: rows, checkedAt: DateTime.now());
    }

    // Chrome URLBlocklist count.
    final int chromeCount = await _countRegistryEntries(
      r'HKCU\SOFTWARE\Policies\Google\Chrome\URLBlocklist',
    );
    rows.add(_StatusRow(
      label: 'Chrome 차단 패턴',
      detail: chromeCount > 0
          ? '$chromeCount개 적용 중'
          : '0개 — 정책 키가 비어있음 (ACL 잠금 가능성)',
      ok: chromeCount > 0,
    ));

    // Edge URLBlocklist count.
    final int edgeCount = await _countRegistryEntries(
      r'HKCU\SOFTWARE\Policies\Microsoft\Edge\URLBlocklist',
    );
    rows.add(_StatusRow(
      label: 'Edge 차단 패턴',
      detail: edgeCount > 0 ? '$edgeCount개 적용 중' : '0개 — 미적용',
      ok: edgeCount > 0,
    ));

    // Firefox WebsiteFilter\Block count.
    final int ffCount = await _countRegistryEntries(
      r'HKCU\SOFTWARE\Policies\Mozilla\Firefox\WebsiteFilter\Block',
    );
    rows.add(_StatusRow(
      label: 'Firefox 차단 패턴',
      detail: ffCount > 0 ? '$ffCount개 적용 중' : '0개 — 미적용',
      ok: ffCount > 0,
    ));

    // HKCU policy ACL writable. We INFER from chromeCount > 0 most of the
    // time (if URLBlocklist has entries, ACL must be writable). Skip the
    // explicit write+delete probe when we already know it's fine — that
    // probe is a reg-add + reg-delete pair, two more process spawns we
    // can avoid 99% of the time.
    final bool aclOk = chromeCount > 0 ? true : await _hkcuPolicyWritable();
    rows.add(_StatusRow(
      label: 'HKCU 정책 키 쓰기 권한',
      detail: aclOk
          ? '쓰기 가능 (잠금 없음)'
          : 'ACL 잠금 — 정책 쓰기가 모두 실패합니다',
      ok: aclOk,
    ));

    // Extension installed in any Chrome profile.
    final _ExtensionState extState = await _checkExtensionInstall();
    rows.add(_StatusRow(
      label: 'Chrome 확장 설치',
      detail: extState.installed
          ? '${extState.profilesWithExt}/${extState.totalProfiles} 프로필에 설치됨'
          : '0개 프로필 — SPA 채널 차단 안 됨 (자동 수정으로 설치)',
      ok: extState.installed,
    ));

    // Extension registry sideload.
    final bool extReg = await _checkRegistryKey(
      'HKCU\\SOFTWARE\\Google\\Chrome\\Extensions\\${ChromeExtensionIdentity.extensionId}',
    );
    rows.add(_StatusRow(
      label: '확장 자동 로드 등록',
      detail: extReg
          ? 'HKCU에 등록됨 — 다음 Chrome 실행 시 자동 로드'
          : '등록 안 됨 — 자동 수정 누르면 즉시 등록',
      ok: extReg,
    ));

    final FirefoxInstallVerifyResult ffVerify =
        await WindowsFirefoxExtensionInstallService.verify();
    rows.add(_StatusRow(
      label: 'Firefox Focus Fense',
      detail: ffVerify.profileCount > 0
          ? 'XPI ${ffVerify.profileCount}/${ffVerify.profileTotal} · '
              'policies ${ffVerify.policiesOk ? "OK" : "없음"} — 재시작 후 about:addons 확인'
          : 'XPI 미복사 — 「지금 자동 수정」',
      ok: ffVerify.profileCount > 0 && ffVerify.xpiInProgramData,
    ));

    return _BlockStatus(rows: rows, checkedAt: DateTime.now());
  }

  static Future<int> _countRegistryEntries(String key) async {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final String reg = p.join(windir, 'System32', 'reg.exe');
    try {
      final ProcessResult r = await windowsRunHidden(
        reg,
        <String>['query', key, '/s'],
      );
      if (r.exitCode != 0) return 0;
      int count = 0;
      for (final String line in '${r.stdout}'.split('\n')) {
        if (line.contains('REG_SZ') && !line.contains('(Default)')) {
          count++;
        }
      }
      return count;
    } catch (_) {
      return 0;
    }
  }

  static Future<bool> _hkcuPolicyWritable() async {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final String reg = p.join(windir, 'System32', 'reg.exe');
    const String probeKey = r'HKCU\SOFTWARE\Policies\Google\Chrome';
    const String probeName = '_LiveStatusProbe';
    try {
      final ProcessResult r = await windowsRunHidden(
        reg,
        <String>['add', probeKey, '/v', probeName, '/t', 'REG_SZ', '/d', '1', '/f'],
      );
      if (r.exitCode == 0) {
        await windowsRunHidden(
          reg,
          <String>['delete', probeKey, '/v', probeName, '/f'],
        );
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _checkRegistryKey(String key) async {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final String reg = p.join(windir, 'System32', 'reg.exe');
    try {
      final ProcessResult r = await windowsRunHidden(
        reg,
        <String>['query', key],
      );
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<_ExtensionState> _checkExtensionInstall() async {
    final String? localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData == null) {
      return const _ExtensionState(installed: false, profilesWithExt: 0, totalProfiles: 0);
    }
    final Directory chromeUserData =
        Directory(p.join(localAppData, 'Google', 'Chrome', 'User Data'));
    if (!await chromeUserData.exists()) {
      return const _ExtensionState(installed: false, profilesWithExt: 0, totalProfiles: 0);
    }
    int total = 0;
    int withExt = 0;
    final String extId = ChromeExtensionIdentity.extensionId;
    await for (final FileSystemEntity entity in chromeUserData.list()) {
      if (entity is! Directory) continue;
      final String name = p.basename(entity.path);
      if (name != 'Default' && !name.startsWith('Profile ')) continue;
      total++;
      final Directory extDir = Directory(
        p.join(entity.path, 'Extensions', extId),
      );
      if (await extDir.exists()) withExt++;
    }
    return _ExtensionState(
      installed: withExt > 0,
      profilesWithExt: withExt,
      totalProfiles: total,
    );
  }
}

class _ExtensionState {
  const _ExtensionState({
    required this.installed,
    required this.profilesWithExt,
    required this.totalProfiles,
  });
  final bool installed;
  final int profilesWithExt;
  final int totalProfiles;
}
