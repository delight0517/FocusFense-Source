/// Snap wall-clock minutes to a grid (default 15 minutes).
int snapMinuteOfDayToStep(int totalMinutes, {int stepMinutes = 15}) {
  final int s = stepMinutes <= 0 ? 1 : stepMinutes;
  final int snapped = ((totalMinutes / s).round() * s).clamp(0, 1440);
  return snapped;
}

/// Converts hour+minute to total minutes, snaps, returns (hour, minute) with hour up to 24 for end-of-day.
({int hour, int minute}) snapTimeOfDayToStep(int hour, int minute, {int stepMinutes = 15}) {
  final int total = hour * 60 + minute;
  final int snapped = snapMinuteOfDayToStep(total, stepMinutes: stepMinutes);
  final int h = snapped ~/ 60;
  final int m = snapped % 60;
  return (hour: h, minute: m);
}
