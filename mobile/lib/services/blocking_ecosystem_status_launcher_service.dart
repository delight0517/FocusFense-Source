import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../router/app_router.dart';
import '../widgets/blocking_ecosystem_status_screen.dart';
import 'app_logger.dart';
import 'build_identity_service.dart';

/// 첫 실행·업데이트 직후 **홈(사이드바 유지)** 으로 보내고, 현황은 선택적으로 안내합니다.
final class BlockingEcosystemStatusLauncherService {
  BlockingEcosystemStatusLauncherService._();
  static final BlockingEcosystemStatusLauncherService instance =
      BlockingEcosystemStatusLauncherService._();

  /// v1 keys kept for migration only — do not gate on build number (+N).
  static const String _kIntroSeenKey = 'ecosystem_status_intro_seen_v1';
  static const String _kIntroBuildKey = 'ecosystem_status_intro_build_v1';
  /// User tapped 확인/나중에 — never show mandatory intro again until reset.
  static const String _kIntroDismissedKey = 'ecosystem_status_intro_dismissed_v2';

  bool _attemptedThisSession = false;

  Future<bool> isIntroDismissed() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_kIntroDismissedKey) ?? false) return true;
    // Migrate v1 users who already tapped 확인 on a prior build.
    if (prefs.getBool(_kIntroSeenKey) ?? false) {
      await prefs.setBool(_kIntroDismissedKey, true);
      return true;
    }
    return false;
  }

  /// Call when user leaves mandatory intro (확인 or 나중에).
  Future<void> markIntroDismissed() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kIntroDismissedKey, true);
    final BuildIdentity build = await BuildIdentityService.instance.current();
    await prefs.setBool(_kIntroSeenKey, true);
    await prefs.setString(_kIntroBuildKey, build.buildNumber.trim());
    AppLogger.instance.info('ecosystem_status: intro dismissed (persistent)');
  }

  /// [force] — 디버그·설정에서만 재표시.
  Future<void> maybeShowIntro({bool force = false}) async {
    if (_attemptedThisSession && !force) return;
    if (!Platform.isWindows && !Platform.isMacOS) return;

    if (!force && await isIntroDismissed()) {
      _attemptedThisSession = true;
      return;
    }

    _attemptedThisSession = true;

    await Future<void>.delayed(const Duration(milliseconds: 900));

    for (int i = 0; i < 40; i++) {
      final BuildContext? ctx = appRootNavigatorKey.currentContext;
      if (ctx != null && ctx.mounted) {
        GoRouter.of(ctx).go('/focus');
        await Future<void>.delayed(const Duration(milliseconds: 350));
        if (!ctx.mounted) return;
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(
            content: const Text(
              '홈에서 차단 목록·퀵 블록을 관리할 수 있어요. '
              '브라우저별 상태는 상단 스트립 또는 「브라우저 차단 현황」에서 확인하세요.',
            ),
            duration: const Duration(seconds: 9),
            action: SnackBarAction(
              label: '현황 보기',
              onPressed: () {
                if (!ctx.mounted) return;
                unawaited(openBlockingEcosystemStatusScreen(ctx));
              },
            ),
          ),
        );
        if (force) {
          await Future<void>.delayed(const Duration(milliseconds: 200));
          if (ctx.mounted) {
            await openBlockingEcosystemStatusScreen(
              ctx,
              mandatoryIntro: true,
            );
          }
        } else {
          await markIntroDismissed();
        }
        AppLogger.instance.info('ecosystem_status: home-first intro shown');
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    AppLogger.instance.warn('ecosystem_status: intro skipped — no navigator');
  }

  /// 설정·디버그용 — 다음 부팅에 다시 강제 표시.
  Future<void> resetIntroFlag() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kIntroDismissedKey);
    await prefs.remove(_kIntroSeenKey);
    await prefs.remove(_kIntroBuildKey);
    _attemptedThisSession = false;
  }
}
