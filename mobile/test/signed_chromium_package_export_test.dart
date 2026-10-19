import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:six_clean_room/data/browser_extension_asset_manifest.dart';
import 'package:six_clean_room/services/browser_extension_export_service.dart';
import 'package:six_clean_room/services/chrome_extension_identity.dart';

class DiskAssets extends CachingAssetBundle {
  DiskAssets({this.corruptCrx = false});
  final bool corruptCrx;
  @override
  Future<ByteData> load(String key) async {
    final bytes = await File(key).readAsBytes();
    if (corruptCrx && key.endsWith('.crx')) bytes[bytes.length - 1] ^= 1;
    return ByteData.sublistView(bytes);
  }
}

void main() {
  for (final browser in <String>['chrome', 'aside']) {
    test(
      '$browser failed replacement preserves last good folder and CRX',
      () async {
        final temp = await Directory.systemTemp.createTemp('ff-publish-');
        final folder = p.join(temp.path, '${browser}_blocker');
        final catalog = browser == 'chrome'
            ? BrowserExtensionAssetManifest.chrome
            : BrowserExtensionAssetManifest.aside;
        try {
          await Directory(folder).create();
          await File(p.join(folder, 'previous.txt')).writeAsString('keep me');
          await File('$folder.crx').writeAsString('previous signed artifact');
          await expectLater(
            BrowserExtensionExportService.exportVerifiedChromiumPayload(
              browserId: browser,
              assetPaths: catalog,
              targetDir: folder,
              bundle: DiskAssets(corruptCrx: true),
            ),
            throwsFormatException,
          );
          expect(
            await File(p.join(folder, 'previous.txt')).readAsString(),
            'keep me',
          );
          expect(
            await File('$folder.crx').readAsString(),
            'previous signed artifact',
          );
          await BrowserExtensionExportService.exportVerifiedChromiumPayload(
            browserId: browser,
            assetPaths: catalog,
            targetDir: folder,
            bundle: DiskAssets(),
          );
          final previous = await temp
              .list()
              .where(
                (entry) =>
                    entry is Directory &&
                    p.basename(entry.path).contains('.previous-'),
              )
              .toList();
          expect(previous, hasLength(1));
          expect(
            await File(
              p.join(previous.single.path, 'previous.txt'),
            ).readAsString(),
            'keep me',
          );
          expect(
            await File('${previous.single.path}.crx').readAsString(),
            'previous signed artifact',
          );
          expect(await File(p.join(folder, 'manifest.json')).exists(), true);
        } finally {
          await temp.delete(recursive: true);
        }
      },
    );
    test('$browser restores old folder when final CRX publish fails', () async {
      final temp = await Directory.systemTemp.createTemp('ff-rollback-');
      final folder = p.join(temp.path, '${browser}_blocker');
      final catalog = browser == 'chrome'
          ? BrowserExtensionAssetManifest.chrome
          : BrowserExtensionAssetManifest.aside;
      try {
        await Directory(folder).create();
        await File(p.join(folder, 'previous.txt')).writeAsString('keep me');
        // A directory at the CRX destination causes a real filesystem failure
        // after folder replacement; the old payload must be put back.
        await Directory('$folder.crx').create();
        await expectLater(
          BrowserExtensionExportService.exportVerifiedChromiumPayload(
            browserId: browser,
            assetPaths: catalog,
            targetDir: folder,
            bundle: DiskAssets(),
          ),
          throwsA(isA<FileSystemException>()),
        );
        expect(
          await File(p.join(folder, 'previous.txt')).readAsString(),
          'keep me',
        );
        expect(await Directory('$folder.crx').exists(), true);
      } finally {
        await temp.delete(recursive: true);
      }
    });
    test(
      '$browser rewrites stale update URL/version/hash and refuses missing CRX',
      () async {
        final temp = await Directory.systemTemp.createTemp(
          'ff-update-manifest-',
        );
        final folder = p.join(temp.path, '${browser}_blocker');
        final catalog = browser == 'chrome'
            ? BrowserExtensionAssetManifest.chrome
            : BrowserExtensionAssetManifest.aside;
        try {
          await BrowserExtensionExportService.exportVerifiedChromiumPayload(
            browserId: browser,
            assetPaths: catalog,
            targetDir: folder,
            bundle: DiskAssets(),
          );
          final updates = File(p.join(folder, 'updates.xml'));
          await updates.writeAsString(
            "<updatecheck codebase='file:///wrong.crx' version='0.0.1' />",
          );
          await BrowserExtensionExportService.writeSignedChromiumUpdateManifest(
            browserId: browser,
            folder: folder,
            bundle: DiskAssets(),
          );
          final xml = await updates.readAsString();
          final metadata = jsonDecode(
            await File(
              'assets/browser_extensions/$browser/${browser}_blocker.crx.manifest.json',
            ).readAsString(),
          );
          expect(xml, contains("version='${metadata['version']}'"));
          expect(xml, contains(metadata['sha256']));
          expect(xml, contains(File('$folder.crx').absolute.uri.toString()));
          await File('$folder.crx').delete();
          await expectLater(
            BrowserExtensionExportService.writeSignedChromiumUpdateManifest(
              browserId: browser,
              folder: folder,
              bundle: DiskAssets(),
            ),
            throwsA(isA<FileSystemException>()),
          );
          expect(await updates.readAsString(), xml);
          expect(xml, isNot(contains('manifest.json')));
        } finally {
          await temp.delete(recursive: true);
        }
      },
    );
    test(
      '$browser ships a matching signed package and rejects source drift',
      () async {
        final temp = await Directory.systemTemp.createTemp('ff-signed-export-');
        try {
          final folder = p.join(temp.path, '${browser}_blocker');
          await Directory(folder).create();
          final catalog = browser == 'chrome'
              ? BrowserExtensionAssetManifest.chrome
              : BrowserExtensionAssetManifest.aside;
          for (final asset in catalog) {
            await File(asset).copy(p.join(folder, p.basename(asset)));
          }
          final asset =
              'assets/browser_extensions/$browser/${browser}_blocker.crx';
          final metadata = jsonDecode(
            await File('$asset.manifest.json').readAsString(),
          );
          final publicKey = base64Decode(
            ChromeExtensionIdentity.manifestPublicKeyBase64,
          );
          final identity = sha256
              .convert(publicKey)
              .bytes
              .take(16)
              .expand((byte) => <int>[97 + (byte >> 4), 97 + (byte & 15)]);
          expect(
            String.fromCharCodes(identity),
            ChromeExtensionIdentity.extensionId,
          );
          await BrowserExtensionExportService.exportSignedChromiumPackage(
            browserId: browser,
            folder: folder,
            bundle: DiskAssets(),
          );
          final exported = File('$folder.crx');
          final bytes = await exported.readAsBytes();
          expect(sha256.convert(bytes).toString(), metadata['sha256']);
          expect(
            ChromeExtensionIdentity.readCrx3Identity(bytes),
            ChromeExtensionIdentity.extensionId,
          );
          await exported.delete();
          await expectLater(
            BrowserExtensionExportService.exportSignedChromiumPackage(
              browserId: browser,
              folder: folder,
              bundle: DiskAssets(corruptCrx: true),
            ),
            throwsFormatException,
          );
          expect(await exported.exists(), isFalse);
          await File(
            p.join(folder, 'background.js'),
          ).writeAsString('// stale source');
          await expectLater(
            BrowserExtensionExportService.exportSignedChromiumPackage(
              browserId: browser,
              folder: folder,
              bundle: DiskAssets(),
            ),
            throwsFormatException,
          );
          expect(await exported.exists(), isFalse);
        } finally {
          await temp.delete(recursive: true);
        }
      },
    );
  }
}
