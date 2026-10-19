import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:go_router/go_router.dart';
import '../services/chatgpt_plan_service.dart';
import '../services/chatgpt_sign_in_service.dart';
import 'brainwire_sync_settings_card.dart';

/// Persistent account entry points above every Windows workspace page.
class AccountActions extends StatelessWidget {
  const AccountActions({super.key});
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
    child: Align(
      alignment: Alignment.centerRight,
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        children: [
          OutlinedButton.icon(
            key: const Key('bluecloud-account'),
            icon: const Icon(Icons.cloud_outlined, size: 18),
            label: const Text('블루클라우드 로그인'),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('블루클라우드 계정'),
                content: const SizedBox(
                  width: 440,
                  child: SingleChildScrollView(
                    child: BrainwireSyncSettingsCard(),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('닫기'),
                  ),
                ],
              ),
            ),
          ),
          FilledButton.tonalIcon(
            key: const Key('ai-account'),
            icon: const Icon(Icons.auto_awesome_outlined, size: 18),
            label: const Text('GPT · AI 로그인'),
            onPressed: () => showAiConnectionDialog(context),
          ),
        ],
      ),
    ),
  );
}

Future<void> showAiConnectionDialog(BuildContext context) => showDialog<void>(
  context: context,
  builder: (_) => const AiConnectionDialog(),
);

class AiConnectionDialog extends StatefulWidget {
  const AiConnectionDialog({super.key});
  @override
  State<AiConnectionDialog> createState() => _AiConnectionDialogState();
}

class _AiConnectionDialogState extends State<AiConnectionDialog> {
  final _key = TextEditingController();
  bool _busy = false, _plan = false, _api = false;
  String? _email, _error;
  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    try {
      final plan = await ChatGptSignInService.instance.isConnected;
      final email = await ChatGptSignInService.instance.accountEmail;
      final api = await ChatGptPlanService.instance.hasApiKey;
      if (mounted) {
        setState(() {
          _plan = plan;
          _email = email;
          _api = api;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = '연결 상태를 읽지 못했습니다. 다시 열어주세요.');
    }
  }

  Future<void> _run(Future<void> Function() work) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await work();
      await _refresh();
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = e is FormatException
              ? '로그인 정보를 검증하지 못했습니다. 다시 로그인해 주세요.'
              : e.toString().replaceFirst('Bad state: ', ''),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('GPT · AI 연결'),
    content: SizedBox(
      width: 460,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('AI와 대화해 차단 스케줄을 만들 수 있어요. 적용 전 미리보기를 확인합니다.'),
            const SizedBox(height: 16),
            Text(
              _plan ? 'ChatGPT 연결됨 · ${_email ?? '계정'}' : 'ChatGPT 계정',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            const Text(
              '브라우저에서 로그인하고 ChatGPT 요금제 사용 권한을 승인합니다. 지원되는 계정·요금제에서 사용할 수 있습니다.',
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: _busy
                  ? null
                  : () => _run(ChatGptSignInService.instance.signIn),
              icon: const Icon(Icons.login),
              label: const Text('Continue with ChatGPT'),
            ),
            if (_plan)
              TextButton(
                onPressed: _busy
                    ? null
                    : () => _run(ChatGptSignInService.instance.signOut),
                child: const Text('ChatGPT 연결 해제'),
              ),
            if (_plan)
              TextButton(
                onPressed: () => launchUrl(
                  Uri.parse('https://chatgpt.com/#settings'),
                  mode: LaunchMode.externalApplication,
                ),
                child: const Text('ChatGPT 사용량·연결 관리'),
              ),
            const Divider(height: 28),
            Text(
              _api ? 'OpenAI API 연결됨' : 'OpenAI API 키로 연결',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const Text(
              'API 사용료는 ChatGPT 구독과 별도입니다. 키는 이 PC 보안 저장소에만 저장합니다. 요청과 최근 대화는 선택한 AI 연결을 통해 OpenAI로 전송됩니다.',
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _key,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'OpenAI API 키',
                hintText: 'sk-…',
              ),
            ),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: _busy
                      ? null
                      : () => _run(() async {
                          await ChatGptPlanService.instance.setApiKey(
                            _key.text,
                          );
                          _key.clear();
                        }),
                  child: const Text('키 확인 및 저장'),
                ),
                if (_api)
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _run(ChatGptPlanService.instance.signOut),
                    child: const Text('API 연결 해제'),
                  ),
                TextButton(
                  onPressed: () => launchUrl(
                    Uri.parse('https://platform.openai.com/api-keys'),
                    mode: LaunchMode.externalApplication,
                  ),
                  child: const Text('API 키 관리'),
                ),
              ],
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Expanded(child: Text('연결 중… 브라우저의 로그인·승인을 완료해 주세요.')),
                  ],
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('닫기'),
      ),
      FilledButton(
        onPressed: _busy
            ? null
            : () {
                Navigator.pop(context);
                context.go('/chat');
              },
        child: const Text('AI 채팅 열기'),
      ),
    ],
  );
}
