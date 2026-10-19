/// Rolling “urge buffer” for schedule edits while a schedule is [locked].
///
/// Uses **device local wall clock** ([DateTime.now] in the device timezone).
/// There is no separate in-app “preview timezone” in this codebase; changing
/// the OS date/time or zone updates the same clock used for enforcement.
library;

/// Default horizon: user should ride out impulses for roughly this long
/// before the slice of the timetable that overlaps “right now” can be edited.
const Duration kScheduleUrgeEditHorizon = Duration(hours: 2);

/// Half-open overlap test: [a0,a1) intersects [b0,b1).
bool _intervalsOverlapHalfOpen(DateTime a0, DateTime a1, DateTime b0, DateTime b1) =>
    a0.isBefore(a1) && b0.isBefore(b1) && a0.isBefore(b1) && b0.isBefore(a1);

/// Yields each calendar midnight from [rangeStart] through [rangeEnd] (inclusive of both dates).
Iterable<DateTime> _midnightsTouching(DateTime rangeStart, DateTime rangeEnd) sync* {
  final DateTime a = rangeStart.isBefore(rangeEnd) ? rangeStart : rangeEnd;
  final DateTime b = rangeStart.isBefore(rangeEnd) ? rangeEnd : rangeStart;
  DateTime d = DateTime(a.year, a.month, a.day);
  final DateTime last = DateTime(b.year, b.month, b.day);
  while (!d.isAfter(last)) {
    yield d;
    d = d.add(const Duration(days: 1));
  }
}

/// Returns true when this recurring slot has at least one calendar instance
/// whose absolute local interval intersects **[now, now + horizon)**.
///
/// [day] follows the app convention: **0 = Monday … 6 = Sunday** (same as
/// `DateTime.weekday - 1`).
bool scheduleSlotTouchesUrgeWindow(
  int day,
  int startMinute,
  int endMinute,
  DateTime now, {
  Duration horizon = kScheduleUrgeEditHorizon,
}) {
  if (day < 0 || day > 6) return false;
  if (startMinute < 0 || endMinute > 1440 || startMinute >= endMinute) {
    return false;
  }
  final DateTime w0 = now;
  final DateTime w1 = now.add(horizon);
  final int dartWeekday = day + 1; // Monday = 1 in Dart
  for (final DateTime midnight in _midnightsTouching(w0, w1)) {
    if (midnight.weekday != dartWeekday) continue;
    final DateTime slotStart =
        midnight.add(Duration(minutes: startMinute));
    final DateTime slotEnd =
        midnight.add(Duration(minutes: endMinute));
    if (_intervalsOverlapHalfOpen(w0, w1, slotStart, slotEnd)) {
      return true;
    }
  }
  return false;
}

/// Expands the legacy single-interval + weekday mask model into concrete
/// `(day, start, end)` chunks (same rules as [schedule_edit_screen] legacy import).
Iterable<({int day, int start, int end})> expandLegacyScheduleMask(
  int startMinute,
  int endMinute,
  int daysMask,
) sync* {
  for (int d = 0; d < 7; d++) {
    if ((daysMask & (1 << d)) == 0) continue;
    if (startMinute == endMinute) {
      yield (day: d, start: 0, end: 1440);
    } else if (startMinute < endMinute) {
      yield (day: d, start: startMinute, end: endMinute);
    } else {
      yield (day: d, start: startMinute, end: 1440);
      yield (day: (d + 1) % 7, start: 0, end: endMinute);
    }
  }
}

/// True if [newStart]/[newEnd] **narrows** coverage vs the old slot while the
/// old slot still intersects the rolling urge window — expanding the window
/// (later end, earlier start) is allowed so e.g. 00:00–07:00 → 00:00–07:45 works.
bool urgeSlotTighteningBlocked({
  required int day,
  required int oldStart,
  required int oldEnd,
  required int newStart,
  required int newEnd,
  required DateTime now,
  Duration horizon = kScheduleUrgeEditHorizon,
}) {
  if (!scheduleSlotTouchesUrgeWindow(day, oldStart, oldEnd, now, horizon: horizon)) {
    return false;
  }
  if (newStart <= oldStart && newEnd >= oldEnd) {
    return false;
  }
  return true;
}

/// True if **any** slot row or legacy row overlaps the urge window.
bool scheduleDataTouchesUrgeWindow({
  required List<Map<String, Object?>> slotRows,
  required int legacyStart,
  required int legacyEnd,
  required int legacyDaysMask,
  required DateTime now,
  Duration horizon = kScheduleUrgeEditHorizon,
}) {
  if (slotRows.isNotEmpty) {
    for (final Map<String, Object?> r in slotRows) {
      final Object? d = r['day'];
      final Object? s = r['start_minute'];
      final Object? e = r['end_minute'];
      if (d is! int || s is! int || e is! int) continue;
      if (scheduleSlotTouchesUrgeWindow(d, s, e, now, horizon: horizon)) {
        return true;
      }
    }
    return false;
  }
  for (final ({int day, int start, int end}) chunk
      in expandLegacyScheduleMask(legacyStart, legacyEnd, legacyDaysMask)) {
    if (scheduleSlotTouchesUrgeWindow(
      chunk.day,
      chunk.start,
      chunk.end,
      now,
      horizon: horizon,
    )) {
      return true;
    }
  }
  return false;
}
