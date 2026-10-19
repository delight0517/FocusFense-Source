import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/services/firefox_xpi_packager.dart';

void main() {
  test('missing or unsigned asset preserves existing deployment', () async {
    final dir = await Directory.systemTemp.createTemp('ff-signed-');
    try {
      final dest = File('${dir.path}/${FirefoxXpiPackager.kXpiFileName}');
      await dest.writeAsString('keep existing');
      for (final loader in <Future<Uint8List> Function()>[
        () async => throw StateError('asset unavailable'),
        () async => Uint8List.fromList(List.filled(100, 0)),
      ]) {
        final packager = FirefoxXpiPackager.forTesting(loader, dir);
        await expectLater(
          packager.ensureProgramDataXpi(sourceFolder: dir.path),
          throwsStateError,
        );
        expect(await dest.readAsString(), 'keep existing');
      }
    } finally {
      await dir.delete(recursive: true);
    }
  });
  test(
    'deploys unchanged signed bytes, replaces bad copy and rejects profile mismatch',
    () async {
      final bytes = await File(
        FirefoxXpiPackager.kBundledSignedAsset,
      ).readAsBytes();
      final dir = await Directory.systemTemp.createTemp('ff-signed-');
      try {
        final packager = FirefoxXpiPackager.forTesting(() async => bytes, dir);
        final dest = await packager.ensureProgramDataXpi(
          sourceFolder: dir.path,
        );
        expect(await dest.readAsBytes(), bytes);
        await dest.writeAsString('unsigned replacement');
        expect(await packager.isBundledSignedCopy(dest), false);
        await packager.ensureProgramDataXpi(sourceFolder: dir.path);
        expect(await packager.isBundledSignedCopy(dest), true);
        expect((await dir.list().toList()).length, 1);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );
}
