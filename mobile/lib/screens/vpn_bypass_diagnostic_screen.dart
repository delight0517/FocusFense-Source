import 'package:flutter/material.dart';

import '../widgets/vpn_bypass_diagnostic_panel.dart';

/// Full-screen wrapper for [VpnBypassDiagnosticPanel].
class VpnBypassDiagnosticScreen extends StatelessWidget {
  const VpnBypassDiagnosticScreen({super.key, this.initialHost});

  final String? initialHost;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('브라우저 우회 자가 진단')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          VpnBypassDiagnosticPanel(initialHost: initialHost),
        ],
      ),
    );
  }
}
