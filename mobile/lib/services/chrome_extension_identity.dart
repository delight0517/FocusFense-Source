import 'dart:typed_data';

/// Stable Chrome/Edge MV3 extension ID (from bundled manifest `key`).
final class ChromeExtensionIdentity {
  ChromeExtensionIdentity._();

  /// SubjectPublicKeyInfo (DER) base64 — keeps the same extension ID on every machine.
  static const String manifestPublicKeyBase64 =
      'MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEApsJyuZYxNadMB4llGOFC9iaurDEfIw56fgqzVqUoUihUU8Gqjpe6mEL/CQDM3++4WzD0UmGY21eSPVBo/X1nvY8Fgy5V808pVnSexwsG8tvBfbLPjdhedAL8s1Pevulq0UDNksc38XRqmX54/sOeC+Cjd7255UL9cb8zY8v6i2MIS/+L1y5gHGDVzLT/qJrFDfkbxrq4HYX8iOWy9ghq0SNHR+SfKDoVpZblYab1T+yTubP04ufnvz2OpcUGmiEdHt1MYKaqR2ZQxbBCjthOFBGj68cnRZRhbnAYMWiKniMh+/wmjHegEkN+rq86vpb4wKvurnReufmk00h+YKtDnQIDAQAB';

  // ID derives from the public key matching the retained local signing key.
  static const String extensionId = 'popjkofklmidngceakpcokopghehjngo';

  // @incident: crx-signing-id-mismatch — retain the old identity for cleanup,
  // never for a new force-install registration.
  static const String legacyExtensionId = 'lkmhfebcfeabdfednkliegbincbkidba';

  /// Detection-only store identities. Both stores are unpublished: never use
  /// these IDs for permission or force-install routing.
  static const String chromeStoreExtensionId =
      'bhljnpgggfgojcahcbphhdbmbibkcmom';
  static const String edgeStoreExtensionId =
      'bkhjcoegbppfcgfakokcbcddcaepkodn';

  /// IDs recognized only for detection, not permission or force-install routing.
  /// Unpublished store IDs must never be force-installed by this helper.
  static List<String> recognizedExtensionIdsForBrowser(String browserId) {
    switch (browserId) {
      case 'chrome':
        return const <String>[extensionId, chromeStoreExtensionId];
      case 'edge':
        return const <String>[extensionId, edgeStoreExtensionId];
      default:
        return const <String>[extensionId];
    }
  }

  /// Reads the signed CRX3 identity; this is not a signature verifier. Chromium
  /// still verifies the signature itself when installing the package.
  static String readCrx3Identity(List<int> bytes) {
    if (bytes.length < 12 || String.fromCharCodes(bytes.take(4)) != 'Cr24') {
      throw const FormatException('CRX3 header missing');
    }
    final ByteData view = ByteData.sublistView(Uint8List.fromList(bytes));
    final int size = view.getUint32(8, Endian.little);
    if (view.getUint32(4, Endian.little) != 3 ||
        size > 1048576 ||
        12 + size >= bytes.length) {
      throw const FormatException('Invalid CRX3 header size or version');
    }
    List<int> field(List<int> message, int wanted) {
      int offset = 0;
      int read() {
        int value = 0;
        int shift = 0;
        while (offset < message.length && shift < 49) {
          final int byte = message[offset++];
          value += (byte & 127) << shift;
          if ((byte & 128) == 0) return value;
          shift += 7;
        }
        throw const FormatException('Truncated CRX3 protobuf');
      }

      while (offset < message.length) {
        final int tag = read();
        if ((tag & 7) != 2) {
          throw const FormatException('Invalid CRX3 protobuf wire type');
        }
        final int length = read();
        if (offset + length > message.length) {
          throw const FormatException('Truncated CRX3 field');
        }
        final List<int> value = message.sublist(offset, offset + length);
        if ((tag >> 3) == wanted) return value;
        offset += length;
      }
      throw const FormatException('CRX3 identity field missing');
    }

    final List<int> id = field(field(bytes.sublist(12, 12 + size), 10000), 1);
    if (id.length != 16) {
      throw const FormatException('Invalid CRX3 identity length');
    }
    return String.fromCharCodes(<int>[
      for (final int byte in id) ...<int>[97 + (byte >> 4), 97 + (byte & 15)],
    ]);
  }
}
