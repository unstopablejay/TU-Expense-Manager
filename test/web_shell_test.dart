// The browser's shell, against a stubbed server.
//
// The claim this file exists to check is the whole point of the refactor: that
// the browser renders the *same* DashboardTab and TransactionsTab the phone
// does, fed from a snapshot rather than from SQLite. Asserting the widgets are
// present and showing the snapshot's numbers is what makes that a fact rather
// than a hope.
//
// It also covers the states nobody thinks to build: no device has synced, the
// session expired mid-call, the download was truncated, the ledger is stale.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tu_expense_tracker/src/core/backup_data.dart';
import 'package:tu_expense_tracker/src/core/backup_json.dart';
import 'package:tu_expense_tracker/src/core/constants.dart';
import 'package:tu_expense_tracker/src/core/ledger.dart';
import 'package:tu_expense_tracker/src/core/link_state.dart';
import 'package:tu_expense_tracker/src/ui_shared/connection_dot.dart';
import 'package:tu_expense_tracker/src/ui_shared/dashboard_tab.dart';
import 'package:tu_expense_tracker/src/ui_shared/transactions_tab.dart';
import 'package:tu_expense_tracker/src/web/api_client.dart';
import 'package:tu_expense_tracker/src/web/session.dart';
import 'package:tu_expense_tracker/src/web/web_shell.dart';

/// A server that answers from a script rather than a socket.
class StubServer {
  StubServer();

  final List<String> calls = <String>[];

  /// device id -> snapshot body. A device absent here has not synced.
  final Map<String, String> snapshots = <String, String>{};

  /// device id -> label, in the order the device list should report them.
  final Map<String, String> devices = <String, String>{};

  /// device id -> when it last reported. Absent means "a moment ago".
  final Map<String, DateTime> lastSeen = <String, DateTime>{};

  /// device id -> the sync interval it reports, in minutes. Absent means it is
  /// a build old enough not to report one.
  final Map<String, int> syncMinutes = <String, int>{};

  /// Overrides for a specific path, so a test can force a status.
  final Map<String, http.Response> canned = <String, http.Response>{};

  /// Every edit posted to /api/v1/edits, decoded.
  final List<Map<String, Object?>> queuedEdits = <Map<String, Object?>>[];

  http.Client get client => _StubClient(this);
}

class _StubClient extends http.BaseClient {
  _StubClient(this.server);

  final StubServer server;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final String path = request.url.path;
    server.calls.add('${request.method} $path');

    final http.Response? forced = server.canned[path];
    if (forced != null) return _stream(forced);

    if (path == '/api/v1/devices') {
      return _stream(http.Response(
        jsonEncode(<String, Object?>{
          'ok': true,
          'devices': <Object?>[
            for (final MapEntry<String, String> e in server.devices.entries)
              <String, Object?>{
                'id': e.key,
                'label': e.value,
                'last_seen': (server.lastSeen[e.key] ?? DateTime.now())
                    .toUtc()
                    .toIso8601String(),
                'sync_interval_minutes': server.syncMinutes[e.key],
                'pending_edits': 0,
                'latest': server.snapshots.containsKey(e.key)
                    ? <String, Object?>{
                        'id': 'snap-${e.key}',
                        'counts': <String, Object?>{'transactions': '2'},
                      }
                    : null,
              },
          ],
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      ));
    }

    if (path == '/api/v1/snapshot') {
      final String? device = request.headers['X-Expense-Device'];
      final String? body = server.snapshots[device];
      if (body == null) {
        return _stream(http.Response(
          jsonEncode(<String, Object?>{'ok': false, 'error': 'no snapshot'}),
          404,
        ));
      }
      return _stream(http.Response.bytes(
        utf8.encode(body),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      ));
    }

    if (path == '/api/v1/edits' && request.method == 'POST') {
      final String body = await (request as http.Request).finalize().bytesToString();
      server.queuedEdits.add(jsonDecode(body) as Map<String, Object?>);
      return _stream(http.Response(
        jsonEncode(<String, Object?>{
          'ok': true,
          'pending': server.queuedEdits.length,
        }),
        201,
      ));
    }

    if (path == '/api/v1/logout') {
      return _stream(http.Response('{"ok":true}', 200));
    }

    return _stream(http.Response('{"ok":false,"error":"unhandled"}', 404));
  }

  Future<http.StreamedResponse> _stream(http.Response response) async =>
      http.StreamedResponse(
        Stream<List<int>>.value(response.bodyBytes),
        response.statusCode,
        headers: response.headers,
      );
}

/// A snapshot with two transactions in the current month, so the dashboard's
/// default period actually has something in it.
String snapshotFor({
  required String merchant,
  double first = 1200.0,
  double second = 300.0,
  DateTime? exportedAt,
}) {
  // Mid-month, so a test running on the 1st or the 31st sees the same thing.
  final DateTime now = DateTime.now();
  final DateTime when = DateTime(now.year, now.month, 15, 12);

  return encodeBackupJson(BackupData(
    categories: <Map<String, Object?>>[
      <String, Object?>{'id': 1, 'name': kUncategorized},
      <String, Object?>{'id': 2, 'name': 'Grocery'},
    ],
    merchantMappings: const <Map<String, Object?>>[],
    transactions: <Map<String, Object?>>[
      <String, Object?>{
        'id': 1,
        'amount': first,
        'payment_type': 'YES BANK Card X2858',
        'merchant': merchant,
        'date': when.millisecondsSinceEpoch,
        'category_id': 2,
        'direction': 'debit',
        'reference': '',
        'note': '',
      },
      <String, Object?>{
        'id': 2,
        'amount': second,
        'payment_type': 'YES BANK Card X2858',
        'merchant': '$merchant-TWO',
        'date': when.subtract(const Duration(hours: 2)).millisecondsSinceEpoch,
        'category_id': 1,
        'direction': 'debit',
        'reference': '',
        'note': '',
      },
    ],
    splits: const <Map<String, Object?>>[],
    deleted: const <Map<String, Object?>>[],
    aliases: const <Map<String, Object?>>[],
    appMeta: const <Map<String, Object?>>[],
    meta: buildBackupMeta(
      appVersion: '1.1.0',
      appBuild: '2',
      exportedAt: exportedAt ?? DateTime.now().toUtc(),
      transactions: 2,
      splits: 0,
      categories: 2,
      merchantDefaults: 0,
      nameAliases: 0,
      deleted: 0,
    ),
  ));
}

/// The nth TextField *inside the open dialog*.
///
/// Scoped deliberately: the transactions list behind the dialog has a search
/// field of its own, so an unscoped `find.byType(TextField)` types into that and
/// the test passes or fails for reasons that have nothing to do with the dialog.
Finder _dialogField(int index) => find
    .descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    )
    .at(index);

Future<WebSession> signedInSession() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  final WebSession session = WebSession();
  await session.restore();
  await session.signIn('a-token', 'jay');
  return session;
}

Future<void> pumpShell(WidgetTester tester, StubServer server) async {
  final WebSession session = await signedInSession();
  final ApiClient api = ApiClient(
    client: server.client,
    base: Uri.parse('http://localhost:8099/'),
  )..token = 'a-token';

  await tester.pumpWidget(MaterialApp(
    home: WebShell(api: api, session: session),
  ));
  // Two pumps and a settle: the shell fetches devices then the snapshot.
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('renders the shared tabs from a snapshot', (WidgetTester tester) async {
    // The claim in one test: the browser shows the phone's own widgets.
    final StubServer server = StubServer()
      ..devices['phone'] = "Jay's Pixel"
      ..snapshots['phone'] = snapshotFor(merchant: 'SWIGGY');

    await pumpShell(tester, server);

    expect(find.byType(DashboardTab), findsOneWidget);
    // skipOffstage: false, because IndexedStack keeps the unselected child in
    // the tree but offstage, and find.byType skips offstage widgets by default.
    expect(
      find.byType(TransactionsTab, skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('the ledger it shows is the one the server sent',
      (WidgetTester tester) async {
    final StubServer server = StubServer()
      ..devices['phone'] = "Jay's Pixel"
      ..snapshots['phone'] = snapshotFor(merchant: 'DISTINCTIVEMERCHANT');

    await pumpShell(tester, server);
    await tester.tap(find.text('Transactions'));
    await tester.pumpAndSettle();

    expect(find.textContaining('DISTINCTIVEMERCHANT'), findsWidgets);
  });

  testWidgets('a row can be edited, but not multi-selected',
      (WidgetTester tester) async {
    // What the browser can and cannot do, stated as the callbacks it passes.
    // Multi-select stays null because it exists to drive a bulk delete, and a
    // bulk delete would be one queued edit per row with no way to undo the set
    // as a set.
    final StubServer server = StubServer()
      ..devices['phone'] = "Jay's Pixel"
      ..snapshots['phone'] = snapshotFor(merchant: 'SWIGGY');

    await pumpShell(tester, server);
    await tester.tap(find.text('Transactions'));
    await tester.pumpAndSettle();

    final TransactionsTab tab = tester.widget<TransactionsTab>(
        find.byType(TransactionsTab, skipOffstage: false));
    expect(tab.onTap, isNotNull);
    expect(tab.onDelete, isNotNull);
    expect(tab.onToggleSelected, isNull);
    expect(tab.onFiltersChanged, isNotNull);
    expect(tab.onSortChanged, isNotNull);
  });

  group('editing from the browser', () {
    Future<void> openFirstRow(WidgetTester tester, StubServer server) async {
      await pumpShell(tester, server);
      await tester.tap(find.text('Transactions'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('SWIGGY').first);
      await tester.pumpAndSettle();
    }

    StubServer withLedger() => StubServer()
      ..devices['phone'] = "Jay's Pixel"
      ..snapshots['phone'] = snapshotFor(merchant: 'SWIGGY');

    testWidgets('tapping a row offers the four queued operations',
        (WidgetTester tester) async {
      await openFirstRow(tester, withLedger());

      expect(find.text('Change category'), findsOneWidget);
      expect(find.textContaining('note'), findsWidgets);
      expect(find.textContaining('Split'), findsWidgets);
      expect(find.text('Delete'), findsOneWidget);
      // Says what will happen, rather than pretending it already has.
      expect(find.textContaining('next sync'), findsOneWidget);
    });

    testWidgets('changing a category queues an edit', (WidgetTester tester) async {
      final StubServer server = withLedger();
      await openFirstRow(tester, server);

      await tester.tap(find.text('Change category'));
      await tester.pumpAndSettle();
      // The transaction is on Grocery, so Uncategorized is a real change.
      await tester.tap(find.text(kUncategorized).last);
      await tester.pumpAndSettle();

      expect(server.queuedEdits.length, 1);
      expect(server.queuedEdits.single['op'], 'set_category');
      expect(
        (server.queuedEdits.single['payload']! as Map<String, Object?>)['category_id'],
        1,
      );
      expect(find.textContaining('Queued'), findsOneWidget);
    });

    testWidgets('the queued edit addresses the row by id and natural key',
        (WidgetTester tester) async {
      // Both halves, so a stale edit resolves to nothing rather than to whatever
      // now holds that id.
      final StubServer server = withLedger();
      await openFirstRow(tester, server);
      await tester.tap(find.text('Change category'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(kUncategorized).last);
      await tester.pumpAndSettle();

      final Map<String, Object?> edit = server.queuedEdits.single;
      expect(edit['txn_id'], isA<int>());
      expect(edit['natural_key'], isA<String>());
      expect(edit['natural_key'], contains('swiggy'),
          reason: 'the key is built from the merchant as stored, lower-cased');
      expect(edit['edit_id'], isA<String>());
    });

    testWidgets('editing a note queues it, and cancelling does not',
        (WidgetTester tester) async {
      final StubServer server = withLedger();
      await openFirstRow(tester, server);

      await tester.tap(find.text('Add a note'));
      await tester.pumpAndSettle();
      await tester.enterText(_dialogField(0), 'dinner with sam');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(server.queuedEdits.length, 1);
      expect(server.queuedEdits.single['op'], 'set_note');
      expect(
        (server.queuedEdits.single['payload']! as Map<String, Object?>)['note'],
        'dinner with sam',
      );
    });

    testWidgets('cancelling a note queues nothing', (WidgetTester tester) async {
      final StubServer server = withLedger();
      await openFirstRow(tester, server);

      await tester.tap(find.text('Add a note'));
      await tester.pumpAndSettle();
      await tester.enterText(_dialogField(0), 'typed then abandoned');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(server.queuedEdits, isEmpty);
    });

    testWidgets('a split has to add up before it can be saved',
        (WidgetTester tester) async {
      // The invariant saveSplits enforces on the phone, enforced here too — with
      // the same core arithmetic, so the two cannot disagree.
      final StubServer server = withLedger();
      await openFirstRow(tester, server);

      await tester.tap(find.textContaining('Split'));
      await tester.pumpAndSettle();

      // Opens balanced: the whole amount on its own category, plus an empty line.
      expect(find.text('Adds up.'), findsOneWidget);

      // Take some off the first line without putting it anywhere.
      await tester.enterText(_dialogField(0), '500');
      await tester.pumpAndSettle();
      expect(find.textContaining('still to allocate'), findsOneWidget);

      final FilledButton save = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save'),
      );
      expect(save.onPressed, isNull,
          reason: 'refusing now is better than the phone refusing at next sync');
    });

    testWidgets('Balance puts the remainder on the last line',
        (WidgetTester tester) async {
      final StubServer server = withLedger();
      await openFirstRow(tester, server);
      await tester.tap(find.textContaining('Split'));
      await tester.pumpAndSettle();

      await tester.enterText(_dialogField(0), '500');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Balance'));
      await tester.pumpAndSettle();

      expect(find.text('Adds up.'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      final Map<String, Object?> edit = server.queuedEdits.single;
      expect(edit['op'], 'save_splits');
      final List<Object?> lines =
          (edit['payload']! as Map<String, Object?>)['lines']! as List<Object?>;
      expect(lines.length, 2);
      // 1200 total, 500 typed, so 700 lands on the last line.
      expect((lines.last! as Map<String, Object?>)['amount'], 700.0);
    });

    testWidgets('deleting asks first, and says the rescan will not undo it',
        (WidgetTester tester) async {
      final StubServer server = withLedger();
      await openFirstRow(tester, server);

      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.textContaining('will not bring it back'), findsOneWidget);

      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();

      expect(server.queuedEdits.single['op'], 'delete_txn');
    });

    testWidgets('cancelling a delete queues nothing', (WidgetTester tester) async {
      final StubServer server = withLedger();
      await openFirstRow(tester, server);
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(server.queuedEdits, isEmpty);
    });

    testWidgets('the pending banner appears once something is queued',
        (WidgetTester tester) async {
      final StubServer server = withLedger();
      await openFirstRow(tester, server);
      await tester.tap(find.text('Change category'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(kUncategorized).last);
      await tester.pumpAndSettle();

      expect(find.textContaining('waiting'), findsOneWidget);
    });

    testWidgets('a refused queue attempt says so and claims nothing',
        (WidgetTester tester) async {
      final StubServer server = withLedger()
        ..canned['/api/v1/edits'] = http.Response(
          '{"ok":false,"error":"That edit was not accepted."}',
          400,
        );
      await openFirstRow(tester, server);
      await tester.tap(find.text('Change category'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(kUncategorized).last);
      await tester.pumpAndSettle();

      expect(find.textContaining('not accepted'), findsOneWidget);
      expect(find.textContaining('waiting'), findsNothing,
          reason: 'nothing is pending, so nothing should claim to be');
    });
  });

  testWidgets('filtering and sorting still work without a server round trip',
      (WidgetTester tester) async {
    final StubServer server = StubServer()
      ..devices['phone'] = "Jay's Pixel"
      ..snapshots['phone'] = snapshotFor(merchant: 'SWIGGY');

    await pumpShell(tester, server);
    await tester.tap(find.text('Transactions'));
    await tester.pumpAndSettle();

    final int before = server.calls.length;
    final TransactionsTab tab =
        tester.widget<TransactionsTab>(find.byType(TransactionsTab, skipOffstage: false));
    tab.onSortChanged(LedgerSort.largest);
    await tester.pumpAndSettle();

    expect(server.calls.length, before,
        reason: 'a sort must not go back to the server');
  });

  testWidgets('says so when nothing has synced yet', (WidgetTester tester) async {
    // The state a new install lands in, and the one most likely to be left as a
    // blank screen.
    await pumpShell(tester, StubServer());

    expect(find.textContaining('No device has synced'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('says so when a device exists but has never pushed',
      (WidgetTester tester) async {
    final StubServer server = StubServer()..devices['phone'] = "Jay's Pixel";
    await pumpShell(tester, server);

    expect(find.textContaining('has not synced'), findsOneWidget);
  });

  testWidgets('an expired session signs out rather than showing an error',
      (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final WebSession session = WebSession();
    await session.restore();
    await session.signIn('a-token', 'jay');

    final StubServer server = StubServer()
      ..canned['/api/v1/devices'] =
          http.Response('{"ok":false,"error":"unauthorized"}', 401);

    final ApiClient api = ApiClient(
      client: server.client,
      base: Uri.parse('http://localhost:8099/'),
    )..token = 'a-token';

    await tester.pumpWidget(MaterialApp(
      home: WebShell(api: api, session: session),
    ));
    await tester.pumpAndSettle();

    expect(session.signedIn, isFalse,
        reason: 'the login screen is the useful answer to an expired session, '
            'not a retry button that cannot work');
  });

  testWidgets('a truncated snapshot is a readable message, not a crash',
      (WidgetTester tester) async {
    final String whole = snapshotFor(merchant: 'SWIGGY');
    final StubServer server = StubServer()
      ..devices['phone'] = "Jay's Pixel"
      // Reported as synced, so the shell actually asks for a snapshot — without
      // this it correctly stops at "that device has not synced yet" and the
      // truncation is never reached.
      ..snapshots['phone'] = whole
      ..canned['/api/v1/snapshot'] = http.Response(
        whole.substring(0, whole.length ~/ 2),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );

    await pumpShell(tester, server);

    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.cloud_off_outlined), findsOneWidget);
  });

  testWidgets('somebody else\'s JSON is refused with a sentence',
      (WidgetTester tester) async {
    final StubServer server = StubServer()
      ..devices['phone'] = "Jay's Pixel"
      ..snapshots['phone'] = snapshotFor(merchant: 'SWIGGY')
      ..canned['/api/v1/snapshot'] = http.Response(
        '{"hello":"world"}',
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );

    await pumpShell(tester, server);

    expect(tester.takeException(), isNull);
    expect(find.textContaining('not a TU Expense Tracker snapshot'),
        findsOneWidget);
  });

  testWidgets('a fresh ledger is reported as such', (WidgetTester tester) async {
    final StubServer server = StubServer()
      ..devices['phone'] = "Jay's Pixel"
      ..snapshots['phone'] = snapshotFor(merchant: 'SWIGGY');

    await pumpShell(tester, server);

    expect(find.byIcon(Icons.cloud_done_outlined), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_outlined), findsNothing);
  });

  testWidgets('a stale ledger is flagged, so it cannot be read as current',
      (WidgetTester tester) async {
    // The single most useful thing this screen does: a week-old number that
    // looks current is worse than no number.
    final StubServer server = StubServer()
      ..devices['phone'] = "Jay's Pixel"
      ..snapshots['phone'] = snapshotFor(
        merchant: 'SWIGGY',
        exportedAt: DateTime.now().toUtc().subtract(const Duration(days: 7)),
      );

    await pumpShell(tester, server);

    expect(find.byIcon(Icons.warning_amber_outlined), findsOneWidget);
    expect(find.text('7 d ago'), findsOneWidget);
  });

  // Two tests rather than two pumps in one. pumpWidget reuses the State when the
  // widget type and key match, so a second pump does not re-run initState and the
  // shell would still be holding the first scenario's device list.
  testWidgets('no device picker when there is nothing to choose between',
      (WidgetTester tester) async {
    final StubServer server = StubServer()
      ..devices['phone'] = "Jay's Pixel"
      ..snapshots['phone'] = snapshotFor(merchant: 'SWIGGY');
    await pumpShell(tester, server);
    expect(find.byIcon(Icons.devices_outlined), findsNothing);
  });

  testWidgets('a device picker appears once there is a choice',
      (WidgetTester tester) async {
    final StubServer server = StubServer()
      ..devices['phone'] = "Jay's Pixel"
      ..devices['emulator'] = 'Emulator'
      ..snapshots['phone'] = snapshotFor(merchant: 'PHONE')
      ..snapshots['emulator'] = snapshotFor(merchant: 'EMU');
    await pumpShell(tester, server);
    expect(find.byIcon(Icons.devices_outlined), findsOneWidget);
  });

  testWidgets('switching device shows that device ledger, not the other one',
      (WidgetTester tester) async {
    // The two-device case, from the browser's side.
    final StubServer server = StubServer()
      ..devices['phone'] = "Jay's Pixel"
      ..devices['emulator'] = 'Emulator'
      ..snapshots['phone'] = snapshotFor(merchant: 'PHONELEDGER')
      ..snapshots['emulator'] = snapshotFor(merchant: 'EMULATORLEDGER');

    await pumpShell(tester, server);
    await tester.tap(find.text('Transactions'));
    await tester.pumpAndSettle();
    expect(find.textContaining('PHONELEDGER'), findsWidgets);

    await tester.tap(find.byIcon(Icons.devices_outlined));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Emulator').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('EMULATORLEDGER'), findsWidgets);
    expect(find.textContaining('PHONELEDGER'), findsNothing);
  });

  testWidgets('refresh re-fetches, because a mouse cannot pull down',
      (WidgetTester tester) async {
    final StubServer server = StubServer()
      ..devices['phone'] = "Jay's Pixel"
      ..snapshots['phone'] = snapshotFor(merchant: 'SWIGGY');

    await pumpShell(tester, server);
    final int before = server.calls.length;

    await tester.tap(find.byIcon(Icons.refresh));
    await tester.pumpAndSettle();

    expect(server.calls.length, greaterThan(before));
  });

  testWidgets('signing out ends the session', (WidgetTester tester) async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final WebSession session = WebSession();
    await session.restore();
    await session.signIn('a-token', 'jay');

    final StubServer server = StubServer()
      ..devices['phone'] = "Jay's Pixel"
      ..snapshots['phone'] = snapshotFor(merchant: 'SWIGGY');

    final ApiClient api = ApiClient(
      client: server.client,
      base: Uri.parse('http://localhost:8099/'),
    )..token = 'a-token';

    await tester.pumpWidget(MaterialApp(
      home: WebShell(api: api, session: session),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.logout));
    await tester.pumpAndSettle();

    expect(session.signedIn, isFalse);
    expect(api.token, isNull);
  });

  group('the connection light', () {
    LinkState lightIn(WidgetTester tester) =>
        tester.widget<ConnectionDot>(find.byType(ConnectionDot)).state;

    testWidgets('is green while the phone is in touch',
        (WidgetTester tester) async {
      final StubServer server = StubServer()
        ..devices['phone'] = "Jay's Pixel"
        ..snapshots['phone'] = snapshotFor(merchant: 'SWIGGY')
        ..syncMinutes['phone'] = 15
        ..lastSeen['phone'] = DateTime.now().subtract(const Duration(minutes: 3));

      await pumpShell(tester, server);

      expect(lightIn(tester), LinkState.connected);
    });

    testWidgets('is red once the phone has gone quiet for longer than its '
        'own interval explains', (WidgetTester tester) async {
      final StubServer server = StubServer()
        ..devices['phone'] = "Jay's Pixel"
        ..snapshots['phone'] = snapshotFor(merchant: 'SWIGGY')
        ..syncMinutes['phone'] = 15
        ..lastSeen['phone'] = DateTime.now().subtract(const Duration(hours: 4));

      await pumpShell(tester, server);

      expect(lightIn(tester), LinkState.disconnected);
    });

    testWidgets('does not call a phone on a long interval disconnected for '
        'being slow', (WidgetTester tester) async {
      // The reason the phone reports its interval at all. Forty minutes of
      // silence is a fault at fifteen-minute syncing and entirely normal at
      // hourly, and a light that could not tell them apart would be red all day
      // for anyone who moved the setting.
      final StubServer server = StubServer()
        ..devices['phone'] = "Jay's Pixel"
        ..snapshots['phone'] = snapshotFor(merchant: 'SWIGGY')
        ..syncMinutes['phone'] = 60
        ..lastSeen['phone'] = DateTime.now().subtract(const Duration(minutes: 40));

      await pumpShell(tester, server);

      expect(lightIn(tester), LinkState.connected);
    });

    testWidgets('is red when the server does not answer this browser either',
        (WidgetTester tester) async {
      final StubServer server = StubServer()
        ..devices['phone'] = "Jay's Pixel"
        ..snapshots['phone'] = snapshotFor(merchant: 'SWIGGY')
        ..canned['/api/v1/devices'] = http.Response('nope', 500);

      await pumpShell(tester, server);

      expect(lightIn(tester), LinkState.disconnected);
    });
  });
}
