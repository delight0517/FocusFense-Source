/// Steps shown after 「지금 적용」 (hosts + DNS lock + policies).
final class ApplyActivationReport {
  const ApplyActivationReport({
    required this.success,
    required this.steps,
    required this.summary,
  });

  final bool success;
  final List<ApplyActivationStep> steps;
  final String summary;
}

final class ApplyActivationStep {
  const ApplyActivationStep({
    required this.id,
    required this.label,
    required this.ok,
    required this.detail,
  });

  final String id;
  final String label;
  final bool ok;
  final String detail;
}
