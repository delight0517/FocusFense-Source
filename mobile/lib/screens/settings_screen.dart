import 'dart:async';
import 'dart:io' show Directory, Platform;
import '../services/usage_ingest_server.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import '../localization/app_i18n.dart';
import '../constants/app_constants.dart';
import '../models/rules_meta.dart';
import '../enforcement/enforcement_controller.dart';
import '../services/build_identity_service.dart';
import '../services/backup_service.dart';
import '../services/locale_controller.dart';
import '../services/local_database.dart';
import '../services/lock_policy_service.dart';
import '../services/lock_schedule_enforcement.dart';
import '../services/mac_autostart_service.dart';
import '../services/autostart_result.dart';
import '../services/windows_desktop_rebuild_service.dart';
import '../services/rebuild_preferences_service.dart';
import '../services/windows_autostart_service.dart';
import '../services/windows_integration_prefs.dart';
import '../services/windows_watchdog_service.dart';
import '../services/windows_os_integration_service.dart';
import '../services/mac_system_block_service.dart';
import '../services/block_sync_service.dart';
import '../services/windows_five_layer_block_service.dart';
import '../services/windows_protection_mode_prefs.dart';
import '../services/windows_hkcu_policy_service.dart';
import '../services/windows_system_block_service.dart';
import '../services/windows_window_title_guard_service.dart';
import '../services/windows_firewall_block_service.dart';
import '../services/windows_extension_guard_service.dart';
import '../services/extension_rules_snapshot_service.dart';
import '../services/quick_block_controller.dart';
import '../services/quick_block_prefs_store.dart';
import '../services/quick_block_service.dart';
import '../services/uninstall_friction_policy_service.dart';
import '../services/rules_export_service.dart';
import '../services/rules_host_resolver.dart';
import '../theme/app_colors.dart';
import '../services/browser_one_tap_service.dart';
import 'unlock_vault_screen.dart';
import 'browser_extensions_screen.dart';
import 'background_components_screen.dart';
import '../widgets/protection_gaps_banner.dart';
import '../widgets/brainwire_sync_settings_card.dart';
import '../widgets/game_daily_budget_card.dart';
import '../widgets/firefox_performance_card.dart';
import '../widgets/settings_disclosure.dart';
import 'youtube_feed_block_screen.dart';
import 'trash_screen.dart';
import 'uninstall_assistant_screen.dart';
import 'usage_limits_screen.dart';
import 'settings_diagnostics_tab.dart';
import 'app_intro_screen.dart';
import 'preset_share_screen.dart';
import 'stats_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabCtrl;
  final RulesExportService _export = RulesExportService();
  final RulesHostResolver _resolver = RulesHostResolver.instance;
  final LocalDatabase _db = LocalDatabase.instance;
  String? _lastPath;
  String? _storagePath;
  String? _error;
  bool _simulationOn = true;
  bool _prefsLoaded = false;
  RulesMeta _rulesMeta = RulesMeta.defaults;
  bool _macBlockActive = false;
  bool _macBusy = false;
  bool _autostartOn = false;
  bool _autostartBusy = false;
  bool _hklmMirrorOn = false;
  bool _hklmMirrorBusy = false;
  bool _watchdogOn = false;
  bool _watchdogBusy = false;
  bool _manualProtectionEnabled = true;
  bool _manualProtectionBusy = false;
  String? _backupFolder;
  bool _scheduleModeOn = false;
  TimeOfDay _scheduleStart = const TimeOfDay(hour: 22, minute: 0);
  TimeOfDay _scheduleEnd = const TimeOfDay(hour: 7, minute: 0);
  int _scheduleDaysMask = kScheduleDaysMaskAll;
  static const List<String> _kScheduleDowShort = <String>[
    '월',
    '화',
    '수',
    '목',
    '금',
    '토',
    '일',
  ];
  final LockPolicyService _lockPolicy = LockPolicyService.instance;
  int _uninstallWaitSec = UninstallFrictionPolicyService.kDefaultWaitSec;
  DateTime? _uninstallDurationLockUntil;
  bool _frictionEnforced = true;
  String? _diagnosticsBuildTag;
  RebuildRootStatus? _rebuildRootStatus;
  final TextEditingController _windowsDevMobileRootCtrl =
      TextEditingController();
  bool _quickDockShowGames = true;
  bool _quickDockShowMedia = true;
  bool _noAutoAgentRebuild = false;
  bool _heavyPostRebuild = false;
  bool _rebuildAutoShower = true;

  @override
  void dispose() {
    _tabCtrl.dispose();
    _windowsDevMobileRootCtrl.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 4, vsync: this);
    _loadPrefsAndPaths();
    unawaited(_loadDiagnosticsBuildTag());
  }

  Future<void> _loadDiagnosticsBuildTag() async {
    try {
      final BuildIdentity id = await BuildIdentityService.instance.current();
      final String label =
          '${id.appName} ${id.version}+${id.buildNumber} · ${id.operatingSystem}';
      if (mounted) setState(() => _diagnosticsBuildTag = label);
    } catch (_) {
      if (mounted) {
        setState(() => _diagnosticsBuildTag = '(빌드 정보를 불러오지 못함)');
      }
    }
  }

  Future<void> _loadPrefsAndPaths() async {
    final bool sim = await _resolver.useLocalSimulation();
    final RulesMeta meta = await _db.rulesMeta();
    final ScheduleConfig cfg = await _lockPolicy.loadSchedule();
    final bool macActive = await MacSystemBlockService.instance.isActive();
    final bool autostartInstalled = Platform.isMacOS
        ? await MacAutostartService.instance.isInstalled()
        : Platform.isWindows
        ? await WindowsAutostartService.instance.isInstalled()
        : false;
    final bool manualAutostartOff =
        Platform.isWindows &&
        await WindowsIntegrationPrefs.instance.isAutostartExplicitlyOff();
    final bool manualProtectionEnabled = await WindowsProtectionModePrefs
        .instance
        .isProtectionEnabled();
    final bool autostart = manualAutostartOff ? false : autostartInstalled;
    final bool watchdog = Platform.isWindows
        ? await WindowsWatchdogService.instance.isInstalled()
        : false;
    final bool hklmMirror = Platform.isWindows
        ? await WindowsAutostartService.instance.isHklmMirrorInstalled()
        : false;
    final String backupFolder = await BackupService.instance.resolvedFolder();
    final int uWait = await UninstallFrictionPolicyService.instance
        .getWaitSeconds();
    final DateTime? uLock = await UninstallFrictionPolicyService.instance
        .editLockUntil();
    final bool uEnf = await UninstallFrictionPolicyService.instance
        .isFrictionEnforced();
    final String? winDevRoot = Platform.isWindows
        ? await WindowsDesktopRebuildService.discoverMobileRoot(persist: true)
        : await WindowsDesktopRebuildPrefs.getMobileRoot();
    final RebuildRootStatus? rebuildSt = Platform.isWindows
        ? await WindowsDesktopRebuildService.status()
        : null;
    final bool qDockGames = await QuickBlockDockPrefs.showGames();
    final bool qDockMedia = await QuickBlockDockPrefs.showMedia();
    final bool noAutoRebuild = await RebuildPreferencesService.instance
        .noAutoAgentRebuild();
    final bool heavyPostRebuild = await RebuildPreferencesService.instance
        .heavyPostRebuildBootstrap();
    final bool rebuildAutoShower = await RebuildPreferencesService.instance
        .rebuildAutoShowerEnabled();
    _windowsDevMobileRootCtrl.text = winDevRoot ?? '';
    setState(() {
      _simulationOn = sim;
      _rulesMeta = meta;
      _scheduleModeOn = cfg.enabled;
      _scheduleStart = TimeOfDay(
        hour: cfg.startMinuteOfDay ~/ 60,
        minute: cfg.startMinuteOfDay % 60,
      );
      _scheduleEnd = TimeOfDay(
        hour: cfg.endMinuteOfDay ~/ 60,
        minute: cfg.endMinuteOfDay % 60,
      );
      _scheduleDaysMask = cfg.daysMask;
      _macBlockActive = macActive;
      _autostartOn = autostart;
      _hklmMirrorOn = hklmMirror;
      _watchdogOn = watchdog;
      _manualProtectionEnabled = manualProtectionEnabled;
      _backupFolder = backupFolder;
      _uninstallWaitSec = uWait;
      _uninstallDurationLockUntil = uLock;
      _frictionEnforced = uEnf;
      _rebuildRootStatus = rebuildSt;
      _quickDockShowGames = qDockGames;
      _quickDockShowMedia = qDockMedia;
      _noAutoAgentRebuild = noAutoRebuild;
      _heavyPostRebuild = heavyPostRebuild;
      _rebuildAutoShower = rebuildAutoShower;
      _prefsLoaded = true;
    });
    await _refreshPaths();
  }

  Future<void> _enableManualWindowsProtection() async {
    if (_manualProtectionBusy || !Platform.isWindows) return;
    setState(() => _manualProtectionBusy = true);
    try {
      await WindowsProtectionModePrefs.instance.setProtectionEnabled(true);
      await UsageIngestServer.instance.start();
      if (mounted) setState(() => _manualProtectionEnabled = true);
      BlockSyncService.instance.enabled = true;
      EnforcementController.instance.enabled = true;
      final MacBlockResult hosts = await BlockSyncService.instance.applyNow();
      final HkcuPolicyResult browserPolicies = await WindowsHkcuPolicyService
          .instance
          .applyNow();
      final FiveLayerStatus layers = await WindowsFiveLayerBlockService.instance
          .syncLayers(reason: 'manual');
      if (!mounted) return;
      setState(() {
        _manualProtectionEnabled = true;
        _manualProtectionBusy = false;
      });
      final bool applied =
          browserPolicies.targets.isNotEmpty || hosts.ok || layers.anyActive;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            applied
                ? '수동 보호를 켰습니다. 브라우저 정책 적용 대상: ${browserPolicies.targets.isEmpty ? '확인 중' : browserPolicies.targets.join(', ')}. 자동 복구는 계속 꺼져 있습니다.'
                : '보호 켜기를 요청했지만 적용 확인에 실패했습니다. 상태 진단을 확인하세요.',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _manualProtectionBusy = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('수동 보호를 켜지 못했습니다: $error')));
    }
  }

  Future<void> _disableManualWindowsProtection() async {
    if (_manualProtectionBusy || !Platform.isWindows) return;
    setState(() => _manualProtectionBusy = true);
    try {
      // Persist the off switch first so watchdogs and timers cannot reapply
      // protection while cleanup is in progress.
      await WindowsProtectionModePrefs.instance.setProtectionEnabled(false);
      BlockSyncService.instance.enabled = false;
      EnforcementController.instance.enabled = false;
      await Future.wait(<Future<bool>>[
        ExtensionRulesSnapshotService.instance.writeToChromePayload(
          force: true,
        ),
        ExtensionRulesSnapshotService.instance.writeToFirefoxPayload(),
      ]);
      // @incident: full-off-extension-lock — stopping hosts/PAC alone leaves
      // forced extensions and their cached rules active after app OFF.
      String? extensionFailure;
      try {
        final result = await WindowsExtensionGuardService.instance
            .disableAllBrowserExtensions();
        if (!result.ok) extensionFailure = result.message;
      } catch (error) {
        extensionFailure = '$error';
      }
      final MacBlockResult cleanup = await WindowsSystemBlockService.instance
          .deactivate();
      await WindowsWindowTitleGuardService.instance.stop();
      await WindowsFirewallBlockService.instance.deactivate();
      if (!mounted) return;
      setState(() {
        _manualProtectionEnabled = false;
        _manualProtectionBusy = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            cleanup.ok && extensionFailure == null
                ? '자동 집행을 중지하고 확장 비활성화·차단 해제 정책을 적용했습니다. 브라우저 반영 여부는 별도 확인이 필요합니다. 저장한 규칙은 유지됩니다.'
                : '보호 중지는 기록했지만 일부 해제가 완료되지 않았습니다. ${extensionFailure ?? ''} ${cleanup.ok ? '' : cleanup.message ?? 'hosts 정리 확인 실패'}',
          ),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _manualProtectionBusy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('보호는 꺼졌지만 일부 정책 정리에 실패했습니다: $error')),
      );
    }
  }

  Future<void> _toggleAutostart(bool turnOn) async {
    setState(() => _autostartBusy = true);
    if (Platform.isWindows) {
      await WindowsIntegrationPrefs.instance.setAutostartExplicitlyOff(!turnOn);
      if (turnOn) {
        await UninstallFrictionPolicyService.instance
            .clearRemovalAuthorization();
      }
    }
    final AutostartResult r = Platform.isMacOS
        ? (turnOn
              ? await MacAutostartService.instance.install()
              : await MacAutostartService.instance.uninstall())
        : Platform.isWindows
        ? (turnOn
              ? await _enableWindowsAutostart()
              : await _disableWindowsAutostart())
        : const AutostartResult(ok: false, message: '지원하지 않는 플랫폼');
    final bool installed = Platform.isMacOS
        ? await MacAutostartService.instance.isInstalled()
        : Platform.isWindows
        ? await WindowsAutostartService.instance.isInstalled()
        : false;
    if (!mounted) return;
    setState(() {
      _autostartBusy = false;
      _autostartOn = installed;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(r.message)));
  }

  Future<AutostartResult> _enableWindowsAutostart() async {
    await WindowsIntegrationPrefs.instance.setAutostartExplicitlyOff(false);
    await UninstallFrictionPolicyService.instance.clearRemovalAuthorization();
    await WindowsOsIntegrationService.ensureOnBoot();
    return const AutostartResult(ok: true, message: '자동 실행과 복구 작업을 다시 켰습니다.');
  }

  Future<AutostartResult> _disableWindowsAutostart() async {
    final AutostartResult user = await WindowsAutostartService.instance
        .disableForManualMode();
    final AutostartResult machine = await WindowsAutostartService.instance
        .uninstallHklmMirror();
    if (!user.ok || !machine.ok) {
      return AutostartResult(
        ok: false,
        message: <String>[user.message, machine.message].join('\n'),
      );
    }
    return user;
  }

  Future<void> _toggleHklmMirror(bool turnOn) async {
    if (!Platform.isWindows) return;
    if (turnOn) {
      final bool confirm =
          await showDialog<bool>(
            context: context,
            builder: (BuildContext ctx) => AlertDialog(
              title: const Text('강화: 모든 사용자 자동 시작'),
              content: const Text(
                '관리자 권한(UAC) 한 번을 받아서 이 PC의 **모든 Windows 계정**에서 '
                'Focus Fense가 로그인 시 자동 실행되도록 합니다.\n\n'
                '• 새 계정을 만들어 우회하는 시도를 막아 줍니다.\n'
                '• 작업 관리자 시작 앱 탭에서 끄려고 해도(HKCU만 보임) HKLM은 살아 있어 자동 시작이 유지됩니다.\n'
                '• 같은 PC에 있는 가족·동거인도 자동으로 앱이 떠요. 괜찮을 때만 켜세요.',
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('취소'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('UAC 받고 등록'),
                ),
              ],
            ),
          ) ??
          false;
      if (!confirm) return;
    }
    setState(() => _hklmMirrorBusy = true);
    final AutostartResult r = turnOn
        ? await WindowsAutostartService.instance.installHklmMirror()
        : await WindowsAutostartService.instance.uninstallHklmMirror();
    final bool on = await WindowsAutostartService.instance
        .isHklmMirrorInstalled();
    if (!mounted) return;
    setState(() {
      _hklmMirrorBusy = false;
      _hklmMirrorOn = on;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(r.message)));
  }

  Future<void> _pickBackupFolder() async {
    String? initial;
    try {
      initial = await BackupService.instance.resolvedFolder();
      if (!await Directory(initial).exists()) {
        initial = null;
      }
    } catch (_) {
      initial = null;
    }
    final String? picked = await FilePicker.getDirectoryPath(
      dialogTitle: '백업 폴더 선택',
      initialDirectory: initial,
    );
    if (picked == null || picked.isEmpty) return;
    await BackupService.instance.setFolder(picked);
    final String resolved = await BackupService.instance.resolvedFolder();
    if (!mounted) return;
    setState(() => _backupFolder = resolved);
  }

  Future<void> _resetBackupFolderToDefault() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('기본 백업 경로'),
        content: const Text(
          '문서 폴더 아래의 기본 백업 위치(예: 문서/6 VPN Blocker Backup)로 되돌립니다.\n'
          '지금 커스텀으로 지정한 경로 설정은 지워집니다.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('기본으로'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await BackupService.instance.useDefaultFolder();
    final String resolved = await BackupService.instance.resolvedFolder();
    if (!mounted) return;
    setState(() => _backupFolder = resolved);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('백업 위치: $resolved')));
  }

  Future<void> _createSubfolderUnderCurrent() async {
    final TextEditingController ctrl = TextEditingController(
      text: 'SixVPN_Backup',
    );
    final String? name = await showDialog<String?>(
      context: context,
      builder: (BuildContext ctx) {
        return AlertDialog(
          title: const Text('현재 경로 안에 하위 폴더'),
          content: TextField(
            controller: ctrl,
            decoration: const InputDecoration(
              labelText: '새 폴더 이름',
              hintText: '예: SixVPN_Backup',
            ),
            autofocus: true,
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () {
                final String t = ctrl.text.trim();
                Navigator.pop(ctx, t.isEmpty ? null : t);
              },
              child: const Text('만들고 사용'),
            ),
          ],
        );
      },
    );
    ctrl.dispose();
    if (name == null || name.isEmpty) return;
    try {
      final String parent = await BackupService.instance.resolvedFolder();
      final String path = await BackupService.instance.createAndUseSubfolder(
        parent: parent,
        childName: name,
      );
      if (!mounted) return;
      setState(() => _backupFolder = path);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('새 백업 폴더: $path')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('폴더 만들기 실패: $e')));
    }
  }

  Future<void> _syncNow() async {
    final BackupRunResult r = await BackupService.instance.syncNow();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(r.ok ? '백업 완료' : '백업 실패: ${r.error ?? ""}')),
    );
  }

  /// Inspect the configured folder for a `current.json` and offer to load
  /// it. Used both for explicit user-driven restores (after reinstall on
  /// a different mac) and to recover from accidental deletes.
  Future<void> _restoreFromBackup() async {
    final RestorePreview? preview = await BackupService.instance
        .previewRestore();
    if (!mounted) return;
    if (preview == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('선택한 폴더에서 백업 파일(current.json) 을 찾지 못했어요.'),
        ),
      );
      return;
    }
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) {
        final DateTime? when = preview.exportedAt;
        return AlertDialog(
          title: const Text('백업에서 복원'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                '⚠️ 현재 앱 데이터는 모두 삭제되고 백업으로 덮어써집니다.',
                style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                  color: AppColors.danger,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Text('백업 시각: ${when?.toLocal().toString() ?? "알 수 없음"}'),
              const SizedBox(height: 6),
              Text('스케줄 ${preview.schedules}개 · 슬롯 ${preview.scheduleSlots}개'),
              Text('사이트 ${preview.domains}개 · 키워드 ${preview.keywords}개'),
              Text('차단 앱 ${preview.blockedApps}개'),
              const SizedBox(height: 10),
              SelectableText(
                preview.sourcePath,
                style: Theme.of(ctx).textTheme.bodySmall?.copyWith(
                  color: AppColors.muted,
                  fontFamily: 'Menlo',
                  fontSize: 11,
                ),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('취소'),
            ),
            FilledButton.icon(
              icon: const Icon(Icons.restore),
              label: const Text('복원'),
              onPressed: () => Navigator.of(ctx).pop(true),
            ),
          ],
        );
      },
    );
    if (ok != true) return;
    final RestoreResult r = await BackupService.instance.restoreNow();
    if (!mounted) return;
    if (r.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '복원 완료 — 스케줄 ${r.counts!.schedules}개, '
            '사이트 ${r.counts!.domains}개, 앱 ${r.counts!.blockedApps}개',
          ),
          duration: const Duration(seconds: 5),
        ),
      );
      setState(() {}); // refresh whatever the screen surfaces from DB
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('복원 실패: ${r.error ?? ""}')));
    }
  }

  Future<void> _macApply() async {
    setState(() => _macBusy = true);
    final MacBlockResult r = await MacSystemBlockService.instance.activate();
    final bool active = await MacSystemBlockService.instance.isActive();
    if (!mounted) return;
    setState(() {
      _macBusy = false;
      _macBlockActive = active;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(_macMessage(r, applied: true))));
  }

  Future<void> _macDeactivate() async {
    setState(() => _macBusy = true);
    final MacBlockResult r = await MacSystemBlockService.instance.deactivate();
    final bool active = await MacSystemBlockService.instance.isActive();
    if (!mounted) return;
    setState(() {
      _macBusy = false;
      _macBlockActive = active;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(_macMessage(r, applied: false))));
  }

  String _macMessage(MacBlockResult r, {required bool applied}) {
    switch (r.status) {
      case MacBlockStatus.success:
        return applied
            ? 'Mac 시스템 차단 적용됨 (Safari/Chrome/Firefox 공통)'
            : 'Mac 시스템 차단 해제됨';
      case MacBlockStatus.cancelled:
        return '관리자 비밀번호 입력이 취소되었습니다.';
      case MacBlockStatus.unsupported:
        return '이 기능은 macOS에서만 동작합니다.';
      case MacBlockStatus.failure:
        return '실패: ${r.message ?? "원인 미상"}';
    }
  }

  Future<void> _persistRulesMeta(RulesMeta meta) async {
    await _db.saveRulesMeta(meta);
    setState(() => _rulesMeta = meta);
  }

  Future<void> _refreshPaths() async {
    try {
      final p = await _export.storagePathForDisplay();
      setState(() {
        _storagePath = p;
        _error = null;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _storagePath = null;
      });
    }
  }

  Future<void> _setSimulation(bool value) async {
    await _resolver.setUseLocalSimulation(value);
    setState(() => _simulationOn = value);
    await _refreshPaths();
  }

  static const List<int> _kCooldownChoices = <int>[15, 30, 60, 120, 300];

  int _cooldownSnap(int seconds) {
    if (_kCooldownChoices.contains(seconds)) return seconds;
    return 60;
  }

  Future<void> _exportRules() async {
    setState(() {
      _error = null;
    });
    try {
      final path = await _export.exportCurrentRules();
      setState(() => _lastPath = path);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(path == null ? '실패' : '저장됨: $path')),
      );
    } catch (e) {
      setState(() => _error = e.toString());
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('오류: $e')));
    }
  }

  Future<void> _pickScheduleTime({required bool pickStart}) async {
    final TimeOfDay initial = pickStart ? _scheduleStart : _scheduleEnd;
    final TimeOfDay? result = await showTimePicker(
      context: context,
      initialTime: initial,
    );
    if (result == null) return;
    setState(() {
      if (pickStart) {
        _scheduleStart = result;
      } else {
        _scheduleEnd = result;
      }
    });
    await _saveSchedule();
  }

  String _fmt(TimeOfDay t) => t.format(context);

  int _toMinuteOfDay(TimeOfDay t) => t.hour * 60 + t.minute;

  Future<void> _saveSchedule() async {
    await _lockPolicy.saveSchedule(
      ScheduleConfig(
        enabled: _scheduleModeOn,
        startMinuteOfDay: _toMinuteOfDay(_scheduleStart),
        endMinuteOfDay: _toMinuteOfDay(_scheduleEnd),
        daysMask: _scheduleDaysMask,
      ),
    );
    await enforceLockScheduleIfNeeded();
  }

  Future<void> _toggleScheduleWeekday(int dayIndex) async {
    if (!_scheduleModeOn || dayIndex < 0 || dayIndex > 6) return;
    final int bit = 1 << dayIndex;
    int next = _scheduleDaysMask & kScheduleDaysMaskAll;
    if ((next & bit) != 0) {
      next &= ~bit;
      if (next == 0) {
        next = bit;
      }
    } else {
      next |= bit;
    }
    setState(() => _scheduleDaysMask = next);
    await _saveSchedule();
  }

  bool get _locked => _lockPolicy.isLockedByPolicy(_rulesMeta);

  Future<void> _refreshUninstallFrictionUi() async {
    final int sec = await UninstallFrictionPolicyService.instance
        .getWaitSeconds();
    final DateTime? until = await UninstallFrictionPolicyService.instance
        .editLockUntil();
    final bool enf = await UninstallFrictionPolicyService.instance
        .isFrictionEnforced();
    if (!mounted) return;
    setState(() {
      _uninstallWaitSec = sec;
      _uninstallDurationLockUntil = until;
      _frictionEnforced = enf;
    });
  }

  String _fmtUninstallPresetLabel(int sec) {
    if (sec < 3600) return '${sec ~/ 60}분';
    if (sec < 86400) return '${sec ~/ 3600}시간';
    return '${sec ~/ 86400}일';
  }

  Future<void> _onPickUninstallWait(int sec) async {
    if (sec == _uninstallWaitSec) return;
    final UninstallWaitChangeResult result =
        await UninstallFrictionPolicyService.instance.trySetWaitSeconds(sec);
    if (!mounted) return;
    if (!result.ok) {
      final DateTime? u = result.blockedUntil ?? _uninstallDurationLockUntil;
      await showDialog<void>(
        context: context,
        builder: (BuildContext ctx) => AlertDialog(
          title: const Text('대기 시간 줄이기 잠금'),
          content: Text(
            u == null
                ? '지금은 대기 시간을 줄일 수 없습니다. 늘리는 것은 언제든 가능합니다.'
                : '대기 시간을 줄이려면 현재 설정한 제거 대기(${_fmtUninstallPresetLabel(_uninstallWaitSec)})만큼 '
                      '먼저 기다려야 합니다.\n\n'
                      '${u.year}-${u.month.toString().padLeft(2, '0')}-${u.day.toString().padLeft(2, '0')} '
                      '${u.hour.toString().padLeft(2, '0')}:${u.minute.toString().padLeft(2, '0')} '
                      '이후에 더 짧은 값을 고를 수 있어요.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('확인'),
            ),
          ],
        ),
      );
      return;
    }
    await _refreshUninstallFrictionUi();
    if (!mounted) return;
    final String tail = result.increased
        ? '늘리기는 즉시 적용됩니다.'
        : '이 값보다 짧게 바꾸려면 같은 시간만큼 다시 기다려야 합니다.';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('제거 도우미 대기: ${_fmtUninstallPresetLabel(sec)} — $tail'),
        duration: const Duration(seconds: 5),
      ),
    );
  }

  /// Steps under "규칙 적용" on the Settings export card — iOS vs Windows.
  String _exportTodoCardBody() {
    if (Platform.isWindows) {
      if (_simulationOn) {
        return '1) 규칙·스케줄에서 단어/사이트 추가\n'
            '2) 위의 규칙 적용 버튼 실행\n'
            '3) 테스트 탭 또는「브라우저 확장」에서 Chrome/Firefox로 확인\n'
            '4) 전체 DNS 차단은 스케줄 화면의 Windows 시스템 차단을 사용';
      }
      return '1) 규칙·스케줄에서 단어/사이트·앱 차단 추가\n'
          '2) 위의 규칙 적용 버튼 실행\n'
          '3)「브라우저 확장」에서 Chrome·Edge·Firefox에 확장 로드\n'
          '4) 스케줄 화면의 Windows 시스템 DNS 차단으로 도메인 전체 차단';
    }
    if (_simulationOn) {
      return '1) 규칙 탭에서 단어/사이트 추가\n'
          '2) 위의 "규칙 적용하기 (시뮬)" 버튼 누르기\n'
          '3) 테스트 탭에서 동작 확인\n'
          '4) 실제 Safari 차단이 필요하면 "실전 Safari 모드"로 전환';
    }
    return '1) Apple Developer에서 App Group 등록\n'
        '2) Xcode에서 Runner + 두 확장에 같은 App Group 연결\n'
        '3) 아이폰 설정 > Safari > 확장에서 Shield 켜기\n'
        '4) 이 화면에서 규칙 적용 후 Safari에서 테스트';
  }

  @override
  Widget build(BuildContext context) {
    final localeCtrl = LocaleController.instance;
    final locale = localeCtrl.locale;
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  AppI18n.t(locale, 'settings_title'),
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '보호를 켜고 차단할 항목을 선택하세요. 세부 설정은 필요할 때 열 수 있습니다.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.muted,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          TabBar(
            controller: _tabCtrl,
            isScrollable: true,
            labelStyle: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
            tabs: const <Tab>[
              Tab(text: '보호'),
              Tab(text: '확인·도움'),
              Tab(text: '고급'),
              Tab(text: '백업·데이터'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabCtrl,
              children: <Widget>[
                ListView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                  children: <Widget>[
                    if (_prefsLoaded && Platform.isWindows)
                      _buildWindowsProtectionCard(context),
                    if (_prefsLoaded && Platform.isWindows)
                      const SizedBox(height: 12),
                    if (Platform.isWindows)
                      ListTile(
                        leading: const Icon(
                          Icons.admin_panel_settings_outlined,
                        ),
                        title: const Text('브라우저 관리'),
                        subtitle: const Text('관리자 설치·복구, Firefox 서명과 암호화 백업'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => context.pushNamed('browser_management'),
                      ),
                    if (_prefsLoaded && Platform.isMacOS)
                      _buildMacBlockCard(context),
                    if (_prefsLoaded) _buildAdultProtectionCard(context),
                    if (Platform.isWindows) GameDailyBudgetCard(locale: locale),
                    if (Platform.isWindows) FirefoxPerformanceCard(locale: locale),
                    const SizedBox(height: 12),
                    ListTile(
                      leading: const Icon(Icons.help_outline),
                      title: const Text('차단이 잘 되는지 확인하기'),
                      subtitle: const Text('사이트 확인과 문제 해결을 한곳에서'),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => _tabCtrl.animateTo(1),
                    ),
                    const SizedBox(height: 12),
                    SettingsDisclosure(
                      title: '언어·사용 환경',
                      subtitle: '표시 언어와 빠른 차단 메뉴',
                      icon: Icons.language,
                      builder: (context) => Column(
                        children: [
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    AppI18n.t(locale, 'language_title'),
                                    style: Theme.of(
                                      context,
                                    ).textTheme.titleSmall,
                                  ),
                                  const SizedBox(height: 6),
                                  Text(
                                    AppI18n.t(locale, 'language_subtitle'),
                                    style: Theme.of(context).textTheme.bodySmall
                                        ?.copyWith(color: AppColors.muted),
                                  ),
                                  const SizedBox(height: 8),
                                  DropdownButton<String>(
                                    isExpanded: true,
                                    value: locale.languageCode,
                                    items: AppI18n.supportedLocales
                                        .map(
                                          (Locale l) =>
                                              DropdownMenuItem<String>(
                                                value: l.languageCode,
                                                child: Text(
                                                  AppI18n.languageName(
                                                    l.languageCode,
                                                  ),
                                                ),
                                              ),
                                        )
                                        .toList(),
                                    onChanged: (String? code) async {
                                      if (code == null) return;
                                      await localeCtrl.setLocaleCode(code);
                                      if (!mounted) return;
                                      setState(() {});
                                    },
                                  ),
                                ],
                              ),
                            ),
                          ),
                          if (_prefsLoaded)
                            _buildQuickBlockDockSettingsCard(context),
                        ],
                      ),
                    ),
                    if (_prefsLoaded)
                      SettingsDisclosure(
                        title: '잠금·앱 삭제 설정',
                        subtitle: 'PIN, 해제 대기 시간과 앱 삭제',
                        icon: Icons.lock_outline,
                        builder: (context) => Column(
                          children: [
                            _buildLockPolicyCard(context),
                            _buildUninstallWaitCard(context),
                            _buildUninstallFrontDoorCard(context),
                          ],
                        ),
                      ),
                  ],
                ),
                SettingsDiagnosticsTab(buildTagLine: _diagnosticsBuildTag),
                ListView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                  children: <Widget>[
                    SettingsDisclosure(
                      title: '추가 도구',
                      subtitle: '프리셋, 브라우저 설치와 백그라운드 항목',
                      builder: (context) => _buildToolboxCard(context),
                    ),
                    const SizedBox(height: 12),
                    if (_prefsLoaded)
                      ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: const Text('시스템 관리'),
                        subtitle: const Text('자동 관리 항목과 세부 제어'),
                        children: <Widget>[
                          if (Platform.isMacOS || Platform.isWindows)
                            _buildAutostartCard(context),
                          if (Platform.isMacOS || Platform.isWindows)
                            const SizedBox(height: 12),
                          if (Platform.isWindows)
                            _buildWindowsWatchdogCard(context),
                          if (Platform.isWindows) const SizedBox(height: 12),
                          if (Platform.isWindows)
                            _buildWindowsCloseHostsCard(context),
                          if (Platform.isWindows) const SizedBox(height: 12),
                          if (Platform.isWindows)
                            _buildWindowsDevRebuildCard(context),
                          if (Platform.isWindows) const SizedBox(height: 12),
                          if (Platform.isWindows)
                            ExpansionTile(
                              tilePadding: EdgeInsets.zero,
                              title: const Text('기기 간 동기화'),
                              subtitle: const Text('연결 및 동기화 세부 설정'),
                              children: const <Widget>[
                                BrainwireSyncSettingsCard(),
                              ],
                            ),
                        ],
                      ),
                  ],
                ),
                ListView(
                  padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                  children: <Widget>[
                    if (_prefsLoaded) _buildBackupCard(context),
                    if (_prefsLoaded) const SizedBox(height: 12),
                    if (_prefsLoaded) _buildTrashEntry(context),
                    if (_prefsLoaded) const SizedBox(height: 12),
                    if (_prefsLoaded && Platform.isIOS)
                      Card(
                        child: Padding(
                          padding: const EdgeInsets.all(14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                AppI18n.t(locale, 'mode_title'),
                                style: Theme.of(context).textTheme.titleSmall,
                              ),
                              const SizedBox(height: 6),
                              Text(
                                _simulationOn
                                    ? AppI18n.t(locale, 'mode_practice_desc')
                                    : AppI18n.t(locale, 'mode_live_desc'),
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(
                                      color: AppColors.muted,
                                      height: 1.35,
                                    ),
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: <Widget>[
                                  Expanded(
                                    child: FilledButton.tonal(
                                      onPressed: _simulationOn
                                          ? null
                                          : () => _setSimulation(true),
                                      child: Text(
                                        AppI18n.t(locale, 'mode_practice'),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: FilledButton(
                                      onPressed: _simulationOn
                                          ? () => _setSimulation(false)
                                          : null,
                                      child: Text(
                                        AppI18n.t(locale, 'mode_live'),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (_prefsLoaded && !Platform.isIOS)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          '백업에는 이 기기에 저장된 목록과 설정이 포함됩니다.',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: AppColors.muted),
                        ),
                      ),
                    if (_prefsLoaded)
                      ExpansionTile(
                        tilePadding: EdgeInsets.zero,
                        title: Text(
                          AppI18n.t(locale, 'advanced_title'),
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        subtitle: Text(
                          AppI18n.t(locale, 'advanced_subtitle'),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: AppColors.muted),
                        ),
                        children: <Widget>[
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  ListTile(
                                    title: Text(
                                      '정책 · 집중 (고급)',
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleSmall,
                                    ),
                                    subtitle: Text(
                                      '엄격도·쿨다운·밤 시간 자동 잠금. PIN은 보호 탭의 잠금·앱 삭제 설정에서 변경할 수 있습니다.',
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodySmall
                                          ?.copyWith(color: AppColors.muted),
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      16,
                                      0,
                                      16,
                                      8,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: <Widget>[
                                        Text(
                                          '엄격도',
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelSmall
                                              ?.copyWith(
                                                color: AppColors.muted,
                                              ),
                                        ),
                                        DropdownButton<String>(
                                          isExpanded: true,
                                          value:
                                              _rulesMeta.strictness == 'strict'
                                              ? 'strict'
                                              : 'standard',
                                          items:
                                              const <DropdownMenuItem<String>>[
                                                DropdownMenuItem(
                                                  value: 'standard',
                                                  child: Text('표준 (standard)'),
                                                ),
                                                DropdownMenuItem(
                                                  value: 'strict',
                                                  child: Text('엄격 (strict)'),
                                                ),
                                              ],
                                          onChanged: (String? v) {
                                            if (v == null) return;
                                            _persistRulesMeta(
                                              _rulesMeta.copyWith(
                                                strictness: v,
                                              ),
                                            );
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      16,
                                      0,
                                      16,
                                      8,
                                    ),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: <Widget>[
                                        Text(
                                          '해제 쿨다운(초)',
                                          style: Theme.of(context)
                                              .textTheme
                                              .labelSmall
                                              ?.copyWith(
                                                color: AppColors.muted,
                                              ),
                                        ),
                                        DropdownButton<int>(
                                          isExpanded: true,
                                          value: _cooldownSnap(
                                            _rulesMeta.unlockCooldownSeconds,
                                          ),
                                          items: const <DropdownMenuItem<int>>[
                                            DropdownMenuItem(
                                              value: 15,
                                              child: Text('15초'),
                                            ),
                                            DropdownMenuItem(
                                              value: 30,
                                              child: Text('30초'),
                                            ),
                                            DropdownMenuItem(
                                              value: 60,
                                              child: Text('1분'),
                                            ),
                                            DropdownMenuItem(
                                              value: 120,
                                              child: Text('2분'),
                                            ),
                                            DropdownMenuItem(
                                              value: 300,
                                              child: Text('5분'),
                                            ),
                                          ],
                                          onChanged: (int? v) {
                                            if (v == null) return;
                                            _persistRulesMeta(
                                              _rulesMeta.copyWith(
                                                unlockCooldownSeconds: v,
                                              ),
                                            );
                                          },
                                        ),
                                      ],
                                    ),
                                  ),
                                  // ── Google SafeSearch + Time Lock ──
                                  Card(
                                    margin: const EdgeInsets.fromLTRB(
                                      12,
                                      4,
                                      12,
                                      8,
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: <Widget>[
                                          SwitchListTile(
                                            contentPadding: EdgeInsets.zero,
                                            title: const Text(
                                              'Google / Bing SafeSearch 강제',
                                            ),
                                            subtitle: const Text(
                                              '검색 엔진이 성인 결과를 숨기도록 DNS + 확장을 통해 강제합니다.',
                                            ),
                                            value: _rulesMeta.forceSafeSearch,
                                            onChanged: (bool v) {
                                              _persistRulesMeta(
                                                _rulesMeta.copyWith(
                                                  forceSafeSearch: v,
                                                ),
                                              );
                                            },
                                          ),
                                          const Divider(),
                                          Text(
                                            'Time Lock — 해제 시도 시 잠금 시간 (분)',
                                            style: Theme.of(context)
                                                .textTheme
                                                .labelSmall
                                                ?.copyWith(
                                                  color: AppColors.muted,
                                                ),
                                          ),
                                          const SizedBox(height: 4),
                                          DropdownButton<int>(
                                            isExpanded: true,
                                            value:
                                                <int>[
                                                  0,
                                                  10,
                                                  15,
                                                  20,
                                                  30,
                                                ].contains(
                                                  _rulesMeta
                                                      .bypassTimeLockMinutes,
                                                )
                                                ? _rulesMeta
                                                      .bypassTimeLockMinutes
                                                : 0,
                                            items:
                                                const <DropdownMenuItem<int>>[
                                                  DropdownMenuItem(
                                                    value: 0,
                                                    child: Text('OFF (잠금 없음)'),
                                                  ),
                                                  DropdownMenuItem(
                                                    value: 10,
                                                    child: Text('10분'),
                                                  ),
                                                  DropdownMenuItem(
                                                    value: 15,
                                                    child: Text('15분'),
                                                  ),
                                                  DropdownMenuItem(
                                                    value: 20,
                                                    child: Text('20분'),
                                                  ),
                                                  DropdownMenuItem(
                                                    value: 30,
                                                    child: Text('30분'),
                                                  ),
                                                ],
                                            onChanged: (int? v) {
                                              if (v == null) return;
                                              _persistRulesMeta(
                                                _rulesMeta.copyWith(
                                                  bypassTimeLockMinutes: v,
                                                ),
                                              );
                                            },
                                          ),
                                          if (_rulesMeta.bypassTimeLockMinutes >
                                              0)
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                top: 4,
                                              ),
                                              child: Text(
                                                '차단된 사이트 우회 시도가 감지되면 ${_rulesMeta.bypassTimeLockMinutes}분 동안 앱 설정·해제를 잠급니다.',
                                                style: Theme.of(context)
                                                    .textTheme
                                                    .bodySmall
                                                    ?.copyWith(
                                                      color: AppColors.muted,
                                                    ),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  Card(
                                    margin: const EdgeInsets.fromLTRB(
                                      12,
                                      4,
                                      12,
                                      8,
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.all(12),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: <Widget>[
                                          SwitchListTile(
                                            contentPadding: EdgeInsets.zero,
                                            title: const Text('스케줄 모드 (베타)'),
                                            subtitle: const Text(
                                              '선택한 요일·시간에 잠금 모드를 자동으로 켭니다. (요일은 아래 칩으로 고릅니다.)',
                                            ),
                                            value: _scheduleModeOn,
                                            onChanged: (bool v) async {
                                              setState(
                                                () => _scheduleModeOn = v,
                                              );
                                              await _saveSchedule();
                                            },
                                          ),
                                          Row(
                                            children: <Widget>[
                                              Expanded(
                                                child: OutlinedButton.icon(
                                                  onPressed: _scheduleModeOn
                                                      ? () => _pickScheduleTime(
                                                          pickStart: true,
                                                        )
                                                      : null,
                                                  icon: const Icon(
                                                    Icons.nightlight_round,
                                                  ),
                                                  label: Text(
                                                    '시작 ${_fmt(_scheduleStart)}',
                                                  ),
                                                ),
                                              ),
                                              const SizedBox(width: 8),
                                              Expanded(
                                                child: OutlinedButton.icon(
                                                  onPressed: _scheduleModeOn
                                                      ? () => _pickScheduleTime(
                                                          pickStart: false,
                                                        )
                                                      : null,
                                                  icon: const Icon(
                                                    Icons.wb_sunny_outlined,
                                                  ),
                                                  label: Text(
                                                    '종료 ${_fmt(_scheduleEnd)}',
                                                  ),
                                                ),
                                              ),
                                            ],
                                          ),
                                          if (_scheduleModeOn) ...<Widget>[
                                            const SizedBox(height: 10),
                                            Text(
                                              '자동 잠금 요일',
                                              style: Theme.of(context)
                                                  .textTheme
                                                  .labelSmall
                                                  ?.copyWith(
                                                    color: AppColors.muted,
                                                  ),
                                            ),
                                            const SizedBox(height: 6),
                                            Wrap(
                                              spacing: 6,
                                              runSpacing: 6,
                                              children: List<Widget>.generate(
                                                7,
                                                (int i) {
                                                  final bool sel =
                                                      (_scheduleDaysMask &
                                                          (1 << i)) !=
                                                      0;
                                                  return FilterChip(
                                                    label: Text(
                                                      _kScheduleDowShort[i],
                                                    ),
                                                    selected: sel,
                                                    showCheckmark: false,
                                                    onSelected: (_) =>
                                                        _toggleScheduleWeekday(
                                                          i,
                                                        ),
                                                  );
                                                },
                                              ),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    if (_prefsLoaded) const SizedBox(height: 12),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              _simulationOn
                                  ? '저장 위치 (시뮬)'
                                  : '저장 위치 (App Group)',
                              style: Theme.of(context).textTheme.titleSmall,
                            ),
                            const SizedBox(height: 6),
                            SelectableText(
                              kAppGroupId,
                              style: const TextStyle(
                                color: AppColors.muted,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              '컨테이너/폴더: ${_storagePath ?? "—"}',
                              style: const TextStyle(
                                color: AppColors.muted,
                                fontSize: 13,
                              ),
                            ),
                            if (_lastPath != null) ...<Widget>[
                              const SizedBox(height: 8),
                              Text(
                                '마지막 rules 파일: $_lastPath',
                                style: const TextStyle(fontSize: 12),
                              ),
                            ],
                            if (_error != null) ...<Widget>[
                              const SizedBox(height: 8),
                              Text(
                                _error!,
                                style: const TextStyle(
                                  color: AppColors.danger,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _exportRules,
                      icon: const Icon(Icons.ios_share),
                      label: Text(
                        _simulationOn
                            ? AppI18n.t(locale, 'apply_rules_sim')
                            : AppI18n.t(locale, 'apply_rules_live'),
                      ),
                    ),
                    const SizedBox(height: 12),
                    OutlinedButton(
                      onPressed: _refreshPaths,
                      child: Text(AppI18n.t(locale, 'refresh_path')),
                    ),
                    const SizedBox(height: 24),
                    Text(
                      Platform.isWindows
                          ? (_simulationOn
                                ? '지금 할 일 (Windows · 시뮬 저장소)'
                                : '지금 할 일 (Windows)')
                          : (_simulationOn
                                ? AppI18n.t(locale, 'todo_title_practice')
                                : AppI18n.t(locale, 'todo_title_live')),
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 8),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Text(
                          _exportTodoCardBody(),
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: AppColors.muted, height: 1.45),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMacBlockCard(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool locked = _lockPolicy.isLockedByPolicy(_rulesMeta);
    final Color statusColor = _macBlockActive
        ? AppColors.success
        : AppColors.muted;
    final String statusText = _macBlockActive
        ? '시스템 차단 ON · Safari / Chrome / Firefox 적용 중'
        : '시스템 차단 OFF · 규칙을 시스템에 적용하지 않음';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.shield_moon_outlined, color: statusColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Mac 전체 차단 (시스템 DNS)',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              statusText,
              style: theme.textTheme.bodySmall?.copyWith(color: statusColor),
            ),
            const SizedBox(height: 6),
            Text(
              '도메인 규칙을 이 Mac의 /etc/hosts 에 기록해서 모든 브라우저와 모든 앱에서 차단됩니다. '
              '활성/해제 시 Mac 관리자 비밀번호를 한 번 묻습니다.\n\n'
              '✓ Safari: 자동 적용\n'
              '✓ Chrome / Firefox: 적용은 되지만 "보안 DNS / Secure DNS" 옵션을 끄거나 "운영 체제 사용"으로 두어야 함\n'
              '✓ Google / Bing 이미지 검색은 강제 SafeSearch (가족 안전 검색)로 우회됨',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.muted,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _macBusy ? null : _macApply,
                    icon: const Icon(Icons.shield_outlined),
                    label: Text(
                      _macBlockActive ? '최신 규칙으로 다시 적용' : 'Mac 전체 차단 활성',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: (_macBusy || locked || !_macBlockActive)
                        ? null
                        : _macDeactivate,
                    icon: const Icon(Icons.lock_open_outlined),
                    label: Text(locked ? '잠금 해제 후 가능' : '차단 해제'),
                  ),
                ),
              ],
            ),
            if (locked)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '⚠ 잠금 모드가 켜져 있어 해제 버튼이 비활성화됩니다. 홈에서 잠금을 끄거나 스케줄 시간이 끝나야 해제할 수 있습니다.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.warning,
                    height: 1.4,
                  ),
                ),
              ),
            if (_macBusy)
              const Padding(
                padding: EdgeInsets.only(top: 10),
                child: LinearProgressIndicator(minHeight: 3),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAdultProtectionCard(BuildContext context) => Card(
    child: SwitchListTile(
      secondary: const Icon(Icons.shield_outlined),
      title: const Text('성인 사이트 차단'),
      subtitle: Text(
        Platform.isWindows && !_manualProtectionEnabled
            ? '선택은 저장됩니다. 위에서 보호를 켜면 적용됩니다.'
            : '내장 목록의 사이트를 차단합니다. 직접 추가한 목록도 유지됩니다.',
      ),
      value: _rulesMeta.adultSitesBlocked,
      onChanged: (enabled) async {
        await _persistRulesMeta(
          _rulesMeta.copyWith(adultSitesBlocked: enabled),
        );
        BlockSyncService.instance.requestApply();
      },
    ),
  );

  Widget _buildWindowsProtectionCard(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color statusColor = _manualProtectionEnabled
        ? AppColors.success
        : AppColors.muted;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.shield_outlined, color: statusColor),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _manualProtectionBusy
                        ? '보호 설정을 적용하는 중…'
                        : _manualProtectionEnabled
                        ? '보호 켜짐'
                        : '보호 꺼짐',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _manualProtectionEnabled
                  ? '보호가 켜져 있습니다. 브라우저별 적용 상태는 확인·도움에서 확인하세요.'
                  : '저장한 차단 목록은 유지됩니다. 보호를 켜면 다시 적용합니다.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.muted,
                height: 1.4,
              ),
            ),
            if (!_manualProtectionEnabled) ...<Widget>[
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _manualProtectionBusy
                    ? null
                    : _enableManualWindowsProtection,
                icon: _manualProtectionBusy
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.play_arrow_rounded),
                label: const Text('보호 켜기'),
              ),
            ] else ...<Widget>[
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _manualProtectionBusy
                    ? null
                    : _disableManualWindowsProtection,
                icon: const Icon(Icons.pause_circle_outline),
                label: const Text('보호 끄기'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildWindowsCloseHostsCard(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.info_outline, color: AppColors.muted),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '창 닫기(X)와 시스템 차단',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '• X 버튼: 창만 숨기고 트레이에 남습니다. 스케줄·앱 차단 타이머는 계속 돕니다.\n'
              '• 완전 종료: 트레이 아이콘에서 종료. 그래도 시스템 hosts에 적어 둔 도메인 차단은(UAC로 한 번 적용했다면) 브라우저가 OS DNS를 쓸 때 남습니다.\n'
              '• Firefox가 안 막히면: DNS over HTTPS 끄기 + 앱에서 지금 적용(UAC) 후 Firefox를 완전히 끄고 다시 실행하세요.\n'
              '• ko. 같은 지역 주소는 example.com만 넣어도 hosts에 더 넓게 깔리도록 확장했습니다. 규칙을 바꾼 뒤 스케줄 또는 진단에서 다시 적용하세요.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.muted,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWindowsDevRebuildCard(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final RebuildRootStatus? st = _rebuildRootStatus;
    final String terminalCmd = st?.mobileRoot != null
        ? 'powershell -NoProfile -ExecutionPolicy Bypass -File "${st!.mobileRoot!.replaceAll('/', '\\')}\\tools\\Rebuild-From-Terminal.ps1"'
        : r'powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\YOURNAME\Desktop\app dev\6VPN_Image_Blocker\mobile\tools\Rebuild-From-Terminal.ps1"';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(
                  Icons.construction_outlined,
                  color: AppColors.accent,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Windows 개발 빌드 (로컬 소스)',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
              ],
            ),
            if (st != null) ...<Widget>[
              const SizedBox(height: 10),
              DecoratedBox(
                decoration: BoxDecoration(
                  color: st.found
                      ? AppColors.success.withValues(alpha: 0.12)
                      : AppColors.danger.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: st.found
                        ? AppColors.success.withValues(alpha: 0.4)
                        : AppColors.danger.withValues(alpha: 0.35),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(10),
                  child: Text(
                    st.message,
                    style: theme.textTheme.bodySmall?.copyWith(height: 1.35),
                  ),
                ),
              ),
            ],
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Cursor/AI 자동 리빌드 끄기'),
              subtitle: Text(
                _noAutoAgentRebuild
                    ? '켜짐 — 코드만 고치고 앱은 자동으로 다시 빌드·재실행하지 않습니다.'
                    : '꺼짐 — AI가 mobile/ 수정 후 Rebuild 스크립트를 실행할 수 있습니다.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.muted,
                  height: 1.35,
                ),
              ),
              value: _noAutoAgentRebuild,
              onChanged: (bool v) async {
                setState(() => _noAutoAgentRebuild = v);
                await RebuildPreferencesService.instance.setNoAutoAgentRebuild(
                  v,
                );
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('리빌드 시 자동 샤워'),
              subtitle: Text(
                _rebuildAutoShower
                    ? '켜짐 — 새 빌드 후 이전 HKCU·PAC·확장 중복을 지우고 규칙을 다시 적용합니다. (스케줄 DB는 유지)'
                    : '꺼짐 — 리빌드 후 기존 차단 레이어를 그대로 둡니다.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.muted,
                  height: 1.35,
                ),
              ),
              value: _rebuildAutoShower,
              onChanged: (bool v) async {
                setState(() => _rebuildAutoShower = v);
                await RebuildPreferencesService.instance
                    .setRebuildAutoShowerEnabled(v);
              },
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('리빌드 후 무거운 자동 점검'),
              subtitle: Text(
                _heavyPostRebuild
                    ? '켜짐 — 새 빌드 후 UAC·브라우저 전체 재설치 점검을 실행합니다.'
                    : '꺼짐(권장) — 규칙·확장 스냅샷만 동기화합니다.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.muted,
                  height: 1.35,
                ),
              ),
              value: _heavyPostRebuild,
              onChanged: (bool v) async {
                setState(() => _heavyPostRebuild = v);
                await RebuildPreferencesService.instance
                    .setHeavyPostRebuildBootstrap(v);
              },
            ),
            const SizedBox(height: 8),
            Text(
              '사이드바「새 버전 받기」는 **숨겨진 외부 PowerShell**에서 '
              'Rebuild-6VPN-Windows.ps1 을 실행하고, 빌드 로그만 앱 화면에 표시합니다. '
              '설치본만 있고 소스가 없으면 자동 탐지가 실패합니다. '
              '빌드 성공 시 경로가 %LOCALAPPDATA%\\SixVPNBlocker\\rebuild_mobile_root.txt 에 저장됩니다.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.muted,
                height: 1.45,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _windowsDevMobileRootCtrl,
              decoration: const InputDecoration(
                labelText: 'mobile 폴더 전체 경로',
                hintText:
                    r'예: C:\Users\me\Desktop\app dev\6VPN_Image_Blocker\mobile',
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.tonalIcon(
                  onPressed: _autoFindWindowsMobileRoot,
                  icon: const Icon(Icons.search, size: 18),
                  label: const Text('소스 자동 찾기'),
                ),
                OutlinedButton.icon(
                  onPressed: _pickWindowsDevMobileRoot,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('폴더 선택'),
                ),
                FilledButton.tonal(
                  onPressed: _saveWindowsDevMobileRoot,
                  child: const Text('경로 저장'),
                ),
                TextButton(
                  onPressed: _clearWindowsDevMobileRoot,
                  child: const Text('저장값 지우기'),
                ),
                OutlinedButton.icon(
                  onPressed: () {
                    Clipboard.setData(ClipboardData(text: terminalCmd));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('터미널 명령을 복사했습니다.')),
                    );
                  },
                  icon: const Icon(Icons.copy_outlined, size: 18),
                  label: const Text('터미널 명령 복사'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            SelectableText(
              terminalCmd,
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                fontSize: 11,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _autoFindWindowsMobileRoot() async {
    final String? root = await WindowsDesktopRebuildService.discoverMobileRoot(
      persist: true,
    );
    final RebuildRootStatus st = await WindowsDesktopRebuildService.status();
    if (!mounted) return;
    setState(() {
      _rebuildRootStatus = st;
      _windowsDevMobileRootCtrl.text = root ?? '';
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          root != null
              ? '찾았습니다: $root'
              : '소스를 찾지 못했습니다. mobile\\tools\\Rebuild-6VPN-Windows.ps1 이 있는 폴더를 직접 지정하세요.',
        ),
      ),
    );
  }

  Future<void> _pickWindowsDevMobileRoot() async {
    final String? dir = await FilePicker.getDirectoryPath(
      dialogTitle: 'mobile 폴더 선택 (pubspec.yaml 이 있는 폴더)',
    );
    if (dir == null) return;
    _windowsDevMobileRootCtrl.text = dir;
    setState(() {});
  }

  Future<void> _saveWindowsDevMobileRoot() async {
    final String t = _windowsDevMobileRootCtrl.text.trim();
    if (t.isNotEmpty &&
        !await WindowsDesktopRebuildService.isValidMobileRoot(t)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            '이 경로에 pubspec.yaml 과 tools\\Rebuild-6VPN-Windows.ps1 이 있어야 합니다.',
          ),
        ),
      );
      return;
    }
    await WindowsDesktopRebuildPrefs.setMobileRoot(t.isEmpty ? null : t);
    if (t.isNotEmpty) {
      await WindowsDesktopRebuildService.writeMarker(t);
    }
    final RebuildRootStatus st = await WindowsDesktopRebuildService.status();
    if (!mounted) return;
    setState(() => _rebuildRootStatus = st);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('저장했어요. 사이드바에서 최신 빌드를 실행할 수 있어요.')),
    );
  }

  Future<void> _clearWindowsDevMobileRoot() async {
    await WindowsDesktopRebuildPrefs.setMobileRoot(null);
    final String? inferred =
        await WindowsDesktopRebuildService.discoverMobileRoot(persist: false);
    final RebuildRootStatus st = await WindowsDesktopRebuildService.status();
    _windowsDevMobileRootCtrl.text = inferred ?? '';
    if (!mounted) return;
    setState(() => _rebuildRootStatus = st);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('저장된 경로를 지웠어요. 실행 파일 위치에서 자동 탐지된 값만 보입니다.')),
    );
  }

  Future<void> _toggleWatchdog(bool turnOn) async {
    setState(() => _watchdogBusy = true);
    final AutostartResult r = turnOn
        ? await WindowsWatchdogService.instance.install()
        : await WindowsWatchdogService.instance.uninstall();
    final bool on = await WindowsWatchdogService.instance.isInstalled();
    if (!mounted) return;
    setState(() {
      _watchdogBusy = false;
      _watchdogOn = on;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(r.message)));
  }

  Widget _buildWindowsWatchdogCard(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool locked = _lockPolicy.isLockedByPolicy(_rulesMeta);
    final Color statusColor = _watchdogOn ? AppColors.success : AppColors.muted;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.timer_outlined, color: statusColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '작업 관리자로 끈 뒤에도 다시 실행 (워치독)',
                    style: theme.textTheme.titleSmall,
                  ),
                ),
                Switch(
                  value: _watchdogOn,
                  onChanged: (_watchdogBusy || (_watchdogOn && locked))
                      ? null
                      : (bool v) => _toggleWatchdog(v),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _watchdogOn
                  ? '✓ 작업 스케줄러 두 개가 30초 stagger로 돌면서 (1분 간격 × 2) 30초 안에 앱을 다시 띄웁니다.\n'
                        '✓ 작업 관리자로 강제 종료해도 곧 복귀합니다(우회 난이도는 올라감).\n'
                        '✓ 완전히 끄려면: 설정에서 이 스위치를 끄거나, 트레이「워치독 끄고 종료」.\n'
                        '✓ 한계: PC 관리자는 작업 스케줄러에서 작업을 삭제할 수 있습니다. '
                        'VPN·DNS·DoH는 라우터·Windows DNS 정책·가족 보호와 함께 쓰는 편이 더 강합니다.'
                  : '꺼짐 — 프로세스를 종료하면 그대로 멈춥니다. '
                        '확장 프로그램 사용량 전송·일부 기능은 앱이 켜져 있을 때만 동작합니다.\n'
                        '※ hosts(DNS) 차단은 보통 파일에 남지만, Chrome 보안 DNS·VPN 우회는 별도 이슈입니다.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.muted,
                height: 1.4,
              ),
            ),
            if (locked && _watchdogOn)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '⚠ 잠금 모드 중에는 워치독을 끌 수 없습니다.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.warning,
                  ),
                ),
              ),
            if (_watchdogBusy)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(minHeight: 3),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildAutostartCard(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool locked = _lockPolicy.isLockedByPolicy(_rulesMeta);
    final bool autostartOffBlocked = locked;
    final Color statusColor = _autostartOn
        ? AppColors.success
        : AppColors.muted;
    final bool mac = Platform.isMacOS;
    final bool win = Platform.isWindows;
    final String title = mac
        ? '항상 켜져 있기 (자동 시작 + 강제 종료 방지)'
        : 'Windows 로그인 시 자동 시작';
    final String onBody = mac
        ? '✓ Mac 로그인 시 자동 시작\n'
              '✓ 강제 종료 시 자동 재실행 (KeepAlive) — Dock에서 창을 닫아도 프로세스가 살아 있을 수 있어요\n'
              '✓ 잠금 모드가 켜져 있으면 이 스위치를 끌 수 없습니다'
        : '✓ Windows 로그인 시 자동 시작(Run 레지스트리) — **기본 켜짐**\n'
              '✓ Store에 깔린 앱이 아니라서, PC 켜고 로그인한 뒤에도 스스로 뜨게 하려면 이 스위치가 필요합니다\n'
              '✓ 잠금 모드가 켜져 있으면 이 스위치를 끌 수 없습니다';
    final String offBody = mac
        ? '꺼짐 — 앱을 끄면 그대로 종료됩니다. 켜면 로그인 시 자동 시작하고, 종료·숨김 후에도 곧 다시 떠서 스케줄·차단이 이어질 수 있습니다.'
        : '꺼짐 — PC를 켠 뒤에도 앱이 **자동으로 뜨지 않습니다**. 데스크톱/시작 메뉴에서 직접 실행해야 합니다.\n'
              '부팅 시 자동 실행이 필요하면 켜 주세요. (`Rebuild-6VPN-Windows.ps1` 끝에서 바로가기도 갱신됩니다.)';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.power_settings_new, color: statusColor),
                const SizedBox(width: 8),
                Expanded(child: Text(title, style: theme.textTheme.titleSmall)),
                Switch(
                  value: _autostartOn,
                  onChanged:
                      (_autostartBusy ||
                              (_autostartOn && autostartOffBlocked)) ||
                          (!mac && !win)
                      ? null
                      : (bool v) => _toggleAutostart(v),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _autostartOn ? onBody : offBody,
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.muted,
                height: 1.4,
              ),
            ),
            if (autostartOffBlocked && _autostartOn)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '⚠ 잠금 모드 중에는 끌 수 없습니다.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.warning,
                  ),
                ),
              ),
            if (_autostartBusy)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(minHeight: 3),
              ),
            if (win && _autostartOn) ...<Widget>[
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Divider(height: 1),
              ),
              Row(
                children: <Widget>[
                  Icon(
                    Icons.admin_panel_settings_outlined,
                    color: _hklmMirrorOn ? AppColors.success : AppColors.muted,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '강화: 이 PC의 모든 계정에서 자동 시작 (HKLM 미러)',
                      style: theme.textTheme.titleSmall,
                    ),
                  ),
                  Switch(
                    value: _hklmMirrorOn,
                    onChanged: (_hklmMirrorBusy || (_hklmMirrorOn && locked))
                        ? null
                        : (bool v) => _toggleHklmMirror(v),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                _hklmMirrorOn
                    ? '✓ HKLM\\…\\Run 에 등록됨 — 새 Windows 계정에서도 자동 시작.\n'
                          '✓ 작업 관리자 시작 앱 토글(HKCU 전용)로 끌 수 없습니다.\n'
                          '※ 같은 PC 다른 사용자도 로그인 시 앱이 떠요.'
                    : '꺼짐 — 켜면 UAC 한 번 받고 HKLM\\…\\Run 에 동일한 자동 시작 항목을 추가합니다.\n'
                          '※ 가족·동거인 계정에서도 앱이 자동으로 뜹니다. 괜찮을 때만 켜세요.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.muted,
                  height: 1.4,
                ),
              ),
              if (_hklmMirrorBusy)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: LinearProgressIndicator(minHeight: 3),
                ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildBackupCard(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                const Icon(Icons.folder_special_outlined),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('자동 백업 폴더', style: theme.textTheme.titleSmall),
                ),
                ValueListenableBuilder<BackupStatus>(
                  valueListenable: BackupService.instance.status,
                  builder:
                      (BuildContext context, BackupStatus s, Widget? child) {
                        return _BackupStatusPill(status: s);
                      },
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '규칙·스케줄·잠금 설정을 추가/변경할 때마다 이 폴더의 current.json 에 자동으로 저장됩니다(짧게 모아서 저장·부담 적음). '
              '앱을 업데이트하거나 삭제 후 다시 설치해도 같은 폴더가 있으면 자동으로 복원돼서 처음부터 다시 셋업할 필요가 없습니다. '
              '매일 한 번 일자별 스냅샷도 따로 남깁니다.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.muted,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFF1F5FB),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: SelectableText(
                      _backupFolder ?? '경로 로드 중…',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppColors.ink,
                        fontFamily: 'Menlo',
                      ),
                    ),
                  ),
                  if (Platform.isMacOS || Platform.isWindows)
                    IconButton(
                      onPressed: () => BackupService.instance.revealFolder(),
                      icon: const Icon(Icons.open_in_new, size: 18),
                      tooltip: Platform.isWindows ? '탐색기에서 열기' : 'Finder에서 열기',
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
            ),
            ValueListenableBuilder<BackupStatus>(
              valueListenable: BackupService.instance.status,
              builder: (BuildContext context, BackupStatus s, Widget? child) {
                if (s.kind == BackupStatusKind.queued ||
                    s.kind == BackupStatusKind.saving) {
                  return Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        minHeight: 3,
                        backgroundColor: AppColors.accent.withValues(
                          alpha: 0.12,
                        ),
                      ),
                    ),
                  );
                }
                return const SizedBox.shrink();
              },
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                FilledButton.tonalIcon(
                  onPressed: _pickBackupFolder,
                  icon: const Icon(Icons.drive_folder_upload_outlined),
                  label: const Text('폴더 변경 / 찾아보기'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _createSubfolderUnderCurrent,
                  icon: const Icon(Icons.create_new_folder_outlined),
                  label: const Text('여기 안에 새 폴더'),
                ),
                OutlinedButton.icon(
                  onPressed: _resetBackupFolderToDefault,
                  icon: const Icon(Icons.restore_page_outlined),
                  label: const Text('기본 문서 경로'),
                ),
                FilledButton.tonalIcon(
                  onPressed: _syncNow,
                  icon: const Icon(Icons.sync),
                  label: const Text('지금 백업'),
                ),
                OutlinedButton.icon(
                  onPressed: _restoreFromBackup,
                  icon: const Icon(Icons.restore),
                  label: const Text('이 폴더에서 복원'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              Platform.isMacOS
                  ? '※ "폴더 변경" 다이얼로그에서 좌측의 새 폴더 아이콘(또는 ⌘N)으로 새 폴더를 만들 수 있어요.'
                  : Platform.isWindows
                  ? '※ "폴더 변경" 창에서 드라이브·폴더를 고른 뒤, 빈 곳 우클릭 → 새로 만들기 → 폴더 로 위치를 만들 수 있어요. 상단 칩이 "저장 중"일 때만 가느다란 진행줄이 잠깐 보입니다.'
                  : '※ 기기의 파일 선택기에서 백업 폴더를 지정하세요.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: AppColors.muted,
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLockPolicyCard(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool locked = _locked;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ListTile(
              leading: Icon(
                locked ? Icons.lock : Icons.lock_open,
                color: locked ? AppColors.warning : AppColors.success,
              ),
              title: const Text('잠금 · 집중'),
              subtitle: Text(
                locked
                    ? '잠금 ON — 차단·Mac 해제·자동 시작 끄기가 막혀 있을 수 있어요.'
                    : '잠금 OFF — 아래 스위치로 집중 모드와 PIN을 바꿀 수 있어요.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.muted,
                ),
              ),
            ),
            SwitchListTile(
              title: const Text('잠금 모드 (집중)'),
              subtitle: const Text('홈 탭 스위치와 같은 값입니다.'),
              value: _rulesMeta.focusEnabled,
              onChanged: (bool v) {
                if (locked && !v) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('잠금 상태에서는 차단을 끌 수 없습니다.')),
                  );
                  return;
                }
                _persistRulesMeta(_rulesMeta.copyWith(focusEnabled: v));
              },
            ),
            SwitchListTile(
              title: const Text('해제 시 PIN 필요'),
              value: _rulesMeta.unlockPinRequired,
              onChanged: (bool v) {
                if (locked && !v) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('잠금 상태에서는 이 설정을 끌 수 없습니다.')),
                  );
                  return;
                }
                _persistRulesMeta(_rulesMeta.copyWith(unlockPinRequired: v));
              },
            ),
            ListTile(
              leading: const Icon(Icons.vpn_key_outlined),
              title: const Text('잠금 코드 (delay & reveal)'),
              subtitle: const Text(
                '직접 정한 코드를 보관 → 대기 후 공개 → 입력하면 짧은 수정 창이 열립니다',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const UnlockVaultScreen(),
                  ),
                );
              },
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                '해제 쿨다운·밤 시간 자동 잠금(스케줄)은 아래 「${AppI18n.t(LocaleController.instance.locale, 'advanced_title')}」을 펼치세요.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.muted,
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUninstallFrontDoorCard(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool locked = _frictionEnforced;
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          width: locked ? 3 : 1,
          color: locked
              ? AppColors.warning
              : theme.dividerColor.withValues(alpha: 0.6),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(
                  locked ? Icons.lock : Icons.lock_open,
                  size: 30,
                  color: locked ? AppColors.warning : AppColors.muted,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '제거 방지: 항상 켜짐',
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '제거 도우미에서 ${_fmtUninstallPresetLabel(_uninstallWaitSec)}'
                        '${_uninstallWaitSec == UninstallFrictionPolicyService.kDefaultWaitSec ? ' (앱 기본 1시간)' : ''}'
                        ' 타이머가 끝나야 확인 코드·제거 안내가 나옵니다. '
                        '긴급·5분·15초 우회는 없습니다.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: AppColors.muted,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  elevation: 0,
                  foregroundColor: theme.colorScheme.onSurface,
                  backgroundColor: theme.colorScheme.surfaceContainerHighest,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(6),
                    side: BorderSide(color: theme.dividerColor),
                  ),
                ),
                onPressed: () {
                  Navigator.of(context).push<void>(
                    MaterialPageRoute<void>(
                      builder: (_) => const UninstallAssistantScreen(),
                    ),
                  );
                },
                child: const Text('앱 제거 안내 / 타이머 화면 열기'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUninstallWaitCard(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final DateTime? until = _uninstallDurationLockUntil;
    final bool shortenLocked = until != null && DateTime.now().isBefore(until);
    final List<int> choices = <int>[];
    final Set<int> seen = <int>{};
    for (final int s in UninstallFrictionPolicyService.kPresetSeconds) {
      if (seen.add(s)) {
        choices.add(s);
      }
    }
    if (seen.add(_uninstallWaitSec)) {
      choices.add(_uninstallWaitSec);
    }
    final int dropdownValue = choices.contains(_uninstallWaitSec)
        ? _uninstallWaitSec
        : choices.first;
    final bool isDefaultWait =
        _uninstallWaitSec == UninstallFrictionPolicyService.kDefaultWaitSec;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: isDefaultWait
                      ? AppColors.accent.withValues(alpha: 0.14)
                      : theme.colorScheme.surfaceContainerHighest.withValues(
                          alpha: 0.55,
                        ),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isDefaultWait
                        ? AppColors.accent.withValues(alpha: 0.45)
                        : theme.dividerColor.withValues(alpha: 0.35),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        Icons.schedule_outlined,
                        color: isDefaultWait
                            ? AppColors.accent
                            : AppColors.muted,
                        size: 22,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '지금 제거 대기: ${_fmtUninstallPresetLabel(_uninstallWaitSec)}'
                          '${isDefaultWait ? ' · 앱 기본(1시간)' : ''}',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.shield_outlined),
              title: const Text('전체 제거 대기 (항상 적용)'),
              subtitle: Text(
                '늘리기는 즉시 가능합니다. 줄이려면 현재 대기 시간만큼 기다린 뒤에만 바꿀 수 있습니다.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.muted,
                  height: 1.35,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.timer_outlined),
              title: const Text('대기 시간 프리셋'),
              subtitle: Text(
                shortenLocked
                    ? '늘리기는 지금도 가능합니다. 줄이기는 '
                          '${until.year}-${until.month.toString().padLeft(2, '0')}-${until.day.toString().padLeft(2, '0')} '
                          '${until.hour.toString().padLeft(2, '0')}:${until.minute.toString().padLeft(2, '0')} 이후에만 됩니다.'
                    : '늘리기는 언제든 가능합니다. 줄이려면 현재 대기 시간만큼 기다린 뒤에만 바꿀 수 있어요.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.muted,
                  height: 1.35,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: DropdownButton<int>(
                isExpanded: true,
                value: dropdownValue,
                items: choices
                    .map(
                      (int s) => DropdownMenuItem<int>(
                        value: s,
                        child: Text(_fmtUninstallPresetLabel(s)),
                      ),
                    )
                    .toList(),
                onChanged: (int? v) {
                  if (v == null) return;
                  _onPickUninstallWait(v);
                },
              ),
            ),
            if (Platform.isWindows)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                child: Text(
                  '앱을 다시 빌드·설치하려면 왼쪽 사이드바의 Windows 재빌드(또는 '
                  '프로젝트의 Rebuild-6VPN-Windows.ps1)를 사용하면 됩니다.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: AppColors.muted,
                    height: 1.35,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _setQuickDockShowGames(bool v) async {
    await QuickBlockDockPrefs.setShowGames(v);
    if (!mounted) return;
    setState(() => _quickDockShowGames = v);
    QuickBlockController.instance.bump();
  }

  Future<void> _setQuickDockShowMedia(bool v) async {
    await QuickBlockDockPrefs.setShowMedia(v);
    if (!mounted) return;
    setState(() => _quickDockShowMedia = v);
    QuickBlockController.instance.bump();
  }

  Widget _buildQuickBlockDockSettingsCard(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            ListTile(
              leading: const Icon(Icons.bolt_outlined),
              title: const Text('퀵 블록 도크'),
              subtitle: Text(
                '홈 탭 아래(모바일) 또는 왼쪽 사이드바 홈 바로 위에서 한 번에 여러 사이트를 전역 차단합니다. '
                '스케줄 목록과는 무관합니다.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.muted,
                  height: 1.35,
                ),
              ),
            ),
            SwitchListTile(
              title: Text('「${QuickBlockCatalog.games.label}」 버튼 표시'),
              value: _quickDockShowGames,
              onChanged: (bool v) {
                unawaited(_setQuickDockShowGames(v));
              },
            ),
            ListTile(
              dense: true,
              title: Text('「${QuickBlockCatalog.games.label}」 사이트 편집'),
              trailing: const Icon(Icons.edit_outlined, size: 20),
              onTap: () => context.push('/settings/quick-block/catalog/games'),
            ),
            SwitchListTile(
              title: Text('「${QuickBlockCatalog.media.label}」 버튼 표시'),
              value: _quickDockShowMedia,
              onChanged: (bool v) {
                unawaited(_setQuickDockShowMedia(v));
              },
            ),
            ListTile(
              dense: true,
              title: Text('「${QuickBlockCatalog.media.label}」 사이트 편집'),
              trailing: const Icon(Icons.edit_outlined, size: 20),
              onTap: () => context.push('/settings/quick-block/catalog/media'),
            ),
            ListTile(
              leading: const Icon(Icons.tune),
              title: const Text('퀵 블록 · 시간·프리셋·내 블록'),
              subtitle: Text(
                '사이트·앱 직접 추가, 기본 ${QuickBlockPrefsStore.kDefaultDurationHours}시간 차단 등',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: AppColors.muted,
                ),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/settings/quick-block'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToolboxCard(BuildContext context) {
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ListTile(
            leading: const Icon(
              Icons.menu_book_outlined,
              color: AppColors.accent,
            ),
            title: const Text('앱 자기소개 · 사용법'),
            subtitle: Text(
              '핵심 기능, 작동 원리(A/B/C), 처음 쓰는 순서를 큰 글로 안내',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(builder: (_) => const AppIntroScreen()),
              );
            },
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.analytics_outlined),
            title: const Text('사이트 이용 시간 제한'),
            subtitle: Text(
              Platform.isWindows
                  ? '하루·구간·세션 — 초과 시 hosts 잠금. 확장으로 웹 시간 측정.'
                  : Platform.isMacOS
                  ? '전면 앱·웹 호스트. 하루/구간/세션 타이머.'
                  : 'Windows·macOS에서 측정·차단합니다.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const UsageLimitsScreen(),
                ),
              );
            },
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(
              Icons.ios_share_outlined,
              color: AppColors.accent,
            ),
            title: const Text('나만의 프리셋 공유'),
            subtitle: Text(
              '스케줄·퀵블록을 파일/코드로 내보내 친구에게 공유, 또는 가져오기',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const PresetShareScreen(),
                ),
              );
            },
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(
              Icons.science_outlined,
              color: AppColors.accent,
            ),
            title: const Text('테스트'),
            subtitle: Text(
              '차단이 실제로 걸려있는지 사이트·검색어로 직접 확인',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(builder: (_) => const StatsScreen()),
              );
            },
          ),
          const Divider(height: 1),
          ListTile(
            leading: const Icon(
              Icons.video_library_outlined,
              color: AppColors.accent,
            ),
            title: const Text('YouTube 목록 (.txt 가져오기)'),
            subtitle: Text(
              '.txt 목록 가져오기 · 구글 검색·유튜브 피드에서 숨김 (브라우저 확장 필요)',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
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
          const Divider(height: 1),
          if (Platform.isWindows || Platform.isMacOS)
            ListTile(
              leading: const Icon(Icons.health_and_safety_outlined),
              title: const Text('보호 커버리지 점검'),
              subtitle: Text(
                '키워드·유튜브·Firefox 확장 등 아직 작동하지 않는 항목 확인',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showProtectionCoverageSheet(context),
            ),
          if (Platform.isWindows || Platform.isMacOS) const Divider(height: 1),
          if (Platform.isWindows)
            ListTile(
              leading: const Icon(Icons.open_in_browser),
              title: const Text('Chrome 열기 (차단 켜짐)'),
              subtitle: Text(
                '버튼 한 번 — 준비·설치·실행을 앱이 처리합니다',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
              ),
              trailing: const Icon(Icons.play_arrow),
              onTap: () => BrowserOneTapService.openWithFeedback(context),
            ),
          if (Platform.isWindows) const Divider(height: 1),
          if (Platform.isWindows)
            ExpansionTile(
              leading: const Icon(Icons.tune),
              title: const Text('브라우저 고급'),
              subtitle: Text(
                '수동 폴더·UAC (일반 사용자는 위 버튼만)',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
              ),
              children: <Widget>[
                ListTile(
                  title: const Text('수동 설치 화면'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                        builder: (_) => const BrowserExtensionsScreen(),
                      ),
                    );
                  },
                ),
              ],
            ),
          if (Platform.isWindows) const Divider(height: 1),
          if (!Platform.isWindows)
            ListTile(
              leading: const Icon(Icons.extension_outlined),
              title: const Text('브라우저 확장'),
              subtitle: Text(
                'Chrome / Firefox 폴더 내보내기 · 피드 숨김·SafeSearch는 확장 설정에서',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => const BrowserExtensionsScreen(),
                  ),
                );
              },
            ),
          if (!Platform.isWindows) const Divider(height: 1),
          if (Platform.isWindows)
            ListTile(
              leading: const Icon(Icons.shield_outlined),
              title: const Text('백그라운드 항목 안내'),
              subtitle: Text(
                'PowerShell 창·예약 작업이 뭔지 확인하고 옛 항목을 정리합니다.',
                style: Theme.of(
                  context,
                ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => const BackgroundComponentsScreen(),
                  ),
                );
              },
            ),
          if (Platform.isWindows) const Divider(height: 1),
          ListTile(
            leading: const Icon(Icons.delete_forever_outlined),
            title: const Text('제거 도우미 (타이머·코드)'),
            subtitle: Text(
              '설정 상단의「앱 제거 안내」와 같은 화면입니다.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () {
              Navigator.of(context).push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const UninstallAssistantScreen(),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildTrashEntry(BuildContext context) {
    return Card(
      child: ListTile(
        leading: const Icon(Icons.delete_sweep_outlined),
        title: const Text('휴지통 (30일 보관)'),
        subtitle: Text(
          '삭제한 사이트·키워드는 30일 동안 복원 가능합니다.',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: AppColors.muted),
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          Navigator.of(context).push<void>(
            MaterialPageRoute<void>(builder: (_) => const TrashScreen()),
          );
        },
      ),
    );
  }
}

class _BackupStatusPill extends StatelessWidget {
  const _BackupStatusPill({required this.status});
  final BackupStatus status;

  @override
  Widget build(BuildContext context) {
    late Color color;
    late String text;
    late IconData icon;
    switch (status.kind) {
      case BackupStatusKind.idle:
        color = AppColors.muted;
        text = '대기';
        icon = Icons.circle_outlined;
        break;
      case BackupStatusKind.queued:
        color = AppColors.warning;
        text = '대기 중';
        icon = Icons.schedule;
        break;
      case BackupStatusKind.saving:
        color = AppColors.warning;
        text = '저장 중…';
        icon = Icons.sync;
        break;
      case BackupStatusKind.synced:
        color = AppColors.success;
        final DateTime? w = status.when;
        text = w == null
            ? '동기화 완료'
            : '저장됨 ${w.hour.toString().padLeft(2, '0')}:${w.minute.toString().padLeft(2, '0')}';
        icon = Icons.check_circle;
        break;
      case BackupStatusKind.error:
        color = AppColors.danger;
        text = '에러';
        icon = Icons.error_outline;
        break;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
