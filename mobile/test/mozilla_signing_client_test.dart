import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/services/mozilla_signing_client.dart';

class FakeTransport implements MozillaSigningTransport {
  final replies = <MozillaSigningResponse>[];
  final calls =
      <
        ({String method, Uri uri, Map<String, String> headers, List<int>? body})
      >[];
  @override
  Future<MozillaSigningResponse> send(
    String method,
    Uri uri, {
    required Map<String, String> headers,
    List<int>? body,
  }) async {
    calls.add((method: method, uri: uri, headers: headers, body: body));
    return replies.removeAt(0);
  }

  void json(Object data, {int status = 200}) => replies.add(
    MozillaSigningResponse(status, utf8.encode(jsonEncode(data))),
  );
}

List<int> package({
  String id = MozillaSigningClient.addonId,
  String version = '1.0.22',
  bool signed = false,
}) {
  final archive = Archive();
  final manifest = utf8.encode(
    jsonEncode({
      'version': version,
      'browser_specific_settings': {
        'gecko': {'id': id},
      },
    }),
  );
  archive.addFile(ArchiveFile('manifest.json', manifest.length, manifest));
  if (signed) {
    for (final name in ['mozilla.rsa', 'mozilla.sf', 'manifest.mf']) {
      archive.addFile(ArchiveFile('META-INF/$name', 1, [0]));
    }
  }
  return ZipEncoder().encode(archive);
}

Object state({
  String status = 'public',
  String url = 'https://addons.mozilla.org/file.xpi',
  String version = '1.0.22',
  bool internal = false,
}) => {
  'id': 123,
  'version': version,
  'file': {
    'status': status,
    'url': url,
    'is_mozilla_signed_extension': internal,
  },
};

void main() {
  late Directory directory;
  late FakeTransport transport;
  late MozillaSigningClient client;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('ff-amo-test-');
    transport = FakeTransport();
    client = MozillaSigningClient(
      transport: transport,
      wait: (_) async {},
      processingAttempts: 2,
    );
  });
  tearDown(() async => directory.delete(recursive: true));

  test(
    'credential validation is read-only; auth and rate errors reveal no body',
    () async {
      for (final (status, code) in [
        (401, 'invalid_credentials'),
        (429, 'rate_limited'),
      ]) {
        transport.json({'secret': 'fixture-remote-secret'}, status: status);
        await expectLater(
          client.validateCredentials(
            issuer: 'fixture-issuer',
            secret: 'fixture-secret',
          ),
          throwsA(
            isA<MozillaSigningException>()
                .having((e) => e.code, 'code', code)
                .having(
                  (e) => e.toString().contains('fixture'),
                  'safe message',
                  false,
                ),
          ),
        );
      }
      expect(transport.calls.every((c) => c.method == 'GET'), true);
    },
  );

  test(
    'submit validates local identity before network and sends unlisted package',
    () async {
      final file = File('${directory.path}/candidate.xpi');
      await file.writeAsBytes(package(id: 'wrong@example.invalid'));
      await expectLater(
        client.submitPackage(
          path: file.path,
          issuer: 'fixture',
          secret: 'fixture',
        ),
        throwsA(isA<MozillaSigningException>()),
      );
      expect(transport.calls, isEmpty);
      await file.writeAsBytes(package());
      transport.json({'uuid': 'fixture-upload-id'});
      transport.json({'processed': false});
      transport.json({'processed': true, 'valid': true});
      transport.json({'id': 123, 'version': '1.0.22'});
      final receipt = await client.submitPackage(
        path: file.path,
        issuer: 'fixture',
        secret: 'fixture',
      );
      expect(receipt.versionId, 123);
      expect(latin1.decode(transport.calls.first.body!), contains('unlisted'));
      expect(transport.calls.last.uri.path, endsWith('/versions/'));
    },
  );

  test('processing bounded and pending means no version submitted', () async {
    final file = await File(
      '${directory.path}/candidate.xpi',
    ).writeAsBytes(package());
    transport.json({'uuid': 'fixture-upload-id'});
    transport.json({'processed': false});
    transport.json({'processed': false});
    await expectLater(
      client.submitPackage(
        path: file.path,
        issuer: 'fixture',
        secret: 'fixture',
      ),
      throwsA(
        isA<MozillaSigningException>().having(
          (e) => e.code,
          'code',
          'processing_pending',
        ),
      ),
    );
    expect(transport.calls.where((c) => c.method == 'POST').length, 1);
  });

  test(
    'public is ready despite false Mozilla internal certificate, unreviewed is pending',
    () async {
      transport.json(state(internal: false));
      expect(
        (await client.status(
          versionId: 123,
          issuer: 'fixture',
          secret: 'fixture',
        )).approved,
        true,
      );
      transport.json(state(status: 'unreviewed', internal: true));
      expect(
        (await client.status(
          versionId: 123,
          issuer: 'fixture',
          secret: 'fixture',
        )).approved,
        false,
      );
    },
  );

  test(
    'signed staging strips authorization on CDN redirect and retains package hash',
    () async {
      transport.json(state());
      transport.replies.add(
        const MozillaSigningResponse(
          302,
          [],
          location: 'https://addons.cdn.mozilla.net/file.xpi',
        ),
      );
      transport.replies.add(MozillaSigningResponse(200, package(signed: true)));
      final result = await client.downloadApproved(
        versionId: 123,
        expectedVersion: '1.0.22',
        issuer: 'fixture',
        secret: 'fixture',
        stagingDir: directory.path,
      );
      expect(await File(result.path).exists(), true);
      expect(result.sha256.length, 64);
      expect(transport.calls[1].headers.containsKey('Authorization'), true);
      expect(transport.calls[2].headers.containsKey('Authorization'), false);
    },
  );

  test(
    'external redirects rejected without request or file; unsigned packages rejected',
    () async {
      transport.json(state());
      transport.replies.add(
        const MozillaSigningResponse(
          302,
          [],
          location: 'https://evil.invalid/file.xpi',
        ),
      );
      await expectLater(
        client.downloadApproved(
          versionId: 123,
          expectedVersion: '1.0.22',
          issuer: 'fixture',
          secret: 'fixture',
          stagingDir: directory.path,
        ),
        throwsA(isA<MozillaSigningException>()),
      );
      expect(transport.calls.length, 2);
      transport.json(state());
      transport.replies.add(MozillaSigningResponse(200, package()));
      await expectLater(
        client.downloadApproved(
          versionId: 123,
          expectedVersion: '1.0.22',
          issuer: 'fixture',
          secret: 'fixture',
          stagingDir: directory.path,
        ),
        throwsA(isA<MozillaSigningException>()),
      );
      expect(await directory.list().isEmpty, true);
    },
  );
}
