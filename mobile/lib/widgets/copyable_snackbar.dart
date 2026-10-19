import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Snackbar with a **복사** action — for errors during extension setup / tests.
void showCopyableSnackBar(
  BuildContext context,
  String message, {
  Duration duration = const Duration(seconds: 10),
  String copyLabel = '복사',
}) {
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      duration: duration,
      action: SnackBarAction(
        label: copyLabel,
        onPressed: () {
          Clipboard.setData(ClipboardData(text: message));
        },
      ),
    ),
  );
}
