import 'dart:async';

import 'package:flutter/material.dart';

import '../services/brainwire_blocklist_sync_service.dart';

class BrainwireSyncSettingsCard extends StatefulWidget {
  const BrainwireSyncSettingsCard({super.key});

  @override
  State<BrainwireSyncSettingsCard> createState() =>
      _BrainwireSyncSettingsCardState();
}

class _BrainwireSyncSettingsCardState extends State<BrainwireSyncSettingsCard> {
  bool _connected = false;
  bool _busy = true;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
  }

  Future<void> _refresh() async {
    final bool connected =
        await BrainwireBlocklistSyncService.instance.isConnected;
    if (mounted) {
      setState(() {
        _connected = connected;
        _busy = false;
      });
    }
  }

  Future<void> _run(Future<void> Function() action, String success) async {
    setState(() => _busy = true);
    try {
      await action();
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(success)));
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('BlueCloud 오류: $error')));
      }
    } finally {
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    final BrainwireBlocklistSyncService service =
        BrainwireBlocklistSyncService.instance;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'BlueCloud (Brainwire) 동기화',
              style: Theme.of(context).textTheme.titleSmall,
            ),
            const SizedBox(height: 6),
            const Text(
              '같은 Brainwire Google 계정을 연결한 기기 사이에 스케줄, 웹사이트·키워드 차단 규칙, 앱 차단 목록을 동기화합니다.',
            ),
            const SizedBox(height: 6),
            Text(
              _busy
                  ? '상태 확인 중…'
                  : _connected
                  ? (service.status ?? '이 기기 연결됨')
                  : '연결 안 됨',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              children: <Widget>[
                if (!_connected)
                  FilledButton.icon(
                    onPressed: _busy
                        ? null
                        : () => _run(
                            service.connectAndSync,
                            'BlueCloud 연결 및 동기화 완료',
                          ),
                    icon: const Icon(Icons.cloud_sync),
                    label: const Text('Google 계정 연결'),
                  )
                else ...<Widget>[
                  FilledButton.tonalIcon(
                    onPressed: _busy
                        ? null
                        : () => _run(service.syncNow, 'BlueCloud 동기화 완료'),
                    icon: const Icon(Icons.sync),
                    label: const Text('지금 동기화'),
                  ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => _run(
                            service.disconnect,
                            '이 기기의 BlueCloud 연결을 해제했습니다.',
                          ),
                    child: const Text('연결 해제'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
