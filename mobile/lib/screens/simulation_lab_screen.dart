import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/pending_share_ingest.dart';
import '../services/simulated_share_actions.dart';
import '../theme/app_colors.dart';

/// 유료 Apple 계정 없이 **차단·공유 적재** 흐름을 WebView로 확인하는 연습장.
/// 브라우저 확장이 하는 것과 비슷한 “후처리” 개념을 데스크톱에서 익힐 수 있습니다.
class SimulationLabScreen extends StatefulWidget {
  const SimulationLabScreen({super.key});

  @override
  State<SimulationLabScreen> createState() => _SimulationLabScreenState();
}

class _SimulationLabScreenState extends State<SimulationLabScreen> {
  late final WebViewController _web = WebViewController()
    ..setJavaScriptMode(JavaScriptMode.unrestricted)
    ..setBackgroundColor(const Color(0xFF0B1220))
    ..loadHtmlString(_demoHtml);

  final TextEditingController _hostCtrl = TextEditingController(text: 'blocked-demo.test');
  bool _fullPageMask = false;

  static const String _demoHtml = '''
<!DOCTYPE html>
<html>
<head>
<meta name="viewport" content="width=device-width, initial-scale=1" />
<style>
  body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; padding: 16px; color: #e6eaf2; background: #0b1220; }
  .hint { color: #8b95a8; font-size: 14px; margin-top: 24px; }
  .redact { background: rgba(94,234,212,0.15); padding: 2px 6px; border-radius: 4px; }
</style>
</head>
<body>
  <h2>가짜 웹 페이지</h2>
  <p>일반 문장입니다. <span id="w" class="redact">악성키워드</span>는 시뮬에서 가릴 수 있습니다.</p>
  <p class="hint">아래 버튼은 Flutter가 이 WebView에 JavaScript를 주입해 텍스트를 바꿉니다. (브라우저 확장과 유사한 “후처리” 느낌)</p>
</body>
</html>
''';

  @override
  void dispose() {
    _hostCtrl.dispose();
    super.dispose();
  }

  Future<void> _redactKeyword() async {
    await _web.runJavaScript(
      r"(function(){var n=document.getElementById('w');if(n)n.innerText='████';})();",
    );
  }

  Future<void> _simulateShare() async {
    final actions = SimulatedShareActions();
    await actions.appendHost(_hostCtrl.text);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('pending_share_hosts.json 에 호스트를 쌓았습니다. 앱으로 돌아가 ingest와 동일합니다.')),
    );
    final n = await PendingShareIngest().ingestIfNeeded();
    if (!mounted) return;
    if (n > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('ingest로 DB에 $n개 반영됨')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('연습장 · 시뮬레이션'),
        backgroundColor: AppColors.background,
      ),
      backgroundColor: AppColors.background,
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: <Widget>[
          Text(
            Platform.isWindows
                ? '규칙 → 가리기 / 공유 적재 흐름을 여기서 연습합니다. '
                    '(Chrome·Edge·Firefox 확장이 하는 것과 비슷한 “후처리” 개념입니다.)'
                : 'Safari 없이도 “규칙 → 가리기 / 공유 적재” 감각을 익힙니다.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppColors.muted),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 220,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  WebViewWidget(controller: _web),
                  if (_fullPageMask)
                    Container(
                      color: const Color(0xE60B1220),
                      alignment: Alignment.center,
                      child: const Padding(
                        padding: EdgeInsets.all(16),
                        child: Text(
                          '전면 차단 오버레이 시뮬\n(실제 확장은 declarativeNetRequest 등으로 네트워크를 막습니다)',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: AppColors.ink, height: 1.35),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              FilledButton.tonal(
                onPressed: _redactKeyword,
                child: const Text('키워드 가리기 JS 주입'),
              ),
              FilledButton.tonal(
                onPressed: () => setState(() => _fullPageMask = !_fullPageMask),
                child: Text(_fullPageMask ? '전면 가림 끄기' : '전면 가림 켜기'),
              ),
            ],
          ),
          const Divider(height: 36),
          Text('공유 시트 시뮬', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          TextField(
            controller: _hostCtrl,
            decoration: const InputDecoration(
              labelText: '차단할 호스트',
              hintText: 'example.com',
            ),
            keyboardType: TextInputType.url,
            autocorrect: false,
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _simulateShare,
            child: const Text('공유로 이 호스트를 보냈다고 가정'),
          ),
        ],
      ),
    );
  }
}
