import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:six_clean_room/services/youtube_budget_exemption_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'watch URL resolves exact mixed case video to official owner, not domain',
    () async {
      final ids = <String>[];
      final store = YoutubeBudgetExemptionStore(
        resolveVideo: (id) async {
          ids.add(id);
          return {
            'author_url': 'https://www.youtube.com/@OnlyLord',
            'author_name': 'Only Lord',
            'title': 'unrelated recommendation',
          };
        },
      );
      final entries = await store.resolveTargets([
        'https://www.youtube.com/watch?v=YKi9KlVDInQ',
      ]);
      expect(ids, ['YKi9KlVDInQ']);
      expect(entries.single['kind'], 'channelHandle');
      expect(entries.single['value'], 'onlylord');
      expect(entries.single['label'], 'Only Lord');
      await store.resolveTargets([
        'https://www.youtube.com/watch?v=YKi9KlVDInQ',
      ]);
      expect(ids.length, 1);
      expect(await store.entries(), isEmpty);
    },
  );
  test('malicious or recursive author URL cannot broaden exemption', () async {
    for (final author in [
      'https://youtube.com.evil.test/@onlylord',
      'https://www.youtube.com/watch?v=YKi9KlVDInQ',
      'https://www.youtube.com/@',
      'https://www.youtube.com/@onlylord/watch',
      'https://user@www.youtube.com/@onlylord',
    ]) {
      var calls = 0;
      final store = YoutubeBudgetExemptionStore(
        resolveVideo: (_) async {
          calls++;
          return {'author_url': author};
        },
      );
      await expectLater(
        store.resolveTargets(['https://youtu.be/YKi9KlVDInQ']),
        throwsFormatException,
      );
      expect(calls, 1);
      expect(await store.entries(), isEmpty);
    }
  });
  test('failed resolution or invalid writes preserve prior entries', () async {
    final store = YoutubeBudgetExemptionStore(
      resolveVideo: (_) async => throw const FormatException(),
    );
    await store.addEntries([
      {'kind': 'channelHandle', 'value': 'onlylord'},
    ]);
    await expectLater(
      store.resolveTargets(['https://youtu.be/YKi9KlVDInQ']),
      throwsFormatException,
    );
    await expectLater(
      store.addEntries([
        {'kind': 'channelHandle', 'value': '@'},
      ]),
      throwsFormatException,
    );
    await expectLater(
      store.restoreFromBackup([
        {'kind': 'channelHandle', 'value': '@'},
      ]),
      throwsFormatException,
    );
    expect((await store.entries()).single['value'], 'onlylord');
  });
  test(
    'concurrent instances serialize mutations, deduplicate and restore',
    () async {
      final first = YoutubeBudgetExemptionStore();
      final second = YoutubeBudgetExemptionStore();
      await Future.wait([
        first.addEntries([
          {'kind': 'channelHandle', 'value': 'OnlyLord'},
        ]),
        second.addEntries([
          {'kind': 'domain', 'value': 'example.org'},
        ]),
      ]);
      expect((await first.entries()).length, 2);
      await first.addEntries([
        {'kind': 'channelHandle', 'value': '@ONLYLORD'},
      ]);
      expect((await first.entries()).length, 2);
      final backup = await first.entries();
      await Future.wait([
        first.removeEntries([
          {'kind': 'channelHandle', 'value': 'onlylord'},
        ]),
        second.addEntries([
          {'kind': 'domain', 'value': 'another.org'},
        ]),
      ]);
      expect(
        (await first.entries()).map((e) => e['value']),
        unorderedEquals(['example.org', 'another.org']),
      );
      await first.restoreFromBackup(backup);
      expect(await first.entries(), backup);
    },
  );
  test(
    'only verified current video owner matches; titles and recommendations ignored',
    () async {
      final store = YoutubeBudgetExemptionStore();
      await store.addEntries([
        {'kind': 'channelHandle', 'value': 'onlylord'},
      ]);
      const url = 'https://www.youtube.com/watch?v=YKi9KlVDInQ';
      final exact = {
        'verified': true,
        'ownerVerified': true,
        'videoId': 'YKi9KlVDInQ',
        'channelHandle': '@OnlyLord',
      };
      expect(await store.isYoutubeMetadataExempt(exact, url), true);
      expect(
        await store.isYoutubeMetadataExempt({
          ...exact,
          'ownerVerified': false,
        }, url),
        false,
      );
      expect(
        await store.isYoutubeMetadataExempt({...exact, 'verified': false}, url),
        false,
      );
      expect(
        await store.isYoutubeMetadataExempt({
          ...exact,
          'videoId': 'yki9klvdinq',
        }, url),
        false,
      );
      expect(
        await store.isYoutubeMetadataExempt({
          ...exact,
          'channelHandle': 'other',
          'title': 'onlylord',
          'recommendations': ['onlylord'],
        }, url),
        false,
      );
      expect(
        await store.isYoutubeMetadataExempt(
          exact,
          'https://youtube.com.evil.test/watch?v=YKi9KlVDInQ',
        ),
        false,
      );
    },
  );
  test('domain suffix requires label boundary', () async {
    final store = YoutubeBudgetExemptionStore();
    await store.addEntries([
      {'kind': 'domain', 'value': 'example.org'},
    ]);
    expect(await store.isDomainExempt('example.org'), true);
    expect(await store.isDomainExempt('sub.example.org'), true);
    expect(await store.isDomainExempt('notexample.org'), false);
    expect(await store.isDomainExempt('example.org.evil.test'), false);
  });
}
