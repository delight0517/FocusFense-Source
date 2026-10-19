import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/build_identity_service.dart';
import '../theme/app_colors.dart';

/// Bottom build stamp — tap to copy full build identity for support/screenshots.
class BuildIdentityStrip extends StatefulWidget {
  const BuildIdentityStrip({super.key, required this.desktopStyle});

  /// Uses [MacColors] when true (macOS/Windows shell), else [AppColors].
  final bool desktopStyle;

  @override
  State<BuildIdentityStrip> createState() => _BuildIdentityStripState();
}

class _BuildIdentityStripState extends State<BuildIdentityStrip> {
  String _line = BuildIdentityService.kProductDisplayName;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final String s = await BuildIdentityService.instance.shortUiLine();
      if (mounted) setState(() => _line = s);
    } catch (_) {
      /* package_info may fail */
    }
  }

  Future<void> _copy(BuildContext context) async {
    try {
      final String full = await BuildIdentityService.instance.summaryLine();
      await Clipboard.setData(ClipboardData(text: full));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('앱 이름·버전·빌드 번호를 복사했습니다.'),
          duration: Duration(seconds: 2),
        ),
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    const Color fg = Color(0xFF111827);
    final Color accent = widget.desktopStyle
        ? MacColors.secondary
        : AppColors.accent;
    final Color bg = widget.desktopStyle
        ? Colors.white.withValues(alpha: 0.92)
        : Colors.white.withValues(alpha: 0.96);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => _copy(context),
        onLongPress: () => _copy(context),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(12, 5, 12, 6),
          decoration: BoxDecoration(
            color: bg,
            border: Border(
              top: BorderSide(
                color: widget.desktopStyle
                    ? MacColors.hairline
                    : AppColors.muted.withValues(alpha: 0.25),
              ),
            ),
          ),
          child: Row(
            children: <Widget>[
              Icon(Icons.info_outline, size: 13, color: accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _line,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: fg,
                    fontSize: 11,
                    height: 1.25,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.copy_rounded, size: 13, color: accent),
              const SizedBox(width: 4),
              Text(
                '탭하여 복사',
                style: TextStyle(
                  color: accent,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
