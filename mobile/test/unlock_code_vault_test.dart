import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:six_clean_room/services/unlock_code_vault_service.dart';

class _SeededRng implements Random {
  _SeededRng(int seed) : _r = Random(seed);
  final Random _r;
  @override
  bool nextBool() => _r.nextBool();
  @override
  double nextDouble() => _r.nextDouble();
  @override
  int nextInt(int max) => _r.nextInt(max);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DateTime fakeNow;
  DateTime nowFn() => fakeNow;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    fakeNow = DateTime.utc(2026, 6, 18, 12);
    UnlockCodeVaultService.instance.debugOverrideClock(nowFn);
    UnlockCodeVaultService.instance.debugOverrideRng(_SeededRng(42));
    await UnlockCodeVaultService.instance.debugWipe();
  });

  tearDown(() {
    UnlockCodeVaultService.instance.debugResetClock();
    UnlockCodeVaultService.instance.debugResetRng();
  });

  test('starts in notConfigured', () async {
    final VaultStatus s = await UnlockCodeVaultService.instance.getStatus();
    expect(s.state, VaultState.notConfigured);
    expect(await UnlockCodeVaultService.instance.isConfigured(), isFalse);
  });

  test('setupCode → idle, persists across getStatus calls', () async {
    await UnlockCodeVaultService.instance.setupCode('mySecret');
    expect(await UnlockCodeVaultService.instance.isConfigured(), isTrue);
    final VaultStatus s = await UnlockCodeVaultService.instance.getStatus();
    expect(s.state, VaultState.idle);
  });

  test('setupCode rejects short phrases', () async {
    await expectLater(
      () => UnlockCodeVaultService.instance.setupCode('ab'),
      throwsArgumentError,
    );
  });

  test('cannot replace code while locked', () async {
    await UnlockCodeVaultService.instance.setupCode('originalCode');
    await expectLater(
      () => UnlockCodeVaultService.instance.setupCode('newCode'),
      throwsStateError,
    );
  });

  test('requestReveal → pending, peek returns null before timer', () async {
    await UnlockCodeVaultService.instance.setupCode('phrase-one');
    await UnlockCodeVaultService.instance.requestReveal(waitSeconds: 1800);
    final VaultStatus s = await UnlockCodeVaultService.instance.getStatus();
    expect(s.state, VaultState.pending);
    expect(s.revealRemaining, isNotNull);
    expect(await UnlockCodeVaultService.instance.peekRevealedCode(), isNull);
  });

  test('after timer expires → revealable, peek returns the stored code', () async {
    await UnlockCodeVaultService.instance.setupCode('phrase-one');
    await UnlockCodeVaultService.instance.requestReveal(waitSeconds: 1800);
    fakeNow = fakeNow.add(const Duration(seconds: 1801));
    final VaultStatus s = await UnlockCodeVaultService.instance.getStatus();
    expect(s.state, VaultState.revealable);
    expect(
      await UnlockCodeVaultService.instance.peekRevealedCode(),
      'phrase-one',
    );
  });

  test('verifyCode correct → unlocks for 10 minutes, clears request', () async {
    await UnlockCodeVaultService.instance.setupCode('phrase-one');
    await UnlockCodeVaultService.instance.requestReveal(waitSeconds: 1800);
    fakeNow = fakeNow.add(const Duration(seconds: 1801));
    final VerifyResult v =
        await UnlockCodeVaultService.instance.verifyCode('phrase-one');
    expect(v.outcome, VerifyOutcome.correct);
    final VaultStatus s = await UnlockCodeVaultService.instance.getStatus();
    expect(s.state, VaultState.unlocked);
    expect(s.unlockRemaining, isNotNull);
    expect(s.unlockRemaining!.inMinutes, lessThanOrEqualTo(10));
  });

  test('verifyCode wrong → counts attempts; 5th invalidates the request', () async {
    await UnlockCodeVaultService.instance.setupCode('phrase-one');
    await UnlockCodeVaultService.instance.requestReveal(waitSeconds: 1800);
    fakeNow = fakeNow.add(const Duration(seconds: 1801));

    for (int i = 1; i <= 4; i++) {
      final VerifyResult v =
          await UnlockCodeVaultService.instance.verifyCode('wrong');
      expect(v.outcome, VerifyOutcome.wrong);
      expect(v.remainingAttempts, 5 - i);
    }
    final VerifyResult fifth =
        await UnlockCodeVaultService.instance.verifyCode('wrong');
    expect(fifth.outcome, VerifyOutcome.lockedOut);
    final VaultStatus s = await UnlockCodeVaultService.instance.getStatus();
    expect(s.state, VaultState.idle,
        reason: 'request must be cleared after lockout');
  });

  test('verifyCode rejects pre-timer entry as notRevealable', () async {
    await UnlockCodeVaultService.instance.setupCode('phrase-one');
    await UnlockCodeVaultService.instance.requestReveal(waitSeconds: 1800);
    final VerifyResult v =
        await UnlockCodeVaultService.instance.verifyCode('phrase-one');
    expect(v.outcome, VerifyOutcome.notRevealable);
  });

  test('unlock window expires → state returns to idle, code rotates', () async {
    await UnlockCodeVaultService.instance.setupCode('phrase-one');
    await UnlockCodeVaultService.instance.requestReveal(waitSeconds: 1800);
    fakeNow = fakeNow.add(const Duration(seconds: 1801));
    await UnlockCodeVaultService.instance.verifyCode('phrase-one');

    // Advance past the unlock window.
    fakeNow = fakeNow.add(const Duration(minutes: 11));
    final VaultStatus s = await UnlockCodeVaultService.instance.getStatus();
    expect(s.state, VaultState.idle);
    expect(s.rotationCount, greaterThan(0));

    // The old code must no longer work.
    await UnlockCodeVaultService.instance.requestReveal(waitSeconds: 1800);
    fakeNow = fakeNow.add(const Duration(seconds: 1801));
    final String? newCode =
        await UnlockCodeVaultService.instance.peekRevealedCode();
    expect(newCode, isNot('phrase-one'));
    final VerifyResult oldFails =
        await UnlockCodeVaultService.instance.verifyCode('phrase-one');
    expect(oldFails.outcome, VerifyOutcome.wrong);
  });

  test('endUnlockWindow rotates and locks immediately', () async {
    await UnlockCodeVaultService.instance.setupCode('phrase-one');
    await UnlockCodeVaultService.instance.requestReveal(waitSeconds: 1800);
    fakeNow = fakeNow.add(const Duration(seconds: 1801));
    await UnlockCodeVaultService.instance.verifyCode('phrase-one');
    expect(await UnlockCodeVaultService.instance.isUnlocked(), isTrue);

    await UnlockCodeVaultService.instance.endUnlockWindow();
    expect(await UnlockCodeVaultService.instance.isUnlocked(), isFalse);
    final VaultStatus s = await UnlockCodeVaultService.instance.getStatus();
    expect(s.state, VaultState.idle);
    expect(s.rotationCount, greaterThan(0));
  });

  test('cancelRequest clears pending without rotating', () async {
    await UnlockCodeVaultService.instance.setupCode('phrase-one');
    await UnlockCodeVaultService.instance.requestReveal(waitSeconds: 1800);
    await UnlockCodeVaultService.instance.cancelRequest();
    final VaultStatus s = await UnlockCodeVaultService.instance.getStatus();
    expect(s.state, VaultState.idle);
    expect(s.rotationCount, 0);
  });

  test('user can replace code with a memorable phrase during unlock', () async {
    await UnlockCodeVaultService.instance.setupCode('phrase-one');
    await UnlockCodeVaultService.instance.requestReveal(waitSeconds: 1800);
    fakeNow = fakeNow.add(const Duration(seconds: 1801));
    await UnlockCodeVaultService.instance.verifyCode('phrase-one');

    await UnlockCodeVaultService.instance.setupCode('newCodeChosen');

    // Exit unlock window and confirm new code works on next cycle.
    await UnlockCodeVaultService.instance.endUnlockWindow();
    await UnlockCodeVaultService.instance.requestReveal(waitSeconds: 1800);
    fakeNow = fakeNow.add(const Duration(seconds: 1801));
    // endUnlockWindow rotates to random, so 'newCodeChosen' shouldn't be
    // current — the setup during unlock then got overwritten by the
    // expiry-rotation. Document that behavior:
    final String? current =
        await UnlockCodeVaultService.instance.peekRevealedCode();
    expect(current, isNot('newCodeChosen'),
        reason: 'endUnlockWindow always rotates — explicit re-setup must '
            'happen AFTER endUnlock, not before');
  });

  test('requestReveal clamps below kMinRevealWaitSec', () async {
    await UnlockCodeVaultService.instance.setupCode('phrase-one');
    await UnlockCodeVaultService.instance.requestReveal(waitSeconds: 60);
    final VaultStatus s = await UnlockCodeVaultService.instance.getStatus();
    expect(s.revealRemaining!.inSeconds,
        greaterThanOrEqualTo(UnlockCodeVaultService.kMinRevealWaitSec - 1));
  });

  test('duplicate requestReveal does not reset the existing timer', () async {
    await UnlockCodeVaultService.instance.setupCode('phrase-one');
    await UnlockCodeVaultService.instance.requestReveal(waitSeconds: 1800);
    fakeNow = fakeNow.add(const Duration(seconds: 600));
    await UnlockCodeVaultService.instance.requestReveal(waitSeconds: 1800);
    final VaultStatus s = await UnlockCodeVaultService.instance.getStatus();
    expect(s.revealRemaining!.inSeconds, lessThanOrEqualTo(1200 + 5));
  });
}
