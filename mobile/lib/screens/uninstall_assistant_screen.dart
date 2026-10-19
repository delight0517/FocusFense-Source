import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/uninstall_friction_policy_service.dart';
import '../services/windows_uninstall_cleanup_service.dart';
import '../theme/app_colors.dart';

/// Friction helper before showing uninstall / removal instructions.
///
/// Countdown persists on disk until it finishes, is cancelled, or the PC
/// reboots — app close / rebuild does not pause it.
class UninstallAssistantScreen extends StatefulWidget {
  const UninstallAssistantScreen({super.key});

  @override
  State<UninstallAssistantScreen> createState() =>
      _UninstallAssistantScreenState();
}

class _UninstallAssistantScreenState extends State<UninstallAssistantScreen> {
  bool _loading = true;
  bool _sessionActive = false;
  int _fullWaitSec = UninstallFrictionPolicyService.kDefaultWaitSec;
  int _remaining = 0;
  Timer? _t;
  String? _code;
  bool _done = false;
  bool _cleanupRunning = false;
  bool _cleanupCompleted = false;
  List<String> _cleanupSteps = <String>[];
  final TextEditingController _codeInput = TextEditingController();

  bool get _codeConfirmed => _codeInput.text.trim().toUpperCase() == _code;

  @override
  void initState() {
    super.initState();
    _code = _makeCode();
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    _t?.cancel();
    final int sec = await UninstallFrictionPolicyService.instance
        .getWaitSeconds();
    final UninstallActiveSession? active = await UninstallFrictionPolicyService
        .instance
        .loadActiveSession();

    if (!mounted) return;

    final bool authorized = await UninstallFrictionPolicyService.instance
        .isRemovalAuthorized();
    if (authorized) {
      setState(() {
        _fullWaitSec = sec;
        _loading = false;
        _sessionActive = false;
        _done = true;
        _remaining = 0;
      });
      return;
    }

    if (active != null) {
      setState(() {
        _fullWaitSec = active.fullSec;
        _loading = false;
        _sessionActive = true;
        _remaining = active.remainingSec;
        _done = active.isComplete;
      });
      if (!active.isComplete) {
        _startPersistentTicker();
      }
      return;
    }

    setState(() {
      _fullWaitSec = sec;
      _loading = false;
      _sessionActive = false;
      _done = false;
      _remaining = 0;
    });
  }

  Future<void> _startTimer() async {
    final int sec = await UninstallFrictionPolicyService.instance
        .getWaitSeconds();
    await _beginSession(sec);
  }

  Future<void> _beginSession(int seconds) async {
    await UninstallFrictionPolicyService.instance.startSession(
      durationSec: seconds,
      usingFullFriction: true,
    );
    if (!mounted) return;
    setState(() {
      _fullWaitSec = seconds;
      _sessionActive = true;
      _remaining = seconds;
      _done = false;
    });
    _startPersistentTicker();
  }

  Future<void> _cancelTimer() async {
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('제거 타이머 취소'),
        content: const Text(
          '대기 타이머를 취소할까요?\n'
          '나중에 다시 「제거 타이머 시작」을 눌러 시작할 수 있습니다.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('계속 대기'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('취소하기'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    _t?.cancel();
    await UninstallFrictionPolicyService.instance.cancelSession();
    if (!mounted) return;
    setState(() {
      _sessionActive = false;
      _remaining = 0;
      _done = false;
    });
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('제거 타이머를 취소했습니다.')));
  }

  void _startPersistentTicker() {
    _t?.cancel();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(_tickFromDisk());
    });
  }

  Future<void> _tickFromDisk() async {
    if (_done || !mounted) return;
    final UninstallActiveSession? active = await UninstallFrictionPolicyService
        .instance
        .loadActiveSession();
    if (!mounted) return;
    if (active == null || active.isComplete) {
      setState(() {
        _remaining = 0;
        _done = true;
        _sessionActive = false;
      });
      _t?.cancel();
      await UninstallFrictionPolicyService.instance.markRemovalAuthorized();
      await UninstallFrictionPolicyService.instance.clearSession();
      return;
    }
    setState(() => _remaining = active.remainingSec);
  }

  @override
  void dispose() {
    _t?.cancel();
    _codeInput.dispose();
    super.dispose();
  }

  Future<void> _openWindowsInstalledAppsSettings() async {
    final Uri uri = Uri.parse('ms-settings:appsfeatures');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('시스템 설정을 열지 못했습니다. Windows 설정 → 앱 → 설치된 앱에서 제거하세요.'),
        ),
      );
    }
  }

  Future<void> _prepareWindowsUninstall() async {
    final bool? proceed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('차단과 자동 복구를 해제할까요?'),
        content: const Text(
          'Focus Fense가 등록한 hosts·브라우저 정책·PAC·방화벽·자동 실행·복구 작업을 정리합니다. '
          '앱과 사용자 데이터, 백업은 이 단계에서 삭제하지 않습니다. '
          '정리가 끝나면 Windows 설치된 앱에서 직접 제거를 확정할 수 있습니다.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('돌아가기'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('차단 해제 진행'),
          ),
        ],
      ),
    );
    if (proceed != true || !mounted) return;
    setState(() {
      _cleanupRunning = true;
      _cleanupSteps = <String>[];
      _cleanupCompleted = false;
    });
    final WindowsUninstallCleanupResult result =
        await WindowsUninstallCleanupService.instance.prepare();
    if (!mounted) return;
    setState(() {
      _cleanupRunning = false;
      _cleanupCompleted = result.completed;
      _cleanupSteps = result.steps;
    });
  }

  String _makeCode() {
    const String chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
    final Random r = Random();
    return List<String>.generate(
      6,
      (_) => chars[r.nextInt(chars.length)],
    ).join();
  }

  String _fmt(int s) {
    final int m = s ~/ 60;
    final int sec = s % 60;
    return '${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}';
  }

  String _fmtDuration(int sec) {
    if (sec < 3600) return '${sec ~/ 60}분';
    if (sec < 86400) return '${sec ~/ 3600}시간';
    return '${sec ~/ 86400}일';
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('앱 제거 안내')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              '제거 방지가 항상 켜져 있습니다. 타이머가 끝나야 확인 코드가 나옵니다. '
              '앱을 닫거나 업데이트해도 시간은 계속 흐르고, PC 재시작 시에만 초기화됩니다. '
              '시작한 뒤에는 아래 「타이머 취소」로 중단할 수 있습니다.',
              style: theme.textTheme.bodyMedium?.copyWith(height: 1.45),
            ),
            const SizedBox(height: 16),
            if (_loading)
              const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(),
                ),
              )
            else if (!_sessionActive && !_done)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    '대기 시간: ${_fmtDuration(_fullWaitSec)}',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: _startTimer,
                    icon: const Icon(Icons.timer_outlined),
                    label: const Text('제거 타이머 시작'),
                  ),
                ],
              )
            else if (!_done && _remaining > 0)
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    '남은 시간 ${_fmt(_remaining)}',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.displaySmall?.copyWith(
                      fontWeight: FontWeight.w900,
                      color: AppColors.warning,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '전체 대기: ${_fmtDuration(_fullWaitSec)}',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppColors.muted,
                    ),
                  ),
                  const SizedBox(height: 16),
                  OutlinedButton.icon(
                    onPressed: _cancelTimer,
                    icon: const Icon(Icons.close),
                    label: const Text('타이머 취소'),
                  ),
                ],
              )
            else if (_done) ...<Widget>[
              const Text(
                '확인 코드 (메모해 두세요)',
                textAlign: TextAlign.center,
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 8),
              SelectableText(
                _code ?? '',
                textAlign: TextAlign.center,
                style: theme.textTheme.headlineMedium?.copyWith(
                  letterSpacing: 4,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _codeInput,
                textCapitalization: TextCapitalization.characters,
                onChanged: (_) => setState(() {}),
                decoration: const InputDecoration(
                  labelText: '확인 코드를 직접 입력',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: _code ?? ''));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('코드를 복사했습니다.')),
                    );
                  }
                },
                icon: const Icon(Icons.copy),
                label: const Text('코드 복사'),
              ),
            ],
            const SizedBox(height: 20),
            if (Platform.isWindows && _done) ...<Widget>[
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _cleanupRunning || !_codeConfirmed
                    ? null
                    : _prepareWindowsUninstall,
                icon: _cleanupRunning
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.layers_clear_outlined),
                label: Text(
                  _cleanupRunning ? '차단·복구 해제 중…' : '차단과 자동 복구 해제 · 제거 준비',
                ),
              ),
              if (_cleanupSteps.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                Text(
                  _cleanupSteps.join('\n'),
                  style: theme.textTheme.bodySmall?.copyWith(height: 1.35),
                ),
              ],
              if (_cleanupCompleted)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '차단 해제 단계가 완료됐습니다. 아래에서 Windows 제거 화면을 열어 앱 제거를 마치세요. '
                    '보호 설정·작업을 복구하면 제거 준비도 다시 진행해야 합니다.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: AppColors.success,
                    ),
                  ),
                ),
            ],
            if (Platform.isWindows)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    elevation: 0,
                    foregroundColor: theme.colorScheme.onSurface,
                    backgroundColor: theme.colorScheme.surfaceContainerHighest,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(6),
                      side: BorderSide(color: theme.dividerColor),
                    ),
                  ),
                  onPressed: _done && _cleanupCompleted
                      ? _openWindowsInstalledAppsSettings
                      : null,
                  child: const Text('Windows 설치된 앱(시스템 제거) 화면 열기'),
                ),
              ),
            if (!_done)
              const Text(
                '타이머가 끝나면 차단 해제 단계를 진행할 수 있습니다. '
                '타이머를 취소하면 설치·설정·보호 상태는 유지됩니다.',
                style: TextStyle(
                  color: AppColors.muted,
                  height: 1.4,
                  fontSize: 12,
                ),
              )
            else
              Text(
                '확인 코드를 직접 입력한 뒤 「차단과 자동 복구 해제」를 누르세요. '
                '이 단계는 앱과 사용자 데이터를 지우지 않습니다. 정리 결과가 모두 성공하면 '
                'Windows 설치된 앱 화면에서 앱 제거를 확정할 수 있습니다. '
                '별도로 보관한 백업은 보존됩니다.',
                style: const TextStyle(
                  color: AppColors.muted,
                  height: 1.4,
                  fontSize: 12,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
