import 'package:flutter/material.dart';

import '../services/local_database.dart';
import '../theme/app_colors.dart';

/// Trash. Items live here for 30 days after delete, then auto-purge.
/// Restore brings the item back to its schedule (or always-on if its
/// schedule was deleted in the meantime).
class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key});

  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

class _TrashScreenState extends State<TrashScreen> {
  final LocalDatabase _db = LocalDatabase.instance;
  List<Map<String, Object?>> _trashedDomains = <Map<String, Object?>>[];
  List<Map<String, Object?>> _trashedKeywords = <Map<String, Object?>>[];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final List<Map<String, Object?>> d = await _db.trashedDomains();
    final List<Map<String, Object?>> k = await _db.trashedKeywords();
    if (!mounted) return;
    setState(() {
      _trashedDomains = d;
      _trashedKeywords = k;
    });
  }

  Future<void> _restoreDomain(String id) async {
    await _db.restoreDomain(id);
    await _reload();
  }

  Future<void> _restoreKeyword(String id) async {
    await _db.restoreKeyword(id);
    await _reload();
  }

  Future<void> _hardDelDomain(String id, String host) async {
    final bool? ok = await _confirmHardDelete(host);
    if (ok != true) return;
    await _db.hardDeleteDomain(id);
    await _reload();
  }

  Future<void> _hardDelKeyword(String id, String pattern) async {
    final bool? ok = await _confirmHardDelete(pattern);
    if (ok != true) return;
    await _db.hardDeleteKeyword(id);
    await _reload();
  }

  Future<bool?> _confirmHardDelete(String label) {
    return showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('완전 삭제'),
        content: Text('"$label" 항목을 휴지통에서 완전 삭제합니다. 되돌릴 수 없습니다.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('취소'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('완전 삭제'),
          ),
        ],
      ),
    );
  }

  String _retentionLabel(int deletedAtMs) {
    final DateTime t = DateTime.fromMillisecondsSinceEpoch(deletedAtMs);
    final DateTime purgeAt = t.add(const Duration(days: 30));
    final Duration left = purgeAt.difference(DateTime.now());
    if (left.isNegative) return '곧 영구 삭제';
    return '${left.inDays}일 후 영구 삭제';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('휴지통 (30일 보관)')),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            Text(
              '삭제한 사이트·키워드는 30일 동안 보관됩니다. 그 안에 복원하면 원래대로 돌아오고, 30일이 지나면 자동으로 영구 삭제됩니다.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppColors.muted, height: 1.4),
            ),
            const SizedBox(height: 16),
            Text('사이트 (${_trashedDomains.length})',
                style: Theme.of(context).textTheme.titleSmall),
            const Divider(),
            if (_trashedDomains.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('비어 있음', style: TextStyle(color: AppColors.muted)),
              ),
            ..._trashedDomains.map((Map<String, Object?> r) {
              final String id = r['id']! as String;
              final String host = r['host']! as String;
              final int deletedAt = (r['deleted_at']! as int);
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.public),
                title: Text(host),
                subtitle: Text(_retentionLabel(deletedAt),
                    style: const TextStyle(color: AppColors.muted)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    TextButton.icon(
                      onPressed: () => _restoreDomain(id),
                      icon: const Icon(Icons.restore),
                      label: const Text('복원'),
                    ),
                    IconButton(
                      onPressed: () => _hardDelDomain(id, host),
                      icon: const Icon(Icons.delete_forever_outlined,
                          color: AppColors.danger),
                      tooltip: '완전 삭제',
                    ),
                  ],
                ),
              );
            }),
            const SizedBox(height: 20),
            Text('키워드 (${_trashedKeywords.length})',
                style: Theme.of(context).textTheme.titleSmall),
            const Divider(),
            if (_trashedKeywords.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text('비어 있음', style: TextStyle(color: AppColors.muted)),
              ),
            ..._trashedKeywords.map((Map<String, Object?> r) {
              final String id = r['id']! as String;
              final String p = r['pattern']! as String;
              final int deletedAt = (r['deleted_at']! as int);
              return ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.tag),
                title: Text(p),
                subtitle: Text(_retentionLabel(deletedAt),
                    style: const TextStyle(color: AppColors.muted)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    TextButton.icon(
                      onPressed: () => _restoreKeyword(id),
                      icon: const Icon(Icons.restore),
                      label: const Text('복원'),
                    ),
                    IconButton(
                      onPressed: () => _hardDelKeyword(id, p),
                      icon: const Icon(Icons.delete_forever_outlined,
                          color: AppColors.danger),
                      tooltip: '완전 삭제',
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}
