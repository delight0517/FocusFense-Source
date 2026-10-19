import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// User-owned accounting settings, not a website/blocking allowlist.
class YoutubeBudgetExemptionStore {
  YoutubeBudgetExemptionStore({
    Future<Map<String, dynamic>> Function(String)? resolveVideo,
  }) : _resolveVideo = resolveVideo ?? _oembed;
  static final instance = YoutubeBudgetExemptionStore();
  static const preferenceKey = 'youtube_budget_exemptions_v1';
  final Future<Map<String, dynamic>> Function(String) _resolveVideo;
  final Map<String, List<Map<String, Object?>>> _resolved = {};
  final Map<String, DateTime> _resolvedAt = {};
  // All instances share the same preferences key; serialize read/modify/write
  // so simultaneous chat, CLI and backup edits cannot silently lose an entry.
  static Future<void> _mutations = Future<void>.value();
  static Future<void> _mutate(Future<void> Function() action) {
    final operation = _mutations.then((_) => action());
    _mutations = operation.catchError((Object _) {});
    return operation;
  }

  static Future<Map<String, dynamic>> _oembed(String videoId) async {
    final uri = Uri.https('www.youtube.com', '/oembed', {
      'url': 'https://www.youtube.com/watch?v=$videoId',
      'format': 'json',
    });
    final client = http.Client();
    try {
      final response = await client
          .send(http.Request('GET', uri)..followRedirects = false)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) {
        throw const FormatException('영상 채널을 확인하지 못했습니다. 채널 주소를 입력해 주세요.');
      }
      final bytes = <int>[];
      await for (final chunk in response.stream.timeout(
        const Duration(seconds: 15),
      )) {
        bytes.addAll(chunk);
        if (bytes.length > 128 * 1024) {
          throw const FormatException('채널 응답이 너무 큽니다.');
        }
      }
      return Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
    } finally {
      client.close();
    }
  }

  static bool _youtube(String host) =>
      host == 'youtube.com' || host.endsWith('.youtube.com');
  static Map<String, Object?> _validate(Map<String, Object?> row) {
    final kind = row['kind'];
    final raw = row['value'];
    if (raw is! String || raw.trim().isEmpty || raw.length > 512) {
      throw const FormatException('예외 대상이 올바르지 않습니다.');
    }
    var value = raw.trim();
    switch (kind) {
      case 'channelHandle':
        value = value.replaceFirst(RegExp(r'^@'), '').toLowerCase();
        if (value.isEmpty ||
            value.contains('@') ||
            RegExp(r'[\s/?#\\]').hasMatch(value)) {
          throw const FormatException('채널 핸들을 확인해 주세요.');
        }
      case 'channelId':
        if (!RegExp(r'^UC[A-Za-z0-9_-]{22}$').hasMatch(value)) {
          throw const FormatException('채널 ID를 확인해 주세요.');
        }
      case 'videoId':
        if (!RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(value)) {
          throw const FormatException('영상 ID를 확인해 주세요.');
        }
      case 'domain':
        value = value.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
        if (!RegExp(
              r'^[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\.[a-z]{2,}$',
            ).hasMatch(value) ||
            value.contains('..')) {
          throw const FormatException('사이트 도메인을 확인해 주세요.');
        }
      default:
        throw const FormatException('지원하지 않는 예외 유형입니다.');
    }
    return {
      'kind': kind,
      'value': value,
      if (row['label'] is String)
        'label': (row['label'] as String).substring(
          0,
          (row['label'] as String).length.clamp(0, 200),
        ),
      if (row['sourceUrl'] is String) 'sourceUrl': row['sourceUrl'],
    };
  }

  Future<List<Map<String, Object?>>> entries() => listEntries();
  Future<List<Map<String, Object?>>> listEntries() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(preferenceKey);
    if (raw == null) return [];
    return (jsonDecode(raw) as List)
        .map((e) => _validate(Map<String, Object?>.from(e as Map)))
        .toList();
  }

  Future<List<Map<String, Object?>>> resolveTargets(
    List<String> targets,
  ) async {
    if (targets.isEmpty || targets.length > 100) {
      throw const FormatException('예외로 지정할 사이트 또는 채널 주소를 입력해 주세요.');
    }
    final result = <String, Map<String, Object?>>{};
    for (final raw in targets) {
      final input = raw.trim();
      if (input.length > 2048 || RegExp(r'\s').hasMatch(input)) {
        throw const FormatException('주소를 확인해 주세요.');
      }
      final cached = _resolved[input];
      if (cached != null &&
          DateTime.now().difference(_resolvedAt[input]!) <
              const Duration(minutes: 10)) {
        for (final e in cached) {
          result['${e['kind']}:${e['value']}'] = Map.of(e);
        }
        continue;
      }
      final uri = Uri.parse(input.contains('://') ? input : 'https://$input');
      if (!['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasPort) {
        throw const FormatException('웹사이트 또는 YouTube 채널 주소가 필요합니다.');
      }
      Map<String, Object?> row;
      final host = uri.host.toLowerCase();
      final segments = uri.pathSegments;
      if (_youtube(host) &&
          segments.isNotEmpty &&
          segments.first.startsWith('@')) {
        row = {
          'kind': 'channelHandle',
          'value': segments.first.substring(1),
          'label': segments.first,
          'sourceUrl': uri.toString(),
        };
      } else if (_youtube(host) &&
          segments.length >= 2 &&
          segments.first == 'channel') {
        row = {
          'kind': 'channelId',
          'value': segments[1],
          'label': segments[1],
          'sourceUrl': uri.toString(),
        };
      } else {
        final video = host == 'youtu.be' && segments.isNotEmpty
            ? segments.first
            : _youtube(host) &&
                  segments.length >= 2 &&
                  ['shorts', 'live', 'embed'].contains(segments.first)
            ? segments[1]
            : _youtube(host)
            ? uri.queryParameters['v']
            : null;
        if (video != null) {
          if (!RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(video)) {
            throw const FormatException('YouTube 영상 주소를 확인해 주세요.');
          }
          final data = await _resolveVideo(video);
          final author = data['author_url'];
          if (author is! String) {
            throw const FormatException(
              '영상 소유 채널을 확인하지 못했습니다. 채널 주소를 입력해 주세요.',
            );
          }
          final authorUri = Uri.parse(author);
          if (authorUri.scheme != 'https' ||
              !_youtube(authorUri.host) ||
              authorUri.userInfo.isNotEmpty ||
              authorUri.hasPort) {
            throw const FormatException('채널 응답을 확인하지 못했습니다.');
          }
          final ownerSegments = authorUri.pathSegments;
          if (!(ownerSegments.length == 1 &&
                  ownerSegments.first.startsWith('@')) &&
              !(ownerSegments.length == 2 &&
                  ownerSegments.first == 'channel')) {
            throw const FormatException('영상 소유 채널 주소가 필요합니다.');
          }
          final resolved = await resolveTargets([author]);
          if (resolved.length != 1 ||
              ![
                'channelHandle',
                'channelId',
              ].contains(resolved.single['kind'])) {
            throw const FormatException('채널을 확인하지 못했습니다.');
          }
          row = {
            ...resolved.single,
            'sourceUrl': uri.toString(),
            'label': data['author_name'] is String
                ? data['author_name']
                : resolved.single['value'],
          };
        } else {
          if (_youtube(host) && segments.isNotEmpty) {
            throw const FormatException('채널 주소 또는 영상 주소를 입력해 주세요.');
          }
          row = {
            'kind': 'domain',
            'value': host,
            'label': host,
            'sourceUrl': uri.toString(),
          };
        }
      }
      row = _validate(row);
      if (_resolved.length >= 100) {
        final oldest = _resolved.keys.first;
        _resolved.remove(oldest);
        _resolvedAt.remove(oldest);
      }
      _resolved[input] = [Map.of(row)];
      _resolvedAt[input] = DateTime.now();
      result['${row['kind']}:${row['value']}'] = row;
    }
    return result.values.toList();
  }

  Future<void> addEntries(List<Map<String, Object?>> rows) => _mutate(() async {
    final all = {
      for (final row in await listEntries())
        '${row['kind']}:${row['value']}': row,
    };
    for (final raw in rows) {
      final row = _validate(raw);
      all['${row['kind']}:${row['value']}'] = row;
    }
    if (all.length > 500) {
      throw const FormatException('예외는 최대 500개까지 저장할 수 있습니다.');
    }
    await (await SharedPreferences.getInstance()).setString(
      preferenceKey,
      jsonEncode(all.values.toList()),
    );
  });

  Future<void> removeEntries(List<Map<String, Object?>> rows) =>
      _mutate(() async {
        final identities = rows
            .map(_validate)
            .map((row) => '${row['kind']}:${row['value']}')
            .toSet();
        final all = (await listEntries())
            .where(
              (row) => !identities.contains('${row['kind']}:${row['value']}'),
            )
            .toList();
        await (await SharedPreferences.getInstance()).setString(
          preferenceKey,
          jsonEncode(all),
        );
      });

  Future<bool> isDomainExempt(String host) async => (await listEntries()).any(
    (row) =>
        row['kind'] == 'domain' &&
        (host.toLowerCase() == row['value'] ||
            host.toLowerCase().endsWith('.${row['value']}')),
  );
  Future<bool> isYoutubeMetadataExempt(
    Object? metadata,
    String documentUrl,
  ) async {
    if (metadata is! Map || metadata['verified'] != true) return false;
    final uri = Uri.tryParse(documentUrl);
    if (uri == null ||
        uri.scheme != 'https' ||
        !_youtube(uri.host) ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort) {
      return false;
    }
    final video =
        uri.queryParameters['v'] ??
        (uri.pathSegments.length >= 2 &&
                ['shorts', 'live'].contains(uri.pathSegments.first)
            ? uri.pathSegments[1]
            : null);
    if (video == null ||
        metadata['videoId'] != video ||
        !RegExp(r'^[A-Za-z0-9_-]{11}$').hasMatch(video)) {
      return false;
    }
    final handle = '${metadata['channelHandle'] ?? ''}'
        .replaceFirst(RegExp(r'^@'), '')
        .toLowerCase();
    return (await listEntries()).any(
      (row) =>
          row['kind'] == 'channelHandle' &&
              metadata['ownerVerified'] == true &&
              handle.isNotEmpty &&
              row['value'] == handle ||
          row['kind'] == 'channelId' &&
              metadata['ownerVerified'] == true &&
              row['value'] == metadata['channelId'] ||
          row['kind'] == 'videoId' && row['value'] == video ||
          row['kind'] == 'domain' &&
              (uri.host == row['value'] ||
                  uri.host.endsWith('.${row['value']}')),
    );
  }

  Future<void> restoreFromBackup(Object? value) => _mutate(() async {
    if (value == null) return;
    final rows = (value as List)
        .map((e) => _validate(Map<String, Object?>.from(e as Map)))
        .toList();
    if (rows.length > 500) {
      throw const FormatException('예외는 최대 500개까지 복원할 수 있습니다.');
    }
    await (await SharedPreferences.getInstance()).setString(
      preferenceKey,
      jsonEncode(rows),
    );
  });
}
