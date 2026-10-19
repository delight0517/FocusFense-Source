import 'package:flutter/material.dart';

/// Traffic-light level for ecosystem scan rows.
enum EcosystemScanLevel { ready, partial, off, unavailable }

extension EcosystemScanLevelUi on EcosystemScanLevel {
  Color color(BuildContext context) {
    switch (this) {
      case EcosystemScanLevel.ready:
        return Colors.green.shade700;
      case EcosystemScanLevel.partial:
        return Colors.orange.shade800;
      case EcosystemScanLevel.off:
        return Colors.red.shade700;
      case EcosystemScanLevel.unavailable:
        return Colors.grey.shade600;
    }
  }

  IconData get icon {
    switch (this) {
      case EcosystemScanLevel.ready:
        return Icons.check_circle;
      case EcosystemScanLevel.partial:
        return Icons.warning_amber_rounded;
      case EcosystemScanLevel.off:
        return Icons.cancel;
      case EcosystemScanLevel.unavailable:
        return Icons.remove_circle_outline;
    }
  }

  String get badgeKo {
    switch (this) {
      case EcosystemScanLevel.ready:
        return '차단 적용';
      case EcosystemScanLevel.partial:
        return '일부만';
      case EcosystemScanLevel.off:
        return '미적용';
      case EcosystemScanLevel.unavailable:
        return '해당 없음';
    }
  }
}

/// One browser / app surface (Chrome, Firefox, Safari, …).
final class EcosystemTargetRow {
  const EcosystemTargetRow({
    required this.id,
    required this.displayName,
    required this.level,
    required this.headline,
    required this.detailLines,
    this.installed = true,
    this.running = false,
    this.installUrl,
    this.uninstallHintKo,
    this.appsSearchName,
    this.pluginSupportReady = false,
    this.pluginSupportLabel,
    this.ifYouInstallKo,
    this.killOnNoBlock = false,
    this.urlBlockUsable = false,
  });

  final String id;
  final String displayName;
  final EcosystemScanLevel level;
  final String headline;
  final List<String> detailLines;
  final bool installed;
  final bool running;
  final String? installUrl;
  final String? uninstallHintKo;
  final String? appsSearchName;

  /// 미설치 브라우저 — 앱이 설치 후 정책/확장을 줄 수 있는지.
  final bool pluginSupportReady;
  final String? pluginSupportLabel;
  final String? ifYouInstallKo;

  /// URL 차단 없을 때 프로세스 kill guard 대상.
  final bool killOnNoBlock;

  /// [BrowserProtectionTruthService] — startup “URL 차단 가능”과 kill guard 공통.
  final bool urlBlockUsable;

  EcosystemTargetRow withCatalog({
    String? installUrl,
    String? uninstallHintKo,
    String? appsSearchName,
    bool? pluginSupportReady,
    String? pluginSupportLabel,
    String? ifYouInstallKo,
    bool? killOnNoBlock,
    bool? urlBlockUsable,
  }) {
    return EcosystemTargetRow(
      id: id,
      displayName: displayName,
      level: level,
      headline: headline,
      detailLines: detailLines,
      installed: installed,
      running: running,
      installUrl: installUrl ?? this.installUrl,
      uninstallHintKo: uninstallHintKo ?? this.uninstallHintKo,
      appsSearchName: appsSearchName ?? this.appsSearchName,
      pluginSupportReady: pluginSupportReady ?? this.pluginSupportReady,
      pluginSupportLabel: pluginSupportLabel ?? this.pluginSupportLabel,
      ifYouInstallKo: ifYouInstallKo ?? this.ifYouInstallKo,
      killOnNoBlock: killOnNoBlock ?? this.killOnNoBlock,
      urlBlockUsable: urlBlockUsable ?? this.urlBlockUsable,
    );
  }
}

/// Windows default HTTP browser vs block policy.
final class DefaultBrowserAdvisory {
  const DefaultBrowserAdvisory({
    required this.browserId,
    required this.displayName,
    required this.blockActive,
    required this.isProblem,
    required this.messageKo,
    this.progId,
    this.suggestSwitchTo,
    this.settingsUri,
  });

  final String browserId;
  final String displayName;
  final String? progId;
  final bool blockActive;
  final bool isProblem;
  final String messageKo;
  final String? suggestSwitchTo;
  final String? settingsUri;
}

/// App-wide protection feature (extension delete guard, kill guard, …).
final class EcosystemFeatureRow {
  const EcosystemFeatureRow({
    required this.id,
    required this.title,
    required this.level,
    required this.summary,
    this.detail = '',
  });

  final String id;
  final String title;
  final EcosystemScanLevel level;
  final String summary;
  final String detail;
}

/// Full friendly report for the diagnostics UI.
final class BlockingEcosystemReport {
  const BlockingEcosystemReport({
    required this.buildLabel,
    required this.scannedAt,
    required this.isPostUpdateScan,
    required this.platformLabel,
    required this.summaryKo,
    required this.targets,
    required this.features,
    required this.builtinAdultCount,
    required this.activeRuleCount,
    this.defaultBrowser,
    this.killGuardActive = false,
  });

  final String buildLabel;
  final DateTime scannedAt;
  final bool isPostUpdateScan;
  final String platformLabel;
  final String summaryKo;
  final List<EcosystemTargetRow> targets;
  final List<EcosystemFeatureRow> features;
  final int builtinAdultCount;
  final int activeRuleCount;
  final DefaultBrowserAdvisory? defaultBrowser;
  final bool killGuardActive;

  int get readyCount => targets
      .where((EcosystemTargetRow t) => t.level == EcosystemScanLevel.ready)
      .length;

  /// Same list as kill-guard “safe to use” — [BrowserProtectionTruthService].
  int get urlBlockUsableCount => targets
      .where((EcosystemTargetRow t) => t.installed && t.urlBlockUsable)
      .length;

  int get installedCount =>
      targets.where((EcosystemTargetRow t) => t.installed).length;

  static EcosystemScanLevel? _levelFrom(String? raw) {
    if (raw == null) return null;
    for (final EcosystemScanLevel l in EcosystemScanLevel.values) {
      if (l.name == raw) return l;
    }
    return null;
  }

  static BlockingEcosystemReport? tryFromJson(Map<String, Object?> json) {
    try {
      final String? scannedRaw = json['scannedAt'] as String?;
      if (scannedRaw == null) return null;
      final int schema = json['schemaVersion'] is int
          ? json['schemaVersion'] as int
          : int.tryParse('${json['schemaVersion']}') ?? 1;
      if (schema < 1) return null;
      final List<EcosystemTargetRow> targets = <EcosystemTargetRow>[];
      final Object? rawTargets = json['targets'];
      if (rawTargets is List) {
        for (final Object item in rawTargets) {
          if (item is! Map) continue;
          final Map<String, Object?> m = Map<String, Object?>.from(item);
          final EcosystemScanLevel? level = _levelFrom(m['level'] as String?);
          if (level == null) continue;
          targets.add(
            EcosystemTargetRow(
              id: '${m['id'] ?? ''}',
              displayName: '${m['displayName'] ?? ''}',
              level: level,
              headline: '${m['headline'] ?? ''}',
              detailLines:
                  (m['detailLines'] as List?)
                      ?.map((dynamic e) => '$e')
                      .toList(growable: false) ??
                  const <String>[],
              installed: m['installed'] == true,
              running: m['running'] == true,
              installUrl: m['installUrl'] as String?,
              uninstallHintKo: m['uninstallHintKo'] as String?,
              killOnNoBlock: m['killOnNoBlock'] == true,
              // v1 cache had no urlBlockUsable — infer from level when possible.
              urlBlockUsable:
                  m['urlBlockUsable'] == true ||
                  (schema < 2 &&
                      m['urlBlockUsable'] != false &&
                      level == EcosystemScanLevel.ready),
            ),
          );
        }
      }
      final List<EcosystemFeatureRow> features = <EcosystemFeatureRow>[];
      final Object? rawFeatures = json['features'];
      if (rawFeatures is List) {
        for (final Object item in rawFeatures) {
          if (item is! Map) continue;
          final Map<String, Object?> m = Map<String, Object?>.from(item);
          final EcosystemScanLevel? level = _levelFrom(m['level'] as String?);
          if (level == null) continue;
          features.add(
            EcosystemFeatureRow(
              id: '${m['id'] ?? ''}',
              title: '${m['title'] ?? ''}',
              level: level,
              summary: '${m['summary'] ?? ''}',
              detail: '${m['detail'] ?? ''}',
            ),
          );
        }
      }
      DefaultBrowserAdvisory? defaultBrowser;
      final Object? rawDef = json['defaultBrowser'];
      if (rawDef is Map) {
        final Map<String, Object?> d = Map<String, Object?>.from(rawDef);
        defaultBrowser = DefaultBrowserAdvisory(
          browserId: '${d['browserId'] ?? ''}',
          displayName: '${d['displayName'] ?? ''}',
          progId: d['progId'] as String?,
          blockActive: d['blockActive'] == true,
          isProblem: d['isProblem'] == true,
          messageKo: '${d['messageKo'] ?? ''}',
          suggestSwitchTo: d['suggestSwitchTo'] as String?,
        );
      }
      return BlockingEcosystemReport(
        buildLabel: '${json['buildLabel'] ?? ''}',
        scannedAt: DateTime.parse(scannedRaw),
        isPostUpdateScan: json['isPostUpdateScan'] == true,
        platformLabel: '${json['platformLabel'] ?? ''}',
        summaryKo: '${json['summaryKo'] ?? ''}',
        targets: targets,
        features: features,
        builtinAdultCount: json['builtinAdultCount'] is int
            ? json['builtinAdultCount'] as int
            : int.tryParse('${json['builtinAdultCount']}') ?? 0,
        activeRuleCount: json['activeRuleCount'] is int
            ? json['activeRuleCount'] as int
            : int.tryParse('${json['activeRuleCount']}') ?? 0,
        defaultBrowser: defaultBrowser,
        killGuardActive: json['killGuardActive'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': 2,
    'buildLabel': buildLabel,
    'scannedAt': scannedAt.toIso8601String(),
    'isPostUpdateScan': isPostUpdateScan,
    'platformLabel': platformLabel,
    'summaryKo': summaryKo,
    'builtinAdultCount': builtinAdultCount,
    'activeRuleCount': activeRuleCount,
    'defaultBrowser': defaultBrowser == null
        ? null
        : <String, Object?>{
            'browserId': defaultBrowser!.browserId,
            'displayName': defaultBrowser!.displayName,
            'progId': defaultBrowser!.progId,
            'blockActive': defaultBrowser!.blockActive,
            'isProblem': defaultBrowser!.isProblem,
            'messageKo': defaultBrowser!.messageKo,
            'suggestSwitchTo': defaultBrowser!.suggestSwitchTo,
          },
    'targets': targets
        .map(
          (EcosystemTargetRow t) => <String, Object?>{
            'id': t.id,
            'displayName': t.displayName,
            'level': t.level.name,
            'headline': t.headline,
            'detailLines': t.detailLines,
            'installed': t.installed,
            'running': t.running,
            'installUrl': t.installUrl,
            'uninstallHintKo': t.uninstallHintKo,
            'killOnNoBlock': t.killOnNoBlock,
            'urlBlockUsable': t.urlBlockUsable,
          },
        )
        .toList(),
    'features': features
        .map(
          (EcosystemFeatureRow f) => <String, Object?>{
            'id': f.id,
            'title': f.title,
            'level': f.level.name,
            'summary': f.summary,
            'detail': f.detail,
          },
        )
        .toList(),
  };
}

/// User-facing status for the always-visible browser setup prompt.
///
/// Only installed browsers count as uncovered. Browsers that are not installed
/// are not presented as failures; when none are installed, the prompt explains
/// that setup cannot be verified yet.
final class BlockingSetupNotice {
  const BlockingSetupNotice({
    required this.isReady,
    required this.title,
    required this.detail,
    this.unprotectedBrowsers = const <String>[],
  });

  final bool isReady;
  final String title;
  final String detail;
  final List<String> unprotectedBrowsers;

  factory BlockingSetupNotice.fromReport(BlockingEcosystemReport report) {
    final List<EcosystemTargetRow> installed = report.targets
        .where((EcosystemTargetRow target) => target.installed)
        .toList(growable: false);

    if (installed.isEmpty) {
      return const BlockingSetupNotice(
        isReady: false,
        title: '브라우저 차단 설정이 아직 완료되지 않았어요',
        detail:
            '지원 브라우저를 찾지 못해 차단 상태를 확인할 수 없습니다. 설정 안내에서 브라우저별 설치 단계를 진행해 주세요.',
      );
    }

    final List<String> unprotected = installed
        .where((EcosystemTargetRow target) => !target.urlBlockUsable)
        .map((EcosystemTargetRow target) => target.displayName)
        .toList(growable: false);

    if (unprotected.isNotEmpty) {
      return BlockingSetupNotice(
        isReady: false,
        title: '일부 브라우저에서는 차단이 적용되지 않아요',
        detail:
            '${unprotected.join(' · ')}에서 차단을 확인하지 못했어요. 브라우저 설정 단계를 마쳐 주세요.',
        unprotectedBrowsers: unprotected,
      );
    }

    return BlockingSetupNotice(
      isReady: true,
      title: '브라우저 차단이 정상 적용 중이에요',
      detail: '${installed.length}개 설치된 브라우저에서 차단 상태를 확인했어요.',
    );
  }
}
