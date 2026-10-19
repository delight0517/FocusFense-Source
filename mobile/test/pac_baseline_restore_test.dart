import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;
import 'package:six_clean_room/services/windows_chromium_registry_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late String root, journal, marker;
  late File pac;
  String Function(String)? transform;
  late WindowsChromiumRegistryService service;
  String q(String value) => "'${value.replaceAll("'", "''")}'";
  Future<ProcessResult> ps(String script) => Process.run('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    script,
  ]);
  Future<void> execute(String script) async {
    final result = await ps("\$ErrorActionPreference='Stop'\n$script");
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  }

  Future<Map<String, dynamic>> state() async {
    final result = await ps('''
\$out=@{}
foreach (\$part in @('Chrome','Edge','Internet')) {
  \$key=Join-Path ${q(root)} \$part
  \$values=@{}
  if (Test-Path -LiteralPath \$key) {
    \$item=Get-Item -LiteralPath \$key
    foreach (\$name in \$item.GetValueNames()) {
      \$values[\$name]=@{kind=\$item.GetValueKind(\$name).ToString();value=\$item.GetValue(\$name,\$null,[Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)}
    }
  }
  \$out[\$part]=\$values
}
ConvertTo-Json -InputObject \$out -Depth 8 -Compress
''');
    expect(result.exitCode, 0, reason: '${result.stderr}');
    return (jsonDecode('${result.stdout}'.trim()) as Map)
        .cast<String, dynamic>();
  }

  Future<void> seed() => execute('''
foreach (\$part in @('Chrome','Edge','Internet')) { New-Item -Path (Join-Path ${q(root)} \$part) -Force | Out-Null }
foreach (\$part in @('Chrome','Edge')) {
  \$key=Join-Path ${q(root)} \$part
  Set-ItemProperty -LiteralPath \$key -Name ProxyMode -Value 'fixed_servers' -Type String
  Set-ItemProperty -LiteralPath \$key -Name ProxyPacUrl -Value 'https://company.example/original.pac' -Type String
  Set-ItemProperty -LiteralPath \$key -Name BuiltInDnsClientEnabled -Value 1 -Type DWord
  Set-ItemProperty -LiteralPath \$key -Name DnsOverHttpsMode -Value 'automatic' -Type String
}
Set-ItemProperty -LiteralPath ${q('$root\\Internet')} -Name AutoConfigURL -Value 'https://company.example/original.pac' -Type String
''');
  List<dynamic> entries() => File(journal).existsSync()
      ? jsonDecode(File(journal).readAsStringSync())['entries'] as List
      : [];

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('ff-pac-baseline-');
    root =
        r'HKCU:\Software\FocusFensePacBaselineTest\' +
        DateTime.now().microsecondsSinceEpoch.toString();
    journal = p.join(temp.path, 'owned.json');
    marker = p.join(temp.path, 'off.json');
    pac = File(p.join(temp.path, 'test.pac'));
    await pac.writeAsString('function FindProxyForURL(){return "DIRECT";}');
    transform = null;
    service = WindowsChromiumRegistryService.forTesting(
      protectionOff: () => File(marker).existsSync(),
      ownershipJournalPath: journal,
      offMarkerPath: marker,
      browserPolicyRoots: ['$root\\Chrome', '$root\\Edge'],
      internetSettingsRoot: '$root\\Internet',
      run: (exe, args) async {
        final result = await Process.run(exe, [
          ...args.take(args.length - 1),
          transform?.call(args.last) ?? args.last,
        ]);
        if (result.exitCode != 0) {
          debugPrint('PAC_TEST_ERROR: ${result.stderr}');
        }
        return result;
      },
    );
  });
  tearDown(() async {
    await ps(
      'Remove-Item -LiteralPath ${q(root)} -Recurse -Force -ErrorAction SilentlyContinue',
    );
    await temp.delete(recursive: true);
  });

  test('PAC apply and OFF restore every original typed scalar', () async {
    await seed();
    final before = await state();
    expect(await service.applyPacEverywhere(pac.path), true);
    expect(entries(), hasLength(9));
    await service.clearOwnedPac();
    expect(await state(), before);
    expect(entries(), isEmpty);
    await service.clearOwnedPac();
    expect(await state(), before, reason: 'OFF is idempotent');
  }, skip: !Platform.isWindows);

  test('missing originals are removed without leaving DNS overrides', () async {
    final before = await state();
    expect(await service.applyPacEverywhere(pac.path), true);
    await service.clearOwnedPac();
    expect(await state(), before);
  }, skip: !Platform.isWindows);

  test(
    'repeated apply and changed PAC path retain the first baseline',
    () async {
      await seed();
      final before = await state();
      expect(await service.applyPacEverywhere(pac.path), true);
      expect(await service.applyPacEverywhere(pac.path), true);
      final second = File(p.join(temp.path, 'next.pac'));
      await second.writeAsString(
        'function FindProxyForURL(){return "DIRECT";}',
      );
      expect(await service.applyPacEverywhere(second.path), true);
      await service.clearOwnedPac();
      expect(await state(), before);
    },
    skip: !Platform.isWindows,
  );

  test(
    'OFF preserves later administrator changes and different value kinds',
    () async {
      await seed();
      expect(await service.applyPacEverywhere(pac.path), true);
      await execute('''
Set-ItemProperty -LiteralPath ${q('$root\\Chrome')} -Name ProxyPacUrl -Value 'https://later.example/proxy.pac' -Type String
Set-ItemProperty -LiteralPath ${q('$root\\Chrome')} -Name DnsOverHttpsMode -Value 'secure' -Type String
Set-ItemProperty -LiteralPath ${q('$root\\Chrome')} -Name BuiltInDnsClientEnabled -Value '0' -Type String
Set-ItemProperty -LiteralPath ${q('$root\\Edge')} -Name BuiltInDnsClientEnabled -Value ([byte[]]@(1,2,3)) -Type Binary
''');
      await service.clearOwnedPac();
      final chrome = (await state())['Chrome'];
      expect(chrome['ProxyPacUrl']['value'], 'https://later.example/proxy.pac');
      expect(chrome['DnsOverHttpsMode']['value'], 'secure');
      expect(chrome['BuiltInDnsClientEnabled'], {
        'kind': 'String',
        'value': '0',
      });
      expect(entries(), isEmpty);
      expect((await state())['Edge']['BuiltInDnsClientEnabled'], {
        'kind': 'Binary',
        'value': [1, 2, 3],
      });
    },
    skip: !Platform.isWindows,
  );

  test(
    'selective cleanup retains unselected ownership without reporting failure',
    () async {
      await seed();
      final before = await state();
      expect(await service.applyPacEverywhere(pac.path), true);
      await service.clearOwnedPac(browsers: false);
      expect((await state())['Internet'], before['Internet']);
      expect(entries(), hasLength(8));
      await service.clearOwnedPac(winInet: false);
      expect(await state(), before);
      expect(entries(), isEmpty);
    },
    skip: !Platform.isWindows,
  );

  test(
    'expanded-string baseline is restored without expanding its contents',
    () async {
      await seed();
      await execute(
        "Set-ItemProperty -LiteralPath ${q('$root\\Internet')} -Name AutoConfigURL -Type ExpandString -Value '%USERPROFILE%/original.pac'",
      );
      final before = await state();
      expect(await service.applyPacEverywhere(pac.path), true);
      await service.clearOwnedPac();
      expect(await state(), before);
    },
    skip: !Platform.isWindows,
  );

  test(
    'corrupt journal refuses apply before changing registry values',
    () async {
      await seed();
      final before = await state();
      await File(journal).writeAsString('{invalid');
      expect(await service.applyPacEverywhere(pac.path), false);
      expect(await state(), before);
    },
    skip: !Platform.isWindows,
  );

  test(
    'journal target tampering refuses restore before touching any registry value',
    () async {
      await seed();
      expect(await service.applyPacEverywhere(pac.path), true);
      final applied = await state();
      final original = await File(journal).readAsString();
      final changed = jsonDecode(original);
      changed['entries'][0]['key'] = r'HKCU:\Software\Unrelated';
      await File(journal).writeAsString(jsonEncode(changed));
      await expectLater(service.clearOwnedPac(), throwsStateError);
      expect(await state(), applied);
      await File(journal).writeAsString(original);
    },
    skip: !Platform.isWindows,
  );

  test(
    'OFF between journal intent and write stops apply and remains reversible',
    () async {
      await seed();
      final before = await state();
      transform = (script) => script.replaceFirst(
        'Save-FFPac \$records\n      if (Test-Path',
        "Save-FFPac \$records\n      [IO.File]::WriteAllText(${q(marker)},'off')\n      if (Test-Path",
      );
      expect(await service.applyPacEverywhere(pac.path), false);
      expect(File(marker).existsSync(), true);
      transform = null;
      await service.clearOwnedPac();
      expect(await state(), before);
    },
    skip: !Platform.isWindows,
  );

  test(
    'interrupted PAC URL update retains the previous owned value for rollback',
    () async {
      await seed();
      final before = await state();
      expect(await service.applyPacEverywhere(pac.path), true);
      final second = File(p.join(temp.path, 'interrupted.pac'));
      await second.writeAsString(
        'function FindProxyForURL(){return "DIRECT";}',
      );
      transform = (script) => script.replaceFirst(
        'Save-FFPac \$records\n      if (Test-Path',
        "Save-FFPac \$records\n      throw 'injected interruption before mutation'\n      if (Test-Path",
      );
      expect(await service.applyPacEverywhere(second.path), false);
      transform = null;
      await service.clearOwnedPac();
      expect(await state(), before);
    },
    skip: !Platform.isWindows,
  );

  test(
    'concurrent OFF waits for apply lock and cannot leave a late PAC write',
    () async {
      await seed();
      final before = await state();
      final ready = File(p.join(temp.path, 'apply-ready'));
      final release = File(p.join(temp.path, 'apply-release'));
      final cleanupReady = File(p.join(temp.path, 'cleanup-ready'));
      Future<void> waitFor(File file) async {
        final deadline = DateTime.now().add(const Duration(seconds: 8));
        while (!await file.exists() && DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        expect(await file.exists(), true, reason: file.path);
      }

      transform = (script) => script.replaceFirst(
        '      Write-FFPacState \$spec.key \$spec.name \$entry.after',
        '      Write-FFPacState \$spec.key \$spec.name \$entry.after\n'
            "    [IO.File]::WriteAllText(${q(ready.path)},'ready')\n"
            "    for (\$pause=0; \$pause -lt 400 -and -not (Test-Path -LiteralPath ${q(release.path)}); \$pause++) { Start-Sleep -Milliseconds 20 }\n"
            '',
      );
      final applying = service.applyPacEverywhere(pac.path);
      try {
        await waitFor(ready);
        await File(marker).writeAsString('off');
        transform = (script) => script.replaceFirst(
          '\$cleanupLock = Open-FFPacLock',
          "[IO.File]::WriteAllText(${q(cleanupReady.path)},'ready')\n\$cleanupLock = Open-FFPacLock",
        );
        final clearing = service.clearOwnedPac();
        await waitFor(cleanupReady);
        await release.writeAsString('release');
        expect(await applying, false);
        await clearing;
        expect(await state(), before);
        expect(entries(), isEmpty);
      } finally {
        await release.writeAsString('release');
        await applying;
      }
    },
    skip: !Platform.isWindows,
  );

  test(
    'failed restore retains only failed entries and succeeds on retry',
    () async {
      await seed();
      final before = await state();
      expect(await service.applyPacEverywhere(pac.path), true);
      transform = (script) => script.replaceFirst(
        'function Write-FFPacState([string]\$key,[string]\$name,\$state) {',
        "function Write-FFPacState([string]\$key,[string]\$name,\$state) {\nif (\$name -ceq 'ProxyMode') { throw 'injected restore failure' }",
      );
      await expectLater(service.clearOwnedPac(), throwsStateError);
      expect(entries(), hasLength(2));
      transform = null;
      await service.clearOwnedPac();
      expect(await state(), before);
      expect(entries(), isEmpty);
    },
    skip: !Platform.isWindows,
  );
}
