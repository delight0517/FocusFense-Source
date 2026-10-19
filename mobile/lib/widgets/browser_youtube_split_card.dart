import 'dart:async';

import 'package:flutter/material.dart';

import '../services/chrome_gmail_gemini_allowlist_service.dart';
import '../services/universal_browser_block_service.dart';
import '../services/unprotected_browser_kill_guard_prefs.dart';
import '../theme/app_colors.dart';

/// Settings → 진단: Firefox는 채널·영상만, Chrome/Edge는 YouTube 전체 차단 +
/// Chrome Gmail/Gemini 예외.
class BrowserYoutubeSplitCard extends StatefulWidget {
  const BrowserYoutubeSplitCard({super.key});

  @override
  State<BrowserYoutubeSplitCard> createState() =>
      _BrowserYoutubeSplitCardState();
}

class _BrowserYoutubeSplitCardState extends State<BrowserYoutubeSplitCard> {
  bool _loading = true;
  bool _gmailGeminiOnly = true;
  bool _killUnprotected = true;
  bool _applying = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final bool on = await ChromeGmailGeminiAllowlistService.instance.enabled();
    final bool kill =
        await UnprotectedBrowserKillGuardPrefs.instance.enabled();
    if (!mounted) return;
    setState(() {
      _gmailGeminiOnly = on;
      _killUnprotected = kill;
      _loading = false;
    });
  }

  Future<void> _toggle(bool value) async {
    setState(() {
      _gmailGeminiOnly = value;
      _applying = true;
    });
    await ChromeGmailGeminiAllowlistService.instance.setEnabled(value);
    if (value) {
      await ChromeGmailGeminiAllowlistService.instance.applyNow();
    } else {
      await ChromeGmailGeminiAllowlistService.instance.removeNow();
    }
    await UniversalBrowserBlockService.instance.syncNow(
      reason: 'gmail_gemini_toggle',
    );
    if (!mounted) return;
    setState(() => _applying = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          value
              ? 'Chrome: Gmail·Gemini·로그인만 허용 · Edge 등: YouTube 전체 차단'
              : 'Chrome Gmail/Gemini 예외 해제 — 일반 URLBlocklist로 복귀',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppColors.accent.withValues(alpha: 0.08),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.language, color: AppColors.accent, size: 22),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    '브라우저별 YouTube · Chrome 예외',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                ),
                if (_applying)
                  const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            const Text(
              'Firefox — 채널→영상 차단만 (유튜브 홈·다른 채널은 열림)\n'
              'Chrome / Edge / Whale / Brave — youtube.com 전체 비활성화\n'
              'Chrome 예외 — Gmail · Gemini · Google 로그인만 허용',
              style: TextStyle(fontSize: 13, height: 1.45),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Chrome: Gmail · Gemini만 사용'),
              subtitle: const Text(
                '켜면 Chrome에서 mail.google.com · gemini.google.com · '
                'accounts.google.com(로그인)만 열립니다.',
                style: TextStyle(fontSize: 12),
              ),
              value: _loading ? false : _gmailGeminiOnly,
              onChanged: _loading || _applying ? null : _toggle,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('URL 차단 없는 브라우저 즉시 종료'),
              subtitle: const Text(
                'Whale·Brave·Opera 등 URLBlocklist가 비어 있거나 '
                '음란물 규칙이 안 먹히면 프로세스를 닫습니다.',
                style: TextStyle(fontSize: 12),
              ),
              value: _loading ? true : _killUnprotected,
              onChanged: _loading || _applying
                  ? null
                  : (bool v) async {
                      setState(() => _killUnprotected = v);
                      await UnprotectedBrowserKillGuardPrefs.instance
                          .setEnabled(v);
                    },
            ),
          ],
        ),
      ),
    );
  }
}
