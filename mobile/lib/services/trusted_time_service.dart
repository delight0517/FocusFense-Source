import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'app_logger.dart';

/// NTP-anchored time that survives the user dragging the system clock
/// backwards to "skip" a scheduled-block window.
///
/// **Why this exists.** Schedule-based blocks (e.g. "block YouTube from
/// 22:00–06:00") previously read `DateTime.now()` directly. A user could
/// open Windows Settings > Time & Language, turn off "Set time
/// automatically", and roll the clock back to noon — skipping the entire
/// blocked window. This service detects that case and gives the rest of
/// the app a clock the user cannot trivially poison.
///
/// **How it works.**
///   1. On `init()` and every [_kRefreshInterval] thereafter, send a
///      48-byte SNTP query (RFC 4330) to `time.windows.com`.
///   2. Anchor the response timestamp against `Stopwatch.elapsed` (a
///      monotonic counter Dart guarantees does NOT track the wallclock).
///   3. [now] returns `ntpAnchor + monotonicElapsedSinceAnchor`. Result
///      is immune to local clock jumps for the lifetime of the process.
///   4. On every [now] call, compare with `DateTime.now()` — if they
///      diverge by more than [_kTamperThreshold], surface
///      [isClockTampered] = true for the strictest-policy fallback.
///
/// **Failure mode.** If the NTP fetch fails (no network at boot, ICMP
/// blocked, etc.) [now] falls back to `DateTime.now()` and
/// [isAnchored] stays false. Schedule code can decide whether to fail
/// open or closed via [strictNow].
final class TrustedTimeService {
  TrustedTimeService._();
  static final TrustedTimeService instance = TrustedTimeService._();

  /// Public hosts we'll round-robin through. The first one that responds
  /// within [_kRequestTimeout] is used. Microsoft's pool and the public
  /// NTP pool are both fine; one is enough to anchor.
  static const List<String> _kNtpHosts = <String>[
    'time.windows.com',
    'time.google.com',
    'pool.ntp.org',
  ];
  static const int _kNtpPort = 123;
  static const Duration _kRequestTimeout = Duration(seconds: 4);
  static const Duration _kRefreshInterval = Duration(hours: 6);

  /// If trusted vs local wallclock disagree by more than this, the local
  /// clock is considered tampered. Five minutes is comfortably above
  /// normal clock drift (~seconds/day on consumer hardware) and below any
  /// meaningful block-window minimum (typically ≥30 min).
  static const Duration _kTamperThreshold = Duration(minutes: 5);

  // NTP epoch starts 1900-01-01; Unix epoch is 1970-01-01.
  // Difference = 70 years + 17 leap days = 2208988800 seconds.
  static const int _kNtpUnixOffsetSeconds = 2208988800;

  DateTime? _ntpAnchor;
  final Stopwatch _monotonic = Stopwatch();
  int _monotonicAtAnchorMs = 0;
  Timer? _refreshTimer;
  bool _lastTamperFlag = false;
  DateTime? _firstTamperDetectedAt;

  /// True once we've successfully anchored against at least one NTP server.
  bool get isAnchored => _ntpAnchor != null;

  /// True if the most recent [now] call detected the local clock diverging
  /// from the NTP-anchored clock by more than [_kTamperThreshold]. Reset
  /// to false the moment they agree again, so call this right after [now]
  /// and treat it as a snapshot.
  bool get isClockTampered => _lastTamperFlag;

  /// First time we detected tampering this session (null if never).
  /// Persisted across `now()` calls so the diagnostic screen can show
  /// "clock was moved at 14:32" instead of just a transient flag.
  DateTime? get firstTamperedAt => _firstTamperDetectedAt;

  Future<void> init() async {
    if (_monotonic.isRunning) return;
    _monotonic.start();
    await _refresh();
    _refreshTimer ??=
        Timer.periodic(_kRefreshInterval, (_) => unawaited(_refresh()));
  }

  /// Best-effort trusted time. Falls back to `DateTime.now()` until the
  /// first NTP fetch succeeds. Cheap — no I/O, just arithmetic on cached
  /// state.
  DateTime now() {
    final DateTime? anchor = _ntpAnchor;
    if (anchor == null) {
      _lastTamperFlag = false;
      return DateTime.now();
    }
    final int elapsedMs =
        _monotonic.elapsedMilliseconds - _monotonicAtAnchorMs;
    final DateTime trusted = anchor.add(Duration(milliseconds: elapsedMs));
    final DateTime local = DateTime.now();
    final Duration delta = trusted.difference(local).abs();
    _lastTamperFlag = delta > _kTamperThreshold;
    if (_lastTamperFlag && _firstTamperDetectedAt == null) {
      _firstTamperDetectedAt = trusted;
      AppLogger.instance.warn(
        'trusted_time: clock tamper detected '
        'local=$local trusted=$trusted delta=${delta.inSeconds}s',
      );
    }
    return trusted;
  }

  /// "Strict" mode for schedule evaluators: if we have NO anchor at all,
  /// returns null so the caller can decide (default-deny / default-allow).
  DateTime? strictNow() => isAnchored ? now() : null;

  /// Force-refresh from NTP. Returns true on success. Exposed so the
  /// diagnostic screen can offer a "re-sync now" button.
  Future<bool> refreshNow() => _refresh();

  Future<bool> _refresh() async {
    for (final String host in _kNtpHosts) {
      try {
        final DateTime? t = await _queryNtp(host);
        if (t == null) continue;
        _ntpAnchor = t;
        _monotonicAtAnchorMs = _monotonic.elapsedMilliseconds;
        AppLogger.instance.info(
          'trusted_time: anchored via $host @ $t (local=${DateTime.now()})',
        );
        return true;
      } catch (e) {
        AppLogger.instance.warn('trusted_time: $host failed: $e');
      }
    }
    AppLogger.instance.warn('trusted_time: all NTP hosts failed');
    return false;
  }

  /// Sends an SNTP v4 client request and returns the transmit timestamp
  /// from the response, converted to UTC `DateTime`. Returns null on
  /// any protocol / network failure.
  Future<DateTime?> _queryNtp(String host) async {
    final List<InternetAddress> addrs = await InternetAddress.lookup(
      host,
      type: InternetAddressType.IPv4,
    ).timeout(_kRequestTimeout);
    if (addrs.isEmpty) return null;

    final RawDatagramSocket socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      0,
    );
    final Completer<DateTime?> done = Completer<DateTime?>();
    late final StreamSubscription<RawSocketEvent> sub;
    Timer? timeout;

    void finish(DateTime? result) {
      if (done.isCompleted) return;
      timeout?.cancel();
      sub.cancel();
      socket.close();
      done.complete(result);
    }

    sub = socket.listen((RawSocketEvent ev) {
      if (ev != RawSocketEvent.read) return;
      final Datagram? dg = socket.receive();
      if (dg == null || dg.data.length < 48) return;
      // Transmit timestamp is at bytes 40..47.
      // Seconds = bytes 40..43 (big-endian unsigned 32-bit), counted from
      // NTP epoch 1900-01-01. Fractional = bytes 44..47 in units of
      // 1/2^32 of a second.
      final ByteData bd = ByteData.sublistView(dg.data);
      final int seconds = bd.getUint32(40);
      final int fraction = bd.getUint32(44);
      if (seconds == 0) {
        finish(null);
        return;
      }
      final int unixSeconds = seconds - _kNtpUnixOffsetSeconds;
      // fraction / 2^32 * 1e9 → nanoseconds; we only need millis.
      final int ms = ((fraction / 0x100000000) * 1000).round();
      finish(
        DateTime.fromMillisecondsSinceEpoch(
          unixSeconds * 1000 + ms,
          isUtc: true,
        ),
      );
    });

    timeout = Timer(_kRequestTimeout, () => finish(null));

    final Uint8List packet = Uint8List(48);
    // LI(0) | VN(4) | Mode(3 = client) = 0x23.
    packet[0] = 0x23;
    socket.send(packet, addrs.first, _kNtpPort);

    return done.future;
  }

  void dispose() {
    _refreshTimer?.cancel();
    _refreshTimer = null;
    _monotonic.stop();
  }
}
