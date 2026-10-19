import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/services/adult_domain_component_store.dart';
import 'package:six_clean_room/services/youtube_enforcement_hosts.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ff-components-');
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });

  Future<String> install(String version, List<String> domains) async {
    final bytes = utf8.encode(
      jsonEncode({
        'schemaVersion': 1,
        'component': 'adult-domains',
        'version': version,
        'domains': domains,
        'numericStems': ['fixtureadult'],
      }),
    );
    final digest = sha256.convert(bytes).toString();
    final dir = Directory('${root.path}/releases/$digest');
    await dir.create(recursive: true);
    await File('${dir.path}/package.json').writeAsBytes(bytes);
    await File('${root.path}/current.json').writeAsString(
      jsonEncode({
        'schemaVersion': 1,
        'component': 'adult-domains',
        'release': digest,
      }),
    );
    return digest;
  }

  test(
    'live data switch and rollback update same host without losing baseline',
    () async {
      final store = AdultDomainComponentStore(root);
      final builtin = await store.read();
      final first = await install('1', ['first.example']);
      expect((await store.read()).domains, contains('first.example'));
      await install('2', ['second.example']);
      final second = await store.read();
      expect(second.domains, containsAll(builtin.domains));
      expect(second.domains, contains('second.example'));
      expect(second.extraDomains, isNot(contains('first.example')));
      await File('${root.path}/current.json').writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'component': 'adult-domains',
          'release': first,
        }),
      );
      expect((await store.read()).version, '1');
      expect(store.status['error'], isNull);
    },
  );
  test(
    'hash mismatch and missing pointer preserve last good rules; cold start stays safe',
    () async {
      final store = AdultDomainComponentStore(root);
      final hash = await install('1', ['first.example']);
      await store.read();
      await File(
        '${root.path}/releases/$hash/package.json',
      ).writeAsString('{}');
      expect(
        (await store.read(force: true)).domains,
        contains('first.example'),
      );
      expect(store.status['error'], isNotNull);
      final cold = AdultDomainComponentStore(root);
      expect((await cold.read()).version, 'builtin');
      expect(cold.status['baselinePreserved'], true);
      await File('${root.path}/current.json').delete();
      expect((await store.read()).domains, contains('first.example'));
    },
  );
  test(
    'path traversal pointer rejected, invalid packages rejected, adult OFF preserved in hosts',
    () async {
      final store = AdultDomainComponentStore(root);
      await File('${root.path}/current.json').writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'component': 'adult-domains',
          'release': '../escape',
        }),
      );
      expect((await store.read()).version, 'builtin');
      for (final domains in [
        <String>[],
        ['youtube.com'],
        ['bad/path'],
        ['UPPER.example'],
      ]) {
        expect(
          () => AdultDomainComponent.parse({
            'schemaVersion': 1,
            'component': 'adult-domains',
            'version': '1',
            'domains': domains,
          }, 'digest'),
          throwsFormatException,
        );
      }
      expect(
        YoutubeEnforcementHosts.expandedBuiltinDomainsForWindowsHosts(
          includeAdult: false,
          adultDomains: ['first.example'],
        ),
        isNot(contains('first.example')),
      );
      expect(
        YoutubeEnforcementHosts.expandedBuiltinDomainsForWindowsHosts(
          includeAdult: true,
          adultDomains: ['first.example'],
        ),
        contains('first.example'),
      );
    },
  );
}
