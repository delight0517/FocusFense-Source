import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/services/windows_chromium_registry_service.dart';
import 'package:six_clean_room/services/windows_browser_proxy_policy_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final stopAt in [
    'entry',
    'migration',
    'apply',
    'failed-apply',
    'success',
  ]) {
    test(
      'PAC wrapper honors OFF at $stopAt and never starts a second writer',
      () async {
        final directory = await Directory.systemTemp.createTemp(
          'ff-pac-wrapper-',
        );
        try {
          final pac = File('${directory.path}\\test.pac');
          await pac.writeAsString(
            'function FindProxyForURL(){return "DIRECT";}',
          );
          bool off = stopAt == 'entry';
          int migrations = 0;
          int applies = 0;
          final service = WindowsBrowserProxyPolicyService.forTesting(
            protectionOff: () => off,
            migrate: () async {
              migrations++;
              if (stopAt == 'migration') off = true;
            },
            apply: (path) async {
              expect(path, pac.path);
              applies++;
              if (stopAt == 'apply') off = true;
              return stopAt != 'failed-apply';
            },
          );
          expect(
            await service.forceChromiumPac(pacPath: pac.path),
            stopAt == 'success',
          );
          expect(migrations, stopAt == 'entry' ? 0 : 1);
          expect(applies, ['entry', 'migration'].contains(stopAt) ? 0 : 1);
        } finally {
          await directory.delete(recursive: true);
        }
      },
      skip: !Platform.isWindows,
    );
  }
  test(
    'manual OFF prevents direct PAC apply, migration and policy probe',
    () async {
      final calls = <List<String>>[];
      final service = WindowsChromiumRegistryService.forTesting(
        protectionOff: () => true,
        run: (exe, args) async {
          calls.add(args);
          return ProcessResult(0, 0, '', '');
        },
      );
      expect(await service.applyPacEverywhere('unused.pac'), isFalse);
      expect(
        await service.ensureChromiumEnforcement(pacPath: 'unused.pac'),
        isFalse,
      );
      await service.migrateLegacyPacRegistry();
      expect(await service.isEdgeHkcuPolicyLocked(), isFalse);
      expect(calls, isEmpty);
    },
    skip: !Platform.isWindows,
  );

  test('OFF as the PAC process finishes cannot report apply success', () async {
    final directory = await Directory.systemTemp.createTemp('ff-pac-last-off-');
    try {
      final pac = File('${directory.path}\\test.pac');
      await pac.writeAsString('function FindProxyForURL(){return "DIRECT";}');
      bool off = false;
      final service = WindowsChromiumRegistryService.forTesting(
        protectionOff: () => off,
        run: (exe, args) async {
          expect(args.last, contains('Invoke-FFPacApply'));
          off = true;
          return ProcessResult(0, 0, 'pac_ok=3', '');
        },
      );
      expect(await service.applyPacEverywhere(pac.path), isFalse);
      expect(off, isTrue);
    } finally {
      await directory.delete(recursive: true);
    }
  }, skip: !Platform.isWindows);

  test('OFF during PAC apply prevents any second policy process', () async {
    final directory = await Directory.systemTemp.createTemp('ff-pac-off-');
    try {
      final pac = File('${directory.path}\\test.pac');
      await pac.writeAsString('function FindProxyForURL(){return "DIRECT";}');
      bool off = false;
      final calls = <List<String>>[];
      final service = WindowsChromiumRegistryService.forTesting(
        protectionOff: () => off,
        run: (exe, args) async {
          calls.add(args);
          off = true;
          return ProcessResult(0, 0, '', '');
        },
      );
      expect(await service.applyPacEverywhere(pac.path), isFalse);
      expect(calls, hasLength(1));
      expect(calls.single.last, contains('Invoke-FFPacApply'));
    } finally {
      await directory.delete(recursive: true);
    }
  }, skip: !Platform.isWindows);

  test('OFF still permits own PAC cleanup', () async {
    int calls = 0;
    final service = WindowsChromiumRegistryService.forTesting(
      protectionOff: () => true,
      run: (exe, args) async {
        calls++;
        expect(args.last, contains('Remove-ItemProperty'));
        return ProcessResult(0, 0, '', '');
      },
    );
    await service.clearOwnedPac();
    expect(calls, 1);
  }, skip: !Platform.isWindows);
}
