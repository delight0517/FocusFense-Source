import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/services/firefox_xpi_packager.dart';
import 'package:six_clean_room/services/mozilla_signing_client.dart';

Uint8List fixture(String version) {
  final archive = Archive();
  final manifest = utf8.encode(
    jsonEncode({
      'version': version,
      'browser_specific_settings': {
        'gecko': {'id': MozillaSigningClient.addonId},
      },
    }),
  );
  archive.addFile(ArchiveFile('manifest.json', manifest.length, manifest));
  for (final name in ['mozilla.rsa', 'mozilla.sf', 'manifest.mf']) {
    archive.addFile(ArchiveFile('META-INF/$name', 1, [0]));
  }
  return Uint8List.fromList(ZipEncoder().encode(archive));
}

void main() {
  late Directory temp, releases, output;
  late FirefoxXpiPackager packager;
  final bundled = fixture('1.0.22');
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ff-pinned-test-');
    releases = Directory('${temp.path}/releases');
    output = Directory('${temp.path}/output');
    packager = FirefoxXpiPackager.forTesting(
      () async => bundled,
      output,
      releases: releases,
    );
  });
  tearDown(() async => temp.delete(recursive: true));

  Future<MozillaSignedDownload> candidate(String version) async {
    final bytes = fixture(version);
    final path = '${temp.path}/candidate-$version.xpi';
    await File(path).writeAsBytes(bytes);
    return MozillaSignedDownload(
      path: path,
      sha256: sha256.convert(bytes).toString(),
      versionId: 123,
      version: version,
    );
  }

  test(
    'approved release selected durably and repair preserves approved bytes',
    () async {
      final download = await candidate('1.0.23');
      await packager.adoptApprovedDownload(download);
      final expected = await File(download.path).readAsBytes();
      final restarted = FirefoxXpiPackager.forTesting(
        () async => bundled,
        output,
        releases: releases,
      );
      expect(await restarted.trustedSignedVersion(), '1.0.23');
      final deployed = await restarted.ensureProgramDataXpi(
        sourceFolder: 'unused',
      );
      expect(await deployed.readAsBytes(), expected);
      await deployed.writeAsString('tampered');
      expect(await restarted.isBundledSignedCopy(deployed), false);
      await restarted.ensureProgramDataXpi(sourceFolder: 'unused');
      expect(await deployed.readAsBytes(), expected);
      expect(await restarted.isBundledSignedCopy(deployed), true);
      expect(await File(download.path).readAsBytes(), expected);
    },
  );

  test('downgrades refused and previous immutable release retained', () async {
    await packager.adoptApprovedDownload(await candidate('1.0.23'));
    await expectLater(
      packager.adoptApprovedDownload(await candidate('1.0.21')),
      throwsStateError,
    );
    await packager.adoptApprovedDownload(await candidate('1.0.24'));
    expect(await packager.trustedSignedVersion(), '1.0.24');
    expect(
      await releases.list().where((f) => f.path.endsWith('.xpi')).length,
      2,
    );
  });

  test(
    'receipt tampering cannot replace selection; damaged pin safely falls back',
    () async {
      final download = await candidate('1.0.23');
      await expectLater(
        packager.adoptApprovedDownload(
          MozillaSignedDownload(
            path: download.path,
            sha256: '0' * 64,
            versionId: 123,
            version: download.version,
          ),
        ),
        throwsStateError,
      );
      expect(await packager.trustedSignedBytes(), bundled);
      await packager.adoptApprovedDownload(download);
      final selected = await releases
          .list()
          .where((f) => f.path.endsWith('.xpi'))
          .first;
      await File(selected.path).writeAsString('tampered');
      expect(await packager.trustedSignedBytes(), bundled);
      expect(await packager.trustedSignedVersion(), '1.0.22');
    },
  );
}
