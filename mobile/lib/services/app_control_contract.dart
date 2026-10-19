import 'browser_management_control.dart';

class AppControlContract {
  static const resources = [
    'policy',
    'domains',
    'keywords',
    'schedules',
    'browser-switches',
    'quick-block',
    'components',
    'browser-management',
    'youtube-exemptions',
    'game-budget',
    'browser-performance',
  ];
  static const schemas = <String, Object?>{
    'resources': resources,
    'argumentSchemas': {
      ...BrowserManagementControl.argumentSchemas,
      'browser.performance': {
        'youtubeFeedFiltering':
            'required bool; Firefox YouTube feed filtering only',
      },
      'gameBudget.configure': {
        'maxMinutes': 'integer 1..1440; pooled daily local-midnight budget',
        'warningMinutes': 'integer 0..<maxMinutes; warning remaining threshold',
        'targets':
            '1..100 explicit executable filenames without paths or wildcards',
        'enabled':
            'true; weakening and lock checks remain in the existing service',
      },
      'youtube.exemptions.preview': {
        'targets': '1..50 nonempty target URLs, max 2048 characters each',
      },
      'youtube.exemptions.add': {
        'targets': '1..50 explicit targets; budget exemptions only',
      },
      'youtube.exemptions.remove': {
        'targets': '1..50 explicit targets; budget exemptions only',
      },
      'chat.preview': {
        'message': 'nonempty string, max 8000 characters',
        'resolution': 'optional existing/new',
        'forceScheduleId': 'optional nonempty schedule ID',
      },
      'chat.apply': {
        'message': 'nonempty string, max 8000 characters',
        'resolution': 'optional existing/new',
        'forceScheduleId': 'optional nonempty schedule ID',
        'debugOverride':
            'optional bool; bypass schedule edit cooldown for authenticated CLI',
      },
      'app.keepFirefoxOpen': <String, Object?>{},
      'app.holdBrowsers': <String, Object?>{},
      'components.reload': <String, Object?>{},
      'app.releaseBrowserHold': {
        'debugOverride':
            'optional bool; authenticated local CLI may bypass hold minimum and app policy lock for this browser hold only',
      },
      'quickBlock.clear': {
        'debugOverride':
            'optional bool; authenticated local CLI may bypass active quick-block timer and app lock',
      },
      'quickBlock.testLease.begin': {
        'durationMinutes':
            'integer 1..60; temporarily release only an explicit browser hold',
        'debugOverride': 'required true; authenticated local CLI test action',
      },
      'quickBlock.testLease.end': {
        'debugOverride':
            'required true; restore the original browser hold immediately',
      },
      'app.blockChrome': {
        'hours': 'integer from 1 to 72; refuses existing quick session',
      },
      'rule.add': {
        'type': ['domain', 'keyword'],
        'value': 'nonempty string, max 2048 chars',
      },
      'rule.remove': {
        'type': ['domain', 'keyword'],
        'value': 'exact normalized host or exact keyword pattern',
        'debugOverride':
            'optional bool; bypass app/schedule lock for this rule only',
      },
      'rule.setEnabled': {
        'type': ['domain', 'keyword'],
        'value': 'exact normalized host or exact keyword pattern',
        'enabled': 'required bool',
        'debugOverride':
            'optional bool; bypass app/schedule lock for this rule only',
      },
      'schedule.setEnabled': {
        'scheduleId': 'required existing schedule ID',
        'enabled': 'required bool',
        'debugOverride':
            'optional bool; bypass app/schedule lock for this schedule only',
      },
      'browser.enable': {
        'browser': ['chrome', 'edge', 'firefox', 'aside'],
      },
      'browser.disable': {
        'browser': ['chrome', 'edge', 'firefox', 'aside'],
        'debugOverride':
            'optional bool; bypass app lock for this browser switch only',
      },
      'policy.patch': {
        'adultSitesBlocked': 'optional bool',
        'forceSafeSearch': 'optional bool',
        'strictness': ['standard', 'strict'],
      },
    },
    'unsupported': {
      'autostart-and-recovery': 'Not exposed yet; retain current user choices',
      'pin-unlock-and-uninstall':
          'Requires existing identity/lock flow; no bypass endpoint',
      'arbitrary-sql-shell-or-memory': 'Not provided by app control API',
      'os-elevation': 'Windows consent is external to app automation',
      'other-app-features':
          'Not yet registered; schema is the source of supported coverage',
    },
  };

  static void validate(String action, Map<String, Object?> args) {
    if (BrowserManagementControl.actions.containsKey(action)) {
      BrowserManagementControl.validate(action, args);
      return;
    }
    final allowed = switch (action) {
      'browser.performance' => {'youtubeFeedFiltering'},
      'gameBudget.configure' => {
        'maxMinutes',
        'warningMinutes',
        'targets',
        'enabled',
      },
      'youtube.exemptions.preview' ||
      'youtube.exemptions.add' ||
      'youtube.exemptions.remove' => {'targets'},
      'chat.preview' => {'message', 'resolution', 'forceScheduleId'},
      'chat.apply' => {
        'message',
        'resolution',
        'forceScheduleId',
        'debugOverride',
      },
      'app.blockChrome' => {'hours'},
      'app.releaseBrowserHold' => {'debugOverride'},
      'quickBlock.clear' => {'debugOverride'},
      'quickBlock.testLease.begin' => {'durationMinutes', 'debugOverride'},
      'quickBlock.testLease.end' => {'debugOverride'},
      'rule.add' => {'type', 'value'},
      'rule.remove' => {'type', 'value', 'debugOverride'},
      'rule.setEnabled' => {'type', 'value', 'enabled', 'debugOverride'},
      'schedule.setEnabled' => {'scheduleId', 'enabled', 'debugOverride'},
      'browser.enable' => {'browser'},
      'browser.disable' => {'browser', 'debugOverride'},
      'policy.patch' => {'adultSitesBlocked', 'forceSafeSearch', 'strictness'},
      _ => <String>{},
    };
    if (args.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('Unknown arguments');
    }
    if (action == 'browser.performance' &&
        args['youtubeFeedFiltering'] is! bool) {
      throw const FormatException('Expected youtubeFeedFiltering bool');
    }
    if (action == 'gameBudget.configure') {
      final minutes = args['maxMinutes'];
      final warning = args['warningMinutes'];
      final targets = args['targets'];
      if (minutes is! int ||
          minutes < 1 ||
          minutes > 1440 ||
          warning is! int ||
          warning < 0 ||
          warning >= minutes ||
          args['enabled'] != true ||
          targets is! List ||
          targets.isEmpty ||
          targets.length > 100 ||
          targets.any(
            (value) =>
                value is! String ||
                !RegExp(
                  r'^[A-Za-z0-9][A-Za-z0-9 _().-]{0,119}\.exe$',
                  caseSensitive: false,
                ).hasMatch(value),
          )) {
        throw const FormatException('Invalid pooled daily game budget');
      }
      if (targets
              .map((value) => (value as String).toLowerCase())
              .toSet()
              .length !=
          targets.length) {
        throw const FormatException('Duplicate game executable');
      }
    }
    if (action.startsWith('youtube.exemptions.')) {
      final targets = args['targets'];
      if (targets is! List ||
          targets.isEmpty ||
          targets.length > 50 ||
          targets.any(
            (value) =>
                value is! String ||
                value.trim().isEmpty ||
                value.length > 2048 ||
                value.contains(RegExp(r'[\x00-\x1f]')),
          )) {
        throw const FormatException('Expected 1..50 explicit targets');
      }
    }
    if (action == 'chat.preview' || action == 'chat.apply') {
      final message = args['message'];
      if (message is! String ||
          message.trim().isEmpty ||
          message.length > 8000 ||
          (args.containsKey('resolution') &&
              !['existing', 'new'].contains(args['resolution'])) ||
          (args.containsKey('forceScheduleId') &&
              (args['forceScheduleId'] is! String ||
                  (args['forceScheduleId'] as String).trim().isEmpty ||
                  (args['forceScheduleId'] as String).length > 200)) ||
          (args.containsKey('debugOverride') &&
              (action != 'chat.apply' || args['debugOverride'] is! bool))) {
        throw const FormatException('Invalid chat request');
      }
    }
    if (action == 'app.blockChrome' &&
        (args['hours'] is! int ||
            (args['hours'] as int) < 1 ||
            (args['hours'] as int) > 72)) {
      throw const FormatException('Hours must be an integer from 1 to 72');
    }
    if (action == 'app.releaseBrowserHold' &&
        args.containsKey('debugOverride') &&
        args['debugOverride'] is! bool) {
      throw const FormatException('debugOverride must be a bool');
    }
    if (action == 'quickBlock.clear' &&
        args.containsKey('debugOverride') &&
        args['debugOverride'] is! bool) {
      throw const FormatException('debugOverride must be a bool');
    }
    if ((action == 'quickBlock.testLease.begin' &&
            (args['durationMinutes'] is! int ||
                (args['durationMinutes'] as int) < 1 ||
                (args['durationMinutes'] as int) > 60 ||
                args['debugOverride'] != true)) ||
        (action == 'quickBlock.testLease.end' &&
            args['debugOverride'] != true)) {
      throw const FormatException('Invalid authenticated test lease request');
    }
    if ((action == 'rule.remove' || action == 'rule.setEnabled') &&
        (!['domain', 'keyword'].contains(args['type']) ||
            args['value'] is! String ||
            (args['value'] as String).trim().isEmpty ||
            (args['value'] as String).length > 2048 ||
            (action == 'rule.setEnabled' && args['enabled'] is! bool) ||
            (args.containsKey('debugOverride') &&
                args['debugOverride'] is! bool))) {
      throw const FormatException('Invalid rule change');
    }
    if (action == 'schedule.setEnabled' &&
        (args['scheduleId'] is! String ||
            (args['scheduleId'] as String).trim().isEmpty ||
            args['enabled'] is! bool ||
            (args.containsKey('debugOverride') &&
                args['debugOverride'] is! bool))) {
      throw const FormatException('Invalid schedule change');
    }
    if (action == 'browser.disable' &&
        args.containsKey('debugOverride') &&
        args['debugOverride'] is! bool) {
      throw const FormatException('debugOverride must be a bool');
    }
    if (action == 'rule.add') {
      if (!['domain', 'keyword'].contains(args['type']) ||
          args['value'] is! String ||
          (args['value'] as String).trim().isEmpty ||
          (args['value'] as String).length > 2048) {
        throw const FormatException('Invalid rule');
      }
      if (args['type'] == 'domain') normalizeHost(args['value'] as String);
    }
    if (action == 'browser.enable' &&
        !['chrome', 'edge', 'firefox', 'aside'].contains(args['browser'])) {
      throw const FormatException('Unknown browser');
    }
    if (action == 'policy.patch') {
      if (args.isEmpty ||
          args.entries.any(
            (entry) => entry.key == 'strictness'
                ? !['standard', 'strict'].contains(entry.value)
                : entry.value is! bool,
          )) {
        throw const FormatException('Invalid policy patch');
      }
    }
  }

  static String normalizeHost(String value) {
    final uri = Uri.parse(value.contains('://') ? value : 'https://$value');
    if (!['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        RegExp(r'[\s/\\]').hasMatch(uri.host)) {
      throw const FormatException('Invalid domain');
    }
    return uri.host.toLowerCase().replaceFirst(RegExp(r'\.$'), '');
  }
}
