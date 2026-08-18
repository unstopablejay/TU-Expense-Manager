/// A snapshot, read as the ledger the screens expect.
///
/// The web build has no SQLite, so this does in Dart what `AppDatabase` does in
/// SQL: joins the category names on, attaches the split lines, orders the rows,
/// and applies the merge rules. What comes out is what `AppDatabase.transactions()`
/// and `AppDatabase.categories()` return, so `DashboardTab` and `TransactionsTab`
/// cannot tell which of the two produced it — which is the whole point.
library;

import 'aliases.dart';
import 'backup_data.dart';
import 'constants.dart';
import 'models.dart';
import 'splits.dart';

/// One snapshot, joined and ordered, ready to hand to the shared tabs.
///
/// **This is the second implementation of one join.** The first is
/// `AppDatabase.transactions()` in `lib/src/mobile/database.dart`, and the two
/// must agree: any difference shows up as the phone and the PC disagreeing about
/// what the same ledger says. `test/snapshot_store_test.dart` pins the shape
/// that keeps them honest, and neither should be changed without the other.
class SnapshotStore {
  const SnapshotStore._({
    required this.transactions,
    required this.categories,
    required this.meta,
  });

  /// Builds the ledger [data] describes.
  ///
  /// Does no validation — run `validateBackup` first. This assumes referential
  /// integrity and is deliberately forgiving where it cannot: a transaction
  /// whose `category_id` names no category reads as Uncategorized rather than
  /// throwing, because a snapshot that fails to render tells the user nothing,
  /// while one rendered with a visibly odd row tells them where to look.
  factory SnapshotStore.fromBackup(BackupData data) {
    final Map<int, String> categoryNames = <int, String>{
      for (final Map<String, Object?> row in data.categories)
        if (row['id'] is int && row['name'] is String)
          row['id']! as int: row['name']! as String,
    };

    return SnapshotStore._(
      transactions: _ledger(data, categoryNames),
      categories: _categories(data),
      meta: data.meta,
    );
  }

  /// The whole ledger, newest first, with merged names already applied.
  final List<ExpenseTxn> transactions;

  /// Every category, Uncategorized first and the rest alphabetical.
  final List<ExpenseCategory> categories;

  /// The snapshot's Meta block — when it was taken, and by which build.
  final Map<String, String> meta;

  /// When the snapshot was taken, or null if it does not say.
  ///
  /// The web UI shows this and greys it once stale. A validated snapshot with no
  /// timestamp is readable but not trustworthy as *current*, and the difference
  /// is worth surfacing rather than assuming.
  DateTime? get exportedAt {
    final String? raw = meta['exported_at'];
    return raw == null ? null : DateTime.tryParse(raw);
  }

  /// How many transactions the snapshot claims to hold.
  ///
  /// From the Meta block rather than from [transactions], so it can be compared
  /// against what was actually decoded.
  int? get claimedTransactions => int.tryParse(meta['transactions'] ?? '');
}

/// `AppDatabase.categories()` without the SQL.
///
/// Uncategorized pinned to the top and the rest alphabetical — the same order
/// the `CASE WHEN name = 'Uncategorized' THEN 0 ELSE 1 END, name ASC` clause
/// produces, because the picker's first entry should not move between targets.
List<ExpenseCategory> _categories(BackupData data) {
  final List<ExpenseCategory> out = data.categories
      .where((Map<String, Object?> row) =>
          row['id'] is int && row['name'] is String)
      .map(ExpenseCategory.fromMap)
      .toList()
    ..sort((ExpenseCategory a, ExpenseCategory b) {
      final int aFirst = a.name.toLowerCase() == kUncategorized.toLowerCase() ? 0 : 1;
      final int bFirst = b.name.toLowerCase() == kUncategorized.toLowerCase() ? 0 : 1;
      return aFirst != bFirst
          ? aFirst - bFirst
          // SQLite's `name ASC` on a NOCASE column is case-insensitive, so the
          // comparison here has to be too, or the two targets order a list
          // containing both `Fuel` and `food` differently.
          : a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
  return out;
}

/// `AppDatabase.transactions()` without the SQL.
List<ExpenseTxn> _ledger(BackupData data, Map<int, String> categoryNames) {
  // Grouped in one sweep, exactly as the two-query version does. The splits
  // table holds rows only for transactions that were actually split, so it stays
  // a great deal smaller than the ledger.
  final Map<int, List<TxnSplit>> splits = <int, List<TxnSplit>>{};
  final List<Map<String, Object?>> splitRows =
      List<Map<String, Object?>>.of(data.splits)
        ..sort(_bySplitOrder);
  for (final Map<String, Object?> row in splitRows) {
    final Object? txnId = row['transaction_id'];
    final Object? categoryId = row['category_id'];
    if (txnId is! int || categoryId is! int) continue;
    (splits[txnId] ??= <TxnSplit>[]).add(TxnSplit.fromMap(<String, Object?>{
      ...row,
      // TxnSplit.fromMap wants the joined name; SQL supplies it via the JOIN.
      'category_name': categoryNames[categoryId] ?? kUncategorized,
    }));
  }

  final List<Map<String, Object?>> rows =
      List<Map<String, Object?>>.of(data.transactions)..sort(_byNewestFirst);

  return canonicaliseLedger(
    <ExpenseTxn>[
      for (final Map<String, Object?> row in rows)
        if (row['id'] is int)
          ExpenseTxn.fromMap(
            <String, Object?>{
              ...row,
              'category_name':
                  categoryNames[row['category_id']] ?? kUncategorized,
            },
            splits: splits[row['id']] ?? const <TxnSplit>[],
          ),
    ],
    NameAliases.fromRows(data.aliases),
  );
}

/// `ORDER BY t.date DESC, t.id DESC`.
int _byNewestFirst(Map<String, Object?> a, Map<String, Object?> b) {
  final int byDate = _int(b['date']).compareTo(_int(a['date']));
  return byDate != 0 ? byDate : _int(b['id']).compareTo(_int(a['id']));
}

/// `ORDER BY s.transaction_id, s.position, s.id`.
///
/// The order matters beyond presentation: `transactions.category_id` caches the
/// largest line, and the split editor puts the rounding remainder on the last
/// one, so lines that come back shuffled do not sum the way they were saved.
int _bySplitOrder(Map<String, Object?> a, Map<String, Object?> b) {
  final int byTxn = _int(a['transaction_id']).compareTo(_int(b['transaction_id']));
  if (byTxn != 0) return byTxn;
  final int byPosition = _int(a['position']).compareTo(_int(b['position']));
  return byPosition != 0 ? byPosition : _int(a['id']).compareTo(_int(b['id']));
}

/// A sort key that cannot throw. A row with a missing or odd value sorts as 0
/// rather than taking the whole screen down with it.
int _int(Object? value) => switch (value) {
      final int v => v,
      final num v => v.toInt(),
      final String v => int.tryParse(v) ?? 0,
      _ => 0,
    };
