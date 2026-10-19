import 'dart:io';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'app_control_contract.dart';
import 'browser_management_control.dart';
import 'youtube_budget_exemption_store.dart';
import 'game_daily_budget_service.dart';
import 'browser_performance_prefs.dart';
import 'lock_policy_service.dart';
import 'backup_service.dart';
import 'chat_schedule_apply_service.dart';
import 'chat_schedule_audit_log_service.dart';
import '../models/quick_block_user_bundle.dart';
import '../models/quick_block_rule_entries.dart';
import 'quick_block_prefs_store.dart';
import 'quick_block_session_service.dart';
import '../enforcement/enforcement_controller.dart';
import 'block_sync_service.dart';
import 'build_identity_service.dart';
import 'extension_guard_prefs.dart';
import 'extension_rules_snapshot_service.dart';
import 'local_control_api.dart';
import 'local_database.dart';
import 'universal_browser_block_service.dart';
import 'windows_protection_mode_prefs.dart';
import 'windows_extension_guard_service.dart';
import 'windows_system_block_service.dart';
import 'windows_window_title_guard_service.dart';
import 'windows_firewall_block_service.dart';
import 'adult_domain_component_store.dart';
import 'windows_app_block_service.dart';
import '../router/app_router.dart';

/// UI and CLI use the existing app rule/enforcement services, not a second engine.
class AppControlActions {
  static Future<String>? _credential;
  static Future<String> prepare() => _credential ??=
      LocalControlApi.loadOrCreateToken(
        File(
          p.join(
            Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path,
            'SixVPNBlocker',
            'focusfense_cli.token',
          ),
        ),
      ).catchError((Object error) {
        _credential = null;
        throw error;
      });
  static final api = LocalControlApi(
    token: prepare,
    schemas: AppControlContract.schemas,
    validateArguments: AppControlContract.validate,
    readResource: (name, offset, limit) async {
      if (name == 'browser-performance') {
        return BrowserPerformancePrefs.instance.status();
      }
      if (name == 'game-budget') {
        return GameDailyBudgetService.instance.status();
      }
      if (name == 'youtube-exemptions') {
        final entries = await YoutubeBudgetExemptionStore.instance
            .listEntries();
        return {
          'scope': 'youtube-time-budget-only',
          'items': entries.skip(offset).take(limit).toList(),
          'total': entries.length,
          'nextOffset': offset + limit < entries.length ? offset + limit : null,
        };
      }
      if (name == 'browser-management') {
        return BrowserManagementControl.status();
      }
      final db = LocalDatabase.instance;
      if (name == 'components') {
        await AdultDomainComponentStore.instance.read();
        return {
          'items': [AdultDomainComponentStore.instance.status],
        };
      }
      if (name == 'quick-block') {
        final session = await QuickBlockSessionService.instance.activeSession();
        return {
          'session': session?.toJson(),
          'testLeaseUntilMs': await QuickBlockSessionService.instance
              .testLeaseUntilMs(),
          'apps': [
            for (final app
                in await QuickBlockSessionService.instance.activeBlockApps())
              app.toJson(),
          ],
        };
      }
      if (name == 'policy') return (await db.rulesMeta()).toJson();
      if (name == 'browser-switches') {
        return {
          for (final browser in ExtensionGuardPrefs.managedBrowserIds)
            browser: !ExtensionGuardPrefs.instance.isBrowserExplicitlyDisabled(
              browser,
            ),
        };
      }
      final rows = switch (name) {
        'domains' => await db.domains(),
        'keywords' => await db.keywords(),
        'schedules' => await db.schedules(),
        _ => throw const FormatException('Unknown resource'),
      };
      return {
        'items': rows.skip(offset).take(limit).toList(),
        'total': rows.length,
        'nextOffset': offset + limit < rows.length ? offset + limit : null,
      };
    },
    actions: const {
      ...BrowserManagementControl.actions,
      'browser.performance':
          'Change Firefox YouTube feed filtering only; retain URL protection, SafeSearch and time quotas',
      'gameBudget.configure':
          'Configure one pooled daily game budget with a remaining-time warning; preserve measured usage and existing locks',
      'youtube.exemptions.preview':
          'Resolve explicit targets for YouTube time-count exemptions without changing protection rules',
      'youtube.exemptions.add':
          'Add explicit YouTube time-count exemptions; all other protection rules remain active',
      'youtube.exemptions.remove':
          'Remove explicit YouTube time-count exemptions',
      'chat.preview':
          'Preview a chat schedule request through the existing parser and safety checks',
      'chat.apply':
          'Apply a schedule request; authenticated debug override can bypass its edit cooldown',
      'app.keepFirefoxOpen':
          'Preserve Firefox work sessions while retaining site protection',
      'components.reload':
          'Reload verified local data components and refresh browser rule snapshots',
      'app.holdBrowsers':
          'Hold Chrome and Aside until explicit release, with the existing 72-hour minimum preserved',
      'app.releaseBrowserHold':
          'Release the browser hold normally or bypass its minimum and app lock via authenticated debug override',
      'quickBlock.clear':
          'Clear the active quick block; debug override bypasses timer and app lock',
      'quickBlock.testLease.begin':
          'Temporarily release only an explicit browser hold for up to 60 minutes; restore is persisted across app restart',
      'quickBlock.testLease.end':
          'End a browser test lease and restore its original hold immediately',
      'app.blockChrome':
          'Temporarily block main Google Chrome for up to 72 hours; preserve PWAs and existing quick sessions',
      'protection.enable':
          'Enable manual protection; keep autostart/recovery unchanged',
      'protection.disable':
          'Stop protection using normal cleanup; keep control API reachable',
      'rule.add': 'Add a global domain or keyword rule',
      'rule.remove':
          'Remove an exact domain or keyword rule; debug override can bypass locks',
      'rule.setEnabled':
          'Enable or disable an exact domain or keyword rule; debug override can bypass locks',
      'schedule.setEnabled':
          'Enable or disable a schedule; debug override can bypass locks',
      'browser.enable':
          'Enable the selected managed browser and schedule rule sync',
      'browser.disable':
          'Disable the selected managed browser; debug override can bypass the app lock',
      'policy.patch':
          'Update the registered adult, SafeSearch or strictness settings',
      'adult.enable': 'Enable the built-in adult-site category',
      'adult.disable': 'Disable the built-in adult-site category',
      'browser.apply':
          'Apply current rules with the app browser synchronization service',
    },
    readStatus: () async => {
      'appBuild': await BuildIdentityService.instance.summaryLine(),
      'processId': pid,
      'windowVisible': Platform.isWindows
          ? await windowManager.isVisible()
          : null,
      'windowFocused': Platform.isWindows
          ? await windowManager.isFocused()
          : null,
      'protectionEnabled':
          !WindowsProtectionModePrefs.isProtectionExplicitlyOff,
      'browserSwitches': {
        for (final browser in ExtensionGuardPrefs.managedBrowserIds)
          browser: !ExtensionGuardPrefs.instance.isBrowserExplicitlyDisabled(
            browser,
          ),
      },
      'adultSitesBlocked':
          (await LocalDatabase.instance.rulesMeta()).adultSitesBlocked,
      'apiVersion': 2,
    },
    runAction: (action, arguments) async {
      AppControlContract.validate(action, arguments);
      if (action == 'browser.mozilla.credentialsPrompt') {
        final context = appRootNavigatorKey.currentContext;
        if (context == null || !context.mounted) {
          throw StateError(
            'FocusFense window is not ready to show credentials',
          );
        }
        final requestId = DateTime.now().microsecondsSinceEpoch;
        GoRouter.of(context).goNamed(
          'browser_management',
          queryParameters: {'credentialPrompt': '$requestId'},
        );
        if (Platform.isWindows) {
          await windowManager.show();
          await windowManager.focus();
        }
        return {
          'ok': true,
          'promptRequested': true,
          'credentialsReturned': false,
          'purpose': 'mozilla-amo',
        };
      }
      if (action == 'browser.performance') {
        final enabled = arguments['youtubeFeedFiltering'] as bool;
        if (!enabled &&
            await LockPolicyService.instance.isEffectivelyLocked(
              await LocalDatabase.instance.rulesMeta(),
            )) {
          throw const FormatException(
            'Firefox feed filtering cannot be weakened while protection is locked',
          );
        }
        await BrowserPerformancePrefs.instance.setYoutubeFeedFiltering(enabled);
        BackupService.instance.scheduleSync();
        final snapshotWritten = await ExtensionRulesSnapshotService.instance
            .writeToFirefoxPayload();
        return {
          'ok': true,
          ...await BrowserPerformancePrefs.instance.status(),
          'snapshotWritten': snapshotWritten,
          'browserRestarted': false,
        };
      }
      if (action == 'gameBudget.configure') {
        final status = await GameDailyBudgetService.instance.configure(
          enabled: arguments['enabled'] as bool,
          maxMinutes: arguments['maxMinutes'] as int,
          warningMinutes: arguments['warningMinutes'] as int,
          targets: List<String>.from(arguments['targets'] as List),
        );
        return {'ok': true, ...status};
      }
      if (action.startsWith('youtube.exemptions.')) {
        final store = YoutubeBudgetExemptionStore.instance;
        final targets = List<String>.from(arguments['targets'] as List);
        final entries = await store.resolveTargets(targets);
        if (action == 'youtube.exemptions.add') {
          await store.addEntries(entries);
        } else if (action == 'youtube.exemptions.remove') {
          await store.removeEntries(entries);
        }
        if (!action.endsWith('.preview')) {
          await ExtensionRulesSnapshotService.instance.writeToChromePayload(
            force: true,
          );
          await ExtensionRulesSnapshotService.instance.writeToFirefoxPayload();
        }
        return {
          'ok': true,
          'scope': 'youtube-time-budget-only',
          'preview': action.endsWith('.preview'),
          'resolved': entries,
          'items': await store.listEntries(),
        };
      }
      if (action == 'chat.preview' || action == 'chat.apply') {
        final message = arguments['message'] as String;
        final resolution = arguments['resolution'] as String?;
        final scheduleId = arguments['forceScheduleId'] as String?;
        if (action == 'chat.preview') {
          return {
            'ok': true,
            'preview': (await ChatScheduleApplyService.instance.preview(
              message,
              resolution: resolution,
              forceScheduleId: scheduleId,
            )).toJson(),
          };
        }
        final result = await ChatScheduleApplyService.instance.apply(
          message,
          resolution: resolution,
          forceScheduleId: scheduleId,
          debugOverride: arguments['debugOverride'] == true,
        );
        await ChatScheduleAuditLogService.instance.record(
          conversationId: 'cli-${const Uuid().v4()}',
          turnIndex: 0,
          message: message,
          result: result,
          conversation: [
            {'role': 'user', 'content': message},
          ],
        );
        return result.toJson();
      }
      if (BrowserManagementControl.actions.containsKey(action)) {
        return BrowserManagementControl.run(action, arguments);
      }
      if (action == 'app.keepFirefoxOpen') {
        await WindowsAppBlockService.instance.keepFirefoxOpen();
        return {
          'ok': true,
          'firefoxKeptOpen': true,
          'siteProtectionUnchanged': true,
        };
      } else if (action == 'app.releaseBrowserHold') {
        final service = QuickBlockSessionService.instance;
        final session = await service.activeSession();
        if (session?.releaseRequired != true) {
          throw const FormatException('No browser release hold exists');
        }
        final debugOverride = arguments['debugOverride'] == true;
        final outcome = await service.tryClearSession(
          debugOverrideMinimum: debugOverride,
          debugOverridePolicy: debugOverride,
        );
        return {
          'ok': outcome == QuickBlockClearOutcome.cleared,
          'outcome': outcome.name,
          'debugOverrideMinimum': debugOverride,
        };
      } else if (action == 'quickBlock.clear') {
        final debugOverride = arguments['debugOverride'] == true;
        final outcome = await QuickBlockSessionService.instance.tryClearSession(
          debugOverrideMinimum: debugOverride,
          debugOverridePolicy: debugOverride,
        );
        return {
          'ok': outcome == QuickBlockClearOutcome.cleared,
          'outcome': outcome.name,
          'debugOverride': debugOverride,
        };
      } else if (action == 'quickBlock.testLease.begin') {
        final untilMs = await QuickBlockSessionService.instance
            .beginBrowserHoldTestLease(
              durationMinutes: arguments['durationMinutes'] as int,
            );
        return {
          'ok': true,
          'untilMs': untilMs,
          'autoRestore': true,
          'scope': 'explicit-browser-release-hold-only',
        };
      } else if (action == 'quickBlock.testLease.end') {
        await QuickBlockSessionService.instance.endBrowserHoldTestLease();
        return {'ok': true, 'restored': true};
      } else if (action == 'app.holdBrowsers') {
        if (!Platform.isWindows ||
            WindowsProtectionModePrefs.isProtectionExplicitlyOff) {
          throw const FormatException('Windows protection must be enabled');
        }
        final service = QuickBlockSessionService.instance;
        final store = QuickBlockPrefsStore.instance;
        final bundles = await store.loadBundles();
        var session = await service.activeSession();
        if (session != null) {
          // Preserve unrelated quick blocks instead of silently changing their duration/apps.
          final active = bundles
              .where((b) => session!.bundleIds.contains(b.id))
              .toList();
          if (active.length != 1 ||
              session.bundleIds.length != 1 ||
              ![
                'Chrome 임시 차단',
                'Chrome · Aside 출시 대기',
              ].contains(active.single.label) ||
              active.single.domains.isNotEmpty ||
              active.single.keywords.isNotEmpty ||
              active.single.apps.isEmpty ||
              active.single.apps.any(
                (a) => ![
                  'win|chrome.exe|_main',
                  'win|aside.exe|_main',
                ].contains(a.bundleId),
              )) {
            throw const FormatException(
              'Unrelated quick session will not be overwritten',
            );
          }
        }
        final id = session?.bundleIds.single ?? const Uuid().v4();
        await store.saveBundles([
          for (final bundle in bundles)
            if (bundle.id != id) bundle,
          QuickBlockUserBundle(
            id: id,
            label: 'Chrome · Aside 출시 대기',
            apps: const [
              QuickBlockAppRule(
                displayName: 'Google Chrome',
                bundleId: 'win|chrome.exe|_main',
              ),
              QuickBlockAppRule(
                displayName: 'Aside',
                bundleId: 'win|aside.exe|_main',
              ),
            ],
          ),
        ]);
        session ??= await service.startWithBundles(
          [id],
          durationHours: 72,
          cancelDelayMinutes: 0,
        );
        final held = await service.holdForRelease(session!);
        return {
          'ok': true,
          'session': held.toJson(),
          'runtimeVerificationRequired': true,
        };
      } else if (action == 'app.blockChrome') {
        if (!Platform.isWindows ||
            WindowsProtectionModePrefs.isProtectionExplicitlyOff) {
          throw const FormatException('Windows protection must be enabled');
        }
        final service = QuickBlockSessionService.instance;
        if (await service.hasActiveSession()) {
          throw const FormatException(
            'An active quick block already exists; it will not be overwritten',
          );
        }
        final store = QuickBlockPrefsStore.instance;
        final bundles = await store.loadBundles();
        final id = const Uuid().v4();
        await store.saveBundles([
          ...bundles,
          QuickBlockUserBundle(
            id: id,
            label: 'Chrome 임시 차단',
            apps: const [
              QuickBlockAppRule(
                displayName: 'Google Chrome',
                bundleId: 'win|chrome.exe|_main',
              ),
            ],
          ),
        ]);
        final session = await service.startWithBundles(
          [id],
          durationHours: arguments['hours'] as int,
          cancelDelayMinutes: 0,
        );
        return {
          'ok': session != null,
          'session': session?.toJson(),
          'runtimeVerificationRequired': true,
        };
      } else if (action == 'protection.enable') {
        await WindowsProtectionModePrefs.instance.setProtectionEnabled(true);
        final prefs = await SharedPreferences.getInstance();
        for (final browser
            in prefs.getStringList('control_restore_browsers_v1') ??
                <String>[]) {
          if (ExtensionGuardPrefs.managedBrowserIds.contains(browser)) {
            await ExtensionGuardPrefs.instance.setBrowserEnabled(browser, true);
          }
        }
        await prefs.remove('control_restore_browsers_v1');
        BlockSyncService.instance.enabled = true;
        EnforcementController.instance.enabled = true;
      } else if (action == 'protection.disable') {
        if (!Platform.isWindows) throw const FormatException('Windows only');
        if (!WindowsProtectionModePrefs.isProtectionExplicitlyOff) {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setStringList('control_restore_browsers_v1', [
            for (final browser in ExtensionGuardPrefs.managedBrowserIds)
              if (!ExtensionGuardPrefs.instance.isBrowserExplicitlyDisabled(
                browser,
              ))
                browser,
          ]);
        }
        await WindowsProtectionModePrefs.instance.setProtectionEnabled(false);
        BlockSyncService.instance.enabled = false;
        EnforcementController.instance.enabled = false;
        final errors = <String>[];
        Future<void> step(String name, Future<void> Function() work) async {
          try {
            await work();
          } catch (_) {
            errors.add(name);
          }
        }

        await step('snapshots', () async {
          await ExtensionRulesSnapshotService.instance.writeToChromePayload(
            force: true,
          );
          await ExtensionRulesSnapshotService.instance.writeToFirefoxPayload();
        });
        await step('extensions', () async {
          if (!(await WindowsExtensionGuardService.instance
                  .disableAllBrowserExtensions())
              .ok) {
            errors.add('extensions');
          }
        });
        await step('system', () async {
          if (!(await WindowsSystemBlockService.instance.deactivate()).ok) {
            errors.add('system');
          }
        });
        await step(
          'window-guard',
          () => WindowsWindowTitleGuardService.instance.stop(),
        );
        await step('firewall', () async {
          await WindowsFirewallBlockService.instance.deactivate();
        });
        return {
          'ok': errors.isEmpty,
          'protectionEnabled': false,
          'cleanupIncomplete': errors,
          'requiredAction': errors.isEmpty
              ? null
              : 'Inspect named cleanup stages; Windows consent may be needed',
          'runtimeVerificationRequired': true,
        };
      } else if (action == 'components.reload') {
        await AdultDomainComponentStore.instance.read(force: true);
        if (AdultDomainComponentStore.instance.status['error'] != null) {
          throw const FormatException(
            'Invalid component; previous rules retained',
          );
        }
        BlockSyncService.instance.requestApply();
      } else if (action == 'rule.add') {
        final value = (arguments['value'] as String).trim();
        final db = LocalDatabase.instance;
        if (arguments['type'] == 'domain') {
          final host = AppControlContract.normalizeHost(value);
          if (!await db.hasActiveDomain(host)) {
            await db.insertDomain(
              id: const Uuid().v4(),
              host: host,
              source: 'cli',
            );
          }
        } else if (!await db.hasActiveKeywordPattern(value)) {
          await db.insertKeyword(id: const Uuid().v4(), pattern: value);
        }
      } else if (action == 'rule.remove' || action == 'rule.setEnabled') {
        final type = arguments['type'] as String;
        final rawValue = (arguments['value'] as String).trim();
        final debugOverride = arguments['debugOverride'] == true;
        final enabled = action == 'rule.setEnabled'
            ? arguments['enabled'] as bool
            : false;
        final db = LocalDatabase.instance;
        final meta = await db.rulesMeta();
        if (!debugOverride &&
            !enabled &&
            await LockPolicyService.instance.isEffectivelyLocked(meta)) {
          throw const FormatException(
            'Rule change is locked; use the authenticated debug override to change it',
          );
        }
        var changed = 0;
        if (type == 'domain') {
          final host = AppControlContract.normalizeHost(rawValue);
          final rows = await db.domains();
          for (final row in rows.where(
            (row) => (row['host'] as String? ?? '').toLowerCase() == host,
          )) {
            final scheduleId = row['schedule_id'] as String?;
            if (!debugOverride &&
                !enabled &&
                scheduleId != null &&
                await db.isScheduleEffectivelyLocked(scheduleId)) {
              throw const FormatException(
                'Rule belongs to a locked schedule; use the authenticated debug override to change it',
              );
            }
            if (action == 'rule.remove') {
              await db.deleteDomain(row['id'] as String);
            } else {
              await db.setDomainEnabled(row['id'] as String, enabled);
            }
            changed++;
          }
        } else {
          final rows = await db.keywords();
          for (final row in rows.where(
            (row) =>
                (row['pattern'] as String? ?? '').toLowerCase() ==
                rawValue.toLowerCase(),
          )) {
            final scheduleId = row['schedule_id'] as String?;
            if (!debugOverride &&
                !enabled &&
                scheduleId != null &&
                await db.isScheduleEffectivelyLocked(scheduleId)) {
              throw const FormatException(
                'Rule belongs to a locked schedule; use the authenticated debug override to change it',
              );
            }
            if (action == 'rule.remove') {
              await db.deleteKeyword(row['id'] as String);
            } else {
              await db.setKeywordEnabled(row['id'] as String, enabled);
            }
            changed++;
          }
        }
        if (changed == 0) {
          throw const FormatException('No exact active rule matched');
        }
        await ExtensionRulesSnapshotService.instance.writeToChromePayload(
          force: true,
        );
        await ExtensionRulesSnapshotService.instance.writeToFirefoxPayload();
        UniversalBrowserBlockService.instance.scheduleSync(
          reason: 'cli_$action',
        );
        return {
          'ok': true,
          'action': action,
          'type': type,
          'value': rawValue,
          'changed': changed,
          'debugOverride': debugOverride,
          'runtimeVerificationRequired': true,
        };
      } else if (action == 'schedule.setEnabled') {
        final id = (arguments['scheduleId'] as String).trim();
        final enabled = arguments['enabled'] as bool;
        final debugOverride = arguments['debugOverride'] == true;
        final db = LocalDatabase.instance;
        final schedule = await db.scheduleById(id);
        if (schedule == null) {
          throw const FormatException('Schedule not found');
        }
        if (!debugOverride &&
            !enabled &&
            (await db.isScheduleEffectivelyLocked(id) ||
                await LockPolicyService.instance.isEffectivelyLocked(
                  await db.rulesMeta(),
                ))) {
          throw const FormatException(
            'Schedule is locked; use the authenticated debug override to change it',
          );
        }
        await db.setScheduleEnabled(id, enabled);
        await ExtensionRulesSnapshotService.instance.writeToChromePayload(
          force: true,
        );
        await ExtensionRulesSnapshotService.instance.writeToFirefoxPayload();
        UniversalBrowserBlockService.instance.scheduleSync(
          reason: 'cli_$action',
        );
        return {
          'ok': true,
          'action': action,
          'scheduleId': id,
          'enabled': enabled,
          'debugOverride': debugOverride,
          'runtimeVerificationRequired': true,
        };
      } else if (action == 'browser.enable') {
        await ExtensionGuardPrefs.instance.setBrowserEnabled(
          arguments['browser'] as String,
          true,
        );
      } else if (action == 'browser.disable') {
        final debugOverride = arguments['debugOverride'] == true;
        if (!debugOverride &&
            await LockPolicyService.instance.isEffectivelyLocked(
              await LocalDatabase.instance.rulesMeta(),
            )) {
          throw const FormatException(
            'Browser switch is locked; use the authenticated debug override to change it',
          );
        }
        await ExtensionGuardPrefs.instance.setBrowserEnabled(
          arguments['browser'] as String,
          false,
        );
      } else if (action == 'policy.patch') {
        final meta = await LocalDatabase.instance.rulesMeta();
        await LocalDatabase.instance.saveRulesMeta(
          meta.copyWith(
            adultSitesBlocked: arguments['adultSitesBlocked'] as bool?,
            forceSafeSearch: arguments['forceSafeSearch'] as bool?,
            strictness: arguments['strictness'] as String?,
          ),
        );
      } else if (action == 'adult.enable' || action == 'adult.disable') {
        final meta = await LocalDatabase.instance.rulesMeta();
        await LocalDatabase.instance.saveRulesMeta(
          meta.copyWith(adultSitesBlocked: action == 'adult.enable'),
        );
      } else if (action == 'browser.apply') {
        final result = await UniversalBrowserBlockService.instance.syncNow(
          reason: 'cli',
        );
        return {
          'ok': result.ok,
          'message': result.message,
          'steps': result.steps,
          'pacApplied': result.pacApplied,
          'runtimeVerificationRequired': true,
        };
      } else {
        throw const FormatException('Unknown action');
      }
      await ExtensionRulesSnapshotService.instance.writeToChromePayload(
        force: true,
      );
      await ExtensionRulesSnapshotService.instance.writeToFirefoxPayload();
      UniversalBrowserBlockService.instance.scheduleSync(reason: 'cli_$action');
      return {
        'ok': true,
        'action': action,
        'protectionEnabled':
            !WindowsProtectionModePrefs.isProtectionExplicitlyOff,
        'adultSitesBlocked':
            (await LocalDatabase.instance.rulesMeta()).adultSitesBlocked,
        'runtimeVerificationRequired': true,
      };
    },
  );
}
