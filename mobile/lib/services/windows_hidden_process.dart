import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

/// Windows subprocess helpers that avoid the brief black console flash.
///
/// Console-subsystem tools (`powershell.exe`, `reg.exe`, `cmd.exe`, …) always
/// allocate a console with plain `Process.run`. These use `CREATE_NO_WINDOW`.
const int _createNoWindow = CREATE_NO_WINDOW;
const int _detachedProcess = DETACHED_PROCESS;

// Quiet error mode bits — make a spawned child that fails to initialise stay
// silent instead of popping the modal "reg.exe - Application Error
// (0xc0000142)" dialog. The child inherits the parent's error mode at
// CreateProcess time, so we set these around the spawn then restore.
const int _semFailCriticalErrors = 0x0001;
const int _semNoGpFaultErrorBox = 0x0002;
const int _semNoOpenFileErrorBox = 0x8000;
const int _quietErrorMode =
    _semFailCriticalErrors | _semNoGpFaultErrorBox | _semNoOpenFileErrorBox;

// STATUS_DLL_INIT_FAILED — what Windows returns when a console helper
// (reg.exe/powershell.exe) can't start, usually transient desktop-heap
// pressure when many subprocesses spawn at once. Worth one retry.
const int _statusDllInitFailed = 0xC0000142;
const int _maxSpawnRetries = 2;

/// Set the process-wide error mode to quiet once at startup. Because a child
/// inherits the parent's error mode at creation, this makes EVERY subprocess —
/// including any spawned by Dart's own `Process.run` — stay silent instead of
/// popping the modal "reg.exe - Application Error (0xc0000142)" dialog the user
/// kept seeing. Safe and idempotent; call from `main()`.
void suppressChildProcessErrorDialogs() {
  if (!Platform.isWindows) return;
  try {
    SetErrorMode(_quietErrorMode);
  } catch (_) {/* best-effort */}
}

String _quoteWinArg(String arg) {
  if (arg.isEmpty) return '""';
  if (!arg.contains(' ') &&
      !arg.contains('"') &&
      !arg.contains('\t') &&
      !arg.contains('\n')) {
    return arg;
  }
  return '"${arg.replaceAll('"', r'\"')}"';
}

String buildWindowsCommandLine(String executable, List<String> arguments) {
  final StringBuffer sb = StringBuffer(_quoteWinArg(executable));
  for (final String a in arguments) {
    sb.write(' ');
    sb.write(_quoteWinArg(a));
  }
  return sb.toString();
}

void _configureStartupInfo(
  Pointer<STARTUPINFO> si, {
  required int stdOutWrite,
  required int stdErrWrite,
}) {
  si.ref.cb = sizeOf<STARTUPINFO>();
  si.ref.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
  si.ref.wShowWindow = SW_HIDE;
  si.ref.hStdOutput = stdOutWrite;
  si.ref.hStdError = stdErrWrite;
  si.ref.hStdInput = NULL;
}

Pointer<SECURITY_ATTRIBUTES> _inheritableSa() {
  final Pointer<SECURITY_ATTRIBUTES> sa = calloc<SECURITY_ATTRIBUTES>();
  sa.ref.nLength = sizeOf<SECURITY_ATTRIBUTES>();
  sa.ref.bInheritHandle = TRUE;
  return sa;
}

(int read, int write) _createPipe(Pointer<SECURITY_ATTRIBUTES> sa) {
  final Pointer<IntPtr> read = calloc<IntPtr>();
  final Pointer<IntPtr> write = calloc<IntPtr>();
  if (CreatePipe(read, write, sa, 0) == 0) {
    calloc.free(read);
    calloc.free(write);
    throw WindowsException(GetLastError());
  }
  SetHandleInformation(read.value, HANDLE_FLAG_INHERIT, 0);
  return (read.value, write.value);
}

/// Poll-based async wait — yields the event loop so the UI thread keeps
/// pumping frames while a subprocess runs. `WaitForSingleObject(.., INFINITE)`
/// is a sync FFI call: on the UI isolate it freezes Flutter for the entire
/// subprocess duration and Windows shows "Not Responding" within 5 seconds.
Future<int> _waitForProcessAsync(int hProcess) async {
  // Tiny initial polls catch fast subprocesses (most reg/schtasks calls finish
  // in <50ms), then back off to 50ms so long-running PowerShell scripts don't
  // burn CPU on the poll itself.
  const List<int> backoffMs = <int>[5, 10, 25, 50];
  int idx = 0;
  while (true) {
    final int r = WaitForSingleObject(hProcess, 0);
    if (r != WAIT_TIMEOUT) return r;
    await Future<void>.delayed(Duration(milliseconds: backoffMs[idx]));
    if (idx < backoffMs.length - 1) idx++;
  }
}

Future<Uint8List> _readAllFromPipe(int handle) async {
  // ReadFile reuses this native buffer and finally frees it. Retaining its
  // views corrupts earlier chunks (and single-chunk reads after free).
  final BytesBuilder bytes = BytesBuilder(copy: true);
  final Pointer<Uint8> buffer = calloc<Uint8>(8192);
  final Pointer<DWORD> bytesRead = calloc<DWORD>();
  final Pointer<DWORD> avail = calloc<DWORD>();
  // PeekNamedPipe lets us yield to the event loop while the subprocess is
  // running but hasn't written anything yet. A bare ReadFile blocks the whole
  // isolate (UI thread on Flutter desktop) for the lifetime of the child —
  // the actual root cause of "App is not responding" reports.
  try {
    while (true) {
      final int peekOk =
          PeekNamedPipe(handle, nullptr, 0, nullptr, avail, nullptr);
      if (peekOk == 0) {
        if (GetLastError() == ERROR_BROKEN_PIPE) break;
        // Transient error — yield and retry rather than hard-fail.
        await Future<void>.delayed(const Duration(milliseconds: 25));
        continue;
      }
      if (avail.value == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 15));
        continue;
      }
      final int ok = ReadFile(handle, buffer, 8192, bytesRead, nullptr);
      if (ok == 0) {
        if (GetLastError() == ERROR_BROKEN_PIPE) break;
        throw WindowsException(GetLastError());
      }
      final int n = bytesRead.value;
      if (n == 0) break;
      bytes.add(buffer.asTypedList(n));
    }
  } finally {
    CloseHandle(handle);
    calloc.free(buffer);
    calloc.free(bytesRead);
    calloc.free(avail);
  }
  return bytes.takeBytes();
}

/// Runs [executable] without a console window; waits for exit.
///
/// Retries a transient `0xC0000142` (STATUS_DLL_INIT_FAILED) — Windows can fail
/// to start a console helper under desktop-heap pressure when the app spawns
/// many `reg.exe`/`powershell.exe` at once. The OS error dialog is suppressed
/// via an inherited quiet error mode, so the user never sees the modal box.
Future<ProcessResult> windowsRunHidden(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) async {
  if (!Platform.isWindows) {
    return Process.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
    );
  }

  ProcessResult? last;
  for (int attempt = 0; attempt <= _maxSpawnRetries; attempt++) {
    last = await _runHiddenAttempt(executable, arguments, workingDirectory);
    if (last.exitCode != _statusDllInitFailed) return last;
    // Transient init failure — back off briefly to let desktop heap / loader
    // recover, then retry. Final attempt returns whatever we got.
    if (attempt < _maxSpawnRetries) {
      await Future<void>.delayed(Duration(milliseconds: 120 * (attempt + 1)));
    }
  }
  return last!;
}

Future<ProcessResult> _runHiddenAttempt(
  String executable,
  List<String> arguments,
  String? workingDirectory,
) async {
  final Pointer<SECURITY_ATTRIBUTES> sa = _inheritableSa();
  final (int outRead, int outWrite) = _createPipe(sa);
  final (int errRead, int errWrite) = _createPipe(sa);

  final Pointer<STARTUPINFO> si = calloc<STARTUPINFO>();
  _configureStartupInfo(si, stdOutWrite: outWrite, stdErrWrite: errWrite);

  final Pointer<PROCESS_INFORMATION> pi = calloc<PROCESS_INFORMATION>();
  final String cmd = buildWindowsCommandLine(executable, arguments);
  final Pointer<Utf16> cmdLine = cmd.toNativeUtf16();
  final Pointer<Utf16> cwd = workingDirectory?.toNativeUtf16() ?? nullptr;

  try {
    // Suppress the child's "Application Error" dialog: the child inherits the
    // parent's error mode at creation, so set quiet, spawn, then restore so
    // the Flutter app's own error behaviour is untouched.
    final int prevMode = SetErrorMode(_quietErrorMode);
    final int ok = CreateProcess(
      nullptr,
      cmdLine,
      nullptr,
      nullptr,
      TRUE,
      _createNoWindow,
      nullptr,
      cwd,
      si,
      pi,
    );
    SetErrorMode(prevMode);
    if (ok == 0) throw WindowsException(GetLastError());

    CloseHandle(outWrite);
    CloseHandle(errWrite);
    CloseHandle(pi.ref.hThread);

    final Future<Uint8List> outF = _readAllFromPipe(outRead);
    final Future<Uint8List> errF = _readAllFromPipe(errRead);

    await _waitForProcessAsync(pi.ref.hProcess);
    final Pointer<DWORD> exit = calloc<DWORD>();
    GetExitCodeProcess(pi.ref.hProcess, exit);
    final int code = exit.value;
    calloc.free(exit);
    CloseHandle(pi.ref.hProcess);

    final Uint8List outBytes = await outF;
    final Uint8List errBytes = await errF;
    return ProcessResult(
      pi.ref.dwProcessId,
      code,
      utf8.decode(outBytes, allowMalformed: true),
      utf8.decode(errBytes, allowMalformed: true),
    );
  } finally {
    calloc.free(cmdLine);
    if (cwd != nullptr) calloc.free(cwd);
    calloc.free(si);
    calloc.free(pi);
    calloc.free(sa);
  }
}

/// Child process without a console; stdout/stderr are streamed.
final class WindowsHiddenProcess {
  WindowsHiddenProcess._({
    required this.pid,
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    required void Function() onKill,
  }) : _onKill = onKill;

  final int pid;
  final Future<int> exitCode;
  final Stream<List<int>> stdout;
  final Stream<List<int>> stderr;
  final void Function() _onKill;

  void kill([ProcessSignal signal = ProcessSignal.sigterm]) => _onKill();
}

Future<WindowsHiddenProcess> windowsStartHidden(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) async {
  if (!Platform.isWindows) {
    final Process proc = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      runInShell: false,
    );
    return WindowsHiddenProcess._(
      pid: proc.pid,
      exitCode: proc.exitCode,
      stdout: proc.stdout,
      stderr: proc.stderr,
      onKill: () => proc.kill(),
    );
  }

  final Pointer<SECURITY_ATTRIBUTES> sa = _inheritableSa();
  final (int outRead, int outWrite) = _createPipe(sa);
  final (int errRead, int errWrite) = _createPipe(sa);

  final Pointer<STARTUPINFO> si = calloc<STARTUPINFO>();
  _configureStartupInfo(si, stdOutWrite: outWrite, stdErrWrite: errWrite);

  final Pointer<PROCESS_INFORMATION> pi = calloc<PROCESS_INFORMATION>();
  final String cmd = buildWindowsCommandLine(executable, arguments);
  final Pointer<Utf16> cmdLine = cmd.toNativeUtf16();
  final Pointer<Utf16> cwd = workingDirectory?.toNativeUtf16() ?? nullptr;

  final int prevMode = SetErrorMode(_quietErrorMode);
  final int ok = CreateProcess(
    nullptr,
    cmdLine,
    nullptr,
    nullptr,
    TRUE,
    _createNoWindow,
    nullptr,
    cwd,
    si,
    pi,
  );
  SetErrorMode(prevMode);
  if (ok == 0) {
    final int err = GetLastError();
    calloc.free(cmdLine);
    if (cwd != nullptr) calloc.free(cwd);
    calloc.free(si);
    calloc.free(pi);
    calloc.free(sa);
    throw WindowsException(err);
  }

  CloseHandle(outWrite);
  CloseHandle(errWrite);
  CloseHandle(pi.ref.hThread);

  final int pid = pi.ref.dwProcessId;
  final int hProcess = pi.ref.hProcess;

  final StreamController<List<int>> outCtrl = StreamController<List<int>>();
  final StreamController<List<int>> errCtrl = StreamController<List<int>>();

  Future<void> pump(int handle, StreamController<List<int>> ctrl) async {
    final Pointer<Uint8> buffer = calloc<Uint8>(8192);
    final Pointer<DWORD> nRead = calloc<DWORD>();
    final Pointer<DWORD> avail = calloc<DWORD>();
    try {
      while (true) {
        // Yield the isolate between reads — see _readAllFromPipe.
        final int peekOk =
            PeekNamedPipe(handle, nullptr, 0, nullptr, avail, nullptr);
        if (peekOk == 0) {
          if (GetLastError() == ERROR_BROKEN_PIPE) break;
          await Future<void>.delayed(const Duration(milliseconds: 25));
          continue;
        }
        if (avail.value == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 15));
          continue;
        }
        final int okRead = ReadFile(handle, buffer, 8192, nRead, nullptr);
        if (okRead == 0) {
          if (GetLastError() == ERROR_BROKEN_PIPE) break;
          throw WindowsException(GetLastError());
        }
        if (nRead.value == 0) break;
        ctrl.add(List<int>.from(buffer.asTypedList(nRead.value)));
      }
    } finally {
      CloseHandle(handle);
      calloc.free(buffer);
      calloc.free(nRead);
      calloc.free(avail);
      await ctrl.close();
    }
  }

  unawaited(pump(outRead, outCtrl));
  unawaited(pump(errRead, errCtrl));

  final Future<int> exitCode = () async {
    await _waitForProcessAsync(hProcess);
    final Pointer<DWORD> code = calloc<DWORD>();
    GetExitCodeProcess(hProcess, code);
    final int v = code.value;
    calloc.free(code);
    CloseHandle(hProcess);
    calloc.free(cmdLine);
    if (cwd != nullptr) calloc.free(cwd);
    calloc.free(si);
    calloc.free(pi);
    calloc.free(sa);
    return v;
  }();

  final String taskkill = p.join(
    Platform.environment['WINDIR'] ?? r'C:\Windows',
    'System32',
    'taskkill.exe',
  );

  return WindowsHiddenProcess._(
    pid: pid,
    exitCode: exitCode,
    stdout: outCtrl.stream,
    stderr: errCtrl.stream,
    onKill: () {
      unawaited(
        windowsRunHidden(
          taskkill,
          <String>['/F', '/T', '/PID', '$pid'],
        ),
      );
    },
  );
}

/// Fire-and-forget child — no console flash (rebuild launcher, etc.).
Future<void> windowsStartDetachedHidden(
  String executable,
  List<String> arguments, {
  String? workingDirectory,
}) async {
  if (!Platform.isWindows) {
    await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      mode: ProcessStartMode.detached,
    );
    return;
  }

  final Pointer<STARTUPINFO> si = calloc<STARTUPINFO>();
  si.ref.cb = sizeOf<STARTUPINFO>();
  si.ref.dwFlags = STARTF_USESHOWWINDOW;
  si.ref.wShowWindow = SW_HIDE;

  final Pointer<PROCESS_INFORMATION> pi = calloc<PROCESS_INFORMATION>();
  final String cmd = buildWindowsCommandLine(executable, arguments);
  final Pointer<Utf16> cmdLine = cmd.toNativeUtf16();
  final Pointer<Utf16> cwd = workingDirectory?.toNativeUtf16() ?? nullptr;

  try {
    final int prevMode = SetErrorMode(_quietErrorMode);
    final int ok = CreateProcess(
      nullptr,
      cmdLine,
      nullptr,
      nullptr,
      FALSE,
      _createNoWindow | _detachedProcess,
      nullptr,
      cwd,
      si,
      pi,
    );
    SetErrorMode(prevMode);
    if (ok == 0) throw WindowsException(GetLastError());
    CloseHandle(pi.ref.hThread);
    CloseHandle(pi.ref.hProcess);
  } finally {
    calloc.free(cmdLine);
    if (cwd != nullptr) calloc.free(cwd);
    calloc.free(si);
    calloc.free(pi);
  }
}
