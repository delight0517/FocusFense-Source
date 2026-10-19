import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/services/mac_system_block_service.dart';
import 'package:six_clean_room/services/numeric_apex_hosts_gap_healer_service.dart';
import 'package:six_clean_room/utils/numeric_suffix_evasion.dart';

void main() {
  test('fromHost — redbogo4.com → stem redbogo', () {
    final NumericSuffixEvasionMatch? m = NumericSuffixEvasion.fromHost(
      'https://redbogo4.com/',
    );
    expect(m, isNotNull);
    expect(m!.stem, 'redbogo');
    expect(m.exampleHost, 'redbogo4.com');
  });

  test('fromHost — mingky01.live → stem mingky', () {
    final NumericSuffixEvasionMatch? m = NumericSuffixEvasion.fromHost(
      'https://mingky01.live/',
    );
    expect(m, isNotNull);
    expect(m!.stem, 'mingky');
    expect(m.exampleHost, 'mingky01.live');
  });

  test(
    'priorityConcreteApexForStem — live TLD before com, includes 01 suffix',
    () {
      final List<String> hosts =
          NumericSuffixEvasion.priorityConcreteApexForStem(
            'mingky',
            maxHosts: 40,
          );
      expect(hosts.first, 'mingky01.live');
      expect(hosts, contains('mingky01.live'));
      expect(hosts, contains('www.mingky01.live'));
      expect(
        hosts.indexOf('mingky01.live'),
        lessThan(hosts.indexOf('mingky1.live')),
      );
    },
  );

  test('pinPriorityNumericApexHosts — mingky01.live in hosts set', () {
    final Set<String> hosts = <String>{};
    MacSystemBlockService.pinPriorityNumericApexHosts(hosts, <String>[
      'mingky',
    ]);
    expect(hosts, contains('mingky01.live'));
    if (Platform.isWindows) {
      expect(hosts, contains('www.mingky01.live'));
    }
  });

  test('isConcreteNumericApexBlocklistPattern', () {
    expect(
      NumericSuffixEvasion.isConcreteNumericApexBlocklistPattern(
        '*://mingky01.live/*',
      ),
      isTrue,
    );
    expect(
      NumericSuffixEvasion.isConcreteNumericApexBlocklistPattern(
        '*://mingky*.live/*',
      ),
      isFalse,
    );
  });

  test('chromiumPolicyHostFiltersForStem emits concrete Chrome filters', () {
    final List<String> filters =
        NumericSuffixEvasion.chromiumPolicyHostFiltersForStem(
          'mingky',
          maxHosts: 8,
        );
    expect(filters, contains('mingky01.live'));
    expect(filters, isNot(contains('[*.]mingky01.live')));
    expect(filters, isNot(contains('*://*.mingky01.live/*')));
  });

  test('rotatingNumericChildProbeHosts pins xbbg numeric sibling', () {
    final List<String> probes =
        NumericApexHostsGapHealerService.rotatingNumericChildProbeHosts(
          <String>['xbbg.tv', '14.xbbg.tv', 'darkgirl12.com'],
        );
    expect(probes.first, '16.xbbg.tv');
    expect(probes, contains('14.xbbg.tv'));
    expect(probes, isNot(contains('16.darkgirl12.com')));
  });
}
