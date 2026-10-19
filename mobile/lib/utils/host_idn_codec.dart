import 'package:punycode/punycode.dart';

/// Converts Unicode domain labels to ASCII punycode (`xn--…`) for hosts/PAC.
abstract final class HostIdnCodec {
  static String toAsciiHost(String host) {
    String h = host.trim().toLowerCase();
    if (h.isEmpty) return h;
    if (h.contains('%')) {
      try {
        h = Uri.decodeComponent(h);
      } catch (_) {
        // Keep percent-encoded form when decode fails.
      }
    }
    final List<String> labels = h.split('.');
    final List<String> out = <String>[];
    for (final String label in labels) {
      if (label.isEmpty) {
        out.add(label);
        continue;
      }
      final bool needsPuny =
          label.runes.any((int codeUnit) => codeUnit > 0x7f);
      if (needsPuny) {
        out.add('xn--${punycodeEncode(label)}');
      } else {
        out.add(label);
      }
    }
    return out.join('.');
  }
}
