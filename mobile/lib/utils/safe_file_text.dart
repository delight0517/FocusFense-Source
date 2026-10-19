import 'dart:convert';
import 'dart:io';

/// Reads/writes text without throwing on legacy or mixed encodings (e.g. Windows logs).
abstract final class SafeFileText {
  static String decodeBytes(List<int> bytes) {
    if (bytes.isEmpty) return '';
    try {
      return utf8.decode(bytes);
    } on FormatException {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }

  static Future<String> readFile(
    File file, {
    int maxBytes = 64 * 1024,
  }) async {
    if (!await file.exists()) return '';
    final int len = await file.length();
    if (len <= maxBytes) {
      return decodeBytes(await file.readAsBytes());
    }
    final RandomAccessFile raf = await file.open();
    try {
      await raf.setPosition(len - maxBytes);
      final List<int> bytes = await raf.read(maxBytes);
      return decodeBytes(bytes);
    } finally {
      await raf.close();
    }
  }

  static Future<void> writeString(
    File file,
    String contents, {
    FileMode mode = FileMode.write,
    bool flush = true,
  }) async {
    await file.writeAsBytes(utf8.encode(contents), mode: mode, flush: flush);
  }

  static Future<void> appendString(
    File file,
    String line, {
    bool flush = false,
  }) async {
    await file.writeAsBytes(
      utf8.encode(line),
      mode: FileMode.append,
      flush: flush,
    );
  }
}
