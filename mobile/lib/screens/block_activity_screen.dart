import 'package:flutter/material.dart';

import '../widgets/block_activity_live_panel.dart';

/// Full-screen live block activity (settings / diagnostics entry).
class BlockActivityScreen extends StatelessWidget {
  const BlockActivityScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('실시간 차단 · 활동'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: const <Widget>[
          BlockActivityLivePanel(maxHeight: 420),
        ],
      ),
    );
  }
}
