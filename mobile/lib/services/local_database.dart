import 'dart:convert';
import 'dart:io' show Directory;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../init_sqflite_desktop.dart';
import '../models/block_app.dart';
import '../models/diagnostic_agent_models.dart';
import '../models/rules_bundle.dart';
import '../models/rules_meta.dart';
import 'backup_service.dart';
import 'block_sync_service.dart';
import 'usage_bucket_config_service.dart';

/// Calls [BackupService.scheduleSync] without forcing a circular import for
/// pure DB read paths. Wrapped so tests / non-Mac platforms tolerate it.
/// Also debounce-schedules a Mac system-block re-apply so /etc/hosts stays
/// in sync with the latest rules without the user having to click "Apply".
void _kickBackup() {
  try {
    BackupService.instance.scheduleSync();
  } catch (_) {
    // Backup is best-effort; never crash a DB write because of it.
  }
  try {
    BlockSyncService.instance.requestApply();
  } catch (_) {
    // Same: never crash a DB write because of an apply scheduler hiccup.
  }
}

const String _kRulesMetaKey = 'rules_meta';

/// Phases of the per-schedule lock state machine. Computed purely from the
/// `schedules` row — no client state required. See `scheduleLockPhase`.
enum ScheduleLockPhase {
  /// User has not locked this schedule — free edits.
  unlocked,

  /// Locked, no countdown running. To edit, tap "Start unlock" which moves
  /// into [countdown].
  locked,

  /// Cooldown timer running. Modifications still refused. UI shows progress.
  countdown,

  /// Cooldown elapsed — 5-minute edit window. Modifications allowed.
  editWindow,
}

final class RuleCounts {
  const RuleCounts({
    required this.keywordsTotal,
    required this.keywordsEnabled,
    required this.domainsTotal,
    required this.domainsEnabled,
    required this.serpFiltersTotal,
    required this.serpFiltersEnabled,
    required this.searchBlocksTotal,
    required this.searchBlocksEnabled,
  });

  final int keywordsTotal;
  final int keywordsEnabled;
  final int domainsTotal;
  final int domainsEnabled;
  final int serpFiltersTotal;
  final int serpFiltersEnabled;
  final int searchBlocksTotal;
  final int searchBlocksEnabled;
}

final class LocalDatabase {
  LocalDatabase._();

  static final LocalDatabase instance = LocalDatabase._();

  Database? _db;

  Future<Database> get database async {
    ensureSqfliteDesktopInitialized();
    if (_db != null) return _db!;
    final Directory dir = await getApplicationDocumentsDirectory();
    final String path = p.join(dir.path, 'six_clean_room.db');
    _db = await openDatabase(
      path,
      version: 15,
      onCreate: (Database db, int version) async {
        await _createV2Schema(db);
        await _createV3Schema(db);
        await _createV4Schema(db);
        await _createV5Schema(db);
        await _createV6Schema(db);
        await _createV7Schema(db);
        await _createV8Schema(db);
        await _createV9Schema(db);
        await _createV10Schema(db);
        await _createV11Schema(db);
        await _createV12Schema(db);
        await _createV13Schema(db);
        await _createV14Schema(db);
        await _createV15Schema(db);
        await _ensureRulesMeta(db);
        await _seedDefaultSerpIfEmpty(db);
        await _seedNightlyForegroundLimitsIfEmpty(db);
      },
      onUpgrade: (Database db, int oldVersion, int newVersion) async {
        if (oldVersion < 2) await _upgradeToV2(db);
        if (oldVersion < 3) await _upgradeToV3(db);
        if (oldVersion < 4) await _upgradeToV4(db);
        if (oldVersion < 5) await _upgradeToV5(db);
        if (oldVersion < 6) await _upgradeToV6(db);
        if (oldVersion < 7) await _upgradeToV7(db);
        if (oldVersion < 8) await _upgradeToV8(db);
        if (oldVersion < 9) await _upgradeToV9(db);
        if (oldVersion < 10) await _upgradeToV10(db);
        if (oldVersion < 11) await _upgradeToV11(db);
        if (oldVersion < 12) await _upgradeToV12(db);
        if (oldVersion < 13) await _upgradeToV13(db);
        if (oldVersion < 14) await _upgradeToV14(db);
        if (oldVersion < 15) await _upgradeToV15(db);
      },
    );
    return _db!;
  }

  static Future<void> _createV2Schema(Database db) async {
    await db.execute('''
CREATE TABLE keywords (
  id TEXT PRIMARY KEY,
  pattern TEXT NOT NULL,
  match_type TEXT NOT NULL DEFAULT 'contains',
  action TEXT NOT NULL DEFAULT 'redact',
  case_sensitive INTEGER NOT NULL DEFAULT 0,
  enabled INTEGER NOT NULL DEFAULT 1,
  created_at INTEGER NOT NULL
);
''');
    await db.execute('''
CREATE TABLE domains (
  id TEXT PRIMARY KEY,
  host TEXT NOT NULL,
  include_subdomains INTEGER NOT NULL DEFAULT 1,
  source TEXT NOT NULL DEFAULT 'user',
  enabled INTEGER NOT NULL DEFAULT 1,
  action TEXT NOT NULL DEFAULT 'block_document',
  created_at INTEGER NOT NULL
);
''');
    await db.execute('''
CREATE TABLE settings_kv (
  key TEXT PRIMARY KEY,
  value_json TEXT NOT NULL
);
''');
    await db.execute('''
CREATE TABLE serp_filters (
  id TEXT PRIMARY KEY,
  host_suffix TEXT NOT NULL,
  path_prefix TEXT NOT NULL,
  remove_selectors_json TEXT NOT NULL DEFAULT '[]',
  enabled INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);
''');
    await db.execute('''
CREATE TABLE search_query_blocks (
  id TEXT PRIMARY KEY,
  term TEXT NOT NULL,
  match TEXT NOT NULL DEFAULT 'exact',
  enabled INTEGER NOT NULL DEFAULT 1,
  scope TEXT NOT NULL DEFAULT 'in_app_browser_only',
  created_at INTEGER NOT NULL
);
''');
  }

  static Future<void> _upgradeToV2(Database db) async {
    await _addColumnIfMissing(db, 'keywords', 'case_sensitive', 'INTEGER NOT NULL DEFAULT 0');
    await _addColumnIfMissing(db, 'domains', 'action', "TEXT NOT NULL DEFAULT 'block_document'");
    await db.execute('''
CREATE TABLE IF NOT EXISTS serp_filters (
  id TEXT PRIMARY KEY,
  host_suffix TEXT NOT NULL,
  path_prefix TEXT NOT NULL,
  remove_selectors_json TEXT NOT NULL DEFAULT '[]',
  enabled INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);
''');
    await db.execute('''
CREATE TABLE IF NOT EXISTS search_query_blocks (
  id TEXT PRIMARY KEY,
  term TEXT NOT NULL,
  match TEXT NOT NULL DEFAULT 'exact',
  enabled INTEGER NOT NULL DEFAULT 1,
  scope TEXT NOT NULL DEFAULT 'in_app_browser_only',
  created_at INTEGER NOT NULL
);
''');
    await _ensureRulesMeta(db);
    await _seedDefaultSerpIfEmpty(db);
  }

  static Future<void> _createV3Schema(Database db) async {
    await db.execute('''
CREATE TABLE schedules (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  enabled INTEGER NOT NULL DEFAULT 1,
  start_minute INTEGER NOT NULL DEFAULT 1320,
  end_minute INTEGER NOT NULL DEFAULT 420,
  days_mask INTEGER NOT NULL DEFAULT 127,
  created_at INTEGER NOT NULL
);
''');
    await _addColumnIfMissing(db, 'keywords', 'schedule_id', "TEXT");
    await _addColumnIfMissing(db, 'domains', 'schedule_id', "TEXT");
  }

  static Future<void> _upgradeToV3(Database db) async {
    final List<Map<String, Object?>> exists = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='schedules'",
    );
    if (exists.isEmpty) {
      await _createV3Schema(db);
    } else {
      await _addColumnIfMissing(db, 'keywords', 'schedule_id', "TEXT");
      await _addColumnIfMissing(db, 'domains', 'schedule_id', "TEXT");
    }
  }

  /// v4: soft-delete + stem expansion.
  ///   * `deleted_at INTEGER` — when set, item lives in the Trash and is
  ///     auto-purged after 30 days. NULL = active.
  ///   * `is_stem INTEGER` — when 1 on a domain row, the `host` value is a
  ///     stem (e.g. "porn") that gets expanded to many real hosts at apply
  ///     time, to catch rotating domains like p\*\*\*\*hub1.com.
  static Future<void> _createV4Schema(Database db) async {
    await _addColumnIfMissing(db, 'keywords', 'deleted_at', 'INTEGER');
    await _addColumnIfMissing(db, 'domains', 'deleted_at', 'INTEGER');
    await _addColumnIfMissing(db, 'domains', 'is_stem',
        'INTEGER NOT NULL DEFAULT 0');
  }

  static Future<void> _upgradeToV4(Database db) async {
    await _createV4Schema(db);
  }

  /// v5: per-day time-slot rows. A schedule can have many slots, one or more
  /// per day-of-week. Replaces the old single-window (start/end + mask) model
  /// for the active-now check. The legacy fields on `schedules` are kept for
  /// backward compatibility — schedules with no slots fall back to the old
  /// fields (and are upgraded into slot rows during migration).
  static Future<void> _createV5Schema(Database db) async {
    await db.execute('''
CREATE TABLE IF NOT EXISTS schedule_slots (
  id TEXT PRIMARY KEY,
  schedule_id TEXT NOT NULL,
  day INTEGER NOT NULL,
  start_minute INTEGER NOT NULL,
  end_minute INTEGER NOT NULL,
  created_at INTEGER NOT NULL
);
''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_schedule_slots_schedule '
      'ON schedule_slots(schedule_id);',
    );
  }

  static Future<void> _upgradeToV5(Database db) async {
    await _createV5Schema(db);
    final List<Map<String, Object?>> tables = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='schedules'",
    );
    if (tables.isEmpty) return;
    final List<Map<String, Object?>> existing = await db.query('schedules');
    final int now = DateTime.now().millisecondsSinceEpoch;
    for (final Map<String, Object?> row in existing) {
      final String id = row['id']! as String;
      final int start = row['start_minute']! as int;
      final int end = row['end_minute']! as int;
      final int mask = row['days_mask']! as int;
      for (int d = 0; d < 7; d++) {
        if ((mask & (1 << d)) == 0) continue;
        if (start == end) {
          await db.insert('schedule_slots', <String, Object?>{
            'id': 'slot_${id}_${d}_all',
            'schedule_id': id,
            'day': d,
            'start_minute': 0,
            'end_minute': 1440,
            'created_at': now,
          });
        } else if (start < end) {
          await db.insert('schedule_slots', <String, Object?>{
            'id': 'slot_${id}_${d}_a',
            'schedule_id': id,
            'day': d,
            'start_minute': start,
            'end_minute': end,
            'created_at': now,
          });
        } else {
          // Overnight window: split into [start..24:00) on day d AND
          // [00:00..end) on day d+1. Always insert both, even when d+1 is
          // already in the mask — the tail represents day d's overflow,
          // not day d+1's own window, so they're distinct slots.
          await db.insert('schedule_slots', <String, Object?>{
            'id': 'slot_${id}_${d}_n1',
            'schedule_id': id,
            'day': d,
            'start_minute': start,
            'end_minute': 1440,
            'created_at': now,
          });
          final int next = (d + 1) % 7;
          await db.insert('schedule_slots', <String, Object?>{
            'id': 'slot_${id}_${d}_n2',
            'schedule_id': id,
            'day': next,
            'start_minute': 0,
            'end_minute': end,
            'created_at': now,
          });
        }
      }
    }
  }

  /// v6 — per-schedule lock.
  ///   * `locked` = 1 when this specific schedule's rules cannot be
  ///     deleted/disabled. Adding always remains allowed.
  ///   * `unlock_until` = epoch-ms; if `> now`, the schedule is *temporarily*
  ///     unlocked even though `locked == 1`. This is the per-schedule grace
  ///     window — set by the user via a duration picker, not a fixed 5min.
  static Future<void> _createV6Schema(Database db) async {
    await _addColumnIfMissing(db, 'schedules', 'locked', 'INTEGER NOT NULL DEFAULT 0');
    await _addColumnIfMissing(db, 'schedules', 'unlock_until', 'INTEGER NOT NULL DEFAULT 0');
  }

  static Future<void> _upgradeToV6(Database db) async {
    await _createV6Schema(db);
  }

  /// v7 — schedule-scoped application blocking.
  ///
  /// Each row pins a display name (case-insensitive, matched against
  /// `NSRunningApplication.localizedName` on macOS) to a schedule. While
  /// the schedule is active the native enforcer terminates any matching
  /// process every 2s.
  ///
  /// We use display names rather than bundle IDs because they survive
  /// future App Store re-signs and let the user just type "Discord"
  /// without hunting the bundle identifier.
  static Future<void> _createV7Schema(Database db) async {
    await db.execute('''
CREATE TABLE IF NOT EXISTS blocked_apps (
  id TEXT PRIMARY KEY,
  schedule_id TEXT NOT NULL,
  name TEXT NOT NULL,
  bundle_id TEXT,
  created_at INTEGER NOT NULL,
  deleted_at INTEGER
);
''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_blocked_apps_schedule '
      'ON blocked_apps(schedule_id);',
    );
  }

  static Future<void> _upgradeToV7(Database db) async {
    await _createV7Schema(db);
  }

  /// v8 — pre-committed lock cooldown.
  ///
  /// The user's commitment is made at schedule-creation time: pick a number
  /// (`lock_cooldown_minutes`) that future-self will be forced to wait
  /// before any modification is allowed. While the schedule is locked the
  /// cooldown is **immutable** — you cannot lower it on impulse.
  ///
  /// `unlock_started_at` (epoch-ms) is when the user tapped "Start unlock".
  /// Phases derived from these three columns:
  ///   * Locked, no countdown    → started == 0 and locked == 1
  ///   * Cooldown running        → now < started + cooldown_ms
  ///   * Edit window (5 min)     → started + cooldown ≤ now < +cooldown+5min
  ///   * Re-locked automatically → otherwise
  ///
  /// Re-uses the existing `unlock_until` column from v6 as a compatibility
  /// shim for older code paths that still query it. We keep it in sync.
  static Future<void> _createV8Schema(Database db) async {
    await _addColumnIfMissing(
        db, 'schedules', 'lock_cooldown_minutes', 'INTEGER NOT NULL DEFAULT 30');
    await _addColumnIfMissing(
        db, 'schedules', 'unlock_started_at', 'INTEGER NOT NULL DEFAULT 0');
  }

  static Future<void> _upgradeToV8(Database db) async {
    await _createV8Schema(db);
    // v6→v8: zero out any stale duration-style unlock_until from the old
    // "pick a duration" model so users start fresh on the new contract.
    await db.update('schedules',
        <String, Object?>{'unlock_until': 0, 'unlock_started_at': 0});
  }

  /// v9 — foreground usage buckets (Mac) + per-subject daily caps.
  static Future<void> _createV9Schema(Database db) async {
    await db.execute('''
CREATE TABLE IF NOT EXISTS usage_hourly (
  subject TEXT NOT NULL,
  hour_start_ms INTEGER NOT NULL,
  seconds INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (subject, hour_start_ms)
);
''');
    await db.execute('''
CREATE TABLE IF NOT EXISTS usage_daily (
  subject TEXT NOT NULL,
  day_start_ms INTEGER NOT NULL,
  seconds INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (subject, day_start_ms)
);
''');
    await db.execute('''
CREATE TABLE IF NOT EXISTS usage_limits (
  id TEXT PRIMARY KEY,
  subject TEXT NOT NULL UNIQUE,
  display_label TEXT NOT NULL,
  max_seconds_per_day INTEGER NOT NULL DEFAULT 900,
  created_at INTEGER NOT NULL
);
''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_usage_hourly_time ON usage_hourly(hour_start_ms);');
  }

  static Future<void> _upgradeToV9(Database db) async {
    await _createV9Schema(db);
  }

  /// v10 — in-app diagnostic agent audit log (mutating actions only).
  static Future<void> _createV10Schema(Database db) async {
    await db.execute('''
CREATE TABLE IF NOT EXISTS diagnostic_agent_log (
  id TEXT PRIMARY KEY,
  created_at_ms INTEGER NOT NULL,
  action_kind TEXT NOT NULL,
  status TEXT NOT NULL,
  reason TEXT NOT NULL,
  detail_json TEXT NOT NULL DEFAULT '{}'
);
''');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_diag_agent_log_time ON diagnostic_agent_log(created_at_ms);');
  }

  static Future<void> _upgradeToV10(Database db) async {
    await _createV10Schema(db);
  }

  static Future<void> _createV11Schema(Database db) async {
    await _addColumnIfMissing(db, 'usage_limits', 'quota_mode', "TEXT NOT NULL DEFAULT 'daily'");
    await _addColumnIfMissing(db, 'usage_limits', 'window_seconds', 'INTEGER NOT NULL DEFAULT 10800');
    await _addColumnIfMissing(db, 'usage_limits', 'session_max_seconds', 'INTEGER NOT NULL DEFAULT 0');
    await _addColumnIfMissing(
        db, 'usage_limits', 'session_period_seconds', 'INTEGER NOT NULL DEFAULT 1800');
    await _addColumnIfMissing(db, 'usage_limits', 'enabled', 'INTEGER NOT NULL DEFAULT 1');
    await db.execute('''
CREATE TABLE IF NOT EXISTS usage_quota_session (
  limit_id TEXT PRIMARY KEY,
  period_start_ms INTEGER NOT NULL,
  used_seconds INTEGER NOT NULL DEFAULT 0
);
''');
  }

  static Future<void> _upgradeToV11(Database db) async {
    await _createV11Schema(db);
  }

  /// v12 — per-schedule search-query blocks (Google/YouTube 검색어 차단).
  static Future<void> _createV12Schema(Database db) async {
    await _addColumnIfMissing(
        db, 'search_query_blocks', 'schedule_id', 'TEXT');
  }

  static Future<void> _upgradeToV12(Database db) async {
    await _createV12Schema(db);
  }

  /// v13 — foreground vs background seconds in usage buckets (YT Music 등).
  static Future<void> _createV13Schema(Database db) async {
    await _addColumnIfMissing(
        db, 'usage_hourly', 'fg_seconds', 'INTEGER NOT NULL DEFAULT 0');
    await _addColumnIfMissing(
        db, 'usage_hourly', 'bg_seconds', 'INTEGER NOT NULL DEFAULT 0');
    await _addColumnIfMissing(
        db, 'usage_daily', 'fg_seconds', 'INTEGER NOT NULL DEFAULT 0');
    await _addColumnIfMissing(
        db, 'usage_daily', 'bg_seconds', 'INTEGER NOT NULL DEFAULT 0');
    await db.execute(
      'UPDATE usage_hourly SET fg_seconds = seconds WHERE fg_seconds = 0 AND seconds > 0',
    );
    await db.execute(
      'UPDATE usage_daily SET fg_seconds = seconds WHERE fg_seconds = 0 AND seconds > 0',
    );
  }

  static Future<void> _upgradeToV13(Database db) async {
    await _createV13Schema(db);
  }

  /// v14 — preset **bundle** tracking. Before this, clicking a preset chip
  /// (e.g. 「성인」) inserted every domain/keyword as an indistinguishable
  /// individual `source='user'` row — no way to manage or remove the whole
  /// bundle as a unit later. `preset_id` tags each row with the bundle it
  /// came from; `schedule_applied_presets` records which bundles are "on"
  /// for a schedule so the UI can show ✓ state and offer a single
  /// "묶음 전체 제거" action instead of hunting down scattered rows.
  static Future<void> _createV14Schema(Database db) async {
    await _addColumnIfMissing(db, 'domains', 'preset_id', 'TEXT');
    await _addColumnIfMissing(db, 'keywords', 'preset_id', 'TEXT');
    await db.execute('''
CREATE TABLE IF NOT EXISTS schedule_applied_presets (
  schedule_id TEXT NOT NULL,
  preset_id TEXT NOT NULL,
  applied_at INTEGER NOT NULL,
  PRIMARY KEY (schedule_id, preset_id)
);
''');
  }

  static Future<void> _upgradeToV14(Database db) async {
    await _createV14Schema(db);
  }

  /// v15 — nightly "foreground-only, per-hour" quota (e.g. YouTube Music
  /// 23:00–11:00, 15분/시간 while it's the active/visible tab or PWA window;
  /// background playback stays unlimited). See [UsageQuotaMode.hourlyForegroundWindow].
  static Future<void> _createV15Schema(Database db) async {
    await _addColumnIfMissing(
        db, 'usage_limits', 'window_start_hour', 'INTEGER NOT NULL DEFAULT -1');
    await _addColumnIfMissing(
        db, 'usage_limits', 'window_end_hour', 'INTEGER NOT NULL DEFAULT -1');
    await _addColumnIfMissing(
        db, 'usage_limits', 'max_seconds_per_hour', 'INTEGER NOT NULL DEFAULT 900');
  }

  static Future<void> _upgradeToV15(Database db) async {
    await _createV15Schema(db);
    await _seedNightlyForegroundLimitsIfEmpty(db);
  }

  /// Seeds the "YouTube Music 야간 포그라운드 제한" the user asked for
  /// (23:00–11:00, 15분/시간 foreground-only, 백그라운드 무제한) so the
  /// feature works out of the box. Only inserts if that subject has no
  /// existing row (won't clobber a user's own edit/delete of it).
  static Future<void> _seedNightlyForegroundLimitsIfEmpty(DatabaseExecutor db) async {
    const String subject = 'web|music.youtube.com';
    final List<Map<String, Object?>> existing = await db.query(
      'usage_limits',
      where: 'subject = ?',
      whereArgs: <Object>[subject],
      limit: 1,
    );
    if (existing.isNotEmpty) return;
    await db.insert(
      'usage_limits',
      <String, Object?>{
        'id': 'seed-nightly-fg-youtube-music',
        'subject': subject,
        'display_label': 'YouTube Music (야간 포그라운드)',
        'max_seconds_per_day': 900,
        'quota_mode': 'hourly_fg_window',
        'window_seconds': 10800,
        'session_max_seconds': 0,
        'session_period_seconds': 1800,
        'window_start_hour': 23,
        'window_end_hour': 11,
        'max_seconds_per_hour': 900,
        'enabled': 1,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  static Future<void> _addColumnIfMissing(Database db, String table, String column, String definition) async {
    final List<Map<String, Object?>> info = await db.rawQuery('PRAGMA table_info($table)');
    final bool exists = info.any((Map<String, Object?> r) => r['name'] == column);
    if (!exists) {
      await db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
    }
  }

  static Future<void> _ensureRulesMeta(DatabaseExecutor db) async {
    final List<Map<String, Object?>> rows =
        await db.query('settings_kv', where: 'key = ?', whereArgs: <Object>[_kRulesMetaKey]);
    if (rows.isEmpty) {
      await db.insert('settings_kv', <String, Object?>{
        'key': _kRulesMetaKey,
        'value_json': RulesMeta.defaults.toPrefsJson(),
      });
    }
  }

  static Future<void> _seedDefaultSerpIfEmpty(DatabaseExecutor db) async {
    final int? n = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) AS c FROM serp_filters'));
    if ((n ?? 0) > 0) return;
    await db.insert('serp_filters', <String, Object?>{
      'id': 'sf_google_default',
      'host_suffix': 'google.',
      'path_prefix': '/search',
      'remove_selectors_json': jsonEncode(<String>['div#search', 'div#rso']),
      'enabled': 0,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  Future<RulesMeta> rulesMeta() async {
    final Database db = await database;
    await _ensureRulesMeta(db);
    final List<Map<String, Object?>> rows =
        await db.query('settings_kv', where: 'key = ?', whereArgs: <Object>[_kRulesMetaKey]);
    return RulesMeta.fromPrefsString(rows.first['value_json']! as String);
  }

  Future<void> saveRulesMeta(RulesMeta meta) async {
    final Database db = await database;
    await db.insert(
      'settings_kv',
      <String, Object?>{
        'key': _kRulesMetaKey,
        'value_json': meta.toPrefsJson(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    _kickBackup();
  }

  Future<RuleCounts> ruleCounts() async {
    final Database db = await database;
    Future<int> count(String sql, [List<Object?>? args]) async {
      return Sqflite.firstIntValue(await db.rawQuery(sql, args)) ?? 0;
    }
    return RuleCounts(
      keywordsTotal: await count('SELECT COUNT(*) AS c FROM keywords'),
      keywordsEnabled: await count('SELECT COUNT(*) AS c FROM keywords WHERE enabled = 1'),
      domainsTotal: await count('SELECT COUNT(*) AS c FROM domains'),
      domainsEnabled: await count('SELECT COUNT(*) AS c FROM domains WHERE enabled = 1'),
      serpFiltersTotal: await count('SELECT COUNT(*) AS c FROM serp_filters'),
      serpFiltersEnabled: await count('SELECT COUNT(*) AS c FROM serp_filters WHERE enabled = 1'),
      searchBlocksTotal: await count('SELECT COUNT(*) AS c FROM search_query_blocks'),
      searchBlocksEnabled: await count('SELECT COUNT(*) AS c FROM search_query_blocks WHERE enabled = 1'),
    );
  }

  Future<List<Map<String, Object?>>> keywords() async {
    final Database db = await database;
    return db.query('keywords',
        where: 'deleted_at IS NULL', orderBy: 'created_at DESC');
  }

  Future<List<Map<String, Object?>>> domains() async {
    final Database db = await database;
    return db.query('domains',
        where: 'deleted_at IS NULL', orderBy: 'created_at DESC');
  }

  /// Items in the Trash (soft-deleted, awaiting purge).
  Future<List<Map<String, Object?>>> trashedKeywords() async {
    final Database db = await database;
    return db.query('keywords',
        where: 'deleted_at IS NOT NULL', orderBy: 'deleted_at DESC');
  }

  Future<List<Map<String, Object?>>> trashedDomains() async {
    final Database db = await database;
    return db.query('domains',
        where: 'deleted_at IS NOT NULL', orderBy: 'deleted_at DESC');
  }

  Future<List<Map<String, Object?>>> serpFilters() async {
    final Database db = await database;
    return db.query('serp_filters', orderBy: 'created_at ASC');
  }

  Future<List<Map<String, Object?>>> searchQueryBlocks() async {
    final Database db = await database;
    return db.query('search_query_blocks', orderBy: 'created_at DESC');
  }

  // Backup helpers — return EVERY row (including soft-deleted ones) so the
  // snapshot is a faithful mirror and Trash can be restored too. Used by
  // `BackupService._dumpDatabase` and `restoreFromBackupMap`.
  Future<List<Map<String, Object?>>> keywordsIncludingTrash() async {
    final Database db = await database;
    return db.query('keywords', orderBy: 'created_at ASC');
  }

  Future<List<Map<String, Object?>>> domainsIncludingTrash() async {
    final Database db = await database;
    return db.query('domains', orderBy: 'created_at ASC');
  }

  Future<List<Map<String, Object?>>> allBlockedAppsIncludingTrash() async {
    final Database db = await database;
    return db.query('blocked_apps', orderBy: 'created_at ASC');
  }

  Future<List<Map<String, Object?>>> allScheduleSlots() async {
    final Database db = await database;
    return db.query('schedule_slots',
        orderBy: 'schedule_id ASC, day ASC, start_minute ASC');
  }

  Future<bool> hasDomainHost(String host) async {
    final Database db = await database;
    final int? n = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) AS c FROM domains WHERE lower(host) = ?', <Object>[host.toLowerCase()]),
    );
    return (n ?? 0) > 0;
  }

  /// Like [hasDomainHost] but ignores soft-deleted rows so a cleared quick-block
  /// host can be re-added.
  Future<bool> hasActiveDomainHost(String host) async {
    final Database db = await database;
    final int? n = Sqflite.firstIntValue(
      await db.rawQuery(
        'SELECT COUNT(*) AS c FROM domains WHERE lower(host) = ? AND deleted_at IS NULL',
        <Object>[host.toLowerCase()],
      ),
    );
    return (n ?? 0) > 0;
  }

  Future<List<Map<String, Object?>>> allDomainsQuickBlock() async {
    final Database db = await database;
    return db.query(
      'domains',
      where: 'schedule_id IS NULL AND source = ? AND deleted_at IS NULL',
      whereArgs: <Object>['quick_block'],
    );
  }

  /// Soft-delete global quick_block domains (see [QuickBlockService]).
  Future<int> softDeleteQuickBlockGlobalDomains() async {
    final Database db = await database;
    final int now = DateTime.now().millisecondsSinceEpoch;
    return db.update(
      'domains',
      <String, Object?>{'deleted_at': now},
      where: 'schedule_id IS NULL AND source = ? AND deleted_at IS NULL',
      whereArgs: <Object>['quick_block'],
    );
  }

  /// Global keywords inserted by [QuickBlockService] (`id` prefix `qb_k_`).
  Future<int> softDeleteQuickBlockGlobalKeywords() async {
    final Database db = await database;
    final int now = DateTime.now().millisecondsSinceEpoch;
    return db.update(
      'keywords',
      <String, Object?>{'deleted_at': now},
      where: 'schedule_id IS NULL AND id LIKE ? AND deleted_at IS NULL',
      whereArgs: <Object>['qb_k_%'],
    );
  }

  Future<bool> hasActiveKeywordPattern(String pattern) async {
    final Database db = await database;
    final int? n = Sqflite.firstIntValue(
      await db.rawQuery(
        'SELECT COUNT(*) AS c FROM keywords WHERE lower(pattern) = ? AND deleted_at IS NULL',
        <Object>[pattern.toLowerCase()],
      ),
    );
    return (n ?? 0) > 0;
  }

  Future<void> insertKeyword({
    required String id,
    required String pattern,
    String matchType = 'contains',
    String action = 'redact',
    bool caseSensitive = false,
    bool enabled = true,
    String? scheduleId,
    String? presetId,
  }) async {
    final Database db = await database;
    await db.insert('keywords', <String, Object?>{
      'id': id,
      'pattern': pattern,
      'match_type': matchType,
      'action': action,
      'case_sensitive': caseSensitive ? 1 : 0,
      'enabled': enabled ? 1 : 0,
      'schedule_id': scheduleId,
      'preset_id': presetId,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    _kickBackup();
  }

  Future<void> setKeywordEnabled(String id, bool enabled) async {
    final Database db = await database;
    await db.update('keywords', <String, Object?>{'enabled': enabled ? 1 : 0}, where: 'id = ?', whereArgs: <Object>[id]);
    // Without this, toggling a keyword on/off never pushes the change to the
    // extension snapshot / HKCU policy / PAC. The user clicks the switch and
    // the block does not apply.
    _kickBackup();
  }

  Future<void> updateKeywordFields({
    required String id,
    String? matchType,
    String? action,
    bool? caseSensitive,
  }) async {
    final Database db = await database;
    final Map<String, Object?> patch = <String, Object?>{};
    if (matchType != null) patch['match_type'] = matchType;
    if (action != null) patch['action'] = action;
    if (caseSensitive != null) patch['case_sensitive'] = caseSensitive ? 1 : 0;
    if (patch.isEmpty) return;
    await db.update('keywords', patch, where: 'id = ?', whereArgs: <Object>[id]);
    _kickBackup();
  }

  /// Soft-delete: moves to Trash (auto-purged after 30 days).
  Future<void> deleteKeyword(String id) async {
    final Database db = await database;
    await db.update(
      'keywords',
      <String, Object?>{'deleted_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: <Object>[id],
    );
    _kickBackup();
  }

  Future<void> restoreKeyword(String id) async {
    final Database db = await database;
    await db.update(
      'keywords',
      <String, Object?>{'deleted_at': null},
      where: 'id = ?',
      whereArgs: <Object>[id],
    );
    _kickBackup();
  }

  Future<void> hardDeleteKeyword(String id) async {
    final Database db = await database;
    await db.delete('keywords', where: 'id = ?', whereArgs: <Object>[id]);
    _kickBackup();
  }

  Future<bool> hasActiveDomain(String host) async {
    final Database db = await database;
    final String h = host.trim().toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    final int? n = Sqflite.firstIntValue(
      await db.rawQuery(
        'SELECT COUNT(*) AS c FROM domains WHERE lower(host) = ? AND deleted_at IS NULL',
        <Object>[h],
      ),
    );
    return (n ?? 0) > 0;
  }

  Future<void> insertDomain({
    required String id,
    required String host,
    bool includeSubdomains = true,
    String source = 'user',
    bool enabled = true,
    String action = 'block_document',
    String? scheduleId,
    bool isStem = false,
    String? presetId,
  }) async {
    final Database db = await database;
    await db.insert('domains', <String, Object?>{
      'id': id,
      'host': host,
      'include_subdomains': includeSubdomains ? 1 : 0,
      'source': source,
      'enabled': enabled ? 1 : 0,
      'action': action,
      'schedule_id': scheduleId,
      'is_stem': isStem ? 1 : 0,
      'preset_id': presetId,
      'deleted_at': null,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    _kickBackup();
  }

  // ── Preset bundle tracking (v14) ──────────────────────────────────────
  // A preset chip (「성인」 etc.) is applied/removed as ONE unit, not as
  // scattered individual domain/keyword rows. `schedule_applied_presets`
  // records which bundles are "on" for a schedule; `preset_id` on each
  // domains/keywords row lets a whole-bundle removal find exactly the rows
  // that bundle added (and none the user added by hand afterward).

  /// Preset IDs currently applied to [scheduleId].
  Future<Set<String>> appliedPresetIds(String scheduleId) async {
    final Database db = await database;
    final List<Map<String, Object?>> rows = await db.query(
      'schedule_applied_presets',
      columns: <String>['preset_id'],
      where: 'schedule_id = ?',
      whereArgs: <Object>[scheduleId],
    );
    return rows.map((r) => r['preset_id']! as String).toSet();
  }

  /// Marks [presetId] as applied to [scheduleId]. Idempotent.
  Future<void> recordAppliedPreset(String scheduleId, String presetId) async {
    final Database db = await database;
    await db.insert(
      'schedule_applied_presets',
      <String, Object?>{
        'schedule_id': scheduleId,
        'preset_id': presetId,
        'applied_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  /// Removes the whole [presetId] bundle from [scheduleId]: soft-deletes
  /// every domain/keyword row tagged with that preset (to Trash, 30-day
  /// purge — same as a manual delete) and clears the applied-bundle marker.
  /// Rows the user added by hand (preset_id IS NULL) are untouched.
  Future<void> removePresetBundle(String scheduleId, String presetId) async {
    final Database db = await database;
    final int now = DateTime.now().millisecondsSinceEpoch;
    await db.update(
      'domains',
      <String, Object?>{'deleted_at': now},
      where: 'schedule_id = ? AND preset_id = ? AND deleted_at IS NULL',
      whereArgs: <Object>[scheduleId, presetId],
    );
    await db.update(
      'keywords',
      <String, Object?>{'deleted_at': now},
      where: 'schedule_id = ? AND preset_id = ? AND deleted_at IS NULL',
      whereArgs: <Object>[scheduleId, presetId],
    );
    await db.delete(
      'schedule_applied_presets',
      where: 'schedule_id = ? AND preset_id = ?',
      whereArgs: <Object>[scheduleId, presetId],
    );
    _kickBackup();
  }

  Future<void> setDomainEnabled(String id, bool enabled) async {
    final Database db = await database;
    await db.update('domains', <String, Object?>{'enabled': enabled ? 1 : 0}, where: 'id = ?', whereArgs: <Object>[id]);
    // Same fix as setKeywordEnabled: without this, toggling a domain block
    // on/off doesn't push the new rule set to the snapshot/policy/PAC.
    _kickBackup();
  }

  Future<void> setDomainIncludeSubdomains(String id, bool value) async {
    final Database db = await database;
    await db.update('domains', <String, Object?>{'include_subdomains': value ? 1 : 0}, where: 'id = ?', whereArgs: <Object>[id]);
    _kickBackup();
  }

  /// Soft-delete: moves to Trash (auto-purged after 30 days).
  Future<void> deleteDomain(String id) async {
    final Database db = await database;
    await db.update(
      'domains',
      <String, Object?>{'deleted_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: <Object>[id],
    );
    _kickBackup();
  }

  Future<void> restoreDomain(String id) async {
    final Database db = await database;
    await db.update(
      'domains',
      <String, Object?>{'deleted_at': null},
      where: 'id = ?',
      whereArgs: <Object>[id],
    );
    _kickBackup();
  }

  Future<void> hardDeleteDomain(String id) async {
    final Database db = await database;
    await db.delete('domains', where: 'id = ?', whereArgs: <Object>[id]);
    _kickBackup();
  }

  /// Permanently purge items in the Trash older than 30 days.
  /// Call at app launch.
  Future<int> purgeOldTrash() async {
    final Database db = await database;
    final int cutoff = DateTime.now()
        .subtract(const Duration(days: 30))
        .millisecondsSinceEpoch;
    final int a = await db.delete('keywords',
        where: 'deleted_at IS NOT NULL AND deleted_at < ?',
        whereArgs: <Object>[cutoff]);
    final int b = await db.delete('domains',
        where: 'deleted_at IS NOT NULL AND deleted_at < ?',
        whereArgs: <Object>[cutoff]);
    if (a + b > 0) _kickBackup();
    return a + b;
  }

  // ─────────────────── usage tracking (v9) ───────────────────
  // High-frequency writes: never call [_kickBackup] here.

  static String usageSubjectForApp(String bundleId, String localizedName) {
    final String b = bundleId.trim();
    if (b.isNotEmpty) return 'app|$b';
    final String n = localizedName.trim().toLowerCase();
    return 'app_name|$n';
  }

  static String usageSubjectForWebHost(String host) {
    final String h = host.trim().toLowerCase();
    return 'web|$h';
  }

  /// Add [seconds] to the current period bucket (see [periodHours]) + calendar day.
  Future<void> addUsageSeconds(
    String subject,
    int seconds,
    DateTime nowLocal, {
    int periodHours = 1,
    bool background = false,
  }) async {
    if (seconds <= 0) return;
    final Database db = await database;
    final int periodStartMs =
        UsageBucketConfigService.periodStartMs(nowLocal, periodHours);
    final int dayMs = DateTime(nowLocal.year, nowLocal.month, nowLocal.day)
        .millisecondsSinceEpoch;
    await db.transaction((Transaction txn) async {
      await _usageBump(
        txn,
        'usage_hourly',
        subject,
        periodStartMs,
        seconds,
        background: background,
      );
      await _usageBump(
        txn,
        'usage_daily',
        subject,
        dayMs,
        seconds,
        background: background,
      );
    });
  }

  static Future<void> _usageBump(
    Transaction txn,
    String table,
    String subject,
    int bucketMs,
    int delta, {
    bool background = false,
  }) async {
    final String col = table == 'usage_hourly' ? 'hour_start_ms' : 'day_start_ms';
    final List<Map<String, Object?>> rows = await txn.query(
      table,
      where: 'subject = ? AND $col = ?',
      whereArgs: <Object>[subject, bucketMs],
      limit: 1,
    );
    if (rows.isEmpty) {
      await txn.insert(table, <String, Object?>{
        'subject': subject,
        col: bucketMs,
        'seconds': delta,
        'fg_seconds': background ? 0 : delta,
        'bg_seconds': background ? delta : 0,
      });
    } else {
      final int prev = (rows.first['seconds'] as int?) ?? 0;
      final int prevFg = (rows.first['fg_seconds'] as int?) ?? prev;
      final int prevBg = (rows.first['bg_seconds'] as int?) ?? 0;
      await txn.update(
        table,
        <String, Object?>{
          'seconds': prev + delta,
          'fg_seconds': background ? prevFg : prevFg + delta,
          'bg_seconds': background ? prevBg + delta : prevBg,
        },
        where: 'subject = ? AND $col = ?',
        whereArgs: <Object>[subject, bucketMs],
      );
    }
  }

  Future<int> usageDailyTotal(String subject, DateTime dayLocal) async {
    final Database db = await database;
    final int dayMs =
        DateTime(dayLocal.year, dayLocal.month, dayLocal.day).millisecondsSinceEpoch;
    final List<Map<String, Object?>> rows = await db.query(
      'usage_daily',
      columns: <String>['seconds'],
      where: 'subject = ? AND day_start_ms = ?',
      whereArgs: <Object>[subject, dayMs],
      limit: 1,
    );
    if (rows.isEmpty) return 0;
    return (rows.first['seconds'] as int?) ?? 0;
  }

  /// Foreground-only usage seconds for a subject on a given calendar day.
  Future<int> usageDailyFgTotal(String subject, DateTime dayLocal) async {
    final Database db = await database;
    final int dayMs =
        DateTime(dayLocal.year, dayLocal.month, dayLocal.day).millisecondsSinceEpoch;
    final List<Map<String, Object?>> rows = await db.query(
      'usage_daily',
      columns: <String>['fg_seconds'],
      where: 'subject = ? AND day_start_ms = ?',
      whereArgs: <Object>[subject, dayMs],
      limit: 1,
    );
    if (rows.isEmpty) return 0;
    return (rows.first['fg_seconds'] as int?) ?? 0;
  }

  /// Sum of all tracked subjects for the local calendar day (app + web).
  Future<int> usageDailyGrandTotal(DateTime dayLocal) async {
    final Database db = await database;
    final int dayMs =
        DateTime(dayLocal.year, dayLocal.month, dayLocal.day).millisecondsSinceEpoch;
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'SELECT COALESCE(SUM(seconds), 0) AS total FROM usage_daily '
      'WHERE day_start_ms = ?',
      <Object>[dayMs],
    );
    if (rows.isEmpty) return 0;
    return (rows.first['total'] as int?) ?? 0;
  }

  Future<List<Map<String, Object?>>> usageHourlyForSubjectOnDay(
    String subject,
    DateTime dayLocal,
  ) async {
    final Database db = await database;
    final int start =
        DateTime(dayLocal.year, dayLocal.month, dayLocal.day).millisecondsSinceEpoch;
    final int end = start + const Duration(days: 1).inMilliseconds;
    return db.query(
      'usage_hourly',
      where: 'subject = ? AND hour_start_ms >= ? AND hour_start_ms < ?',
      whereArgs: <Object>[subject, start, end],
      orderBy: 'hour_start_ms ASC',
    );
  }

  Future<List<Map<String, Object?>>> usageLimits() async {
    final Database db = await database;
    return db.query('usage_limits', orderBy: 'display_label ASC');
  }

  Future<List<Map<String, Object?>>> usageLimitsForSubject(String subject) async {
    final Database db = await database;
    return db.query(
      'usage_limits',
      where: 'subject = ?',
      whereArgs: <Object>[subject],
    );
  }

  /// Foreground seconds already used in the single hour bucket starting at
  /// [bucketStartMs] — used by [UsageQuotaMode.hourlyForegroundWindow] to
  /// check the current clock-hour only (never earlier hours).
  Future<int> usageHourlyFgSecondsAt(String subject, int bucketStartMs) async {
    final Database db = await database;
    final List<Map<String, Object?>> rows = await db.query(
      'usage_hourly',
      columns: <String>['fg_seconds'],
      where: 'subject = ? AND hour_start_ms = ?',
      whereArgs: <Object>[subject, bucketStartMs],
      limit: 1,
    );
    if (rows.isEmpty) return 0;
    return (rows.first['fg_seconds'] as int?) ?? 0;
  }

  Future<int> usageSecondsSince(String subject, int sinceMs) async {
    final Database db = await database;
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'SELECT COALESCE(SUM(seconds), 0) AS total FROM usage_hourly '
      'WHERE subject = ? AND hour_start_ms >= ?',
      <Object>[subject, sinceMs],
    );
    if (rows.isEmpty) return 0;
    return (rows.first['total'] as int?) ?? 0;
  }

  Future<void> ensureQuotaSessionPeriod({
    required String limitId,
    required int periodSeconds,
    required DateTime now,
  }) async {
    final Database db = await database;
    final int nowMs = now.millisecondsSinceEpoch;
    final List<Map<String, Object?>> rows = await db.query(
      'usage_quota_session',
      where: 'limit_id = ?',
      whereArgs: <Object>[limitId],
      limit: 1,
    );
    if (rows.isEmpty) {
      await db.insert('usage_quota_session', <String, Object?>{
        'limit_id': limitId,
        'period_start_ms': nowMs,
        'used_seconds': 0,
      });
      return;
    }
    final int start = (rows.first['period_start_ms'] as int?) ?? nowMs;
    if (nowMs - start >= periodSeconds * 1000) {
      await db.update(
        'usage_quota_session',
        <String, Object?>{
          'period_start_ms': nowMs,
          'used_seconds': 0,
        },
        where: 'limit_id = ?',
        whereArgs: <Object>[limitId],
      );
    }
  }

  Future<int> quotaSessionUsedSeconds(String limitId) async {
    final Database db = await database;
    final List<Map<String, Object?>> rows = await db.query(
      'usage_quota_session',
      where: 'limit_id = ?',
      whereArgs: <Object>[limitId],
      limit: 1,
    );
    if (rows.isEmpty) return 0;
    return (rows.first['used_seconds'] as int?) ?? 0;
  }

  Future<void> addQuotaSessionSeconds(String limitId, int seconds) async {
    if (seconds <= 0) return;
    final Database db = await database;
    final List<Map<String, Object?>> rows = await db.query(
      'usage_quota_session',
      where: 'limit_id = ?',
      whereArgs: <Object>[limitId],
      limit: 1,
    );
    if (rows.isEmpty) return;
    final int prev = (rows.first['used_seconds'] as int?) ?? 0;
    await db.update(
      'usage_quota_session',
      <String, Object?>{'used_seconds': prev + seconds},
      where: 'limit_id = ?',
      whereArgs: <Object>[limitId],
    );
  }

  Future<void> upsertUsageLimit({
    required String id,
    required String subject,
    required String displayLabel,
    required int maxSecondsPerDay,
    String quotaMode = 'daily',
    int windowSeconds = 10800,
    int sessionMaxSeconds = 0,
    int sessionPeriodSeconds = 1800,
    int windowStartHour = -1,
    int windowEndHour = -1,
    int maxSecondsPerHour = 900,
    bool enabled = true,
  }) async {
    final Database db = await database;
    await db.insert(
      'usage_limits',
      <String, Object?>{
        'id': id,
        'subject': subject,
        'display_label': displayLabel,
        'max_seconds_per_day': maxSecondsPerDay,
        'quota_mode': quotaMode,
        'window_seconds': windowSeconds,
        'session_max_seconds': sessionMaxSeconds,
        'session_period_seconds': sessionPeriodSeconds,
        'window_start_hour': windowStartHour,
        'window_end_hour': windowEndHour,
        'max_seconds_per_hour': maxSecondsPerHour,
        'enabled': enabled ? 1 : 0,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    await ensureQuotaSessionPeriod(
      limitId: id,
      periodSeconds: sessionPeriodSeconds,
      now: DateTime.now(),
    );
  }

  Future<void> deleteUsageLimit(String id) async {
    final Database db = await database;
    await db.delete('usage_limits', where: 'id = ?', whereArgs: <Object>[id]);
  }

  Future<void> insertSerpFilter({
    required String id,
    required String hostSuffix,
    required String pathPrefix,
    List<String> removeSelectors = const <String>[],
    bool enabled = false,
  }) async {
    final Database db = await database;
    await db.insert('serp_filters', <String, Object?>{
      'id': id,
      'host_suffix': hostSuffix,
      'path_prefix': pathPrefix,
      'remove_selectors_json': jsonEncode(removeSelectors),
      'enabled': enabled ? 1 : 0,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> setSerpFilterEnabled(String id, bool enabled) async {
    final Database db = await database;
    await db.update('serp_filters', <String, Object?>{'enabled': enabled ? 1 : 0}, where: 'id = ?', whereArgs: <Object>[id]);
  }

  Future<void> deleteSerpFilter(String id) async {
    final Database db = await database;
    await db.delete('serp_filters', where: 'id = ?', whereArgs: <Object>[id]);
  }

  Future<void> insertSearchQueryBlock({
    required String id,
    required String term,
    String match = 'contains',
    bool enabled = true,
    String scope = 'browser_extension',
    String? scheduleId,
  }) async {
    final Database db = await database;
    await db.insert('search_query_blocks', <String, Object?>{
      'id': id,
      'term': term,
      'match': match,
      'enabled': enabled ? 1 : 0,
      'scope': scope,
      'schedule_id': scheduleId,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    _kickBackup();
  }

  Future<List<Map<String, Object?>>> searchQueryBlocksForSchedule(
      String scheduleId) async {
    final Database db = await database;
    return db.query(
      'search_query_blocks',
      where: 'schedule_id = ?',
      whereArgs: <Object>[scheduleId],
      orderBy: 'created_at DESC',
    );
  }

  Future<void> deleteSearchQueryBlock(String id) async {
    final Database db = await database;
    await db.delete('search_query_blocks', where: 'id = ?', whereArgs: <Object>[id]);
    _kickBackup();
  }

  /// Active search-query blocks (schedule-aware), for extension `/rules`.
  Future<List<Map<String, Object?>>> searchQueryBlocksActiveNow(
      DateTime now) async {
    final Database db = await database;
    final List<Map<String, Object?>> all = await db.query(
      'search_query_blocks',
      where: 'enabled = 1',
      orderBy: 'created_at DESC',
    );
    final List<Map<String, Object?>> activeSchedules =
        await _activeSchedulesNow(db, now);
    final Set<String> activeIds = activeSchedules
        .map((Map<String, Object?> r) => r['id']! as String)
        .toSet();
    return all.where((Map<String, Object?> r) {
      final String? sid = r['schedule_id'] as String?;
      if (sid == null) return true;
      return activeIds.contains(sid);
    }).toList();
  }

  /// All enabled search-query blocks on enabled schedules.
  Future<List<Map<String, Object?>>> searchQueryBlocksAllEnabled() async {
    final Database db = await database;
    final List<Map<String, Object?>> all = await db.query(
      'search_query_blocks',
      where: 'enabled = 1',
      orderBy: 'created_at DESC',
    );
    return _filterRowsOnEnabledSchedules(db, all);
  }

  Future<void> setSearchBlockEnabled(String id, bool enabled) async {
    final Database db = await database;
    await db.update('search_query_blocks', <String, Object?>{'enabled': enabled ? 1 : 0}, where: 'id = ?', whereArgs: <Object>[id]);
    _kickBackup();
  }

  // ---------------------------------------------------------------------------
  // SCHEDULES (v3) — primary organising unit for "what to block right now".
  // ---------------------------------------------------------------------------

  Future<List<Map<String, Object?>>> schedules() async {
    final Database db = await database;
    return db.query('schedules', orderBy: 'created_at ASC');
  }

  Future<Map<String, Object?>?> scheduleById(String id) async {
    final Database db = await database;
    final List<Map<String, Object?>> rows =
        await db.query('schedules', where: 'id = ?', whereArgs: <Object>[id], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> upsertSchedule({
    required String id,
    required String name,
    required int startMinute,
    required int endMinute,
    required int daysMask,
    bool enabled = true,
  }) async {
    _kickBackup();
    final Database db = await database;
    final List<Map<String, Object?>> existing = await db.query(
      'schedules',
      where: 'id = ?',
      whereArgs: <Object>[id],
      limit: 1,
    );
    if (existing.isEmpty) {
      await db.insert('schedules', <String, Object?>{
        'id': id,
        'name': name,
        'enabled': enabled ? 1 : 0,
        'start_minute': startMinute,
        'end_minute': endMinute,
        'days_mask': daysMask,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
    } else {
      await db.update(
        'schedules',
        <String, Object?>{
          'name': name,
          'enabled': enabled ? 1 : 0,
          'start_minute': startMinute,
          'end_minute': endMinute,
          'days_mask': daysMask,
        },
        where: 'id = ?',
        whereArgs: <Object>[id],
      );
    }
  }

  Future<void> setScheduleEnabled(String id, bool enabled) async {
    final Database db = await database;
    await db.update(
      'schedules',
      <String, Object?>{'enabled': enabled ? 1 : 0},
      where: 'id = ?',
      whereArgs: <Object>[id],
    );
    _kickBackup();
  }

  // ──────────────────── per-schedule lock (v6 + v8) ────────────────────
  // The lock is owned by the schedule itself.
  //
  // Pre-commitment design (v8):
  //   * When the schedule is **created**, the user picks a cooldown
  //     duration (default 30 min). This is the mandatory wait future-self
  //     must endure before *any* modification.
  //   * The user can change the cooldown only while the schedule is
  //     **unlocked**. Once `locked = 1`, the cooldown is immutable —
  //     impulse-self cannot dial it down.
  //   * To modify a locked schedule the user taps "Start unlock". This sets
  //     `unlock_started_at = now`. There is **no duration choice** at this
  //     point — the cooldown was committed at creation time.
  //   * After the cooldown elapses, a fixed 5-minute edit window opens.
  //     After that, the schedule re-locks automatically.

  /// Fixed edit window granted after the user serves the cooldown. Mirrors
  /// the legacy global grace duration so muscle memory carries over.
  static const Duration kScheduleEditWindow = Duration(minutes: 5);

  /// Lowest cooldown a user can pick. Anything shorter defeats the purpose
  /// of pre-commitment.
  static const int kMinCooldownMinutes = 30;

  Future<void> setScheduleLocked(String id, bool locked) async {
    final Database db = await database;
    await db.update(
      'schedules',
      <String, Object?>{
        'locked': locked ? 1 : 0,
        if (locked)
          // Re-locking cancels any cooldown-in-progress / edit window.
          ...<String, Object?>{
            'unlock_started_at': 0,
            'unlock_until': 0,
          },
      },
      where: 'id = ?',
      whereArgs: <Object>[id],
    );
    _kickBackup();
  }

  /// Sets the *pre-committed* cooldown. Rejected when the schedule is
  /// currently locked — that's the whole point of the design.
  /// Returns `true` when the change was accepted.
  Future<bool> setScheduleCooldownMinutes(String id, int minutes) async {
    final Map<String, Object?>? row = await scheduleById(id);
    if (row == null) return false;
    final int locked = (row['locked'] as int?) ?? 0;
    final int started = (row['unlock_started_at'] as int?) ?? 0;
    final int now = DateTime.now().millisecondsSinceEpoch;
    final bool inCountdown = started > 0 &&
        now <
            started +
                ((row['lock_cooldown_minutes'] as int?) ?? 30) * 60 * 1000 +
                kScheduleEditWindow.inMilliseconds;
    if (locked == 1 || inCountdown) return false;

    final int safe = minutes < kMinCooldownMinutes ? kMinCooldownMinutes : minutes;
    final Database db = await database;
    await db.update(
      'schedules',
      <String, Object?>{'lock_cooldown_minutes': safe},
      where: 'id = ?',
      whereArgs: <Object>[id],
    );
    _kickBackup();
    return true;
  }

  /// Applies a bypass-attempt time lock penalty.
  ///
  /// This is used when the user tries to disable/edit while locked.
  /// It raises the schedule cooldown to at least [minutes], and if no countdown
  /// is running it starts one immediately from now.
  Future<void> applyBypassTimeLockPenalty(String id, int minutes) async {
    final int safeMinutes = minutes < kMinCooldownMinutes ? kMinCooldownMinutes : minutes;
    final Map<String, Object?>? row = await scheduleById(id);
    if (row == null) return;
    final int locked = (row['locked'] as int?) ?? 0;
    if (locked != 1) return;
    final int currentCooldown = (row['lock_cooldown_minutes'] as int?) ?? 30;
    final int started = (row['unlock_started_at'] as int?) ?? 0;
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int effectiveCooldown = currentCooldown > safeMinutes ? currentCooldown : safeMinutes;
    final int cooldownMs = effectiveCooldown * 60 * 1000;
    final int endOfEdit = now + cooldownMs + kScheduleEditWindow.inMilliseconds;
    final Database db = await database;
    await db.update(
      'schedules',
      <String, Object?>{
        'lock_cooldown_minutes': effectiveCooldown,
        if (started <= 0) ...<String, Object?>{
          'unlock_started_at': now,
          'unlock_until': endOfEdit,
        },
      },
      where: 'id = ?',
      whereArgs: <Object>[id],
    );
    _kickBackup();
  }

  /// Tap on "Start unlock". Stamps `unlock_started_at` and (for compat with
  /// older callers) sets `unlock_until` to the end of the edit window.
  /// No duration argument — the duration is the pre-committed cooldown.
  Future<void> startScheduleUnlockCountdown(String id) async {
    final Map<String, Object?>? row = await scheduleById(id);
    if (row == null) return;
    final int locked = (row['locked'] as int?) ?? 0;
    if (locked != 1) return; // already unlocked — nothing to do
    final int cooldownMs =
        ((row['lock_cooldown_minutes'] as int?) ?? 30) * 60 * 1000;
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int endOfEdit =
        now + cooldownMs + kScheduleEditWindow.inMilliseconds;
    final Database db = await database;
    await db.update(
      'schedules',
      <String, Object?>{
        'unlock_started_at': now,
        'unlock_until': endOfEdit,
      },
      where: 'id = ?',
      whereArgs: <Object>[id],
    );
    _kickBackup();
  }

  /// Cancels a running countdown / edit window. Cancelling does NOT bypass
  /// anything — it just re-locks early. Safe to call any time.
  Future<void> cancelScheduleUnlock(String id) async {
    final Database db = await database;
    await db.update(
      'schedules',
      <String, Object?>{'unlock_started_at': 0, 'unlock_until': 0},
      where: 'id = ?',
      whereArgs: <Object>[id],
    );
    _kickBackup();
  }

  /// Pure phase computation. Reads the schedule row and reports which phase
  /// of the lock state machine it's currently in, plus the absolute wall
  /// clock for the next transition.
  ///
  /// Returned record is `(phase, transitionAt)`.
  ///   * `phase` ∈ {unlocked, locked, countdown, editWindow}
  ///   * `transitionAt` is when the phase will change (null when no timer).
  Future<({ScheduleLockPhase phase, DateTime? transitionAt})>
      scheduleLockPhase(String id) async {
    final Map<String, Object?>? row = await scheduleById(id);
    if (row == null) {
      return (phase: ScheduleLockPhase.unlocked, transitionAt: null);
    }
    final int locked = (row['locked'] as int?) ?? 0;
    if (locked != 1) {
      return (phase: ScheduleLockPhase.unlocked, transitionAt: null);
    }
    final int started = (row['unlock_started_at'] as int?) ?? 0;
    if (started <= 0) {
      return (phase: ScheduleLockPhase.locked, transitionAt: null);
    }
    final int cooldownMs =
        ((row['lock_cooldown_minutes'] as int?) ?? 30) * 60 * 1000;
    final int now = DateTime.now().millisecondsSinceEpoch;
    final int endOfCooldown = started + cooldownMs;
    final int endOfEdit = endOfCooldown + kScheduleEditWindow.inMilliseconds;
    if (now < endOfCooldown) {
      return (
        phase: ScheduleLockPhase.countdown,
        transitionAt: DateTime.fromMillisecondsSinceEpoch(endOfCooldown),
      );
    }
    if (now < endOfEdit) {
      return (
        phase: ScheduleLockPhase.editWindow,
        transitionAt: DateTime.fromMillisecondsSinceEpoch(endOfEdit),
      );
    }
    // Window expired — caller should also persist this transition.
    return (phase: ScheduleLockPhase.locked, transitionAt: null);
  }

  /// True when modifications must be refused. Convenience wrapper around
  /// [scheduleLockPhase]. Counts both `locked` (no countdown) and
  /// `countdown` (waiting for cooldown) as effectively locked.
  Future<bool> isScheduleEffectivelyLocked(String id) async {
    final ({ScheduleLockPhase phase, DateTime? transitionAt}) p =
        await scheduleLockPhase(id);
    return p.phase == ScheduleLockPhase.locked ||
        p.phase == ScheduleLockPhase.countdown;
  }

  Future<void> deleteSchedule(String id) async {
    final Database db = await database;
    await db.update(
      'keywords',
      <String, Object?>{'schedule_id': null},
      where: 'schedule_id = ?',
      whereArgs: <Object>[id],
    );
    await db.update(
      'domains',
      <String, Object?>{'schedule_id': null},
      where: 'schedule_id = ?',
      whereArgs: <Object>[id],
    );
    await db.delete('schedule_slots',
        where: 'schedule_id = ?', whereArgs: <Object>[id]);
    await db.delete('schedules', where: 'id = ?', whereArgs: <Object>[id]);
    _kickBackup();
  }

  Future<void> setKeywordSchedule(String keywordId, String? scheduleId) async {
    final Database db = await database;
    await db.update(
      'keywords',
      <String, Object?>{'schedule_id': scheduleId},
      where: 'id = ?',
      whereArgs: <Object>[keywordId],
    );
  }

  Future<void> setDomainSchedule(String domainId, String? scheduleId) async {
    final Database db = await database;
    await db.update(
      'domains',
      <String, Object?>{'schedule_id': scheduleId},
      where: 'id = ?',
      whereArgs: <Object>[domainId],
    );
  }

  Future<List<Map<String, Object?>>> keywordsForSchedule(String? scheduleId) async {
    final Database db = await database;
    if (scheduleId == null) {
      return db.query('keywords',
          where: 'schedule_id IS NULL AND deleted_at IS NULL',
          orderBy: 'created_at DESC');
    }
    return db.query('keywords',
        where: 'schedule_id = ? AND deleted_at IS NULL',
        whereArgs: <Object>[scheduleId],
        orderBy: 'created_at DESC');
  }

  Future<List<Map<String, Object?>>> domainsForSchedule(String? scheduleId) async {
    final Database db = await database;
    if (scheduleId == null) {
      return db.query('domains',
          where: 'schedule_id IS NULL AND deleted_at IS NULL',
          orderBy: 'created_at DESC');
    }
    return db.query('domains',
        where: 'schedule_id = ? AND deleted_at IS NULL',
        whereArgs: <Object>[scheduleId],
        orderBy: 'created_at DESC');
  }

  /// Returns the set of `domains` rows that should be active **right now**,
  /// taking schedules into account:
  ///   - rules with `schedule_id IS NULL` are always-on
  ///   - rules with a schedule_id are included only if that schedule is enabled
  ///     AND the current local time falls within its window AND the day matches.
  Future<List<Map<String, Object?>>> domainsActiveNow(DateTime now) async {
    final Database db = await database;
    final List<Map<String, Object?>> all = await db.query('domains',
        where: 'enabled = 1 AND deleted_at IS NULL',
        orderBy: 'created_at DESC');
    final List<Map<String, Object?>> activeSchedules =
        await _activeSchedulesNow(db, now);
    final Set<String> activeIds =
        activeSchedules.map((Map<String, Object?> r) => r['id']! as String).toSet();
    return all.where((Map<String, Object?> r) {
      final String? sid = r['schedule_id'] as String?;
      if (sid == null) return true;
      return activeIds.contains(sid);
    }).toList();
  }

  /// Same schedule window logic as [domainsActiveNow], for keyword / URL rules.
  Future<List<Map<String, Object?>>> keywordsActiveNow(DateTime now) async {
    final Database db = await database;
    final List<Map<String, Object?>> all = await db.query('keywords',
        where: 'enabled = 1 AND deleted_at IS NULL',
        orderBy: 'created_at DESC');
    final List<Map<String, Object?>> activeSchedules =
        await _activeSchedulesNow(db, now);
    final Set<String> activeIds =
        activeSchedules.map((Map<String, Object?> r) => r['id']! as String).toSet();
    return all.where((Map<String, Object?> r) {
      final String? sid = r['schedule_id'] as String?;
      if (sid == null) return true;
      return activeIds.contains(sid);
    }).toList();
  }

  /// All enabled keywords on enabled schedules (ignores time-of-day windows).
  Future<List<Map<String, Object?>>> keywordsAllEnabled() async {
    final Database db = await database;
    final List<Map<String, Object?>> all = await db.query(
      'keywords',
      where: 'enabled = 1 AND deleted_at IS NULL',
      orderBy: 'created_at DESC',
    );
    return _filterRowsOnEnabledSchedules(db, all);
  }

  /// All enabled domain blocks on enabled schedules (ignores time-of-day windows).
  Future<List<Map<String, Object?>>> domainsAllEnabled() async {
    final Database db = await database;
    final List<Map<String, Object?>> all = await db.query(
      'domains',
      where: 'enabled = 1 AND deleted_at IS NULL',
      orderBy: 'created_at DESC',
    );
    return _filterRowsOnEnabledSchedules(db, all);
  }

  Future<List<Map<String, Object?>>> _filterRowsOnEnabledSchedules(
    DatabaseExecutor db,
    List<Map<String, Object?>> rows,
  ) async {
    final List<Map<String, Object?>> sched = await db.query(
      'schedules',
      where: 'enabled = 1',
    );
    final Set<String> enabledIds =
        sched.map((Map<String, Object?> r) => r['id']! as String).toSet();
    return rows.where((Map<String, Object?> r) {
      final String? sid = r['schedule_id'] as String?;
      if (sid == null) return true;
      return enabledIds.contains(sid);
    }).toList();
  }

  // ─────────────────── blocked applications (v7) ───────────────────

  Future<List<Map<String, Object?>>> appsForSchedule(String scheduleId) async {
    final Database db = await database;
    return db.query(
      'blocked_apps',
      where: 'schedule_id = ? AND deleted_at IS NULL',
      whereArgs: <Object>[scheduleId],
      orderBy: 'created_at DESC',
    );
  }

  /// Insert a new blocked-app row. Pass [bundleId] when known (e.g. preset
  /// picks from the popular catalog) so iOS / Android targets can also use
  /// it later, but on macOS we match by [name] (lowercased).
  Future<void> insertBlockedApp({
    required String id,
    required String name,
    required String scheduleId,
    String? bundleId,
  }) async {
    final Database db = await database;
    await db.insert('blocked_apps', <String, Object?>{
      'id': id,
      'schedule_id': scheduleId,
      'name': name.trim(),
      'bundle_id': bundleId,
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'deleted_at': null,
    });
    _kickBackup();
  }

  /// Soft-delete an app row (30-day trash policy). Use [hardDeleteBlockedApp]
  /// for the immediate purge needed when an undo stack rewinds an add.
  Future<void> deleteBlockedApp(String id) async {
    final Database db = await database;
    await db.update(
      'blocked_apps',
      <String, Object?>{'deleted_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: <Object>[id],
    );
    _kickBackup();
  }

  Future<void> hardDeleteBlockedApp(String id) async {
    final Database db = await database;
    await db.delete('blocked_apps', where: 'id = ?', whereArgs: <Object>[id]);
    _kickBackup();
  }

  /// Names of apps that should be terminated **right now** — union of every
  /// active schedule's blocked-apps list. Returned as the user-typed display
  /// names; native side normalises (lowercase, trim) before matching.
  Future<List<String>> blockedAppsActiveNow(DateTime now) async {
    final Database db = await database;
    final List<Map<String, Object?>> activeSchedules =
        await _activeSchedulesNow(db, now);
    if (activeSchedules.isEmpty) return <String>[];
    final List<String> ids = activeSchedules
        .map((Map<String, Object?> r) => r['id']! as String)
        .toList();
    final String placeholders = List<String>.filled(ids.length, '?').join(',');
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'SELECT name FROM blocked_apps '
      'WHERE deleted_at IS NULL AND schedule_id IN ($placeholders)',
      ids,
    );
    return rows
        .map((Map<String, Object?> r) => (r['name']! as String).trim())
        .where((String s) => s.isNotEmpty)
        .toSet()
        .toList();
  }

  /// Windows [WindowsAppBlockService]: full [BlockApp] rows (name + optional
  /// `win|exe|chromeAppId` in [bundle_id]) for active schedules.
  Future<List<BlockApp>> blockedWindowsAppsActiveNow(DateTime now) async {
    final Database db = await database;
    final List<Map<String, Object?>> activeSchedules =
        await _activeSchedulesNow(db, now);
    if (activeSchedules.isEmpty) return <BlockApp>[];
    final List<String> ids = activeSchedules
        .map((Map<String, Object?> r) => r['id']! as String)
        .toList();
    final String placeholders = List<String>.filled(ids.length, '?').join(',');
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'SELECT name, bundle_id FROM blocked_apps '
      'WHERE deleted_at IS NULL AND schedule_id IN ($placeholders)',
      ids,
    );
    final List<BlockApp> out = <BlockApp>[];
    for (final Map<String, Object?> r in rows) {
      final BlockApp? b = blockedAppRowToBlockApp(r);
      if (b != null) out.add(b);
    }
    final Map<String, BlockApp> dedup = <String, BlockApp>{};
    for (final BlockApp b in out) {
      final String k;
      if (b.exeName.isEmpty) {
        k = 'lt:${(b.windowTitleMatch ?? b.displayName).toLowerCase()}';
      } else if (b.isPwa) {
        k = '${b.exeName}?${b.chromeAppId}';
      } else {
        k = b.exeName;
      }
      dedup.putIfAbsent(k, () => b);
    }
    return dedup.values.toList();
  }

  static BlockApp? blockedAppRowToBlockApp(Map<String, Object?> r) {
    final String name = (r['name'] as String?)?.trim() ?? '';
    if (name.isEmpty) return null;
    final String? bundle = r['bundle_id'] as String?;
    if (bundle != null && bundle.startsWith('win|')) {
      final List<String> parts = bundle.split('|');
      if (parts.length < 3) {
        return BlockApp(
          exeName: '',
          displayName: name,
          windowTitleMatch: name,
        );
      }
      final String exe = BlockApp.normalizeExeName(parts[1]);
      if (exe.isEmpty) {
        return BlockApp(
          exeName: '',
          displayName: name,
          windowTitleMatch: name,
        );
      }
      final String cidRaw = parts.sublist(2).join('|');
      String? chromeId;
      if (BlockApp.browserExes.contains(exe)) {
        chromeId =
            cidRaw.isEmpty ? BlockApp.mainBrowserKey : cidRaw;
      }
      return BlockApp(
        exeName: exe,
        displayName: name,
        chromeAppId: chromeId,
      );
    }
    return BlockApp(
      exeName: '',
      displayName: name,
      windowTitleMatch: name,
    );
  }

  /// Schedules that are enabled and whose slot/window includes [now] (local).
  Future<List<Map<String, Object?>>> schedulesActiveNow(DateTime now) async {
    final Database db = await database;
    return _activeSchedulesNow(db, now);
  }

  Future<List<Map<String, Object?>>> _activeSchedulesNow(
      DatabaseExecutor db, DateTime now) async {
    final List<Map<String, Object?>> rows = await db.query('schedules',
        where: 'enabled = 1', orderBy: 'created_at ASC');
    final int minuteOfDay = now.hour * 60 + now.minute;
    final int today = now.weekday - 1; // Mon=1 → 0
    final int dayBit = 1 << today;
    final int yesterday = (today + 6) % 7;
    final List<Map<String, Object?>> allSlots = await db.query('schedule_slots');
    final Map<String, List<Map<String, Object?>>> slotsBySchedule =
        <String, List<Map<String, Object?>>>{};
    for (final Map<String, Object?> slot in allSlots) {
      slotsBySchedule
          .putIfAbsent(slot['schedule_id']! as String,
              () => <Map<String, Object?>>[])
          .add(slot);
    }
    final List<Map<String, Object?>> out = <Map<String, Object?>>[];
    for (final Map<String, Object?> r in rows) {
      final String id = r['id']! as String;
      final List<Map<String, Object?>> slots =
          slotsBySchedule[id] ?? const <Map<String, Object?>>[];
      if (slots.isNotEmpty) {
        final bool hit = slots.any((Map<String, Object?> s) {
          final int st = s['start_minute']! as int;
          final int en = s['end_minute']! as int;
          final int day = s['day']! as int;
          if (st > en) {
            return (day == today && minuteOfDay >= st) ||
                (day == yesterday && minuteOfDay < en);
          }
          if (day != today) return false;
          if (st == 0 && en >= 1440) return true;
          return minuteOfDay >= st && minuteOfDay < en;
        });
        if (hit) out.add(r);
        continue;
      }
      // Legacy fallback for schedules that haven't been migrated to slots.
      final int start = r['start_minute']! as int;
      final int end = r['end_minute']! as int;
      final int mask = r['days_mask']! as int;
      if (start == end) {
        if ((mask & dayBit) != 0) out.add(r);
      } else if (start < end) {
        if ((mask & dayBit) != 0 && minuteOfDay >= start && minuteOfDay < end) {
          out.add(r);
        }
      } else {
        if (((mask & dayBit) != 0 && minuteOfDay >= start) ||
            ((mask & (1 << yesterday)) != 0 && minuteOfDay < end)) {
          out.add(r);
        }
      }
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // SCHEDULE SLOTS (v5) — many-per-schedule time windows, one per day-of-week.
  // ---------------------------------------------------------------------------

  Future<List<Map<String, Object?>>> slotsForSchedule(String scheduleId) async {
    final Database db = await database;
    return db.query('schedule_slots',
        where: 'schedule_id = ?',
        whereArgs: <Object>[scheduleId],
        orderBy: 'day ASC, start_minute ASC');
  }

  Future<void> insertSlot({
    required String id,
    required String scheduleId,
    required int day,
    required int startMinute,
    required int endMinute,
  }) async {
    final Database db = await database;
    await db.insert('schedule_slots', <String, Object?>{
      'id': id,
      'schedule_id': scheduleId,
      'day': day,
      'start_minute': startMinute,
      'end_minute': endMinute,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    _kickBackup();
  }

  Future<void> deleteSlot(String id) async {
    final Database db = await database;
    await db.delete('schedule_slots', where: 'id = ?', whereArgs: <Object>[id]);
    _kickBackup();
  }

  Future<void> deleteSlotsForSchedule(String scheduleId) async {
    final Database db = await database;
    await db.delete('schedule_slots',
        where: 'schedule_id = ?', whereArgs: <Object>[scheduleId]);
    _kickBackup();
  }

  Future<RulesBundle> buildRulesBundle() async {
    final Database db = await database;
    final RulesMeta meta = await rulesMeta();

    final List<Map<String, Object?>> kwRows = await db.query('keywords', orderBy: 'created_at ASC');
    final List<KeywordRule> keywords = kwRows.map((Map<String, Object?> row) {
      return KeywordRule(
        id: row['id']! as String,
        pattern: row['pattern']! as String,
        match: row['match_type']! as String,
        caseSensitive: (row['case_sensitive'] as int? ?? 0) == 1,
        action: row['action']! as String,
        enabled: (row['enabled'] as int) == 1,
      );
    }).toList();

    final List<Map<String, Object?>> dRows = await db.query('domains', orderBy: 'created_at ASC');
    final List<DomainRule> domains = dRows.map((Map<String, Object?> row) {
      return DomainRule(
        id: row['id']! as String,
        host: row['host']! as String,
        includeSubdomains: (row['include_subdomains'] as int) == 1,
        action: row['action'] as String? ?? 'block_document',
        enabled: (row['enabled'] as int) == 1,
        source: row['source']! as String,
      );
    }).toList();

    final List<Map<String, Object?>> sfRows = await db.query('serp_filters', orderBy: 'created_at ASC');
    final List<SerpFilter> serpFilters = sfRows.map((Map<String, Object?> row) {
      List<String> sels = <String>[];
      try {
        final Object? raw = row['remove_selectors_json'];
        final Object? decoded = jsonDecode(raw as String? ?? '[]');
        if (decoded is List<dynamic>) {
          sels = decoded.map((dynamic e) => '$e').toList();
        }
      } catch (_) {}
      return SerpFilter(
        id: row['id']! as String,
        hostSuffix: row['host_suffix']! as String,
        pathPrefix: row['path_prefix']! as String,
        removeSelectors: sels,
        enabled: (row['enabled'] as int) == 1,
      );
    }).toList();

    final List<Map<String, Object?>> sqRows = await db.query('search_query_blocks', orderBy: 'created_at ASC');
    final List<SearchQueryBlock> searchQueryBlocklist = sqRows.map((Map<String, Object?> row) {
      return SearchQueryBlock(
        id: row['id']! as String,
        term: row['term']! as String,
        match: row['match']! as String,
        enabled: (row['enabled'] as int) == 1,
        scope: row['scope']! as String,
      );
    }).toList();

    return RulesBundle(
      schemaVersion: 1,
      updatedAt: DateTime.now().toUtc(),
      strictness: meta.strictness,
      keywordRules: keywords,
      domainRules: domains,
      serpFilters: serpFilters,
      searchQueryBlocklist: searchQueryBlocklist,
      focusEnabled: meta.focusEnabled,
      unlockPinRequired: meta.unlockPinRequired,
      unlockCooldownSeconds: meta.unlockCooldownSeconds,
    );
  }

  // ─────────────────────────── RESTORE ───────────────────────────
  //
  // Used by BackupService to rehydrate the DB from a snapshot JSON.
  // Strategy: wipe the user tables in one transaction, then bulk-insert
  // every row from the snapshot. Schema columns that don't exist in the
  // older snapshot are filled with sensible defaults (e.g. v8 lock fields).

  /// Wipe + reinsert. Returns the row counts actually applied. Does NOT
  /// call `_kickBackup` (the caller must mark sync-safe before any writes).
  Future<RestoreCounts> restoreFromBackupMap(Map<String, Object?> data) async {
    final Database db = await database;

    final List<Map<String, Object?>> schedules =
        _asListOfMaps(data['schedules']);
    final List<Map<String, Object?>> slots =
        _asListOfMaps(data['scheduleSlots']);
    final List<Map<String, Object?>> keywords =
        _asListOfMaps(data['keywords']);
    final List<Map<String, Object?>> domains =
        _asListOfMaps(data['domains']);
    final List<Map<String, Object?>> apps =
        _asListOfMaps(data['blockedApps']);
    final List<Map<String, Object?>> serps =
        _asListOfMaps(data['serpFilters']);
    final List<Map<String, Object?>> sqBlocks =
        _asListOfMaps(data['searchQueryBlocks']);

    await db.transaction((Transaction tx) async {
      // Order matters because of FK ordering: children first.
      await tx.delete('schedule_slots');
      await tx.delete('blocked_apps');
      await tx.delete('keywords');
      await tx.delete('domains');
      await tx.delete('search_query_blocks');
      await tx.delete('serp_filters');
      await tx.delete('schedules');

      for (final Map<String, Object?> row in schedules) {
        await tx.insert('schedules', _coerceScheduleRow(row),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final Map<String, Object?> row in slots) {
        await tx.insert('schedule_slots', _coerceScheduleSlotRow(row),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final Map<String, Object?> row in keywords) {
        await tx.insert('keywords', _coerceKeywordRow(row),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final Map<String, Object?> row in domains) {
        await tx.insert('domains', _coerceDomainRow(row),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final Map<String, Object?> row in apps) {
        await tx.insert('blocked_apps', _coerceBlockedAppRow(row),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final Map<String, Object?> row in serps) {
        await tx.insert('serp_filters', _coerceSerpFilterRow(row),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      for (final Map<String, Object?> row in sqBlocks) {
        await tx.insert('search_query_blocks', _coerceSearchQueryBlockRow(row),
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    });

    // Restore rules_meta separately (it's a key/value blob).
    final Object? metaRaw = data['rulesMeta'];
    if (metaRaw is Map) {
      try {
        await db.insert(
          'settings_kv',
          <String, Object?>{
            'key': _kRulesMetaKey,
            'value_json': const JsonEncoder().convert(metaRaw),
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      } catch (_) {/* swallow — defaults will be reseeded by _ensureRulesMeta */}
    } else if (metaRaw is String) {
      await db.insert(
        'settings_kv',
        <String, Object?>{
          'key': _kRulesMetaKey,
          'value_json': metaRaw,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );
    }

    return RestoreCounts(
      schedules: schedules.length,
      scheduleSlots: slots.length,
      keywords: keywords.length,
      domains: domains.length,
      blockedApps: apps.length,
      serpFilters: serps.length,
      searchQueryBlocks: sqBlocks.length,
    );
  }

  /// Append-only audit for [DiagnosticAgentService] mutating actions.
  Future<void> insertDiagnosticAgentLog({
    required String id,
    required String actionKind,
    required String status,
    required String reason,
    Map<String, Object?> detail = const <String, Object?>{},
  }) async {
    final Database db = await database;
    await db.insert(
      'diagnostic_agent_log',
      <String, Object?>{
        'id': id,
        'created_at_ms': DateTime.now().millisecondsSinceEpoch,
        'action_kind': actionKind,
        'status': status,
        'reason': reason,
        'detail_json': jsonEncode(detail),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<List<DiagnosticAgentLogRow>> diagnosticAgentLogs({int limit = 80}) async {
    final Database db = await database;
    final List<Map<String, Object?>> rows = await db.query(
      'diagnostic_agent_log',
      orderBy: 'created_at_ms DESC',
      limit: limit,
    );
    return rows.map(DiagnosticAgentLogRow.fromMap).toList(growable: false);
  }

  static List<Map<String, Object?>> _asListOfMaps(Object? v) {
    if (v is! List) return const <Map<String, Object?>>[];
    return v
        .whereType<Map<Object?, Object?>>()
        .map<Map<String, Object?>>((Map<Object?, Object?> e) =>
            e.map((Object? k, Object? v) =>
                MapEntry<String, Object?>(k.toString(), v)))
        .toList();
  }

  static int _asInt(Object? v, [int fallback = 0]) {
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? fallback;
    if (v is bool) return v ? 1 : 0;
    return fallback;
  }

  /// Strip a row down to the columns the current schema knows about,
  /// substituting defaults for any v8-and-later columns the older snapshot
  /// might be missing.
  static Map<String, Object?> _coerceScheduleRow(Map<String, Object?> r) {
    return <String, Object?>{
      'id': r['id'],
      'name': r['name'] ?? '복원된 스케줄',
      'start_minute': _asInt(r['start_minute']),
      'end_minute': _asInt(r['end_minute'], 1440),
      'days_mask': _asInt(r['days_mask']),
      'enabled': _asInt(r['enabled'], 1),
      'created_at': _asInt(r['created_at'], DateTime.now().millisecondsSinceEpoch),
      'locked': _asInt(r['locked']),
      'unlock_until': _asInt(r['unlock_until']),
      'lock_cooldown_minutes': _asInt(r['lock_cooldown_minutes'], 30),
      'unlock_started_at': _asInt(r['unlock_started_at']),
    };
  }

  static Map<String, Object?> _coerceScheduleSlotRow(Map<String, Object?> r) {
    return <String, Object?>{
      'id': r['id'],
      'schedule_id': r['schedule_id'],
      'day': _asInt(r['day']),
      'start_minute': _asInt(r['start_minute']),
      'end_minute': _asInt(r['end_minute']),
      'created_at':
          _asInt(r['created_at'], DateTime.now().millisecondsSinceEpoch),
    };
  }

  static Map<String, Object?> _coerceKeywordRow(Map<String, Object?> r) {
    return <String, Object?>{
      'id': r['id'],
      'pattern': r['pattern'],
      'match_type': r['match_type'] ?? 'contains',
      'action': r['action'] ?? 'redact',
      'case_sensitive': _asInt(r['case_sensitive']),
      'enabled': _asInt(r['enabled'], 1),
      'schedule_id': r['schedule_id'],
      'created_at':
          _asInt(r['created_at'], DateTime.now().millisecondsSinceEpoch),
      'deleted_at': r['deleted_at'] == null ? null : _asInt(r['deleted_at']),
    };
  }

  static Map<String, Object?> _coerceDomainRow(Map<String, Object?> r) {
    return <String, Object?>{
      'id': r['id'],
      'host': r['host'],
      'include_subdomains': _asInt(r['include_subdomains'], 1),
      'source': r['source'] ?? 'user',
      'enabled': _asInt(r['enabled'], 1),
      'action': r['action'] ?? 'block_document',
      'schedule_id': r['schedule_id'],
      'is_stem': _asInt(r['is_stem']),
      'created_at':
          _asInt(r['created_at'], DateTime.now().millisecondsSinceEpoch),
      'deleted_at': r['deleted_at'] == null ? null : _asInt(r['deleted_at']),
    };
  }

  static Map<String, Object?> _coerceBlockedAppRow(Map<String, Object?> r) {
    return <String, Object?>{
      'id': r['id'],
      'schedule_id': r['schedule_id'],
      'name': r['name'],
      'bundle_id': r['bundle_id'],
      'created_at':
          _asInt(r['created_at'], DateTime.now().millisecondsSinceEpoch),
      'deleted_at': r['deleted_at'] == null ? null : _asInt(r['deleted_at']),
    };
  }

  static Map<String, Object?> _coerceSerpFilterRow(Map<String, Object?> r) {
    return <String, Object?>{
      'id': r['id'],
      'host_suffix': r['host_suffix'] ?? '',
      'path_prefix': r['path_prefix'] ?? '/',
      'remove_selectors_json': r['remove_selectors_json'] ?? '[]',
      'enabled': _asInt(r['enabled']),
      'created_at':
          _asInt(r['created_at'], DateTime.now().millisecondsSinceEpoch),
    };
  }

  static Map<String, Object?> _coerceSearchQueryBlockRow(
      Map<String, Object?> r) {
    return <String, Object?>{
      'id': r['id'],
      'term': r['term'],
      'match': r['match'] ?? 'contains',
      'enabled': _asInt(r['enabled'], 1),
      'scope': r['scope'] ?? 'browser_extension',
      'schedule_id': r['schedule_id'],
      'created_at':
          _asInt(r['created_at'], DateTime.now().millisecondsSinceEpoch),
    };
  }
}

/// Row counts applied during a [LocalDatabase.restoreFromBackupMap] call.
class RestoreCounts {
  const RestoreCounts({
    required this.schedules,
    required this.scheduleSlots,
    required this.keywords,
    required this.domains,
    required this.blockedApps,
    required this.serpFilters,
    required this.searchQueryBlocks,
  });
  final int schedules;
  final int scheduleSlots;
  final int keywords;
  final int domains;
  final int blockedApps;
  final int serpFilters;
  final int searchQueryBlocks;
}
