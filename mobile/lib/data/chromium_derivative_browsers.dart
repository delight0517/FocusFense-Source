import 'dart:io';

import 'package:path/path.dart' as p;

/// Chromium 파생 브라우저 — MV3 확장 강제 설치 + URLBlocklist (Brave와 동일 계열).
final class ChromiumDerivativeBrowserDef {
  const ChromiumDerivativeBrowserDef({
    required this.id,
    required this.displayName,
    required this.policyRoot,
    required this.userExtRegSubKey,
    required this.exeCandidates,
    required this.payloadDirName,
    required this.vbsFileName,
  });

  final String id;
  final String displayName;
  final String policyRoot;
  final String userExtRegSubKey;
  final List<String> exeCandidates;
  final String payloadDirName;
  final String vbsFileName;

  String get policyRootHkcu => r'HKCU\' + policyRoot;
  String get policyRootHklm => r'HKLM\' + policyRoot;

  String userExtKeyHkcu(String extId) =>
      r'HKCU\' + userExtRegSubKey + r'\' + extId;
}

String _pf() => Platform.environment['ProgramFiles'] ?? r'C:\Program Files';
String _pf86() =>
    Platform.environment['ProgramFiles(x86)'] ?? r'C:\Program Files (x86)';
String _la() => Platform.environment['LOCALAPPDATA'] ?? '';

final List<ChromiumDerivativeBrowserDef> kChromiumDerivativeBrowsers =
    <ChromiumDerivativeBrowserDef>[
      ChromiumDerivativeBrowserDef(
        id: 'aside',
        displayName: 'Aside AI Browser',
        // Aside is a Chromium fork. Its Windows install is system-level under
        // Program Files; use Chromium's enterprise policy hive.
        policyRoot: r'SOFTWARE\Policies\Chromium',
        userExtRegSubKey: r'Software\Chromium\Extensions',
        exeCandidates: <String>[
          p.join(_pf(), 'Aside', 'Application', 'Aside.exe'),
          p.join(_pf86(), 'Aside', 'Application', 'Aside.exe'),
        ],
        payloadDirName: 'aside_blocker',
        vbsFileName: 'Launch-6VPN-Aside.vbs',
      ),
      ChromiumDerivativeBrowserDef(
        id: 'vivaldi',
        displayName: 'Vivaldi',
        policyRoot: r'SOFTWARE\Policies\Vivaldi',
        userExtRegSubKey: r'Software\Vivaldi\Extensions',
        exeCandidates: <String>[
          p.join(_pf(), 'Vivaldi', 'Application', 'vivaldi.exe'),
          p.join(_pf86(), 'Vivaldi', 'Application', 'vivaldi.exe'),
          p.join(_la(), 'Vivaldi', 'Application', 'vivaldi.exe'),
        ],
        payloadDirName: 'vivaldi_blocker',
        vbsFileName: 'Launch-6VPN-Vivaldi.vbs',
      ),
      ChromiumDerivativeBrowserDef(
        id: 'whale',
        displayName: 'Naver Whale',
        policyRoot: r'SOFTWARE\Policies\NAVER\Whale',
        userExtRegSubKey: r'Software\Naver\Naver Whale\Extensions',
        exeCandidates: <String>[
          p.join(_pf(), 'Naver', 'Naver Whale', 'Application', 'whale.exe'),
          p.join(_pf86(), 'Naver', 'Naver Whale', 'Application', 'whale.exe'),
          p.join(_la(), 'Naver', 'Naver Whale', 'Application', 'whale.exe'),
        ],
        payloadDirName: 'whale_blocker',
        vbsFileName: 'Launch-6VPN-Whale.vbs',
      ),
      ChromiumDerivativeBrowserDef(
        id: 'opera',
        displayName: 'Opera',
        policyRoot: r'SOFTWARE\Policies\Opera Software\Opera Stable',
        userExtRegSubKey: r'Software\Opera Software\Opera Stable\Extensions',
        exeCandidates: <String>[
          p.join(_pf(), 'Opera', 'opera.exe'),
          p.join(_pf86(), 'Opera', 'opera.exe'),
          p.join(_la(), 'Programs', 'Opera', 'opera.exe'),
        ],
        payloadDirName: 'opera_blocker',
        vbsFileName: 'Launch-6VPN-Opera.vbs',
      ),
      ChromiumDerivativeBrowserDef(
        id: 'opera_gx',
        displayName: 'Opera GX',
        policyRoot: r'SOFTWARE\Policies\Opera Software\Opera GX Stable',
        userExtRegSubKey: r'Software\Opera Software\Opera GX Stable\Extensions',
        exeCandidates: <String>[
          p.join(_pf(), 'Opera GX', 'opera.exe'),
          p.join(_la(), 'Programs', 'Opera GX', 'opera.exe'),
        ],
        payloadDirName: 'opera_gx_blocker',
        vbsFileName: 'Launch-6VPN-OperaGX.vbs',
      ),
    ];

ChromiumDerivativeBrowserDef? chromiumDerivativeById(String id) {
  for (final ChromiumDerivativeBrowserDef d in kChromiumDerivativeBrowsers) {
    if (d.id == id) return d;
  }
  return null;
}
