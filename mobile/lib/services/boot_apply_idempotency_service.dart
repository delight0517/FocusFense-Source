import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'automated_browser_handoff_service.dart';
import 'build_identity_service.dart';
import 'crash_journal_service.dart';
import 'extension_rules_builder.dart';
import 'windows_extension_guard_service.dart';

/// Skips redundant boot/resume apply when nothing changed since last success.
///
/// Cursor agents: read `%USERPROFILE%\Documents\SixVPN_Blocker_Debug\boot_apply_idempotency.json`
/// — when `skipRedundantBootApply` is true, do **not** re-run full PAC/hosts/extension
/// pipelines until fingerprint or build changes.
final class BootApplyIdempotencyService {
  BootApplyIdempotencyService._();
  static final BootApplyIdempotencyService instance =
      BootApplyIdempotencyService._();

  static const Duration kSkipTtl = Duration(hours: 36);

  String get snapshotPath => p.join(
        CrashJournalService.instance.debugFolderPath,
        'boot_apply_idempotency.json',
      );

  Future<String> computeFingerprint() async {
    final BuildIdentity build = await BuildIdentityService.instance.current();
    final ExtensionRulesPayload rules =
        await ExtensionRulesBuilder.buildActiveNow();
    final ExtensionPolicyVerifyResult ext =
        await WindowsExtensionGuardService.verifyAllPolicies();
    final BrowserProcessProbe probe =
        await AutomatedBrowserHandoffService.probeBrowsers();

    final int ruleCount = rules.keywords.length +
        rules.blockedDomains.length +
        rules.blockedYoutubeVideoIds.length;
    return <String>[
      'b${build.buildNumber}',
      'rules=$ruleCount',
      'ext=${ext.protectionOk}',
      'cp=${probe.chromeProtected}',
      'cu=${probe.chromeUnprotected}',
      'cr=${probe.chromeRunning}',
    ].join('|');
  }

  /// Whether launch/resume pipelines should no-op (steady state).
  Future<BootApplySkipVerdict> evaluateSkip({
    required String reason,
    bool userInitiated = false,
    bool force = false,
  }) async {
    if (!Platform.isWindows) {
      return const BootApplySkipVerdict(run: true);
    }
    if (userInitiated || force) {
      return const BootApplySkipVerdict(run: true);
    }
    if (reason == 'manual' ||
        reason.contains('user') ||
        reason == 'post_rebuild') {
      return const BootApplySkipVerdict(run: true);
    }

    final BrowserProcessProbe probe =
        await AutomatedBrowserHandoffService.probeBrowsers();
    if (probe.chromeUnprotected) {
      return const BootApplySkipVerdict(
        run: true,
        detail: 'plain_chrome_running',
      );
    }

    final String fingerprint = await computeFingerprint();
    final BootApplyIdempotencySnapshot? last = await _read();
    if (last == null) {
      return const BootApplySkipVerdict(run: true, detail: 'no_prior_success');
    }
    if (!last.ok || last.fingerprint != fingerprint) {
      return const BootApplySkipVerdict(run: true, detail: 'fingerprint_changed');
    }
    final Duration age = DateTime.now().difference(last.at);
    if (age > kSkipTtl) {
      return const BootApplySkipVerdict(run: true, detail: 'ttl_expired');
    }

    return BootApplySkipVerdict(
      run: false,
      fingerprint: fingerprint,
      detail: 'steady_state',
      messageKo:
          '이전 부트 적용이 유효합니다 (${age.inHours}시간 전 성공) — 중복 PAC·확장·handoff 생략. '
          '빌드·규칙·Chrome 보호 상태가 바뀌면 자동 재적용.',
    );
  }

  Future<void> recordSuccess({
    required String source,
    String? verdict,
  }) async {
    if (!Platform.isWindows) return;
    try {
      final String fingerprint = await computeFingerprint();
      final BootApplyIdempotencySnapshot snap = BootApplyIdempotencySnapshot(
        at: DateTime.now(),
        fingerprint: fingerprint,
        ok: true,
        source: source,
        verdict: verdict ?? 'ok',
      );
      await _write(snap);
      AppLogger.instance.info(
        'boot_apply_idempotency: recorded $source fp=$fingerprint',
      );
    } catch (e) {
      AppLogger.instance.warn('boot_apply_idempotency record failed: $e');
    }
  }

  Future<void> invalidate({String reason = 'manual'}) async {
    try {
      final BootApplyIdempotencySnapshot? last = await _read();
      if (last == null) return;
      await _write(
        BootApplyIdempotencySnapshot(
          at: DateTime.now(),
          fingerprint: last.fingerprint,
          ok: false,
          source: reason,
          verdict: 'invalidated',
        ),
      );
    } catch (_) {}
  }

  Future<BootApplyIdempotencySnapshot?> _read() async {
    try {
      await CrashJournalService.instance.warmup();
      final File f = File(snapshotPath);
      if (!await f.exists()) return null;
      final Object? raw = jsonDecode(await f.readAsString());
      if (raw is! Map) return null;
      return BootApplyIdempotencySnapshot.fromJson(
        Map<String, Object?>.from(raw),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _write(BootApplyIdempotencySnapshot snap) async {
    await CrashJournalService.instance.warmup();
    final File f = File(snapshotPath);
    await f.parent.create(recursive: true);
    await f.writeAsString(
      const JsonEncoder.withIndent('  ').convert(<String, Object?>{
        ...snap.toJson(),
        'skipRedundantBootApply': snap.ok,
        'cursorReadme':
            'docs/CURSOR_BOOT_APPLY_IDEMPOTENCY.md — do not re-run full boot apply while fingerprint matches and ok=true',
        'updatedAt': DateTime.now().toIso8601String(),
      }),
      flush: true,
    );
  }
}

final class BootApplySkipVerdict {
  const BootApplySkipVerdict({
    required this.run,
    this.fingerprint,
    this.detail,
    this.messageKo,
  });

  final bool run;
  final String? fingerprint;
  final String? detail;
  final String? messageKo;

  bool get skip => !run;
}

final class BootApplyIdempotencySnapshot {
  const BootApplyIdempotencySnapshot({
    required this.at,
    required this.fingerprint,
    required this.ok,
    required this.source,
    required this.verdict,
  });

  final DateTime at;
  final String fingerprint;
  final bool ok;
  final String source;
  final String verdict;

  factory BootApplyIdempotencySnapshot.fromJson(Map<String, Object?> json) {
    return BootApplyIdempotencySnapshot(
      at: DateTime.tryParse('${json['at'] ?? ''}') ?? DateTime.now(),
      fingerprint: '${json['fingerprint'] ?? ''}',
      ok: json['ok'] == true,
      source: '${json['source'] ?? ''}',
      verdict: '${json['verdict'] ?? ''}',
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'at': at.toIso8601String(),
        'fingerprint': fingerprint,
        'ok': ok,
        'source': source,
        'verdict': verdict,
      };
}
