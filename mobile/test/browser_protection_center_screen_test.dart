import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:six_clean_room/screens/browser_protection_center_screen.dart';
import 'package:six_clean_room/services/mozilla_credential_store.dart';
import 'package:six_clean_room/services/mozilla_signing_client.dart';
import 'package:six_clean_room/services/windows_firefox_extension_install_service.dart';

class _AbsentCredentialStore extends MozillaCredentialStore {
  int saves = 0;
  _AbsentCredentialStore(String root)
    : super(storePath: '$root/absent.json', backupDirectory: '$root/backups');
  @override
  Future<MozillaCredentialStatus> status() async =>
      MozillaCredentialStatus(false, false, storePath);
  @override
  Future<void> save({
    required String issuer,
    required String secret,
    String account = MozillaCredentialStore.expectedAccount,
  }) async {
    saves++;
  }
}

class _CredentialStore extends _AbsentCredentialStore {
  _CredentialStore() : super('test-only-no-io');
  bool failSave = false, failBackup = false;
  int attempts = 0;
  String? savedIssuer, savedSecret;
  @override
  Future<void> save({
    required String issuer,
    required String secret,
    String account = MozillaCredentialStore.expectedAccount,
  }) async {
    attempts++;
    if (failSave) throw StateError('fixture storage failure');
    savedIssuer = issuer;
    savedSecret = secret;
    saves++;
  }

  @override
  Future<MozillaCredentialStatus> status() async =>
      MozillaCredentialStatus(saves > 0, saves > 0, storePath);
  @override
  Future<MozillaCredentialBackup> backupCiphertext({String? directory}) async {
    if (failBackup) throw StateError('fixture backup failure');
    return MozillaCredentialBackup('test-only-no-io/backup.json', 'a' * 64);
  }
}

class _CredentialSigner extends MozillaSigningClient {
  int calls = 0;
  String? error;
  String? lastIssuer, lastSecret;
  Completer<void>? pending;
  @override
  Future<void> validateCredentials({
    required String issuer,
    required String secret,
  }) async {
    calls++;
    lastIssuer = issuer;
    lastSecret = secret;
    if (pending != null) await pending!.future;
    if (error != null) throw MozillaSigningException(error!, httpStatus: 401);
  }
}

void main() {
  testWidgets('credential prompt request opens the in-app secure dialog', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(
      MaterialApp(
        home: BrowserProtectionCenterScreen(
          locale: const Locale('ko'),
          credentialPromptRequestId: 123,
          credentialStore: _CredentialStore(),
          signingClient: _CredentialSigner(),
          inspectFirefox: () async => const FirefoxManagedRepairReport(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Mozilla 연결'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('mozilla-secret-input')))
          .obscureText,
      isTrue,
    );
  });

  Future<void> openCredentialDialog(
    WidgetTester tester,
    _CredentialStore store,
    _CredentialSigner signer,
  ) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({
      'mozilla_backup_folder_v1': r'C:\test-only-no-io\backups',
    });
    await tester.pumpWidget(
      MaterialApp(
        home: BrowserProtectionCenterScreen(
          locale: const Locale('ko'),
          credentialStore: store,
          signingClient: signer,
          inspectFirefox: () async => const FirefoxManagedRepairReport(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('연결·자격증명 변경'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('mozilla-issuer-input')),
      'fixture-issuer',
    );
    await tester.enterText(
      find.byKey(const Key('mozilla-secret-input')),
      'fixture-real-secret',
    );
  }

  testWidgets(
    '401 remains inline with masked inputs preserved and no vault save',
    (tester) async {
      final store = _CredentialStore(),
          signer = _CredentialSigner()..error = 'invalid_credentials';
      await openCredentialDialog(tester, store, signer);
      await tester.tap(find.byKey(const Key('mozilla-authenticate-save')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('인증 실패 (401)'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('mozilla-issuer-input')))
            .controller!
            .text,
        'fixture-issuer',
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('mozilla-secret-input')))
            .controller!
            .text,
        'fixture-real-secret',
      );
      expect(store.saves, 0);
      expect(store.attempts, 0);
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      signer.close();
    },
  );

  testWidgets(
    'credential input normalization strips copy wrappers and whitespace',
    (tester) async {
      final store = _CredentialStore(), signer = _CredentialSigner();
      await openCredentialDialog(tester, store, signer);
      await tester.enterText(
        find.byKey(const Key('mozilla-issuer-input')),
        "  ' user : 123 : 7 '  ",
      );
      await tester.enterText(
        find.byKey(const Key('mozilla-secret-input')),
        ' ` abc\n def 123 ` ',
      );
      await tester.tap(find.byKey(const Key('mozilla-authenticate-save')));
      await tester.pumpAndSettle();
      expect(signer.lastIssuer, 'user:123:7');
      expect(signer.lastSecret, 'abcdef123');
      expect(store.savedIssuer, signer.lastIssuer);
      expect(store.savedSecret, signer.lastSecret);
      signer.close();
    },
  );

  testWidgets('issuer and secret visibility can each be toggled', (
    tester,
  ) async {
    final store = _CredentialStore(), signer = _CredentialSigner();
    await openCredentialDialog(tester, store, signer);
    final issuer = find.byKey(const Key('mozilla-issuer-input'));
    final secret = find.byKey(const Key('mozilla-secret-input'));
    expect(tester.widget<TextField>(issuer).obscureText, isTrue);
    expect(tester.widget<TextField>(secret).obscureText, isTrue);
    await tester.tap(find.byKey(const Key('mozilla-secret-visibility')));
    await tester.pump();
    expect(tester.widget<TextField>(secret).obscureText, isFalse);
    expect(tester.widget<TextField>(issuer).obscureText, isTrue);
    await tester.tap(find.byKey(const Key('mozilla-secret-visibility')));
    await tester.tap(find.byKey(const Key('mozilla-issuer-visibility')));
    await tester.pump();
    expect(tester.widget<TextField>(secret).obscureText, isTrue);
    expect(tester.widget<TextField>(issuer).obscureText, isFalse);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    signer.close();
  });

  testWidgets(
    'successful authentication saves once before closing and duplicate clicks disabled',
    (tester) async {
      final store = _CredentialStore(),
          signer = _CredentialSigner()..pending = Completer<void>();
      await openCredentialDialog(tester, store, signer);
      await tester.tap(find.byKey(const Key('mozilla-authenticate-save')));
      await tester.pump();
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('mozilla-authenticate-save')),
            )
            .onPressed,
        isNull,
      );
      expect(store.saves, 0);
      signer.pending!.complete();
      await tester.pumpAndSettle();
      expect(store.saves, 1);
      expect(signer.calls, 1);
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        find.textContaining('Mozilla 인증과 이 PC의 암호화 저장을 완료했습니다.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      signer.close();
    },
  );

  testWidgets(
    'storage failure retains dialog and actual inputs after successful authentication',
    (tester) async {
      final store = _CredentialStore()..failSave = true,
          signer = _CredentialSigner();
      await openCredentialDialog(tester, store, signer);
      await tester.tap(find.byKey(const Key('mozilla-authenticate-save')));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('인증은 성공했지만 이 PC의 암호화 저장에 실패'), findsOneWidget);
      expect(store.attempts, 1);
      expect(store.saves, 0);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('mozilla-secret-input')))
            .controller!
            .text,
        'fixture-real-secret',
      );
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      signer.close();
    },
  );

  testWidgets(
    'masked placeholder rejected locally; backup failure does not undo saved success',
    (tester) async {
      final store = _CredentialStore()..failBackup = true,
          signer = _CredentialSigner();
      await openCredentialDialog(tester, store, signer);
      await tester.enterText(
        find.byKey(const Key('mozilla-secret-input')),
        '••••••',
      );
      await tester.tap(find.byKey(const Key('mozilla-authenticate-save')));
      await tester.pumpAndSettle();
      expect(signer.calls, 0);
      expect(store.saves, 0);
      expect(find.textContaining('실제 secret을 붙여 넣어'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('mozilla-secret-input')),
        '03a...bd',
      );
      await tester.tap(find.byKey(const Key('mozilla-authenticate-save')));
      await tester.pumpAndSettle();
      expect(signer.calls, 0);
      expect(store.saves, 0);
      await tester.enterText(
        find.byKey(const Key('mozilla-secret-input')),
        'fixture-real-secret',
      );
      await tester.tap(find.byKey(const Key('mozilla-authenticate-save')));
      await tester.pumpAndSettle();
      expect(store.saves, 1);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.textContaining('저장됐지만 암호화 백업에 실패'), findsOneWidget);
      signer.close();
    },
  );
  testWidgets('maintenance screen reads status only and masks credentials', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final store = _AbsentCredentialStore('test-only-no-io');
    var inspections = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: BrowserProtectionCenterScreen(
          credentialStore: store,
          locale: const Locale('ko'),
          inspectFirefox: () async {
            inspections++;
            return const FirefoxManagedRepairReport(message: 'test-only');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(inspections, 1);
    expect(find.text('브라우저 보호 관리'), findsOneWidget);
    expect(find.text('현재 실행 중인 Firefox 확장 활성화: 아직 확인되지 않음'), findsOneWidget);
    await tester.ensureVisible(find.text('연결·자격증명 변경'));
    await tester.tap(find.text('연결·자격증명 변경'));
    await tester.pumpAndSettle();
    final fields = tester
        .widgetList<TextField>(find.byType(TextField))
        .toList();
    expect(fields.length, 2);
    expect(
      fields.every(
        (field) =>
            field.obscureText &&
            !field.enableSuggestions &&
            field.autocorrect == false,
      ),
      true,
    );
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(store.saves, 0);
    expect(inspections, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'update opens only on explicit click; launch request never claims visible dialog or live activation',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = _AbsentCredentialStore('test-only-no-io');
      var opens = 0, inspections = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: BrowserProtectionCenterScreen(
            locale: const Locale('en'),
            credentialStore: store,
            inspectFirefox: () async {
              inspections++;
              return const FirefoxManagedRepairReport(
                filesPrepared: true,
                expectedVersion: '1.0.25',
                profileTotal: 1,
                profiles: [
                  FirefoxProfileAddonStatus(
                    profilePath: 'fixture',
                    name: 'FocusFense',
                    version: '1.0.25',
                    active: true,
                    signedState: 2,
                    xpiPath: 'fixture.xpi',
                    sha256: 'fixture-hash',
                  ),
                ],
                expectedSha256: 'fixture-hash',
              );
            },
            openFirefoxUpdate: () async {
              opens++;
              return {
                'ok': true,
                'filesPrepared': true,
                'artifactVerified': true,
                'launchRequested': true,
                'nativeDialogVerified': false,
                'activationVerified': false,
                'requiresUserConfirmation': true,
              };
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(opens, 0);
      expect(inspections, 1);
      expect(
        find.textContaining('Profile package and installation records match'),
        findsOneWidget,
      );
      expect(
        find.text('Activation in the running Firefox: not verified'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.byKey(const Key('firefox-open-update')));
      await tester.tap(find.byKey(const Key('firefox-open-update')));
      await tester.pumpAndSettle();
      expect(opens, 1);
      expect(
        find.byKey(const Key('firefox-update-launch-state')),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'The confirmation dialog and approval have not been verified.',
        ),
        findsWidgets,
      );
      expect(
        find.text('Activation in the running Firefox: not verified'),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const Key('firefox-update-recheck')));
      await tester.pumpAndSettle();
      expect(inspections, 2);
      expect(opens, 1);
    },
  );

  testWidgets(
    'update open failure stays distinct from preparation and never reports activation',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await tester.pumpWidget(
        MaterialApp(
          home: BrowserProtectionCenterScreen(
            locale: const Locale('ko'),
            credentialStore: _AbsentCredentialStore('test-only-no-io'),
            inspectFirefox: () async => const FirefoxManagedRepairReport(),
            openFirefoxUpdate: () async => {
              'ok': false,
              'filesPrepared': true,
              'launchRequested': false,
              'nativeDialogVerified': false,
              'activationVerified': false,
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const Key('firefox-open-update')));
      await tester.tap(find.byKey(const Key('firefox-open-update')));
      await tester.pumpAndSettle();
      expect(find.text('업데이트 파일 준비됨'), findsOneWidget);
      expect(find.text('업데이트 열기 요청을 전달하지 못했습니다.'), findsWidgets);
      expect(find.text('현재 실행 중인 Firefox 확장 활성화: 아직 확인되지 않음'), findsOneWidget);
    },
  );
}
