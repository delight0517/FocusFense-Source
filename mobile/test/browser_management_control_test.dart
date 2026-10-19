import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:six_clean_room/services/browser_management_control.dart';
import 'package:six_clean_room/services/mozilla_credential_store.dart';
import 'package:six_clean_room/services/mozilla_signing_client.dart';
import 'package:six_clean_room/services/windows_firefox_extension_install_service.dart';

class FakeVault extends MozillaCredentialStore {
  FakeVault()
    : super(
        storePath: r'C:\fixture\vault',
        backupDirectory: r'C:\fixture\backups',
      );
  final backups = <String?>[];
  String? restoredHash;
  @override
  Future<MozillaCredentialStatus> status() async =>
      MozillaCredentialStatus(true, true, storePath);
  @override
  Future<MozillaCredentials> load() async =>
      const MozillaCredentials('fixture-issuer', 'fixture-secret');
  @override
  Future<MozillaCredentialBackup> backupCiphertext({String? directory}) async {
    backups.add(directory);
    return MozillaCredentialBackup(
      '${directory ?? backupDirectory}/backup.json',
      'a' * 64,
    );
  }

  @override
  Future<void> restoreVerifiedBackup({
    required String path,
    required String expectedSha256,
  }) async {
    restoredHash = expectedSha256;
  }
}

class FakeSigner extends MozillaSigningClient {
  int validates = 0, submits = 0, statusReads = 0, downloads = 0;
  bool deny = false;
  @override
  Future<void> validateCredentials({
    required String issuer,
    required String secret,
  }) async {
    validates++;
    if (deny)
      throw const MozillaSigningException(
        'invalid_credentials',
        httpStatus: 401,
      );
  }

  @override
  Future<String> packageVersion(String path) async => '1.0.23';
  @override
  Future<MozillaSigningReceipt> submitPackage({
    required String path,
    required String issuer,
    required String secret,
  }) async {
    submits++;
    return const MozillaSigningReceipt(versionId: 456, version: '1.0.23');
  }

  @override
  Future<MozillaSigningStatus> status({
    required int versionId,
    required String issuer,
    required String secret,
  }) async {
    statusReads++;
    return MozillaSigningStatus(
      versionId: versionId,
      version: '1.0.23',
      fileStatus: 'public',
      mozillaInternalCertificate: false,
      downloadUrl: Uri.parse(
        'https://addons.mozilla.org/file?token=fixture-private-token',
      ),
    );
  }

  @override
  Future<MozillaSignedDownload> downloadApproved({
    required int versionId,
    required String expectedVersion,
    required String issuer,
    required String secret,
    required String stagingDir,
  }) async {
    downloads++;
    return MozillaSignedDownload(
      path: '$stagingDir/signed.xpi',
      sha256: 'b' * 64,
      versionId: versionId,
      version: expectedVersion,
    );
  }
}

void main() {
  late FakeVault vault;
  late FakeSigner signer;
  late BrowserManagementControl control;
  final elevations = <bool>[];
  final adopted = <MozillaSignedDownload>[];
  var updateRequests = 0;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    elevations.clear();
    adopted.clear();
    updateRequests = 0;
    vault = FakeVault();
    signer = FakeSigner();
    control = BrowserManagementControl(
      credentialStore: vault,
      signingClient: signer,
      inspectFirefox: () async =>
          const FirefoxManagedRepairReport(firefoxRunning: true),
      repairFirefox: (elevate) async {
        elevations.add(elevate);
        return const FirefoxManagedRepairReport(filesPrepared: true);
      },
      openFirefoxUpdate: () async {
        updateRequests++;
        return {
          'launchRequested': true,
          'nativeDialogVerified': false,
          'activationVerified': false,
          'requiresUserConfirmation': true,
        };
      },
      adoptDownload: (download) async {
        adopted.add(download);
      },
      stagingDirectory: () async => Directory(r'C:\fixture\stage'),
    );
  });
  tearDown(() => signer.close());

  test('missing receipt never looks up a stale signing version', () async {
    final status = await control.execute('browser.status', {});
    expect((status['signingReceipt'] as Map)['available'], false);
    expect((status['signingReceipt'] as Map)['versionId'], 0);
    expect((status['signingReceipt'] as Map)['version'], isNull);
    for (final action in [
      'browser.mozilla.signingStatus',
      'browser.mozilla.download',
    ]) {
      expect(
        (await control.execute(action, {}))['error'],
        'signing_receipt_missing',
      );
    }
    expect(signer.statusReads, 0);
    expect(signer.downloads, 0);
    expect(
      (await control.execute('browser.mozilla.signingStatus', {
        'versionId': 456,
      }))['ok'],
      true,
    );
    expect(signer.statusReads, 1);
  });

  test(
    'only explicit update action requests native UI and never claims activation',
    () async {
      await control.execute('browser.status', {});
      await control.execute('browser.firefox.inspect', {});
      await control.execute('browser.firefox.prepare', {});
      expect(updateRequests, 0);
      final result = await control.execute('browser.firefox.openUpdate', {});
      expect(updateRequests, 1);
      expect(result['ok'], true);
      expect(result['nativeDialogVerified'], false);
      expect(result['activationVerified'], false);
      expect(result['liveBackgroundVerified'], false);
      expect(result['currentTabVerified'], false);
      expect(result['behaviorVerified'], false);
      expect(result['requiresUserConfirmation'], true);
      expect(
        () => BrowserManagementControl.validate('browser.firefox.openUpdate', {
          'path': r'C:\\other.xpi',
        }),
        throwsFormatException,
      );
    },
  );

  test(
    'schemas reject secrets, unknown args and invalid local paths before work',
    () async {
      expect(
        () => BrowserManagementControl.validate('browser.mozilla.validate', {
          'secret': 'fixture',
        }),
        throwsFormatException,
      );
      expect(
        () => BrowserManagementControl.validate('browser.mozilla.submit', {
          'path': 'relative.xpi',
        }),
        throwsFormatException,
      );
      expect(
        () => BrowserManagementControl.validate('browser.mozilla.restore', {
          'path': r'C:\fixture\backup.json',
          'sha256': 'bad',
        }),
        throwsFormatException,
      );
      expect(
        () => BrowserManagementControl.validate('browser.firefox.prepare', {
          'requestElevation': true,
        }),
        throwsFormatException,
      );
      expect(
        BrowserManagementControl.actions.keys.toSet(),
        BrowserManagementControl.argumentSchemas.keys.toSet(),
      );
    },
  );

  test(
    'read-only status never elevates or opens UI and safe errors exclude secrets',
    () async {
      final status = await control.execute('browser.status', {});
      expect(status['ok'], true);
      expect(elevations, isEmpty);
      expect(vault.backups, isEmpty);
      expect(jsonEncode(status), isNot(contains('fixture-secret')));
      signer.deny = true;
      expect(await control.execute('browser.mozilla.validate', {}), {
        'ok': false,
        'error': 'invalid_credentials',
        'httpStatus': 401,
      });
    },
  );

  test(
    'prepare never requests UAC; only explicit repair requests it',
    () async {
      await control.execute('browser.firefox.prepare', {});
      await control.execute('browser.firefox.repair', {});
      expect(elevations, [false, true]);
    },
  );

  test(
    'submission persists UI receipt, refuses repeat and status hides private URL',
    () async {
      expect(
        (await control.execute('browser.mozilla.submit', {
          'path': r'C:\fixture\candidate.xpi',
        }))['versionId'],
        456,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('mozilla_signing_version_v1'), '1.0.23');
      expect(prefs.getInt('mozilla_signing_version_id_v1'), 456);
      expect(
        (await control.execute('browser.mozilla.submit', {
          'path': r'C:\fixture\candidate.xpi',
        }))['error'],
        'version_already_recorded',
      );
      expect(signer.submits, 1);
      final status = await control.execute('browser.mozilla.signingStatus', {});
      expect(status['readyForSignedDownload'], true);
      expect(jsonEncode(status), isNot(contains('fixture-private-token')));
    },
  );

  test(
    'download adopts approved artifact without elevation or activation claim',
    () async {
      final result = await control.execute('browser.mozilla.download', {
        'versionId': 456,
        'version': '1.0.23',
      });
      expect(result['adopted'], true);
      expect(result['activationVerified'], false);
      expect(elevations, isEmpty);
      expect(adopted.single.versionId, 456);
    },
  );

  test(
    'backup keeps local copy plus configured folder; restore requires digest',
    () async {
      await control.execute('browser.mozilla.backupFolder', {
        'directory': r'C:\fixture\drive',
      });
      final result = await control.execute('browser.mozilla.backup', {});
      expect(vault.backups, [null, r'C:\fixture\drive']);
      expect(result['cloudUploadVerified'], false);
      await control.execute('browser.mozilla.restore', {
        'path': r'C:\fixture\backup.json',
        'sha256': 'a' * 64,
      });
      expect(vault.restoredHash, 'a' * 64);
    },
  );
}
