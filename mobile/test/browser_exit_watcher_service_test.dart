import 'package:flutter_test/flutter_test.dart';
import 'package:six_clean_room/services/browser_exit_watcher_service.dart';

void main() {
  test('browser exit watcher recognizes Aside process names', () {
    expect(BrowserExitWatcherService.watchesImage('Aside.exe'), isTrue);
    expect(BrowserExitWatcherService.watchesImage('aside.exe'), isTrue);
    expect(
      BrowserExitWatcherService.watchesImage('not-a-browser.exe'),
      isFalse,
    );
  });
}
