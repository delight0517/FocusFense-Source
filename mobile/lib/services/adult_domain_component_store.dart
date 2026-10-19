import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../data/builtin_adult_apex_domains.dart';

/// Data-only extension point. Packages can add rules, never erase the baseline.
class AdultDomainComponentStore {
  AdultDomainComponentStore(this.directory);
  static final instance = AdultDomainComponentStore(
    Directory(
      p.join(
        Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path,
        'SixVPNBlocker',
        'components',
        'adult-domains',
      ),
    ),
  );

  final Directory directory;
  AdultDomainComponent _current = const AdultDomainComponent();
  String? _pointer;
  String? _error;

  Future<AdultDomainComponent> read({bool force = false}) async {
    try {
      final pointer = File(p.join(directory.path, 'current.json'));
      if (!await pointer.exists()) {
        // Preserve last good rules if a deployment disappears while running.
        _error = _pointer == null ? null : 'pointer_missing_using_last_good';
        return _current;
      }
      await _requireRegular(pointer, 4096);
      final text = await pointer.readAsString();
      if (!force && text == _pointer) return _current;
      final data = jsonDecode(text) as Map<String, dynamic>;
      if (data['schemaVersion'] != 1 || data['component'] != 'adult-domains') {
        throw const FormatException('Invalid component pointer');
      }
      final release = data['release'];
      if (release is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(release)) {
        throw const FormatException('Invalid release digest');
      }
      final releases = Directory(p.join(directory.path, 'releases'));
      final folder = Directory(p.join(releases.path, release));
      for (final path in [directory.path, releases.path, folder.path]) {
        if (await FileSystemEntity.type(path, followLinks: false) !=
            FileSystemEntityType.directory) {
          throw const FormatException('Linked component directory rejected');
        }
      }
      final file = File(p.join(folder.path, 'package.json'));
      await _requireRegular(file, 2 * 1024 * 1024);
      final bytes = await file.readAsBytes();
      if (sha256.convert(bytes).toString() != release) {
        throw const FormatException('Component checksum mismatch');
      }
      _current = AdultDomainComponent.parse(
        jsonDecode(utf8.decode(bytes)),
        release,
      );
      _pointer = text;
      _error = null;
    } catch (_) {
      _error = 'invalid_component_using_last_good_or_builtin';
    }
    return _current;
  }

  Map<String, Object?> get status => {
    'component': 'adult-domains',
    'schemaVersion': 1,
    'version': _current.version,
    'release': _current.release,
    'source': _current.release == null ? 'builtin' : 'local-package',
    'extraDomains': _current.extraDomains.length,
    'extraNumericStems': _current.extraNumericStems.length,
    'baselinePreserved': true,
    'error': _error,
  };

  static Future<void> _requireRegular(File file, int limit) async {
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.length() > limit) {
      throw const FormatException('Invalid component file');
    }
  }
}

class AdultDomainComponent {
  const AdultDomainComponent({
    this.version = 'builtin',
    this.release,
    this.extraDomains = const [],
    this.extraNumericStems = const [],
  });
  final String version;
  final String? release;
  final List<String> extraDomains;
  final List<String> extraNumericStems;
  Iterable<String> get domains => {
    ...kBuiltinAdultApexDomains,
    ...extraDomains,
  };
  Iterable<String> get numericStems => {
    ...kBuiltinAdultNumericStems,
    ...extraNumericStems,
  };

  static AdultDomainComponent parse(dynamic raw, String digest) {
    if (raw is! Map ||
        raw['schemaVersion'] != 1 ||
        raw['component'] != 'adult-domains' ||
        raw.keys.any(
          (key) => ![
            'schemaVersion',
            'component',
            'version',
            'domains',
            'numericStems',
          ].contains(key),
        ) ||
        raw['version'] is! String ||
        !RegExp(
          r'^[A-Za-z0-9][A-Za-z0-9._+-]{0,79}$',
        ).hasMatch(raw['version'] as String)) {
      throw const FormatException('Unsupported rules package');
    }
    final domains = raw['domains'];
    final stems = raw['numericStems'] ?? <String>[];
    if (domains is! List ||
        domains.isEmpty ||
        domains.length > 50000 ||
        stems is! List ||
        stems.length > 5000) {
      throw const FormatException('Invalid rules list');
    }
    final domainPattern = RegExp(
      r'^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$',
    );
    for (final value in domains) {
      if (value is! String ||
          !domainPattern.hasMatch(value) ||
          [
            'youtube.com',
            'youtu.be',
            'googlevideo.com',
            'ytimg.com',
          ].any((host) => value == host || value.endsWith('.$host'))) {
        throw const FormatException('Invalid or shared-media domain');
      }
    }
    for (final value in stems) {
      if (value is! String ||
          !RegExp(r'^[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$').hasMatch(value)) {
        throw const FormatException('Invalid numeric stem');
      }
    }
    return AdultDomainComponent(
      version: raw['version'] as String,
      release: digest,
      extraDomains: List<String>.unmodifiable(domains.cast<String>().toSet()),
      extraNumericStems: List<String>.unmodifiable(
        stems.cast<String>().toSet(),
      ),
    );
  }
}
