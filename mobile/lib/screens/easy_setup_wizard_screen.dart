import 'package:flutter/material.dart';

import 'one_tap_block_screen.dart';

/// The first-run and manual setup entries share the same accessible flow.
/// Existing recovery preferences are preserved; no setup toggles are forced here.
class EasySetupWizardScreen extends StatelessWidget {
  const EasySetupWizardScreen({super.key});

  @override
  Widget build(BuildContext context) => const OneTapBlockScreen();
}
