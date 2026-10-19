/// Result of installing or removing OS-level autostart (macOS LaunchAgent,
/// Windows Startup shortcut, etc.).
final class AutostartResult {
  const AutostartResult({required this.ok, required this.message});

  final bool ok;
  final String message;
}
