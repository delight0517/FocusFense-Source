import 'dart:io';

import 'package:path/path.dart' as p;

import '../enforcement/layers/browser_policy_layer.dart';
import 'app_logger.dart';
import 'chrome_extension_identity.dart';
import 'chromium_policy_service.dart';
import 'opera_chromium_policy_file_service.dart';
import 'windows_emergency_block_service.dart';
import 'windows_hidden_process.dart';
import 'windows_protection_mode_prefs.dart';
import 'extension_guard_prefs.dart';
import 'mac_system_block_service.dart';
import 'windows_url_allowlist_ownership_service.dart';

/// Closes the bypass holes that the original three-browser pipeline
/// (Chrome / Edge / Firefox) does not cover:
///
/// 1. **URLAllowlist override** — Chrome/Edge policy precedence puts
///    URLAllowlist ABOVE URLBlocklist. A leftover entry from a previous
///    install / corporate IT / a "safe-website" prompt silently re-opens
///    every blocked site. We probe and surgically remove only the entries
///    that conflict with our blocked hosts/handles — never touch
///    user-intended allowlist values for unrelated sites.
///
/// 2. **Chromium derivatives** — Naver Whale (huge in Korea), Brave,
///    Vivaldi, Opera, Edge Beta, Edge Dev. All of them honor the same
///    URLBlocklist policy schema as Chrome/Edge, just under different
///    registry roots. The base [`WindowsHkcuPolicyService`] only writes
///    Chrome/Edge — so a user who switches to Whale (default browser on
///    millions of Korean PCs) sees zero block. Same for Brave.
///
/// 3. **Incognito-mode bypass** — A force-installed extension only runs
///    in Incognito if the manifest opts in *and* the user (or policy)
///    enables it. Without that, every blocked site opens cleanly in an
///    Incognito window. Setting `IncognitoModeAvailability = 1` disables
///    incognito mode entirely — single-source-of-truth fix.
///
/// 4. **Our extension ID hiding in ExtensionInstallBlocklist** — if any
///    prior install / GPO / parental control tool blocks our extension
///    by ID, force-install fails silently. We probe each root and remove
///    only our ID from the blocklist (preserve other entries).
///
/// 5. **Edge IE Mode bypass** — `BrowserSwitcherEnabled = 0` so the user
///    can't punt the blocked URL into the IE engine which doesn't honor
///    Edge URLBlocklist.
///
/// 6. **QUIC fingerprint hardening** — `QuicAllowed = 0` removes the
///    HTTP/3 path; URL is still visible in the URL bar (URLBlocklist
///    still fires), but prevents some edge-case TLS-fingerprint bypasses
///    from forwarding the request before the URL-match policy runs.
///
/// Failure mode catalog: `docs/BROWSER_BLOCK_PIPELINE_POSTMORTEM.md`.
final class WindowsBrowserBypassCloserService {
  WindowsBrowserBypassCloserService._();
  static final WindowsBrowserBypassCloserService instance =
      WindowsBrowserBypassCloserService._();

  bool get isSupported => Platform.isWindows;

  static String get ownedHardeningJournalPath => p.join(
    Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path,
    'SixVPNBlocker',
    'owned_browser_hardening_v1.json',
  );
  static String get _offMarker => p.join(
    Platform.environment['LOCALAPPDATA'] ?? Directory.systemTemp.path,
    'SixVPNBlocker',
    'protection_disabled_v1.json',
  );
  static List<Map<String, Object>> hardeningValues(
    String pacUri, {
    ExtensionGuardPrefs? preferences,
  }) {
    final prefs = preferences ?? ExtensionGuardPrefs.instance;
    String psRoot(String root) => root.replaceFirst(r'HKCU\', r'HKCU:\');
    Map<String, Object> value(
      String root,
      String name,
      String kind,
      Object data,
    ) => {
      'key': psRoot(root),
      'name': name,
      'kind': kind,
      'value': data,
      'enabled': !prefs.isRegistryRootExplicitlyDisabled(root),
      if (ExtensionGuardPrefs.browserIdForRegistryRoot(root)
          case final String browser)
        'disabledMarkerPath': prefs.browserDisabledMarkerPath(browser),
    };
    final primary = [
      r'HKCU\SOFTWARE\Policies\Google\Chrome',
      r'HKCU\SOFTWARE\Policies\Microsoft\Edge',
    ];
    return [
      for (final root in [...primary, ...derivativeHkcuRoots]) ...[
        value(root, 'IncognitoModeAvailability', 'DWord', 1),
        value(root, 'QuicAllowed', 'DWord', 0),
      ],
      // Primary Chrome/Edge PAC/DNS belong to WindowsChromiumRegistryService.
      // Never capture another writer's own value as a new original baseline.
      for (final root in derivativeHkcuRoots) ...[
        value(root, 'ProxyMode', 'String', 'pac_script'),
        value(root, 'ProxyPacUrl', 'String', pacUri),
        value(root, 'BuiltInDnsClientEnabled', 'DWord', 0),
        value(root, 'DnsOverHttpsMode', 'String', 'off'),
      ],
      for (final root in [
        r'HKCU\SOFTWARE\Policies\Microsoft\Edge',
        r'HKCU\SOFTWARE\Policies\Microsoft\EdgeBeta',
        r'HKCU\SOFTWARE\Policies\Microsoft\EdgeDev',
      ]) ...[
        value(root, 'BrowserSwitcherEnabled', 'DWord', 0),
        value(root, 'InternetExplorerIntegrationLevel', 'DWord', 0),
      ],
      value(
        r'HKCU\SOFTWARE\Policies\Mozilla\Firefox',
        'DisablePrivateBrowsing',
        'DWord',
        1,
      ),
    ];
  }

  static String buildOwnedHardeningScript({
    required String pacUri,
    String? journalPath,
    String? offMarkerPath,
    List<Map<String, Object>>? valuesForTesting,
    List<String>? restoreRoots,
  }) {
    String q(String value) => "'${value.replaceAll("'", "''")}'";
    final values = valuesForTesting ?? hardeningValues(pacUri);
    final restore =
        restoreRoots ?? values.map((v) => v['key']! as String).toSet().toList();
    final body = BrowserPolicyLayer.ownedPacPowerShell(
      journalPath: journalPath ?? ownedHardeningJournalPath,
      offMarkerPath: offMarkerPath ?? _offMarker,
      values: values,
    );
    return '$body\n' +
        (restoreRoots != null
            ? 'Restore-FFPac -selectedKeys @(${restore.map(q).join(',')})\n'
            : 'if (-not (Invoke-FFPacApply)) { throw \'Browser hardening stopped by OFF\' }\nWrite-Output \'owned_hardening_written\'\n');
  }

  static String buildOwnedHardeningRestoreScript({
    String? journalPath,
    List<String>? selectedRoots,
    List<Map<String, Object>>? valuesForTesting,
  }) {
    final values =
        valuesForTesting ??
        hardeningValues(
          Uri.file(WindowsEmergencyBlockService.pacPath()).toString(),
        );
    return buildOwnedHardeningScript(
      pacUri: '',
      journalPath: journalPath,
      valuesForTesting: values,
      restoreRoots:
          selectedRoots ??
          values.map((v) => v['key']! as String).toSet().toList(),
    );
  }

  static Future<ProcessResult> _runOwnedHardening(String body) async {
    final directory = await Directory.systemTemp.createTemp(
      'ff-owned-hardening-',
    );
    try {
      final file = File(p.join(directory.path, 'apply.ps1'));
      await file.writeAsString('\uFEFF$body', flush: true);
      return await windowsRunHidden(
        p.join(
          Platform.environment['WINDIR'] ?? r'C:\Windows',
          'System32',
          'WindowsPowerShell',
          'v1.0',
          'powershell.exe',
        ),
        ['-NoProfile', '-NonInteractive', '-File', file.path],
      );
    } finally {
      await directory.delete(recursive: true);
    }
  }

  Future<void> restoreOwnedHardening() async {
    if (!isSupported) return;
    Object? failure;
    try {
      final result = await _runOwnedHardening(
        buildOwnedHardeningRestoreScript(),
      );
      if (result.exitCode != 0) {
        failure = StateError(
          'Browser hardening restore incomplete; retry records retained.',
        );
      }
    } catch (error) {
      failure = error;
    }
    try {
      await WindowsUrlAllowlistOwnershipService.instance.restoreAll();
    } catch (error) {
      failure ??= error;
    }
    if (failure != null) {
      throw StateError(
        'FocusFense browser policy restore incomplete: $failure',
      );
    }
  }

  /// HKCU policy roots we mirror Chrome/Edge writes to. Each Chromium
  /// derivative reads URLBlocklist / URLAllowlist / IncognitoModeAvailability
  /// from its own root using the same schema — so a single
  /// blocklist string set on each works in every browser.
  /// HKCU policy roots for Chromium derivatives (Brave, Whale, Opera, …).
  static List<String> get derivativeHkcuRoots => kDerivatives
      .map((_DerivativeRoot d) => d.hkcuPath)
      .toList(growable: false);

  /// Chromium derivatives that must mirror Chrome/Edge PAC + URLBlocklist.
  static const List<_DerivativeRoot> kDerivatives = <_DerivativeRoot>[
    // Chrome derivatives (most popular in Korea + globally).
    _DerivativeRoot(
      displayName: 'Naver Whale',
      hkcuPath: r'HKCU\SOFTWARE\Policies\NAVER\Whale',
    ),
    _DerivativeRoot(
      displayName: 'Brave',
      hkcuPath: r'HKCU\SOFTWARE\Policies\BraveSoftware\Brave-Browser',
    ),
    _DerivativeRoot(
      displayName: 'Vivaldi',
      hkcuPath: r'HKCU\SOFTWARE\Policies\Vivaldi',
    ),
    _DerivativeRoot(
      displayName: 'Opera',
      hkcuPath: r'HKCU\SOFTWARE\Policies\Opera Software\Opera Stable',
    ),
    _DerivativeRoot(
      displayName: 'Opera GX',
      hkcuPath: r'HKCU\SOFTWARE\Policies\Opera Software\Opera GX Stable',
    ),
    // Edge channels (alpha/beta users on dev preview installs).
    _DerivativeRoot(
      displayName: 'Edge Beta',
      hkcuPath: r'HKCU\SOFTWARE\Policies\Microsoft\EdgeBeta',
    ),
    _DerivativeRoot(
      displayName: 'Edge Dev',
      hkcuPath: r'HKCU\SOFTWARE\Policies\Microsoft\EdgeDev',
    ),
    // Vanilla Chromium / open-source builds (Cent Browser, SRWare Iron, etc).
    _DerivativeRoot(
      displayName: 'Chromium',
      hkcuPath: r'HKCU\SOFTWARE\Policies\Chromium',
    ),
    // Arc Browser (The Browser Company) — Chromium-based, growing share,
    // honors the standard Chromium policy schema under its own root.
    _DerivativeRoot(
      displayName: 'Arc',
      hkcuPath: r'HKCU\SOFTWARE\Policies\TheBrowserCompany\Arc',
    ),
  ];

  /// Roots that must NEVER allow a blocked host through their URLAllowlist.
  /// Includes the primary Chrome/Edge/Firefox roots PLUS every derivative
  /// above — a URLAllowlist set on Brave is just as bypassing as on Chrome.
  static List<String> _allRootsForAllowlistSweep() {
    return <String>[
      r'HKCU\SOFTWARE\Policies\Google\Chrome',
      r'HKCU\SOFTWARE\Policies\Microsoft\Edge',
      r'HKCU\SOFTWARE\Policies\Mozilla\Firefox',
      for (final _DerivativeRoot d in kDerivatives) d.hkcuPath,
    ];
  }

  /// Extract literal hosts from Chromium host filters and URL patterns.
  /// Bare host filters are the common representation; the previous scheme-only
  /// parser silently skipped them, leaving URLAllowlist able to override a
  /// block rule.
  static Set<String> blockedHostsFromPatterns(Iterable<String> patterns) {
    final Set<String> hosts = <String>{};
    for (final String raw in patterns) {
      String value = raw.trim().toLowerCase();
      if (value.isEmpty || value == '*' || value == '<all_urls>') continue;
      value = value.replaceFirst(RegExp(r'^(?:https?|\*)://'), '');
      value = value.split(RegExp(r'[/?:@#]')).first;
      value = value.replaceFirst(RegExp(r'^\*\.'), '');
      value = value.replaceFirst(RegExp(r'^www\.'), '');
      if (value.isEmpty || value.contains('*')) continue;
      final String host = MacSystemBlockService.canonicalHost(value);
      if (host.isNotEmpty && host.contains('.') && !host.startsWith('.')) {
        hosts.add(host);
      }
    }
    return hosts;
  }

  static String _regExe() {
    final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
    return p.join(windir, 'System32', 'reg.exe');
  }

  /// Runs every bypass-closing step. Each step is independent — one failing
  /// does not abort the rest. Returns a per-step summary for the diagnostics
  /// UI / one-tap report.
  Future<BypassCloserResult> applyAll() async {
    if (!isSupported) {
      return const BypassCloserResult(
        ok: true,
        message: 'Windows 전용',
        steps: <String>[],
      );
    }
    if (WindowsProtectionModePrefs.isProtectionExplicitlyOff) {
      return const BypassCloserResult(
        ok: true,
        message: '수동 보호가 꺼져 있어 우회 차단 강화를 건너뜁니다.',
        steps: <String>['manual_protection_off'],
      );
    }
    final List<String> steps = <String>[];
    final List<String> patterns =
        await ChromiumPolicyService.activeBlocklistPatternsForChromium();
    if (patterns.isEmpty ||
        WindowsProtectionModePrefs.isProtectionExplicitlyOff) {
      return const BypassCloserResult(
        ok: true,
        message: '활성 규칙 없음 — 닫기 단계 건너뜀',
        steps: <String>[],
      );
    }

    // Step 1: Sweep URLAllowlist for conflicting entries.
    final int sweepCount = await _sweepConflictingUrlAllowlists(patterns);
    steps.add('allowlist_swept=$sweepCount');

    // URL entries and scalar hardening share each browser's requested state.
    final eligible = kDerivatives.where(
      (d) => !ExtensionGuardPrefs.instance.isRegistryRootExplicitlyDisabled(
        d.hkcuPath,
      ),
    );
    int writtenDerivatives = 0;
    for (final d in eligible) {
      if (WindowsProtectionModePrefs.isProtectionExplicitlyOff) break;
      if (await _writeBlocklistToRoot(d.hkcuPath, patterns))
        writtenDerivatives++;
    }
    steps.add('derivatives_total=$writtenDerivatives');
    bool hardeningOk = false;
    final pac = WindowsEmergencyBlockService.pacPath();
    if (!WindowsProtectionModePrefs.isProtectionExplicitlyOff &&
        await File(pac).exists()) {
      final result = await _runOwnedHardening(
        buildOwnedHardeningScript(pacUri: Uri.file(pac).toString()),
      );
      hardeningOk =
          result.exitCode == 0 &&
          '${result.stdout}'.contains('owned_hardening_written') &&
          !WindowsProtectionModePrefs.isProtectionExplicitlyOff;
    }
    steps.add('owned_hardening_ok=$hardeningOk');
    if (!WindowsProtectionModePrefs.isProtectionExplicitlyOff) {
      final operaFile = await OperaChromiumPolicyFileService.instance
          .applyPatterns(patterns);
      if (operaFile.isNotEmpty)
        steps.add('opera_policy_file=${operaFile.join("|")}');
    }
    final cleaned = WindowsProtectionModePrefs.isProtectionExplicitlyOff
        ? 0
        : await _scrubOurExtensionFromBlocklists();
    steps.add('install_blocklist_cleaned=$cleaned');
    final ok =
        hardeningOk &&
        writtenDerivatives == eligible.length &&
        !WindowsProtectionModePrefs.isProtectionExplicitlyOff;
    final message =
        '${ok ? "우회 차단 설정 적용됨" : "일부 우회 차단 설정 적용 실패"}: '
        '파생 브라우저=$writtenDerivatives, allowlist 정리=$sweepCount';
    AppLogger.instance.info('bypass_closer: $message steps=$steps');
    return BypassCloserResult(ok: ok, message: message, steps: steps);
  }

  /// Iterates every Chromium root's URLAllowlist, deletes any value whose
  /// data contains a blocked host. Preserves unrelated entries.
  ///
  /// Returns the total number of entries deleted across all roots.
  Future<int> _sweepConflictingUrlAllowlists(List<String> patterns) async {
    final Set<String> blockedHosts = blockedHostsFromPatterns(patterns);
    if (blockedHosts.isEmpty) return 0;

    if (WindowsProtectionModePrefs.isProtectionExplicitlyOff) return 0;
    final List<String> activeRoots = _allRootsForAllowlistSweep()
        .where(
          (String root) => !ExtensionGuardPrefs.instance
              .isRegistryRootExplicitlyDisabled(root),
        )
        .map((String root) => root.replaceFirst(r'HKCU\', r'HKCU:\'))
        .toList(growable: false);
    final int removed = await WindowsUrlAllowlistOwnershipService.instance
        .removeConflicts(blockedHosts, roots: activeRoots);
    if (removed > 0) {
      AppLogger.instance.info(
        'bypass_closer: removed $removed conflicting allowlist entries with reversible ownership',
      );
    }
    return removed;
  }

  static String buildOwnedBlocklistScript(
    String root,
    List<String> patterns, {
    String? journalPath,
    List<String>? policyRoots,
    String? offMarkerPath,
  }) {
    String quote(String value) => "'${value.replaceAll("'", "''")}'";
    final marker =
        offMarkerPath ??
        p.join(
          Platform.environment['LOCALAPPDATA'] ?? '',
          'SixVPNBlocker',
          'protection_disabled_v1.json',
        );
    final psRoot = root.replaceFirst(r'HKCU\', r'HKCU:\');
    return "\$ErrorActionPreference='Stop'\n" +
        BrowserPolicyLayer.ownedListsPowerShell(
          journalPath: journalPath,
          policyRoots: policyRoots,
        ) +
        '\nif (Test-Path -LiteralPath ${quote(marker)}) { exit 0 }\n' +
        'Set-FFOwnedList -key ${quote('$psRoot\\URLBlocklist')} -patterns @(${patterns.map(quote).join(',')})\n' +
        "Write-Output 'owned_blocklist_written'\n";
  }

  /// Share ownership with the primary writer so OFF can restore our entries.
  Future<bool> _writeBlocklistToRoot(String root, List<String> patterns) async {
    if (WindowsProtectionModePrefs.isProtectionExplicitlyOff) return false;
    final slice = patterns.take(1000).toList();
    final directory = await Directory.systemTemp.createTemp(
      'ff-derivative-policy-',
    );
    try {
      final file = File(p.join(directory.path, 'apply.ps1'));
      await file.writeAsString(buildOwnedBlocklistScript(root, slice));
      if (WindowsProtectionModePrefs.isProtectionExplicitlyOff) return false;
      final result = await windowsRunHidden(
        p.join(
          Platform.environment['WINDIR'] ?? r'C:\Windows',
          'System32',
          'WindowsPowerShell',
          'v1.0',
          'powershell.exe',
        ),
        <String>['-NoProfile', '-NonInteractive', '-File', file.path],
      );
      final written =
          result.exitCode == 0 &&
          '${result.stdout}'.contains('owned_blocklist_written');
      return written;
    } finally {
      await directory.delete(recursive: true);
    }
  }

  /// Removes our extension ID from each root's `ExtensionInstallBlocklist`.
  /// Preserves any other entries the user / admin intentionally set.
  Future<int> _scrubOurExtensionFromBlocklists() async {
    int cleaned = 0;
    for (final String root in <String>[
      r'HKCU\SOFTWARE\Policies\Google\Chrome',
      r'HKCU\SOFTWARE\Policies\Microsoft\Edge',
      for (final _DerivativeRoot d in kDerivatives) d.hkcuPath,
    ]) {
      if (WindowsProtectionModePrefs.isProtectionExplicitlyOff) return cleaned;
      if (ExtensionGuardPrefs.instance.isRegistryRootExplicitlyDisabled(root))
        continue;
      final String key = '$root\\ExtensionInstallBlocklist';
      final ProcessResult q = await windowsRunHidden(_regExe(), <String>[
        'query',
        key,
      ]);
      if (q.exitCode != 0) continue;
      final String out = '${q.stdout}';
      for (final String line in out.split('\n')) {
        if (!line.contains(ChromeExtensionIdentity.extensionId) &&
            !line.contains('*')) {
          continue;
        }
        final List<String> cols = line
            .split(RegExp(r'\s{2,}'))
            .where((String s) => s.isNotEmpty)
            .toList();
        if (cols.length < 3) continue;
        final String name = cols[0].trim();
        if (name.isEmpty || name.startsWith('HKEY_')) continue;
        if (WindowsProtectionModePrefs.isProtectionExplicitlyOff)
          return cleaned;
        final ProcessResult del = await windowsRunHidden(_regExe(), <String>[
          'delete',
          key,
          '/v',
          name,
          '/f',
        ]);
        if (del.exitCode == 0) cleaned++;
      }
    }
    return cleaned;
  }
}

class _DerivativeRoot {
  const _DerivativeRoot({required this.displayName, required this.hkcuPath});
  final String displayName;
  final String hkcuPath;
}

final class BypassCloserResult {
  const BypassCloserResult({
    required this.ok,
    required this.message,
    required this.steps,
  });

  final bool ok;
  final String message;
  final List<String> steps;
}
