import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import '../services/safe_external_link_service.dart';

import '../services/browser_install_safety_service.dart';
import '../services/new_browser_install_notifier.dart';
import '../services/windows_default_apps_launcher.dart';
import '../theme/app_colors.dart';

/// 상단 스트립 아래 — 새 브라우저 감지 / 전면 차단 안전망.
class BrowserInstallSafetyBanners extends StatefulWidget {
  const BrowserInstallSafetyBanners({super.key});

  @override
  State<BrowserInstallSafetyBanners> createState() =>
      _BrowserInstallSafetyBannersState();
}

class _BrowserInstallSafetyBannersState extends State<BrowserInstallSafetyBanners> {
  NewBrowserInstallEvent? _novel;
  BrowserLockdownSnapshot? _lockdown;
  Duration? _graceLeft;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    NewBrowserInstallNotifier.instance.addListener(_onNovel);
    _novel = NewBrowserInstallNotifier.instance.latest;
    _refreshLockdown();
    _tick = Timer.periodic(const Duration(seconds: 15), (_) => _refreshLockdown());
  }

  @override
  void dispose() {
    NewBrowserInstallNotifier.instance.removeListener(_onNovel);
    _tick?.cancel();
    super.dispose();
  }

  void _onNovel() {
    if (!mounted) return;
    setState(() => _novel = NewBrowserInstallNotifier.instance.latest);
  }

  Future<void> _refreshLockdown() async {
    _lockdown = BrowserInstallSafetyService.instance.lockdown;
    await _refreshGrace();
    if (mounted) setState(() {});
  }

  Future<void> _refreshGrace() async {
    final Duration? left =
        await BrowserInstallSafetyService.instance.remainingGrace();
    if (!mounted) return;
    setState(() => _graceLeft = left);
  }

  Future<void> _allowInstall() async {
    await BrowserInstallSafetyService.instance.beginUserInstallGrace();
    await _refreshGrace();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('45분간 브라우저 강제 종료를 멈췄습니다. 설치·다운로드 후 원탭 적용하세요.'),
        duration: Duration(seconds: 5),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) return const SizedBox.shrink();

    final List<Widget> children = <Widget>[];

    final NewBrowserInstallEvent? novel = _novel;
    if (novel != null && novel.isActive) {
      children.add(_NovelBrowserBanner(event: novel));
    } else if (novel != null &&
        novel.phase == NewBrowserInstallPhase.done) {
      children.add(_NovelDoneBanner(
        event: novel,
        onDismiss: () {
          NewBrowserInstallNotifier.instance.clearIfDone();
          setState(() => _novel = null);
        },
      ));
    }

    final BrowserLockdownSnapshot? lock = _lockdown;
    if (lock != null) {
      children.add(_LockdownBanner(
        snapshot: lock,
        graceLeft: _graceLeft,
        onAllowInstall: _allowInstall,
      ));
    } else if (_graceLeft != null) {
      children.add(_GraceActiveBanner(remaining: _graceLeft!));
    }

    if (children.isEmpty) return const SizedBox.shrink();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }
}

class _NovelBrowserBanner extends StatelessWidget {
  const _NovelBrowserBanner({required this.event});

  final NewBrowserInstallEvent event;

  @override
  Widget build(BuildContext context) {
    final bool applying = event.phase == NewBrowserInstallPhase.applying;
    return Material(
      color: Colors.indigo.shade50,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (applying)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.indigo.shade700,
                  ),
                ),
              )
            else
              Icon(Icons.downloading, color: Colors.indigo.shade700),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                event.messageKo,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                  color: Colors.indigo.shade900,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NovelDoneBanner extends StatelessWidget {
  const _NovelDoneBanner({
    required this.event,
    required this.onDismiss,
  });

  final NewBrowserInstallEvent event;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.green.shade50,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: <Widget>[
            Icon(Icons.check_circle, color: Colors.green.shade800, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                event.messageKo,
                style: TextStyle(
                  fontSize: 12.5,
                  color: Colors.green.shade900,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TextButton(onPressed: onDismiss, child: const Text('닫기')),
          ],
        ),
      ),
    );
  }
}

class _LockdownBanner extends StatelessWidget {
  const _LockdownBanner({
    required this.snapshot,
    required this.graceLeft,
    required this.onAllowInstall,
  });

  final BrowserLockdownSnapshot snapshot;
  final Duration? graceLeft;
  final VoidCallback onAllowInstall;

  @override
  Widget build(BuildContext context) {
    final String graceLabel = graceLeft != null
        ? ' · 남은 보호 ${graceLeft!.inMinutes}분'
        : '';
    return Material(
      color: Colors.orange.shade50,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Icon(Icons.warning_amber_rounded,
                    color: Colors.orange.shade900, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '모든 브라우저가 차단 상태$graceLabel',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      color: Colors.orange.shade900,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              snapshot.messageKo,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.4,
                color: Colors.orange.shade900,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: <Widget>[
                FilledButton.tonalIcon(
                  onPressed: onAllowInstall,
                  icon: const Icon(Icons.install_desktop, size: 18),
                  label: const Text('브라우저 설치 허용 (45분)'),
                ),
                OutlinedButton.icon(
                  onPressed: () =>
                      WindowsDefaultAppsLauncher.openDefaultAppsSettings(),
                  icon: const Icon(Icons.home_outlined, size: 18),
                  label: const Text('기본 브라우저 설정'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _GraceActiveBanner extends StatelessWidget {
  const _GraceActiveBanner({required this.remaining});

  final Duration remaining;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.accent.withValues(alpha: 0.1),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Row(
          children: <Widget>[
            const Icon(Icons.timer_outlined, color: AppColors.accent, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '브라우저 설치·다운로드 허용 중 — '
                '강제 종료 멈춤 (약 ${remaining.inMinutes}분 남음)',
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: AppColors.ink,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 홈·현황판용 — 기본 브라우저 + 설치 허용 버튼 묶음.
class BrowserSafetyActionRow extends StatelessWidget {
  const BrowserSafetyActionRow({super.key});

  @override
  Widget build(BuildContext context) {
    if (!Platform.isWindows) return const SizedBox.shrink();

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        OutlinedButton.icon(
          onPressed: () =>
              WindowsDefaultAppsLauncher.openDefaultAppsSettings(),
          icon: const Icon(Icons.home_outlined, size: 18),
          label: const Text('Windows 기본 브라우저 설정'),
        ),
        FilledButton.tonalIcon(
          onPressed: () async {
            await BrowserInstallSafetyService.instance.beginUserInstallGrace();
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  '45분간 브라우저 강제 종료를 멈췄습니다. '
                  '새 브라우저를 설치한 뒤 자동으로 플러그인이 적용됩니다.',
                ),
                duration: Duration(seconds: 6),
              ),
            );
          },
          icon: const Icon(Icons.install_desktop, size: 18),
          label: const Text('브라우저 설치 허용 (45분)'),
        ),
      ],
    );
  }
}

/// 미설치 브라우저 카드용 — 설치 페이지 자동 열기.
Future<void> openBrowserInstallPage(String browserId) async {
  final String? url = BrowserInstallSafetyService.installUrlFor(browserId);
  if (url == null) return;
  final Uri? uri = Uri.tryParse(url);
  if (uri == null) return;
  await SafeExternalLinkService.instance.open(uri);
}
