import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/build_identity_service.dart';
import '../theme/app_colors.dart';

/// Always-visible top-left build stamp (screenshots + AI version match).
class BuildIdentityCornerBadge extends StatefulWidget {
  const BuildIdentityCornerBadge({super.key, this.desktopStyle = false});

  final bool desktopStyle;

  @override
  State<BuildIdentityCornerBadge> createState() =>
      _BuildIdentityCornerBadgeState();
}

class _BuildIdentityCornerBadgeState extends State<BuildIdentityCornerBadge> {
  String _short = BuildIdentityService.kProductDisplayName;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final String s = await BuildIdentityService.instance.shortUiLine();
      if (mounted) setState(() => _short = s);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final Color bg = widget.desktopStyle
        ? MacColors.surface.withValues(alpha: 0.92)
        : Colors.black.withValues(alpha: 0.55);
    final Color fg = widget.desktopStyle ? MacColors.ink : Colors.white;
    final Color border = widget.desktopStyle
        ? MacColors.hairline
        : Colors.white24;

    return Material(
      color: Colors.transparent,
      elevation: 2,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () async {
          try {
            final String full =
                await BuildIdentityService.instance.summaryLine();
            await Clipboard.setData(ClipboardData(text: full));
            if (!context.mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('앱 이름·버전·빌드 번호를 복사했습니다.'),
                duration: Duration(seconds: 2),
              ),
            );
          } catch (_) {}
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: border),
          ),
          child: Text(
            _short,
            style: TextStyle(
              color: fg,
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              height: 1.2,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }
}
