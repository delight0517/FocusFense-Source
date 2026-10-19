import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'app_logger.dart';
import 'platform_process.dart';

/// Append-only error / diagnostic timeline that survives abrupt process death.
///
/// Writes under **Documents/SixVPN_Blocker_Debug/** (and mirrors path after
/// [warmup]) using **synchronous** IO + `flushSync` so a kill right after an
/// error still leaves the last line on disk.
final class CrashJournalService {
  CrashJournalService._();
  static final CrashJournalService instance = CrashJournalService._();

  /// Included on every JSONL row after [setLogTag] (matches [AppLogger] tag).
  String? _logTag;

  void setLogTag(String? tag) {
    _logTag = tag;
  }

  static const String _kDirName = 'SixVPN_Blocker_Debug';
  static const String _kFileName = 'crash_journal.jsonl';
  static const int _kMaxBytes = 512 * 1024;

  String? _resolvedDir;

  /// Call early from `main` so async path is known; sync path still works
  /// without this via USERPROFILE/HOME.
  Future<void> warmup() async {
    try {
      final Directory d = await getApplicationDocumentsDirectory();
      _resolvedDir = p.join(d.path, _kDirName);
      final Directory dir = Directory(_resolvedDir!);
      if (!await dir.exists()) await dir.create(recursive: true);
    } catch (e) {
      AppLogger.instance.warn('CrashJournal warmup failed', error: e);
    }
  }

  Directory _syncRoot() {
    if (_resolvedDir != null) {
      return Directory(_resolvedDir!);
    }
    final String? home = Platform.environment['USERPROFILE'] ??
        Platform.environment['HOME'];
    if (home != null && home.isNotEmpty) {
      return Directory(p.join(home, 'Documents', _kDirName));
    }
    return Directory.systemTemp;
  }

  String get _journalPath => p.join(_syncRoot().path, _kFileName);

  /// Human-readable path for UI / Cursor agents (folder that always exists
  /// after first write).
  String get debugFolderPath => _syncRoot().path;

  void _rotateIfHugeSync() {
    try {
      final File f = File(_journalPath);
      if (!f.existsSync()) return;
      if (f.lengthSync() <= _kMaxBytes) return;
      final File bak = File('$_journalPath.bak');
      if (bak.existsSync()) bak.deleteSync();
      f.renameSync(bak.path);
    } catch (_) {/* best-effort */}
  }

  void record({
    required String kind,
    required String message,
    Object? error,
    StackTrace? stack,
  }) {
    final Map<String, Object?> map = <String, Object?>{
      'ts': DateTime.now().toUtc().toIso8601String(),
      'tsLocal': DateTime.now().toIso8601String(),
      'kind': kind,
      'message': message,
      if (_logTag != null) 'appBuild': _logTag,
      if (error != null) 'error': error.toString(),
      if (stack != null) 'stack': stack.toString(),
    };
    final String line = jsonEncode(map);
    try {
      final Directory root = _syncRoot();
      root.createSync(recursive: true);
      _rotateIfHugeSync();
      final File f = File(_journalPath);
      final RandomAccessFile raf = f.openSync(mode: FileMode.append);
      try {
        raf.writeFromSync(utf8.encode('$line\n'));
        raf.flushSync();
      } finally {
        raf.closeSync();
      }
    } catch (_) {/* never throw from crash logger */}
  }

  void recordZoneError(Object error, StackTrace stack) {
    record(
      kind: 'zone',
      message: 'Uncaught zone error',
      error: error,
      stack: stack,
    );
  }

  void recordFlutterError(Object exception, StackTrace stack) {
    record(
      kind: 'flutter',
      message: 'Flutter framework error',
      error: exception,
      stack: stack,
    );
  }

  void recordDispatcherError(Object error, StackTrace stack) {
    record(
      kind: 'platform',
      message: 'PlatformDispatcher.onError',
      error: error,
      stack: stack,
    );
  }

  /// Reads newest entries last (tail of file), capped for UI.
  Future<List<String>> readTailLines({int maxLines = 400}) async {
    try {
      final File f = File(_journalPath);
      if (!await f.exists()) return <String>[];
      final String all = await f.readAsString();
      final List<String> lines =
          all.split('\n').where((String s) => s.trim().isNotEmpty).toList();
      if (lines.length <= maxLines) return lines;
      return lines.sublist(lines.length - maxLines);
    } catch (e) {
      return <String>['(읽기 실패: $e)'];
    }
  }

  Future<String> readRawForExport({int maxJournalBytes = 256 * 1024}) async {
    final StringBuffer sb = StringBuffer();
    sb.writeln('=== SixVPN crash journal (jsonl, newest at bottom) ===');
    sb.writeln('folder: ${debugFolderPath}');
    try {
      final File f = File(_journalPath);
      if (await f.exists()) {
        final int len = await f.length();
        if (len <= maxJournalBytes) {
          sb.writeln(await f.readAsString());
        } else {
          final RandomAccessFile raf = await f.open();
          try {
            await raf.setPosition(len - maxJournalBytes);
            final List<int> bytes = await raf.read(maxJournalBytes);
            sb.writeln(String.fromCharCodes(bytes));
          } finally {
            await raf.close();
          }
        }
      } else {
        sb.writeln('(journal file empty or missing)');
      }
    } catch (e) {
      sb.writeln('(journal read error: $e)');
    }
    return sb.toString();
  }

  Future<void> clear() async {
    try {
      final File f = File(_journalPath);
      if (await f.exists()) await f.delete();
      final File bak = File('$_journalPath.bak');
      if (await bak.exists()) await bak.delete();
    } catch (_) {}
  }

  /// Opens the debug folder in Explorer / Finder so agents or the user can
  /// grab `crash_journal.jsonl` even if the UI cannot start.
  Future<void> revealDebugFolder() async {
    try {
      await warmup();
      final Directory root = _syncRoot();
      root.createSync(recursive: true);
      await PlatformProcess.openFolder(root.path);
    } catch (e) {
      AppLogger.instance.warn('CrashJournal reveal failed', error: e);
    }
  }
}
