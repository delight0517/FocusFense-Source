import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:pointycastle/asymmetric/api.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/signers/rsa_signer.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'auth_browser_launcher.dart';
import 'package:uuid/uuid.dart';

/// Official SIWC personal-local client flow. No Codex credentials are reused.
class ChatGptSignInService {
  static final instance = ChatGptSignInService();
  static const _secure = FlutterSecureStorage();
  static const _key = 'focusfense_chatgpt_connection_v2';
  static const _resource = 'https://api.openai.com/v1';
  static const _issuer = 'https://auth.openai.com';
  Future<String>? _refreshing;
  bool _signingIn = false;

  Future<Map<String, dynamic>?> _read() async {
    final raw = await _secure.read(key: _key);
    return raw == null
        ? null
        : Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  Future<String?> get accountEmail async =>
      (await _read())?['email'] as String?;
  Future<bool> get isConnected async => (await _read()) != null;
  Future<void> signOut() => _secure.delete(key: _key);
  static String _random() => base64Url
      .encode(List<int>.generate(48, (_) => Random.secure().nextInt(256)))
      .replaceAll('=', '');

  Future<void> signIn() async {
    if (_signingIn) throw StateError('ChatGPT 로그인 진행 중입니다.');
    _signingIn = true;
    HttpServer? server;
    StreamSubscription<HttpRequest>? listener;
    try {
      final previous = await _read();
      final issuedClient = previous?['client_id'] as String?;
      final prefs = await SharedPreferences.getInstance();
      var host = prefs.getString('focusfense_chatgpt_host_v1');
      host ??= 'urn:uuid:${const Uuid().v4()}';
      await prefs.setString('focusfense_chatgpt_host_v1', host);
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final redirect = 'http://127.0.0.1:${server.port}/auth/callback';
      final state = _random(), nonce = _random(), verifier = _random();
      final callback = Completer<Map<String, String>>();
      listener = server.listen((request) async {
        final q = request.uri.queryParameters;
        if (request.uri.path != '/auth/callback' || q['state'] != state) {
          request.response.statusCode = 400;
          await request.response.close();
          return;
        }
        request.response.headers.contentType = ContentType.html;
        request.response.write(
          '<!doctype html><meta charset="utf-8"><p>FocusFense에서 로그인 결과를 확인해 주세요. 이 창을 닫아도 됩니다.</p>',
        );
        await request.response.close();
        if (!callback.isCompleted) callback.complete(q);
      });
      final uri = Uri.parse('$_issuer/api/accounts/authorize').replace(
        queryParameters: {
          'client_id': issuedClient ?? 'dynamic_agent_client',
          if (issuedClient == null) 'agent_name_hint': 'FocusFense',
          if (previous?['id_token'] is String)
            'id_token_hint': previous!['id_token'] as String,
          'ext_agent_host_id': host,
          'response_type': 'code',
          'redirect_uri': redirect,
          'scope':
              'openid profile email offline_access resource.invoke chatgpt.tokens.use.direct',
          'resource': _resource,
          'state': state,
          'nonce': nonce,
          'code_challenge_method': 'S256',
          'code_challenge': base64Url
              .encode(sha256.convert(utf8.encode(verifier)).bytes)
              .replaceAll('=', ''),
        },
      );
      if (!await launchAccountAuthorization(uri)) {
        throw StateError('로그인 브라우저를 열지 못했습니다.');
      }
      final q = await callback.future.timeout(const Duration(minutes: 5));
      if (q.containsKey('error')) throw StateError('로그인이 취소되었거나 승인되지 않았습니다.');
      final clientId = q['client_id'] ?? issuedClient;
      if (clientId == null ||
          clientId == 'dynamic_agent_client' ||
          q['code'] == null) {
        throw StateError('ChatGPT 앱 등록이 완료되지 않았습니다.');
      }
      if (issuedClient != null && clientId != issuedClient) {
        throw StateError('등록된 ChatGPT 계정과 로그인 결과가 일치하지 않습니다.');
      }
      final tokens = await _token({
        'grant_type': 'authorization_code',
        'client_id': clientId,
        'code': q['code']!,
        'code_verifier': verifier,
        'redirect_uri': redirect,
        'resource': _resource,
      });
      final response = await http
          .get(Uri.parse('$_issuer/.well-known/jwks.json'))
          .timeout(const Duration(seconds: 20));
      if (response.statusCode != 200) throw StateError('로그인 서명 키를 확인하지 못했습니다.');
      final claims = verifyIdToken(
        tokens['id_token'] as String,
        jsonDecode(response.body) as Map<String, dynamic>,
        clientId: clientId,
        nonce: nonce,
        now: DateTime.now(),
      );
      _checkScopes(tokens);
      if (previous != null && previous['sub'] != claims['sub']) {
        throw StateError('다른 계정으로 바꾸려면 먼저 ChatGPT 연결을 해제해 주세요.');
      }
      await _secure.write(
        key: _key,
        value: jsonEncode({
          ...tokens,
          'client_id': clientId,
          'email': claims['email'],
          'sub': claims['sub'],
          'saved_at_ms': DateTime.now().millisecondsSinceEpoch,
        }),
      );
    } finally {
      await listener?.cancel();
      await server?.close(force: true);
      _signingIn = false;
    }
  }

  static Map<String, dynamic> verifyIdToken(
    String token,
    Map<String, dynamic> jwks, {
    required String clientId,
    required String nonce,
    required DateTime now,
  }) {
    final parts = token.split('.');
    if (parts.length != 3) throw const FormatException('Invalid ID token');
    final header =
        jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[0]))))
            as Map;
    if (header['alg'] != 'RS256') {
      throw const FormatException('Unsupported ID token signature');
    }
    final matches = (jwks['keys'] as List)
        .whereType<Map>()
        .where((key) => key['kid'] == header['kid'] && key['kty'] == 'RSA')
        .toList();
    if (matches.length != 1) {
      throw const FormatException('Unknown ID token signing key');
    }
    BigInt number(String text) => BigInt.parse(
      base64Url
          .decode(base64Url.normalize(text))
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(),
      radix: 16,
    );
    final key = matches.single;
    final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
      ..init(
        false,
        PublicKeyParameter<RSAPublicKey>(
          RSAPublicKey(number(key['n'] as String), number(key['e'] as String)),
        ),
      );
    if (!signer.verifySignature(
      Uint8List.fromList(utf8.encode('${parts[0]}.${parts[1]}')),
      RSASignature(base64Url.decode(base64Url.normalize(parts[2]))),
    )) {
      throw const FormatException('Invalid ID token signature');
    }
    final claims = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(parts[1]))))
          as Map,
    );
    final audience = claims['aud'];
    if (claims['iss'] != _issuer ||
        !(audience == clientId ||
            audience is List && audience.contains(clientId)) ||
        claims['nonce'] != nonce ||
        claims['sub'] is! String ||
        (claims['sub'] as String).isEmpty ||
        claims['exp'] is! num ||
        (claims['exp'] as num) * 1000 <= now.millisecondsSinceEpoch ||
        claims['nbf'] is num &&
            (claims['nbf'] as num) * 1000 > now.millisecondsSinceEpoch) {
      throw const FormatException('Invalid ID token claims');
    }
    if (audience is List && audience.length > 1 && claims['azp'] != clientId) {
      throw const FormatException('Invalid ID token authorized party');
    }
    return claims;
  }

  static void _checkScopes(Map<String, dynamic> tokens) {
    if (tokens['access_token'] is! String ||
        (tokens['access_token'] as String).isEmpty ||
        tokens['expires_in'] is! num ||
        (tokens['expires_in'] as num) <= 0 ||
        !(tokens['scope'] as String? ?? '')
            .split(' ')
            .contains('chatgpt.tokens.use.direct')) {
      throw StateError('ChatGPT 요금제 사용 권한이 승인되지 않았습니다.');
    }
  }

  Future<Map<String, dynamic>> _token(Map<String, String> body) async {
    final r = await http
        .post(Uri.parse('$_issuer/api/accounts/oauth/token'), body: body)
        .timeout(const Duration(seconds: 30));
    if (r.statusCode != 200) {
      throw StateError('ChatGPT 인증 처리 실패 (${r.statusCode}). 다시 로그인해 주세요.');
    }
    return Map<String, dynamic>.from(jsonDecode(r.body) as Map);
  }

  Future<String?> accessToken() async {
    final c = await _read();
    if (c == null) return null;
    if (DateTime.now().millisecondsSinceEpoch <
        (c['saved_at_ms'] as int) +
            ((c['expires_in'] as num).toInt() - 60) * 1000) {
      return c['access_token'] as String;
    }
    return _refreshing ??= _refresh(c).whenComplete(() => _refreshing = null);
  }

  Future<String> _refresh(Map<String, dynamic> c) async {
    final refresh = c['refresh_token'] as String?;
    if (refresh == null) throw StateError('ChatGPT에 다시 로그인해 주세요.');
    final tokens = await _token({
      'grant_type': 'refresh_token',
      'client_id': c['client_id'] as String,
      'refresh_token': refresh,
      'resource': _resource,
    });
    _checkScopes(tokens);
    // Do not resurrect a connection that the user signed out during refresh.
    if (await _secure.read(key: _key) != jsonEncode(c)) {
      throw StateError('ChatGPT 연결이 변경되었습니다. 다시 시도해 주세요.');
    }
    await _secure.write(
      key: _key,
      value: jsonEncode({
        ...c,
        ...tokens,
        'saved_at_ms': DateTime.now().millisecondsSinceEpoch,
      }),
    );
    return tokens['access_token'] as String;
  }
}
