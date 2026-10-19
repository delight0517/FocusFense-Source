import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../constants/support_constants.dart';
import 'app_logger.dart';
import 'block_activity_log_service.dart';
import 'browser_block_enforcement_health_service.dart';
import 'build_identity_service.dart';
import 'crash_journal_service.dart';
import 'platform_process.dart';
import 'protection_coverage_service.dart';
import 'windows_hidden_process.dart';

enum FeedbackCategory {
  blockNotWorking('차단이 안 됨', 'youtube_block'),
  appError('앱 오류·멈춤', 'app_error'),
  installSetup('설치·쉬운 설치', 'install'),
  browser('Chrome·Edge·Firefox', 'browser'),
  other('기타', 'other');

  const FeedbackCategory(this.label, this.id);

  final String label;
  final String id;
}

final class UserFeedbackBundleResult {
  const UserFeedbackBundleResult({
    required this.ok,
    required this.message,
    this.zipPath,
    this.summaryText,
    this.stagingDir,
  });

  final bool ok;
  final String message;
  final String? zipPath;
  final String? summaryText;
  final String? stagingDir;
}

/// Packages diagnostics + user message; opens mail / folder / clipboard.
final class UserFeedbackService {
  UserFeedbackService._();
  static final UserFeedbackService instance = UserFeedbackService._();

  static String get _feedbackDir =>
      p.join(CrashJournalService.instance.debugFolderPath, 'feedback');

  static String get _submissionsLog =>
      p.join(CrashJournalService.instance.debugFolderPath, 'feedback_submissions.jsonl');

  Future<UserFeedbackBundleResult> createBundle({
    required FeedbackCategory category,
    required String userMessage,
    bool includeLogs = true,
  }) async {
    try {
      await BlockActivityLogService.instance.refreshSnapshot(reason: 'feedback');
      final String stamp = _stamp();
      final Directory outDir = Directory(_feedbackDir);
      if (!await outDir.exists()) await outDir.create(recursive: true);

      final Directory staging = Directory(p.join(outDir.path, 'staging_$stamp'));
      if (await staging.exists()) await staging.delete(recursive: true);
      await staging.create(recursive: true);

      final Map<String, Object?> report = await _buildReportJson(
        category: category,
        userMessage: userMessage,
      );
      await File(p.join(staging.path, 'feedback_report.json')).writeAsString(
        const JsonEncoder.withIndent('  ').convert(report),
        flush: true,
      );
      await File(p.join(staging.path, 'user_message.txt')).writeAsString(
        userMessage.trim().isEmpty ? '(메시지 없음)' : userMessage.trim(),
        flush: true,
      );

      if (includeLogs) {
        await _copyIfExists(
          p.join(CrashJournalService.instance.debugFolderPath, 'crash_journal.jsonl'),
          p.join(staging.path, 'crash_journal.jsonl'),
        );
        await _copyIfExists(
          p.join(CrashJournalService.instance.debugFolderPath, 'crash_journal.jsonl.bak'),
          p.join(staging.path, 'crash_journal.jsonl.bak'),
        );
        await _copyIfExists(
          BlockActivityLogService.instance.summaryPath,
          p.join(staging.path, 'block_activity_summary.json'),
        );
        await _copyIfExists(
          BlockActivityLogService.instance.jsonlPath,
          p.join(staging.path, 'block_activity.jsonl'),
        );
        final String? appLog = await AppLogger.instance.filePath();
        if (appLog != null) {
          await _copyIfExists(appLog, p.join(staging.path, 'app.log'));
          await _copyIfExists('$appLog.1', p.join(staging.path, 'app.log.1'));
        }
        await File(p.join(staging.path, 'block_activity_export.txt')).writeAsString(
          await BlockActivityLogService.instance.exportForCursor(maxLines: 120),
          flush: true,
        );
      }

      final String zipName = '6VPN_Feedback_$stamp.zip';
      final String zipPath = p.join(outDir.path, zipName);
      if (await File(zipPath).exists()) await File(zipPath).delete();

      if (Platform.isWindows) {
        final bool zipped = await _zipWithPowerShell(staging.path, zipPath);
        if (!zipped) {
          return UserFeedbackBundleResult(
            ok: false,
            message: 'ZIP 만들기에 실패했습니다. staging 폴더를 열어 파일을 직접 보내 주세요.',
            stagingDir: staging.path,
          );
        }
      } else {
        // macOS/iOS: folder bundle (no Compress-Archive dependency in Dart).
        return UserFeedbackBundleResult(
          ok: true,
          message: '진단 폴더가 준비되었습니다. 폴더 전체를 메일·AirDrop으로 보내 주세요.',
          stagingDir: staging.path,
          summaryText: await _buildSummaryText(
            category: category,
            userMessage: userMessage,
            report: report,
            attachmentHint: staging.path,
          ),
        );
      }

      final String summary = await _buildSummaryText(
        category: category,
        userMessage: userMessage,
        report: report,
        attachmentHint: zipPath,
      );

      await _appendSubmissionLog(
        category: category,
        userMessage: userMessage,
        zipPath: zipPath,
        report: report,
      );

      return UserFeedbackBundleResult(
        ok: true,
        message: '진단 ZIP이 준비되었습니다.',
        zipPath: zipPath,
        summaryText: summary,
        stagingDir: staging.path,
      );
    } catch (e, st) {
      AppLogger.instance.error('feedback bundle failed', error: e, stack: st);
      return UserFeedbackBundleResult(
        ok: false,
        message: '피드백 준비 실패: $e',
      );
    }
  }

  Future<bool> sendWithMailAndReveal({
    required UserFeedbackBundleResult bundle,
    required FeedbackCategory category,
  }) async {
    if (!bundle.ok) return false;

    final String? zip = bundle.zipPath;
    final String? folder = bundle.stagingDir;
    if (zip != null && await File(zip).exists()) {
      await PlatformProcess.revealFileInFolder(zip);
    } else if (folder != null) {
      await PlatformProcess.openFolder(folder);
    }

    final String email = kDeveloperFeedbackEmail.trim();
    if (email.isEmpty) return true;

    final String subject =
        '$kFeedbackEmailSubjectPrefix — ${category.label}';
    final String body = bundle.summaryText ?? '';
    final Uri uri = Uri(
      scheme: 'mailto',
      path: email,
      query: _encodeMailQuery(<String, String>{
        'subject': subject,
        'body': body,
      }),
    );
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
      return true;
    }
    return false;
  }

  Future<void> copySummary(UserFeedbackBundleResult bundle) async {
    final String text = bundle.summaryText ?? '';
    if (text.isEmpty) return;
    await Clipboard.setData(ClipboardData(text: text));
  }

  Future<Map<String, Object?>> _buildReportJson({
    required FeedbackCategory category,
    required String userMessage,
  }) async {
    final BuildIdentity id = await BuildIdentityService.instance.current();
    final BrowserEnforcementHealth enforce =
        await BrowserBlockEnforcementHealthService.instance.analyze();
    ProtectionCoverageReport? coverage;
    try {
      coverage = await ProtectionCoverageService.instance.analyze(force: true);
    } catch (_) {}

    return <String, Object?>{
      'submittedAt': DateTime.now().toIso8601String(),
      'category': category.id,
      'categoryLabel': category.label,
      'userMessage': userMessage.trim(),
      'build': <String, Object?>{
        'product': BuildIdentityService.kProductDisplayName,
        'version': id.version,
        'buildNumber': id.buildNumber,
        'os': id.operatingSystem,
        'osVersion': id.operatingSystemVersion,
        'exe': id.executableBaseName,
        'exePath': id.executablePath,
      },
      'enforcement': <String, Object?>{
        'phase': enforce.phase.name,
        'youtubeRuleCount': enforce.youtubeRuleCount,
        'recentBlockCount': enforce.recentBlockCount,
        'rulesFetchSeen': enforce.rulesFetchSeen,
        'browserInstallOk': enforce.browserInstallOk,
        'rulesApiRunning': enforce.rulesApiRunning,
        'sampleRule': enforce.sampleRule,
      },
      if (coverage != null)
        'protection': <String, Object?>{
          'chromeExtensionOk': coverage.chromeExtensionOk,
          'edgeExtensionOk': coverage.edgeExtensionOk,
          'firefoxExtensionOk': coverage.firefoxExtensionOk,
          'hostsActive': coverage.hostsActive,
          'rulesApiRunning': coverage.rulesApiRunning,
          'gapCount': coverage.gaps.length,
          'topGaps': coverage.gaps
              .take(5)
              .map(
                (ProtectionGap g) => <String, Object?>{
                  'id': g.id,
                  'title': g.title,
                  'severity': g.severity.name,
                },
              )
              .toList(),
        },
      'paths': <String, String>{
        'debugFolder': CrashJournalService.instance.debugFolderPath,
        'appLog': await AppLogger.instance.filePath() ?? '',
      },
    };
  }

  Future<String> _buildSummaryText({
    required FeedbackCategory category,
    required String userMessage,
    required Map<String, Object?> report,
    required String attachmentHint,
  }) async {
    final String buildLine = await BuildIdentityService.instance.summaryLine();
    final Map<String, Object?>? enf =
        report['enforcement'] as Map<String, Object?>?;
    final StringBuffer sb = StringBuffer()
      ..writeln('Focus Fense — 사용자 피드백')
      ..writeln(buildLine)
      ..writeln('카테고리: ${category.label}')
      ..writeln();
    if (userMessage.trim().isNotEmpty) {
      sb.writeln('증상:');
      sb.writeln(userMessage.trim());
      sb.writeln();
    }
    if (enf != null) {
      sb.writeln(
        '차단 상태: ${enf['phase']} · 유튜브 규칙 ${enf['youtubeRuleCount']} · '
        '최근 차단 ${enf['recentBlockCount']}건',
      );
      sb.writeln();
    }
    sb.writeln('첨부 파일:');
    sb.writeln(attachmentHint);
    sb.writeln();
    sb.writeln('ZIP 안에 crash_journal, block_activity, app.log 가 포함됩니다.');
    return sb.toString().trim();
  }

  Future<void> _appendSubmissionLog({
    required FeedbackCategory category,
    required String userMessage,
    required String zipPath,
    required Map<String, Object?> report,
  }) async {
    try {
      final Map<String, Object?> row = <String, Object?>{
        'ts': DateTime.now().toIso8601String(),
        'category': category.id,
        'message': userMessage.trim(),
        'zip': zipPath,
        'build': (report['build'] as Map<String, Object?>?)?.cast<String, Object?>(),
      };
      final File f = File(_submissionsLog);
      await f.parent.create(recursive: true);
      await f.writeAsString(
        '${jsonEncode(row)}\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {}
  }

  static String _stamp() {
    final DateTime n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}${two(n.month)}${two(n.day)}_${two(n.hour)}${two(n.minute)}${two(n.second)}';
  }

  static Future<void> _copyIfExists(String src, String dest) async {
    final File f = File(src);
    if (!await f.exists()) return;
    await f.copy(dest);
  }

  static Future<bool> _zipWithPowerShell(String sourceDir, String zipPath) async {
    final String srcEsc = sourceDir.replaceAll("'", "''");
    final String zipEsc = zipPath.replaceAll("'", "''");
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final String ps = p.join(
      windir,
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
    final ProcessResult r = await windowsRunHidden(
      ps,
      <String>[
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-Command',
        "Compress-Archive -Path (Join-Path '$srcEsc' '*') "
            "-DestinationPath '$zipEsc' -Force",
      ],
    );
    if (r.exitCode != 0) return false;
    final File z = File(zipPath);
    return await z.exists() && await z.length() > 0;
  }

  static String _encodeMailQuery(Map<String, String> params) {
    return params.entries
        .map(
          (MapEntry<String, String> e) =>
              '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}',
        )
        .join('&');
  }
}
