import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/uninstall_friction_policy_service.dart';
import '../services/unlock_code_vault_service.dart';

/// Single screen that walks the user through every state of the unlock vault:
/// first-time setup → request reveal → countdown → reveal → verify → unlocked.
/// Surfaces only the controls relevant to the current [VaultState].
class UnlockVaultScreen extends StatefulWidget {
  const UnlockVaultScreen({super.key});

  @override
  State<UnlockVaultScreen> createState() => _UnlockVaultScreenState();
}

class _UnlockVaultScreenState extends State<UnlockVaultScreen> {
  VaultStatus? _status;
  String? _revealedCode;
  Timer? _ticker;
  bool _busy = false;
  String? _flash;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final VaultStatus s = await UnlockCodeVaultService.instance.getStatus();
    final String? code = s.state == VaultState.revealable
        ? await UnlockCodeVaultService.instance.peekRevealedCode()
        : null;
    if (!mounted) return;
    setState(() {
      _status = s;
      _revealedCode = code;
    });
  }

  Future<void> _withBusy(Future<void> Function() body) async {
    setState(() => _busy = true);
    try {
      await body();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _refresh();
  }

  Future<void> _doSetup() async {
    final String? code = await showDialog<String>(
      context: context,
      builder: (_) => const _CodeSetupDialog(),
    );
    if (code == null || code.trim().length < 4) return;
    await _withBusy(() async {
      try {
        await UnlockCodeVaultService.instance.setupCode(code.trim());
      } catch (e) {
        _flash = '저장 실패: $e';
      }
    });
  }

  Future<void> _doRequestReveal() async {
    final int wait =
        await UninstallFrictionPolicyService.instance.getWaitSeconds();
    await _withBusy(() async {
      await UnlockCodeVaultService.instance.requestReveal(waitSeconds: wait);
      _flash = '대기 시작. 타이머가 끝나면 코드가 공개됩니다.';
    });
  }

  Future<void> _doVerify() async {
    final String? entered = await showDialog<String>(
      context: context,
      builder: (_) => const _CodeVerifyDialog(),
    );
    if (entered == null) return;
    await _withBusy(() async {
      final VerifyResult r =
          await UnlockCodeVaultService.instance.verifyCode(entered);
      switch (r.outcome) {
        case VerifyOutcome.correct:
          _flash = '잠금 해제. 10분 안에 수정하세요.';
        case VerifyOutcome.wrong:
          _flash = '코드가 다릅니다. 남은 시도 ${r.remainingAttempts}회.';
        case VerifyOutcome.lockedOut:
          _flash = '5회 실패. 다시 대기해야 합니다.';
        case VerifyOutcome.notRevealable:
          _flash = '아직 공개되지 않은 코드입니다.';
      }
    });
  }

  Future<void> _doCancelRequest() async {
    await _withBusy(() async {
      await UnlockCodeVaultService.instance.cancelRequest();
      _flash = '대기 취소됨.';
    });
  }

  Future<void> _doEndUnlock() async {
    await _withBusy(() async {
      await UnlockCodeVaultService.instance.endUnlockWindow();
      _flash = '잠금 다시 켜짐. 코드가 새 값으로 바뀌었습니다.';
    });
  }

  Future<void> _doReplaceCode() async {
    final String? code = await showDialog<String>(
      context: context,
      builder: (_) => const _CodeSetupDialog(replacing: true),
    );
    if (code == null || code.trim().length < 4) return;
    await _withBusy(() async {
      try {
        await UnlockCodeVaultService.instance.setupCode(code.trim());
        _flash = '새 코드로 교체됨.';
      } catch (e) {
        _flash = '교체 실패: $e';
      }
    });
  }

  String _fmt(Duration d) {
    final int total = d.inSeconds.clamp(0, 86400 * 7);
    final int h = total ~/ 3600;
    final int m = (total % 3600) ~/ 60;
    final int s = total % 60;
    if (h > 0) {
      return '$h시간 ${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final VaultStatus? s = _status;
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('잠금 코드')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: s == null
            ? const Center(child: CircularProgressIndicator())
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    '이 앱은 본인이 정한 코드를 저장하고 ‘일정 시간 뒤에만’ 보여줍니다. '
                    '수정/제거를 하려면 대기 후 본인이 정한 코드를 직접 입력해야 합니다.',
                    style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
                  ),
                  const SizedBox(height: 16),
                  _StateBadge(state: s.state),
                  const SizedBox(height: 16),
                  Expanded(child: _buildBody(theme, s)),
                  if (_flash != null) ...<Widget>[
                    const SizedBox(height: 8),
                    Text(
                      _flash!,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
      ),
    );
  }

  Widget _buildBody(ThemeData theme, VaultStatus s) {
    switch (s.state) {
      case VaultState.notConfigured:
        return _section(
          title: '첫 셋업이 필요합니다',
          description:
              '4글자 이상 코드를 정해주세요. 의도적으로 외우지 마세요 — 외운 즉시 보호 효과가 사라집니다. '
              '권장: 무작위로 키보드를 두드린 한 줄.',
          primary: ElevatedButton(
            onPressed: _busy ? null : _doSetup,
            child: const Text('코드 셋업'),
          ),
        );
      case VaultState.idle:
        return _section(
          title: '잠겨 있음',
          description:
              '코드 공개를 요청하면 대기 타이머가 시작됩니다. '
              '대기 길이는 [앱 제거 안내]의 대기 설정을 그대로 따라갑니다.',
          primary: ElevatedButton(
            onPressed: _busy ? null : _doRequestReveal,
            child: const Text('코드 공개 요청'),
          ),
        );
      case VaultState.pending:
        return _section(
          title: '대기 중',
          description: '남은 시간 동안 코드는 비공개입니다. 앱을 닫아도 타이머는 흐릅니다 (PC 재시작 시에만 초기화).',
          primary: Column(
            children: <Widget>[
              Text(
                _fmt(s.revealRemaining ?? Duration.zero),
                style: theme.textTheme.displaySmall?.copyWith(
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: _busy ? null : _doCancelRequest,
                child: const Text('요청 취소'),
              ),
            ],
          ),
        );
      case VaultState.revealable:
        return _section(
          title: '코드 공개됨',
          description: '아래 코드를 외운 뒤 ‘입력해 잠금 해제’를 누르세요. 5회 틀리면 다시 대기합니다.',
          primary: Column(
            children: <Widget>[
              SelectableText(
                _revealedCode ?? '…',
                style: theme.textTheme.displaySmall?.copyWith(
                  letterSpacing: 4,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 6),
              TextButton.icon(
                onPressed: _revealedCode == null
                    ? null
                    : () async {
                        await Clipboard.setData(
                            ClipboardData(text: _revealedCode!));
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('복사됨')),
                          );
                        }
                      },
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('복사'),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: _busy ? null : _doVerify,
                child: const Text('입력해 잠금 해제'),
              ),
              if (s.failedAttempts > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '틀린 횟수 ${s.failedAttempts} / ${UnlockCodeVaultService.kMaxFailedAttempts}',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        );
      case VaultState.unlocked:
        return _section(
          title: '잠금 해제됨',
          description: '${_fmt(s.unlockRemaining ?? Duration.zero)} 뒤에 자동으로 다시 잠깁니다. '
              '이 시간 안에 설정을 마치고, 원하면 새 코드로 교체할 수 있습니다.',
          primary: Column(
            children: <Widget>[
              ElevatedButton(
                onPressed: _busy ? null : _doReplaceCode,
                child: const Text('새 코드로 교체'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _busy ? null : _doEndUnlock,
                child: const Text('지금 다시 잠그기'),
              ),
            ],
          ),
        );
    }
  }

  Widget _section({
    required String title,
    required String description,
    required Widget primary,
  }) {
    return Center(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: 8),
            Text(
              description,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    height: 1.45,
                  ),
            ),
            const SizedBox(height: 20),
            primary,
          ],
        ),
      ),
    );
  }
}

class _StateBadge extends StatelessWidget {
  const _StateBadge({required this.state});
  final VaultState state;

  @override
  Widget build(BuildContext context) {
    late final String label;
    late final Color bg;
    switch (state) {
      case VaultState.notConfigured:
        label = '미설정';
        bg = Colors.grey;
      case VaultState.idle:
        label = '잠겨 있음';
        bg = Colors.indigo;
      case VaultState.pending:
        label = '대기 중';
        bg = Colors.orange;
      case VaultState.revealable:
        label = '코드 공개됨';
        bg = Colors.teal;
      case VaultState.unlocked:
        label = '잠금 해제됨';
        bg = Colors.green;
    }
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: bg.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: bg.withValues(alpha: 0.5)),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: bg,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.4,
          ),
        ),
      ),
    );
  }
}

class _CodeSetupDialog extends StatefulWidget {
  const _CodeSetupDialog({this.replacing = false});
  final bool replacing;

  @override
  State<_CodeSetupDialog> createState() => _CodeSetupDialogState();
}

class _CodeSetupDialogState extends State<_CodeSetupDialog> {
  final TextEditingController _a = TextEditingController();
  final TextEditingController _b = TextEditingController();
  String? _err;

  @override
  void dispose() {
    _a.dispose();
    _b.dispose();
    super.dispose();
  }

  void _ok() {
    final String a = _a.text.trim();
    final String b = _b.text.trim();
    if (a.length < 4) {
      setState(() => _err = '4글자 이상 입력해주세요.');
      return;
    }
    if (a != b) {
      setState(() => _err = '두 입력이 다릅니다.');
      return;
    }
    Navigator.of(context).pop(a);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.replacing ? '새 코드 교체' : '코드 셋업'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          TextField(
            controller: _a,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '코드 입력',
              hintText: '키보드를 무작위로 두드린 한 줄을 권장합니다',
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _b,
            obscureText: true,
            decoration: const InputDecoration(labelText: '한 번 더 입력'),
          ),
          if (_err != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(_err!,
                style: const TextStyle(color: Colors.red, fontSize: 12)),
          ],
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(onPressed: _ok, child: const Text('저장')),
      ],
    );
  }
}

class _CodeVerifyDialog extends StatefulWidget {
  const _CodeVerifyDialog();

  @override
  State<_CodeVerifyDialog> createState() => _CodeVerifyDialogState();
}

class _CodeVerifyDialogState extends State<_CodeVerifyDialog> {
  final TextEditingController _c = TextEditingController();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('코드 입력'),
      content: TextField(
        controller: _c,
        autofocus: true,
        decoration: const InputDecoration(labelText: '공개된 코드'),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('취소'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_c.text),
          child: const Text('확인'),
        ),
      ],
    );
  }
}
