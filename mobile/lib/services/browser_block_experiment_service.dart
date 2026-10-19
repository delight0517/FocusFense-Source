import 'dart:io';

import 'app_logger.dart';
import 'block_activity_log_service.dart';
import 'chrome_load_extension_launcher.dart';

/// Opens protected Chrome/Firefox with a URL and verifies the extension reported a block.
final class BrowserBlockExperimentService {
  BrowserBlockExperimentService._();
  static final BrowserBlockExperimentService instance =
      BrowserBlockExperimentService._();

  static const Duration kWaitAfterOpen = Duration(seconds: 8);
  static const Duration kBlockLookback = Duration(seconds: 20);

  Future<BrowserBlockExperimentResult> run({
    required String url,
    required String browser,
    required String label,
    required bool expectBlocked,
  }) async {
    if (!Platform.isWindows) {
      return BrowserBlockExperimentResult(
        browser: browser,
        url: url,
        label: label,
        expectBlocked: expectBlocked,
        opened: false,
        blockReported: false,
        ok: !expectBlocked,
        detail: 'Windows 전용 실험',
      );
    }

    final String videoId = _videoIdFromUrl(url);
    final DateTime before = DateTime.now();

    final bool opened = browser == 'firefox'
        ? await ChromeLoadExtensionLauncher.openUrlInProtectedFirefox(url)
        : await ChromeLoadExtensionLauncher.openUrlInProtectedChrome(url);

    if (!opened) {
      return BrowserBlockExperimentResult(
        browser: browser,
        url: url,
        label: label,
        expectBlocked: expectBlocked,
        opened: false,
        blockReported: false,
        ok: false,
        detail: '보호 브라우저 실행 실패 — 확장 폴더·실행 파일 확인',
      );
    }

    await Future<void>.delayed(kWaitAfterOpen);

    final bool blockReported = videoId.isNotEmpty
        ? BlockActivityLogService.instance.hasRecentBlockForVideo(
            videoId,
            since: before.subtract(const Duration(seconds: 2)),
            browser: browser,
          )
        : BlockActivityLogService.instance.hasRecentBlockForUrl(
            url,
            since: before.subtract(const Duration(seconds: 2)),
            browser: browser,
          );

    final bool ok = expectBlocked ? blockReported : !blockReported;
    final String detail = expectBlocked
        ? (blockReported
            ? '차단 오버레이·/block 보고 확인'
            : '규칙상 차단이어야 하는데 브라우저가 재생 중 — 확장 미로드 또는 API 끊김')
        : (blockReported ? '오탐 차단' : '정상 통과');

    AppLogger.instance.info(
      'browser_experiment [$browser] $label ok=$ok blocked=$blockReported url=$url',
    );

    return BrowserBlockExperimentResult(
      browser: browser,
      url: url,
      label: label,
      expectBlocked: expectBlocked,
      opened: true,
      blockReported: blockReported,
      ok: ok,
      detail: detail,
    );
  }

  static String _videoIdFromUrl(String url) {
    final Uri? u = Uri.tryParse(url);
    final String? v = u?.queryParameters['v'];
    if (v != null && v.length >= 6) return v.toLowerCase();
    final RegExpMatch? m =
        RegExp(r'(?:youtu\.be/|/shorts/|[?&]v=)([\w-]{6,})', caseSensitive: false)
            .firstMatch(url);
    return m != null ? m.group(1)!.toLowerCase() : '';
  }
}

final class BrowserBlockExperimentResult {
  const BrowserBlockExperimentResult({
    required this.browser,
    required this.url,
    required this.label,
    required this.expectBlocked,
    required this.opened,
    required this.blockReported,
    required this.ok,
    required this.detail,
  });

  final String browser;
  final String url;
  final String label;
  final bool expectBlocked;
  final bool opened;
  final bool blockReported;
  final bool ok;
  final String detail;

  Map<String, Object?> toJson() => <String, Object?>{
        'browser': browser,
        'url': url,
        'label': label,
        'expectBlocked': expectBlocked,
        'opened': opened,
        'blockReported': blockReported,
        'ok': ok,
        'detail': detail,
      };
}
