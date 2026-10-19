import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:six_clean_room/services/mozilla_credential_store.dart';

void main() {
  late Directory temporary;
  late MozillaCredentialStore store;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp(
      'focusfense-credential-test-',
    );
    store = MozillaCredentialStore(
      storePath: p.join(temporary.path, 'vault.json'),
      backupDirectory: p.join(temporary.path, 'backups'),
    );
  });
  tearDown(() async {
    await temporary.delete(recursive: true);
  });

  test(
    'real DPAPI round trip and immutable backup preserve previous rotation',
    () async {
      expect((await store.status()).exists, false);
      await store.save(issuer: 'test-issuer-only', secret: 'test-secret-only');
      expect((await store.load()).issuer, 'test-issuer-only');
      expect((await store.load()).toString(), isNot(contains('test-secret')));
      final text = await File(store.storePath).readAsString();
      expect(text, isNot(contains('test-secret-only')));
      final backup = await store.backupCiphertext();
      expect(backup.cloudUploadVerified, false);
      await store.save(issuer: 'new-test-issuer', secret: 'new-test-secret');
      expect((await store.load()).issuer, 'new-test-issuer');
      expect(await File(backup.path).readAsString(), text);
      await store.restoreVerifiedBackup(
        path: backup.path,
        expectedSha256: backup.sha256,
      );
      expect((await store.load()).issuer, 'test-issuer-only');
      expect(await Directory(store.backupDirectory).list().length, 3);
    },
    skip: !Platform.isWindows,
  );

  test('identity and tampering fail without replacing valid store', () async {
    await store.save(issuer: 'test-issuer-only', secret: 'test-secret-only');
    final original = await File(store.storePath).readAsString();
    await expectLater(
      store.save(issuer: 'test', secret: 'test', account: 'wrong'),
      throwsA(isA<MozillaCredentialException>()),
    );
    expect(await File(store.storePath).readAsString(), original);
    final backup = await store.backupCiphertext();
    await expectLater(
      store.restoreVerifiedBackup(path: backup.path, expectedSha256: '0' * 64),
      throwsA(isA<MozillaCredentialException>()),
    );
    final data = jsonDecode(original) as Map<String, dynamic>;
    data['ciphertext'] = base64Encode(List.filled(32, 0));
    await File(store.storePath).writeAsString(jsonEncode(data));
    expect((await store.status()).readable, false);
    await expectLater(store.load(), throwsA(isA<MozillaCredentialException>()));
  }, skip: !Platform.isWindows);
}
