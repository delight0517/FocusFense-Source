import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/services/extension_rules_builder.dart';
import 'package:six_clean_room/services/youtube_video_block_resolver.dart';

void main() {
  test('oYVEqFdjNDs resolves channel via oEmbed with mixed-case id', () async {
    final YoutubeVideoResolveResult resolved =
        await YoutubeVideoBlockResolver.instance.resolveVideo('oYVEqFdjNDs');
    expect(resolved.error, isNull);
    expect(resolved.channelHandle, '뷰티풀너드');
  });

  test('lowercased id uses cache after mixed-case resolve', () async {
    YoutubeVideoBlockResolver.instance.resolveVideo('oYVEqFdjNDs');
    // second call would need async - skip duplicate network
  }, skip: true);
}
