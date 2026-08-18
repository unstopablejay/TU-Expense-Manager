// Reading a snapshot as a ledger.
//
// SnapshotStore is the second implementation of the join in
// AppDatabase.transactions(). The database version cannot be tested here — there
// is no sqflite in a unit test, which is why the app has no DB tests at all — so
// what these assert is the *contract* the SQL states: the ordering its ORDER BY
// clauses produce, the category name its JOIN attaches, the split lines its
// second query groups, and the merge rules canonicaliseLedger applies.
//
// If one of these fails after a change to database.dart, the two have drifted,
// and the symptom in the field would be the phone and the PC disagreeing about
// what the same ledger says.

import 'package:flutter_test/flutter_test.dart';
import 'package:tu_expense_tracker/main.dart';

Map<String, Object?> category(int id, String name) =>
    <String, Object?>{'id': id, 'name': name};

Map<String, Object?> txn({
  required int id,
  required double amount,
  required String merchant,
  required int date,
  int categoryId = 1,
  String direction = 'debit',
  String reference = '',
  String note = '',
  String? paymentType = 'CARD X1',
}) =>
    <String, Object?>{
      'id': id,
      'amount': amount,
      'payment_type': paymentType,
      'merchant': merchant,
      'date': date,
      'category_id': categoryId,
      'direction': direction,
      'reference': reference,
      'note': note,
    };

Map<String, Object?> split({
  required int id,
  required int transactionId,
  required int categoryId,
  required double amount,
  required int position,
}) =>
    <String, Object?>{
      'id': id,
      'transaction_id': transactionId,
      'category_id': categoryId,
      'amount': amount,
      'position': position,
    };

BackupData snapshot({
  List<Map<String, Object?>>? categories,
  List<Map<String, Object?>>? transactions,
  List<Map<String, Object?>>? splits,
  List<Map<String, Object?>>? aliases,
  Map<String, String>? meta,
}) =>
    BackupData(
      categories: categories ??
          <Map<String, Object?>>[
            category(1, kUncategorized),
            category(2, 'Grocery'),
            category(3, 'Food'),
          ],
      merchantMappings: const <Map<String, Object?>>[],
      transactions: transactions ?? const <Map<String, Object?>>[],
      splits: splits ?? const <Map<String, Object?>>[],
      deleted: const <Map<String, Object?>>[],
      aliases: aliases ?? const <Map<String, Object?>>[],
      appMeta: const <Map<String, Object?>>[],
      meta: meta ??
          <String, String>{
            'format': kBackupFormat,
            'format_version': '$kBackupFormatVersion',
            'schema_version': '$kSchemaVersion',
          },
    );

void main() {
  group('ordering, as the ORDER BY clauses state it', () {
    test('transactions come back newest first', () {
      // ORDER BY t.date DESC
      final SnapshotStore store = SnapshotStore.fromBackup(snapshot(
        transactions: <Map<String, Object?>>[
          txn(id: 1, amount: 10, merchant: 'OLDEST', date: 1000),
          txn(id: 2, amount: 20, merchant: 'NEWEST', date: 3000),
          txn(id: 3, amount: 30, merchant: 'MIDDLE', date: 2000),
        ],
      ));
      expect(
        store.transactions.map((ExpenseTxn t) => t.merchant),
        <String>['NEWEST', 'MIDDLE', 'OLDEST'],
      );
    });

    test('a tie on date is broken by id, highest first', () {
      // ORDER BY t.date DESC, t.id DESC — load-bearing for UPI alerts, which
      // carry a date but no clock time, so same-day rows share a timestamp.
      final SnapshotStore store = SnapshotStore.fromBackup(snapshot(
        transactions: <Map<String, Object?>>[
          txn(id: 1, amount: 10, merchant: 'FIRST', date: 1000),
          txn(id: 3, amount: 30, merchant: 'THIRD', date: 1000),
          txn(id: 2, amount: 20, merchant: 'SECOND', date: 1000),
        ],
      ));
      expect(
        store.transactions.map((ExpenseTxn t) => t.id),
        <int>[3, 2, 1],
      );
    });

    test('split lines keep their saved order', () {
      // ORDER BY s.transaction_id, s.position, s.id. Not cosmetic: the editor
      // puts the rounding remainder on the last line, so a shuffled set does
      // not sum the way it was saved.
      final SnapshotStore store = SnapshotStore.fromBackup(snapshot(
        transactions: <Map<String, Object?>>[
          txn(id: 7, amount: 1000, merchant: 'AMAZON', date: 1000, categoryId: 2),
        ],
        splits: <Map<String, Object?>>[
          split(id: 30, transactionId: 7, categoryId: 3, amount: 300, position: 2),
          split(id: 10, transactionId: 7, categoryId: 2, amount: 500, position: 0),
          split(id: 20, transactionId: 7, categoryId: 1, amount: 200, position: 1),
        ],
      ));
      expect(
        store.transactions.single.splits.map((TxnSplit s) => s.amount),
        <double>[500, 200, 300],
      );
    });

    test('a tie on position is broken by id, lowest first', () {
      final SnapshotStore store = SnapshotStore.fromBackup(snapshot(
        transactions: <Map<String, Object?>>[
          txn(id: 7, amount: 300, merchant: 'X', date: 1000, categoryId: 2),
        ],
        splits: <Map<String, Object?>>[
          split(id: 9, transactionId: 7, categoryId: 3, amount: 200, position: 0),
          split(id: 4, transactionId: 7, categoryId: 2, amount: 100, position: 0),
        ],
      ));
      expect(
        store.transactions.single.splits.map((TxnSplit s) => s.amount),
        <double>[100, 200],
      );
    });

    test('categories put Uncategorized first, then alphabetical', () {
      // CASE WHEN name = 'Uncategorized' THEN 0 ELSE 1 END, name ASC
      final SnapshotStore store = SnapshotStore.fromBackup(snapshot(
        categories: <Map<String, Object?>>[
          category(5, 'Travel'),
          category(2, 'Grocery'),
          category(1, kUncategorized),
          category(3, 'Fuel'),
        ],
      ));
      expect(
        store.categories.map((ExpenseCategory c) => c.name),
        <String>[kUncategorized, 'Fuel', 'Grocery', 'Travel'],
      );
    });

    test('category ordering ignores case, as a NOCASE column does', () {
      final SnapshotStore store = SnapshotStore.fromBackup(snapshot(
        categories: <Map<String, Object?>>[
          category(1, kUncategorized),
          category(2, 'Fuel'),
          category(3, 'food'),
        ],
      ));
      expect(
        store.categories.map((ExpenseCategory c) => c.name),
        <String>[kUncategorized, 'food', 'Fuel'],
        reason: 'a case-sensitive sort would put Fuel before food',
      );
    });
  });

  group('the join', () {
    test('a transaction carries its category name', () {
      final SnapshotStore store = SnapshotStore.fromBackup(snapshot(
        transactions: <Map<String, Object?>>[
          txn(id: 1, amount: 10, merchant: 'X', date: 1000, categoryId: 3),
        ],
      ));
      expect(store.transactions.single.categoryName, 'Food');
    });

    test('a split line carries its own category name, not its parent\'s', () {
      final SnapshotStore store = SnapshotStore.fromBackup(snapshot(
        transactions: <Map<String, Object?>>[
          txn(id: 7, amount: 800, merchant: 'AMAZON', date: 1000, categoryId: 2),
        ],
        splits: <Map<String, Object?>>[
          split(id: 1, transactionId: 7, categoryId: 2, amount: 500, position: 0),
          split(id: 2, transactionId: 7, categoryId: 3, amount: 300, position: 1),
        ],
      ));
      expect(
        store.transactions.single.splits.map((TxnSplit s) => s.categoryName),
        <String>['Grocery', 'Food'],
      );
    });

    test('split lines attach to the right transaction', () {
      final SnapshotStore store = SnapshotStore.fromBackup(snapshot(
        transactions: <Map<String, Object?>>[
          txn(id: 1, amount: 100, merchant: 'A', date: 2000, categoryId: 2),
          txn(id: 2, amount: 200, merchant: 'B', date: 1000, categoryId: 3),
        ],
        splits: <Map<String, Object?>>[
          split(id: 1, transactionId: 2, categoryId: 2, amount: 150, position: 0),
          split(id: 2, transactionId: 2, categoryId: 3, amount: 50, position: 1),
        ],
      ));
      final List<ExpenseTxn> out = store.transactions;
      expect(out.first.merchant, 'A');
      expect(out.first.splits, isEmpty, reason: 'an unsplit row has no lines');
      expect(out.last.merchant, 'B');
      expect(out.last.splits.length, 2);
    });

    test('an unsplit transaction reports one synthesised line for its total', () {
      // effectiveSplits is what every total in the app reads, so an unsplit row
      // has to answer it the same way the database-backed one does.
      final SnapshotStore store = SnapshotStore.fromBackup(snapshot(
        transactions: <Map<String, Object?>>[
          txn(id: 1, amount: 250.75, merchant: 'X', date: 1000, categoryId: 3),
        ],
      ));
      final List<TxnSplit> effective = store.transactions.single.effectiveSplits;
      expect(effective.length, 1);
      expect(effective.single.amount, 250.75);
      expect(effective.single.categoryName, 'Food');
    });
  });

  group('merged names are applied on read', () {
    test('a merchant alias resolves', () {
      final SnapshotStore store = SnapshotStore.fromBackup(snapshot(
        transactions: <Map<String, Object?>>[
          txn(id: 1, amount: 10, merchant: 'SWIGGY LTD', date: 2000),
          txn(id: 2, amount: 20, merchant: 'Swiggy', date: 1000),
        ],
        aliases: <Map<String, Object?>>[
          <String, Object?>{
            'kind': 'merchant',
            'alias': 'swiggy ltd',
            'canonical': 'Swiggy',
          },
        ],
      ));
      expect(
        store.transactions.map((ExpenseTxn t) => t.merchant),
        <String>['Swiggy', 'Swiggy'],
      );
    });

    test('a card alias resolves', () {
      final SnapshotStore store = SnapshotStore.fromBackup(snapshot(
        transactions: <Map<String, Object?>>[
          txn(
            id: 1,
            amount: 10,
            merchant: 'X',
            date: 1000,
            paymentType: 'HDFC Bank A/C *0444',
          ),
        ],
        aliases: <Map<String, Object?>>[
          <String, Object?>{
            'kind': 'payment_type',
            'alias': 'hdfc bank a/c *0444',
            'canonical': 'HDFC 0444',
          },
        ],
      ));
      expect(store.transactions.single.paymentType, 'HDFC 0444');
    });
  });

  group('a snapshot that is odd rather than invalid still renders', () {
    test('a category_id naming no category reads as Uncategorized', () {
      // validateBackup would have caught this. If one slips through anyway, a
      // visibly odd row tells the user where to look; a crash tells them nothing.
      final SnapshotStore store = SnapshotStore.fromBackup(snapshot(
        transactions: <Map<String, Object?>>[
          txn(id: 1, amount: 10, merchant: 'X', date: 1000, categoryId: 99),
        ],
      ));
      expect(store.transactions.single.categoryName, kUncategorized);
    });

    test('an empty snapshot is an empty ledger, not an error', () {
      final SnapshotStore store = SnapshotStore.fromBackup(snapshot());
      expect(store.transactions, isEmpty);
      expect(store.categories.length, 3);
    });
  });

  group('what the snapshot says about itself', () {
    test('exportedAt parses the Meta timestamp', () {
      final SnapshotStore store = SnapshotStore.fromBackup(snapshot(
        meta: <String, String>{
          'format': kBackupFormat,
          'exported_at': '2026-08-18T21:04:33.000Z',
          'transactions': '412',
        },
      ));
      expect(store.exportedAt, DateTime.utc(2026, 8, 18, 21, 4, 33));
      expect(store.claimedTransactions, 412);
    });

    test('a snapshot with no timestamp says so rather than guessing', () {
      // The web UI greys a stale timestamp. "No timestamp" is a different
      // state from "old", and reporting it as now would be a lie.
      final SnapshotStore store = SnapshotStore.fromBackup(snapshot(
        meta: <String, String>{'format': kBackupFormat},
      ));
      expect(store.exportedAt, isNull);
      expect(store.claimedTransactions, isNull);
    });
  });

  test('a snapshot survives the wire and still reads the same', () {
    // The path an actual sync takes: exportAll -> JSON -> HTTP -> JSON -> here.
    final BackupData original = snapshot(
      transactions: <Map<String, Object?>>[
        txn(id: 1, amount: 1200.0, merchant: 'SWIGGY', date: 2000, categoryId: 2),
        txn(id: 2, amount: 39.5, merchant: 'AMAZON', date: 1000, categoryId: 3),
      ],
      splits: <Map<String, Object?>>[
        split(id: 1, transactionId: 1, categoryId: 2, amount: 800.0, position: 0),
        split(id: 2, transactionId: 1, categoryId: 3, amount: 400.0, position: 1),
      ],
    );

    final SnapshotStore direct = SnapshotStore.fromBackup(original);
    final SnapshotStore overWire =
        SnapshotStore.fromBackup(decodeBackupJson(encodeBackupJson(original)));

    expect(
      overWire.transactions.map((ExpenseTxn t) => t.merchant),
      direct.transactions.map((ExpenseTxn t) => t.merchant),
    );
    expect(
      overWire.transactions.map((ExpenseTxn t) => t.amount),
      direct.transactions.map((ExpenseTxn t) => t.amount),
    );
    expect(
      overWire.transactions.first.splits.map((TxnSplit s) => s.amount),
      <double>[800.0, 400.0],
    );
  });
}
