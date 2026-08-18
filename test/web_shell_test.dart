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

  /// Overrides for a specific path, so a test can force a status.
  final Map<String, http.Response> canned = <String, http.Response>{};

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
                'last_seen': DateTime.now().toUtc().toIso8601String(),
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

  testWidgets('the list is read-only: no delete, no tap-to-edit',
      (WidgetTester tester) async {
    // Nullable callbacks rather than a flag, so this is what "read-only" means
    // in practice — the tiles render themselves non-interactive.
    final StubServer server = StubServer()
      ..devices['phone'] = "Jay's Pixel"
      ..snapshots['phone'] = snapshotFor(merchant: 'SWIGGY');

    await pumpShell(tester, server);
    await tester.tap(find.text('Transactions'));
    await tester.pumpAndSettle();

    final TransactionsTab tab =
        tester.widget<TransactionsTab>(find.byType(TransactionsTab, skipOffstage: false));
    expect(tab.onTap, isNull);
    expect(tab.onDelete, isNull);
    expect(tab.onToggleSelected, isNull);
    // But the view controls still work: they are local and useful anywhere.
    expect(tab.onFiltersChanged, isNotNull);
    expect(tab.onSortChanged, isNotNull);
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
}
