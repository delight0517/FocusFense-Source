/// Distinguishes **expected heavy work** (rebuild, block apply) from
/// **unexpected UI freeze** so lag logs and overlays can persuade the user
/// or flag a bug for Cursor/Claude.
enum LagLegitimacy {
  /// User-initiated or scheduled heavy pipeline — wait is normal.
  expectedHeavy,

  /// Background maintenance the app must run — brief system slowdown OK.
  backgroundMaintenance,

  /// No matching work label while UI/CPU is stuck — likely a bug.
  unexpectedBug,
}

final class LagWorkClassification {
  const LagWorkClassification({
    required this.legitimacy,
    required this.headlineKo,
    required this.explainKo,
    this.primaryLabel,
    this.userShouldWait = true,
  });

  final LagLegitimacy legitimacy;
  final String headlineKo;
  final String explainKo;
  final String? primaryLabel;
  final bool userShouldWait;

  String get legitimacyLabelKo {
    switch (legitimacy) {
      case LagLegitimacy.expectedHeavy:
        return '정상 · 중요 작업';
      case LagLegitimacy.backgroundMaintenance:
        return '백그라운드 점검';
      case LagLegitimacy.unexpectedBug:
        return '예상치 못한 멈춤';
    }
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'legitimacy': legitimacy.name,
        'legitimacyLabelKo': legitimacyLabelKo,
        'headlineKo': headlineKo,
        'explainKo': explainKo,
        'primaryLabel': primaryLabel,
        'userShouldWait': userShouldWait,
      };
}

/// Maps [WorkContextTracker] labels + progress titles to legitimacy.
abstract final class LagWorkClassifier {
  static const Set<String> _expectedHeavy = <String>{
    'cursor_full_pack',
    'post_rebuild_bootstrap',
    'windows_rebuild',
    'block_sync.applyNow',
    'autonomous_apply.full_pipeline',
    'universal_browser_block.syncNow',
    'one_tap_block_everything',
    'boot_browser_autofix',
    'chrome_url_block_reload',
    'installed_browsers_auto_apply',
  };

  static const Set<String> _backgroundMaintenance = <String>{
    'browser_block_health.probe',
    'browser_block_enforcement.analyze',
    'extension_keepalive',
    'blocking_self_heal',
    'numeric_apex_hosts_gap_healer',
    'chrome_extension_auto_sync',
    'protection_gap',
    'tier3',
    'hosts_health_probe',
    'youtube_proactive',
    'ecosystem_scan',
    'browser_exit_watcher',
  };

  static LagWorkClassification classify({
    List<String> activeLabels = const <String>[],
    String? progressTitle,
    String? triggerKind,
    bool highChildProcessStorm = false,
  }) {
    final String? label = _pickPrimary(activeLabels, progressTitle);
    if (label != null) {
      final String base = _baseLabel(label);
      if (_matches(base, _expectedHeavy)) {
        return LagWorkClassification(
          legitimacy: LagLegitimacy.expectedHeavy,
          headlineKo: _headlineFor(base),
          explainKo:
              'PC가 잠시 느려질 수 있어요. 이 작업이 끝나야 차단·보호가 '
              '안정됩니다. 다른 창을 건드리지 않아도 됩니다.',
          primaryLabel: label,
        );
      }
      if (_matches(base, _backgroundMaintenance)) {
        return LagWorkClassification(
          legitimacy: LagLegitimacy.backgroundMaintenance,
          headlineKo: _headlineFor(base),
          explainKo:
              '백그라운드에서 브라우저·차단 상태를 점검 중입니다. '
              '잠시만 기다려 주세요.',
          primaryLabel: label,
        );
      }
      if (progressTitle != null && progressTitle.isNotEmpty) {
        return LagWorkClassification(
          legitimacy: LagLegitimacy.expectedHeavy,
          headlineKo: progressTitle,
          explainKo:
              '진행 중인 작업이 우선입니다. 완료될 때까지 PC가 '
              '무거워질 수 있어요.',
          primaryLabel: label,
        );
      }
    }

    if (highChildProcessStorm) {
      return const LagWorkClassification(
        legitimacy: LagLegitimacy.unexpectedBug,
        headlineKo: '시스템 점검 과부하',
        explainKo:
            'PowerShell·레지스트리 호출이 비정상적으로 많습니다. '
            '작업이 끝나면 설정→진단→「AI용 번들 복사」로 '
            'Cursor에 보내 주세요.',
        userShouldWait: false,
      );
    }

    return LagWorkClassification(
      legitimacy: LagLegitimacy.unexpectedBug,
      headlineKo: triggerKind == 'cpu_spike'
          ? 'CPU 사용량 급증'
          : '앱 응답 지연',
      explainKo:
          '예상된 작업 없이 멈춤이 감지됐어요. 복구되면 '
          '설정→진단→「AI용 번들 복사」로 로그를 Cursor에 붙여넣으면 '
          '다음에 원인을 찾기 쉽습니다.',
      primaryLabel: label,
      userShouldWait: false,
    );
  }

  static String? _pickPrimary(List<String> labels, String? progressTitle) {
    if (labels.isNotEmpty) return labels.last;
    if (progressTitle != null && progressTitle.isNotEmpty) {
      return progressTitle;
    }
    return null;
  }

  static String _baseLabel(String label) {
    if (label.startsWith('wc:')) return label.substring(3);
    return label;
  }

  static bool _matches(String label, Set<String> patterns) {
    for (final String p in patterns) {
      if (label == p || label.startsWith('$p.')) return true;
    }
    return false;
  }

  static String _headlineFor(String base) {
    const Map<String, String> map = <String, String>{
      'cursor_full_pack': 'Cursor 진단 팩 수집',
      'post_rebuild_bootstrap': '리빌드 후 초기 설정',
      'windows_rebuild': '앱 리빌드',
      'block_sync.applyNow': '차단 목록 적용',
      'autonomous_apply.full_pipeline': '자율 점검·차단 적용',
      'universal_browser_block.syncNow': '브라우저 URL 차단 동기화',
      'one_tap_block_everything': '원탭 차단 적용',
      'boot_browser_autofix': '브라우저 자동 복구',
      'browser_block_health.probe': '브라우저 차단 점검',
      'ecosystem_scan': '브라우저 현황 스캔',
    };
    return map[base] ?? base.replaceAll('.', ' · ');
  }
}
