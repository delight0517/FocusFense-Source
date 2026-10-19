import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import '../data/browser_extension_asset_manifest.dart';
import '../services/app_logger.dart';
import '../services/browser_one_tap_service.dart';
import '../services/browser_extension_export_service.dart';
import '../services/browser_extension_launcher.dart';
import '../services/chrome_extension_identity.dart';
import '../services/extension_rules_builder.dart';
import '../services/extension_guard_prefs.dart';
import '../services/usage_ingest_server.dart';
import '../services/windows_extension_guard_service.dart';
import '../services/windows_extension_self_heal_service.dart';
import '../services/windows_extension_setup_automation.dart';
import '../services/windows_firefox_extension_install_service.dart';
import '../services/browser_block_health_monitor_service.dart';
import '../services/chrome_extension_state_probe.dart';
import '../services/chromium_derivative_extension_service.dart';
import '../services/platform_process.dart';
import '../theme/app_colors.dart';
import '../widgets/browser_extension_setup_guides.dart';
import '../widgets/app_live_log_panel.dart';
import '../widgets/copyable_snackbar.dart';
import 'log_viewer_screen.dart';
import 'youtube_feed_block_screen.dart';

/// Full wizard: export extension folder → one-click open browser extension
/// settings → copy path → auto-sync keywords/domains to extension storage JSON.
class BrowserExtensionsScreen extends StatefulWidget {
  const BrowserExtensionsScreen({super.key});

  @override
  State<BrowserExtensionsScreen> createState() =>
      _BrowserExtensionsScreenState();
}

class _BrowserExtensionsScreenState extends State<BrowserExtensionsScreen>
    with SingleTickerProviderStateMixin {
  // Step index: 0 = export, 1 = load, 2 = done
  int _step = 0;
  bool _exporting = false;
  bool _syncing = false;
  String? _chromePath;
  String? _firefoxPath;
  bool? _bundledOk;
  bool _applyingGuard = false;
  bool _autoInstalling = false;
  bool _asideBusy = false;
  String? _asideStatus;
  DerivativeExtensionVerifyResult? _asideVerify;

  /// 0 = Chrome, 1 = Edge, 2 = Firefox (step 2 UI tabs).
  int _browserSetupTab = 0;
  String _exportLocationLabel = '다운로드';
  String? _exportRootPreview;
  String? _expectedChromePath;
  String? _expectedFirefoxPath;
  late Future<_ExtensionAvailabilitySnapshot> _extensionAvailability;
  late final AnimationController _stepAnim;

  @override
  void initState() {
    super.initState();
    _stepAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    _verifyBundle();
    _restoreExistingPaths();
    unawaited(_refreshPathPreview());
    _extensionAvailability = _loadExtensionAvailability();
    if (Platform.isWindows) unawaited(_refreshAsideStatus());
  }

  Future<void> _refreshAsideStatus() async {
    final result = await ChromiumDerivativeExtensionService.instance.verify(
      'aside',
    );
    if (!mounted) return;
    setState(() => _asideVerify = result);
  }

  Future<void> _installAside() async {
    setState(() {
      _asideBusy = true;
      _asideStatus = null;
    });
    try {
      final result = await ChromiumDerivativeExtensionService.instance
          .installAside(reason: 'settings');
      if (!mounted) return;
      setState(() {
        _asideStatus = result.message;
        _asideVerify = result.verify;
      });
      _showSnack(result.message);
    } finally {
      if (mounted) setState(() => _asideBusy = false);
    }
  }

  Future<void> _uninstallAside() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Aside 확장 비활성화'),
        content: const Text(
          '확장 제거 정책을 적용하고 앱의 자동 재설치를 중지합니다. 사이트 차단 규칙은 별도로 유지됩니다. 브라우저가 정책을 다시 읽어야 반영됩니다.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('비활성화'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _asideBusy = true;
      _asideStatus = null;
    });
    try {
      final result = await WindowsExtensionGuardService.instance
          .disableBrowserExtension('aside');
      if (!mounted) return;
      setState(() => _asideStatus = result.message);
      await _refreshAsideStatus();
      _showSnack(result.message);
    } finally {
      if (mounted) setState(() => _asideBusy = false);
    }
  }

  Future<void> _manageBrowserExtension(String browserId, bool enabled) async {
    if (browserId == 'aside') {
      if (enabled) {
        await _installAside();
      } else {
        await _uninstallAside();
      }
      return;
    }
    setState(() {
      _asideBusy = true;
      _asideStatus = null;
    });
    try {
      ExtensionGuardResult result;
      if (!enabled) {
        result = await WindowsExtensionGuardService.instance
            .disableBrowserExtension(browserId);
      } else {
        final BrowserExtensionExportResult chrome =
            await BrowserExtensionExportService.exportAssets(
              assetPaths: BrowserExtensionAssetManifest.chrome,
              subdirName: BrowserExtensionExportService.kChromeSubdir,
            );
        if (!chrome.ok) throw StateError('확장 파일을 준비하지 못했습니다.');
        if (browserId == 'firefox') {
          final BrowserExtensionExportResult firefox =
              await BrowserExtensionExportService.exportAssets(
                assetPaths: BrowserExtensionAssetManifest.firefox,
                subdirName: BrowserExtensionExportService.kFirefoxSubdir,
              );
          if (!firefox.ok) throw StateError('Firefox 확장 파일을 준비하지 못했습니다.');
        }
        await ExtensionGuardPrefs.instance.setBrowserEnabled(browserId, true);
        result = await WindowsExtensionGuardService.instance.runElevatedGuard(
          chromeExtensionFolder: chrome.path,
          onlyBrowserId: browserId,
        );
      }
      if (mounted) {
        setState(() => _asideStatus = result.message);
        _showSnack(result.message);
      }
    } catch (error) {
      if (mounted) setState(() => _asideStatus = '확장 설정 실패: $error');
    } finally {
      if (mounted) setState(() => _asideBusy = false);
    }
  }

  Widget _asideManagementCard(ThemeData theme) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            '브라우저 확장 켜기·끄기',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 6),
          for (final MapEntry<String, String> browser in const <String, String>{
            'chrome': 'Chrome',
            'edge': 'Edge',
            'firefox': 'Firefox',
            'aside': 'Aside AI Browser',
          }.entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  Text(
                    '${browser.value} · ${ExtensionGuardPrefs.instance.isBrowserExplicitlyDisabled(browser.key) ? '자동 설치·복구 중지' : '설치·복구 허용'}',
                  ),
                  FilledButton.tonal(
                    onPressed: _asideBusy
                        ? null
                        : () => _manageBrowserExtension(browser.key, true),
                    child: const Text('설치·켜기'),
                  ),
                  OutlinedButton(
                    onPressed: _asideBusy
                        ? null
                        : () => _manageBrowserExtension(browser.key, false),
                    child: const Text('끄기·제거'),
                  ),
                ],
              ),
            ),
          Text(
            _asideVerify == null
                ? '정책·확장 상태 확인 중…'
                : _asideVerify!.extensionReady
                ? '강제 설치 정책과 확장 페이로드가 확인되었습니다.'
                : '확장 상태: ${_asideVerify!.detail}',
            style: theme.textTheme.bodySmall,
          ),
          if (_asideStatus != null)
            Text(_asideStatus!, style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            children: <Widget>[
              OutlinedButton.icon(
                onPressed: _asideBusy ? null : _refreshAsideStatus,
                icon: const Icon(Icons.refresh),
                label: const Text('Aside 상태 확인'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '설치·제거는 Windows 관리자 승인을 요청합니다. 제거해도 URLBlocklist의 사이트 차단 규칙은 지우지 않습니다.',
            style: theme.textTheme.bodySmall?.copyWith(color: AppColors.muted),
          ),
        ],
      ),
    ),
  );

  Future<_ExtensionAvailabilitySnapshot> _loadExtensionAvailability() async {
    if (!Platform.isWindows) {
      return const _ExtensionAvailabilitySnapshot({}, {});
    }
    final BrowserBlockHealthReport report =
        await BrowserBlockHealthMonitorService.instance.probe(
          reason: 'extension_setup_status',
        );
    final Map<String, bool> browserInstalled = <String, bool>{
      for (final BrowserHealth browser in report.browsers)
        browser.id: browser.installed,
    };
    final Map<String, bool> extensionInstalled = <String, bool>{};
    if (browserInstalled['chrome'] == true) {
      extensionInstalled['chrome'] = (await ChromeExtensionStateProbe.probe(
        browser: 'chrome',
      )).properlyInstalled;
    }
    if (browserInstalled['edge'] == true) {
      extensionInstalled['edge'] = (await ChromeExtensionStateProbe.probe(
        browser: 'edge',
      )).properlyInstalled;
    }
    if (browserInstalled['firefox'] == true) {
      final FirefoxInstallVerifyResult firefox =
          await WindowsFirefoxExtensionInstallService.verify();
      extensionInstalled['firefox'] =
          firefox.policiesOk &&
          firefox.xpiInProgramData &&
          firefox.profileCount > 0;
    }
    return _ExtensionAvailabilitySnapshot(browserInstalled, extensionInstalled);
  }

  void _refreshExtensionAvailability() {
    setState(() => _extensionAvailability = _loadExtensionAvailability());
  }

  Widget _extensionAvailabilityCard(ThemeData theme) {
    return FutureBuilder<_ExtensionAvailabilitySnapshot>(
      future: _extensionAvailability,
      builder:
          (
            BuildContext context,
            AsyncSnapshot<_ExtensionAvailabilitySnapshot> snapshot,
          ) {
            if (snapshot.connectionState != ConnectionState.done ||
                !snapshot.hasData) {
              return const Card(
                child: ListTile(
                  leading: SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  title: Text('브라우저 확장 설치 상태 확인 중…'),
                ),
              );
            }
            final _ExtensionAvailabilitySnapshot state = snapshot.data!;
            final List<Widget> rows = <Widget>[];
            for (final ({String id, String name}) browser
                in const <({String id, String name})>[
                  (id: 'chrome', name: 'Chrome'),
                  (id: 'edge', name: 'Microsoft Edge'),
                  (id: 'firefox', name: 'Firefox'),
                ]) {
              final bool available = state.browserInstalled[browser.id] == true;
              final bool installed =
                  state.extensionInstalled[browser.id] == true;
              rows.add(
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    !available
                        ? Icons.remove_circle_outline
                        : installed
                        ? Icons.verified_outlined
                        : Icons.warning_amber_rounded,
                    color: !available
                        ? AppColors.muted
                        : installed
                        ? AppColors.success
                        : AppColors.warning,
                  ),
                  title: Text(browser.name),
                  subtitle: Text(
                    !available
                        ? 'Unavailable · 이 브라우저가 PC에 설치되어 있지 않습니다.'
                        : installed
                        ? '확장 설치 확인됨'
                        : '브라우저는 사용 가능하지만 차단 확장은 아직 설치되지 않았습니다.',
                  ),
                  trailing: !available || installed
                      ? Text(!available ? 'Unavailable' : '완료')
                      : TextButton.icon(
                          onPressed: _exporting || _syncing
                              ? null
                              : browser.id == 'firefox'
                              ? _doSetupFirefox
                              : _doSetupChrome,
                          icon: const Icon(Icons.download_outlined),
                          label: const Text('다운로드'),
                        ),
                ),
              );
            }
            final bool needsSetup = state.browserInstalled.entries.any(
              (MapEntry<String, bool> e) =>
                  e.value && state.extensionInstalled[e.key] != true,
            );
            return Card(
              color: needsSetup
                  ? AppColors.warning.withValues(alpha: 0.12)
                  : AppColors.success.withValues(alpha: 0.10),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Icon(
                          needsSetup
                              ? Icons.warning_amber_rounded
                              : Icons.shield_outlined,
                          color: needsSetup
                              ? AppColors.warning
                              : AppColors.success,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            needsSetup
                                ? '차단 설정이 아직 끝나지 않았습니다'
                                : '브라우저별 차단 확장 상태',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: '상태 다시 확인',
                          onPressed: _refreshExtensionAvailability,
                          icon: const Icon(Icons.refresh),
                        ),
                      ],
                    ),
                    Text(
                      needsSetup
                          ? 'PC에 있는 브라우저 중 확장 프로그램이 없는 항목은 아래 다운로드 버튼으로 설치를 진행하세요.'
                          : '설치 파일 준비 여부가 아니라 브라우저 프로필의 실제 확장 설치 상태를 확인합니다.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppColors.muted,
                      ),
                    ),
                    const SizedBox(height: 4),
                    ...rows,
                  ],
                ),
              ),
            );
          },
    );
  }

  Future<void> _refreshPathPreview() async {
    try {
      final String rootLine =
          await BrowserExtensionExportService.exportRootDisplayLine();
      final String chrome =
          await BrowserExtensionExportService.expectedChromePath();
      final String firefox =
          await BrowserExtensionExportService.expectedFirefoxPath();
      if (!mounted) return;
      setState(() {
        _exportRootPreview = rootLine;
        _expectedChromePath = chrome;
        _expectedFirefoxPath = firefox;
        if (_chromePath == null) {
          final Directory d = Directory(chrome);
          if (d.existsSync()) _chromePath = chrome;
        }
        if (_firefoxPath == null) {
          final Directory d = Directory(firefox);
          if (d.existsSync()) _firefoxPath = firefox;
        }
      });
    } catch (_) {}
  }

  Future<void> _restoreExistingPaths() async {
    final String? chrome =
        await BrowserExtensionExportService.existingFolderPath(
          BrowserExtensionExportService.kChromeSubdir,
        );
    final String? firefox =
        await BrowserExtensionExportService.existingFolderPath(
          BrowserExtensionExportService.kFirefoxSubdir,
        );
    if (!mounted) return;
    if (chrome != null || firefox != null) {
      setState(() {
        if (chrome != null) _chromePath = chrome;
        if (firefox != null) _firefoxPath = firefox;
        if (_chromePath != null || _firefoxPath != null) {
          _step = _step < 1 ? 1 : _step;
        }
      });
    }
  }

  @override
  void dispose() {
    _stepAnim.dispose();
    super.dispose();
  }

  Future<void> _verifyBundle() async {
    try {
      for (final String a in _chromeAssets) {
        await rootBundle.load(a);
      }
      for (final String a in _firefoxAssets) {
        await rootBundle.load(a);
      }
      if (mounted) setState(() => _bundledOk = true);
    } catch (_) {
      if (mounted) setState(() => _bundledOk = false);
    }
  }

  static const List<String> _chromeAssets =
      BrowserExtensionAssetManifest.chrome;
  static const List<String> _firefoxAssets =
      BrowserExtensionAssetManifest.firefox;

  String _formatExportFailure(BrowserExtensionExportResult r) {
    final StringBuffer sb = StringBuffer('폴더 준비 실패\n');
    if (r.error != null && r.error!.isNotEmpty) {
      sb.writeln(r.error);
    }
    if (r.repairs.isNotEmpty) {
      sb.writeln('자동 복구 시도: ${r.repairs.join(' · ')}');
    }
    sb.writeln('버튼을 다시 누르거나 앱을 한 번 종료 후 재시도하세요.');
    return sb.toString().trim();
  }

  String _formatExportSuccess(BrowserExtensionExportResult r) {
    final StringBuffer sb = StringBuffer()
      ..writeln('준비 완료 · $_exportLocationLabel/SixVPN_확장')
      ..writeln(r.path);
    if (r.repairs.isNotEmpty) {
      sb.writeln('복구: ${r.repairs.join(' · ')}');
    }
    return sb.toString().trim();
  }

  /// Build a minimal chrome.storage-compatible JSON from the app DB and write
  /// it next to the extension files so users can import it via the options page.
  Future<void> _syncRulesToExtensionStorage(String extFolder) async {
    final ExtensionRulesPayload payload =
        await ExtensionRulesBuilder.buildActiveNow();
    final int port = UsageIngestServer.instance.boundPort;

    final Map<String, Object?> storageData = <String, Object?>{
      'hideImages': true,
      'hideSerp': true,
      'hideYtHomeFeed': false,
      'hideImagesOnYoutube': false,
      'hideGoogleHomeFeed': true,
      'forceSafeSearch': true,
      'keywords': payload.keywords,
      'searchQueries': payload.searchQueries.map((e) => e.toJson()).toList(),
      'blockedDomains': payload.blockedDomains,
      'precisionContentFilter': payload.precisionContentFilter,
      'rulesApi': 'http://127.0.0.1:$port/rules',
    };

    // Write as a JSON file the user can inspect; also write a readme.
    final File syncFile = File(p.join(extFolder, 'sixvpn_sync.json'));
    await syncFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(storageData),
    );

    final File readme = File(p.join(extFolder, 'SYNC_README.txt'));
    await readme.writeAsString(
      '이 폴더를 Chrome/Edge에 "압축 해제된 확장 프로그램으로 로드"하면\n'
      '아래 설정이 자동 적용됩니다.\n\n'
      '차단 키워드(검색 결과·영상 카드): ${payload.keywords.length}개\n'
      '차단 검색어(Google q / YouTube search_query): ${payload.searchQueries.length}개\n'
      '차단 도메인: ${payload.blockedDomains.length}개\n'
      '확장 ID(고정): ${ChromeExtensionIdentity.extensionId}\n'
      '실시간 API: http://127.0.0.1:$port/rules (앱 실행 중 자동 동기화)\n'
      'SafeSearch: ON\n'
      'YouTube 홈 전체 숨김: OFF (목록에 있는 채널·영상만)\n'
      'YouTube 채널·영상 패턴: ${payload.keywords.length}개\n'
      'Google 피드 숨김: ON\n'
      '이미지 숨김: Google 등 ON · YouTube 썸네일은 유지\n\n'
      '앱에서 단어·사이트를 추가하면 이 버튼을 다시 눌러\n'
      '폴더를 갱신하세요. (F5로 탭 새로고침)\n',
    );
  }

  Future<void> _doSetupChrome() async {
    setState(() => _exporting = true);
    try {
      final BrowserExtensionExportResult r =
          await BrowserExtensionExportService.exportAssets(
            assetPaths: _chromeAssets,
            subdirName: BrowserExtensionExportService.kChromeSubdir,
          );
      if (!r.ok) {
        if (mounted) _showSnack(_formatExportFailure(r));
        return;
      }
      _exportLocationLabel = r.locationLabel;
      setState(() {
        _chromePath = r.path;
        _syncing = true;
        _browserSetupTab = 0;
      });
      await _syncRulesToExtensionStorage(r.path);
      await _writeChromeEdgeInstallGuide(r.path);
      if (!mounted) return;
      setState(() {
        _syncing = false;
        _step = 1;
      });
      _stepAnim.forward(from: 0);
      _showSnack(_formatExportSuccess(r));
      await BrowserExtensionLauncher.revealExtensionFolder(r.path);
      await _refreshPathPreview();
    } catch (e, st) {
      await AppLogger.instance.repairLogFileIfNeeded();
      if (mounted) {
        _showSnack('폴더 준비 실패: $e\n(아래 실시간 로그 복사 · 다시 시도)');
      }
      AppLogger.instance.error('chrome extension export', error: e, stack: st);
    } finally {
      if (mounted) {
        setState(() {
          _exporting = false;
          _syncing = false;
        });
      }
    }
  }

  Future<void> _doSetupFirefox() async {
    setState(() => _exporting = true);
    try {
      final BrowserExtensionExportResult r =
          await BrowserExtensionExportService.exportAssets(
            assetPaths: _firefoxAssets,
            subdirName: BrowserExtensionExportService.kFirefoxSubdir,
          );
      if (!r.ok) {
        if (mounted) _showSnack(_formatExportFailure(r));
        return;
      }
      _exportLocationLabel = r.locationLabel;
      setState(() {
        _firefoxPath = r.path;
        _syncing = true;
        _browserSetupTab = 2;
      });
      await _syncRulesToExtensionStorage(r.path);
      await _writeFirefoxInstallGuide(r.path);
      if (!mounted) return;
      setState(() {
        _syncing = false;
        _step = 1;
      });
      _stepAnim.forward(from: 0);
      _showSnack(_formatExportSuccess(r));
      await BrowserExtensionLauncher.revealExtensionFolder(r.path);
      await _refreshPathPreview();
    } catch (e, st) {
      await AppLogger.instance.repairLogFileIfNeeded();
      if (mounted) {
        _showSnack('폴더 준비 실패: $e\n(아래 실시간 로그 복사 · 다시 시도)');
      }
      AppLogger.instance.error('firefox extension export', error: e, stack: st);
    } finally {
      if (mounted) {
        setState(() {
          _exporting = false;
          _syncing = false;
        });
      }
    }
  }

  Future<void> _writeChromeEdgeInstallGuide(String dir) async {
    final File f = File(p.join(dir, 'CHROME_EDGE_설치_가이드.txt'));
    await f.writeAsString(
      '■ Chrome / Edge 확장 설치 (Focus Fense)\n\n'
      '위치: $_exportLocationLabel\\SixVPN_확장\\chrome_blocker\n'
      '1) 이 폴더 전체를 기억: $dir\n'
      '2) Chrome 실행 → 주소창: chrome://extensions\n'
      '3) 오른쪽 위 「개발자 모드」 켜기\n'
      '4) 「압축 해제된 확장 프로그램을 로드합니다」\n'
      '5) 이 폴더(chrome_blocker) 선택 — manifest.json이 있는 폴더\n\n'
      'Edge: edge://extensions → 개발자 모드 → 같은 폴더 로드\n\n'
      '※ Windows Store가 뜨면 잘못된 경로입니다. 반드시 Chrome/Edge 안에서 열어야 합니다.\n',
    );
  }

  Future<void> _writeFirefoxInstallGuide(String dir) async {
    final File f = File(p.join(dir, 'FIREFOX_설치_가이드.txt'));
    await f.writeAsString(
      '■ Firefox 임시 애드온 설치 (Focus Fense)\n\n'
      '위치: $_exportLocationLabel\\SixVPN_확장\\firefox_blocker\n'
      '1) Firefox 실행\n'
      '2) 주소창에 입력: about:debugging#/runtime/this-firefox\n'
      '3) 왼쪽 「이 Firefox」(This Firefox) 클릭\n'
      '4) 「임시 애드온 불러오기…」(Load Temporary Add-on…)\n'
      '5) 이 폴더에서 manifest.json 파일 선택\n'
      '   경로: $dir\\manifest.json\n\n'
      '※ 폴더 전체가 아니라 manifest.json 한 파일을 고릅니다.\n'
      '※ Microsoft Store / 애드온 스토어가 아닙니다.\n'
      '※ Firefox를 완전히 종료 후 다시 열면 앱의 hosts·정책과 맞습니다.\n',
    );
  }

  Future<void> _openFolder(String path) async {
    await PlatformProcess.openFolder(path);
  }

  Future<void> _openFolderSafe(String path) async {
    try {
      await _openFolder(path);
    } catch (e, st) {
      AppLogger.instance.error('탐색기 폴더 열기 실패', error: e, stack: st);
      await Clipboard.setData(ClipboardData(text: path));
      if (mounted) {
        _showSnack(
          '폴더는 만들어졌지만 탐색기를 열지 못했습니다.\n'
          '경로가 클립보드에 복사되었습니다.\n$path',
        );
      }
    }
  }

  Future<void> _revealChromeFolder() async {
    final String? dir = _chromePath ?? _expectedChromePath;
    if (dir == null || dir.startsWith('(')) {
      _showSnack('먼저 ① Chrome/Edge 폴더 준비를 실행하세요.');
      return;
    }
    try {
      await BrowserExtensionLauncher.revealExtensionFolder(dir);
    } catch (e) {
      await _openFolderSafe(dir);
    }
  }

  Future<void> _revealFirefoxFolder() async {
    final String? dir = _firefoxPath ?? _expectedFirefoxPath;
    if (dir == null || dir.startsWith('(')) {
      _showSnack('먼저 ① Firefox 폴더 준비를 실행하세요.');
      return;
    }
    try {
      await BrowserExtensionLauncher.revealExtensionFolder(dir);
    } catch (e) {
      await _openFolderSafe(dir);
    }
  }

  Future<void> _launchBrowserPage(
    Future<BrowserExtensionLaunchResult> Function() open,
    String urlFallback,
  ) async {
    final BrowserExtensionLaunchResult r = await open();
    if (!mounted) return;
    if (r.ok) {
      _showSnack('${r.message.split('\n').first} (창이 안 보이면 작업 표시줄 확인)');
      return;
    }
    await Clipboard.setData(ClipboardData(text: urlFallback));
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('브라우저를 자동으로 열지 못함'),
        content: SelectableText('${r.message}\n\n주소창에 붙여넣기:\n$urlFallback'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('닫기'),
          ),
          FilledButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: urlFallback));
              Navigator.pop(ctx);
              _showSnack('주소 복사됨 — Chrome/Edge/Firefox 주소창에 붙여넣기');
            },
            child: const Text('주소 복사'),
          ),
        ],
      ),
    );
  }

  Future<void> _openChromeExtensions() async {
    await _launchBrowserPage(
      BrowserExtensionLauncher.openChromeExtensions,
      'chrome://extensions',
    );
  }

  Future<void> _openEdgeExtensions() async {
    await _launchBrowserPage(
      BrowserExtensionLauncher.openEdgeExtensions,
      'edge://extensions',
    );
  }

  Future<void> _openFirefoxDebugging() async {
    await _launchBrowserPage(
      BrowserExtensionLauncher.openFirefoxDebugging,
      'about:debugging#/runtime/this-firefox',
    );
  }

  Future<void> _runAutoSetup() async {
    if (!Platform.isWindows) {
      _showSnack('Windows에서만 자동 설치를 사용할 수 있습니다.');
      return;
    }
    setState(() => _autoInstalling = true);
    final ValueNotifier<String> statusLine = ValueNotifier<String>('준비 중…');
    if (!mounted) return;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (BuildContext ctx) {
          return ValueListenableBuilder<String>(
            valueListenable: statusLine,
            builder: (BuildContext context, String line, Widget? child) {
              return AlertDialog(
                title: const Text('한 번에 자동 설치'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const LinearProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(line),
                    const SizedBox(height: 8),
                    Text(
                      'UAC 창이 뜨면 **예**를 눌러 주세요.\n'
                      '아니오를 누르면 레지스트리가 비어 「없음」으로 나옵니다.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
    try {
      final ExtensionSetupAutomationResult r =
          await WindowsExtensionSetupAutomation.instance.runFullSetup(
            chromeAssetPaths: _chromeAssets,
            firefoxAssetPaths: _firefoxAssets,
            onStatus: (String s) => statusLine.value = s,
            allowElevated: true,
          );
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      if (!mounted) return;
      if (r.chromePath != null) {
        setState(() {
          _chromePath = r.chromePath;
          if (r.firefoxPath != null) _firefoxPath = r.firefoxPath;
          _step = 1;
        });
        if (r.chromePath != null) {
          await _syncRulesToExtensionStorage(r.chromePath!);
        }
      }
      await _showAutoSetupResult(r);
    } catch (e) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      if (mounted) _showSnack('자동 설치 오류: $e');
    } finally {
      statusLine.dispose();
      if (mounted) setState(() => _autoInstalling = false);
    }
  }

  Future<void> _showAutoSetupResult(ExtensionSetupAutomationResult r) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        icon: Icon(
          r.ok
              ? Icons.check_circle_outline
              : (r.hasUnpackedCopy
                    ? Icons.cleaning_services_outlined
                    : Icons.error_outline),
          color: r.ok ? AppColors.success : AppColors.warning,
          size: 36,
        ),
        title: Text(
          r.ok
              ? '자동 설치 완료'
              : (r.hasUnpackedCopy ? '거의 됐어요 — 복사본만 제거' : '등록 실패 — 아래 확인'),
        ),
        content: SingleChildScrollView(
          child: SelectableText(
            <String>[
              r.message,
              if (r.guardLog != null && r.guardLog!.isNotEmpty)
                '\n[관리자 로그]\n${r.guardLog}',
            ].join(),
          ),
        ),
        actions: <Widget>[
          if (r.hasUnpackedCopy)
            FilledButton(
              onPressed: () {
                Navigator.pop(ctx);
                unawaited(_openChromeExtensions());
              },
              child: const Text('chrome://extensions 열기'),
            ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
  }

  Future<void> _applyExtensionGuard() async {
    final String? path = _chromePath;
    if (path == null || path.isEmpty) {
      _showSnack('먼저 ① Chrome/Edge 폴더 준비를 실행하세요.');
      return;
    }
    setState(() => _applyingGuard = true);
    try {
      await WindowsExtensionGuardService.instance.runElevatedGuard(
        chromeExtensionFolder: path,
      );
      WindowsExtensionSelfHealService.instance.clearCooldown();
      final ExtensionSelfHealResult heal = await WindowsExtensionSelfHealService
          .instance
          .runSelfHeal(
            attemptElevated: true,
            chromeSourceOverride: path,
            userInitiated: true,
          );
      if (!mounted) return;
      await _showGuardResultDialog(heal.message, ok: heal.isAcceptable);
    } finally {
      if (mounted) setState(() => _applyingGuard = false);
    }
  }

  Future<void> _verifyExtensionGuard() async {
    final ExtensionPolicyVerifyResult v =
        await WindowsExtensionGuardService.verifyAllPolicies();
    final FirefoxInstallVerifyResult ff =
        await WindowsFirefoxExtensionInstallService.verify();
    if (!mounted) return;
    await _showGuardResultDialog(
      '${v.detail}\n\n${ff.detail}',
      ok: v.allOk && ff.allOk,
    );
  }

  Future<void> _verifyFirefoxOnly() async {
    final FirefoxInstallVerifyResult v =
        await WindowsFirefoxExtensionInstallService.verify();
    if (!mounted) return;
    await _showGuardResultDialog(v.detail, ok: v.allOk);
  }

  Future<void> _showGuardResultDialog(
    String message, {
    required bool ok,
  }) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        icon: Icon(
          ok ? Icons.verified_user_outlined : Icons.warning_amber_rounded,
          color: ok ? AppColors.success : AppColors.warning,
          size: 32,
        ),
        title: Text(ok ? '관리자 설치 확인됨' : '아직 관리자 설치 아님'),
        content: SingleChildScrollView(child: SelectableText(message)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('닫기'),
          ),
        ],
      ),
    );
  }

  void _copyToClipboard(String text, String label) {
    Clipboard.setData(ClipboardData(text: text));
    _showSnack('$label 복사됨 ✓');
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    showCopyableSnackBar(context, msg);
  }

  void _markDone() {
    setState(() => _step = 2);
    _stepAnim.forward(from: 0);
  }

  // ─── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool isDark = theme.brightness == Brightness.dark;
    final Color cardBg = isDark ? const Color(0xFF272D29) : Colors.white;
    final Color stepActive = isDark
        ? AppColors.accent
        : const Color(0xFF14C7B8);
    final Color stepDone = isDark ? AppColors.success : const Color(0xFF1B9C7E);

    return Scaffold(
      appBar: AppBar(
        title: const Text('검색·이미지·피드 차단 설치'),
        actions: <Widget>[
          IconButton(
            tooltip: '전체 로그 화면',
            icon: const Icon(Icons.article_outlined),
            onPressed: () {
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const LogViewerScreen(),
                ),
              );
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: <Widget>[
          if (_bundledOk == false)
            _warnCard('에셋 오류: flutter clean 후 다시 빌드하세요.', theme),
          Card(
            color: AppColors.accent.withValues(alpha: 0.12),
            child: ListTile(
              leading: const Icon(Icons.video_library_outlined),
              title: const Text('YouTube 채널 목록 (.txt)'),
              subtitle: const Text(
                '채널·영상 URL 목록 가져오기 → 피드·구글 검색에서 숨김 (가이드 포함)',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => const YouTubeFeedBlockScreen(),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),

          _extensionPathsCard(theme, isDark),
          const SizedBox(height: 12),
          if (Platform.isWindows) ...<Widget>[
            _asideManagementCard(theme),
            const SizedBox(height: 12),
            _extensionAvailabilityCard(theme),
            const SizedBox(height: 12),
          ],

          if (Platform.isWindows) ...<Widget>[
            Card(
              margin: EdgeInsets.zero,
              color: AppColors.accent.withValues(alpha: 0.16),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Text(
                      '이 버튼만 누르세요',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: (_autoInstalling || _applyingGuard)
                          ? null
                          : () =>
                                BrowserOneTapService.openWithFeedback(context),
                      icon: const Icon(Icons.shield_outlined, size: 26),
                      label: const Padding(
                        padding: EdgeInsets.symmetric(vertical: 14),
                        child: Text(
                          'Chrome 열기 (차단 켜짐)',
                          style: TextStyle(fontSize: 17),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '쉬운 설치·연결·바로가기는 자동입니다. 아래는 고급용입니다.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppColors.muted,
                        height: 1.35,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('고급 · 수동 설치 (개발자)'),
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: OutlinedButton.icon(
                    onPressed: (_autoInstalling || _applyingGuard)
                        ? null
                        : _runAutoSetup,
                    icon: _autoInstalling
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.auto_fix_high),
                    label: Text(_autoInstalling ? '설치 중…' : 'UAC 포함 전체 자동 설치'),
                  ),
                ),
                BrowserSetupGuidePanel(
                  title: '용어 · 안 되면?',
                  icon: Icons.help_outline,
                  guides: BrowserExtensionSetupGuides.glossary,
                  accent: AppColors.accent,
                ),
              ],
            ),
            const SizedBox(height: 12),
          ],

          // ── 효과 미리보기
          _effectPreviewCard(theme, isDark, cardBg),
          const SizedBox(height: 16),

          // ── 단계 1: 폴더 준비
          _stepCard(
            step: 1,
            title: '폴더 준비 + 규칙 동기화',
            subtitle: '다운로드\\SixVPN_확장 폴더에 복사합니다 (찾기 쉬움).',
            done: _step >= 1,
            active: _step == 0,
            activeColor: stepActive,
            doneColor: stepDone,
            cardBg: cardBg,
            theme: theme,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (_exporting || _syncing)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        LinearProgressIndicator(
                          color: stepActive,
                          backgroundColor: stepActive.withValues(alpha: 0.2),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _syncing ? '규칙 동기화 중…' : '파일 준비 중…',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: AppColors.muted,
                          ),
                        ),
                      ],
                    ),
                  ),
                FilledButton.icon(
                  onPressed: (_exporting || _syncing) ? null : _doSetupChrome,
                  icon: const Icon(Icons.extension_outlined),
                  label: const Text('① Chrome / Edge 용 폴더 준비'),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  style: FilledButton.styleFrom(
                    backgroundColor: stepActive.withValues(alpha: 0.75),
                  ),
                  onPressed: (_exporting || _syncing) ? null : _doSetupFirefox,
                  icon: const Icon(Icons.extension_outlined),
                  label: const Text('① Firefox 용 폴더 준비'),
                ),
                if (_chromePath != null || _firefoxPath != null) ...[
                  const SizedBox(height: 10),
                  if (_chromePath != null)
                    _pathRow('Chrome 폴더:', _chromePath!, theme),
                  if (_firefoxPath != null)
                    _pathRow('Firefox 폴더:', _firefoxPath!, theme),
                ],
              ],
            ),
          ),

          const SizedBox(height: 10),

          // ── 단계 2: 브라우저에서 로드
          _stepCard(
            step: 2,
            title: '브라우저에서 확장 로드',
            subtitle: 'Store가 아닌 Chrome·Edge·Firefox 안에서 설치합니다.',
            done: _step >= 2,
            active: _step == 1,
            activeColor: stepActive,
            doneColor: stepDone,
            cardBg: cardBg,
            theme: theme,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _warnCard(
                  '삭제가 쉬운 이유: 「개발자 모드 → 압축 해제 로드」로 넣었기 때문입니다.\n'
                  '고정 설치 = ① 폴더 준비 → ② UAC만 → ③ 예전 복사본 제거 → Chrome 완전 종료·재실행.\n'
                  '「관리자가 설치」+ 제거 버튼 없음이면 성공입니다.',
                  theme,
                ),
                const SizedBox(height: 10),
                _browserSetupTabBar(theme, stepActive),
                const SizedBox(height: 12),
                if (_browserSetupTab == 0)
                  _buildChromeSetupTab(theme, isDark, stepActive)
                else if (_browserSetupTab == 1)
                  _buildEdgeSetupTab(theme, isDark, stepActive)
                else
                  _buildFirefoxSetupTab(theme, isDark),
                if (Platform.isWindows && _browserSetupTab != 2) ...<Widget>[
                  const SizedBox(height: 12),
                  Card(
                    margin: EdgeInsets.zero,
                    color: AppColors.warning.withValues(alpha: 0.1),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          Text(
                            '② 관리자 설치 (개발자 모드 없음)',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            'UAC 「예」 후 Chrome/Edge **ExtensionInstallForcelist** + '
                            'force_installed + 핀 고정, Firefox force_installed, '
                            '레지스트리 변조 시 **90초마다 자동 복구**.\n'
                            '「압축 해제」 로드는 하지 않아도 됩니다. '
                            '개발자 모드 복사본이 있으면 chrome://extensions 에서 **먼저 제거**.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              height: 1.4,
                              color: AppColors.muted,
                            ),
                          ),
                          const SizedBox(height: 10),
                          FilledButton.icon(
                            onPressed: (_applyingGuard || _chromePath == null)
                                ? null
                                : _applyExtensionGuard,
                            icon: _applyingGuard
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(Icons.shield_outlined),
                            label: Text(
                              _applyingGuard ? '적용 중…' : 'UAC · 관리자 설치 (권장)',
                            ),
                          ),
                          const SizedBox(height: 8),
                          OutlinedButton.icon(
                            onPressed: _verifyExtensionGuard,
                            icon: const Icon(Icons.fact_check_outlined),
                            label: const Text('레지스트리 등록 확인'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 14),
                FilledButton.icon(
                  onPressed: _step >= 1 ? _markDone : null,
                  icon: const Icon(Icons.check_circle_outline),
                  label: const Text('설치 완료! ✓'),
                ),
              ],
            ),
          ),

          const SizedBox(height: 10),

          // ── 단계 3: 완료
          _stepCard(
            step: 3,
            title: '차단 활성화 완료',
            subtitle: '이제 브라우저에서 바로 동작합니다.',
            done: _step >= 2,
            active: _step == 2,
            activeColor: stepActive,
            doneColor: stepDone,
            cardBg: cardBg,
            theme: theme,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                _checkItem(
                  'Google / Bing / DuckDuckGo 검색 결과에서\n키워드·차단 도메인 항목 자동 숨김',
                  theme,
                ),
                _checkItem('구글 이미지 / Bing 이미지 결과 타일 숨김', theme),
                _checkItem('YouTube: 목록에 넣은 채널·영상 카드만 숨김 (전체 X)', theme),
                _checkItem('Google 홈 피드 숨김', theme),
                _checkItem('SafeSearch 강제 (Google·Bing·DDG)', theme),
                const SizedBox(height: 12),
                Text(
                  '차단 단어·사이트를 앱에서 수정하면\n'
                  '①번 버튼을 다시 눌러 재동기화하세요. (탭 F5 새로고침)',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.muted,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 10),
                OutlinedButton.icon(
                  onPressed: () async {
                    setState(() {
                      _step = 0;
                      _chromePath = null;
                      _firefoxPath = null;
                    });
                  },
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('다시 설정'),
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),
          // ── Edge 힌트 (Windows only)
          if (Platform.isWindows)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                'Microsoft Edge는 Chrome 폴더를 그대로 사용합니다. '
                '도메인 전체 차단은 앱 → 진단 → hosts 적용을 함께 쓰세요.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.muted,
                  height: 1.45,
                ),
              ),
            ),
          const SizedBox(height: 16),
          const AppLiveLogPanel(maxHeight: 240),
        ],
      ),
    );
  }

  Widget _browserSetupTabBar(ThemeData theme, Color stepActive) {
    return SegmentedButton<int>(
      segments: const <ButtonSegment<int>>[
        ButtonSegment<int>(
          value: 0,
          label: Text('Chrome'),
          icon: Icon(Icons.language, size: 18),
        ),
        ButtonSegment<int>(
          value: 1,
          label: Text('Edge'),
          icon: Icon(Icons.explore_outlined, size: 18),
        ),
        ButtonSegment<int>(
          value: 2,
          label: Text('Firefox'),
          icon: Icon(Icons.local_fire_department_outlined, size: 18),
        ),
      ],
      selected: <int>{_browserSetupTab},
      onSelectionChanged: (Set<int> v) {
        setState(() => _browserSetupTab = v.first);
      },
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        foregroundColor: WidgetStateProperty.resolveWith<Color?>((
          Set<WidgetState> states,
        ) {
          if (states.contains(WidgetState.selected)) {
            return stepActive;
          }
          return null;
        }),
      ),
    );
  }

  Widget _extensionPathsCard(ThemeData theme, bool isDark) {
    final String chrome =
        _chromePath ?? _expectedChromePath ?? '(① 폴더 준비 후 표시)';
    final String firefox =
        _firefoxPath ?? _expectedFirefoxPath ?? '(① Firefox 준비 후 표시)';
    return Card(
      color: AppColors.accent.withValues(alpha: 0.1),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '확장 파일 위치 (항상 여기)',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w800,
              ),
            ),
            if (_exportRootPreview != null) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                _exportRootPreview!,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontFamily: 'monospace',
                  height: 1.35,
                ),
              ),
            ],
            const SizedBox(height: 10),
            _copyableHintBox(
              label: 'Chrome / Edge — 이 폴더 전체 선택',
              value: chrome,
              theme: theme,
              isDark: isDark,
            ),
            const SizedBox(height: 6),
            _copyableHintBox(
              label: 'Firefox — manifest.json 파일',
              value: firefox == '(① Firefox 준비 후 표시)'
                  ? firefox
                  : p.join(firefox, 'manifest.json'),
              theme: theme,
              isDark: isDark,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChromeSetupTab(ThemeData theme, bool isDark, Color accent) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        FilledButton.icon(
          onPressed: _openChromeExtensions,
          icon: const Icon(Icons.extension, size: 20),
          label: const Text('Chrome 확장 페이지 열기'),
        ),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(
          onPressed: _revealChromeFolder,
          icon: const Icon(Icons.folder_special_outlined, size: 20),
          label: const Text('chrome_blocker 폴더 · manifest.json 표시'),
        ),
        const SizedBox(height: 10),
        _copyableHintBox(
          label: '압축 해제 로드 시 선택할 폴더',
          value: _chromePath ?? _expectedChromePath ?? '(① 폴더 준비 먼저)',
          theme: theme,
          isDark: isDark,
        ),
        const SizedBox(height: 8),
        BrowserSetupGuidePanel(
          title: 'Chrome · 관리자 설치 (권장)',
          icon: Icons.verified_user_outlined,
          guides: BrowserExtensionSetupGuides.chromeAdminOnly,
          accent: accent,
        ),
        const SizedBox(height: 8),
        BrowserSetupGuidePanel(
          title: 'Chrome · 개발자 모드 (테스트만)',
          icon: Icons.build_outlined,
          guides: BrowserExtensionSetupGuides.chromeDevMode,
          accent: AppColors.muted,
        ),
      ],
    );
  }

  Widget _buildEdgeSetupTab(ThemeData theme, bool isDark, Color accent) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        FilledButton.icon(
          onPressed: _openEdgeExtensions,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF0078D4),
          ),
          icon: const Icon(Icons.extension, size: 20),
          label: const Text('Edge 확장 페이지 열기'),
        ),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(
          onPressed: _revealChromeFolder,
          icon: const Icon(Icons.folder_special_outlined, size: 20),
          label: const Text('chrome_blocker 폴더 · manifest.json 표시'),
        ),
        const SizedBox(height: 10),
        _copyableHintBox(
          label: 'Edge도 같은 chrome_blocker 폴더',
          value: _chromePath ?? '① Chrome/Edge 폴더 준비 후 표시',
          theme: theme,
          isDark: isDark,
        ),
        const SizedBox(height: 8),
        BrowserSetupGuidePanel(
          title: 'Edge 설치 단계',
          icon: Icons.explore_outlined,
          guides: BrowserExtensionSetupGuides.edge,
          accent: const Color(0xFF0078D4),
        ),
      ],
    );
  }

  Widget _buildFirefoxSetupTab(ThemeData theme, bool isDark) {
    final String manifestPath = _firefoxPath != null
        ? p.join(_firefoxPath!, 'manifest.json')
        : '① Firefox 폴더 준비 후 표시';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _warnCard(
          '고정 설치 = 상단 「한 번에 자동 설치」 + UAC 예.\n'
          'about:debugging 임시 애드온은 삭제·끄기가 가능합니다.',
          theme,
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _openFirefoxDebugging,
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFFE36426),
          ),
          icon: const Icon(Icons.bug_report_outlined, size: 20),
          label: const Text('Firefox 디버깅 페이지 열기'),
        ),
        const SizedBox(height: 8),
        FilledButton.tonalIcon(
          onPressed: _revealFirefoxFolder,
          icon: const Icon(Icons.description_outlined, size: 20),
          label: const Text('firefox_blocker · manifest.json 표시'),
        ),
        const SizedBox(height: 10),
        _copyableHintBox(
          label: '임시 애드온에서 고를 파일 (폴더 아님)',
          value: _firefoxPath != null
              ? p.join(_firefoxPath!, 'manifest.json')
              : _expectedFirefoxPath != null
              ? p.join(_expectedFirefoxPath!, 'manifest.json')
              : manifestPath,
          theme: theme,
          isDark: isDark,
        ),
        const SizedBox(height: 8),
        BrowserSetupGuidePanel(
          title: 'Firefox 설치 단계',
          icon: Icons.local_fire_department_outlined,
          guides: BrowserExtensionSetupGuides.firefox,
          accent: const Color(0xFFE36426),
        ),
        if (Platform.isWindows) ...<Widget>[
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: (_applyingGuard || _chromePath == null)
                ? null
                : _applyExtensionGuard,
            icon: const Icon(Icons.shield_outlined),
            label: const Text('UAC · Firefox 정책 포함 시스템 고정'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _verifyFirefoxOnly,
            icon: const Icon(Icons.fact_check_outlined),
            label: const Text('Firefox 정책·XPI 확인'),
          ),
        ],
      ],
    );
  }

  // ─── Sub-widgets ──────────────────────────────────────────────────────────

  Widget _effectPreviewCard(ThemeData theme, bool isDark, Color bg) {
    return Card(
      color: bg,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: AppColors.accent.withValues(alpha: 0.35),
          width: 1,
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.auto_awesome, color: AppColors.accent, size: 20),
                const SizedBox(width: 8),
                Text(
                  '설치하면 이런 게 막힙니다',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children:
                  const <String>[
                        '🔍 구글 검색 결과',
                        '🖼 구글 이미지',
                        '📰 구글 홈 피드',
                        '▶️ YouTube 홈 피드',
                        '🔍 Bing 검색·이미지',
                        '🦆 DuckDuckGo 결과',
                        '🔒 SafeSearch 강제',
                      ]
                      .map(
                        (String s) => Chip(
                          label: Text(s, style: const TextStyle(fontSize: 12)),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 0,
                          ),
                        ),
                      )
                      .toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _stepCard({
    required int step,
    required String title,
    required String subtitle,
    required bool done,
    required bool active,
    required Color activeColor,
    required Color doneColor,
    required Color cardBg,
    required ThemeData theme,
    required Widget child,
  }) {
    final Color borderColor = done
        ? doneColor.withValues(alpha: 0.6)
        : active
        ? activeColor.withValues(alpha: 0.5)
        : Colors.transparent;
    final Color numBg = done
        ? doneColor
        : active
        ? activeColor
        : AppColors.muted.withValues(alpha: 0.25);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 280),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: borderColor, width: 1.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                AnimatedContainer(
                  duration: const Duration(milliseconds: 280),
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: numBg,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: done
                        ? const Icon(Icons.check, size: 18, color: Colors.white)
                        : Text(
                            '$step',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppColors.muted,
                          height: 1.3,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (active || done) ...[const SizedBox(height: 14), child],
          ],
        ),
      ),
    );
  }

  Widget _copyableHintBox({
    required String label,
    required String value,
    required ThemeData theme,
    required bool isDark,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1A1F1C) : const Color(0xFFF0F4FF),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: theme.textTheme.labelSmall?.copyWith(
                    color: AppColors.muted,
                  ),
                ),
                const SizedBox(height: 2),
                SelectableText(
                  value,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontFamily: 'monospace',
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: '복사',
            icon: const Icon(Icons.copy_outlined, size: 18),
            onPressed: () => _copyToClipboard(value, label),
          ),
        ],
      ),
    );
  }

  Widget _pathRow(String label, String path, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '$label $path',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.muted,
                fontSize: 11,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: '경로 복사',
            icon: const Icon(Icons.copy_outlined, size: 16),
            onPressed: () => _copyToClipboard(path, label),
          ),
        ],
      ),
    );
  }

  Widget _checkItem(String text, ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.check_circle_outline, size: 18, color: AppColors.success),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
            ),
          ),
        ],
      ),
    );
  }

  Widget _warnCard(String msg, ThemeData theme) {
    return Card(
      color: AppColors.danger.withValues(alpha: 0.12),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Text(
          msg,
          style: theme.textTheme.bodyMedium?.copyWith(height: 1.4),
        ),
      ),
    );
  }
}

final class _ExtensionAvailabilitySnapshot {
  const _ExtensionAvailabilitySnapshot(
    this.browserInstalled,
    this.extensionInstalled,
  );

  final Map<String, bool> browserInstalled;
  final Map<String, bool> extensionInstalled;
}
