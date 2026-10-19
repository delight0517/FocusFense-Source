/// Result of post-rebuild auto-activation (PAC, tiers, prefs) for UI alert.
final class PostRebuildActivationReport {
  const PostRebuildActivationReport({
    required this.buildLabel,
    required this.universalOk,
    required this.universalMessage,
    required this.pacApplied,
    this.pacPath,
    required this.steps,
    required this.youtubeEnforce,
    required this.bulletproofOn,
    required this.chromeBlockingOk,
    required this.keywordCount,
    required this.blocksVideo0ucghClyrrk,
  });

  final String buildLabel;
  final bool universalOk;
  final String universalMessage;
  final bool pacApplied;
  final String? pacPath;
  final List<String> steps;
  final bool youtubeEnforce;
  final bool bulletproofOn;
  final bool chromeBlockingOk;
  final int keywordCount;
  final bool blocksVideo0ucghClyrrk;

  List<String> summaryLines() {
    return <String>[
      '빌드 $buildLabel — 리빌드 후 자동 차단 적용',
      if (pacApplied) '① PAC (전 브라우저): 적용됨' else '① PAC: 실패 — 앱을 다시 실행하세요',
      if (pacPath != null) '   $pacPath',
      if (steps.contains('hkcu_url_blocklist'))
        '② URL 차단 목록: 적용됨'
      else
        '② URL 목록: 일부 PC에서 정책 잠금',
      if (steps.any((String s) => s.startsWith('tier')))
        '③ 3단계(확장·보호 Chrome): 적용됨'
      else
        '③ 3단계: 점검 중',
      if (blocksVideo0ucghClyrrk)
        '필수 차단: watch?v=0ucghClyrrk 포함'
      else
        '필수 차단: 규칙 확인 필요',
      'DB 키워드 $keywordCount개 + 내장 필수 YouTube 규칙',
      '',
      '▶ Chrome은 반드시 앱 「Chrome 열기」 또는 시작 메뉴 「Focus Fense (Windows)」로 여세요.',
      '▶ 일반 Chrome 아이콘으로 열면 재생될 수 있습니다(자동 종료·단계3).',
      '▶ 채널·피드·검색 숨김은 보호 Chrome + 확장에서 동작합니다.',
    ];
  }
}
