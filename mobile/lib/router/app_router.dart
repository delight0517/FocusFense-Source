import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../screens/focus_home_screen.dart';
import '../widgets/blocking_ecosystem_status_screen.dart';
import '../screens/rules_screen.dart';
import '../screens/schedules_screen.dart';
import '../screens/quick_block_catalog_edit_screen.dart';
import '../screens/quick_block_settings_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/browser_protection_center_screen.dart';
import '../services/schedule_change_bus.dart';
import '../widgets/app_shell.dart';
import '../widgets/chat_schedule_panel.dart';

/// Root navigator for dialogs from non-widget code (e.g. tray quit flow).
final GlobalKey<NavigatorState> appRootNavigatorKey = GlobalKey<NavigatorState>(
  debugLabel: 'root',
);

/// Branch navigators — re-tapping a tab pops pushed routes (e.g. schedule edit).
final List<GlobalKey<NavigatorState>> shellBranchNavigatorKeys =
    List<GlobalKey<NavigatorState>>.generate(
      4,
      (_) => GlobalKey<NavigatorState>(),
    );

GoRouter createAppRouter() {
  return GoRouter(
    navigatorKey: appRootNavigatorKey,
    initialLocation: '/focus',
    routes: <RouteBase>[
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) {
          return AppShell(navigationShell: navigationShell);
        },
        branches: <StatefulShellBranch>[
          StatefulShellBranch(
            navigatorKey: shellBranchNavigatorKeys[0],
            routes: <RouteBase>[
              GoRoute(
                path: '/focus',
                name: 'focus',
                pageBuilder: (context, state) =>
                    const NoTransitionPage<void>(child: FocusHomeScreen()),
                routes: <RouteBase>[
                  GoRoute(
                    path: 'browser-status',
                    name: 'browser_status',
                    pageBuilder: (context, state) {
                      final bool intro =
                          state.uri.queryParameters['intro'] == '1';
                      return MaterialPage<void>(
                        child: BlockingEcosystemStatusScreen(
                          mandatoryIntro: intro,
                        ),
                      );
                    },
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: shellBranchNavigatorKeys[1],
            routes: <RouteBase>[
              GoRoute(
                path: '/schedules',
                name: 'schedules',
                pageBuilder: (context, state) {
                  final String? highlight =
                      state.uri.queryParameters['highlight'];
                  return NoTransitionPage<void>(
                    child: SchedulesScreen(highlightScheduleName: highlight),
                  );
                },
                routes: <RouteBase>[
                  GoRoute(
                    path: 'legacy-rules',
                    name: 'legacy_rules',
                    pageBuilder: (context, state) =>
                        const NoTransitionPage<void>(child: RulesScreen()),
                  ),
                ],
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: shellBranchNavigatorKeys[2],
            routes: <RouteBase>[
              GoRoute(
                path: '/chat',
                name: 'chat',
                pageBuilder: (context, state) => NoTransitionPage<void>(
                  child: ChatScheduleFullScreen(
                    onApplied: ScheduleChangeBus.instance.notify,
                  ),
                ),
              ),
            ],
          ),
          StatefulShellBranch(
            navigatorKey: shellBranchNavigatorKeys[3],
            routes: <RouteBase>[
              GoRoute(
                path: '/settings',
                name: 'settings',
                pageBuilder: (context, state) =>
                    const NoTransitionPage<void>(child: SettingsScreen()),
                routes: <RouteBase>[
                  GoRoute(
                    path: 'quick-block',
                    name: 'quick_block_settings',
                    pageBuilder: (context, state) =>
                        const NoTransitionPage<void>(
                          child: QuickBlockSettingsScreen(),
                        ),
                    routes: <RouteBase>[
                      GoRoute(
                        path: 'catalog/:catalogId',
                        name: 'quick_block_catalog_edit',
                        pageBuilder: (context, state) {
                          final String id =
                              state.pathParameters['catalogId'] ?? 'games';
                          return NoTransitionPage<void>(
                            child: QuickBlockCatalogEditScreen(catalogId: id),
                          );
                        },
                      ),
                    ],
                  ),
                  GoRoute(
                    path: 'browser-management',
                    name: 'browser_management',
                    builder: (context, state) => BrowserProtectionCenterScreen(
                      credentialPromptRequestId: int.tryParse(
                        state.uri.queryParameters['credentialPrompt'] ?? '',
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    ],
  );
}
