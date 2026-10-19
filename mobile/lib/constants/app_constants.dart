/// Must match [ios/Runner/Runner.entitlements] and Apple Developer App Group.
const String kAppGroupId = 'group.com.sixcleanroom.sixCleanRoom';

const String kRulesChannelName = 'six_clean_room/rules';

/// Shared file consumed later by Safari Web Extension / Share Extension.
const String kRulesFileName = 'rules_v1.json';

/// Written by iOS Share extension; merged into SQLite on next app resume.
const String kPendingShareHostsFile = 'pending_share_hosts.json';
