import 'package:flutter/material.dart';

/// Quiet, low-glare colors shared by every Focus Fense platform.
/// Cool ink and a restrained cyan accent give the UI a modern feel without
/// turning every card or status into a competing focal point.
abstract final class AppColors {
  static const Color background = Color(0xFFF4F7FA);
  static const Color surface = Color(0xFFFCFDFE);
  static const Color surfaceAlt = Color(0xFFEDF2F6);
  static const Color ink = Color(0xFF172A3A);
  static const Color muted = Color(0xFF718293);
  static const Color accent = Color(0xFF258C9A);
  static const Color accentSoft = Color(0xFFDCEFF1);
  static const Color danger = Color(0xFFBA6268);
  static const Color success = Color(0xFF438774);
  static const Color warning = Color(0xFFAA7A38);
  static const Color hairline = Color(0xFFE1E8ED);
}

/// Desktop navigation uses a slightly distinct surface, not a separate theme.
abstract final class WindowsDesktopColors {
  static const Color background = AppColors.background;
  static const Color sidebar = AppColors.surface;
  static const Color sidebarBorder = AppColors.hairline;
  static const Color sidebarSelected = AppColors.accentSoft;
  static const Color sidebarInk = AppColors.ink;
  static const Color sidebarMuted = AppColors.muted;
}

/// Legacy names remain available to existing macOS widgets while all platforms
/// use the same calm palette and component styling.
abstract final class MacColors {
  static const Color background = AppColors.background;
  static const Color surface = AppColors.surface;
  static const Color surfaceAlt = AppColors.surfaceAlt;
  static const Color sidebar = AppColors.surface;
  static const Color ink = AppColors.ink;
  static const Color mutedInk = AppColors.muted;
  static const Color hairline = AppColors.hairline;
  static const Color primary = AppColors.accent;
  static const Color primaryDim = AppColors.accentSoft;
  static const Color secondary = AppColors.accent;
  static const Color secondaryInk = Colors.white;
  static const Color success = AppColors.success;
  static const Color warning = AppColors.warning;
  static const Color danger = AppColors.danger;
}
