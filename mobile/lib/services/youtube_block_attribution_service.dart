import 'dart:io';

import 'package:path/path.dart' as p;

import 'builtin_block_domains.dart';
import 'local_database.dart';
import 'mandatory_youtube_block_service.dart';
import 'windows_hidden_process.dart';

/// Explains **why** `youtube.com` / `youtu.be` are blocked — built-in vs user rules.
final class YoutubeBlockSource {
  const YoutubeBlockSource({
    required this.layer,
    required this.title,
    required this.detail,
    required this.active,
    this.removable = false,
  });

  final String layer;
  final String title;
  final String detail;
  final bool active;
  final bool removable;
}

abstract final class YoutubeBlockAttributionService {
  static Future<List<YoutubeBlockSource>> explain({
    String host = 'youtube.com',
  }) async {
    final String apex = host.toLowerCase().replaceFirst(RegExp(r'^www\.'), '');
    final List<YoutubeBlockSource> out = <YoutubeBlockSource>[];

    final bool builtinYoutube = kExtensionBuiltinBlockedDomains.contains(apex) ||
        kExtensionBuiltinBlockedDomains.contains('youtube.com');
    out.add(
      YoutubeBlockSource(
        layer: 'builtin',
        title: '앱 내장 기본 차단',
        detail: builtinYoutube
            ? 'builtin_block_domains.dart — apex가 내장 차단 목록에 들어 있습니다.'
            : '없음. youtube.com / youtu.be 자체는 차단되지 않습니다 '
                '(채널·영상 단위 차단은 mandatory · 사용자 규칙 레이어에서 적용).',
        active: builtinYoutube && (apex == 'youtube.com' || apex == 'youtu.be'),
        removable: false,
      ),
    );

    final List<String> mandatory =
        await MandatoryYoutubeBlockService.instance.patterns();
    out.add(
      YoutubeBlockSource(
        layer: 'mandatory',
        title: '필수 YouTube 채널·영상',
        detail: mandatory.isEmpty
            ? 'mandatory_youtube_blocks.txt — (없음)'
            : 'mandatory_youtube_blocks.txt — ${mandatory.length}줄 '
                '(특정 watch?v= · @채널만, apex 전체 아님)',
        active: mandatory.isNotEmpty,
        removable: false,
      ),
    );

    if (Platform.isWindows || Platform.isMacOS) {
      final List<Map<String, Object?>> qbRows =
          await LocalDatabase.instance.allDomainsQuickBlock();
      final List<String> qbYoutubeHosts = qbRows
          .map((Map<String, Object?> r) =>
              (r['host'] as String? ?? '').trim().toLowerCase())
          .where(
            (String h) =>
                h == 'youtube.com' ||
                h == 'youtu.be' ||
                h.endsWith('.youtube.com'),
          )
          .toList();
      out.add(
        YoutubeBlockSource(
          layer: 'quick_block',
          title: '퀵 블록 DB (영상·SNS 등)',
          detail: qbYoutubeHosts.isEmpty
              ? 'quick_block source 도메인 — youtube 없음'
              : 'quick_block — ${qbYoutubeHosts.join(', ')} (해제 시 퀵블록에서 제거)',
          active: qbYoutubeHosts.isNotEmpty,
          removable: true,
        ),
      );

      final List<Map<String, Object?>> domains =
          await LocalDatabase.instance.domains();
      final List<String> userYoutube = domains
          .where((Map<String, Object?> r) => (r['enabled'] as int? ?? 0) == 1)
          .map((Map<String, Object?> r) =>
              (r['host'] as String? ?? '').trim().toLowerCase())
          .where(
            (String h) =>
                h == 'youtube.com' ||
                h == 'youtu.be' ||
                h.endsWith('.youtube.com'),
          )
          .toList();
      out.add(
        YoutubeBlockSource(
          layer: 'user_db',
          title: '내가 추가한 도메인 규칙',
          detail: userYoutube.isEmpty
              ? 'DB domains — youtube 관련 없음'
              : 'DB domains — ${userYoutube.join(', ')}',
          active: userYoutube.isNotEmpty,
          removable: true,
        ),
      );

      if (Platform.isWindows) {
        final bool urlBl = await _urlBlocklistHasYoutube();
        out.add(
          YoutubeBlockSource(
            layer: 'url_blocklist',
            title: 'Chrome/Edge URLBlocklist',
            detail: urlBl
                ? '*://*.youtube.com/* · *://youtu.be/* — 브라우저 정책(확장 없어도 차단)'
                : 'URLBlocklist에 youtube 패턴 없음 — 원탭 적용 필요',
            active: urlBl,
            removable: false,
          ),
        );

        final bool pacYt = await _pacHasYoutube();
        out.add(
          YoutubeBlockSource(
            layer: 'pac',
            title: 'PAC 프록시 (sixvpn_block.pac)',
            detail: pacYt
                ? 'youtube.com / youtu.be → PROXY 차단 규칙 포함'
                : 'PAC 파일 없거나 youtube 규칙 없음',
            active: pacYt,
            removable: false,
          ),
        );

        final bool hostsSink =
            await _hostsFileContainsYoutubeApex();
        out.add(
          YoutubeBlockSource(
            layer: 'hosts',
            title: 'Windows hosts (DNS)',
            detail: hostsSink
                ? 'hosts에 0.0.0.0 youtube.com — UAC 적용 시 (드묾, apex는 보통 제외)'
                : 'hosts apex youtube 없음 — DNS는 열림, 브라우저 정책·확장으로 차단',
            active: hostsSink,
            removable: true,
          ),
        );
      }
    }

    return out.where((YoutubeBlockSource s) => s.active).toList();
  }

  static Future<bool> _urlBlocklistHasYoutube() async {
    try {
      final String local = Platform.environment['LOCALAPPDATA'] ?? '';
      final File patterns = File(
        p.join(local, 'SixVPNBlocker', 'policy_batch', 'url_blocklist_patterns.json'),
      );
      if (await patterns.exists()) {
        final String raw = await patterns.readAsString();
        return raw.toLowerCase().contains('youtube.com');
      }
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      // windowsRunHidden (CREATE_NO_WINDOW) — a bare Process.run on reg.exe pops
      // a black console flash, which is exactly what makes the app look like a
      // virus to the user. See windows_background_components_service.dart.
      final ProcessResult pr = await windowsRunHidden(
        p.join(windir, 'System32', 'reg.exe'),
        <String>[
          'query',
          r'HKCU\SOFTWARE\Policies\Google\Chrome\URLBlocklist',
          '/s',
        ],
      );
      final String out = '${pr.stdout}'.toLowerCase();
      return out.contains('youtube.com') || out.contains('youtu.be');
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _pacHasYoutube() async {
    try {
      final String local = Platform.environment['LOCALAPPDATA'] ?? '';
      final File pac = File(p.join(local, 'SixVPNBlocker', 'sixvpn_block.pac'));
      if (!await pac.exists()) return false;
      final String raw = (await pac.readAsString()).toLowerCase();
      return raw.contains('youtube.com') || raw.contains('youtu.be');
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _hostsFileContainsYoutubeApex() async {
    try {
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final File hosts = File(
        p.join(windir, 'System32', 'drivers', 'etc', 'hosts'),
      );
      if (!await hosts.exists()) return false;
      final String blob = (await hosts.readAsString()).toLowerCase();
      return RegExp(r'0\.0\.0\.0\s+youtube\.com\b').hasMatch(blob) ||
          RegExp(r'0\.0\.0\.0\s+www\.youtube\.com\b').hasMatch(blob);
    } catch (_) {
      return false;
    }
  }

  static Future<String> summaryLine() async {
    final List<YoutubeBlockSource> active = await explain();
    if (active.isEmpty) {
      return 'youtube.com — 활성 차단 규칙 없음 (내장 목록 확인 필요)';
    }
    final List<String> names =
        active.map((YoutubeBlockSource s) => s.title).toList();
    return 'youtube.com 차단: ${names.join(' · ')}';
  }
}
