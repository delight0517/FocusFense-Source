import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'firefox_xpi_packager.dart';
import 'mozilla_credential_store.dart';
import 'mozilla_signing_client.dart';
import 'windows_firefox_extension_install_service.dart';

/// Authenticated app-control adapter. Secrets are read from the existing vault,
/// never accepted as action arguments or returned in JSON.
class BrowserManagementControl {
  BrowserManagementControl({
    MozillaCredentialStore? credentialStore,
    MozillaSigningClient? signingClient,
    Future<FirefoxManagedRepairReport> Function()? inspectFirefox,
    Future<FirefoxManagedRepairReport> Function(bool requestElevation)?
    repairFirefox,
    Future<Map<String, Object?>> Function()? openFirefoxUpdate,
    Future<void> Function(MozillaSignedDownload)? adoptDownload,
    Future<Directory> Function()? stagingDirectory,
  }) : _store = credentialStore ?? MozillaCredentialStore(),
       _signer = signingClient ?? MozillaSigningClient(),
       _inspect =
           inspectFirefox ??
           WindowsFirefoxExtensionInstallService.instance.inspectManaged,
       _repair =
           repairFirefox ??
           ((elevate) => WindowsFirefoxExtensionInstallService.instance
               .repairManaged(requestElevation: elevate)),
       _openUpdate =
           openFirefoxUpdate ??
           (() async =>
               (await WindowsFirefoxExtensionInstallService.instance
                       .requestNativeUpdate(userInitiated: true))
                   .toJson()),
       _adopt =
           adoptDownload ?? FirefoxXpiPackager.instance.adoptApprovedDownload,
       _staging =
           stagingDirectory ??
           (() => Directory(
             p.join(
               Platform.environment['LOCALAPPDATA'] ??
                   Directory.systemTemp.path,
               'FocusFense',
               'mozilla-staging',
             ),
           ).create(recursive: true));

  static final instance = BrowserManagementControl();
  static const actions = <String, String>{
    'browser.status': 'Read browser management status',
    'browser.firefox.inspect': 'Inspect Firefox profiles without changing them',
    'browser.firefox.prepare': 'Prepare signed Firefox protection without UAC',
    'browser.firefox.repair': 'Apply Firefox repair with explicit Windows UAC',
    'browser.firefox.openUpdate':
        'Explicitly request the verified Firefox extension update; preserve browser confirmation',
    'browser.mozilla.status': 'Read encrypted Mozilla credential status',
    'browser.mozilla.credentialsPrompt':
        'Open the FocusFense Mozilla credential dialog; credentials stay in the app',
    'browser.mozilla.validate': 'Validate stored Mozilla credentials',
    'browser.mozilla.submit':
        'Submit a new local extension version for signing',
    'browser.mozilla.signingStatus': 'Read Mozilla review and signing status',
    'browser.mozilla.download':
        'Download and select an approved signed release',
    'browser.mozilla.backup': 'Back up encrypted Mozilla credentials',
    'browser.mozilla.restore': 'Restore a hash-verified encrypted backup',
    'browser.mozilla.backupFolder': 'Set the encrypted backup destination',
  };
  static Future<Map<String, Object?>> status() =>
      instance.execute('browser.status', const {});
  static Future<Map<String, Object?>> run(
    String action,
    Map<String, Object?> args,
  ) => instance.execute(action, args);
  static const argumentSchemas = <String, Object?>{
    'browser.status': <String, Object?>{},
    'browser.firefox.inspect': <String, Object?>{},
    'browser.firefox.prepare': <String, Object?>{},
    'browser.firefox.repair': <String, Object?>{},
    'browser.firefox.openUpdate': <String, Object?>{},
    'browser.mozilla.status': <String, Object?>{},
    'browser.mozilla.credentialsPrompt': <String, Object?>{},
    'browser.mozilla.validate': <String, Object?>{},
    'browser.mozilla.submit': {'path': 'required absolute local XPI/ZIP path'},
    'browser.mozilla.signingStatus': {
      'versionId': 'optional positive integer; saved receipt used by default',
    },
    'browser.mozilla.download': {
      'versionId': 'optional positive integer',
      'version': 'optional numeric extension version',
    },
    'browser.mozilla.backup': {
      'directory': 'optional absolute backup directory',
    },
    'browser.mozilla.restore': {
      'path': 'required absolute ciphertext backup path',
      'sha256': 'required 64 hexadecimal digest',
    },
    'browser.mozilla.backupFolder': {
      'directory': 'required absolute backup directory',
    },
  };
  static bool handles(String action) => argumentSchemas.containsKey(action);

  static void validate(String action, Map<String, Object?> args) {
    if (!handles(action)) {
      throw const FormatException('Unknown browser management action');
    }
    final schema = argumentSchemas[action] as Map;
    if (args.keys.any((key) => !schema.containsKey(key))) {
      throw const FormatException('Unknown browser management arguments');
    }
    for (final field in ['path', 'directory']) {
      final required =
          (action == 'browser.mozilla.submit' && field == 'path') ||
          (action == 'browser.mozilla.restore' && field == 'path') ||
          (action == 'browser.mozilla.backupFolder' && field == 'directory');
      final value = args[field];
      if ((required && value == null) ||
          (value != null &&
              (value is! String ||
                  value.length > 4096 ||
                  value.contains('\u0000') ||
                  !p.isAbsolute(value)))) {
        throw const FormatException('An absolute local path is required');
      }
    }
    if (args.containsKey('versionId') &&
        (args['versionId'] is! int || (args['versionId'] as int) <= 0)) {
      throw const FormatException('Positive versionId required');
    }
    if (args.containsKey('version') &&
        (args['version'] is! String ||
            !RegExp(
              r'^[0-9]+(?:\.[0-9]+){0,3}$',
            ).hasMatch(args['version'] as String))) {
      throw const FormatException('Numeric extension version required');
    }
    if (action == 'browser.mozilla.restore' &&
        (args['sha256'] is! String ||
            !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(args['sha256'] as String))) {
      throw const FormatException('SHA-256 required');
    }
  }

  final MozillaCredentialStore _store;
  final MozillaSigningClient _signer;
  final Future<FirefoxManagedRepairReport> Function() _inspect;
  final Future<FirefoxManagedRepairReport> Function(bool) _repair;
  final Future<Map<String, Object?>> Function() _openUpdate;
  final Future<void> Function(MozillaSignedDownload) _adopt;
  final Future<Directory> Function() _staging;

  static Map<String, Object?> _firefox(
    FirefoxManagedRepairReport report, {
    bool ok = true,
  }) => {
    'ok': ok,
    'maintenanceComplete': report.ok,
    'filesPrepared': report.filesPrepared,
    'rulesSnapshotPrepared': report.rulesSnapshotPrepared,
    'policiesApplied': report.policiesApplied,
    'expectedVersion': report.expectedVersion,
    'expectedSha256': report.expectedSha256,
    'profileTotal': report.profileTotal,
    'activeProfileCount': report.activeProfileCount,
    'activationVerified': report.activationVerified,
    'metadataMatchesExpected': report.activationVerified,
    'liveBackgroundVerified': false,
    'currentTabVerified': false,
    'behaviorVerified': false,
    'activationVerificationScope':
        'Legacy activationVerified describes profile metadata and XPI bytes only; live execution is not verified',
    'firefoxRunning': report.firefoxRunning,
    'browserConfirmationNeeded': report.browserConfirmationNeeded,
    'nextRestartNeeded': report.nextRestartNeeded,
    'preparedXpiPath': report.preparedXpiPath,
    'profiles': [
      for (final profile in report.profiles)
        {
          'profilePath': profile.profilePath,
          'name': profile.name,
          'version': profile.version,
          'active': profile.active,
          'signedState': profile.signedState,
          'sha256': profile.sha256,
          'xpiPath': profile.xpiPath,
        },
    ],
    'verificationScope':
        'profile metadata and exact XPI bytes; no live page blocking probe',
  };

  Future<Map<String, Object?>> _credentialStatus() async {
    final value = await _store.status();
    return {
      'exists': value.exists,
      'readable': value.readable,
      'path': value.path,
      'account': MozillaCredentialStore.expectedAccount,
      'addonId': MozillaCredentialStore.addonId,
      'recoveryScope': 'original Windows user/profile DPAPI keys',
    };
  }

  Future<Map<String, Object?>> execute(
    String action,
    Map<String, Object?> args,
  ) async {
    validate(action, args);
    try {
      final prefs = await SharedPreferences.getInstance();
      final versionId =
          args['versionId'] as int? ??
          prefs.getInt('mozilla_signing_version_id_v1') ??
          0;
      final version =
          args['version'] as String? ??
          prefs.getString('mozilla_signing_version_v1') ??
          '';
      if ((action == 'browser.mozilla.signingStatus' && versionId <= 0) ||
          (action == 'browser.mozilla.download' &&
              (versionId <= 0 || version.isEmpty))) {
        return {
          'ok': false,
          'error': 'signing_receipt_missing',
          'nextAction':
              'Submit the intended extension version, or supply its actual positive versionId (and version for download).',
        };
      }
      switch (action) {
        case 'browser.status':
          return {
            'ok': true,
            'credentials': await _credentialStatus(),
            'firefox': _firefox(await _inspect()),
            'signingReceipt': {
              'available': versionId > 0 && version.isNotEmpty,
              'versionId': versionId,
              'version': version.isEmpty ? null : version,
            },
            'backupFolder': prefs.getString('mozilla_backup_folder_v1'),
            'lastBackupPath': prefs.getString('mozilla_last_backup_path_v1'),
            'lastBackupSha256': prefs.getString('mozilla_last_backup_hash_v1'),
          };
        case 'browser.firefox.inspect':
          return _firefox(await _inspect());
        case 'browser.firefox.prepare':
          final report = await _repair(false);
          return _firefox(
            report,
            ok: report.filesPrepared && report.rulesSnapshotPrepared,
          );
        case 'browser.firefox.repair':
          final report = await _repair(true);
          return _firefox(report, ok: report.policiesApplied);
        case 'browser.firefox.openUpdate':
          final update = await _openUpdate();
          return {
            ...update,
            'ok': update['launchRequested'] == true,
            'liveBackgroundVerified': false,
            'currentTabVerified': false,
            'behaviorVerified': false,
            'verificationScope':
                'Launch request only; visible native dialog and live extension activation require separate verification',
          };
        case 'browser.mozilla.status':
          return {'ok': true, ...await _credentialStatus()};
        case 'browser.mozilla.backupFolder':
          await prefs.setString(
            'mozilla_backup_folder_v1',
            args['directory'] as String,
          );
          return {
            'ok': true,
            'directory': args['directory'],
            'cloudUploadVerified': false,
          };
        case 'browser.mozilla.backup':
          final directory =
              args['directory'] as String? ??
              prefs.getString('mozilla_backup_folder_v1');
          // Always keep a local recovery copy before an optional sync folder copy.
          final local = await _store.backupCiphertext();
          final backup = directory == null
              ? local
              : await _store.backupCiphertext(directory: directory);
          await prefs.setString('mozilla_last_backup_path_v1', backup.path);
          await prefs.setString('mozilla_last_backup_hash_v1', backup.sha256);
          return {
            'ok': true,
            'path': backup.path,
            'sha256': backup.sha256,
            'localBackupPath': local.path,
            'cloudUploadVerified': false,
          };
        case 'browser.mozilla.restore':
          await _store.restoreVerifiedBackup(
            path: args['path'] as String,
            expectedSha256: args['sha256'] as String,
          );
          return {'ok': true, ...await _credentialStatus()};
        default:
          final credentials = await _store.load();
          if (action == 'browser.mozilla.validate') {
            await _signer.validateCredentials(
              issuer: credentials.issuer,
              secret: credentials.secret,
            );
            return {
              'ok': true,
              'authenticated': true,
              'accountEmailVerified': false,
            };
          }
          if (action == 'browser.mozilla.submit') {
            final path = args['path'] as String;
            final submittedVersion = await _signer.packageVersion(path);
            if (versionId > 0 && submittedVersion == version) {
              return {
                'ok': false,
                'error': 'version_already_recorded',
                'versionId': versionId,
                'version': version,
              };
            }
            final receipt = await _signer.submitPackage(
              path: path,
              issuer: credentials.issuer,
              secret: credentials.secret,
            );
            await prefs.setInt(
              'mozilla_signing_version_id_v1',
              receipt.versionId,
            );
            await prefs.setString(
              'mozilla_signing_version_v1',
              receipt.version,
            );
            return {
              'ok': true,
              'versionId': receipt.versionId,
              'amoVersionId': receipt.versionId,
              'version': receipt.version,
            };
          }
          if (action == 'browser.mozilla.signingStatus') {
            final status = await _signer.status(
              versionId: versionId,
              issuer: credentials.issuer,
              secret: credentials.secret,
            );
            return {
              'ok': true,
              'versionId': status.versionId,
              'version': status.version,
              'fileStatus': status.fileStatus,
              'mozillaInternalCertificate': status.mozillaInternalCertificate,
              'readyForSignedDownload': status.readyForSignedDownload,
              'urlHost': status.downloadUrl?.host,
            };
          }
          if (action == 'browser.mozilla.download') {
            final stage = await _staging();
            final download = await _signer.downloadApproved(
              versionId: versionId,
              expectedVersion: version,
              issuer: credentials.issuer,
              secret: credentials.secret,
              stagingDir: stage.path,
            );
            await _adopt(download);
            await prefs.setInt(
              'mozilla_signing_version_id_v1',
              download.versionId,
            );
            await prefs.setString(
              'mozilla_signing_version_v1',
              download.version,
            );
            return {
              'ok': true,
              'versionId': download.versionId,
              'version': download.version,
              'sha256': download.sha256,
              'path': download.path,
              'adopted': true,
              'policiesApplied': false,
              'activationVerified': false,
              'nextAction': 'browser.firefox.repair',
            };
          }
          throw const FormatException('Unknown browser management action');
      }
    } on MozillaSigningException catch (error) {
      return {
        'ok': false,
        'error': error.code,
        if (error.httpStatus != null) 'httpStatus': error.httpStatus,
      };
    } catch (_) {
      return {'ok': false, 'error': 'browser_management_failed'};
    }
  }
}
