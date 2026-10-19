import 'dart:convert';
import 'chatgpt_sign_in_service.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

/// Optional OpenAI API integration for schedule-language interpretation.
///
/// Uses official SIWC local-client OAuth or a user-supplied OpenAI API key.
final class ChatGptPlanService {
  ChatGptPlanService._();
  static final ChatGptPlanService instance = ChatGptPlanService._();

  static const String _apiKeyStorageKey = 'focus_fense_openai_api_key_v1';
  static const String _legacyOAuthStorageKey =
      'focus_fense_chatgpt_plan_profile_v1';
  static const String _baseUrl = 'https://api.openai.com/v1';
  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  Future<bool> get hasConnection async =>
      await ChatGptSignInService.instance.isConnected || await hasApiKey;

  Future<bool> get hasApiKey async {
    final String? key = await _secure.read(key: _apiKeyStorageKey);
    return key != null && key.trim().isNotEmpty;
  }

  /// Validate against the public API before replacing the saved credential.
  /// The key stays in the OS secure store and is never logged or synced.
  Future<void> setApiKey(String value) async {
    final String key = value.trim();
    if (key.isEmpty) throw ArgumentError('OpenAI API 키를 입력해주세요.');
    final http.Response response = await http.get(
      Uri.parse('$_baseUrl/models'),
      headers: <String, String>{'Authorization': 'Bearer $key'},
    );
    if (response.statusCode != 200) {
      throw StateError(
        response.statusCode == 401
            ? 'API 키가 유효하지 않습니다. 키를 확인해주세요.'
            : 'OpenAI API 키 확인 실패 (${response.statusCode}).',
      );
    }
    await _secure.write(key: _apiKeyStorageKey, value: key);
  }

  Future<void> signOut() async {
    await _secure.delete(key: _apiKeyStorageKey);
    // Remove only the obsolete, unsupported local OAuth session; it is never
    // sent to OpenAI or used by this supported API-key integration.
    await _secure.delete(key: _legacyOAuthStorageKey);
  }

  Future<String> normalizeScheduleRequest({
    required String message,
    required String recentConversation,
    required String currentSchedule,
  }) async {
    final String? planToken = await ChatGptSignInService.instance.accessToken();
    final String? apiKey =
        planToken ?? await _secure.read(key: _apiKeyStorageKey);
    if (apiKey == null || apiKey.trim().isEmpty) {
      throw StateError('먼저 ChatGPT 로그인 또는 OpenAI API 연결을 해주세요.');
    }

    final http.Response catalog = await http.get(
      Uri.parse('$_baseUrl/models'),
      headers: <String, String>{'Authorization': 'Bearer $apiKey'},
    );
    if (catalog.statusCode != 200) {
      throw StateError('OpenAI 모델 목록을 읽지 못했습니다 (${catalog.statusCode}).');
    }
    final dynamic catalogJson = jsonDecode(catalog.body);
    final List<dynamic> data = catalogJson is Map
        ? (catalogJson['models'] ?? catalogJson['data']) as List<dynamic>? ??
              const <dynamic>[]
        : const <dynamic>[];
    final Set<String> available = data
        .whereType<Map>()
        .where((item) => planToken == null || item['visibility'] == 'list')
        .map((item) => item['slug'] ?? item['id'])
        .whereType<String>()
        .toSet();
    final String? model =
        <String>[
          'gpt-6-luna',
          'gpt-6.1-sol',
          'gpt-4.1-mini',
          'gpt-4o-mini',
          ...available,
        ].cast<String?>().firstWhere(
          (String? candidate) => available.contains(candidate),
          orElse: () => null,
        );
    if (model == null) {
      throw StateError('사용 가능한 스케줄 해석 모델을 찾지 못했습니다.');
    }

    final http.Request request = http.Request(
      'POST',
      Uri.parse('$_baseUrl/responses'),
    );
    request.headers.addAll(<String, String>{
      'Authorization': 'Bearer $apiKey',
      'Content-Type': 'application/json',
    });
    request.body = jsonEncode(<String, Object>{
      'model': model,
      'store': false,
      'stream': true,
      'instructions':
          '''You interpret natural-language requests for Focus Fense schedules.
Return exactly one concise, standalone Korean command that the app's local schedule parser can understand. Preserve the user's requested targets, days, times, durations, and schedule name. Use explicit weekdays and 24-hour times when known. Never invent missing values. If required information is missing, return one short Korean clarification question prefixed with "질문:". Do not claim a schedule was applied. The app will show a preview and require the user to apply it.''',
      'input': <String>[
        if (currentSchedule.isNotEmpty) '현재 편집 중인 스케줄: $currentSchedule',
        if (recentConversation.isNotEmpty) '최근 대화:\n$recentConversation',
        '새 요청: $message',
      ].join('\n\n'),
    });
    final client = http.Client();
    final buffer = StringBuffer();
    bool completed = false;
    try {
      final response = await client
          .send(request)
          .timeout(const Duration(seconds: 30));
      if (response.statusCode != 200) {
        throw StateError(
          'OpenAI 요청 실패 (${response.statusCode}). 연결 및 사용 한도를 확인해주세요.',
        );
      }
      await for (final line
          in response.stream
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .timeout(const Duration(seconds: 90))) {
        if (!line.startsWith('data:')) continue;
        final value = line.substring(5).trim();
        if (value == '[DONE]') continue;
        final event = jsonDecode(value) as Map;
        if (event['type'] == 'response.output_text.delta') {
          buffer.write(event['delta'] ?? '');
        }
        if (event['type'] == 'response.completed') completed = true;
        if ([
          'response.failed',
          'response.incomplete',
          'error',
        ].contains(event['type'])) {
          throw StateError('AI 응답이 완료되지 않았습니다. 연결 또는 사용 한도를 확인해주세요.');
        }
      }
      if (!completed) throw StateError('AI 응답 연결이 중단되었습니다. 다시 시도해주세요.');
    } finally {
      client.close();
    }
    final text = buffer.toString().trim();
    if (text.isEmpty) throw StateError('AI 응답에서 텍스트를 받지 못했습니다.');
    if (text.startsWith('질문:')) {
      throw FormatException(text.substring('질문:'.length).trim());
    }
    return text;
  }
}
