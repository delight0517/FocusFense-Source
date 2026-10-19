import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';
import 'chat_schedule_audit_log_service.dart';
import 'platform_process.dart';
import 'local_database.dart';
import 'lock_policy_service.dart';
import 'uninstall_friction_policy_service.dart';
import 'global_usage_cap_service.dart';
import 'usage_bucket_config_service.dart';
import 'youtube_budget_exemption_store.dart';
import 'game_daily_budget_service.dart';
import 'browser_performance_prefs.dart';

/// Lightweight, **survive-the-reinstall** local backup.
///
/// Contract the user explicitly asked for:
///   * Auto-sync after every write (debounced, tiny JSON).
///   * Folder is user-pickable; defaults to `~/Documents/6 VPN Blocker Backup`
///     on macOS so it lives **outside** the app bundle / app-support dir and
///     therefore survives an app delete + reinstall.
///   * On the next launch after a fresh install (no local schedules yet),
///     auto-restore from the folder so the user's data + lock settings
///     come back exactly as they were.
///   * Subtle [status] notifier drives a small chip somewhere unobtrusive in
///     the UI — never a blocking spinner.
///
/// Implementation notes:
///   * Snapshot format = single JSON file `current.json`. Trivial to read by
///     humans, trivial to copy/move/sync via Dropbox/iCloud/etc.
///   * `snapshots/snapshot_YYYY-MM-DD.json` rolls a once-per-day archive in
///     case `current.json` is corrupted by an OS-level crash mid-write.
///   * All writes go to a `.tmp` sibling then `rename()` to be atomic.
final class BackupService {
  BackupService._();
  static final BackupService instance = BackupService._();

  static const String _kFolderPref = 'backup_folder_v1';
  static const String _kInstallToken = 'install_token_v1';
  static const Duration _debounce = Duration(milliseconds: 300);

  /// Bumped whenever the snapshot shape changes so older snapshots can be
  /// recognised on restore. v4 adds `scheduleSlots` and `blockedApps`; v5
  /// is purely informational (no shape change) but bumped so we can tell
  /// post-v8 lock-cooldown data apart from pre-v8 snapshots. v6 adds
  /// `lockSchedule` and `usagePeriodHours` (SharedPreferences) so schedule
  /// mode and usage aggregation survive restore. v7 adds `uninstallFriction`
  /// (wait seconds + optional duration-edit lock). v9 adds
  /// `chatScheduleAuditLog` — the last 7 days of chat-driven schedule
  /// changes, for AI/developer debugging only; NOT restored on reinstall.
  static const int _kSnapshotVersion = 9;

  final ValueNotifier<BackupStatus> status = ValueNotifier<BackupStatus>(
    const BackupStatus.idle(),
  );

  Timer? _timer;
  bool _bootstrapped = false;

  /// Set to `true` once we have either:
  ///   * confirmed there's nothing to restore, or
  ///   * finished restoring.
  /// `scheduleSync()` no-ops until this flips so a fresh-install never
  /// overwrites a good backup with an empty DB.
  bool _safeToSync = false;

  /// Bootstraps the folder. Does NOT enable syncing — that's `markSafeToSync`.
  Future<void> ensureBootstrapped() async {
    if (_bootstrapped) return;
    _bootstrapped = true;
    await _ensureFolderExists();
  }

  Future<String> defaultFolder() async {
    if (Platform.isMacOS) {
      final String home = Platform.environment['HOME'] ?? '';
      return p.join(home, 'Documents', '6 VPN Blocker Backup');
    }
    if (Platform.isWindows) {
      final String home = Platform.environment['USERPROFILE'] ?? '';
      if (home.isNotEmpty) {
        return p.join(home, 'Documents', '6 VPN Blocker Backup');
      }
    }
    final Directory docs = await getApplicationDocumentsDirectory();
    return p.join(docs.path, 'Backup');
  }

  Future<String> resolvedFolder() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? saved = prefs.getString(_kFolderPref);
    if (saved != null && saved.isNotEmpty) return saved;
    return defaultFolder();
  }

  Future<void> setFolder(String path) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kFolderPref, path);
    await _ensureFolderExists();
    // Don't `scheduleSync()` blindly — wait for the safety gate so we don't
    // overwrite an existing backup at the new location.
    if (_safeToSync) scheduleSync();
  }

  /// Clears the custom path and returns to [defaultFolder] (Documents/…).
  Future<void> useDefaultFolder() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kFolderPref);
    await _ensureFolderExists();
    if (_safeToSync) scheduleSync();
  }

  /// Creates `parent/childName` and switches the backup target there.
  Future<String> createAndUseSubfolder({
    required String parent,
    required String childName,
  }) async {
    final String safe = childName
        .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
        .trim();
    if (safe.isEmpty) {
      throw StateError('empty folder name');
    }
    final String path = p.join(parent, safe);
    await Directory(path).create(recursive: true);
    await setFolder(path);
    return path;
  }

  Future<void> _ensureFolderExists() async {
    final String folder = await resolvedFolder();
    final Directory dir = Directory(folder);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final Directory snaps = Directory(p.join(folder, 'snapshots'));
    if (!await snaps.exists()) {
      await snaps.create(recursive: true);
    }
  }

  /// Public entry point — call any time data changes.
  void scheduleSync() {
    if (!_safeToSync) return; // gated until restore decision is made
    _timer?.cancel();
    status.value = const BackupStatus.queued();
    _timer = Timer(_debounce, _runSyncNow);
  }

  /// Force an immediate sync (returns when finished). Bypasses debounce but
  /// still respects the safety gate so we don't clobber a backup.
  Future<BackupRunResult> syncNow() async {
    if (!_safeToSync) {
      return const BackupRunResult(ok: false, error: 'restore pending');
    }
    _timer?.cancel();
    return _runSyncNow();
  }

  Future<BackupRunResult> _runSyncNow() async {
    status.value = const BackupStatus.saving();
    try {
      await _ensureFolderExists();
      final String folder = await resolvedFolder();
      final Map<String, Object?> dump = await _dumpDatabase();
      final String json = const JsonEncoder.withIndent('  ').convert(dump);

      // Atomic write: `.tmp` then rename so a crash mid-write never leaves
      // a half-written `current.json`.
      final File current = File(p.join(folder, 'current.json'));
      final File tmp = File('${current.path}.tmp');
      await tmp.writeAsString(json, flush: true);
      try {
        await tmp.rename(current.path);
      } catch (_) {
        // Cross-volume or sandboxed FS may reject rename — fall back to copy.
        await tmp.copy(current.path);
        await tmp.delete();
      }

      final DateTime now = DateTime.now();
      final String stamp =
          '${now.year.toString().padLeft(4, '0')}-'
          '${now.month.toString().padLeft(2, '0')}-'
          '${now.day.toString().padLeft(2, '0')}';
      final File daily = File(
        p.join(folder, 'snapshots', 'snapshot_$stamp.json'),
      );
      try {
        await daily.writeAsString(json, flush: true);
      } catch (e) {
        AppLogger.instance.warn('daily snapshot write failed: $e');
      }

      status.value = BackupStatus.synced(when: now, path: current.path);
      return BackupRunResult(ok: true, path: current.path);
    } catch (e, st) {
      AppLogger.instance.error('backup sync failed', error: e, stack: st);
      status.value = BackupStatus.error(e.toString());
      return BackupRunResult(ok: false, error: e.toString());
    }
  }

  Future<Map<String, Object?>> _dumpDatabase() async {
    final LocalDatabase db = LocalDatabase.instance;
    return <String, Object?>{
      'schemaVersion': _kSnapshotVersion,
      'exportedAt': DateTime.now().toIso8601String(),
      'schedules': await db.schedules(),
      'scheduleSlots': await db.allScheduleSlots(),
      'keywords': await db.keywordsIncludingTrash(),
      'domains': await db.domainsIncludingTrash(),
      'blockedApps': await db.allBlockedAppsIncludingTrash(),
      'serpFilters': await db.serpFilters(),
      'searchQueryBlocks': await db.searchQueryBlocks(),
      'rulesMeta': (await db.rulesMeta()).toPrefsJson(),
      'lockSchedule': await LockPolicyService.instance.toBackupMap(),
      'usagePeriodHours': await UsageBucketConfigService.instance
          .getPeriodHours(),
      'globalUsageCap': await GlobalUsageCapService.instance.toBackupMap(),
      'youtubeBudgetExemptions': await YoutubeBudgetExemptionStore.instance
          .entries(),
        'gameDailyBudget': await GameDailyBudgetService.instance.toBackupMap(),
        'firefoxYoutubeFeedFiltering': await BrowserPerformancePrefs.instance.youtubeFeedFiltering(),
      'uninstallFriction': await UninstallFrictionPolicyService.instance
          .toBackupMap(),
      // Debug-only, informational: NOT read by restoreFromBackupMap. Kept
      // here so a full backup export always carries the chat-schedule audit
      // trail alongside the data it explains. See
      // docs/CHAT_SCHEDULE_AUDIT_LOG.md.
      'chatScheduleAuditLog': await ChatScheduleAuditLogService.instance
          .recentEntries(),
    };
  }

  // ─────────────────────────── RESTORE ───────────────────────────

  /// True if the local DB looks like a fresh install: no schedules, no
  /// keywords, no domains, no blocked apps. Used to decide whether to
  /// auto-restore at launch.
  Future<bool> _localDbLooksFresh() async {
    final LocalDatabase db = LocalDatabase.instance;
    final List<Map<String, Object?>> s = await db.schedules();
    if (s.isNotEmpty) return false;
    final List<Map<String, Object?>> k = await db.keywords();
    if (k.isNotEmpty) return false;
    final List<Map<String, Object?>> d = await db.domains();
    if (d.isNotEmpty) return false;
    return true;
  }

  /// Inspect [folder] (or the configured one if null) and return the
  /// available restore source: the absolute path to `current.json` plus a
  /// summary of how many of each entity is inside, OR null if nothing's
  /// available.
  Future<RestorePreview?> previewRestore({String? folder}) async {
    final String dir = folder ?? await resolvedFolder();
    final File current = File(p.join(dir, 'current.json'));
    if (!await current.exists()) return null;
    try {
      final String raw = await current.readAsString();
      if (raw.trim().isEmpty) return null;
      final Map<String, Object?> data =
          json.decode(raw) as Map<String, Object?>;
      final int schedules = (data['schedules'] as List<Object?>?)?.length ?? 0;
      final int slots = (data['scheduleSlots'] as List<Object?>?)?.length ?? 0;
      final int domains = (data['domains'] as List<Object?>?)?.length ?? 0;
      final int keywords = (data['keywords'] as List<Object?>?)?.length ?? 0;
      final int apps = (data['blockedApps'] as List<Object?>?)?.length ?? 0;
      final String? exportedAt = data['exportedAt'] as String?;
      return RestorePreview(
        sourcePath: current.path,
        exportedAt: exportedAt != null ? DateTime.tryParse(exportedAt) : null,
        schedules: schedules,
        scheduleSlots: slots,
        domains: domains,
        keywords: keywords,
        blockedApps: apps,
      );
    } catch (e) {
      AppLogger.instance.warn('previewRestore failed: $e');
      return null;
    }
  }

  /// Force-restore from the configured folder. Returns the loaded counts.
  /// Wipes the local user tables first, then bulk-inserts every row from
  /// the snapshot. Marks the safety gate as open so future writes sync.
  Future<RestoreResult> restoreNow({String? folder}) async {
    status.value = const BackupStatus.saving();
    try {
      final String dir = folder ?? await resolvedFolder();
      final File current = File(p.join(dir, 'current.json'));
      if (!await current.exists()) {
        _safeToSync = true;
        status.value = const BackupStatus.idle();
        return const RestoreResult(ok: false, error: 'no current.json');
      }
      final String raw = await current.readAsString();
      final Map<String, Object?> data =
          json.decode(raw) as Map<String, Object?>;
      final LocalDatabase db = LocalDatabase.instance;
      final RestoreCounts counts = await db.restoreFromBackupMap(data);
      await YoutubeBudgetExemptionStore.instance.restoreFromBackup(
        data['youtubeBudgetExemptions'],
      );
        await GameDailyBudgetService.instance.restoreFromBackup(data['gameDailyBudget']);
        if (data['firefoxYoutubeFeedFiltering'] is bool) {
          await BrowserPerformancePrefs.instance.setYoutubeFeedFiltering(data['firefoxYoutubeFeedFiltering'] as bool);
        }
      await LockPolicyService.instance.restoreFromBackupMap(
        data['lockSchedule'],
      );
      await UsageBucketConfigService.instance.restoreFromBackup(
        data['usagePeriodHours'],
      );
      await GlobalUsageCapService.instance.restoreFromBackup(
        data['globalUsageCap'],
      );
      await UninstallFrictionPolicyService.instance.restoreFromBackupMap(
        data['uninstallFriction'],
      );
      await _markInstalled();
      _safeToSync = true;
      status.value = BackupStatus.synced(
        when: DateTime.now(),
        path: current.path,
      );
      AppLogger.instance.info(
        'restored from backup: schedules=${counts.schedules} '
        'slots=${counts.scheduleSlots} keywords=${counts.keywords} '
        'domains=${counts.domains} apps=${counts.blockedApps}',
      );
      return RestoreResult(ok: true, counts: counts, sourcePath: current.path);
    } catch (e, st) {
      AppLogger.instance.error('restore failed', error: e, stack: st);
      status.value = BackupStatus.error(e.toString());
      _safeToSync = true; // unblock — user can manually retry
      return RestoreResult(ok: false, error: e.toString());
    }
  }

  /// One-shot, called early in launch. If the local DB is empty AND the
  /// backup folder has a `current.json`, restore it. Otherwise just open
  /// the safety gate so normal syncs can run.
  ///
  /// Returns the restore result when a restore actually happened, null
  /// otherwise.
  Future<RestoreResult?> autoRestoreIfFresh() async {
    try {
      await ensureBootstrapped();
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final bool everInstalled = prefs.getString(_kInstallToken) != null;
      final bool fresh = await _localDbLooksFresh();
      if (!fresh) {
        // We have data — never auto-restore. Just open the gate.
        await _markInstalled();
        _safeToSync = true;
        return null;
      }
      final RestorePreview? preview = await previewRestore();
      if (preview == null) {
        // Nothing to restore. Mark install + open gate; future writes will
        // populate the (currently empty) backup folder.
        await _markInstalled();
        _safeToSync = true;
        return null;
      }
      AppLogger.instance.info(
        'auto-restoring: fresh DB (everInstalled=$everInstalled), '
        'found ${preview.schedules} schedules in backup',
      );
      return await restoreNow();
    } catch (e, st) {
      AppLogger.instance.error(
        'autoRestoreIfFresh failed',
        error: e,
        stack: st,
      );
      _safeToSync = true; // never deadlock the writer
      return null;
    }
  }

  Future<void> _markInstalled() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (prefs.getString(_kInstallToken) == null) {
      await prefs.setString(_kInstallToken, DateTime.now().toIso8601String());
    }
  }

  /// Reveal the resolved folder in Finder (macOS) or open it via the OS.
  Future<void> revealFolder() async {
    final String folder = await resolvedFolder();
    await PlatformProcess.openFolder(folder);
  }
}

class BackupStatus {
  const BackupStatus._(this.kind, {this.when, this.path, this.error});
  const BackupStatus.idle() : this._(BackupStatusKind.idle);
  const BackupStatus.queued() : this._(BackupStatusKind.queued);
  const BackupStatus.saving() : this._(BackupStatusKind.saving);
  const BackupStatus.synced({DateTime? when, String? path})
    : this._(BackupStatusKind.synced, when: when, path: path);
  const BackupStatus.error(String reason)
    : this._(BackupStatusKind.error, error: reason);

  final BackupStatusKind kind;
  final DateTime? when;
  final String? path;
  final String? error;
}

enum BackupStatusKind { idle, queued, saving, synced, error }

class BackupRunResult {
  const BackupRunResult({required this.ok, this.path, this.error});
  final bool ok;
  final String? path;
  final String? error;
}

/// Lightweight preview of the snapshot at a given folder, for the
/// "Restore?" dialog.
class RestorePreview {
  const RestorePreview({
    required this.sourcePath,
    required this.exportedAt,
    required this.schedules,
    required this.scheduleSlots,
    required this.domains,
    required this.keywords,
    required this.blockedApps,
  });
  final String sourcePath;
  final DateTime? exportedAt;
  final int schedules;
  final int scheduleSlots;
  final int domains;
  final int keywords;
  final int blockedApps;
}

class RestoreResult {
  const RestoreResult({
    required this.ok,
    this.counts,
    this.sourcePath,
    this.error,
  });
  final bool ok;
  final RestoreCounts? counts;
  final String? sourcePath;
  final String? error;
}
