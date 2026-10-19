import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'chrome_gmail_gemini_allowlist_service.dart';
import 'windows_hidden_process.dart';

/// Chrome **Gmail · Gemini · 로그인** 부속 앱(PWA)은 kill guard에서 건드리지 않습니다.
final class ChromeKillExemptService {
  ChromeKillExemptService._();
  static final ChromeKillExemptService instance = ChromeKillExemptService._();

  static const List<String> _allowedHostFragments = <String>[
    'gemini.google.com',
    'bard.google.com',
    'mail.google.com',
    'gmail.com',
    'accounts.google.com',
    'signin.google.com',
    'myaccount.google.com',
    'ogs.google.com',
    'workspace.google.com',
  ];

  /// When ON, kill guard never terminates Chrome (URLAllowlist handles sites).
  Future<bool> chromeKillGuardPaused() async {
    if (!Platform.isWindows) return false;
    return ChromeGmailGeminiAllowlistService.instance.enabled();
  }

  /// True when this chrome.exe command line is a Gmail/Gemini companion we must keep.
  static bool isExemptCommandLine(String? commandLine) {
    if (commandLine == null || commandLine.trim().isEmpty) return false;
    final String lower = commandLine.toLowerCase();

    for (final String frag in _allowedHostFragments) {
      if (lower.contains(frag)) return true;
    }
    for (final String pat in ChromeGmailGeminiAllowlistService.kManagedAllowPatterns) {
      final String needle = pat
          .replaceAll('*://', '')
          .replaceAll('https://', '')
          .replaceAll('/*', '')
          .toLowerCase();
      if (needle.isNotEmpty && lower.contains(needle)) return true;
    }
    return false;
  }

  /// Main browser window (not renderer/gpu utility child).
  static bool isMainBrowserProcess(String? commandLine) {
    if (commandLine == null || commandLine.trim().isEmpty) return true;
    final String lower = commandLine.toLowerCase();
    if (!lower.contains('--type=')) return true;
    return lower.contains('--type=browser');
  }

  Future<String?> commandLineForPid(int pid) async {
    if (!Platform.isWindows || pid <= 0) return null;
    try {
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final String psExe = p.join(
        windir,
        'System32',
        'WindowsPowerShell',
        'v1.0',
        'powershell.exe',
      );
      final ProcessResult r = await windowsRunHidden(
        psExe,
        <String>[
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          "(Get-CimInstance Win32_Process -Filter \"ProcessId=$pid\" "
          "-ErrorAction SilentlyContinue | Select-Object -ExpandProperty CommandLine)",
        ],
      );
      final String out = '${r.stdout}'.trim();
      return out.isEmpty ? null : out;
    } catch (_) {
      return null;
    }
  }

  Future<bool> shouldExemptPid(int pid) async {
    final String? cmd = await commandLineForPid(pid);
    return isExemptCommandLine(cmd);
  }

  /// PIDs safe to terminate for URL-block enforcement (excludes Gemini/Gmail PWAs).
  Future<List<int>> killableChromePids() async {
    if (!Platform.isWindows) return const <int>[];
    final List<_ProcRow> rows = await _listExe('chrome.exe');
    final List<int> out = <int>[];
    for (final _ProcRow row in rows) {
      if (isExemptCommandLine(row.commandLine)) continue;
      if (!isMainBrowserProcess(row.commandLine)) continue;
      out.add(row.pid);
    }
    return out;
  }

  Future<List<int>> killablePidsForExe(String exeName) async {
    if (exeName.toLowerCase() == 'chrome.exe') {
      return killableChromePids();
    }
    final List<_ProcRow> rows = await _listExe(exeName);
    return rows.map((_ProcRow r) => r.pid).toList();
  }

  Future<List<_ProcRow>> _listExe(String exeName) async {
    try {
      final String windir = Platform.environment['WINDIR'] ?? r'C:\Windows';
      final String psExe = p.join(
        windir,
        'System32',
        'WindowsPowerShell',
        'v1.0',
        'powershell.exe',
      );
      final ProcessResult r = await windowsRunHidden(
        psExe,
        <String>[
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          "Get-CimInstance Win32_Process -Filter \"Name='$exeName'\" | "
          "Select-Object ProcessId,CommandLine | ConvertTo-Json -Compress",
        ],
      );
      if (r.exitCode != 0) return const <_ProcRow>[];
      final String stdout = '${r.stdout}'.trim();
      if (stdout.isEmpty) return const <_ProcRow>[];
      final Object? decoded = jsonDecode(stdout);
      final List<dynamic> items = <dynamic>[];
      if (decoded is List) {
        items.addAll(decoded);
      } else if (decoded is Map) {
        items.add(decoded);
      }
      final List<_ProcRow> out = <_ProcRow>[];
      for (final dynamic item in items) {
        if (item is! Map) continue;
        final int pid = (item['ProcessId'] as num?)?.toInt() ?? 0;
        if (pid <= 0) continue;
        out.add(
          _ProcRow(
            pid: pid,
            commandLine: item['CommandLine'] as String?,
          ),
        );
      }
      return out;
    } catch (_) {
      return const <_ProcRow>[];
    }
  }
}

final class _ProcRow {
  const _ProcRow({required this.pid, this.commandLine});
  final int pid;
  final String? commandLine;
}
