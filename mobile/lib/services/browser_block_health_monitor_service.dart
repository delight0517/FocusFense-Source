import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../utils/numeric_suffix_evasion.dart';
import 'app_logger.dart';
import 'blocker_test_service.dart';
import 'extension_rules_builder.dart';
import 'chrome_extension_identity.dart';
import 'chrome_gmail_gemini_allowlist_service.dart';
import 'chromium_policy_service.dart';
import 'crash_journal_service.dart';
import 'opera_chromium_policy_file_service.dart';
import 'browser_protection_truth_service.dart';
import 'windows_hidden_process.dart';
import 'windows_policy_acl_unlock_service.dart';

/// **Live health monitor for the per-browser block.**
///
/// Periodically and on every rules-apply, this service answers the user's
/// real question — "is the block ACTUALLY working in Chrome / Edge /
/// Firefox right now?" — and, when the answer is no, writes a structured
/// report that the in-app UI surfaces as a nudge ("Chrome을 다시 시작해
/// 주세요") AND that Cursor / Claude can pick up by reading a stable file
/// path to fix the underlying issue.
///
/// Detection layers (per browser):
///
/// * **Installed** — is the browser binary present on disk?
/// * **Running** — is any non-`--type=` main process up right now?
/// * **PolicyOnDisk** — is the URLBlocklist actually populated in
///   `HKCU\…\URLBlocklist` (Chrome/Edge family) or `WebsiteFilter\Block`
///   (Firefox) with at least one entry for our rules?
/// * **PolicyLoaded** — for Firefox specifically, the policy is only read
///   at process start. If the browser was launched BEFORE the policy was
///   written, the running process is using a stale set. We compare the
///   process start time vs the policy key's last-write time and recommend
///   restart when the process predates the policy.
/// * **AclWritable** — is `HKCU\Policies` writable at all (the §2.2 ACL
///   lockdown). If not, every other layer is doomed.
///
/// Outputs (stable paths, overwritten on every run):
///
///   * `%LOCALAPPDATA%\SixVPNBlocker\debug\browser_block_health.json`
///     — machine-readable, schema-versioned.
///   * `%LOCALAPPDATA%\SixVPNBlocker\debug\browser_block_health_prompt.txt`
///     — copy-paste prompt for Cursor / Claude: includes the JSON path,
///     the post-mortem doc reference, the broken-browser list, and
///     suggested fixes. The user pastes this into their AI and it has
///     enough context to act.
///   * `%LOCALAPPDATA%\SixVPNBlocker\debug\browser_block_health_nudge.txt`
///     — one-line Korean user-facing nudge ("Chrome 다시 시작 필요").
///     The app reads this for a snackbar / settings-screen banner.
///
/// Contract with external agents: the report's `agentHints.failedBrowsers`
/// list is the single source of truth. Each entry has codeAnchors and a
/// `suggestedRemedy` describing what action the agent (or the user) should
/// take.
final class BrowserBlockHealthMonitorService {
  BrowserBlockHealthMonitorService._();
  static final BrowserBlockHealthMonitorService instance =
      BrowserBlockHealthMonitorService._();

  // PERFORMANCE BUDGET (added 2026-06-08): no background probe in this
  // app may fire faster than 30s, and any probe that spawns 5+ child
  // processes (which this one does — `Get-Process` × 5 browsers, plus
  // policy registry reads × 5 roots, plus the last-write-time WMI query)
  // must fire no faster than 5 minutes. Lower intervals = the user's
  // reported severe-lag scenario where CPU stayed pegged at ~100% of
  // one core. Manual probe is always available via the diagnostics UI.
  static const Duration _kBootDelay = Duration(seconds: 150);
  static const Duration _kMinProbeGap = Duration(seconds: 45);

  bool _running = false;
  DateTime? _lastProbeAt;

  /// Coalesces concurrent [probe] callers (ecosystem scan + kill guard + boot).
  Future<BrowserBlockHealthReport>? _probeInFlight;

  /// In-app subscribers (settings screen banner, diagnostics tile, etc.)
  /// listen here. Bumped after every refresh.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Most recent snapshot — null until first probe completes.
  BrowserBlockHealthReport? _latest;
  BrowserBlockHealthReport? get latest => _latest;

  /// Completes once the very first [probe] call (of this process lifetime)
  /// finishes. Boot-time cache readers should await this instead of racing
  /// a fixed delay against the probe — otherwise a stale 30-min in-memory
  /// or 7-day disk cache can render a false "적용 필요" nag before the real
  /// first probe has had a chance to refresh it.
  final Completer<void> _firstProbeCompleter = Completer<void>();
  bool get firstProbeCompleted => _firstProbeCompleter.isCompleted;
  Future<void> get firstProbeDone => _firstProbeCompleter.future;

  String get reportPath => p.join(
    CrashJournalService.instance.debugFolderPath,
    'browser_block_health.json',
  );

  String get cursorPromptPath => p.join(
    CrashJournalService.instance.debugFolderPath,
    'browser_block_health_prompt.txt',
  );

  String get userNudgePath => p.join(
    CrashJournalService.instance.debugFolderPath,
    'browser_block_health_nudge.txt',
  );

  /// Boot the monitor in passive mode.
  ///
  /// Probes are event-driven only (manual, post-apply, ecosystem scan)
  /// to avoid periodic PowerShell spawn storms.
  Future<void> start() async {
    if (_running) return;
    if (!Platform.isWindows) return;
    _running = true;
    await CrashJournalService.instance.warmup();
    Future<void>.delayed(_kBootDelay, () {
      unawaited(probe(reason: 'boot'));
    });
  }

  void stop() {
    _running = false;
  }

  /// Called by [UniversalBrowserBlockService.syncNow] after a fresh apply
  /// — the monitor probes a few seconds later so reg.exe writes have
  /// settled, then surfaces any "process predates policy" cases.
  void notifyPolicyApplied() {
    Future<void>.delayed(const Duration(seconds: 3), () {
      unawaited(probe(reason: 'post_apply'));
    });
  }

  /// Runs every detection layer and writes the three output files.
  ///
  /// Concurrent callers share one in-flight probe instead of returning an empty
  /// report (which made the ecosystem UI show "브라우저 없음").
  Future<BrowserBlockHealthReport> probe({String reason = 'manual'}) async {
    final Future<BrowserBlockHealthReport>? inFlight = _probeInFlight;
    if (inFlight != null) {
      return inFlight;
    }
    final bool urgent =
        reason == 'manual' ||
        reason == 'one_tap' ||
        reason.startsWith('installed_browsers_') ||
        reason.startsWith('new_browser_');
    final DateTime? last = _lastProbeAt;
    final BrowserBlockHealthReport? cached = _latest;
    if (!urgent &&
        last != null &&
        cached != null &&
        DateTime.now().difference(last) < _kMinProbeGap) {
      return cached;
    }
    final Future<BrowserBlockHealthReport> run = _probeOnce(reason);
    _probeInFlight = run;
    try {
      return await run;
    } finally {
      if (identical(_probeInFlight, run)) {
        _probeInFlight = null;
      }
    }
  }

  Future<BrowserBlockHealthReport> _probeOnce(String reason) async {
    try {
      final List<String> firefoxPatterns =
          await ChromiumPolicyService.activeBlocklistPatternsForFirefox();
      Future<List<String>> chromiumFor(String id) =>
          ChromiumPolicyService.activeBlocklistPatternsForChromiumBrowser(id);
      final List<String> chromePatterns = await chromiumFor('chrome');
      final bool hasAnyRule =
          chromePatterns.isNotEmpty || firefoxPatterns.isNotEmpty;

      // Sequential probes — 7× parallel reg.exe/PowerShell was pegging one core.
      final List<BrowserHealth> browsers = <BrowserHealth>[];
      Future<void> step(Future<BrowserHealth> f) async {
        browsers.add(await f);
        await Future<void>.delayed(const Duration(milliseconds: 90));
      }

      await step(
        _probeChromium(
          id: 'chrome',
          displayName: 'Chrome',
          processName: 'chrome.exe',
          hkcuRoot: r'HKCU\SOFTWARE\Policies\Google\Chrome',
          installCandidates: <String>[
            r'%ProgramFiles%\Google\Chrome\Application\chrome.exe',
            r'%ProgramFiles(x86)%\Google\Chrome\Application\chrome.exe',
            r'%LocalAppData%\Google\Chrome\Application\chrome.exe',
          ],
          expectedPatterns: chromePatterns,
        ),
      );
      await step(
        _probeChromium(
          id: 'edge',
          displayName: 'Microsoft Edge',
          processName: 'msedge.exe',
          hkcuRoot: r'HKCU\SOFTWARE\Policies\Microsoft\Edge',
          installCandidates: <String>[
            r'%ProgramFiles%\Microsoft\Edge\Application\msedge.exe',
            r'%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe',
          ],
          expectedPatterns: await chromiumFor('edge'),
        ),
      );
      await step(_probeFirefox(expectedPatterns: firefoxPatterns));
      await step(
        _probeChromium(
          id: 'whale',
          displayName: 'Naver Whale',
          processName: 'whale.exe',
          hkcuRoot: r'HKCU\SOFTWARE\Policies\NAVER\Whale',
          installCandidates: <String>[
            r'%ProgramFiles%\Naver\Naver Whale\Application\whale.exe',
            r'%ProgramFiles(x86)%\Naver\Naver Whale\Application\whale.exe',
            r'%LocalAppData%\Naver\Naver Whale\Application\whale.exe',
          ],
          expectedPatterns: await chromiumFor('whale'),
        ),
      );
      await step(
        _probeChromium(
          id: 'brave',
          displayName: 'Brave',
          processName: 'brave.exe',
          hkcuRoot: r'HKCU\SOFTWARE\Policies\BraveSoftware\Brave-Browser',
          installCandidates: <String>[
            r'%ProgramFiles%\BraveSoftware\Brave-Browser\Application\brave.exe',
            r'%ProgramFiles(x86)%\BraveSoftware\Brave-Browser\Application\brave.exe',
            r'%LocalAppData%\BraveSoftware\Brave-Browser\Application\brave.exe',
          ],
          expectedPatterns: await chromiumFor('brave'),
        ),
      );
      await step(
        _probeChromium(
          id: 'vivaldi',
          displayName: 'Vivaldi',
          processName: 'vivaldi.exe',
          hkcuRoot: r'HKCU\SOFTWARE\Policies\Vivaldi',
          installCandidates: <String>[
            r'%ProgramFiles%\Vivaldi\Application\vivaldi.exe',
            r'%ProgramFiles(x86)%\Vivaldi\Application\vivaldi.exe',
            r'%LocalAppData%\Vivaldi\Application\vivaldi.exe',
          ],
          expectedPatterns: await chromiumFor('vivaldi'),
        ),
      );
      await step(
        _probeChromium(
          id: 'opera',
          displayName: 'Opera',
          processName: 'opera.exe',
          hkcuRoot: r'HKCU\SOFTWARE\Policies\Opera Software\Opera Stable',
          installCandidates: <String>[
            r'%ProgramFiles%\Opera\opera.exe',
            r'%ProgramFiles(x86)%\Opera\opera.exe',
            r'%LocalAppData%\Programs\Opera\opera.exe',
          ],
          expectedPatterns: await chromiumFor('opera'),
          policyFileBrowserId: 'opera',
        ),
      );

      // Cross-cutting ACL probe — applies to every Chromium-family browser.
      final bool hkcuWritable = await WindowsPolicyAclUnlockService.instance
          .hkcuPoliciesWritable();
      final bool chromeAllowlistMode = await ChromeGmailGeminiAllowlistService
          .instance
          .enabled();
      final bool chromeAllowlistApplied =
          chromeAllowlistMode &&
          await ChromeGmailGeminiAllowlistService.instance.isAppliedOnDisk();

      // Derive remedies per browser. Chrome's intentional block-all policy
      // is healthy only when the approved Gmail/Gemini exceptions are present.
      List<BrowserHealth> graded = browsers.map((BrowserHealth b) {
        return _grade(
          b,
          hkcuWritable: hkcuWritable,
          hasAnyRule: hasAnyRule,
          chromeAllowlistApplied: chromeAllowlistApplied,
        );
      }).toList();

      final bool dnsSinkholeOk = await _probeNumericApexDnsSinkhole();
      if (!dnsSinkholeOk) {
        graded = graded.map((BrowserHealth b) {
          if (!b.installed || !hasAnyRule) return b;
          if (b.id != 'chrome' && b.id != 'edge') return b;
          final List<String> reasons = List<String>.from(b.reasons);
          if (!reasons.contains('numeric_apex_dns_leak')) {
            reasons.add('numeric_apex_dns_leak');
          }
          return b.copyWith(
            blockActive: false,
            reasons: reasons,
            remedy: const BlockHealthRemedy(
              kind: BlockHealthRemedyKind.runOneTapFull,
              userMessageKo:
                  'mingky01.live 등이 DNS로 실제 IP에 연결됩니다 — 앱이 hosts를 자동 재적용합니다. '
                  'UAC 창이 뜨면 「예」를 눌러 주세요.',
              autoActionLabel: 'auto_hosts_heal',
            ),
          );
        }).toList();
      }

      final bool anyFullBlocklist = graded.any(
        (BrowserHealth b) =>
            b.installed &&
            b.blockActive &&
            b.policyEntryCount >= _kMinFullBlocklistEntries,
      );
      final bool overallOk =
          !hasAnyRule ||
          (anyFullBlocklist &&
              graded
                  .where((BrowserHealth b) => b.installed)
                  .every((BrowserHealth b) => b.blockActive));

      final report = BrowserBlockHealthReport(
        ok: overallOk,
        checkedAt: DateTime.now(),
        reason: reason,
        hkcuWritable: hkcuWritable,
        hasAnyRule: hasAnyRule,
        expectedPatternCount: chromePatterns.length,
        browsers: graded,
      );

      _latest = report;
      _lastProbeAt = DateTime.now();
      await BrowserProtectionTruthService.instance.mergeFromHealth(report);
      await _writeReport(report);
      await _writeCursorPrompt(report);
      await _writeUserNudge(report);
      revision.value++;
      return report;
    } catch (e, st) {
      AppLogger.instance.warn('block_health_monitor probe failed: $e\n$st');
      return _latest ?? BrowserBlockHealthReport.empty(reason: '$reason error');
    } finally {
      if (!_firstProbeCompleter.isCompleted) {
        _firstProbeCompleter.complete();
      }
    }
  }

  // ───────────────────────── per-browser probes ──────────────────────────

  Future<BrowserHealth> _probeChromium({
    required String id,
    required String displayName,
    required String processName,
    required String hkcuRoot,
    required List<String> installCandidates,
    required List<String> expectedPatterns,
    String? policyFileBrowserId,
  }) async {
    final bool installed = await _anyExists(installCandidates);
    final _ProcessProbe proc = await _probeProcess(processName);
    _PolicyProbe pol = await _probeChromiumPolicy(
      '$hkcuRoot\\URLBlocklist',
      expectedPatterns,
    );
    if (policyFileBrowserId != null &&
        (!pol.hasEntries || pol.entryCount < _kMinFullBlocklistEntries)) {
      final ({
        bool ok,
        int count,
        String? path,
        bool sampleMatch,
        bool numericApexOk,
      })
      filePol = await OperaChromiumPolicyFileService.probeFilePolicyDetailed(
        policyFileBrowserId,
        expectedPatterns: expectedPatterns,
      );
      if (filePol.ok && filePol.count > pol.entryCount) {
        DateTime? fileMtime;
        if (filePol.path != null) {
          try {
            fileMtime = await File(filePol.path!).lastModified();
          } catch (_) {}
        }
        pol = _PolicyProbe(
          hasEntries: true,
          entryCount: filePol.count,
          lastWrite: fileMtime,
          sampleMatch: pol.sampleMatch || filePol.sampleMatch,
          numericApexOk: pol.numericApexOk || filePol.numericApexOk,
        );
      }
    }
    return BrowserHealth(
      id: id,
      displayName: displayName,
      installed: installed,
      running: proc.running,
      pid: proc.pid,
      processStart: proc.startedAt,
      policyHasEntries: pol.hasEntries,
      policyEntryCount: pol.entryCount,
      policyLastWrite: pol.lastWrite,
      policySampleMatch: pol.sampleMatch,
      policyBlockAll: pol.hasBlockAllSentinel,
      policyNumericApexOk: pol.numericApexOk,
      processOlderThanPolicy:
          proc.startedAt != null &&
          pol.lastWrite != null &&
          proc.startedAt!.isBefore(
            pol.lastWrite!.subtract(const Duration(seconds: 2)),
          ),
      blockActive: false,
      reasons: const <String>[],
      remedy: null,
    );
  }

  Future<BrowserHealth> _probeFirefox({
    required List<String> expectedPatterns,
  }) async {
    final bool installed = await _anyExists(<String>[
      r'%ProgramFiles%\Mozilla Firefox\firefox.exe',
      r'%ProgramFiles(x86)%\Mozilla Firefox\firefox.exe',
      r'%LocalAppData%\Mozilla Firefox\firefox.exe',
    ]);
    final _ProcessProbe proc = await _probeProcess('firefox.exe');
    final _PolicyProbe pol = await _probeChromiumPolicy(
      r'HKCU\SOFTWARE\Policies\Mozilla\Firefox\WebsiteFilter\Block',
      expectedPatterns,
    );
    return BrowserHealth(
      id: 'firefox',
      displayName: 'Firefox',
      installed: installed,
      running: proc.running,
      pid: proc.pid,
      processStart: proc.startedAt,
      policyHasEntries: pol.hasEntries,
      policyEntryCount: pol.entryCount,
      policyLastWrite: pol.lastWrite,
      policySampleMatch: pol.sampleMatch,
      policyNumericApexOk: pol.numericApexOk,
      processOlderThanPolicy:
          proc.startedAt != null &&
          pol.lastWrite != null &&
          proc.startedAt!.isBefore(
            pol.lastWrite!.subtract(const Duration(seconds: 2)),
          ),
      blockActive: false,
      reasons: const <String>[],
      remedy: null,
    );
  }

  /// Resolves environment-variable paths and returns true if any candidate
  /// file exists on disk.
  Future<bool> _anyExists(List<String> candidates) async {
    for (final String c in candidates) {
      final String expanded = _expandEnv(c);
      try {
        if (await File(expanded).exists()) return true;
      } catch (_) {}
    }
    return false;
  }

  String _expandEnv(String s) {
    return s.replaceAllMapped(RegExp(r'%([^%]+)%'), (Match m) {
      return Platform.environment[m.group(1)!] ?? m.group(0)!;
    });
  }

  Future<_ProcessProbe> _probeProcess(String name) async {
    // Get-Process is fast (~50 ms) and gives us PID + StartTime in one call.
    // We restrict to non-`--type=` mains by also calling Win32_Process — but
    // for the health monitor's purpose, ANY process of that name is enough
    // to know the user is using the browser.
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final String psExe = p.join(
      windir,
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
    final String bare = name.replaceAll('.exe', '');
    final String cmd =
        '(Get-Process -Name "$bare" -ErrorAction SilentlyContinue | '
        'Sort-Object StartTime | Select-Object -First 1 | '
        'ForEach-Object { "PID=\$(\$_.Id) START=\$(\$_.StartTime.ToString(\'o\'))" })';
    try {
      final ProcessResult r = await windowsRunHidden(psExe, <String>[
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        cmd,
      ]);
      final String out = '${r.stdout}'.trim();
      if (out.isEmpty) {
        return const _ProcessProbe(running: false, pid: null, startedAt: null);
      }
      final RegExpMatch? pidM = RegExp(r'PID=(\d+)').firstMatch(out);
      final RegExpMatch? startM = RegExp(r'START=(\S+)').firstMatch(out);
      final int? pid = pidM != null ? int.tryParse(pidM.group(1)!) : null;
      DateTime? start;
      if (startM != null) {
        try {
          start = DateTime.parse(startM.group(1)!);
        } catch (_) {}
      }
      return _ProcessProbe(running: pid != null, pid: pid, startedAt: start);
    } catch (_) {
      return const _ProcessProbe(running: false, pid: null, startedAt: null);
    }
  }

  /// `mingky01.live` must resolve to `0.0.0.0` — URLBlocklist alone does not block.
  Future<bool> _probeNumericApexDnsSinkhole() async {
    if (!Platform.isWindows) return true;
    try {
      final ExtensionRulesPayload payload =
          await ExtensionRulesBuilder.buildForBrowserEnforcement();
      if (payload.numericStemHosts.isEmpty &&
          payload.adultNumericStemHosts.isEmpty) {
        return true;
      }
      final List<String> hosts = <String>[];
      for (final String stem in <String>[
        ...payload.numericStemHosts,
        ...payload.adultNumericStemHosts,
      ]) {
        final List<String> priority =
            NumericSuffixEvasion.priorityConcreteApexForStem(stem, maxHosts: 1);
        if (priority.isNotEmpty) hosts.add(priority.first);
        if (hosts.length >= 3) break;
      }
      if (hosts.isEmpty) return true;
      for (final String host in hosts) {
        final HostProbe r = await BlockerTestService.instance.systemProbe(host);
        if (!r.blocked) return false;
      }
      return true;
    } catch (e) {
      AppLogger.instance.warn('numeric apex DNS probe failed: $e');
      return true;
    }
  }

  List<String> _numericApexProbePatterns(List<String> expectedPatterns) {
    return expectedPatterns
        .where(NumericSuffixEvasion.isConcreteNumericApexBlocklistPattern)
        .take(12)
        .toList();
  }

  bool _numericApexProbesSatisfied(String regOut, List<String> numericProbes) {
    if (numericProbes.isEmpty) return true;
    final int matched = numericProbes
        .where((String p) => regOut.contains(p))
        .length;
    final int need = numericProbes.length <= 4
        ? numericProbes.length
        : (numericProbes.length / 2).ceil();
    return matched >= need;
  }

  /// True when registry output contains our blocklist (not only sentinels).
  bool _registryOutputMatchesBlocklist(
    String regOut,
    List<String> expectedPatterns, {
    List<String> numericProbes = const <String>[],
  }) {
    if (expectedPatterns.isEmpty) return false;
    if (regOut.contains('<*>') &&
        !regOut.contains('pornhub') &&
        !regOut.contains('youtube')) {
      return false;
    }
    if (!_numericApexProbesSatisfied(regOut, numericProbes)) {
      return false;
    }
    final int checkN = expectedPatterns.length < 12
        ? expectedPatterns.length
        : 12;
    for (int i = 0; i < checkN; i++) {
      if (regOut.contains(expectedPatterns[i])) return true;
    }
    if (numericProbes.isNotEmpty &&
        _numericApexProbesSatisfied(regOut, numericProbes)) {
      return true;
    }
    const List<String> sentinels = <String>[
      'blocked-test.example',
      'pornhub.com',
      'youtube.com',
      'youtu.be',
    ];
    for (final String s in sentinels) {
      if (regOut.contains(s)) return true;
    }
    return false;
  }

  Future<_PolicyProbe> _probeChromiumPolicy(
    String fullKey,
    List<String> expectedPatterns,
  ) async {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final String regExe = p.join(windir, 'System32', 'reg.exe');
    final List<String> numericProbes = _numericApexProbePatterns(
      expectedPatterns,
    );
    int entryCount = 0;
    bool sampleMatch = false;
    bool hasBlockAll = false;
    bool numericApexOk = numericProbes.isEmpty;
    String regDump = '';
    try {
      // Fast path — value "1" only (~200 B). Full key dump can be 50 KB+ and
      // races with parallel probes under desktop-heap pressure.
      final ProcessResult v1 = await windowsRunHidden(regExe, <String>[
        'query',
        fullKey,
        '/v',
        '1',
      ]);
      if (v1.exitCode == 0) {
        final String v1out = '${v1.stdout}';
        entryCount = entryCount < 1 ? 1 : entryCount;
        if (v1out.contains('<*>')) hasBlockAll = true;
        if (_registryOutputMatchesBlocklist(
          v1out,
          expectedPatterns,
          numericProbes: numericProbes,
        )) {
          sampleMatch = true;
        }
      }

      final ProcessResult q = await windowsRunHidden(regExe, <String>[
        'query',
        fullKey,
      ]);
      if (q.exitCode == 0) {
        final String out = '${q.stdout}';
        entryCount = 0;
        regDump = out;
        if (_registryOutputMatchesBlocklist(
          out,
          expectedPatterns,
          numericProbes: numericProbes,
        )) {
          sampleMatch = true;
        }
        numericApexOk = _numericApexProbesSatisfied(out, numericProbes);
        for (final String line in out.split(RegExp(r'\r?\n'))) {
          if (!line.contains('REG_SZ')) continue;
          final String trimmed = line.trim();
          if (trimmed.startsWith('HKEY_')) continue;
          entryCount++;
          final String lower = line.toLowerCase();
          if (lower.contains('<*>')) {
            hasBlockAll = true;
            sampleMatch = true;
          }
        }
      }
    } catch (_) {}
    if (!numericApexOk && regDump.isNotEmpty) {
      numericApexOk = _numericApexProbesSatisfied(regDump, numericProbes);
    }
    // Last-write time: read via PowerShell since reg.exe doesn't show it.
    DateTime? lastWrite = await _regKeyLastWriteTime(fullKey);
    return _PolicyProbe(
      hasEntries: entryCount > 0,
      entryCount: entryCount,
      lastWrite: lastWrite,
      sampleMatch: sampleMatch,
      hasBlockAllSentinel: hasBlockAll,
      numericApexOk: numericApexOk,
    );
  }

  Future<DateTime?> _regKeyLastWriteTime(String fullKey) async {
    // Convert HKCU\SOFTWARE\… → HKCU:\SOFTWARE\… for PowerShell paths.
    final String psPath = fullKey
        .replaceFirst(RegExp(r'^HKCU\\'), 'HKCU:\\')
        .replaceFirst(RegExp(r'^HKLM\\'), 'HKLM:\\');
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    final String psExe = p.join(
      windir,
      'System32',
      'WindowsPowerShell',
      'v1.0',
      'powershell.exe',
    );
    final String cmd =
        '''
\$k = Get-Item -LiteralPath '$psPath' -ErrorAction SilentlyContinue
if (\$k) {
  \$sig = [Microsoft.Win32.RegistryKey].GetMethod('GetType', [type[]]@())
  try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class RegLastWrite {
  [DllImport("advapi32.dll", CharSet=CharSet.Unicode)]
  public static extern int RegQueryInfoKey(IntPtr hKey, IntPtr lpClass, IntPtr lpcchClass,
    IntPtr lpReserved, IntPtr lpcSubKeys, IntPtr lpcbMaxSubKeyLen, IntPtr lpcbMaxClassLen,
    IntPtr lpcValues, IntPtr lpcbMaxValueNameLen, IntPtr lpcbMaxValueLen, IntPtr lpcbSecurityDescriptor,
    out long lpftLastWriteTime);
}
'@ -ErrorAction SilentlyContinue
  } catch {}
  \$handle = \$k.Handle.DangerousGetHandle()
  \$ft = 0
  [void][RegLastWrite]::RegQueryInfoKey(\$handle, [IntPtr]::Zero,[IntPtr]::Zero,[IntPtr]::Zero,[IntPtr]::Zero,[IntPtr]::Zero,[IntPtr]::Zero,[IntPtr]::Zero,[IntPtr]::Zero,[IntPtr]::Zero,[IntPtr]::Zero,[ref] \$ft)
  if (\$ft -gt 0) { [DateTime]::FromFileTimeUtc(\$ft).ToString('o') }
}
''';
    try {
      final ProcessResult r = await windowsRunHidden(psExe, <String>[
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        cmd,
      ]);
      final String out = '${r.stdout}'.trim();
      if (out.isEmpty) return null;
      return DateTime.tryParse(out);
    } catch (_) {
      return null;
    }
  }

  // ──────────────────────────── grading ────────────────────────────────

  static const int _kMinFullBlocklistEntries = 20;

  BrowserHealth _grade(
    BrowserHealth b, {
    required bool hkcuWritable,
    required bool hasAnyRule,
    required bool chromeAllowlistApplied,
  }) {
    final List<String> reasons = <String>[];
    BlockHealthRemedy? remedy;

    if (!b.installed) {
      // Not installed → not a failure. blockActive is vacuously true here so
      // the overall report doesn't claim a problem on a browser the user
      // doesn't have.
      return b.copyWith(
        blockActive: true,
        reasons: const <String>[],
        remedy: null,
      );
    }

    if (!hasAnyRule) {
      // No rules → nothing to block. Healthy.
      return b.copyWith(
        blockActive: true,
        reasons: const <String>[],
        remedy: null,
      );
    }

    if (!hkcuWritable) {
      reasons.add('hkcu_policy_acl_locked');
      remedy = const BlockHealthRemedy(
        kind: BlockHealthRemedyKind.runAclUnlock,
        userMessageKo:
            'HKCU 정책 키가 잠겨 있습니다. 진단 → 「ACL 잠금 해제」를 눌러 UAC 「예」를 선택하세요.',
        autoActionLabel: 'open_acl_unlock',
      );
    }

    final bool fullBlocklistOnDisk =
        b.policyEntryCount >= _kMinFullBlocklistEntries &&
        b.policySampleMatch &&
        b.policyNumericApexOk;
    final bool chromeBlockAllOnDisk =
        b.id == 'chrome' && chromeAllowlistApplied && b.policyBlockAll;
    final bool policyOnDisk =
        chromeBlockAllOnDisk ||
        fullBlocklistOnDisk ||
        (b.policyHasEntries &&
            b.policySampleMatch &&
            b.policyNumericApexOk &&
            b.policyEntryCount >= 3);

    if (!policyOnDisk) {
      if (!b.policyHasEntries) {
        reasons.add('urlblocklist_empty_on_disk');
        remedy ??= const BlockHealthRemedy(
          kind: BlockHealthRemedyKind.runOneTapFull,
          userMessageKo: '브라우저 정책 차단 목록이 비어 있습니다. 진단 → 「원탭 차단 적용」을 실행하세요.',
          autoActionLabel: 'open_one_tap',
        );
      } else if (b.id == 'chrome' &&
          b.policyEntryCount <= 2 &&
          !chromeAllowlistApplied) {
        reasons.add('chrome_urlblocklist_wildcard_only');
        remedy ??= const BlockHealthRemedy(
          kind: BlockHealthRemedyKind.runOneTapFull,
          userMessageKo:
              'Chrome URL 차단 목록이 Gmail 와일드카드(<*>)만 있습니다. '
              '진단 → 「원탭 차단 적용」으로 megaskorea 등 전체 목록을 씁니다.',
          autoActionLabel: 'open_one_tap',
        );
      } else if (b.id == 'chrome' || b.id == 'edge') {
        reasons.add('chrome_numeric_apex_missing');
        remedy ??= const BlockHealthRemedy(
          kind: BlockHealthRemedyKind.runOneTapFull,
          userMessageKo:
              '스케줄 숫자 우회 도메인(mingky01.live 등)이 Chrome URLBlocklist에 없습니다. '
              '진단 → 「원탭 차단 적용」 후 Chrome을 완전히 종료·재실행하세요.',
          autoActionLabel: 'open_one_tap',
        );
      } else {
        reasons.add('urlblocklist_does_not_match_current_rules');
        remedy ??= const BlockHealthRemedy(
          kind: BlockHealthRemedyKind.runOneTapFull,
          userMessageKo: '브라우저 정책이 최신 규칙과 일치하지 않습니다. 진단 → 「원탭 차단 적용」을 실행하세요.',
          autoActionLabel: 'open_one_tap',
        );
      }
    }

    // Policy on disk but browser started before last write — needs restart for
    // in-process reload. Does NOT mean URL block is absent (kill guard must not
    // treat this as "unprotected").
    if (b.running && b.processOlderThanPolicy && policyOnDisk) {
      remedy ??= BlockHealthRemedy(
        kind: BlockHealthRemedyKind.restartBrowser,
        userMessageKo: '${b.displayName}을(를) 완전히 종료한 뒤 다시 열어 정책을 다시 읽도록 해주세요.',
        autoActionLabel: 'open_browser_restart_help',
      );
    }

    final bool blockActive =
        policyOnDisk && !reasons.contains('hkcu_policy_acl_locked');
    return b.copyWith(
      blockActive: blockActive,
      reasons: reasons,
      remedy: remedy,
    );
  }

  // ───────────────────────── output writers ─────────────────────────────

  Future<void> _writeReport(BrowserBlockHealthReport report) async {
    try {
      final File f = File(reportPath);
      await f.parent.create(recursive: true);
      await f.writeAsString(
        const JsonEncoder.withIndent('  ').convert(report.toJson()),
        flush: true,
      );
    } catch (e) {
      AppLogger.instance.warn('block_health: write report failed: $e');
    }
  }

  Future<void> _writeCursorPrompt(BrowserBlockHealthReport report) async {
    try {
      final List<BrowserHealth> failed = report.browsers
          .where((BrowserHealth b) => !b.blockActive)
          .toList();
      final StringBuffer sb = StringBuffer();
      sb.writeln('# Focus Fense — browser block health prompt');
      sb.writeln();
      sb.writeln(
        'Generated at ${report.checkedAt.toIso8601String()} (reason: ${report.reason}).',
      );
      sb.writeln();
      sb.writeln('## Read this first');
      sb.writeln(
        '- Full machine-readable report: `${reportPath.replaceAll(r"\\", "/")}`',
      );
      sb.writeln(
        '- Postmortem (read first): `docs/BROWSER_BLOCK_PIPELINE_POSTMORTEM.md`',
      );
      sb.writeln('- Extension id: `${ChromeExtensionIdentity.extensionId}`');
      sb.writeln();
      sb.writeln('## Overall status');
      sb.writeln('- ok: **${report.ok}**');
      sb.writeln('- hkcu policies writable: ${report.hkcuWritable}');
      sb.writeln('- expected URL patterns: ${report.expectedPatternCount}');
      sb.writeln('- failing browsers: ${failed.length}');
      sb.writeln();
      if (failed.isEmpty) {
        sb.writeln(
          'All installed browsers report a healthy block. Nothing to do.',
        );
      } else {
        sb.writeln('## Failing browsers');
        for (final BrowserHealth b in failed) {
          sb.writeln();
          sb.writeln('### ${b.displayName} (${b.id})');
          sb.writeln('- installed: ${b.installed}');
          sb.writeln('- running: ${b.running} (pid=${b.pid ?? "-"})');
          sb.writeln(
            '- policy entries on disk: ${b.policyEntryCount} (sample match: ${b.policySampleMatch})',
          );
          sb.writeln('- process predates policy: ${b.processOlderThanPolicy}');
          sb.writeln('- reasons: ${b.reasons.join(", ")}');
          if (b.remedy != null) {
            sb.writeln(
              '- recommended remedy: **${b.remedy!.kind.name}** — ${b.remedy!.userMessageKo}',
            );
          }
        }
        sb.writeln();
        sb.writeln('## Suggested actions for the agent');
        sb.writeln(
          '1. Read the full JSON at the path above (it has codeAnchors per browser).',
        );
        sb.writeln(
          '2. Cross-reference each `reasons[]` entry against §2.1–§2.4 of the postmortem.',
        );
        sb.writeln(
          '3. If `hkcu_policy_acl_locked` is present, that is §2.2 — the user must approve ACL unlock UAC.',
        );
        sb.writeln(
          '4. If `process_predates_policy_apply` is the only reason, the policy is correct; the user just needs to fully close and reopen the browser.',
        );
        sb.writeln(
          '5. If `urlblocklist_empty_on_disk` is present, run the One-Tap pipeline (`OneTapBlockEverythingService.run`).',
        );
        sb.writeln(
          '6. Unprotected browsers are auto-terminated by '
          '`UnprotectedBrowserKillGuardService` when URLBlocklist is empty '
          'or stale while the process is running.',
        );
      }
      await File(cursorPromptPath).writeAsString(sb.toString(), flush: true);
    } catch (e) {
      AppLogger.instance.warn('block_health: write prompt failed: $e');
    }
  }

  Future<void> _writeUserNudge(BrowserBlockHealthReport report) async {
    try {
      final List<BrowserHealth> failed = report.browsers
          .where((BrowserHealth b) => !b.blockActive)
          .toList();
      String nudge;
      if (failed.isEmpty) {
        nudge = '';
      } else {
        // The most impactful failing browser is one that's RUNNING + has the
        // user actively using it. If we have a restart-only fix, surface
        // that first because it's the user's lowest-effort action.
        BrowserHealth pick = failed.first;
        for (final BrowserHealth b in failed) {
          if (b.running &&
              b.remedy?.kind == BlockHealthRemedyKind.restartBrowser) {
            pick = b;
            break;
          }
          if (b.running) pick = b;
        }
        nudge =
            pick.remedy?.userMessageKo ??
            '${pick.displayName} 차단이 활성화되지 않았습니다 — 진단 화면을 확인하세요.';
      }
      await File(userNudgePath).writeAsString(nudge, flush: true);
    } catch (e) {
      AppLogger.instance.warn('block_health: write nudge failed: $e');
    }
  }
}

// ──────────────────────────── data model ──────────────────────────────────

class _ProcessProbe {
  const _ProcessProbe({
    required this.running,
    required this.pid,
    required this.startedAt,
  });
  final bool running;
  final int? pid;
  final DateTime? startedAt;
}

class _PolicyProbe {
  const _PolicyProbe({
    required this.hasEntries,
    required this.entryCount,
    required this.lastWrite,
    required this.sampleMatch,
    this.hasBlockAllSentinel = false,
    this.numericApexOk = true,
  });
  final bool hasEntries;
  final int entryCount;
  final DateTime? lastWrite;
  final bool sampleMatch;
  final bool hasBlockAllSentinel;
  final bool numericApexOk;
}

/// Per-browser health record. Public-shaped so the UI / one-tap report can
/// read it and so Cursor agents can deserialise the JSON file directly.
final class BrowserHealth {
  const BrowserHealth({
    required this.id,
    required this.displayName,
    required this.installed,
    required this.running,
    required this.pid,
    required this.processStart,
    required this.policyHasEntries,
    required this.policyEntryCount,
    required this.policyLastWrite,
    required this.policySampleMatch,
    this.policyNumericApexOk = true,
    this.policyBlockAll = false,
    required this.processOlderThanPolicy,
    required this.blockActive,
    required this.reasons,
    required this.remedy,
  });

  final String id;
  final String displayName;
  final bool installed;
  final bool running;
  final int? pid;
  final DateTime? processStart;
  final bool policyHasEntries;
  final int policyEntryCount;
  final DateTime? policyLastWrite;
  final bool policySampleMatch;
  final bool policyNumericApexOk;
  final bool policyBlockAll;
  final bool processOlderThanPolicy;
  final bool blockActive;
  final List<String> reasons;
  final BlockHealthRemedy? remedy;

  /// Policy on disk but the running process has not reloaded it yet — treat as
  /// unprotected for kill-guard (Chrome `<*>` / URLBlocklist not enforced).
  bool get effectivelyBlockActive =>
      blockActive &&
      policyNumericApexOk &&
      !(running && processOlderThanPolicy);

  BrowserHealth copyWith({
    bool? blockActive,
    List<String>? reasons,
    BlockHealthRemedy? remedy,
  }) => BrowserHealth(
    id: id,
    displayName: displayName,
    installed: installed,
    running: running,
    pid: pid,
    processStart: processStart,
    policyHasEntries: policyHasEntries,
    policyEntryCount: policyEntryCount,
    policyLastWrite: policyLastWrite,
    policySampleMatch: policySampleMatch,
    policyNumericApexOk: policyNumericApexOk,
    policyBlockAll: policyBlockAll,
    processOlderThanPolicy: processOlderThanPolicy,
    blockActive: blockActive ?? this.blockActive,
    reasons: reasons ?? this.reasons,
    remedy: remedy ?? this.remedy,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'displayName': displayName,
    'installed': installed,
    'running': running,
    'pid': pid,
    'processStart': processStart?.toIso8601String(),
    'policyHasEntries': policyHasEntries,
    'policyEntryCount': policyEntryCount,
    'policyLastWrite': policyLastWrite?.toIso8601String(),
    'policySampleMatch': policySampleMatch,
    'policyNumericApexOk': policyNumericApexOk,
    'policyBlockAll': policyBlockAll,
    'processOlderThanPolicy': processOlderThanPolicy,
    'blockActive': blockActive,
    'effectivelyBlockActive': effectivelyBlockActive,
    'reasons': reasons,
    'remedy': remedy?.toJson(),
    'codeAnchors': _codeAnchorsFor(id),
  };

  static List<String> _codeAnchorsFor(String id) {
    switch (id) {
      case 'chrome':
      case 'edge':
        return const <String>[
          'mobile/lib/services/windows_hkcu_policy_service.dart',
          'mobile/lib/services/chromium_policy_service.dart',
          'mobile/lib/services/windows_policy_acl_unlock_service.dart',
          'mobile/lib/services/windows_browser_bypass_closer_service.dart',
          'docs/BROWSER_BLOCK_PIPELINE_POSTMORTEM.md',
        ];
      case 'firefox':
        return const <String>[
          'mobile/lib/services/windows_hkcu_policy_service.dart',
          'mobile/lib/services/windows_firefox_extension_install_service.dart',
          'mobile/lib/services/firefox_config_service.dart',
          'docs/BROWSER_BLOCK_PIPELINE_POSTMORTEM.md',
        ];
      case 'whale':
      case 'brave':
      case 'vivaldi':
      case 'opera':
        return const <String>[
          'mobile/lib/services/windows_browser_bypass_closer_service.dart',
          'docs/BROWSER_BLOCK_PIPELINE_POSTMORTEM.md',
        ];
      default:
        return const <String>['docs/BROWSER_BLOCK_PIPELINE_POSTMORTEM.md'];
    }
  }
}

/// Public report — read by the in-app UI for banners and by external agents
/// (Cursor / Claude) via the stable file path.
final class BrowserBlockHealthReport {
  const BrowserBlockHealthReport({
    required this.ok,
    required this.checkedAt,
    required this.reason,
    required this.hkcuWritable,
    required this.hasAnyRule,
    required this.expectedPatternCount,
    required this.browsers,
  });

  factory BrowserBlockHealthReport.empty({required String reason}) =>
      BrowserBlockHealthReport(
        ok: true,
        checkedAt: DateTime.fromMillisecondsSinceEpoch(0),
        reason: reason,
        hkcuWritable: true,
        hasAnyRule: false,
        expectedPatternCount: 0,
        browsers: const <BrowserHealth>[],
      );

  final bool ok;
  final DateTime checkedAt;
  final String reason;
  final bool hkcuWritable;
  final bool hasAnyRule;
  final int expectedPatternCount;
  final List<BrowserHealth> browsers;

  List<BrowserHealth> get failingBrowsers =>
      browsers.where((BrowserHealth b) => !b.blockActive).toList();

  Map<String, Object?> toJson() => <String, Object?>{
    'schemaVersion': 1,
    'reportKind': 'browser_block_health',
    'docsRef': 'docs/BROWSER_BLOCK_PIPELINE_POSTMORTEM.md',
    'ok': ok,
    'checkedAt': checkedAt.toIso8601String(),
    'reason': reason,
    'hkcuWritable': hkcuWritable,
    'hasAnyRule': hasAnyRule,
    'expectedPatternCount': expectedPatternCount,
    'browsers': browsers.map((BrowserHealth b) => b.toJson()).toList(),
    'agentHints': <String, Object?>{
      'primaryDoc': 'docs/BROWSER_BLOCK_PIPELINE_POSTMORTEM.md',
      'failedBrowsers': failingBrowsers
          .map(
            (BrowserHealth b) => <String, Object?>{
              'id': b.id,
              'reasons': b.reasons,
              'remedy': b.remedy?.toJson(),
              'codeAnchors': BrowserHealth._codeAnchorsFor(b.id),
            },
          )
          .toList(),
    },
  };
}

/// Remedy kinds — closed enum so the UI's snackbar dispatcher can switch on it.
enum BlockHealthRemedyKind {
  /// User must fully close and reopen the browser.
  restartBrowser,

  /// Run the one-tap "전체 자동 수정" pipeline.
  runOneTapFull,

  /// Approve the elevated ACL-unlock UAC.
  runAclUnlock,

  /// Manual: chrome://policy → Reload policies (the user is already
  /// in the browser; restart is more reliable but reload is faster).
  reloadPolicies,
}

final class BlockHealthRemedy {
  const BlockHealthRemedy({
    required this.kind,
    required this.userMessageKo,
    this.autoActionLabel,
  });

  final BlockHealthRemedyKind kind;
  final String userMessageKo;
  final String? autoActionLabel;

  Map<String, Object?> toJson() => <String, Object?>{
    'kind': kind.name,
    'userMessageKo': userMessageKo,
    'autoActionLabel': autoActionLabel,
  };
}
