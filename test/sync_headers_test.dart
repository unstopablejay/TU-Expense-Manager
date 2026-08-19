// What the phone tells the server about itself.
//
// VM only: SyncClient imports dart:io.
//
// These headers are how the browser's connection light knows anything at all. The
// device id says whose ledger this is, and the interval says how long silence
// from that device is normal — without it the light has to guess at a schedule
// and is wrong for anybody who changed the setting.
@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tu_expense_tracker/main.dart';

/// Records the headers of every request and answers the minimum.
class HeaderSpy extends http.BaseClient {
  final List<({String path, Map<String, String> headers})> sent =
      <({String path, Map<String, String> headers})>[];

  Map<String, String>? headersFor(String path) {
    for (final ({String path, Map<String, String> headers}) call in sent) {
      if (call.path == path) return call.headers;
    }
    return null;
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sent.add((path: request.url.path, headers: request.headers));
    return http.StreamedResponse(
      Stream<List<int>>.value(
        // An empty queue for /edits, and enough of a body that nothing downstream
        // trips over it.
        '{"ok":true,"edits":[],"devices":[],"token":"t","username":"jay"}'
            .codeUnits,
      ),
      200,
    );
  }
}

void signedIn({bool auto = true, int minutes = 15}) {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'sync.base_url': 'http://192.168.1.99:8099',
    'sync.token': 'a-session',
    'sync.username': 'jay',
    'sync.device_id': 'abcdefabcdefabcd',
    'sync.device_label': 'Test phone',
    'sync.auto': auto,
    'sync.auto_minutes': minutes,
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the sync interval header', () {
    test('rides on the edit-queue pull, which is what the server counts as '
        'checking in', () async {
      signedIn(minutes: 5);
      final HeaderSpy spy = HeaderSpy();

      // Fails at the export step, which needs a database — by which point the
      // queue has already been pulled, and that request is what this is about.
      await SyncClient(client: spy).syncNow();

      final Map<String, String>? headers = spy.headersFor('/api/v1/edits');
      expect(headers, isNotNull, reason: 'the queue should have been pulled');
      expect(headers!['x-expense-sync-interval'], '5');
      expect(headers['x-expense-device'], 'abcdefabcdefabcd');
    });

    test('rides on the login too, so a phone says its schedule before it has '
        'ever synced', () async {
      signedIn(minutes: 30);
      final HeaderSpy spy = HeaderSpy();

      await SyncClient(client: spy).signIn(
        base: Uri.parse('http://192.168.1.99:8099'),
        username: 'jay',
        password: 'hunter2',
      );

      expect(
        spy.headersFor('/api/v1/login')!['x-expense-sync-interval'],
        '30',
      );
    });

    test('is absent when automatic sync is off, because then there is no '
        'schedule to describe', () async {
      // The device is reachable only when somebody presses Sync. The browser is
      // better off saying nothing about it than implying a cadence that does not
      // exist.
      signedIn(auto: false);
      final HeaderSpy spy = HeaderSpy();

      await SyncClient(client: spy).syncNow();

      expect(
        spy.headersFor('/api/v1/edits')!.containsKey('x-expense-sync-interval'),
        isFalse,
      );
    });
  });
}
