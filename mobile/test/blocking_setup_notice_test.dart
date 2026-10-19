import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/models/ecosystem_scan_models.dart';

BlockingEcosystemReport _report(List<EcosystemTargetRow> targets) {
  return BlockingEcosystemReport(
    buildLabel: 'test',
    scannedAt: DateTime(2026),
    isPostUpdateScan: false,
    platformLabel: 'Windows',
    summaryKo: 'test',
    targets: targets,
    features: const <EcosystemFeatureRow>[],
    builtinAdultCount: 0,
    activeRuleCount: 0,
  );
}

EcosystemTargetRow _browser(
  String name, {
  required bool installed,
  required bool protected,
}) {
  return EcosystemTargetRow(
    id: name.toLowerCase(),
    displayName: name,
    level: protected ? EcosystemScanLevel.ready : EcosystemScanLevel.off,
    headline: '',
    detailLines: const <String>[],
    installed: installed,
    urlBlockUsable: protected,
  );
}

void main() {
  group('BlockingSetupNotice.fromReport', () {
    test('asks for setup when no supported browser is installed', () {
      final BlockingSetupNotice notice = BlockingSetupNotice.fromReport(
        _report(<EcosystemTargetRow>[
          _browser('Chrome', installed: false, protected: false),
          _browser('Firefox', installed: false, protected: false),
        ]),
      );

      expect(notice.isReady, isFalse);
      expect(notice.title, contains('설정이 아직 완료되지 않았어요'));
      expect(notice.detail, contains('설정 안내'));
      expect(notice.unprotectedBrowsers, isEmpty);
    });

    test('names only installed browsers without working URL blocking', () {
      final BlockingSetupNotice notice = BlockingSetupNotice.fromReport(
        _report(<EcosystemTargetRow>[
          _browser('Chrome', installed: true, protected: true),
          _browser('Firefox', installed: true, protected: false),
          _browser('Edge', installed: false, protected: false),
        ]),
      );

      expect(notice.isReady, isFalse);
      expect(notice.title, contains('일부 브라우저'));
      expect(notice.detail, contains('Firefox'));
      expect(notice.detail, isNot(contains('Edge')));
      expect(notice.unprotectedBrowsers, <String>['Firefox']);
    });

    test('marks setup complete when every installed browser is protected', () {
      final BlockingSetupNotice notice = BlockingSetupNotice.fromReport(
        _report(<EcosystemTargetRow>[
          _browser('Chrome', installed: true, protected: true),
          _browser('Edge', installed: true, protected: true),
          _browser('Firefox', installed: false, protected: false),
        ]),
      );

      expect(notice.isReady, isTrue);
      expect(notice.title, contains('정상 적용 중'));
      expect(notice.detail, contains('2개'));
    });
  });
}
