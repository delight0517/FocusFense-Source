import 'package:flutter/material.dart';

/// Advanced tools are created only while open, so hidden diagnostic timers stop.
class SettingsDisclosure extends StatefulWidget {
  const SettingsDisclosure({
    super.key,
    required this.title,
    required this.subtitle,
    required this.builder,
    this.icon = Icons.tune,
  });

  final String title;
  final String subtitle;
  final WidgetBuilder builder;
  final IconData icon;

  @override
  State<SettingsDisclosure> createState() => _SettingsDisclosureState();
}

class _SettingsDisclosureState extends State<SettingsDisclosure> {
  bool _open = false;

  @override
  Widget build(BuildContext context) => Card(
    child: ExpansionTile(
      leading: Icon(widget.icon),
      title: Text(widget.title),
      subtitle: Text(widget.subtitle),
      onExpansionChanged: (open) => setState(() => _open = open),
      children: [
        if (_open)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
            child: widget.builder(context),
          ),
      ],
    ),
  );
}
