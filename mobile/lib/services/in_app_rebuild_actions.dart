import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

import 'build_identity_service.dart';
import 'windows_desktop_rebuild_service.dart';
import 'windows_rebuild_monitor.dart';

/// Shared entry to start an in-app Windows rebuild from any screen.
abstract final class InAppRebuildActions {
  static bool _pipelineStarting = false;

  static Future<void> startRebuild(BuildContext context) async {
    if (!Platform.isWindows) return;
    if (_pipelineStarting || WindowsRebuildMonitor.instance.isActive) return;

    final BuildIdentity running =
        await BuildIdentityService.instance.current();
    final SourceVersion? source =
        await WindowsDesktopRebuildService.readSourceVersion();

    final String? root =
        await WindowsDesktopRebuildService.effectiveMobileRoot();
    if (root == null) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            '소스 폴더를 찾지 못했어요. 설정 → Windows 개발 빌드 → 「소스 자동 찾기」.',
          ),
          action: SnackBarAction(
            label: '설정',
            onPressed: () => context.go('/settings'),
          ),
        ),
      );
      return;
    }

    if (!context.mounted) return;
    final bool matches = source != null &&
        source.matchesRunning(
          runningVersion: running.version,
          runningBuildNumber: running.buildNumber,
        );

    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(matches ? '최신 버전 다시 빌드' : '새 버전 빌드·설치'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (matches)
                const Text(
                  '실행 중인 빌드와 소스 pubspec이 같습니다. '
                  '그래도 다시 빌드할까요?',
                )
              else
                const Text(
                  '터미널에서 최신 소스를 빌드해 설치합니다.\n\n'
                  '• 앱은 패키지 다운로드까지 **계속 열려** 진행 로그를 보여줍니다.\n'
                  '• exe 링크 직전에 잠시 닫힌 뒤, 백그라운드 빌드가 이어집니다.\n'
                  '• 완료되면 **새 버전이 자동 실행**됩니다.',
                ),
              const SizedBox(height: 12),
              _kv('현재 실행', 'v${running.version}+${running.buildNumber}'),
              if (source != null)
                _kv('빌드 대상', 'v${source.display}')
              else
                const Text('소스 버전: (pubspec 읽기 실패)'),
              const SizedBox(height: 8),
              Text(
                'mobile:\n$root',
                style: const TextStyle(fontFamily: 'Menlo', fontSize: 10, height: 1.35),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(matches ? '다시 빌드' : '다운로드·빌드 시작'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;

    _pipelineStarting = true;
    try {
      final DateTime sessionStarted =
          await WindowsDesktopRebuildService.prepareNewInAppRebuildSession();
      WindowsRebuildMonitor.instance.begin(
        sessionPrepared: true,
        sessionStartedAt: sessionStarted,
      );
      // Paint the full-screen overlay before spawning PowerShell.
      await WidgetsBinding.instance.endOfFrame;
      await WindowsDesktopRebuildService.launchRebuildPipeline(
        root,
        fromApp: true,
      );
      bool started = await WindowsDesktopRebuildService
          .verifyRebuildPipelineStarted(timeout: const Duration(seconds: 12));

      // Hidden+detached spawn produced zero evidence of running — some
      // security software specifically kills that pattern before it executes
      // a single line. Retry once with a visible console window: it's one
      // build action the user explicitly asked for, so a brief flash here is
      // an acceptable trade-off if it lets the build actually run.
      if (!started && WindowsRebuildMonitor.instance.isActive) {
        await WindowsDesktopRebuildService.launchRebuildPipeline(
          root,
          fromApp: true,
          visible: true,
        );
        started = await WindowsDesktopRebuildService
            .verifyRebuildPipelineStarted(timeout: const Duration(seconds: 15));
      }

      if (!started && WindowsRebuildMonitor.instance.isActive) {
        WindowsRebuildMonitor.instance.cancel();
        if (context.mounted) {
          await _showLaunchFailedDialog(context, root);
        }
      }
    } catch (e) {
      WindowsRebuildMonitor.instance.cancel();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('시작 실패: $e')),
        );
      }
    } finally {
      _pipelineStarting = false;
    }
  }

  /// Shown when both the hidden and visible spawn attempts produced no
  /// evidence of running (external_launcher.log never appeared, no console
  /// output, no live PID) — a blocking dialog instead of a fleeting SnackBar,
  /// since this needs the user to actually act (run a command), not just
  /// notice a toast for a few seconds.
  static Future<void> _showLaunchFailedDialog(
    BuildContext context,
    String mobileRoot,
  ) async {
    final String command =
        'powershell -NoProfile -ExecutionPolicy Bypass -File '
        '"$mobileRoot\\tools\\Rebuild-From-Terminal.ps1"';
    await showDialog<void>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('빌드가 시작되지 않았습니다'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const Text(
                '숨겨진 창과 보이는 창 두 방식 모두 외부 PowerShell이 실행됐다는 '
                '증거를 남기지 못했습니다. 보안 프로그램(예: 안랩·nProtect 계열)이 '
                '앱이 띄우는 PowerShell을 의심 행위로 보고 실행 직후 차단했을 가능성이 '
                '가장 큽니다.\n\n아래 명령을 터미널(PowerShell)에 붙여넣어 직접 빌드해 주세요:',
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF0F1115),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  command,
                  style: const TextStyle(
                    color: Color(0xFFD4DAE2),
                    fontSize: 11,
                    fontFamily: 'Menlo',
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('닫기'),
          ),
          FilledButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: command));
              if (ctx.mounted) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('명령이 클립보드에 복사되었습니다.')),
                );
              }
            },
            icon: const Icon(Icons.copy_outlined, size: 16),
            label: const Text('명령 복사'),
          ),
        ],
      ),
    );
  }

  static Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 72,
            child: Text(k, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          ),
          Expanded(
            child: Text(
              v,
              style: const TextStyle(
                fontSize: 12,
                fontFamily: 'Menlo',
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
