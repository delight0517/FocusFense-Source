import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/services/windows_firefox_extension_install_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late File xpi;
  late String hash;
  late FirefoxManagedRepairReport prepared;
  int prepareCalls = 0, launches = 0, validations = 0;
  late List<String> launchArguments;
  bool approved = true, failLaunch = false;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ff-native-update-test-');
    xpi = await File(
      '${directory.path}/approved update.xpi',
    ).writeAsBytes(<int>[1, 2, 3, 4]);
    hash = sha256.convert(await xpi.readAsBytes()).toString();
    prepared = FirefoxManagedRepairReport(
      filesPrepared: true,
      preparedXpiPath: xpi.path,
      expectedVersion: '1.0.26',
      expectedSha256: hash,
    );
    prepareCalls = 0;
    launches = 0;
    validations = 0;
    approved = true;
    failLaunch = false;
    launchArguments = <String>[];
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });
  WindowsFirefoxExtensionInstallService service() =>
      WindowsFirefoxExtensionInstallService.forTesting(
        prepare: () async {
          prepareCalls++;
          return prepared;
        },
        validateArtifact: (file) async {
          validations++;
          return approved;
        },
        findFirefox: () async =>
            r'C:\Program Files\Mozilla Firefox\firefox.exe',
        launch: (executable, arguments) async {
          if (failLaunch) throw StateError('launch rejected');
          launches++;
          launchArguments = arguments;
        },
      );
  test(
    'explicit action required: no preparation, validation or browser launch otherwise',
    () async {
      final FirefoxNativeUpdateReport result = await service()
          .requestNativeUpdate(userInitiated: false);
      expect(result.launchRequested, false);
      expect(prepareCalls, 0);
      expect(validations, 0);
      expect(launches, 0);
    },
  );
  test('failed preparation leaves browser untouched', () async {
    prepared = const FirefoxManagedRepairReport(
      message: 'preparation unavailable',
    );
    final FirefoxNativeUpdateReport result = await service()
        .requestNativeUpdate(userInitiated: true);
    expect(result.filesPrepared, false);
    expect(result.launchRequested, false);
    expect(result.message, 'preparation unavailable');
    expect(validations, 0);
    expect(launches, 0);
  });
  test('unapproved bytes rejected before Firefox lookup or launch', () async {
    approved = false;
    final FirefoxNativeUpdateReport result = await service()
        .requestNativeUpdate(userInitiated: true);
    expect(result.filesPrepared, true);
    expect(result.artifactVerified, false);
    expect(result.launchRequested, false);
    expect(launches, 0);
  });
  test(
    'prepared bytes must match expected SHA even if approval adapter reports true',
    () async {
      await xpi.writeAsBytes(<int>[9, 9, 9]);
      final FirefoxNativeUpdateReport result = await service()
          .requestNativeUpdate(userInitiated: true);
      expect(result.artifactVerified, false);
      expect(result.launchRequested, false);
      expect(launches, 0);
    },
  );
  test(
    'approved native request reuses validated opener, reports launch only, preserves sessions',
    () async {
      final FirefoxNativeUpdateReport result = await service()
          .requestNativeUpdate(userInitiated: true);
      expect(result.filesPrepared, true);
      expect(result.artifactVerified, true);
      expect(result.launchRequested, true);
      expect(result.requiresUserConfirmation, true);
      expect(result.nativeDialogVerified, false);
      expect(result.activationVerified, false);
      expect(prepareCalls, 1);
      expect(validations, 2);
      expect(launches, 1);
      expect(launchArguments.length, 2);
      expect(launchArguments.first, '-new-tab');
      expect(Uri.parse(launchArguments.last).scheme, 'file');
      expect(launchArguments.last, contains('approved%20update.xpi'));
      expect(result.toJson()['ok'], true);
      expect(result.toJson()['nativeDialogVerified'], false);
      expect(result.toJson()['activationVerified'], false);
    },
  );
  test(
    'launch failure preserves verified prepared artifact without claiming dialog shown',
    () async {
      failLaunch = true;
      final FirefoxNativeUpdateReport result = await service()
          .requestNativeUpdate(userInitiated: true);
      expect(result.artifactVerified, true);
      expect(result.launchRequested, false);
      expect(result.nativeDialogVerified, false);
      expect(result.activationVerified, false);
      expect(launches, 0);
    },
  );
  test('legacy direct opener retains approved-artifact gate', () async {
    approved = false;
    expect(await service().openSignedXpiInFirefox(xpiPath: xpi.path), false);
    expect(validations, 1);
    expect(launches, 0);
  });
}
