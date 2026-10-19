import 'package:flutter/material.dart';

import '../utils/block_url_input.dart';

/// When the user pastes a URL with a path, [hosts] can only store the host.
/// Ask whether to block the whole site or add a **keyword** snippet (for
/// extensions / SERP-style matching — not a full watch-page firewall).
Future<UrlPathBlockChoice?> showUrlPathBlockChoiceDialog(
  BuildContext context, {
  required BlockUrlInput parsed,
}) {
  final String suggested = BlockUrlInput.suggestKeywordPattern(parsed);
  return showDialog<UrlPathBlockChoice>(
    context: context,
    builder: (BuildContext ctx) {
      return AlertDialog(
        title: const Text('URL에 경로가 포함되어 있습니다'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text(
                '시스템 DNS(hosts) 차단은 도메인 이름만 처리합니다. '
                '주소 뒤의 /watch?… 같은 경로는 hosts 파일에 들어가지 않습니다.',
                style: TextStyle(height: 1.35),
              ),
              const SizedBox(height: 12),
              Text('추출된 호스트: ${parsed.host}',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              if (parsed.pathQuery.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    '무시되는 경로·쿼리: /${parsed.pathQuery}',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
              const SizedBox(height: 12),
              const Text(
                '• 도메인만: 이 호스트 전체가 막힙니다(예: YouTube 전체).\n'
                '• 키워드만: 아래 문자열을 키워드 규칙으로 추가합니다. '
                '브라우저 확장·검색 결과 매칭에 도움이 될 수 있으나, '
                '재생 페이지만 hosts로 정밀 차단하는 것은 불가능합니다.\n'
                '• YouTube 등은 영상이 다른 서버(예: googlevideo)로 나갈 수 있어 '
                '도메인 차단만으로는 재생이 남을 수 있습니다.',
                style: TextStyle(fontSize: 13, height: 1.35),
              ),
              const SizedBox(height: 8),
              Text('제안 키워드: $suggested',
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace')),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, UrlPathBlockChoice.cancel),
            child: const Text('취소'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(ctx, UrlPathBlockChoice.domainOnly),
            child: const Text('도메인만 (사이트 전체)'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(ctx, UrlPathBlockChoice.keywordOnly),
            child: const Text('키워드만 (URL 조각)'),
          ),
        ],
      );
    },
  );
}

enum UrlPathBlockChoice {
  cancel,
  domainOnly,
  keywordOnly,
}
