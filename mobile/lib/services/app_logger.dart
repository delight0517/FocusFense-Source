import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../services/build_identity_service.dart';
import '../utils/safe_file_text.dart';
import 'platform_process.dart';

/// File-backed logger so the user can show us what the app actually did,
/// even after the app is closed. Writes to
/// `<appSupport>/6vpn_logs/app.log` and mirrors to stdout (visible in
/// `flutter run`). Rotates the file once it crosses [_kMaxBytes].
final class AppLogger {
  AppLogger._();
  static final AppLogger instance = AppLogger._();

  static const int _kMaxBytes = 256 * 1024;
  static const int _kLiveMaxChars = 120 * 1024;

  /// Every line is prefixed with this after [setLogTag] (e.g. `App v1.0.0+10 · os · exe`).
  String? _logTag;

  void setLogTag(String? tag) {
    _logTag = tag;
  }

  File? _file;
  Future<void>? _initFuture;
  final List<String> _memBuffer = <String>[];
  final StringBuffer _liveBuffer = StringBuffer();

  /// Rolling ring buffer of the most recent log lines, kept in memory so
  /// the CPU-spike detector (and any other diagnostic surface) can grab
  /// "what was the app doing right before this lag" without parsing the
  /// rotated file. Append-only, cap to [_kRingMax] lines.
  static const int _kRingMax = 200;
  final List<String> _ring = <String>[];

  /// Returns the last [n] log lines (newest last). Caller may copy these
  /// into a spike report / agent prompt.
  List<String> recentLines(int n) {
    if (_ring.length <= n) return List<String>.unmodifiable(_ring);
    return List<String>.unmodifiable(_ring.sublist(_ring.length - n));
  }

  void _pushRing(String line) {
    _ring.add(line);
    if (_ring.length > _kRingMax) {
      _ring.removeRange(0, _ring.length - _kRingMax);
    }
  }

  /// Bumps when [liveText] changes — bind UI for real-time tail.
  final ValueNotifier<int> liveRevision = ValueNotifier<int>(0);

  String get liveText => _liveBuffer.toString();

  Future<void> _ensureInit() {
    return _initFuture ??= _init();
  }

  Future<void> _init() async {
    try {
      final Directory base = await getApplicationSupportDirectory();
      final Directory dir = Directory(p.join(base.path, '6vpn_logs'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      _file = File(p.join(dir.path, 'app.log'));
      if (!await _file!.exists()) {
        await _file!.create();
      }
      // Drain anything buffered before init completed.
      if (_memBuffer.isNotEmpty) {
        await SafeFileText.appendString(_file!, _memBuffer.join(), flush: true);
        _memBuffer.clear();
      }
      await _rotateIfNeeded();
    } catch (e) {
      // Never throw from logger init — logging is best-effort.
      stderr.writeln('[AppLogger] init failed: $e');
    }
  }

  Future<void> _rotateIfNeeded() async {
    final File? f = _file;
    if (f == null) return;
    try {
      final int len = await f.length();
      if (len <= _kMaxBytes) return;
      final File old = File('${f.path}.1');
      if (await old.exists()) await old.delete();
      await f.rename(old.path);
      await File(f.path).create();
    } catch (_) {/* best-effort */}
  }

  void log(String level, String message, {Object? error, StackTrace? stack}) {
    final String ts = DateTime.now().toIso8601String();
    final String tagPrefix = _logTag != null && _logTag!.isNotEmpty
        ? '[${_logTag!}] '
        : '[${BuildIdentityService.kProductDisplayName}] ';
    final StringBuffer sb = StringBuffer()
      ..write('[$ts] ')
      ..write(tagPrefix)
      ..write(level.padRight(5))
      ..write(' ')
      ..write(message);
    if (error != null) sb.write(' | error: $error');
    if (stack != null) sb.write('\n$stack');
    sb.writeln();
    final String line = sb.toString();
    _appendLive(line);
  }

  void _appendLive(String line) {
    // Feed the ring buffer for the spike detector / agent diagnostics.
    _pushRing(line.trimRight());
    _liveBuffer.write(line);
    if (_liveBuffer.length > _kLiveMaxChars) {
      final String tail = _liveBuffer.toString();
      _liveBuffer
        ..clear()
        ..write(tail.substring(tail.length - _kLiveMaxChars));
    }
    liveRevision.value++;
    if (kDebugMode) {
      try {
        stdout.write(line);
      } catch (_) {
        /* Windows GUI: no console */
      }
    }
    final bool flush = line.contains('ERROR') || line.contains('WARN');
    _appendToFile(line, flush: flush);
  }

  void info(String message) => log('INFO', message);
  void warn(String message, {Object? error}) =>
      log('WARN', message, error: error);
  void error(String message, {Object? error, StackTrace? stack}) =>
      log('ERROR', message, error: error, stack: stack);

  void _appendToFile(String line, {bool flush = false}) {
    final File? f = _file;
    if (f == null) {
      _memBuffer.add(line);
      // Trigger init lazily.
      unawaited(_ensureInit());
      return;
    }
    unawaited(_safeAppend(f, line, flush: flush));
  }

  Future<void> _safeAppend(File f, String line, {bool flush = false}) async {
    try {
      await SafeFileText.appendString(f, line, flush: flush);
    } catch (_) {/* best-effort */}
  }

  /// Renames a corrupt [app.log] so reads/writes stop failing (UTF-8 decode errors).
  Future<List<String>> repairLogFileIfNeeded() async {
    final List<String> repairs = <String>[];
    await _ensureInit();
    final File? f = _file;
    if (f == null) return repairs;
    if (!await f.exists()) return repairs;
    try {
      final List<int> bytes = await f.readAsBytes();
      if (bytes.isEmpty) return repairs;
      utf8.decode(bytes);
      return repairs;
    } catch (_) {
      try {
        final String backup =
            '${f.path}.corrupt_${DateTime.now().millisecondsSinceEpoch}';
        await f.rename(backup);
        _file = File(f.path);
        await _file!.create();
        repairs.add('손상된 app.log를 백업하고 새 로그 파일을 만들었습니다');
      } catch (e) {
        repairs.add('app.log 복구 실패: $e');
      }
    }
    return repairs;
  }

  /// Returns the most recent [maxBytes] of log content from disk so the user
  /// can copy/paste it to us for debugging.
  Future<String> readRecent({int maxBytes = 64 * 1024}) async {
    await _ensureInit();
    final File? f = _file;
    if (f == null) return '(로그 파일이 아직 준비되지 않았어요)';
    try {
      if (!await f.exists()) return '(로그 없음)';
      return SafeFileText.readFile(f, maxBytes: maxBytes);
    } catch (e) {
      return '(로그 읽기 실패: $e)';
    }
  }

  /// Path of the on-disk log file, or null if not initialised yet.
  Future<String?> filePath() async {
    await _ensureInit();
    return _file?.path;
  }

  Future<void> clear() async {
    _liveBuffer.clear();
    liveRevision.value++;
    await _ensureInit();
    final File? f = _file;
    if (f == null) return;
    try {
      await SafeFileText.writeString(f, '');
    } catch (_) {}
  }

  Future<void> revealLogFolder() async {
    await _ensureInit();
    final File? f = _file;
    if (f == null) return;
    final Directory dir = f.parent;
    if (!await dir.exists()) return;
    await PlatformProcess.openFolder(dir.path);
  }
}
