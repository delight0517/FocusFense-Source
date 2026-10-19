import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/services/chrome_extension_identity.dart';

Uint8List fixture(List<int> identity) {
  final List<int> signed = <int>[10, identity.length, ...identity];
  final List<int> header = <int>[130, 241, 4, signed.length, ...signed];
  final ByteData prefix = ByteData(12)
    ..setUint32(0, 0x34327243, Endian.little)
    ..setUint32(4, 3, Endian.little)
    ..setUint32(8, header.length, Endian.little);
  return Uint8List.fromList(<int>[
    ...prefix.buffer.asUint8List(),
    ...header,
    80,
    75,
    3,
    4,
  ]);
}

void main() {
  test('reads the signed-header ID rather than assuming the manifest ID', () {
    expect(
      ChromeExtensionIdentity.readCrx3Identity(
        fixture(List<int>.filled(16, 0)),
      ),
      'a' * 32,
    );
    final String expected = ChromeExtensionIdentity.extensionId;
    final List<int> bytes = List<int>.generate(
      16,
      (int i) =>
          ((expected.codeUnitAt(i * 2) - 97) << 4) |
          (expected.codeUnitAt(i * 2 + 1) - 97),
    );
    expect(ChromeExtensionIdentity.readCrx3Identity(fixture(bytes)), expected);
  });

  test(
    'rejects truncated or oversized CRX headers and unsupported versions',
    () {
      expect(
        () => ChromeExtensionIdentity.readCrx3Identity(<int>[1, 2, 3]),
        throwsFormatException,
      );
      final Uint8List wrongVersion = fixture(List<int>.filled(16, 0));
      wrongVersion[4] = 2;
      expect(
        () => ChromeExtensionIdentity.readCrx3Identity(wrongVersion),
        throwsFormatException,
      );
      final Uint8List oversized = fixture(List<int>.filled(16, 0));
      ByteData.sublistView(oversized).setUint32(8, 0x7fffffff, Endian.little);
      expect(
        () => ChromeExtensionIdentity.readCrx3Identity(oversized),
        throwsFormatException,
      );
    },
  );

  test(
    'rejects an invalid signed identity length and a malformed protobuf',
    () {
      expect(
        () => ChromeExtensionIdentity.readCrx3Identity(
          fixture(List<int>.filled(15, 0)),
        ),
        throwsFormatException,
      );
      final Uint8List malformed = fixture(List<int>.filled(16, 0));
      malformed[12] =
          128; // wire type 0 is not a length-delimited header field.
      expect(
        () => ChromeExtensionIdentity.readCrx3Identity(malformed),
        throwsFormatException,
      );
    },
  );
}
