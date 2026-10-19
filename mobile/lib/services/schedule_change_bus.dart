import 'package:flutter/foundation.dart';

/// Tiny cross-screen broadcast: anything that mutates schedules from outside
/// `SchedulesScreen` itself (e.g. the standalone Chat tab) calls [notify] so
/// `SchedulesScreen` — kept alive across tab switches by go_router's
/// `IndexedStack`, so its `initState` never runs again — knows to reload
/// instead of showing stale data until the user happens to trigger a reload
/// some other way.
final class ScheduleChangeBus extends ChangeNotifier {
  ScheduleChangeBus._();
  static final ScheduleChangeBus instance = ScheduleChangeBus._();

  void notify() => notifyListeners();
}
