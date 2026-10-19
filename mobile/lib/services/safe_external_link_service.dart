import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import '../models/active_app_block_entry.dart';
import '../models/ecosystem_scan_models.dart';
import '../router/app_router.dart';
import '../theme/app_colors.dart';
import 'active_app_block_registry_service.dart';
import 'app_logger.dart';
import 'block_activity_log_service.dart';
import 'default_browser_promoter_service.dart';
import 'windows_default_browser_service.dart';
import 'windows_hidden_process.dart';

/// One stable [exeName] per browser, used both to look the binary up on
/// disk and to test "is this exe in the active app-block list?".
/// Order matters: when we have to pick a fallback automatically (no UI),
/// we walk it top-to-bottom — Edge first since it's installed on every
/// Windows machine, then Whale/Chrome/Firefox/Brave/Vivaldi.
const List<_BrowserPath> _kKnownBrowsers = <_BrowserPath>[
  _BrowserPath(
    id: 'edge',
    exeName: 'msedge.exe',
    displayName: 'Microsoft Edge',
    candidatePaths: <String>[
      r'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
      r'C:\Program Files\Microsoft\Edge\Application\msedge.exe',
    ],
  ),
  _BrowserPath(
    id: 'whale',
    exeName: 'whale.exe',
    displayName: 'Naver Whale',
    candidatePaths: <String>[
      r'C:\Program Files\Naver\Naver Whale\Application\whale.exe',
      r'C:\Program Files (x86)\Naver\Naver Whale\Application\whale.exe',
    ],
  ),
  _BrowserPath(
    id: 'chrome',
    exeName: 'chrome.exe',
    displayName: 'Google Chrome',
    candidatePaths: <String>[
      r'C:\Program Files\Google\Chrome\Application\chrome.exe',
      r'C:\Program Files (x86)\Google\Chrome\Application\chrome.exe',
    ],
  ),
  _BrowserPath(
    id: 'firefox',
    exeName: 'firefox.exe',
    displayName: 'Firefox',
    candidatePaths: <String>[
      r'C:\Program Files\Mozilla Firefox\firefox.exe',
      r'C:\Program Files (x86)\Mozilla Firefox\firefox.exe',
    ],
  ),
  _BrowserPath(
    id: 'brave',
    exeName: 'brave.exe',
    displayName: 'Brave',
    candidatePaths: <String>[
      r'C:\Program Files\BraveSoftware\Brave-Browser\Application\brave.exe',
      r'C:\Program Files (x86)\BraveSoftware\Brave-Browser\Application\brave.exe',
    ],
  ),
  _BrowserPath(
    id: 'vivaldi',
    exeName: 'vivaldi.exe',
    displayName: 'Vivaldi',
    candidatePaths: <String>[
      r'C:\Program Files\Vivaldi\Application\vivaldi.exe',
      r'C:\Program Files (x86)\Vivaldi\Application\vivaldi.exe',
    ],
  ),
];

/// Opens an external link safely — never lets a click vanish because the
/// system default browser is in an active app-block schedule.
///
/// Flow:
///   1. Resolve active app-block exe names.
///   2. Resolve the OS default browser exe name.
///   3. If the default is NOT blocked → `launchUrl(externalApplication)`.
///   4. Otherwise → enumerate installed browsers, drop the blocked ones,
///      and either (a) launch the single survivor directly, or (b) show
///      a picker dialog so the user chooses which browser to use.
///   5. If nothing survives → "no usable browser" dialog with a Windows
///      settings deep-link so the user can change their default.
final class SafeExternalLinkService {
  SafeExternalLinkService._();
  static final SafeExternalLinkService instance = SafeExternalLinkService._();

  /// Caches the on-disk install probe — `which-browsers-exist-here`
  /// rarely changes during a session, and probing it does ~6 file existence
  /// checks. Lasts a minute.
  Map<String, _ResolvedBrowser>? _installedCache;
  DateTime? _installedAt;
  static const Duration _installedTtl = Duration(minutes: 1);

  /// Opens [uri] in a browser that is **currently not blocked** by any
  /// active schedule / quick-block / maintenance window. Surfaces an
  /// in-app picker when fallback is needed. Returns `true` on launch.
  Future<bool> open(Uri uri, {BuildContext? context}) async {
    if (!Platform.isWindows) {
      return launchUrl(uri, mode: LaunchMode.externalApplication);
    }
    try {
      final Set<String> blocked = await _blockedExesNow();
      final String? defaultExe = await _resolveDefaultBrowserExe();
      if (defaultExe == null || !blocked.contains(defaultExe.toLowerCase())) {
        // Default browser is fine — use the normal path. This is the
        // fast happy case and avoids the cost of enumerating installs.
        try {
          final bool ok = await launchUrl(
            uri,
            mode: LaunchMode.externalApplication,
          );
          if (ok) return true;
        } catch (_) {/* fall through to picker */}
      } else {
        AppLogger.instance.info(
          'safe_link: default browser ($defaultExe) is in active block — '
          'routing to picker',
        );
        // The user just tried to open a web link through a blocked
        // default browser — escalate to the Settings page (bypasses the
        // 25-min cooldown). This is the single most important place to
        // surface it because the user JUST EXPERIENCED the failure.
        unawaited(
          DefaultBrowserPromoterService.instance.reactToBrowserKill(
            imageName: defaultExe,
            reasonKo: '링크 열기 차단 — 기본 브라우저가 차단 스케줄에 포함됨',
          ),
        );
      }

      final Map<String, _ResolvedBrowser> installed =
          await _resolveInstalledBrowsers();
      final List<_ResolvedBrowser> usable = installed.values
          .where(
            (_ResolvedBrowser b) => !blocked.contains(b.exeName.toLowerCase()),
          )
          .toList(growable: false);

      if (usable.isEmpty) {
        // _surfaceNoUsableBrowser does its own mounted check + falls back
        // to the root navigator when the caller context is dead.
        // ignore: use_build_context_synchronously
        await _surfaceNoUsableBrowser(context, defaultExe);
        return false;
      }

      // BuildContext may have unmounted across the await chain above —
      // capture it once and only re-enter the picker if it's still live.
      final BuildContext? liveCtx =
          (context != null && context.mounted) ? context : null;
      if (usable.length == 1 || liveCtx == null) {
        final _ResolvedBrowser only = usable.first;
        await _launchWith(only, uri);
        BlockActivityLogService.instance.record(
          kind: BlockActivityKind.protection,
          message: '링크 우회 실행: ${only.displayName} (기본 브라우저 차단 중)',
          data: <String, Object?>{
            'browser': only.id,
            'url': uri.toString(),
            'reason': 'default_browser_blocked',
          },
          debounceKey: 'safe_link_${only.id}',
        );
        return true;
      }

      // liveCtx was just .mounted-checked one line above, no await between.
      final _ResolvedBrowser? chosen = await _showPicker(
        // ignore: use_build_context_synchronously
        liveCtx,
        usable,
        defaultExe,
      );
      if (chosen == null) return false;
      await _launchWith(chosen, uri);
      BlockActivityLogService.instance.record(
        kind: BlockActivityKind.protection,
        message:
            '링크 우회 실행: ${chosen.displayName} (사용자 선택, 기본 브라우저 차단 중)',
        data: <String, Object?>{
          'browser': chosen.id,
          'url': uri.toString(),
          'reason': 'user_picked_after_block',
        },
        debounceKey: 'safe_link_picked_${chosen.id}',
      );
      return true;
    } catch (e, st) {
      AppLogger.instance.warn('safe_link open failed: $e\n$st');
      return false;
    }
  }

  Future<Set<String>> _blockedExesNow() async {
    try {
      final List<ActiveAppBlockEntry> entries =
          await ActiveAppBlockRegistryService.instance.activeEntriesNow();
      final Set<String> out = <String>{};
      for (final ActiveAppBlockEntry e in entries) {
        final String exe = e.app.exeName.toLowerCase().trim();
        if (exe.isNotEmpty) out.add(exe);
      }
      return out;
    } catch (e) {
      AppLogger.instance.warn('safe_link: blockedExesNow failed: $e');
      return const <String>{};
    }
  }

  Future<String?> _resolveDefaultBrowserExe() async {
    try {
      // Reuse the existing detector but ignore its advisory shape — we
      // only want the browserId → image-name mapping.
      final DefaultBrowserAdvisory? adv =
          await WindowsDefaultBrowserService.instance
              .detect(targets: const <EcosystemTargetRow>[]);
      final String? id = adv?.browserId;
      if (id == null || id.isEmpty || id == 'unknown') return null;
      for (final _BrowserPath b in _kKnownBrowsers) {
        if (b.id == id) return b.exeName;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<Map<String, _ResolvedBrowser>> _resolveInstalledBrowsers() async {
    final DateTime now = DateTime.now();
    if (_installedCache != null &&
        _installedAt != null &&
        now.difference(_installedAt!) < _installedTtl) {
      return _installedCache!;
    }
    final Map<String, _ResolvedBrowser> out = <String, _ResolvedBrowser>{};
    for (final _BrowserPath b in _kKnownBrowsers) {
      String? hit;
      for (final String candidate in b.candidatePaths) {
        if (await File(candidate).exists()) {
          hit = candidate;
          break;
        }
      }
      hit ??= await _resolveAppPaths(b.exeName);
      if (hit == null) continue;
      out[b.id] = _ResolvedBrowser(
        id: b.id,
        exeName: b.exeName,
        displayName: b.displayName,
        exePath: hit,
      );
    }
    _installedCache = out;
    _installedAt = now;
    return out;
  }

  /// Last-resort install discovery — the per-application registry key
  /// `HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\<exe>` is
  /// the canonical "where is this exe?" lookup on Windows and survives
  /// non-standard install locations.
  Future<String?> _resolveAppPaths(String exeName) async {
    try {
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final String reg = p.join(windir, 'System32', 'reg.exe');
      const List<String> roots = <String>['HKLM', 'HKCU'];
      const List<String> wow = <String>['', r'\WOW6432Node'];
      for (final String root in roots) {
        for (final String w in wow) {
          final String key =
              '$root\\SOFTWARE$w\\Microsoft\\Windows\\CurrentVersion\\App Paths\\$exeName';
          final ProcessResult r = await windowsRunHidden(
            reg,
            <String>['query', key, '/ve'],
          );
          if (r.exitCode != 0) continue;
          final RegExpMatch? m =
              RegExp(r'REG_SZ\s+(.+\.exe)\s*$', multiLine: true)
                  .firstMatch('${r.stdout}');
          final String? path = m?.group(1)?.trim();
          if (path != null && await File(path).exists()) return path;
        }
      }
    } catch (_) {/* fall through */}
    return null;
  }

  Future<void> _launchWith(_ResolvedBrowser b, Uri uri) async {
    AppLogger.instance.info(
      'safe_link: launching ${b.displayName} ${b.exePath} for $uri',
    );
    await Process.start(
      b.exePath,
      <String>[uri.toString()],
      mode: ProcessStartMode.detached,
    );
  }

  Future<_ResolvedBrowser?> _showPicker(
    BuildContext context,
    List<_ResolvedBrowser> usable,
    String? blockedDefaultExe,
  ) async {
    if (!context.mounted) return null;
    return showDialog<_ResolvedBrowser>(
      context: context,
      builder: (BuildContext ctx) => _BrowserPickerDialog(
        usable: usable,
        blockedDefaultExe: blockedDefaultExe,
      ),
    );
  }

  Future<void> _surfaceNoUsableBrowser(
    BuildContext? context,
    String? blockedDefaultExe,
  ) async {
    BlockActivityLogService.instance.record(
      kind: BlockActivityKind.protection,
      message: '링크 열기 실패 — 사용 가능한 브라우저 없음 (기본=${blockedDefaultExe ?? "?"})',
      level: 'warn',
      data: <String, Object?>{'blockedDefault': blockedDefaultExe},
      debounceKey: 'safe_link_no_usable',
    );
    final BuildContext? ctx = context ?? appRootNavigatorKey.currentContext;
    if (ctx == null || !ctx.mounted) return;
    await showDialog<void>(
      context: ctx,
      builder: (BuildContext c) {
        return Dialog(
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
          child: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                // Header
                Container(
                  padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
                  decoration: BoxDecoration(
                    color: AppColors.danger.withOpacity(0.06),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(16),
                      topRight: Radius.circular(16),
                    ),
                    border: Border(
                      bottom: BorderSide(
                          color: AppColors.danger.withOpacity(0.18)),
                    ),
                  ),
                  child: Row(
                    children: <Widget>[
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: AppColors.danger.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: const Icon(
                          Icons.browser_not_supported_outlined,
                          color: AppColors.danger,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Text(
                          '열 수 있는 브라우저가 없습니다',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: AppColors.ink,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                // Body
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        blockedDefaultExe != null
                            ? 'PC에 설치된 브라우저(기본: $blockedDefaultExe 포함) 모두 지금 '
                                '차단 스케줄에 포함되어 있어 링크를 열 수 없습니다.'
                            : '설치된 브라우저가 모두 차단 중입니다.',
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.muted,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppColors.warning.withOpacity(0.06),
                          borderRadius: BorderRadius.circular(9),
                          border: Border.all(
                              color: AppColors.warning.withOpacity(0.22)),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            const Text(
                              '해결 방법',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: AppColors.warning,
                                letterSpacing: 0.3,
                              ),
                            ),
                            const SizedBox(height: 8),
                            const Text(
                              '① 차단 스케줄을 일시 해제하거나',
                              style: TextStyle(
                                  fontSize: 12, color: AppColors.ink),
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              '② 차단 목록에 없는 브라우저를 설치하고\n   Windows 기본 브라우저로 설정하세요.',
                              style: TextStyle(
                                  fontSize: 12, color: AppColors.ink),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
                // Footer
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: <Widget>[
                      TextButton(
                        onPressed: () => Navigator.of(c).pop(),
                        child: const Text('확인'),
                      ),
                      const SizedBox(width: 6),
                      FilledButton.icon(
                        onPressed: () async {
                          Navigator.of(c).pop();
                          try {
                            await launchUrl(
                                Uri.parse('ms-settings:defaultapps'));
                          } catch (_) {}
                        },
                        style: FilledButton.styleFrom(
                          backgroundColor: AppColors.accent,
                          foregroundColor: Colors.white,
                        ),
                        icon: const Icon(Icons.settings_outlined, size: 15),
                        label: const Text(
                          '기본 앱 설정 열기',
                          style: TextStyle(fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _BrowserPath {
  const _BrowserPath({
    required this.id,
    required this.exeName,
    required this.displayName,
    required this.candidatePaths,
  });

  final String id;
  final String exeName;
  final String displayName;
  final List<String> candidatePaths;
}

class _ResolvedBrowser {
  const _ResolvedBrowser({
    required this.id,
    required this.exeName,
    required this.displayName,
    required this.exePath,
  });

  final String id;
  final String exeName;
  final String displayName;
  final String exePath;
}

/// Branded picker dialog shown when the default browser is blocked.
///
/// Top: orange-tinted header with browser name.
/// Middle: bordered browser item tiles (tap = open link now).
/// Bottom: teal tip box with per-browser "기본값으로 설정" buttons.
class _BrowserPickerDialog extends StatelessWidget {
  const _BrowserPickerDialog({
    required this.usable,
    required this.blockedDefaultExe,
  });

  final List<_ResolvedBrowser> usable;
  final String? blockedDefaultExe;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
      child: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            // ── Header ────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
              decoration: BoxDecoration(
                color: AppColors.warning.withOpacity(0.07),
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(16),
                  topRight: Radius.circular(16),
                ),
                border: Border(
                  bottom:
                      BorderSide(color: AppColors.warning.withOpacity(0.18)),
                ),
              ),
              child: Row(
                children: <Widget>[
                  const Icon(
                    Icons.swap_horiz_rounded,
                    color: AppColors.warning,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    '기본 브라우저 차단 중',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.ink,
                    ),
                  ),
                ],
              ),
            ),

            // ── Body ──────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    blockedDefaultExe != null
                        ? '$blockedDefaultExe이(가) 차단 스케줄에 포함되어 있습니다. '
                            '지금 열 브라우저를 선택해 주세요.'
                        : '기본 브라우저로 열 수 없습니다. 아래에서 골라주세요.',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.muted,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 10),
                  // Browser item tiles
                  for (final _ResolvedBrowser b in usable)
                    _BrowserTile(browser: b),
                  const SizedBox(height: 12),
                  // Tip box
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppColors.accent.withOpacity(0.05),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: AppColors.accent.withOpacity(0.22)),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Row(
                          children: <Widget>[
                            Icon(
                              Icons.lightbulb_outline,
                              size: 13,
                              color: AppColors.accent,
                            ),
                            SizedBox(width: 5),
                            Text(
                              '매번 선택하기 번거로우세요?',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: AppColors.accent,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 5),
                        const Text(
                          '위 브라우저를 기본값으로 설정하면 다음부터 자동으로 열립니다.',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.muted,
                            height: 1.45,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: <Widget>[
                            for (final _ResolvedBrowser b in usable)
                              _SetDefaultButton(browser: b),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                ],
              ),
            ),

            // ── Footer ────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
              child: Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: TextButton.styleFrom(
                    foregroundColor: AppColors.muted,
                  ),
                  child: const Text('취소', style: TextStyle(fontSize: 13)),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Single browser row inside [_BrowserPickerDialog].
class _BrowserTile extends StatelessWidget {
  const _BrowserTile({required this.browser});
  final _ResolvedBrowser browser;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: InkWell(
        onTap: () => Navigator.of(context).pop(browser),
        borderRadius: BorderRadius.circular(9),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            border: Border.all(color: AppColors.muted.withOpacity(0.25)),
            borderRadius: BorderRadius.circular(9),
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: AppColors.accent.withOpacity(0.08),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: const Icon(
                  Icons.language_outlined,
                  size: 17,
                  color: AppColors.accent,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      browser.displayName,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: AppColors.ink,
                      ),
                    ),
                    Text(
                      browser.exeName,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.muted,
                      ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right,
                size: 18,
                color: AppColors.muted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Small "기본값으로 설정" button inside the tip box.
class _SetDefaultButton extends StatelessWidget {
  const _SetDefaultButton({required this.browser});
  final _ResolvedBrowser browser;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        foregroundColor: AppColors.accent,
        side: const BorderSide(color: AppColors.accent, width: 0.8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        textStyle: const TextStyle(fontSize: 11),
        visualDensity: VisualDensity.compact,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(7)),
      ),
      icon: const Icon(Icons.open_in_new, size: 12),
      label: Text('${browser.displayName}을(를) 기본값으로'),
      onPressed: () async {
        final String uri =
            'ms-settings:defaultapps?registeredAppUser='
            '${Uri.encodeComponent(browser.displayName)}';
        final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
        final String cmdExe = p.join(windir, 'System32', 'cmd.exe');
        try {
          await windowsRunHidden(cmdExe, <String>['/c', 'start', '', uri]);
        } catch (_) {}
        if (context.mounted) {
          Navigator.of(context).pop();
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(
              content: Text(
                '설정 창에서 "${browser.displayName}" 항목을 찾아 '
                '"기본값으로 설정"을 눌러주세요.',
              ),
              duration: const Duration(seconds: 8),
            ),
          );
        }
      },
    );
  }
}
