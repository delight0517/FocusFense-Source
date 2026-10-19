import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_logger.dart';
import 'windows_hidden_process.dart';

/// What kind of Windows footprint an entry is.
enum BgComponentKind { scheduledTask, runKey }

/// How we classify a discovered footprint item.
///
///  * [essential]  — a known, required part of Focus Fense. Show as 정상.
///  * [optional]   — known and legitimate but not load-bearing.
///  * [orphan]     — left over by an OLD build; safe to remove. Some flash a
///                   console window, which is exactly what looks like a virus.
///  * [unknown]    — a SixVPN-looking entry we don't have a catalog row for.
enum BgComponentClass { essential, optional, orphan, unknown }

/// One row in the "백그라운드 항목 안내" screen — a scheduled task or a
/// Run-key autostart that belongs (or appears to belong) to this app.
final class BgComponent {
  const BgComponent({
    required this.id,
    required this.kind,
    required this.title,
    required this.purpose,
    required this.classification,
    required this.present,
    this.disabled = false,
    this.showsWindow = false,
    this.exec = '',
  });

  /// Task name (e.g. `SixVPNBlockerWatchdog`) or Run-key value name.
  final String id;
  final BgComponentKind kind;

  /// Friendly Korean name shown to the user.
  final String title;

  /// One-paragraph "what this does / why it's here" explanation.
  final String purpose;

  final BgComponentClass classification;

  /// Whether the entry is actually registered on this machine right now.
  final bool present;
  final bool disabled;

  /// True only for orphans that pop a visible PowerShell/CMD window — the
  /// reason the user worried about a virus.
  final bool showsWindow;

  /// The executable the entry launches (for the "고급" detail line).
  final String exec;

  bool get isRemovable => classification == BgComponentClass.orphan && present;
}

/// Result of one cleanup pass.
final class BgCleanupResult {
  const BgCleanupResult({
    required this.removed,
    required this.needsAdmin,
    required this.failed,
  });
  final List<String> removed;
  final List<String> needsAdmin;
  final List<String> failed;

  bool get allClear => needsAdmin.isEmpty && failed.isEmpty;
}

/// Scans the *actual* Windows scheduled tasks + Run-key autostart, matches them
/// against a catalog of known Focus Fense components, and lets the UI explain
/// each one ("this is us, here's why") instead of leaving the user to wonder if
/// a random PowerShell window is malware.
final class WindowsBackgroundComponentsService {
  WindowsBackgroundComponentsService._();
  static final WindowsBackgroundComponentsService instance =
      WindowsBackgroundComponentsService._();

  String _schtasksExe() {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return p.join(windir, 'System32', 'schtasks.exe');
  }

  String _regExe() {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return p.join(windir, 'System32', 'reg.exe');
  }

  /// Catalog of KNOWN scheduled tasks. Anything matching `SixVPN`/`6VPN` that
  /// is NOT in here is surfaced as [BgComponentClass.unknown] so we never hide
  /// something from the user.
  static const Map<String, ({String title, String purpose, BgComponentClass cls, bool showsWindow})>
      _taskCatalog = <String, ({String title, String purpose, BgComponentClass cls, bool showsWindow})>{
    'SixVPNBlockerAutostart': (
      title: '앱 자동 시작',
      purpose: '로그인하면 Focus Fense를 자동으로 켜서 차단이 끊기지 않게 합니다. '
          '창은 뜨지 않고 백그라운드로만 실행됩니다.',
      cls: BgComponentClass.essential,
      showsWindow: false,
    ),
    'SixVPNBlockerBootGuard': (
      title: '부팅 직후 차단 재적용',
      purpose: '컴퓨터를 켠 직후 차단 정책(hosts·DNS)을 다시 적용해, 재부팅으로 '
          '차단이 풀리는 것을 막습니다. 숨김으로 실행돼 화면에 나타나지 않습니다.',
      cls: BgComponentClass.essential,
      showsWindow: false,
    ),
    'SixVPNBlockerWatchdog': (
      title: '앱 보호 감시자',
      purpose: '앱이 강제 종료되면 다시 켜는 감시 프로세스입니다. wscript로 숨겨서 '
          '실행되며 PowerShell 창은 보이지 않습니다.',
      cls: BgComponentClass.essential,
      showsWindow: false,
    ),
    'SixVPNBrowserGuard': (
      title: '브라우저 우회 차단 유지',
      purpose: '브라우저 정책·확장이 꺼지거나 우회되면 자동으로 복구합니다. '
          '숨김 실행이라 작업을 방해하지 않습니다.',
      cls: BgComponentClass.essential,
      showsWindow: false,
    ),
    'SixVPNBlockerOfflineGuard': (
      title: '오프라인 차단 유지',
      purpose: '인터넷이 끊긴 상태에서도 차단 정책이 유지되도록 점검합니다. '
          '숨김 실행입니다.',
      cls: BgComponentClass.optional,
      showsWindow: false,
    ),
    'SixVPNBlockerElevatedMaintain': (
      title: '관리자 유지 작업',
      purpose: '관리자 권한을 한 번 승인하면, 이후에는 UAC 창 없이 hosts·DNS 차단을 '
          '30분마다 조용히 점검합니다. 숨김 실행입니다.',
      cls: BgComponentClass.essential,
      showsWindow: false,
    ),
  };

  /// Orphan tasks left by older builds. Safe to remove. The flagged ones pop a
  /// visible window — the actual source of the "왜 자꾸 PowerShell이 떠?" worry.
  static const Map<String, ({String title, String purpose, bool showsWindow})>
      _orphanCatalog = <String, ({String title, String purpose, bool showsWindow})>{
    'SixVPNAdminExec': (
      title: '구버전 관리자 실행 통로 (불필요)',
      purpose: '예전 버전이 관리자 명령을 실행하려고 만든 작업입니다. 현재 버전은 '
          '쓰지 않으며, 이 작업은 PowerShell 창을 숨기지 않고 띄워 화면에 깜빡입니다. '
          '제거해도 차단 기능에 영향이 없습니다.',
      showsWindow: true,
    ),
    'SixVPNBlockerWatchdog2': (
      title: '중복 감시자 (불필요)',
      purpose: '감시자 작업이 실수로 두 번 등록된 것입니다. 하나면 충분하므로 '
          '제거 대상입니다.',
      showsWindow: false,
    ),
    'SixVPNTier3Watchdog': (
      title: '비활성 감시자 (불필요)',
      purpose: '사용하지 않아 꺼져 있는 옛 감시 작업입니다. 제거해도 됩니다.',
      showsWindow: false,
    ),
  };

  /// True if a scheduled task with [name] is registered. Runs hidden — never
  /// flashes its own console.
  Future<({bool present, bool disabled})> _queryTask(String name) async {
    try {
      final ProcessResult r = await windowsRunHidden(
        _schtasksExe(),
        <String>['/Query', '/TN', name, '/FO', 'LIST'],
      );
      if (r.exitCode != 0) return (present: false, disabled: false);
      final String out = '${r.stdout}';
      final bool disabled = out.contains('Disabled') || out.contains('사용 안 함');
      return (present: true, disabled: disabled);
    } catch (_) {
      return (present: false, disabled: false);
    }
  }

  /// Enumerate every SixVPN-looking scheduled task name on the machine so we can
  /// surface unexpected/unknown ones, not just the catalog entries.
  Future<Set<String>> _allSixVpnTaskNames() async {
    final Set<String> names = <String>{};
    try {
      final ProcessResult r = await windowsRunHidden(
        _schtasksExe(),
        <String>['/Query', '/FO', 'CSV', '/NH'],
      );
      for (final String line in '${r.stdout}'.split('\n')) {
        final String l = line.trim();
        if (l.isEmpty) continue;
        // First CSV column is the task path, e.g. "\SixVPNAdminExec".
        final int firstQuote = l.indexOf('"');
        if (firstQuote != 0) continue;
        final int secondQuote = l.indexOf('"', 1);
        if (secondQuote < 0) continue;
        final String path = l.substring(1, secondQuote);
        final String leaf = path.split(r'\').last;
        final String low = leaf.toLowerCase();
        if (low.contains('sixvpn') || low.contains('6vpn') ||
            low.contains('vpnblocker')) {
          names.add(leaf);
        }
      }
    } catch (e) {
      AppLogger.instance.warn('bg_components: task enum failed: $e');
    }
    return names;
  }

  /// Is the Run-key autostart present?
  Future<bool> _runKeyPresent() async {
    try {
      final ProcessResult r = await windowsRunHidden(
        _regExe(),
        <String>[
          'query',
          r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
          '/v',
          'SixVPNBlocker',
        ],
      );
      return r.exitCode == 0 && '${r.stdout}'.contains('SixVPNBlocker');
    } catch (_) {
      return false;
    }
  }

  /// Full scan → the list the UI renders.
  Future<List<BgComponent>> scan() async {
    if (!Platform.isWindows) return <BgComponent>[];

    final List<BgComponent> out = <BgComponent>[];

    // 1) Run-key autostart.
    final bool runKey = await _runKeyPresent();
    out.add(BgComponent(
      id: 'SixVPNBlocker',
      kind: BgComponentKind.runKey,
      title: '앱 자동 시작 (로그인)',
      purpose: '로그인하면 Focus Fense를 자동 실행합니다. 차단이 항상 켜져 있도록 '
          '하는 정상 등록 항목입니다.',
      classification: BgComponentClass.essential,
      present: runKey,
    ));

    // 2) Known scheduled tasks.
    final Set<String> seen = <String>{};
    for (final MapEntry<String, ({String title, String purpose, BgComponentClass cls, bool showsWindow})> e
        in _taskCatalog.entries) {
      seen.add(e.key.toLowerCase());
      final ({bool present, bool disabled}) q = await _queryTask(e.key);
      out.add(BgComponent(
        id: e.key,
        kind: BgComponentKind.scheduledTask,
        title: e.value.title,
        purpose: e.value.purpose,
        classification: e.value.cls,
        present: q.present,
        disabled: q.disabled,
        showsWindow: e.value.showsWindow,
      ));
    }

    // 3) Orphans we know about.
    for (final MapEntry<String, ({String title, String purpose, bool showsWindow})> e
        in _orphanCatalog.entries) {
      seen.add(e.key.toLowerCase());
      final ({bool present, bool disabled}) q = await _queryTask(e.key);
      out.add(BgComponent(
        id: e.key,
        kind: BgComponentKind.scheduledTask,
        title: e.value.title,
        purpose: e.value.purpose,
        classification: BgComponentClass.orphan,
        present: q.present,
        disabled: q.disabled,
        showsWindow: e.value.showsWindow,
      ));
    }

    // 4) Any SixVPN-looking task NOT in either catalog → surface as unknown so
    //    nothing is hidden from the user.
    final Set<String> all = await _allSixVpnTaskNames();
    for (final String name in all) {
      if (seen.contains(name.toLowerCase())) continue;
      out.add(BgComponent(
        id: name,
        kind: BgComponentKind.scheduledTask,
        title: '알 수 없는 항목: $name',
        purpose: 'Focus Fense 카탈로그에 없는 예약 작업입니다. 옛 버전의 잔여물일 수 '
            '있습니다. 확실하지 않으면 그대로 두세요.',
        classification: BgComponentClass.unknown,
        present: true,
      ));
    }

    return out;
  }

  /// Delete the orphan tasks. User-level orphans delete without elevation;
  /// SYSTEM-level ones (e.g. SixVPNAdminExec) return in [needsAdmin].
  Future<BgCleanupResult> removeOrphans(List<BgComponent> components) async {
    final List<String> removed = <String>[];
    final List<String> needsAdmin = <String>[];
    final List<String> failed = <String>[];

    for (final BgComponent c in components) {
      if (!c.isRemovable) continue;
      try {
        final ProcessResult r = await windowsRunHidden(
          _schtasksExe(),
          <String>['/Delete', '/F', '/TN', c.id],
        );
        if (r.exitCode == 0) {
          removed.add(c.id);
          AppLogger.instance.info('bg_components: removed orphan ${c.id}');
        } else {
          final String err = '${r.stdout}${r.stderr}'.toLowerCase();
          if (err.contains('denied') || err.contains('액세스') ||
              err.contains('거부')) {
            needsAdmin.add(c.id);
          } else {
            failed.add(c.id);
          }
        }
      } catch (e) {
        AppLogger.instance.warn('bg_components: delete ${c.id} failed: $e');
        failed.add(c.id);
      }
    }

    return BgCleanupResult(
      removed: removed,
      needsAdmin: needsAdmin,
      failed: failed,
    );
  }

  /// PowerShell fragment that deletes SYSTEM-level orphan tasks. Folded into the
  /// elevated apply script so they get cleaned the next time the user approves
  /// UAC — no extra prompt of its own.
  static String elevatedOrphanCleanupFragment() {
    final List<String> names = <String>[
      'SixVPNAdminExec',
      'SixVPNTier3Watchdog',
      'SixVPNBlockerWatchdog2',
    ];
    final String arr = names.map((String n) => "'$n'").join(',');
    return '''
  # --- Focus Fense: remove legacy orphan scheduled tasks (one-time) ---
  try {
    foreach (\$orphan in @($arr)) {
      schtasks /Delete /F /TN \$orphan 2>\$null | Out-Null
    }
  } catch {}
''';
  }
}
