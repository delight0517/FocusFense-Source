import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:six_clean_room/services/firefox_config_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp, profile;
  late File userJs, prefsJs;
  late List<int> original, livePrefs;
  bool off = false;
  Future<void> Function()? hook;
  late FirefoxConfigService service;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ff-profile-owned-');
    profile = await Directory(p.join(temp.path, 'profile 한글')).create();
    userJs = File(p.join(profile.path, 'user.js'));
    prefsJs = File(p.join(profile.path, 'prefs.js'));
    original = utf8.encode(
      '\ufeff// 한글 설정\r\nuser_pref("browser.startup.page", 3);\r\nuser_pref("network.proxy.type", 1);',
    );
    livePrefs = utf8.encode(
      'user_pref("network.proxy.type", 1);\r\nuser_pref("network.proxy.http", "company.example");\r\nuser_pref("network.trr.mode", 3);\r\n',
    );
    await userJs.writeAsBytes(original);
    await prefsJs.writeAsBytes(livePrefs);
    off = false;
    hook = null;
    service = FirefoxConfigService.forTesting(
      protectionOff: () => off,
      profiles: () async => [profile],
      beforeWrite: () async => hook?.call(),
    );
  });
  tearDown(() async {
    await temp.delete(recursive: true);
  });

  test(
    'bounded network region preserves BOM, Unicode, CRLF and original proxy bytes',
    () {
      final applied = FirefoxConfigService.mergeManagedNetworkPrefs(
        original,
        enabled: true,
      );
      expect(applied.take(original.length).toList(), original);
      final text = utf8.decode(applied);
      expect('network.proxy.type'.allMatches(text), hasLength(1));
      expect(text.contains('network.proxy.autoconfig_url'), false);
      expect(
        FirefoxConfigService.mergeManagedNetworkPrefs(applied, enabled: true),
        applied,
      );
      expect(
        FirefoxConfigService.mergeManagedNetworkPrefs(applied, enabled: false),
        original,
      );
    },
  );

  test(
    'apply/OFF preserve user.js outside ownership and never edit live prefs.js',
    () async {
      expect((await service.probeProfiles()).single.userJsInstalled, false);
      expect(await service.applyNetworkBlockPrefsInAllProfiles(), [
        profile.path,
      ]);
      final applied = await userJs.readAsBytes();
      expect(await prefsJs.readAsBytes(), livePrefs);
      expect((await service.probeProfiles()).single.userJsInstalled, true);
      await service.applyNetworkBlockPrefsInAllProfiles();
      expect(await userJs.readAsBytes(), applied);
      off = true;
      expect(await service.removeManagedNetworkPrefsInAllProfiles(), [
        profile.path,
      ]);
      expect(await userJs.readAsBytes(), original);
      expect(await prefsJs.readAsBytes(), livePrefs);
      expect((await service.probeProfiles()).single.userJsInstalled, false);
      expect(await service.removeManagedNetworkPrefsInAllProfiles(), isEmpty);
      expect(
        await File(p.join(profile.path, '.focusfense-user-js.tmp')).exists(),
        false,
      );
    },
    skip: !Platform.isWindows && !Platform.isMacOS,
  );

  test('OFF at entry does not enumerate profiles or write files', () async {
    var enumerations = 0;
    final stopped = FirefoxConfigService.forTesting(
      protectionOff: () => true,
      profiles: () async {
        enumerations++;
        return [profile];
      },
    );
    expect(await stopped.applyNetworkBlockPrefsInAllProfiles(), isEmpty);
    expect(enumerations, 0);
    expect(await userJs.readAsBytes(), original);
    expect(await prefsJs.readAsBytes(), livePrefs);
  });

  for (final stage in ['profile-list', 'before-write']) {
    test('OFF during $stage prevents a late profile write', () async {
      final stopped = FirefoxConfigService.forTesting(
        protectionOff: () => off,
        profiles: () async {
          if (stage == 'profile-list') off = true;
          return [profile];
        },
        beforeWrite: () async {
          if (stage == 'before-write') off = true;
        },
      );
      expect(await stopped.applyNetworkBlockPrefsInAllProfiles(), isEmpty);
      expect(off, true);
      expect(await userJs.readAsBytes(), original);
      expect(await prefsJs.readAsBytes(), livePrefs);
    });
  }

  test('serialized OFF cannot be overtaken by an in-flight apply', () async {
    final ready = Completer<void>();
    final release = Completer<void>();
    hook = () async {
      ready.complete();
      await release.future;
    };
    final applying = service.applyNetworkBlockPrefsInAllProfiles();
    await ready.future;
    off = true;
    final removing = service.removeManagedNetworkPrefsInAllProfiles();
    release.complete();
    expect(await applying, isEmpty);
    expect(await removing, isEmpty);
    expect(await userJs.readAsBytes(), original);
    expect(await prefsJs.readAsBytes(), livePrefs);
  });

  test(
    'unclosed ownership marker is preserved and reported instead of overwritten',
    () async {
      final broken = [
        ...original,
        ...ascii.encode('\n${FirefoxConfigService.managedBegin}\nunfinished'),
      ];
      await userJs.writeAsBytes(broken);
      await expectLater(
        service.applyNetworkBlockPrefsInAllProfiles(),
        throwsStateError,
      );
      expect(await userJs.readAsBytes(), broken);
      expect(await prefsJs.readAsBytes(), livePrefs);
      await userJs.writeAsBytes(original);
      await service.applyNetworkBlockPrefsInAllProfiles();
      await service.removeManagedNetworkPrefsInAllProfiles();
      expect(
        await userJs.readAsBytes(),
        original,
        reason: 'Failed update must not poison the queue',
      );
    },
  );

  test(
    'a failed profile does not prevent cleanup of another profile',
    () async {
      final bad = await Directory(p.join(temp.path, 'bad')).create();
      final broken = ascii.encode(
        '\n${FirefoxConfigService.managedBegin}\nunfinished',
      );
      final badJs = File(p.join(bad.path, 'user.js'));
      await badJs.writeAsBytes(broken);
      final multiple = FirefoxConfigService.forTesting(
        protectionOff: () => off,
        profiles: () async => [bad, profile],
      );
      await expectLater(
        multiple.applyNetworkBlockPrefsInAllProfiles(),
        throwsStateError,
      );
      expect(
        utf8.decode(await userJs.readAsBytes()),
        contains(FirefoxConfigService.managedBegin),
      );
      off = true;
      await expectLater(
        multiple.removeManagedNetworkPrefsInAllProfiles(),
        throwsStateError,
      );
      expect(await userJs.readAsBytes(), original);
      expect(await badJs.readAsBytes(), broken);
    },
  );

  test(
    'external edit during preparation is retained and a retry uses the new baseline',
    () async {
      final external = [...original, ...ascii.encode('\n// external change')];
      hook = () async {
        await userJs.writeAsBytes(external);
      };
      await expectLater(
        service.applyNetworkBlockPrefsInAllProfiles(),
        throwsStateError,
      );
      expect(await userJs.readAsBytes(), external);
      hook = null;
      await service.applyNetworkBlockPrefsInAllProfiles();
      await service.removeManagedNetworkPrefsInAllProfiles();
      expect(await userJs.readAsBytes(), external);
      expect(await prefsJs.readAsBytes(), livePrefs);
    },
  );

  test('unbounded legacy content is not guessed to be removable ownership', () {
    final legacy = utf8.encode(
      '// === 6 VPN Blocker managed prefs — do not edit by hand ===\nuser_pref("network.proxy.type",0);\n// user-added content',
    );
    final after = FirefoxConfigService.mergeManagedNetworkPrefs(
      legacy,
      enabled: true,
    );
    expect(
      FirefoxConfigService.mergeManagedNetworkPrefs(after, enabled: false),
      legacy,
    );
    expect(
      FirefoxConfigService.mergeManagedNetworkPrefs(legacy, enabled: false),
      legacy,
    );
  });

  test(
    'absent user.js can receive and remove a managed region without touching prefs.js',
    () async {
      await userJs.delete();
      await service.applyNetworkBlockPrefsInAllProfiles();
      expect(await userJs.exists(), true);
      off = true;
      await service.removeManagedNetworkPrefsInAllProfiles();
      expect(await userJs.readAsBytes(), isEmpty);
      expect(await prefsJs.readAsBytes(), livePrefs);
    },
  );
}
