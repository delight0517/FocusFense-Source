import 'package:flutter/foundation.dart';

import '../models/post_rebuild_activation_report.dart';

/// Latest post-rebuild activation — UI shows [pendingReport] once per session.
final class PostRebuildActivationNotifier extends ChangeNotifier {
  PostRebuildActivationNotifier._();
  static final PostRebuildActivationNotifier instance =
      PostRebuildActivationNotifier._();

  PostRebuildActivationReport? pendingReport;

  void publish(PostRebuildActivationReport report) {
    pendingReport = report;
    notifyListeners();
  }

  void clearPending() {
    pendingReport = null;
    notifyListeners();
  }
}
