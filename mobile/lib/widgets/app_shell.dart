import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../localization/app_i18n.dart';
import '../router/app_router.dart';
import '../services/backup_service.dart';
import '../services/locale_controller.dart';
import '../theme/app_colors.dart';
import 'app_operation_progress_strip.dart';
import 'build_identity_strip.dart';
import 'hosts_apply_fab.dart';
import 'blocking_ecosystem_status_strip.dart';
import 'browser_block_status_banner.dart';
import 'browser_install_safety_banners.dart';
import 'quick_block_dock.dart';
import 'update_top_bar.dart';
import 'windows_sidebar_rebuild_button.dart';
import 'account_actions.dart';

class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.navigationShell});

  final StatefulNavigationShell navigationShell;

  void _onTap(int index) {
    final bool reTap = index == navigationShell.currentIndex;
    if (reTap) {
      final NavigatorState? nav = shellBranchNavigatorKeys[index].currentState;
      while (nav?.canPop() ?? false) {
        nav!.pop();
      }
    }
    navigationShell.goBranch(index, initialLocation: reTap);
  }

  @override
  Widget build(BuildContext context) {
    if (Platform.isWindows) {
      return _WindowsDesktopShell(
        navigationShell: navigationShell,
        onTap: _onTap,
      );
    }
    if (Platform.isMacOS) {
      return _MacShell(navigationShell: navigationShell, onTap: _onTap);
    }
    return _MobileShell(navigationShell: navigationShell, onTap: _onTap);
  }
}

class _MobileShell extends StatelessWidget {
  const _MobileShell({required this.navigationShell, required this.onTap});
  final StatefulNavigationShell navigationShell;
  final void Function(int) onTap;

  @override
  Widget build(BuildContext context) {
    final locale = LocaleController.instance.locale;
    return Scaffold(
      body: Column(
        children: <Widget>[
          const UpdateTopBar(macStyle: false),
          Expanded(
            child: Stack(
              children: <Widget>[
                navigationShell,
                Positioned(
                  top: MediaQuery.of(context).padding.top + 6,
                  right: 10,
                  child: const SafeArea(child: _SyncStatusChip(mac: false)),
                ),
                const HostsApplyFab(bottomInset: 88),
              ],
            ),
          ),
          const AppOperationProgressStrip(desktopStyle: false),
          const BuildIdentityStrip(desktopStyle: false),
        ],
      ),
      bottomNavigationBar: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const QuickBlockDock(macLayout: false),
          NavigationBar(
            selectedIndex: navigationShell.currentIndex,
            onDestinationSelected: onTap,
            destinations: <NavigationDestination>[
              NavigationDestination(
                icon: const Icon(Icons.shield_outlined),
                selectedIcon: const Icon(Icons.shield_moon),
                label: AppI18n.t(locale, 'tab_home'),
              ),
              NavigationDestination(
                icon: const Icon(Icons.schedule_outlined),
                selectedIcon: const Icon(Icons.schedule),
                label: AppI18n.t(locale, 'tab_rules'),
              ),
              NavigationDestination(
                icon: const Icon(Icons.chat_bubble_outline),
                selectedIcon: const Icon(Icons.chat_bubble),
                label: AppI18n.t(locale, 'tab_chat'),
              ),
              NavigationDestination(
                icon: const Icon(Icons.settings_outlined),
                selectedIcon: const Icon(Icons.settings),
                label: AppI18n.t(locale, 'tab_settings'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Windows — 밝은 사이드바 + 읽기 쉬운 본문 (Mac 다크 테마와 분리).
class _WindowsDesktopShell extends StatelessWidget {
  const _WindowsDesktopShell({
    required this.navigationShell,
    required this.onTap,
  });

  final StatefulNavigationShell navigationShell;
  final void Function(int) onTap;

  @override
  Widget build(BuildContext context) {
    final Locale locale = LocaleController.instance.locale;
    return Scaffold(
      backgroundColor: WindowsDesktopColors.background,
      body: Column(
        children: <Widget>[
          const UpdateTopBar(macStyle: false),
          const BlockingEcosystemStatusStrip(),
          const BrowserBlockStatusBanner(),
          const BrowserInstallSafetyBanners(),
          const AccountActions(),
          Expanded(
            child: Row(
              children: <Widget>[
                _WindowsSidebar(
                  currentIndex: navigationShell.currentIndex,
                  onTap: onTap,
                  locale: locale,
                ),
                const VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: WindowsDesktopColors.sidebarBorder,
                ),
                Expanded(
                  child: ColoredBox(
                    color: WindowsDesktopColors.background,
                    child: navigationShell,
                  ),
                ),
              ],
            ),
          ),
          const AppOperationProgressStrip(desktopStyle: true),
          const BuildIdentityStrip(desktopStyle: true),
        ],
      ),
    );
  }
}

class _WindowsSidebar extends StatelessWidget {
  const _WindowsSidebar({
    required this.currentIndex,
    required this.onTap,
    required this.locale,
  });

  final int currentIndex;
  final void Function(int) onTap;
  final Locale locale;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        return Container(
          width: 212,
          decoration: const BoxDecoration(
            color: WindowsDesktopColors.sidebar,
            border: Border(
              right: BorderSide(color: WindowsDesktopColors.sidebarBorder),
            ),
          ),
          child: SingleChildScrollView(
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: constraints.maxHeight),
              child: IntrinsicHeight(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const SizedBox(height: 18),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 4, 18, 16),
                      child: Row(
                        children: <Widget>[
                          Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: AppColors.accent,
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Icon(
                              Icons.shield,
                              color: Colors.white,
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: 10),
                          const Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(
                                  'Focus Fense',
                                  style: TextStyle(
                                    color: WindowsDesktopColors.sidebarInk,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                Text(
                                  'Windows',
                                  style: TextStyle(
                                    color: WindowsDesktopColors.sidebarMuted,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const QuickBlockDock(macLayout: false),
                    _SidebarTile(
                      index: 0,
                      current: currentIndex,
                      icon: Icons.home_outlined,
                      selectedIcon: Icons.home,
                      label: AppI18n.t(locale, 'tab_home'),
                      onTap: onTap,
                      lightShell: true,
                    ),
                    _SidebarTile(
                      index: 1,
                      current: currentIndex,
                      icon: Icons.schedule_outlined,
                      selectedIcon: Icons.schedule,
                      label: AppI18n.t(locale, 'tab_rules'),
                      onTap: onTap,
                      lightShell: true,
                    ),
                    _SidebarTile(
                      index: 2,
                      current: currentIndex,
                      icon: Icons.chat_bubble_outline,
                      selectedIcon: Icons.chat_bubble,
                      label: AppI18n.t(locale, 'tab_chat'),
                      onTap: onTap,
                      lightShell: true,
                    ),
                    _SidebarTile(
                      index: 3,
                      current: currentIndex,
                      icon: Icons.settings_outlined,
                      selectedIcon: Icons.settings,
                      label: AppI18n.t(locale, 'tab_settings'),
                      onTap: onTap,
                      lightShell: true,
                    ),
                    const Spacer(),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Mac shell: left NavigationRail (sidebar) instead of iPhone bottom tabs.
/// Mirrors the Cold Turkey / native macOS pattern — primary nav lives on
/// the left edge so the user never has to drag the mouse downward.
class _MacShell extends StatelessWidget {
  const _MacShell({required this.navigationShell, required this.onTap});
  final StatefulNavigationShell navigationShell;
  final void Function(int) onTap;

  @override
  Widget build(BuildContext context) {
    final locale = LocaleController.instance.locale;
    return Scaffold(
      backgroundColor: MacColors.background,
      body: Column(
        children: <Widget>[
          const UpdateTopBar(macStyle: true),
          const BlockingEcosystemStatusStrip(),
          const BrowserBlockStatusBanner(),
          Expanded(
            child: Row(
              children: <Widget>[
                _MacSidebar(
                  currentIndex: navigationShell.currentIndex,
                  onTap: onTap,
                  locale: locale,
                ),
                const VerticalDivider(
                  width: 1,
                  thickness: 1,
                  color: MacColors.hairline,
                ),
                Expanded(child: navigationShell),
              ],
            ),
          ),
          const AppOperationProgressStrip(desktopStyle: true),
          const BuildIdentityStrip(desktopStyle: true),
        ],
      ),
    );
  }
}

class _MacSidebar extends StatelessWidget {
  const _MacSidebar({
    required this.currentIndex,
    required this.onTap,
    required this.locale,
  });
  final int currentIndex;
  final void Function(int) onTap;
  final Locale locale;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 200,
      decoration: const BoxDecoration(color: MacColors.sidebar),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 6, 18, 18),
            child: Row(
              children: <Widget>[
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: MacColors.primary,
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: const Icon(
                    Icons.shield,
                    color: MacColors.ink,
                    size: 18,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '6 VPN',
                        style: TextStyle(
                          color: MacColors.ink,
                          fontSize: 13,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                        ),
                      ),
                      Text(
                        'BLOCKER',
                        style: TextStyle(
                          color: MacColors.secondary,
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const QuickBlockDock(macLayout: true),
          _SidebarTile(
            index: 0,
            current: currentIndex,
            icon: Icons.dashboard_outlined,
            selectedIcon: Icons.dashboard,
            label: AppI18n.t(locale, 'tab_home'),
            onTap: onTap,
            lightShell: false,
          ),
          _SidebarTile(
            index: 1,
            current: currentIndex,
            icon: Icons.shield_outlined,
            selectedIcon: Icons.shield,
            label: AppI18n.t(locale, 'tab_rules'),
            onTap: onTap,
            lightShell: false,
          ),
          _SidebarTile(
            index: 2,
            current: currentIndex,
            icon: Icons.chat_bubble_outline,
            selectedIcon: Icons.chat_bubble,
            label: AppI18n.t(locale, 'tab_chat'),
            onTap: onTap,
            lightShell: false,
          ),
          _SidebarTile(
            index: 3,
            current: currentIndex,
            icon: Icons.settings_outlined,
            selectedIcon: Icons.settings,
            label: AppI18n.t(locale, 'tab_settings'),
            onTap: onTap,
            lightShell: false,
          ),
          if (Platform.isWindows) ...<Widget>[
            const SizedBox(height: 10),
            const Padding(
              padding: EdgeInsets.fromLTRB(12, 0, 12, 0),
              child: WindowsSidebarRebuildButton(),
            ),
          ],
          const Spacer(),
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 0, 12, 6),
            child: HostsApplyFab(inline: true),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(12, 0, 12, 14),
            child: _SyncStatusChip(mac: true),
          ),
        ],
      ),
    );
  }
}

/// Live backup-sync indicator. Driven by `BackupService.instance.status`.
///
/// Tiny by design — never pops a modal, never blocks input. Color/icon
/// reflect state at a glance:
///   * grey/idle   — waiting for the first edit
///   * amber/queued — debounced write is pending
///   * blue/saving — actively writing the JSON snapshot
///   * green/synced — last write succeeded; shows "N초 전 / N분 전"
///   * red/error  — last write failed; long-press to retry
///
/// Internal 30s ticker refreshes the relative-time label so "방금" decays
/// into "5분 전" without requiring another sync event.
///
/// Tap opens the resolved backup folder in Finder (macOS).
class _SyncStatusChip extends StatefulWidget {
  const _SyncStatusChip({required this.mac});
  final bool mac;

  @override
  State<_SyncStatusChip> createState() => _SyncStatusChipState();
}

class _SyncStatusChipState extends State<_SyncStatusChip> {
  Timer? _relTimer;

  @override
  void initState() {
    super.initState();
    _relTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _relTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool mac = widget.mac;
    return ValueListenableBuilder<BackupStatus>(
      valueListenable: BackupService.instance.status,
      builder: (BuildContext context, BackupStatus s, _) {
        final ({Color tone, IconData icon, String label}) v = _visual(s, mac);
        return InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => BackupService.instance.revealFolder(),
          onLongPress: () {
            BackupService.instance.syncNow();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('자동 저장을 지금 실행합니다…'),
                duration: Duration(seconds: 2),
              ),
            );
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: v.tone.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: v.tone.withValues(alpha: 0.4)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (s.kind == BackupStatusKind.saving)
                  SizedBox(
                    width: 11,
                    height: 11,
                    child: CircularProgressIndicator(
                      strokeWidth: 1.7,
                      valueColor: AlwaysStoppedAnimation<Color>(v.tone),
                    ),
                  )
                else
                  Icon(v.icon, size: 12, color: v.tone),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    v.label,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: v.tone,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  ({Color tone, IconData icon, String label}) _visual(
    BackupStatus s,
    bool mac,
  ) {
    final Color muted = mac ? MacColors.mutedInk : AppColors.muted;
    final Color success = mac ? MacColors.success : AppColors.success;
    final Color warning = mac ? MacColors.warning : AppColors.warning;
    final Color danger = mac ? MacColors.danger : AppColors.danger;
    final Color info = mac ? MacColors.primary : AppColors.accent;

    switch (s.kind) {
      case BackupStatusKind.idle:
        return (tone: muted, icon: Icons.cloud_off, label: '자동 저장 대기');
      case BackupStatusKind.queued:
        return (tone: warning, icon: Icons.schedule, label: '저장 예약…');
      case BackupStatusKind.saving:
        return (tone: info, icon: Icons.cloud_upload, label: '자동 저장 중…');
      case BackupStatusKind.synced:
        final String when = s.when != null ? ' · ${_relative(s.when!)}' : '';
        return (tone: success, icon: Icons.cloud_done, label: '자동 저장 완료$when');
      case BackupStatusKind.error:
        return (
          tone: danger,
          icon: Icons.cloud_off,
          label: '저장 실패 — 길게 눌러 재시도',
        );
    }
  }

  static String _relative(DateTime when) {
    final Duration d = DateTime.now().difference(when);
    if (d.inSeconds < 60) return '방금';
    if (d.inMinutes < 60) return '${d.inMinutes}분 전';
    if (d.inHours < 24) return '${d.inHours}시간 전';
    return '${d.inDays}일 전';
  }
}

class _SidebarTile extends StatelessWidget {
  const _SidebarTile({
    required this.index,
    required this.current,
    required this.icon,
    required this.selectedIcon,
    required this.label,
    required this.onTap,
    required this.lightShell,
  });
  final int index;
  final int current;
  final IconData icon;
  final IconData selectedIcon;
  final String label;
  final void Function(int) onTap;
  final bool lightShell;

  @override
  Widget build(BuildContext context) {
    final bool selected = current == index;
    final Color selBg = lightShell
        ? WindowsDesktopColors.sidebarSelected
        : MacColors.primaryDim.withValues(alpha: 0.55);
    final Color fg = lightShell
        ? (selected ? AppColors.ink : WindowsDesktopColors.sidebarMuted)
        : (selected ? MacColors.secondary : MacColors.ink);
    final Color iconColor = lightShell
        ? (selected ? AppColors.accent : WindowsDesktopColors.sidebarMuted)
        : (selected ? MacColors.secondary : MacColors.mutedInk);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => onTap(index),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: selected ? selBg : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: lightShell && selected
                  ? Border.all(color: AppColors.accent.withValues(alpha: 0.25))
                  : null,
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  selected ? selectedIcon : icon,
                  size: 17,
                  color: iconColor,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: fg,
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
