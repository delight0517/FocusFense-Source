import 'dart:io';

import 'uninstall_friction_policy_service.dart';
import 'windows_autostart_service.dart';
import 'windows_firewall_block_service.dart';
import 'windows_hidden_process.dart';
import 'windows_integration_prefs.dart';
import 'windows_system_block_service.dart';
import 'windows_watchdog_service.dart';

/// Removes Focus Fense protection and recovery hooks before the user opens
/// Windows Installed Apps. It deliberately leaves the app and user data in
/// place until Windows performs the actual uninstall.
final class WindowsUninstallCleanupService {
  WindowsUninstallCleanupService._();
  static final WindowsUninstallCleanupService instance =
      WindowsUninstallCleanupService._();

  static const List<String> _extraTaskNames = <String>[
    'SixVPNBlockerOfflineGuard',
    'SixVPNBrowserGuard',
    'SixVPNTier3Watchdog',
    'SixVPNBlockerElevatedMaintain',
  ];

  Future<WindowsUninstallCleanupResult> prepare() async {
    if (!Platform.isWindows) {
      return const WindowsUninstallCleanupResult(
        completed: false,
        steps: <String>['Windows 전용 정리입니다.'],
      );
    }
    if (!await UninstallFrictionPolicyService.instance
        .canDisableAutostartForRemoval()) {
      return const WindowsUninstallCleanupResult(
        completed: false,
        steps: <String>['제거 도우미 타이머 완료가 확인되지 않았습니다.'],
      );
    }

    final List<String> steps = <String>[];
    var completed = true;

    try {
      final result = await WindowsSystemBlockService.instance.deactivate();
      steps.add('hosts·브라우저 정책·PAC: ${result.message}');
      if (!result.ok) completed = false;
    } catch (e) {
      steps.add('hosts·브라우저 정책·PAC 정리 실패: $e');
      completed = false;
    }

    try {
      await WindowsFirewallBlockService.instance.deactivate();
      final bool? remaining = await WindowsFirewallBlockService.instance
          .hasManagedRules();
      if (remaining == false) {
        steps.add('Focus Fense 방화벽 규칙 정리·확인 완료');
      } else {
        steps.add(
          remaining == true
              ? '방화벽 규칙이 남아 있습니다. 관리자 권한으로 다시 정리해야 합니다.'
              : '방화벽 정리 결과를 확인하지 못했습니다.',
        );
        completed = false;
      }
    } catch (e) {
      steps.add('방화벽 규칙 정리 실패: $e');
      completed = false;
    }

    try {
      final result = await WindowsAutostartService.instance.uninstall();
      steps.add('사용자 자동 실행: ${result.message}');
      if (!result.ok) completed = false;
    } catch (e) {
      steps.add('사용자 자동 실행 정리 실패: $e');
      completed = false;
    }

    try {
      final result = await WindowsAutostartService.instance
          .uninstallHklmMirror();
      steps.add('컴퓨터 전체 자동 실행: ${result.message}');
      if (!result.ok) completed = false;
    } catch (e) {
      steps.add('컴퓨터 전체 자동 실행 정리 실패: $e');
      completed = false;
    }

    try {
      final result = await WindowsWatchdogService.instance.uninstall();
      steps.add('자동 복구 감시: ${result.message}');
      if (!result.ok) completed = false;
    } catch (e) {
      steps.add('자동 복구 감시 정리 실패: $e');
      completed = false;
    }

    final String taskNames = <String>[..._extraTaskNames].join("','");
    final String ps =
        """
\$ErrorActionPreference = 'Stop'
\$names = @('$taskNames')
\$failed = @()
foreach (\$name in \$names) {
  try {
    \$task = Get-ScheduledTask -TaskName \$name -ErrorAction SilentlyContinue
    if (\$task) { Unregister-ScheduledTask -TaskName \$name -Confirm:\$false -ErrorAction Stop }
  } catch { \$failed += \$name }
}
if (\$failed.Count) { Write-Output ('FAILED:' + (\$failed -join ',')); exit 1 }
Write-Output 'OK'
""";
    try {
      final ProcessResult result =
          await windowsRunHidden('powershell.exe', <String>[
            '-NoProfile',
            '-NonInteractive',
            '-ExecutionPolicy',
            'Bypass',
            '-Command',
            ps,
          ]);
      final String output = '${result.stdout}${result.stderr}'.trim();
      steps.add(
        result.exitCode == 0
            ? '추가 보호 예약 작업 정리 완료'
            : '추가 보호 예약 작업 정리 실패: $output',
      );
      if (result.exitCode != 0) completed = false;
    } catch (e) {
      steps.add('추가 보호 예약 작업 정리 실패: $e');
      completed = false;
    }

    // The app stays installed until the user confirms removal in Windows.
    // Retaining this opt-out prevents this running process from turning
    // autostart back on while the uninstall screen is open.
    await WindowsIntegrationPrefs.instance.setAutostartExplicitlyOff(true);
    return WindowsUninstallCleanupResult(completed: completed, steps: steps);
  }
}

final class WindowsUninstallCleanupResult {
  const WindowsUninstallCleanupResult({
    required this.completed,
    required this.steps,
  });

  final bool completed;
  final List<String> steps;
}
