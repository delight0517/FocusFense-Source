import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';
import 'block_activity_log_service.dart';
import 'block_sync_service.dart';
import 'extension_rules_builder.dart';
import 'youtube_channel_videos_fetcher_service.dart';

/// Periodically re-fetches recent videos for every blocked YouTube channel so
/// `watch?v=` URLs land in URLBlocklist even when the user added the channel
/// before auto-fetch existed.
final class YoutubeChannelBootSyncService {
  YoutubeChannelBootSyncService._();
  static final YoutubeChannelBootSyncService instance =
      YoutubeChannelBootSyncService._();

  static const String _kLastRunKey = 'yt_channel_boot_sync_last_ms_v1';
  static const Duration kCooldown = Duration(hours: 6);

  Future<int> runIfDue({
    String reason = 'boot',
    bool force = false,
  }) async {
    if (!Platform.isWindows && !Platform.isMacOS) return 0;

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final int? lastMs = prefs.getInt(_kLastRunKey);
    final DateTime now = DateTime.now();
    if (!force &&
        lastMs != null &&
        now.difference(DateTime.fromMillisecondsSinceEpoch(lastMs)) <
            kCooldown) {
      return 0;
    }

    final ExtensionRulesPayload rules =
        await ExtensionRulesBuilder.buildForBrowserEnforcement();
    if (!rules.hasYoutubeChannelBlocks) {
      return 0;
    }

    try {
      final Map<String, int> fetched =
          await YoutubeChannelVideosFetcherService.instance
              .syncAllBlockedChannels();
      final int inserted =
          fetched.values.fold<int>(0, (int a, int b) => a + b);
      await prefs.setInt(_kLastRunKey, now.millisecondsSinceEpoch);

      if (inserted > 0) {
        BlockSyncService.instance.requestApply();
        BlockActivityLogService.instance.record(
          kind: BlockActivityKind.selfHeal,
          message:
              'YouTube 채널 watch?v= 부트 동기화: $inserted건 추가 ($reason)',
          data: <String, Object?>{
            'reason': reason,
            'inserted': inserted,
            'channels': fetched,
          },
          debounceKey: 'yt_channel_boot_sync',
        );
        AppLogger.instance.info(
          'yt_channel_boot_sync [$reason]: inserted=$inserted channels=${fetched.length}',
        );
      }
      return inserted;
    } catch (e) {
      AppLogger.instance.warn('yt_channel_boot_sync failed: $e');
      return 0;
    }
  }
}
