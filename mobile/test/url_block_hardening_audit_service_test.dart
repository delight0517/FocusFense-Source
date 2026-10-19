import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/services/url_block_hardening_audit_service.dart';

void main() {
  test('URL block hardening catalog tracks exactly 15 failure modes', () {
    final List<UrlBlockFailureMode> catalog =
        UrlBlockHardeningAuditService.failureModeCatalog;
    final Set<String> ids = catalog
        .map((UrlBlockFailureMode m) => m.id)
        .toSet();

    expect(catalog, hasLength(15));
    expect(ids, hasLength(15));
    expect(ids, contains('numeric_mirror_rotation_gap'));
    expect(ids, contains('false_success_after_uac_or_acl'));
  });
}
