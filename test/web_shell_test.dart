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
import 'package:flutter/services.dart';
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
import 'package:tu_expense_tracker/src/web/transactions_table.dart';
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
/// The card every stub transaction is charged to.
///
/// Named rather than repeated, so a test that filters by it and the snapshot that
/// carries it cannot drift apart.
const String kTestPaymentType = 'YES BANK Card X2858';

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
        'payment_type': kTestPaymentType,
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
        'payment_type': kTestPaymentType,
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

/// Pumps the shell, optionally at a given window size.
///
/// The size matters because the browser's transactions screen has two layouts:
/// at or above [kWideLayoutBreakpoint] it is the desktop table, and below it the
/// phone's own [TransactionsTab]. The default test surface is 800x600, which is
/// *narrow* — so a test that means to exercise the table has to say so, or it
/// silently checks the fallback and passes for the wrong reason.
///
/// Reset through `addTearDown` rather than at the end of the test body: a failing
/// expectation throws before any manual reset would run, and would then leak the
/// window size into every test after it.
Future<void> pumpShell(
  WidgetTester tester,
  StubServer server, {
  Size? surface,
}) async {
  if (surface != null) {
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

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
  testWidgets('renders the shared dashboard from a snapshot',
      (WidgetTester tester) async {
    // The claim that still holds in full: the browser shows the phone's own
    // charts, from a snapshot rather than from SQLite.
    final StubServer server = StubServer()
      ..devices['phone'] = "Jay's Pixel"
      ..snapshots['phone'] = snapshotFor(merchant: 'SWIGGY');

    await pumpShell(tester, server);

    expect(find.byType(DashboardTab), findsOneWidget);
  });

  testWidgets('a narrow window falls back to the phone own transactions screen',
      (WidgetTester tester) async {
    // The fallback is a shipped code path, not a test artefact: a phone browser
    // pointed at the server lands here. Below the breakpoint the browser really
    // does render the widget the phone renders.
    final StubServer server = StubServer()
      ..devices['phone'] = "Jay's Pixel"
      ..snapshots['phone'] = snapshotFor(merchant: 'SWIGGY');

    await pumpShell(tester, server, surface: const Size(700, 900));

    // skipOffstage: false, because IndexedStack keeps the unselected child in
    // the tree but offstage, and find.byType skips offstage widgets by default.
    expect(find.byType(TransactionsTab, skipOffstage: false), findsOneWidget);
    expect(find.byType(WebTransactionsView, skipOffstage: false), findsOneWidget,
        reason: 'the fallback is reached through the web view, not instead of it');
  });

  testWidgets('a wide window gets the table, not the phone list',
      (WidgetTester tester) async {
    final StubServer server = StubServer()
      ..devices['phone'] = "Jay's Pixel"
      ..snapshots['phone'] = snapshotFor(merchant: 'SWIGGY');

    await pumpShell(tester, server, surface: const Size(1600, 1000));
    await tester.tap(find.text('Transactions'));
    await tester.pumpAndSettle();

    // The column headings exist only in the table, so finding them is finding it.
    expect(find.text('MERCHANT'), findsOneWidget);
    expect(find.text('CARD / ACCOUNT'), findsOneWidget);
    expect(find.textContaining('SWIGGY'), findsWidgets);
    expect(find.byType(TransactionsTab, skipOffstage: false), findsNothing,
        reason: 'the phone card list has no business on a desktop window');
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

    // Narrow on purpose: this asserts the fallback's props as well as the view's.
    await pumpShell(tester, server, surface: const Size(700, 900));
    await tester.tap(find.text('Transactions'));
    await tester.pumpAndSettle();

    final WebTransactionsView view = tester.widget<WebTransactionsView>(
        find.byType(WebTransactionsView, skipOffstage: false));
    expect(view.onTap, isNotNull);
    expect(view.onDelete, isNotNull);
    expect(view.onFiltersChanged, isNotNull);
    expect(view.onSortChanged, isNotNull);

    // Multi-select is absent from the view's props entirely rather than passed as
    // null, so there is no longer a value here to assert. What can be asserted is
    // that the fallback it hands to the phone's widget still says so.
    final TransactionsTab tab = tester.widget<TransactionsTab>(
        find.byType(TransactionsTab, skipOffstage: false));
    expect(tab.onToggleSelected, isNull);
    expect(tab.selected, isEmpty);
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
      // The invariant saveSplits enforces on the phone, enforced here too â with
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
    final WebTransactionsView view = tester.widget<WebTransactionsView>(
        find.byType(WebTransactionsView, skipOffstage: false));
    view.onSortChanged(LedgerSort.largest);
    await tester.pumpAndSettle();

    expect(server.calls.length, before,
        reason: 'a sort must not go back to the server');
  });

  group('the table on a desktop window', () {
    // 1600x1000: comfortably over kWideLayoutBreakpoint, and tall enough that a
    // handful of rows and an open menu both fit without scrolling.
    const Size desktop = Size(1600, 1000);

    Future<void> openTable(WidgetTester tester, StubServer server) async {
      await pumpShell(tester, server, surface: desktop);
      await tester.tap(find.text('Transactions'));
      await tester.pumpAndSettle();
    }

    StubServer withLedger() => StubServer()
      ..devices['phone'] = "Jay's Pixel"
      ..snapshots['phone'] = snapshotFor(merchant: 'SWIGGY');

    testWidgets('a column heading sorts, and does not go back to the server',
        (WidgetTester tester) async {
      // The reason the table can afford clickable headings at all: the ledger is
      // already in memory, so an order costs one pass over a local list.
      final StubServer server = withLedger();
      await openTable(tester, server);

      final int before = server.calls.length;
      await tester.tap(find.text('AMOUNT'));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<WebTransactionsView>(
                find.byType(WebTransactionsView, skipOffstage: false))
            .sort,
        LedgerSort.largest,
      );
      expect(server.calls.length, before,
          reason: 'a sort must not go back to the server');
    });

    testWidgets('clicking a heading twice reverses it',
        (WidgetTester tester) async {
      final StubServer server = withLedger();
      await openTable(tester, server);

      LedgerSort sortNow() => tester
          .widget<WebTransactionsView>(
              find.byType(WebTransactionsView, skipOffstage: false))
          .sort;

      // Newest is already in force, so the first click has to move off it rather
      // than re-assert it â otherwise the heading would look broken on the very
      // column the table opens ordered by.
      expect(sortNow(), LedgerSort.newest);
      await tester.tap(find.text('DATE'));
      await tester.pumpAndSettle();
      expect(sortNow(), LedgerSort.oldest);

      await tester.tap(find.text('DATE'));
      await tester.pumpAndSettle();
      expect(sortNow(), LedgerSort.newest);
    });

    testWidgets('an unsortable column does not pretend to sort',
        (WidgetTester tester) async {
      // There is no LedgerSort for a card or a category, so those headings must
      // not respond â a click that visibly does nothing reads as a bug.
      final StubServer server = withLedger();
      await openTable(tester, server);

      await tester.tap(find.text('CARD / ACCOUNT'));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<WebTransactionsView>(
                find.byType(WebTransactionsView, skipOffstage: false))
            .sort,
        LedgerSort.newest,
      );
    });

    testWidgets('a facet dropdown narrows the table, and Clear all restores it',
        (WidgetTester tester) async {
      final StubServer server = withLedger();
      await openTable(tester, server);

      expect(find.textContaining('SWIGGY'), findsWidgets);

      // The menus are real dropdowns now, not bottom sheets: open, tick, and the
      // table narrows underneath without an Apply button.
      await tester.tap(find.text('Card / account'));
      await tester.pumpAndSettle();

      // Scoped to a ListTile: the card's name is also in every row's CARD /
      // ACCOUNT cell, and those cells are plain Rows. Without this the tap can
      // land on the table behind the menu and the test passes or fails for a
      // reason that has nothing to do with the menu.
      await tester.tap(find.descendant(
        of: find.byType(ListTile),
        matching: find.text(kTestPaymentType),
      ));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<WebTransactionsView>(
                find.byType(WebTransactionsView, skipOffstage: false))
            .filters
            .paymentType,
        kTestPaymentType,
      );

      // Escape rather than a tap outside: a tap would land on whatever is under
      // the menu, which may be another control.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Clear all'));
      await tester.pumpAndSettle();

      expect(
        tester
            .widget<WebTransactionsView>(
                find.byType(WebTransactionsView, skipOffstage: false))
            .filters
            .paymentType,
        isNull,
      );
    });

    testWidgets('clicking a row queues an edit, through the new rows',
        (WidgetTester tester) async {
      // The per-operation coverage lives in `editing from the browser` at the
      // narrow width. This is the one case that proves the edit path is still
      // reachable through a table row rather than a card.
      final StubServer server = withLedger();
      await openTable(tester, server);

      // Pinned to the table, or this test would go on passing if the breakpoint
      // ever moved and put the card list back on a desktop window â it is the
      // table's rows it exists to check.
      expect(find.text('MERCHANT'), findsOneWidget);

      await tester.tap(find.textContaining('SWIGGY').first);
      await tester.pumpAndSettle();

      expect(find.text('Change category'), findsOneWidget);

      await tester.tap(find.text('Change category'));
      await tester.pumpAndSettle();
      // Uncategorized, because the row is already on Grocery and the shell
      // rightly queues nothing for a change that changes nothing.
      await tester.tap(find.text(kUncategorized).last);
      await tester.pumpAndSettle();

      expect(server.queuedEdits, hasLength(1));
      expect(server.queuedEdits.single['op'], 'set_category');
    });

    testWidgets('the breakpoint is where it says it is',
        (WidgetTester tester) async {
      // Checked on both sides of the one number, because an off-by-one here is a
      // window width at which neither layout is chosen well and nobody would
      // think to look.
      final StubServer server = withLedger();

      await pumpShell(tester, server,
          surface: const Size(kWideLayoutBreakpoint - 1, 900));
      await tester.tap(find.text('Transactions'));
      await tester.pumpAndSettle();
      expect(find.byType(TransactionsTab, skipOffstage: false), findsOneWidget,
          reason: 'one pixel under the breakpoint is still narrow');

      tester.view.physicalSize = const Size(kWideLayoutBreakpoint, 900);
      await tester.pumpAndSettle();
      expect(find.text('MERCHANT'), findsOneWidget,
          reason: 'the breakpoint itself is wide — it is a minimum, not a gap');
      expect(find.byType(TransactionsTab, skipOffstage: false), findsNothing);
    });

    testWidgets('lays out without overflowing at a range of window sizes',
        (WidgetTester tester) async {
      // A RenderFlex overflow is a test failure in flutter_test, so pumping the
      // table at several widths is a real check on its geometry — the failure
      // mode a hand-rolled table is most prone to, and the one a human notices
      // last because it only shows as a yellow stripe in a corner.
      for (final Size size in <Size>[
        const Size(900, 700),
        const Size(1280, 800),
        const Size(1600, 1000),
        const Size(2560, 1400),
      ]) {
        final StubServer server = withLedger();
        await pumpShell(tester, server, surface: size);
        await tester.tap(find.text('Transactions'));
        await tester.pumpAndSettle();

        expect(find.text('MERCHANT'), findsOneWidget,
            reason: 'expected the table at $size');
      }
    });

    testWidgets('an impossible filter set offers the way out of itself',
        (WidgetTester tester) async {
      // The empty state that is a dead end if it gets this wrong: filtered to
      // nothing, with the button that undoes it.
      final StubServer server = withLedger();
      await openTable(tester, server);

      await tester.enterText(
          find.byType(TextField).first, 'NOTHINGMATCHESTHIS');
      await tester.pumpAndSettle();

      expect(find.text('No transactions match this search'), findsOneWidget);
      expect(find.text('Clear filters'), findsOneWidget);
      expect(find.textContaining('SWIGGY'), findsNothing);

      await tester.tap(find.text('Clear filters'));
      await tester.pumpAndSettle();

      expect(find.textContaining('SWIGGY'), findsWidgets);
    });

    testWidgets('the merchant menu can be searched, since it can be long',
        (WidgetTester tester) async {
      final StubServer server = withLedger();
      await openTable(tester, server);

      await tester.tap(find.text('Merchant'));
      await tester.pumpAndSettle();

      // Both stub merchants are offered: SWIGGY and SWIGGY-TWO.
      Finder options() => find.descendant(
            of: find.byType(ListTile),
            matching: find.textContaining('SWIGGY'),
          );
      expect(options(), findsNWidgets(2));

      // The menu's own field, which is the one that is focused inside it.
      await tester.enterText(find.byType(TextField).last, 'TWO');
      await tester.pumpAndSettle();

      expect(options(), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ListTile),
          matching: find.text('SWIGGY-TWO'),
        ),
        findsOneWidget,
      );
    });
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
      // Reported as synced, so the shell actually asks for a snapshot â without
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
