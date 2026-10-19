import 'package:flutter/foundation.dart';

/// Bumps UI (퀵 블록 도크 등) after [QuickBlockService] mutates global rules.
final class QuickBlockController extends ChangeNotifier {
  QuickBlockController._();
  static final QuickBlockController instance = QuickBlockController._();

  void bump() => notifyListeners();
}
