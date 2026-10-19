import 'package:flutter/services.dart';

import '../constants/app_constants.dart';

/// iOS MethodChannel bridge for App Group container + rules JSON export.
final class RulesPlatform {
  RulesPlatform({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(kRulesChannelName);

  final MethodChannel _channel;

  Future<String?> appGroupPath() async {
    final path = await _channel.invokeMethod<String>('appGroupPath');
    return path;
  }

  /// Writes [json] to `rules_v1.json` inside the App Group container. Returns file path on success.
  Future<String?> writeRulesJson(String json) async {
    final path = await _channel.invokeMethod<String>('writeRulesJson', <String, Object?>{
      'json': json,
    });
    return path;
  }
}
