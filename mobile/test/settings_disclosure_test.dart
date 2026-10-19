import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/widgets/settings_disclosure.dart';

void main() {
  testWidgets('closed diagnostics do not start probes and closing stops them', (
    tester,
  ) async {
    var ticks = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SettingsDisclosure(
            title: '상세 진단',
            subtitle: '필요할 때만 확인',
            builder: (_) => _Probe(onTick: () => ticks++),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(seconds: 2));
    expect(ticks, 0);
    await tester.tap(find.text('상세 진단'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 2));
    expect(ticks, greaterThan(0));
    await tester.tap(find.text('상세 진단'));
    await tester.pumpAndSettle();
    final stopped = ticks;
    await tester.pump(const Duration(seconds: 3));
    expect(ticks, stopped);
    await tester.pumpWidget(const SizedBox());
  });
}

class _Probe extends StatefulWidget {
  const _Probe({required this.onTick});
  final VoidCallback onTick;
  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  late final Timer _timer;
  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => widget.onTick());
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const Text('진단 실행 중');
}
