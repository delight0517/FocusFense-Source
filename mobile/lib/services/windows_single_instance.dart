import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Win32 error returned by `CreateMutex` when the named mutex already exists.
const int _errorAlreadyExists = 183;

/// Held for the process lifetime so the OS keeps the mutex owned until exit.
// ignore: unused_element
int _mutexHandle = 0;

// `CreateMutexW` is not surfaced by the win32 package in every version, so we
// bind it from kernel32 directly. Signature:
//   HANDLE CreateMutexW(LPSECURITY_ATTRIBUTES, BOOL bInitialOwner, LPCWSTR name)
typedef _CreateMutexWNative =
    IntPtr Function(
      Pointer<Void> attrs,
      Int32 initialOwner,
      Pointer<Utf16> name,
    );
typedef _CreateMutexWDart =
    int Function(Pointer<Void> attrs, int initialOwner, Pointer<Utf16> name);

final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');
final _CreateMutexWDart _createMutexW = _kernel32
    .lookupFunction<_CreateMutexWNative, _CreateMutexWDart>('CreateMutexW');

/// Returns `true` when this is the ONLY running instance (caller continues).
/// Returns `false` when another copy already owns the mutex — in that case the
/// existing window is surfaced and the caller should `exit(0)`.
///
/// Why this matters: two `six_clean_room.exe` running at once fight over the
/// rules HTTP server port (17361), the sqlite DB, and the scheduled-task
/// installs. Right after an in-app rebuild, a stray second instance is exactly
/// what makes the block "collapse" (the extension can't reach /rules because
/// the port is already taken). One instance = one source of truth.
bool acquireSingleInstanceOrSurfaceExisting({bool surfaceExisting = true}) {
  if (!Platform.isWindows) return true;
  final Pointer<Utf16> namePtr = 'Global\\SixVPNBlocker_SingleInstance_v2'
      .toNativeUtf16();
  try {
    // Retry briefly: during an in-app rebuild the OLD instance is being killed
    // right as the NEW one launches. Its mutex frees the instant the process
    // dies, so a few short retries let the relaunched copy reliably take
    // ownership instead of seeing "already exists" and exiting (which would
    // leave NO app running until the 5-min watchdog). A genuine user double-
    // launch keeps the mutex held across all retries → we surface + exit.
    // @incident: rebuild_relaunch_mutex_race — retries because the outgoing
    // instance's mutex release can race with rebuild relaunch; without this
    // the new instance exits and the app goes dark until the watchdog fires.
    const int maxTries = 6; // ~1.5s total
    for (int attempt = 0; attempt < maxTries; attempt++) {
      final int h = _createMutexW(nullptr, 1, namePtr);
      final int err = GetLastError();
      if (h == 0) {
        // Could not create the mutex at all — fail open so the app starts.
        return true;
      }
      if (err != _errorAlreadyExists) {
        // First instance — keep the handle for the whole process lifetime.
        _mutexHandle = h;
        return true;
      }
      // Already exists. Release our duplicate handle and wait for the previous
      // owner (likely a dying old build) to let go.
      CloseHandle(h);
      if (attempt < maxTries - 1) {
        sleep(const Duration(milliseconds: 250));
      }
    }
    // Still owned after retries → a real second instance. Surface + bail.
    if (surfaceExisting) _surfaceExistingWindow();
    return false;
  } catch (_) {
    // Any FFI hiccup: fail open (never block the app from starting).
    return true;
  } finally {
    calloc.free(namePtr);
  }
}

/// Best-effort: restore + foreground the already-running app window so a
/// double-clicked shortcut feels like "bring to front" instead of nothing.
void _surfaceExistingWindow() {
  final Pointer<Utf16> titlePtr = 'Focus Fense'.toNativeUtf16();
  try {
    final int hwnd = FindWindow(nullptr, titlePtr);
    if (hwnd != 0) {
      ShowWindow(hwnd, SW_RESTORE);
      SetForegroundWindow(hwnd);
    }
  } catch (_) {
    /* best-effort */
  } finally {
    calloc.free(titlePtr);
  }
}
