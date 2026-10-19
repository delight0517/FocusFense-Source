import 'package:flutter/foundation.dart';

enum NewBrowserInstallPhase {
  detected,
  applying,
  done,
  failed,
}

/// UI용 — 새 브라우저 설치 감지·적용 진행 상태.
final class NewBrowserInstallEvent {
  const NewBrowserInstallEvent({
    required this.browserId,
    required this.displayName,
    required this.phase,
    required this.messageKo,
    this.at,
  });

  final String browserId;
  final String displayName;
  final NewBrowserInstallPhase phase;
  final String messageKo;
  final DateTime? at;

  bool get isActive =>
      phase == NewBrowserInstallPhase.detected ||
      phase == NewBrowserInstallPhase.applying;
}

final class NewBrowserInstallNotifier extends ChangeNotifier {
  NewBrowserInstallNotifier._();
  static final NewBrowserInstallNotifier instance = NewBrowserInstallNotifier._();

  NewBrowserInstallEvent? _latest;

  NewBrowserInstallEvent? get latest => _latest;

  void report(NewBrowserInstallEvent event) {
    _latest = event;
    notifyListeners();
  }

  void clearIfDone() {
    if (_latest == null) return;
    if (_latest!.phase == NewBrowserInstallPhase.detected ||
        _latest!.phase == NewBrowserInstallPhase.applying) {
      return;
    }
    _latest = null;
    notifyListeners();
  }
}
