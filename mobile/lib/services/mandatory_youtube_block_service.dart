import 'package:flutter/services.dart';

/// Built-in YouTube lines merged into every browser enforcement payload.
final class MandatoryYoutubeBlockService {
  MandatoryYoutubeBlockService._();
  static final MandatoryYoutubeBlockService instance =
      MandatoryYoutubeBlockService._();

  static const String _assetPath = 'assets/config/mandatory_youtube_blocks.txt';

  List<String>? _cached;

  Future<List<String>> patterns() async {
    if (_cached != null) return _cached!;
    try {
      final String raw = await rootBundle.loadString(_assetPath);
      _cached = raw
          .split('\n')
          .map((String s) => s.trim())
          .where((String s) => s.isNotEmpty && !s.startsWith('#'))
          .toList();
    } catch (_) {
      _cached = const <String>[];
    }
    return _cached!;
  }

  void clearCache() => _cached = null;
}
