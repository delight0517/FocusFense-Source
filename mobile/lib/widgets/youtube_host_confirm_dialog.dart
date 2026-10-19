import 'package:flutter/material.dart';

/// Confirms blocking all of YouTube via hosts (`youtube.com`).
Future<bool> showYoutubeHostConfirmDialog(BuildContext context) async {
  final bool? ok = await showDialog<bool>(
    context: context,
    builder: (BuildContext ctx) => AlertDialog(
      title: const Text('YouTube 전체 차단'),
      content: const Text(
        'youtube.com 을 도메인 규칙으로 넣으면 DNS/hosts 로 '
        'YouTube 서비스 전체(모든 채널·영상·홈)가 막힙니다.\n\n'
        '특정 채널만 막으려면 채널 URL 또는 @핸들을 넣으세요.\n\n'
        '그래도 YouTube 전체를 차단할까요?',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('전체 차단'),
        ),
      ],
    ),
  );
  return ok == true;
}
