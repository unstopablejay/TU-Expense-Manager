// Deciding when to sync.
//
// VM only: [AutoSync] is the phone's, and it reaches [SyncClient], which reaches
// sqflite. The scheduling below is what these tests are about — whether a sync
// happens at all, and how often — never what a sync does, which is
// `sync_client`'s business and needs a database.
@TestOn('vm')
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tu_expense_tracker/main.dart';

/// A [SyncClient] that counts calls instead of opening sockets.
///
/// Subclassed rather than mocked through an interface: the seam [AutoSync] needs
/// is one method, and an interface for it would exist only to be implemented
/// twice.
class RecordingSync extends SyncClient {
  RecordingSync() : super();

  int calls = 0;
  final List<bool> forced = <bool>[];

  @override
  Future<SyncOutcome> syncNow({VoidCallback? onChanged, bool force = true}) async {
    calls++;
    forced.add(force);
    return const SyncOutcome.ok(transactions: 3);
  }
}

/// Preferences for a phone that is signed in to a server.
void signedIn({bool auto = true, int minutes = kDefaultAutoSyncMinutes}) {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'sync.base_url': 'http://192.168.1.99:8099',
    'sync.token': 'a-session',
    'sync.username': 'jay',
    'sync.device_id': 'abcdefabcdefabcd',
    'sync.auto': auto,
    'sync.auto_minutes': minutes,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('when a sync happens', () {
    testWidgets('on start, without waiting for the first interval',
        (WidgetTester tester) async {
      signedIn();
      final RecordingSync sync = RecordingSync();
      final AutoSync auto = AutoSync(client: sync);

      await auto.start(onChanged: () {});
      await tester.pump();

      expect(sync.calls, 1);
      auto.stop();
    });

    testWidgets('again on every interval', (WidgetTester tester) async {
      signedIn(minutes: 5);
      final RecordingSync sync = RecordingSync();
      final AutoSync auto = AutoSync(client: sync);

      await auto.start(onChanged: () {});
      await tester.pump();
      expect(sync.calls, 1);

      await tester.pump(const Duration(minutes: 5));
      await tester.pump();
      expect(sync.calls, 2);

      await tester.pump(const Duration(minutes: 5));
      await tester.pump();
      expect(sync.calls, 3);

      auto.stop();
    });

    testWidgets('never with force, so an unchanged ledger is not re-uploaded',
        (WidgetTester tester) async {
      signedIn(minutes: 5);
      final RecordingSync sync = RecordingSync();
      final AutoSync auto = AutoSync(client: sync);

      await auto.start(onChanged: () {});
      await tester.pump(const Duration(minutes: 5));
      await tester.pump();

      expect(sync.forced, everyElement(isFalse));
      auto.stop();
    });

    testWidgets('a local change is pushed once the run of them has settled',
        (WidgetTester tester) async {
      signedIn();
      final RecordingSync sync = RecordingSync();
      final AutoSync auto = AutoSync(client: sync);

      await auto.start(onChanged: () {});
      await tester.pump();
      expect(sync.calls, 1);

      // Somebody categorising a screenful, one row at a time.
      for (int i = 0; i < 5; i++) {
        auto.nudge();
        await tester.pump(const Duration(seconds: 2));
      }
      expect(sync.calls, 1, reason: 'still typing — nothing should have gone');

      await tester.pump(kAutoSyncSettle);
      await tester.pump();
      expect(sync.calls, 2, reason: 'five edits, one upload');

      auto.stop();
    });
  });

  group('when it stays out of the way', () {
    testWidgets('switched off, nothing happens at all',
        (WidgetTester tester) async {
      signedIn(auto: false);
      final RecordingSync sync = RecordingSync();
      final AutoSync auto = AutoSync(client: sync);

      await auto.start(onChanged: () {});
      await tester.pump(const Duration(hours: 2));
      await tester.pump();

      expect(sync.calls, 0);
      auto.stop();
    });

    testWidgets('with no server configured, nothing happens either',
        (WidgetTester tester) async {
      // The state a user who has never opened the sync settings is in. They
      // should never see a network call, and never an error about one.
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final RecordingSync sync = RecordingSync();
      final AutoSync auto = AutoSync(client: sync);

      await auto.start(onChanged: () {});
      await tester.pump(const Duration(hours: 2));
      await tester.pump();

      expect(sync.calls, 0);
      auto.stop();
    });

    testWidgets('signed out but with an address set, still nothing',
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'sync.base_url': 'http://192.168.1.99:8099',
      });
      final RecordingSync sync = RecordingSync();
      final AutoSync auto = AutoSync(client: sync);

      await auto.start(onChanged: () {});
      await tester.pump();

      expect(sync.calls, 0);
      auto.stop();
    });

    testWidgets('a burst of resumes is one sync, not four',
        (WidgetTester tester) async {
      signedIn();
      final RecordingSync sync = RecordingSync();
      final AutoSync auto = AutoSync(client: sync);

      await auto.start(onChanged: () {});
      await tester.pump();
      expect(sync.calls, 1);

      // A notification shade, a permission dialog, a share sheet: Android sends
      // these in quick succession and each one is a resume.
      for (int i = 0; i < 3; i++) {
        auto.didChangeAppLifecycleState(AppLifecycleState.paused);
        auto.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await tester.pump();
      }

      expect(sync.calls, 1);
      auto.stop();
    });

    testWidgets('nothing keeps ticking after stop', (WidgetTester tester) async {
      signedIn(minutes: 5);
      final RecordingSync sync = RecordingSync();
      final AutoSync auto = AutoSync(client: sync);

      await auto.start(onChanged: () {});
      await tester.pump();
      auto.stop();

      await tester.pump(const Duration(hours: 1));
      await tester.pump();

      expect(sync.calls, 1);
    });

    testWidgets('a paused app does not sync in the background',
        (WidgetTester tester) async {
      signedIn(minutes: 5);
      final RecordingSync sync = RecordingSync();
      final AutoSync auto = AutoSync(client: sync);

      await auto.start(onChanged: () {});
      await tester.pump();
      auto.didChangeAppLifecycleState(AppLifecycleState.paused);

      await tester.pump(const Duration(hours: 1));
      await tester.pump();

      expect(sync.calls, 1, reason: 'only the one from start');
      auto.stop();
    });
  });

  group('the interval setting', () {
    testWidgets('a longer one is honoured immediately, not next launch',
        (WidgetTester tester) async {
      signedIn(minutes: 5);
      final RecordingSync sync = RecordingSync();
      final AutoSync auto = AutoSync(client: sync);

      await auto.start(onChanged: () {});
      await tester.pump();

      await SyncPrefs.instance.setAutoMinutes(60);
      await auto.resume();
      await tester.pump();
      expect(sync.calls, 2, reason: 'changing the setting syncs there and then');

      await tester.pump(const Duration(minutes: 5));
      await tester.pump();
      expect(sync.calls, 2, reason: 'the five-minute timer is gone');

      await tester.pump(const Duration(minutes: 55));
      await tester.pump();
      expect(sync.calls, 3);

      auto.stop();
    });

    test('is clamped, so a hand-edited file cannot ask for a busy loop',
        () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'sync.auto_minutes': 0,
      });
      expect(await SyncPrefs.instance.autoMinutes(), kMinAutoSyncMinutes);

      await SyncPrefs.instance.setAutoMinutes(-5);
      expect(await SyncPrefs.instance.autoMinutes(), kMinAutoSyncMinutes);

      await SyncPrefs.instance.setAutoMinutes(999999);
      expect(await SyncPrefs.instance.autoMinutes(), kMaxAutoSyncMinutes);
    });

    test('reads in words the way the switch describes it', () {
      expect(describeSyncInterval(1), 'Every minute');
      expect(describeSyncInterval(15), 'Every 15 minutes');
      expect(describeSyncInterval(60), 'Every hour');
      expect(describeSyncInterval(120), 'Every 2 hours');
    });
  });

  group('defaults', () {
    test('automatic sync is on, because the browser needs it to be', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      expect(await SyncPrefs.instance.auto(), isTrue);
      expect(await SyncPrefs.instance.autoMinutes(), kDefaultAutoSyncMinutes);
    });

    test('uploading after a scan is still opt-in', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      expect(await SyncPrefs.instance.autoAfterScan(), isFalse);
    });
  });
}
