/// Ring buffer of hosts reported by the browser extension (`POST /ingest`).
final class RecentSiteEvents {
  RecentSiteEvents._();
  static final RecentSiteEvents instance = RecentSiteEvents._();

  static const int _kMax = 40;

  final List<RecentSiteEvent> _events = <RecentSiteEvent>[];

  void record(String host, {int seconds = 0}) {
    final String h = host.trim().toLowerCase();
    if (h.isEmpty || h == 'localhost' || h == '127.0.0.1') return;
    final DateTime now = DateTime.now();
    _events.insert(
      0,
      RecentSiteEvent(host: h, at: now, seconds: seconds),
    );
    if (_events.length > _kMax) {
      _events.removeRange(_kMax, _events.length);
    }
  }

  List<RecentSiteEvent> snapshot() =>
      List<RecentSiteEvent>.unmodifiable(_events);
}

class RecentSiteEvent {
  const RecentSiteEvent({
    required this.host,
    required this.at,
    required this.seconds,
  });

  final String host;
  final DateTime at;
  final int seconds;
}
