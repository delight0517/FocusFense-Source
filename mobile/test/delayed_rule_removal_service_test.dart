import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:six_clean_room/models/scheduled_rule_removal.dart';
import 'package:six_clean_room/services/delayed_rule_removal_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  test('keeps a scheduled removal after the service is recreated', () async {
    final DelayedRuleRemovalService first =
        DelayedRuleRemovalService.forTesting(deleteRule: (_) async {});
    await first.scheduleRemoval(
      ruleKind: ScheduledRuleKind.domain,
      ruleId: 'domain-1',
      label: 'example.com',
    );
    first.dispose();

    final DelayedRuleRemovalService afterRestart =
        DelayedRuleRemovalService.forTesting(deleteRule: (_) async {});
    final List<ScheduledRuleRemoval> pending = await afterRestart.loadPending();

    expect(pending, hasLength(1));
    expect(pending.single.ruleId, 'domain-1');
    expect(pending.single.label, 'example.com');
    expect(
      pending.single.dueAt.difference(DateTime.now()).inMinutes,
      inInclusiveRange(179, 180),
    );
    afterRestart.dispose();
  });

  test('applies an overdue removal when the app starts again', () async {
    final List<ScheduledRuleRemoval> deleted = <ScheduledRuleRemoval>[];
    final DelayedRuleRemovalService beforeShutdown =
        DelayedRuleRemovalService.forTesting(
          deleteRule: (ScheduledRuleRemoval item) async => deleted.add(item),
        );
    await beforeShutdown.scheduleRemoval(
      ruleKind: ScheduledRuleKind.keyword,
      ruleId: 'keyword-1',
      label: 'casino',
      delay: const Duration(seconds: -1),
    );
    beforeShutdown.dispose();

    final DelayedRuleRemovalService afterRestart =
        DelayedRuleRemovalService.forTesting(
          deleteRule: (ScheduledRuleRemoval item) async => deleted.add(item),
        );
    await afterRestart.start();

    expect(deleted, hasLength(1));
    expect(deleted.single.ruleId, 'keyword-1');
    expect(await afterRestart.loadPending(), isEmpty);
    afterRestart.dispose();
  });

  test('cancels a removal before its due time', () async {
    final DelayedRuleRemovalService service =
        DelayedRuleRemovalService.forTesting(deleteRule: (_) async {});
    await service.scheduleRemoval(
      ruleKind: ScheduledRuleKind.domain,
      ruleId: 'domain-2',
      label: 'keep.com',
    );

    expect(
      await service.cancelRemoval(
        ruleKind: ScheduledRuleKind.domain,
        ruleId: 'domain-2',
      ),
      isTrue,
    );
    expect(await service.loadPending(), isEmpty);
    service.dispose();
  });
}
