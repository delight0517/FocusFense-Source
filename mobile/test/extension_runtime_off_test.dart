import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/services/extension_guard_prefs.dart';
import 'package:six_clean_room/services/extension_rules_builder.dart';
import 'package:six_clean_room/services/usage_ingest_server.dart';

void main() {
  test(
    'loopback API delivers OFF rules and bypasses video/channel lookup',
    () async {
      final received = <String?>[];
      final server = UsageIngestServer.forTesting(
        rulesProvider: (browser) {
          received.add(browser);
          return ExtensionRulesBuilder.buildForExtensionRuntime(
            browserId: browser,
            protectionEnabledForTesting: false,
          );
        },
        runtimeEnabled: (_) => false,
      );
      final client = HttpClient();
      try {
        await server.start();
        expect(server.isRunning, true);
        for (final path in <String>[
          '/rules?browser=aside',
          '/youtube/check?v=oKv36JQ64QM&browser=aside',
          '/youtube/channel-check?path=@ChosenFixture&browser=aside',
        ]) {
          final request = await client.getUrl(
            Uri.parse('http://127.0.0.1:${server.boundPort}$path'),
          );
          request.headers.set(HttpHeaders.userAgentHeader, 'Chrome/130');
          final response = await request.close();
          expect(response.statusCode, HttpStatus.ok);
          final json = jsonDecode(await utf8.decoder.bind(response).join());
          expect(json['protectionEnabled'], false);
          if (path.startsWith('/rules'))
            expect(json['blockedDomains'], isEmpty);
          else
            expect(json['blocked'], false);
        }
        expect(received, <String?>['aside']);
        for (final methodAndPath in <(String, String)>[
          ('GET', '/schedules/list'),
          ('GET', '/agent/snapshot'),
          ('POST', '/add-rule'),
        ]) {
          final request = await client.openUrl(methodAndPath.$1,
            Uri.parse('http://127.0.0.1:${server.boundPort}${methodAndPath.$2}'));
          final response = await request.close();
          expect(response.statusCode, HttpStatus.conflict);
          final body = jsonDecode(await utf8.decoder.bind(response).join());
          expect(body['error'], 'protection_disabled');
        }
      } finally {
        client.close(force: true);
        await server.stop();
      }
    },
    skip: !Platform.isWindows && !Platform.isMacOS,
  );

  test(
    'global OFF returns a fully disabled payload without opening a database',
    () async {
      final temp = await Directory.systemTemp.createTemp('ff-runtime-off-');
      try {
        final prefs = ExtensionGuardPrefs.forTesting(temp);
        for (final browser in ExtensionGuardPrefs.managedBrowserIds) {
          final result = await ExtensionRulesBuilder.buildForExtensionRuntime(
            browserId: browser,
            preferences: prefs,
            protectionEnabledForTesting: false,
          );
          final json = result.toJson(port: 17361);
          expect(json['protectionEnabled'], false);
          for (final key in <String>[
            'blockedDomains',
            'keywords',
            'searchQueries',
            'blockedYoutubeHandles',
            'blockedYoutubeChannelIds',
            'blockedYoutubeVideoIds',
          ]) {
            expect(json[key], isEmpty, reason: '$browser $key');
          }
          for (final key in <String>[
            'precisionContentFilter',
            'hideSerp',
            'hideYoutubeResults',
            'hideYtHomeFeed',
            'forceSafeSearch',
            'focusLocked',
          ]) {
            expect(json[key], false, reason: '$browser $key');
          }
          expect(result.copyWithoutYoutubeApex().protectionEnabled, false);
        }
      } finally {
        await temp.delete(recursive: true);
      }
    },
  );

  test(
    'per-browser OFF survives reload and does not disable other browsers',
    () async {
      final temp = await Directory.systemTemp.createTemp('ff-browser-off-');
      try {
        final prefs = ExtensionGuardPrefs.forTesting(temp);
        await prefs.setBrowserEnabled('aside', false);
        final reloaded = ExtensionGuardPrefs.forTesting(temp);
        expect(
          (await ExtensionRulesBuilder.buildForExtensionRuntime(
            browserId: 'aside',
            preferences: reloaded,
            protectionEnabledForTesting: true,
          )).protectionEnabled,
          false,
        );
        for (final browser in <String>['chrome', 'edge', 'firefox']) {
          expect(
            ExtensionRulesBuilder.runtimeProtectionEnabled(
              browserId: browser,
              preferences: reloaded,
              protectionEnabledForTesting: true,
            ),
            true,
          );
        }
        await prefs.setBrowserEnabled('aside', true);
        expect(
          ExtensionRulesBuilder.runtimeProtectionEnabled(
            browserId: 'aside',
            preferences: reloaded,
            protectionEnabledForTesting: true,
          ),
          true,
        );
      } finally {
        await temp.delete(recursive: true);
      }
    },
  );

  test('explicit Aside identity overrides a Chrome-compatible user agent', () {
    expect(
      ExtensionRulesBuilder.browserIdFromClient(
        requested: 'aside',
        userAgent: 'Chrome/130',
      ),
      'aside',
    );
    expect(
      ExtensionRulesBuilder.browserIdFromClient(
        userAgent: 'Chrome/130 Edg/130',
      ),
      'edge',
    );
    expect(
      ExtensionRulesBuilder.browserIdFromClient(userAgent: 'Firefox/130'),
      'firefox',
    );
    expect(
      ExtensionRulesBuilder.browserIdFromClient(
        userAgent: 'Aside/1 Chrome/130',
      ),
      'aside',
    );
    expect(
      ExtensionRulesBuilder.browserIdFromClient(requested: '../aside'),
      isNull,
    );
  });
}
