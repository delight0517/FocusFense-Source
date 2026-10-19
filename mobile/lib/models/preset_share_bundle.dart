import 'dart:convert';

/// Portable "share to a friend" preset — either a full schedule (with time
/// slots) or a time-less domain/keyword/app list, per the user's choice at
/// export time. See `preset_share_service.dart` for encode/decode + apply.
final class PresetShareBundle {
  const PresetShareBundle({
    required this.name,
    required this.includeSchedule,
    this.weekdays = const <int>[],
    this.startMinutes = 0,
    this.endMinutes = 1440,
    this.domains = const <String>[],
    this.keywords = const <String>[],
    this.appNames = const <String>[],
  });

  static const int formatVersion = 1;

  final String name;

  /// `true` → recipient gets a new (disabled-by-default) schedule with
  /// [weekdays]/[startMinutes]/[endMinutes]. `false` → recipient gets a
  /// time-less quick-block bundle (domains/keywords/apps only).
  final bool includeSchedule;

  /// App convention: 0=Monday ... 6=Sunday. Empty means "every day".
  final List<int> weekdays;
  final int startMinutes;
  final int endMinutes;
  final List<String> domains;
  final List<String> keywords;
  final List<String> appNames;

  Map<String, Object?> toJson() => <String, Object?>{
    'formatVersion': formatVersion,
    'name': name,
    'includeSchedule': includeSchedule,
    'weekdays': weekdays,
    'startMinutes': startMinutes,
    'endMinutes': endMinutes,
    'domains': domains,
    'keywords': keywords,
    'appNames': appNames,
  };

  String toJsonString() => jsonEncode(toJson());

  static PresetShareBundle? fromJsonString(String raw) {
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final Map<String, Object?> map = Map<String, Object?>.from(decoded);
      return PresetShareBundle(
        name: '${map['name'] ?? '공유된 프리셋'}'.trim().isEmpty
            ? '공유된 프리셋'
            : '${map['name']}',
        includeSchedule: map['includeSchedule'] == true,
        weekdays: _intList(map['weekdays']),
        startMinutes: (map['startMinutes'] as num?)?.toInt() ?? 0,
        endMinutes: (map['endMinutes'] as num?)?.toInt() ?? 1440,
        domains: _strList(map['domains']),
        keywords: _strList(map['keywords']),
        appNames: _strList(map['appNames']),
      );
    } catch (_) {
      return null;
    }
  }

  static List<String> _strList(Object? v) => v is List
      ? v.map((Object? e) => '$e'.trim()).where((String s) => s.isNotEmpty).toList()
      : const <String>[];

  static List<int> _intList(Object? v) {
    if (v is! List) return const <int>[];
    return v
        .map((Object? e) => e is num ? e.toInt() : int.tryParse('$e') ?? -1)
        .where((int i) => i >= 0 && i <= 6)
        .toList();
  }
}
