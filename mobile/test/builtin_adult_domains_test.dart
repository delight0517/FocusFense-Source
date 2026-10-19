import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/data/builtin_adult_apex_domains.dart';
import 'package:six_clean_room/services/builtin_block_domains.dart';

void main() {
  test('builtin adult apex — ~200 unique hosts', () {
    expect(kBuiltinAdultApexCount, greaterThanOrEqualTo(180));
    expect(kBuiltinAdultApexDomains, contains('pornhub.com'));
    expect(kBuiltinAdultApexDomains, contains('mingky01.live'));
    expect(kBuiltinAdultNumericStems, contains('mingky'));
    expect(kBuiltinAdultNumericStems, contains('redbogo'));
    expect(kBuiltinAdultApexDomains, contains('redbogo4.com'));
    expect(kBuiltinAdultNumericStems, contains('linkdamoa'));
  });

  test(
    'always-on rules do not silently enable optional categories or YouTube',
    () {
      // YouTube apex must NOT be in this list — build +330 traced the YouTube
      // overblock to youtube.com / youtu.be being shipped here. Per-channel /
      // per-video YouTube blocks live in `blockedYoutubeHandles`,
      // `blockedYoutubeChannelIds`, `blockedYoutubeVideoIds` instead.
      expect(
        kExtensionBuiltinBlockedDomains,
        isNot(contains('youtube.com')),
        reason: 'Adding youtube.com here re-triggers the v330 overblock bug.',
      );
      expect(
        kExtensionBuiltinBlockedDomains,
        isNot(contains('youtu.be')),
        reason: 'Adding youtu.be here re-triggers the v330 overblock bug.',
      );
      expect(
        kExtensionBuiltinBlockedDomains,
        contains(kDiagnosticBlockSentinelHost),
      );
      expect(
        kExtensionBuiltinBlockedDomains,
        contains('jusohot7.com'),
        reason: 'The user explicitly requested this host be blocked.',
      );
      // This one apex was explicitly requested as an always-on rule. The rest
      // of the category must only enter the payload through the user's switch.
      expect(
        kExtensionBuiltinBlockedDomains.where(
          (String host) =>
              host != 'wang004.com' && kBuiltinAdultApexDomains.contains(host),
        ),
        isEmpty,
      );
      expect(
        kExtensionBuiltinBlockedDomains.toSet().length,
        kExtensionBuiltinBlockedDomains.length,
      );
    },
  );
}
