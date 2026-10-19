/// JSON written by `tools/Rebuild-6VPN-Windows.ps1` for in-app progress UI.
final class WindowsRebuildStatus {
  const WindowsRebuildStatus({
    required this.phase,
    required this.message,
    this.progress,
    this.requestAppExit = false,
    this.exitCode,
    this.exePath,
    this.updatedAt,
  });

  final String phase;
  final String message;
  final double? progress;
  final bool requestAppExit;
  final int? exitCode;
  final String? exePath;
  final String? updatedAt;

  bool get isFailed => phase == 'failed';
  bool get isDone => phase == 'done';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is WindowsRebuildStatus &&
        other.phase == phase &&
        other.message == message &&
        other.progress == progress &&
        other.requestAppExit == requestAppExit &&
        other.exitCode == exitCode &&
        other.exePath == exePath &&
        other.updatedAt == updatedAt;
  }

  @override
  int get hashCode => Object.hash(
        phase,
        message,
        progress,
        requestAppExit,
        exitCode,
        exePath,
        updatedAt,
      );

  static WindowsRebuildStatus? fromJson(Map<String, Object?> json) {
    final String phase = '${json['phase'] ?? ''}'.trim();
    if (phase.isEmpty) return null;
    final Object? prog = json['progress'];
    double? progress;
    if (prog is num) {
      progress = prog.toDouble().clamp(0.0, 1.0);
    }
    return WindowsRebuildStatus(
      phase: phase,
      message: '${json['message'] ?? ''}',
      progress: progress,
      requestAppExit: json['requestAppExit'] == true,
      exitCode: json['exitCode'] is int
          ? json['exitCode'] as int
          : int.tryParse('${json['exitCode']}'),
      exePath: json['exePath'] as String?,
      updatedAt: json['updatedAt'] as String?,
    );
  }
}
