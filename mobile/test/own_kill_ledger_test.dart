import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/services/own_kill_ledger.dart';

void main() {
  setUp(() => OwnKillLedger.instance.clearForTest());

  test('stampPid → wasOursRecently matches same pid/image', () {
    OwnKillLedger.instance.stampPid(
      pid: 1234,
      imageName: 'Chrome.exe',
      reason: '스케줄 평일 14:00',
      reasonKey: 'app_block_pid',
    );
    expect(
      OwnKillLedger.instance.wasOursRecently(pid: 1234, imageName: 'chrome.exe'),
      isTrue,
      reason: 'image name must match case-insensitively',
    );
    expect(
      OwnKillLedger.instance.wasOursRecently(pid: 9999, imageName: 'chrome.exe'),
      isFalse,
      reason: 'unrelated pid should not hit unless image stamp exists',
    );
  });

  test('stampImage covers any pid of that image within TTL', () {
    OwnKillLedger.instance.stampImage(
      imageName: 'firefox.exe',
      reason: 'Firefox 확장 설치 마무리',
      reasonKey: 'ext_install',
    );
    expect(
      OwnKillLedger.instance
          .wasOursRecently(pid: 5555, imageName: 'firefox.exe'),
      isTrue,
    );
    expect(
      OwnKillLedger.instance
          .wasOursRecently(pid: 5555, imageName: 'chrome.exe'),
      isFalse,
      reason: 'image stamp must not leak across browser images',
    );
  });

  test('reasonFor returns the recorded reason text', () {
    OwnKillLedger.instance.stampPid(
      pid: 42,
      imageName: 'chrome.exe',
      reason: 'URL 차단 정책 재로드',
      reasonKey: 'policy_reload',
      scheduleLabel: 'Chrome',
    );
    final OwnKillReason? r = OwnKillLedger.instance
        .reasonFor(pid: 42, imageName: 'chrome.exe');
    expect(r, isNotNull);
    expect(r!.reason, 'URL 차단 정책 재로드');
    expect(r.reasonKey, 'policy_reload');
    expect(r.scheduleLabel, 'Chrome');
  });

  test('clearForTest empties the ledger', () {
    OwnKillLedger.instance.stampPid(
      pid: 1,
      imageName: 'x.exe',
      reason: 'r',
      reasonKey: 'k',
    );
    OwnKillLedger.instance.clearForTest();
    expect(
      OwnKillLedger.instance.wasOursRecently(pid: 1, imageName: 'x.exe'),
      isFalse,
    );
    expect(OwnKillLedger.instance.recent(), isEmpty);
  });

  test('recent() returns newest entries first', () {
    OwnKillLedger.instance
        .stampImage(imageName: 'a.exe', reason: 'r1', reasonKey: 'k1');
    OwnKillLedger.instance
        .stampImage(imageName: 'b.exe', reason: 'r2', reasonKey: 'k2');
    final List<OwnKillReason> recent = OwnKillLedger.instance.recent(max: 5);
    expect(recent.length, 2);
    expect(recent.first.imageName, 'b.exe');
    expect(recent[1].imageName, 'a.exe');
  });
}
