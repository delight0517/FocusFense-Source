import 'package:flutter/material.dart';

import '../theme/app_colors.dart';
import '../utils/url_rule_detector.dart';

/// One field: URL / domain / channel / keyword — auto-detected hint + add.
class SmartRuleInputBar extends StatefulWidget {
  const SmartRuleInputBar({
    super.key,
    required this.controller,
    required this.onAdd,
    this.hintText = 'URL / 도메인 / 채널 / 키워드 (자동 감지)',
    this.addLabel = '추가',
    this.enabled = true,
  });

  final TextEditingController controller;
  final VoidCallback onAdd;
  final String hintText;
  final String addLabel;
  final bool enabled;

  @override
  State<SmartRuleInputBar> createState() => _SmartRuleInputBarState();
}

class _SmartRuleInputBarState extends State<SmartRuleInputBar> {
  String? _hint;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
    _onTextChanged();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    super.dispose();
  }

  void _onTextChanged() {
    final String? next = UrlRuleDetector.smartRuleHint(widget.controller.text);
    if (next != _hint) {
      setState(() => _hint = next);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                controller: widget.controller,
                enabled: widget.enabled,
                autocorrect: false,
                keyboardType: TextInputType.url,
                decoration: InputDecoration(hintText: widget.hintText),
                onSubmitted: (_) {
                  if (widget.enabled) widget.onAdd();
                },
              ),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: widget.enabled ? widget.onAdd : null,
              child: Text(widget.addLabel),
            ),
          ],
        ),
        if (_hint != null) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            _hint!,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppColors.muted,
                  height: 1.35,
                ),
          ),
        ],
      ],
    );
  }
}
