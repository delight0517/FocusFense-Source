import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/services/windows_chromium_registry_service.dart';

void main() {
  test(
    'PAC OFF clears own URLs and preserves unrelated proxy settings',
    () async {
      final root =
          r'HKCU:\Software\FocusFensePacTest\' +
          DateTime.now().microsecondsSinceEpoch.toString();
      final own = '$root\\Own';
      final other = '$root\\Other';
      final internet = '$root\\Internet';
      final script = WindowsChromiumRegistryService.buildOwnedPacCleanupScript(
        ownedUrls: ['file:///C:/FocusFense/sixvpn_block.pac'],
        browserRoots: [own, other],
        internetSettingsRoot: internet,
      );
      final result = await Process.run('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '''
\$ErrorActionPreference = 'Stop'
try {
  foreach (\$key in @('$own','$other','$internet')) { New-Item -Path \$key -Force | Out-Null }
  Set-ItemProperty -LiteralPath '$own' -Name ProxyPacUrl -Value 'file:///C:/FocusFense/sixvpn_block.pac'
  Set-ItemProperty -LiteralPath '$own' -Name ProxyMode -Value 'pac_script'
  Set-ItemProperty -LiteralPath '$own' -Name DnsOverHttpsMode -Value 'automatic'
  Set-ItemProperty -LiteralPath '$other' -Name ProxyPacUrl -Value 'https://company.example/sixvpn_block.pac'
  Set-ItemProperty -LiteralPath '$other' -Name ProxyMode -Value 'fixed_servers'
  Set-ItemProperty -LiteralPath '$internet' -Name AutoConfigURL -Value 'file:///C:/FocusFense/sixvpn_block.pac'
  $script
  if ((Get-ItemProperty -LiteralPath '$own').ProxyPacUrl) { throw 'Own PAC retained' }
  if ((Get-ItemProperty -LiteralPath '$own').ProxyMode) { throw 'Own mode retained' }
  if ((Get-ItemProperty -LiteralPath '$own').DnsOverHttpsMode -ne 'automatic') { throw 'Unrelated DNS changed' }
  if ((Get-ItemProperty -LiteralPath '$other').ProxyPacUrl -ne 'https://company.example/sixvpn_block.pac') { throw 'Other PAC changed' }
  if ((Get-ItemProperty -LiteralPath '$other').ProxyMode -ne 'fixed_servers') { throw 'Other mode changed' }
  if ((Get-ItemProperty -LiteralPath '$internet').AutoConfigURL) { throw 'Own WinINET retained' }
  Set-ItemProperty -LiteralPath '$own' -Name ProxyPacUrl -Value 'file:///C:/FocusFense/sixvpn_block.pac'
  Set-ItemProperty -LiteralPath '$own' -Name ProxyMode -Value 'direct'
  Set-ItemProperty -LiteralPath '$internet' -Name AutoConfigURL -Value 'https://company.example/proxy.pac'
  $script
  $script
  if ((Get-ItemProperty -LiteralPath '$own').ProxyMode -ne 'direct') { throw 'Later mode changed' }
  if ((Get-ItemProperty -LiteralPath '$internet').AutoConfigURL -ne 'https://company.example/proxy.pac') { throw 'Other WinINET changed' }
} finally {
  if (Test-Path -LiteralPath '$root') { Remove-Item -LiteralPath '$root' -Recurse -Force }
}
''',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    },
    skip: !Platform.isWindows,
  );
}
