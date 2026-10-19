import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pointycastle/api.dart';
import 'package:pointycastle/asymmetric/api.dart';
import 'package:pointycastle/key_generators/rsa_key_generator.dart';
import 'package:pointycastle/key_generators/api.dart';
import 'package:pointycastle/random/fortuna_random.dart';
import 'package:pointycastle/digests/sha256.dart';
import 'package:pointycastle/signers/rsa_signer.dart';
import 'package:six_clean_room/services/chatgpt_sign_in_service.dart';

void main() {
  late AsymmetricKeyPair<PublicKey, PrivateKey> keys;
  late Map<String, dynamic> jwks;
  final now = DateTime.utc(2026, 10, 18);
  String enc(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');
  String number(BigInt n) {
    var hex = n.toRadixString(16);
    if (hex.length.isOdd) hex = '0$hex';
    return enc([
      for (var i = 0; i < hex.length; i += 2)
        int.parse(hex.substring(i, i + 2), radix: 16),
    ]);
  }

  String token(Map<String, dynamic> claims) {
    final payload =
        '${enc(utf8.encode(jsonEncode({'alg': 'RS256', 'kid': 'test-key'})))}.${enc(utf8.encode(jsonEncode(claims)))}';
    final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
      ..init(
        true,
        PrivateKeyParameter<RSAPrivateKey>(keys.privateKey as RSAPrivateKey),
      );
    return '$payload.${enc(signer.generateSignature(Uint8List.fromList(utf8.encode(payload))).bytes)}';
  }

  Map<String, dynamic> claims() => {
    'iss': 'https://auth.openai.com',
    'aud': 'test-client',
    'nonce': 'test-nonce',
    'sub': 'synthetic-account',
    'email': 'fixture@example.test',
    'exp': now.add(const Duration(hours: 1)).millisecondsSinceEpoch ~/ 1000,
  };
  Map<String, dynamic> verify(String value) =>
      ChatGptSignInService.verifyIdToken(
        value,
        jwks,
        clientId: 'test-client',
        nonce: 'test-nonce',
        now: now,
      );
  setUpAll(() {
    final random = FortunaRandom()
      ..seed(KeyParameter(Uint8List.fromList(List.generate(32, (i) => i + 1))));
    final generator = RSAKeyGenerator()
      ..init(
        ParametersWithRandom(
          RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64),
          random,
        ),
      );
    keys = generator.generateKeyPair();
    final public = keys.publicKey as RSAPublicKey;
    jwks = {
      'keys': [
        {
          'kid': 'test-key',
          'kty': 'RSA',
          'n': number(public.modulus!),
          'e': number(public.exponent!),
        },
      ],
    };
  });
  test(
    'valid signed identity is accepted',
    () => expect(verify(token(claims()))['sub'], 'synthetic-account'),
  );
  test('wrong nonce, audience, issuer and expired identity are rejected', () {
    for (final edit in [
      {'nonce': 'other'},
      {'aud': 'other'},
      {'iss': 'https://evil.invalid'},
      {'exp': 0},
      {'sub': ''},
      {
        'aud': ['test-client', 'other'],
        'azp': 'other',
      },
    ]) {
      expect(
        () => verify(token({...claims(), ...edit})),
        throwsFormatException,
      );
    }
  });
  test('tampering and unsigned tokens cannot establish a connection', () {
    final parts = token(claims()).split('.');
    parts[1] = enc(utf8.encode(jsonEncode({...claims(), 'sub': 'tampered'})));
    expect(() => verify(parts.join('.')), throwsFormatException);
    expect(
      () => verify('${enc(utf8.encode('{"alg":"none"}'))}.${parts[1]}.'),
      throwsFormatException,
    );
  });
}
