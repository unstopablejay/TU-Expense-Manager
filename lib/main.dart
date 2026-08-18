import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

// `Border`, `BorderStyle` and `TextSpan` all collide with Material's.
import 'package:excel/excel.dart' hide Border, BorderStyle, TextSpan;
import 'package:file_picker/file_picker.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart' show compute, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
// Maintained fork of `telephony` (identical API). The original 0.2.0 has no
// Gradle namespace and cannot build against AGP 8+.
import 'package:another_telephony/telephony.dart';

import 'src/core/aliases.dart';
import 'src/core/backup_data.dart';
import 'src/core/backup_validate.dart';

export 'src/core/aliases.dart';
export 'src/core/backup_data.dart';
export 'src/core/backup_validate.dart';

import 'src/core/ledger.dart';
import 'src/core/ledger_view.dart';

export 'src/core/ledger.dart';
export 'src/core/ledger_view.dart';

import 'src/core/constants.dart';
import 'src/core/models.dart';
import 'src/core/parser.dart';
import 'src/core/splits.dart';

export 'src/core/constants.dart';
export 'src/core/models.dart';
export 'src/core/parser.dart';
export 'src/core/splits.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TuExpenseTrackerApp());
}

class AppDatabase {
  AppDatabase._();

  static final AppDatabase instance = AppDatabase._();

  /// The schema this build understands. A backup stamps this into its Meta
  /// sheet, and one stamped with a *higher* number is refused rather than
  /// imported — it may hold columns this build has never heard of.
  static const int schemaVersion = kSchemaVersion;

  static const String uncategorized = kUncategorized;
  static const List<String> _defaultCategories = <String>[
    uncategorized, // inserted first so it always lands on id = 1
    'Grocery',
    'Food',
    'Fuel',
    'Shopping',
    'Bills & Utilities',
    'Travel',
    'Entertainment',
    'Health',
  ];

  // Assigned synchronously on first access, so concurrent callers await the
  // same open() future instead of racing to open the file twice.
  Future<Database>? _opening;
  int? _uncategorizedId;

  Future<Database> get database => _opening ??= _open();

  Future<Database> _open() async {
    final path = p.join(await getDatabasesPath(), 'expense_manager.db');
    return openDatabase(
      path,
      version: schemaVersion,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE categories (
        id   INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE COLLATE NOCASE
      )
    ''');

    // COLLATE NOCASE on the merchant key means "Swiggy" and "SWIGGY" resolve
    // to the same mapping without having to uppercase what we display.
    await db.execute('''
      CREATE TABLE merchant_mappings (
        merchant_name TEXT PRIMARY KEY COLLATE NOCASE,
        category_id   INTEGER NOT NULL,
        FOREIGN KEY (category_id) REFERENCES categories (id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE transactions (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        amount       REAL NOT NULL,
        payment_type TEXT,
        merchant     TEXT NOT NULL COLLATE NOCASE,
        date         INTEGER NOT NULL,
        category_id  INTEGER NOT NULL,
        direction    TEXT NOT NULL DEFAULT 'debit',
        reference    TEXT NOT NULL DEFAULT '',
        note         TEXT NOT NULL DEFAULT '',
        FOREIGN KEY (category_id) REFERENCES categories (id)
      )
    ''');

    await db.execute(_createNaturalKeyIndex);
    await db.execute(_createDeletedTransactions);
    await db.execute(_createAppMeta);
    await db.execute(_createTransactionSplits);
    await db.execute(_createTransactionSplitsIndex);
    await db.execute(_createNameAliases);

    final batch = db.batch();
    for (final name in _defaultCategories) {
      batch.insert('categories', <String, Object?>{'name': name});
    }
    await batch.commit(noResult: true);
  }

  /// Same charge, same merchant, same second, same direction, same reference =
  /// the same SMS. Lets an inbox re-scan run repeatedly without piling up
  /// duplicates.
  ///
  /// `direction` is in the key because a debit and a matching refund can land on
  /// the same timestamp. `reference` is in it because UPI alerts carry a date
  /// with no clock time, so two genuine same-day payments of the same amount to
  /// the same payee are otherwise indistinguishable — the UPI Ref separates
  /// them. Templates without a reference store '' and behave as before.
  static const String _createNaturalKeyIndex = '''
      CREATE UNIQUE INDEX idx_transactions_natural_key
        ON transactions (amount, merchant, date, direction, reference)
    ''';

  /// A record that this exact transaction was deleted on purpose. The natural
  /// key index above only stops the *same* SMS being imported twice — the
  /// message itself is still sitting in the inbox, so without a tombstone any
  /// later rescan would faithfully bring a deleted row back.
  ///
  /// The first five columns mirror the natural key exactly, `COLLATE NOCASE` on
  /// `merchant` included, so the two keys compare identically. They alone are
  /// the primary key; the rest is payload carried so the Deleted screen can
  /// rebuild — and restore — a transaction from this row without help.
  static const String _createDeletedTransactions = '''
      CREATE TABLE deleted_transactions (
        amount       REAL NOT NULL,
        merchant     TEXT NOT NULL COLLATE NOCASE,
        date         INTEGER NOT NULL,
        direction    TEXT NOT NULL,
        reference    TEXT NOT NULL DEFAULT '',
        payment_type TEXT,
        category_id  INTEGER,
        original_id  INTEGER,
        deleted_at   INTEGER,
        splits_json  TEXT,
        note         TEXT,
        PRIMARY KEY (amount, merchant, date, direction, reference)
      )
    ''';

  /// One category/amount line of a split. A transaction with no rows here is
  /// unsplit and its `category_id` speaks for the whole amount; one with rows
  /// here owns lines summing to that amount, and its `category_id` is a
  /// denormalised cache of the largest line — never money math.
  ///
  /// `transaction_id` cascades, so deleting a transaction drops its lines. That
  /// is exactly why the tombstone carries `splits_json`: without it, delete and
  /// undo would silently lose a split.
  ///
  /// `category_id` deliberately does *not* cascade — it mirrors
  /// `transactions.category_id`, so deleting a category still in use is refused
  /// rather than quietly vaporising lines and leaving a split that no longer
  /// sums to its transaction, which nothing could repair.
  ///
  /// No UNIQUE on (transaction_id, category_id): two lines in one category on
  /// one transaction is legal and simply adds up. Forbidding it would buy
  /// nothing and cost a repair path.
  static const String _createTransactionSplits = '''
      CREATE TABLE transaction_splits (
        id             INTEGER PRIMARY KEY AUTOINCREMENT,
        transaction_id INTEGER NOT NULL,
        category_id    INTEGER NOT NULL,
        amount         REAL NOT NULL,
        position       INTEGER NOT NULL DEFAULT 0,
        FOREIGN KEY (transaction_id) REFERENCES transactions (id) ON DELETE CASCADE,
        FOREIGN KEY (category_id)    REFERENCES categories (id)
      )
    ''';

  static const String _createTransactionSplitsIndex = '''
      CREATE INDEX idx_transaction_splits_txn
        ON transaction_splits (transaction_id)
    ''';

  /// Key/value scratch space. Currently holds only the inbox scan watermark.
  static const String _createAppMeta = '''
      CREATE TABLE app_meta (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
      )
    ''';

  /// What several labels for one real card, account or merchant are agreed to
  /// be called. `kind` is 'merchant' or 'payment_type'; one table rather than
  /// two because the two behave identically.
  ///
  /// This is a rule rather than a one-off rename, and that is the point: every
  /// SMS template captures the issuer text verbatim, so an alert in the old
  /// format parses to the old label again. Rewriting the rows would fix the
  /// ledger until the next message arrived. Resolving on the way out fixes it
  /// for good, and leaves `transactions` holding what the bank actually said —
  /// which is what makes a merge undoable.
  ///
  /// COLLATE NOCASE on `alias` is load-bearing: it is what lets one row cover
  /// both `HDFC Bank A/C *0444` and `HDFC Bank A/c *0444`.
  static const String _createNameAliases = '''
      CREATE TABLE name_aliases (
        kind      TEXT NOT NULL,
        alias     TEXT NOT NULL COLLATE NOCASE,
        canonical TEXT NOT NULL,
        PRIMARY KEY (kind, alias)
      )
    ''';

  /// v1 predates any notion of spend-vs-receive, so every existing row is a
  /// debit with no reference — which is exactly what the column defaults say.
  /// v2 predates delete and incremental scanning; both new tables start empty,
  /// and an absent watermark is precisely what makes the next scan a full one.
  /// v3 recorded only enough about a deleted row to keep it deleted; the four
  /// v4 columns are what let it be listed and restored later. They must stay
  /// nullable — SQLite cannot `ADD COLUMN ... NOT NULL` without a default — so
  /// a tombstone written by v3 restores into Uncategorized under a fresh id.
  /// v5 adds `transaction_splits`, which needs no backfill — an empty table
  /// already says every existing transaction is unsplit, and that is true.
  /// `splits_json` must be nullable, and NULL is exactly right: a tombstone
  /// written before v5 has no splits to carry.
  /// v6 adds `name_aliases`, which needs no backfill either — an empty table
  /// says nothing has been merged yet, which is true of every database that
  /// predates the feature.
  /// v7 adds `transactions.note`, and the empty string its default supplies is
  /// not a placeholder for missing data — a transaction imported before notes
  /// existed genuinely has no note. The tombstone's copy must be nullable for
  /// the usual reason, and NULL there says the same thing.
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute(
        "ALTER TABLE transactions ADD COLUMN direction TEXT NOT NULL "
        "DEFAULT 'debit'",
      );
      await db.execute(
        "ALTER TABLE transactions ADD COLUMN reference TEXT NOT NULL "
        "DEFAULT ''",
      );
      await db.execute('DROP INDEX IF EXISTS idx_transactions_natural_key');
      await db.execute(_createNaturalKeyIndex);
    }
    if (oldVersion < 3) {
      await db.execute(_createDeletedTransactions);
      await db.execute(_createAppMeta);
    }
    if (oldVersion == 3) {
      // Only a database that was actually created at v3 needs these; one coming
      // from v2 or earlier just got the full v4 table above.
      for (final column in <String>[
        'payment_type TEXT',
        'category_id INTEGER',
        'original_id INTEGER',
        'deleted_at INTEGER',
      ]) {
        await db.execute('ALTER TABLE deleted_transactions ADD COLUMN $column');
      }
    }
    if (oldVersion < 5) {
      await db.execute(_createTransactionSplits);
      await db.execute(_createTransactionSplitsIndex);
      // Same shape of reasoning as the v3 branch above, and it depends on
      // running after it: a database coming from v2 or earlier had
      // `deleted_transactions` created from the const a moment ago, which
      // already carries `splits_json`. Only one created by the v3 or v4 text
      // is missing the column.
      if (oldVersion >= 3) {
        await db.execute(
          'ALTER TABLE deleted_transactions ADD COLUMN splits_json TEXT',
        );
      }
    }
    if (oldVersion < 6) {
      await db.execute(_createNameAliases);
    }
    if (oldVersion < 7) {
      await db.execute(
        "ALTER TABLE transactions ADD COLUMN note TEXT NOT NULL DEFAULT ''",
      );
      // Same shape of reasoning as the v5 branch: a database coming from v2 or
      // earlier had `deleted_transactions` created from the const above, which
      // already carries `note`.
      if (oldVersion >= 3) {
        await db.execute('ALTER TABLE deleted_transactions ADD COLUMN note TEXT');
      }
    }
  }

  Future<int> uncategorizedId() async {
    if (_uncategorizedId != null) return _uncategorizedId!;
    final db = await database;
    final rows = await db.query(
      'categories',
      columns: <String>['id'],
      where: 'name = ?',
      whereArgs: <Object?>[uncategorized],
      limit: 1,
    );
    return _uncategorizedId = rows.first['id'] as int;
  }

  Future<List<ExpenseCategory>> categories() async {
    final db = await database;
    // Uncategorized pinned to the top of the picker, rest alphabetical.
    final rows = await db.query(
      'categories',
      orderBy: "CASE WHEN name = '$uncategorized' THEN 0 ELSE 1 END, name ASC",
    );
    return rows.map(ExpenseCategory.fromMap).toList();
  }

  Future<ExpenseCategory> addCategory(String name) async {
    final db = await database;
    final clean = name.trim();
    final id = await db.insert(
      'categories',
      <String, Object?>{'name': clean},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    if (id != 0) return ExpenseCategory(id: id, name: clean);

    // Name already exists (UNIQUE NOCASE) — reuse the existing row.
    final rows = await db.query(
      'categories',
      where: 'name = ?',
      whereArgs: <Object?>[clean],
      limit: 1,
    );
    return ExpenseCategory.fromMap(rows.first);
  }

  Future<List<ExpenseTxn>> transactions() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT t.id, t.amount, t.payment_type, t.merchant, t.date, t.category_id,
             t.direction, t.reference, t.note, c.name AS category_name
      FROM transactions t
      JOIN categories c ON c.id = t.category_id
      ORDER BY t.date DESC, t.id DESC
    ''');
    // Two queries rather than one per transaction: every split line in one
    // sweep, grouped in memory. The table holds rows only for transactions that
    // were actually split, so it stays a great deal smaller than the ledger.
    final splitRows = await db.rawQuery('''
      SELECT s.transaction_id, s.category_id, s.amount, c.name AS category_name
      FROM transaction_splits s
      JOIN categories c ON c.id = s.category_id
      ORDER BY s.transaction_id, s.position, s.id
    ''');
    final splits = <int, List<TxnSplit>>{};
    for (final row in splitRows) {
      (splits[row['transaction_id'] as int] ??= <TxnSplit>[])
          .add(TxnSplit.fromMap(row));
    }

    // The one place the whole ledger is materialised, and so the one place
    // merged names have to be applied. Everything downstream — the filters, the
    // facets, the summary, the tiles — reads these objects and needs no idea
    // that the columns say something else.
    return canonicaliseLedger(
      rows
          .map((Map<String, Object?> row) => ExpenseTxn.fromMap(
                row,
                splits: splits[row['id'] as int] ?? const <TxnSplit>[],
              ))
          .toList(),
      await aliases(),
    );
  }

  // -------------------------------------------------------------------------
  // 2b. MERGED NAMES
  // -------------------------------------------------------------------------

  Future<NameAliases> aliases() async {
    final db = await database;
    return NameAliases.fromRows(await db.query('name_aliases'));
  }

  /// Replaces every alias row for [kind] in one transaction.
  ///
  /// All of a kind at once rather than row by row, because [mergePlan] may
  /// re-point existing rows as well as add new ones, and a half-applied plan
  /// would leave a name resolving through two hops. It also makes undo exact:
  /// hand back the map read before the change and the state is restored, which
  /// a targeted insert or delete could not promise.
  Future<void> setAliases(NameKind kind, Map<String, String> rows) async {
    final db = await database;
    await db.transaction((Transaction txn) async {
      await txn.delete('name_aliases',
          where: 'kind = ?', whereArgs: <Object?>[kind.column]);
      final batch = txn.batch();
      for (final MapEntry<String, String> row in rows.entries) {
        batch.insert('name_aliases', <String, Object?>{
          'kind': kind.column,
          'alias': row.key,
          'canonical': row.value,
        });
      }
      await batch.commit(noResult: true);
    });
  }

  /// Folds [members] together under [newName].
  Future<void> mergeNames({
    required NameKind kind,
    required Set<String> members,
    required String newName,
  }) async {
    final NameAliases current = await aliases();
    await setAliases(
      kind,
      mergePlan(current.rowsFor(kind), members, newName.trim()),
    );
  }

  /// Undoes a merge: the labels folded into [canonical] go back to standing on
  /// their own. Nothing was overwritten, so this is just dropping the rule.
  Future<void> separateName({
    required NameKind kind,
    required String canonical,
  }) async {
    final db = await database;
    await db.delete(
      'name_aliases',
      where: 'kind = ? AND canonical = ?',
      whereArgs: <Object?>[kind.column, canonical],
    );
  }

  /// The lines for one transaction, in the order they were entered — what the
  /// split editor reopens with.
  Future<List<TxnSplit>> splitsFor(int transactionId) async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT s.category_id, s.amount, c.name AS category_name
      FROM transaction_splits s
      JOIN categories c ON c.id = s.category_id
      WHERE s.transaction_id = ?
      ORDER BY s.position, s.id
    ''', <Object?>[transactionId]);
    return rows.map(TxnSplit.fromMap).toList();
  }

  /// Every merchant the ledger has seen, with what it defaults to and how much
  /// has gone through it.
  ///
  /// Both `transactions.merchant` and `merchant_mappings.merchant_name` are
  /// `COLLATE NOCASE`, so the grouping and the join agree: "AMAZON" and "Amazon"
  /// collapse into one row *and* find the same mapping. `MIN(t.merchant)` is
  /// there because under a case-insensitive group a bare column would be an
  /// arbitrary member of it — this makes the casing on screen deterministic.
  ///
  /// A merchant with a mapping but no surviving transactions does not appear.
  /// That is the right trade until merchants can be configured before they have
  /// been seen, which nothing does today.
  ///
  /// Merged merchants group under the name they were merged into, so this lists
  /// one row per merchant the user believes in rather than one per spelling the
  /// banks sent. The mapping join follows the same expression: a default set
  /// here has to be found again from whichever label the next SMS arrives under.
  Future<List<MerchantSummary>> merchants() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT MIN(COALESCE(a.canonical, t.merchant)) AS merchant,
             COUNT(*)        AS txn_count,
             SUM(CASE WHEN t.direction = 'debit' THEN t.amount ELSE 0 END)
                             AS total_spent,
             MAX(t.date)     AS last_seen,
             m.category_id   AS default_category_id,
             c.name          AS default_category_name
      FROM transactions t
      LEFT JOIN name_aliases a
             ON a.kind = 'merchant' AND a.alias = t.merchant
      LEFT JOIN merchant_mappings m
             ON m.merchant_name = COALESCE(a.canonical, t.merchant)
      LEFT JOIN categories        c ON c.id = m.category_id
      GROUP BY COALESCE(a.canonical, t.merchant) COLLATE NOCASE
      ORDER BY txn_count DESC, merchant ASC
    ''');
    return rows.map(MerchantSummary.fromMap).toList();
  }

  // -------------------------------------------------------------------------
  // 2c. DELETING A CATEGORY
  // -------------------------------------------------------------------------

  /// Every category with what is filed under it, in the same order as
  /// [categories].
  ///
  /// The transaction counts are split in two because a split transaction is not
  /// "in" a category the way an unsplit one is: it has a line there. Counting it
  /// through `transactions.category_id` would both miss the splits whose minor
  /// line is here and count the ones whose dominant line is, which is neither of
  /// the two numbers anybody wants.
  Future<List<CategoryUsage>> categoryUsage() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT c.id, c.name,
             (SELECT COUNT(*)
                FROM transactions t
               WHERE t.category_id = c.id
                 AND NOT EXISTS (SELECT 1
                                   FROM transaction_splits s
                                  WHERE s.transaction_id = t.id))
               AS unsplit_count,
             (SELECT COUNT(DISTINCT s.transaction_id)
                FROM transaction_splits s
               WHERE s.category_id = c.id)
               AS split_count,
             (SELECT COUNT(*)
                FROM merchant_mappings m
               WHERE m.category_id = c.id)
               AS merchant_default_count
      FROM categories c
      ORDER BY CASE WHEN c.name = '$uncategorized' THEN 0 ELSE 1 END, c.name ASC
    ''');
    return rows.map(CategoryUsage.fromMap).toList();
  }

  /// Removes [category] and moves everything filed under it into [moveToId].
  ///
  /// All of it in one SQL transaction. The foreign keys on `transactions` and
  /// `transaction_splits` deliberately do not cascade, so a half-applied delete
  /// either throws with the category still standing or finishes — it can never
  /// leave a split line pointing at a category that is gone.
  ///
  /// `merchant_mappings` is repointed by hand rather than left to its `ON DELETE
  /// CASCADE`: a merchant that defaulted to Food belongs under whatever Food
  /// became, and letting the row cascade away would quietly demote it from
  /// "always files here" to "never configured".
  ///
  /// `deleted_transactions` has no foreign key to follow, which is exactly why it
  /// has to be repointed too. A tombstone left naming a category that no longer
  /// exists restores into a `transactions` insert the FK then rejects, so the bin
  /// would throw instead of restoring — and its `splits_json` snapshot has to be
  /// rewritten for the same reason [restoreTransactions] checks it, or the
  /// breakdown is dropped on the way back.
  ///
  /// Returns what moved, which is what [restoreCategory] needs to undo it.
  Future<CategoryDeletion> deleteCategory({
    required ExpenseCategory category,
    required int moveToId,
  }) async {
    if (category.id == await uncategorizedId()) {
      // Everything falls back to it — ingest, a pre-v4 restore, a merchant set
      // to always ask. There would be nowhere for any of that to land.
      throw ArgumentError('$uncategorized cannot be deleted');
    }
    if (category.id == moveToId) {
      throw ArgumentError('A category cannot be moved into itself');
    }

    final db = await database;
    return db.transaction<CategoryDeletion>((Transaction txn) async {
      final List<Map<String, Object?>> target = await txn.query(
        'categories',
        columns: <String>['name'],
        where: 'id = ?',
        whereArgs: <Object?>[moveToId],
        limit: 1,
      );
      if (target.isEmpty) throw ArgumentError('No category with id $moveToId');
      final String moveToName = target.first['name'] as String;

      final List<int> transactionIds = (await txn.query(
        'transactions',
        columns: <String>['id'],
        where: 'category_id = ?',
        whereArgs: <Object?>[category.id],
      )).map((Map<String, Object?> r) => r['id'] as int).toList();

      final List<int> splitIds = (await txn.query(
        'transaction_splits',
        columns: <String>['id'],
        where: 'category_id = ?',
        whereArgs: <Object?>[category.id],
      )).map((Map<String, Object?> r) => r['id'] as int).toList();

      final List<String> merchantNames = (await txn.query(
        'merchant_mappings',
        columns: <String>['merchant_name'],
        where: 'category_id = ?',
        whereArgs: <Object?>[category.id],
      )).map((Map<String, Object?> r) => r['merchant_name'] as String).toList();

      // Every candidate tombstone read, then filtered by decoding rather than by
      // a LIKE over the JSON: `"category_id":1` is a prefix of
      // `"category_id":12`, and the shape of the encoding is not something this
      // should have to know.
      final List<Map<String, Object?>> tombstones = <Map<String, Object?>>[];
      for (final Map<String, Object?> row in await txn.query(
        'deleted_transactions',
        columns: _tombstoneCategoryColumns,
        where: 'category_id = ? OR splits_json IS NOT NULL',
        whereArgs: <Object?>[category.id],
      )) {
        final List<TxnSplit> lines = decodeSplits(row['splits_json'] as String?);
        final bool inLines =
            lines.any((TxnSplit l) => l.categoryId == category.id);
        final bool inColumn = row['category_id'] == category.id;
        if (!inLines && !inColumn) continue;

        tombstones.add(row);
        await txn.update(
          'deleted_transactions',
          <String, Object?>{
            if (inColumn) 'category_id': moveToId,
            // Only when a line actually named the category: writing the
            // re-encoded lines unconditionally would turn an unreadable
            // `splits_json` into NULL for rows this has no business changing.
            if (inLines)
              'splits_json': encodeSplits(<TxnSplit>[
                for (final TxnSplit line in lines)
                  if (line.categoryId == category.id)
                    TxnSplit(
                      categoryId: moveToId,
                      categoryName: moveToName,
                      amount: line.amount,
                    )
                  else
                    line,
              ]),
          },
          where: _naturalKeyWhere,
          whereArgs: _naturalKeyArgsOf(row),
        );
      }

      for (final String table in <String>[
        'transactions',
        'transaction_splits',
        'merchant_mappings',
      ]) {
        await txn.update(
          table,
          <String, Object?>{'category_id': moveToId},
          where: 'category_id = ?',
          whereArgs: <Object?>[category.id],
        );
      }

      await txn.delete(
        'categories',
        where: 'id = ?',
        whereArgs: <Object?>[category.id],
      );

      return CategoryDeletion(
        categoryId: category.id,
        categoryName: category.name,
        transactionIds: transactionIds,
        splitIds: splitIds,
        merchantNames: merchantNames,
        tombstones: tombstones,
      );
    });
  }

  /// Puts back what [deleteCategory] moved.
  ///
  /// The category returns under its original id wherever that id is still free —
  /// `AUTOINCREMENT` never hands one out twice, so it is — which is what lets the
  /// tombstones be restored verbatim. Should the same name have been created
  /// afresh in the meantime, that row wins and the moved rows go back into it
  /// instead: same name, same transactions, a different id.
  Future<void> restoreCategory(CategoryDeletion deletion) async {
    final db = await database;
    await db.transaction((Transaction txn) async {
      int id = await txn.insert(
        'categories',
        <String, Object?>{'id': deletion.categoryId, 'name': deletion.categoryName},
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      if (id == 0) {
        final List<Map<String, Object?>> existing = await txn.query(
          'categories',
          columns: <String>['id'],
          where: 'name = ?',
          whereArgs: <Object?>[deletion.categoryName],
          limit: 1,
        );
        // Nothing to move back into and no way to make one. Leaving the rows
        // where the delete put them is the only safe answer.
        if (existing.isEmpty) return;
        id = existing.first['id'] as int;
      }

      await _repoint(txn, 'transactions', 'id', deletion.transactionIds, id);
      await _repoint(txn, 'transaction_splits', 'id', deletion.splitIds, id);
      await _repoint(
          txn, 'merchant_mappings', 'merchant_name', deletion.merchantNames, id);

      // Only exact when the original id came back; against a different one the
      // stored text would point at an id that does not exist and reintroduce the
      // failing restore this all exists to prevent. The tombstones then stay
      // where the delete left them, which is at least a category that exists.
      if (id != deletion.categoryId) return;
      for (final Map<String, Object?> row in deletion.tombstones) {
        await txn.update(
          'deleted_transactions',
          <String, Object?>{
            'category_id': row['category_id'],
            'splits_json': row['splits_json'],
          },
          where: _naturalKeyWhere,
          whereArgs: _naturalKeyArgsOf(row),
        );
      }
    });
  }

  /// Sets `category_id` on the [table] rows [keyColumn] names, in chunks small
  /// enough for SQLite's bound-variable limit — an undo can name every
  /// transaction in the ledger.
  static Future<void> _repoint(
    Transaction txn,
    String table,
    String keyColumn,
    List<Object?> keys,
    int categoryId,
  ) async {
    const int chunk = 400;
    for (var i = 0; i < keys.length; i += chunk) {
      final int end = i + chunk < keys.length ? i + chunk : keys.length;
      final List<Object?> slice = keys.sublist(i, end);
      await txn.update(
        table,
        <String, Object?>{'category_id': categoryId},
        where:
            '$keyColumn IN (${List<String>.filled(slice.length, '?').join(', ')})',
        whereArgs: slice,
      );
    }
  }

  /// What [deleteCategory] reads off a tombstone: its key, and the two columns
  /// that can name a category.
  static const List<String> _tombstoneCategoryColumns = <String>[
    'amount',
    'merchant',
    'date',
    'direction',
    'reference',
    'category_id',
    'splits_json',
  ];

  /// `whereArgs` for [_naturalKeyWhere] from a raw `deleted_transactions` row.
  static List<Object?> _naturalKeyArgsOf(Map<String, Object?> row) => <Object?>[
        row['amount'],
        row['merchant'],
        row['date'],
        row['direction'],
        row['reference'],
      ];

  // -------------------------------------------------------------------------
  // 3. AUTO-CATEGORIZE
  // -------------------------------------------------------------------------

  /// Looks the merchant up in `merchant_mappings`; falls back to
  /// 'Uncategorized' when this merchant has never been classified.
  /// Returns the new row id, or 0 when the SMS was a duplicate or names a
  /// transaction the user has deleted.
  ///
  /// Credits go through the same mapping lookup on purpose — a refund from
  /// AMAZON landing back in Shopping is the useful behaviour.
  Future<int> insertParsed(ParsedSms sms) async {
    final db = await database;

    final tombstone = await db.query(
      'deleted_transactions',
      columns: <String>['merchant'],
      where: _naturalKeyWhere,
      whereArgs: <Object?>[
        sms.amount,
        sms.merchant,
        sms.date.millisecondsSinceEpoch,
        sms.direction.name,
        sms.reference,
      ],
      limit: 1,
    );
    if (tombstone.isNotEmpty) return 0;

    final mapping = await db.query(
      'merchant_mappings',
      columns: <String>['category_id'],
      where: 'merchant_name = ?',
      whereArgs: <Object?>[sms.merchant],
      limit: 1,
    );

    // Nothing here needs to know about splits or about "always ask me". A
    // merchant set to always ask has a mapping to Uncategorized, which this
    // already reads and applies; a merchant never configured has no mapping and
    // falls through to the same place. Both land uncategorized, which is
    // exactly right, and a freshly imported alert is never split. Left alone
    // deliberately.
    final categoryId = mapping.isNotEmpty
        ? mapping.first['category_id'] as int
        : await uncategorizedId();

    return db.insert(
      'transactions',
      <String, Object?>{
        'amount': sms.amount,
        'payment_type': sms.paymentType,
        'merchant': sms.merchant,
        'date': sms.date.millisecondsSinceEpoch,
        'category_id': categoryId,
        'direction': sms.direction.name,
        'reference': sms.reference,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  // -------------------------------------------------------------------------
  // 5. LEARN THE MAPPING + BACKFILL
  // -------------------------------------------------------------------------

  /// A transaction that setting a merchant default may re-tag: same merchant,
  /// not already in the target category, and not split.
  ///
  /// Shared verbatim by [backfillableCount] and [setMerchantDefault] so the
  /// number the user is asked to confirm is exactly the set that changes.
  /// Excluding rows already in the target keeps that number honest — "also
  /// apply to N past transactions" should mean N of them actually move.
  ///
  /// Excluding split rows is the important one: a split is a statement about
  /// where that money really went, made by hand, and a merchant-wide default is
  /// a much weaker claim than that. It must never overwrite one.
  /// The `merchant = ?` is expanded to `merchant IN (?, ?, …)` by
  /// [_merchantMatch] when the name has been merged, so a default set on the
  /// merged name reaches the rows filed under every label it covers.
  static String _backfillableWhere(int merchants) =>
      '${_merchantMatch(merchants)} AND category_id <> ? '
      'AND id NOT IN (SELECT transaction_id FROM transaction_splits)';

  /// `merchant = ?` for one label, `merchant IN (?, …)` for a merged set.
  static String _merchantMatch(int count) => count == 1
      ? 'merchant = ?'
      : 'merchant IN (${List<String>.filled(count, '?').join(', ')})';

  /// Re-tags this transaction and nothing else, and drops any split on it —
  /// one category and a set of lines are mutually exclusive statements about
  /// the same money.
  Future<void> setTransactionCategory({
    required int transactionId,
    required int categoryId,
  }) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(
        'transaction_splits',
        where: 'transaction_id = ?',
        whereArgs: <Object?>[transactionId],
      );
      await txn.update(
        'transactions',
        <String, Object?>{'category_id': categoryId},
        where: 'id = ?',
        whereArgs: <Object?>[transactionId],
      );
    });
  }

  /// Writes what the user typed against one transaction. One statement, so no
  /// `db.transaction` around it — unlike [setTransactionCategory], the note
  /// says nothing about any other column and cannot leave the row half-changed.
  ///
  /// An empty [note] is how a note is removed. There is no delete: the column
  /// is NOT NULL and '' already means "nothing written here", so a second way
  /// of saying it would only be a second thing to get wrong.
  Future<void> setTransactionNote({
    required int transactionId,
    required String note,
  }) async {
    final db = await database;
    await db.update(
      'transactions',
      <String, Object?>{'note': note},
      where: 'id = ?',
      whereArgs: <Object?>[transactionId],
    );
  }

  /// How many past transactions [setMerchantDefault] would re-tag, using the
  /// identical predicate so the count shown is the count changed.
  Future<int> backfillableCount({
    required String merchant,
    required int categoryId,
  }) async {
    final db = await database;
    final List<String> labels =
        (await aliases()).membersOf(NameKind.merchant, merchant).toList();
    final rows = await db.rawQuery(
      'SELECT COUNT(*) AS n FROM transactions '
      'WHERE ${_backfillableWhere(labels.length)}',
      <Object?>[...labels, categoryId],
    );
    return Sqflite.firstIntValue(rows) ?? 0;
  }

  /// Remembers `merchant -> categoryId` for everything imported from now on,
  /// and re-tags history only when [backfill] says so. Returns the number of
  /// rows re-tagged.
  ///
  /// A mapping to Uncategorized is how "always ask me" is stored, for a
  /// merchant like Amazon whose charges always need splitting by hand. It is
  /// never backfilled even if asked: applying it to history would erase
  /// per-transaction work rather than save any.
  ///
  /// When [merchant] is a merged name the mapping is written for **every** label
  /// it covers, not just the merged one. Ingest looks the default up under the
  /// raw merchant the SMS parsed to (it has to — the alias is resolved on the
  /// way out, not the way in), so a row keyed only on the merged name would
  /// never be found and the default would silently apply to nothing.
  Future<int> setMerchantDefault({
    required String merchant,
    required int categoryId,
    bool backfill = false,
  }) async {
    final db = await database;
    final int uncategorized = await uncategorizedId();
    final List<String> labels =
        (await aliases()).membersOf(NameKind.merchant, merchant).toList();
    return db.transaction<int>((txn) async {
      final batch = txn.batch();
      for (final String label in labels) {
        batch.insert(
          'merchant_mappings',
          <String, Object?>{
            'merchant_name': label,
            'category_id': categoryId,
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);

      if (!backfill || categoryId == uncategorized) return 0;
      return txn.update(
        'transactions',
        <String, Object?>{'category_id': categoryId},
        where: _backfillableWhere(labels.length),
        whereArgs: <Object?>[...labels, categoryId],
      );
    });
  }

  /// Replaces this transaction's split lines outright — the editor always hands
  /// over the complete set, which makes "replace" and "clear" the same code.
  ///
  /// Throws unless the lines sum to the transaction's amount: a split that does
  /// not add up is a corrupt ledger, and there is no repair path once written.
  /// `transactions.category_id` is refreshed to the largest line so the join in
  /// [transactions], the headline chip and a tombstone restore all still have a
  /// sensible single category to fall back on. It is never money math.
  Future<void> saveSplits(ExpenseTxn transaction, List<TxnSplit> lines) async {
    if (lines.isEmpty) return clearSplits(transaction.id);

    final double sum =
        lines.fold<double>(0, (double s, TxnSplit l) => s + l.amount);
    if ((sum - transaction.amount).abs() > kSplitTolerance) {
      throw ArgumentError(
        'Split lines total $sum, which is not ${transaction.amount}',
      );
    }

    final TxnSplit dominant = lines.reduce(
      (TxnSplit a, TxnSplit b) => b.amount > a.amount ? b : a,
    );

    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(
        'transaction_splits',
        where: 'transaction_id = ?',
        whereArgs: <Object?>[transaction.id],
      );
      for (var i = 0; i < lines.length; i++) {
        await txn.insert('transaction_splits', <String, Object?>{
          'transaction_id': transaction.id,
          'category_id': lines[i].categoryId,
          'amount': lines[i].amount,
          'position': i,
        });
      }
      await txn.update(
        'transactions',
        <String, Object?>{'category_id': dominant.categoryId},
        where: 'id = ?',
        whereArgs: <Object?>[transaction.id],
      );
    });
  }

  /// Drops the lines. `transactions.category_id` keeps whatever the dominant
  /// line left there, which is the sane landing spot for a transaction that has
  /// stopped being split.
  Future<void> clearSplits(int transactionId) async {
    final db = await database;
    await db.delete(
      'transaction_splits',
      where: 'transaction_id = ?',
      whereArgs: <Object?>[transactionId],
    );
  }

  // -------------------------------------------------------------------------
  // 6. DELETE (permanently — see [_createDeletedTransactions])
  // -------------------------------------------------------------------------

  static const String _naturalKeyWhere =
      'amount = ? AND merchant = ? AND date = ? AND direction = ? '
      'AND reference = ?';

  /// The five columns of [_naturalKeyWhere], in that order — `whereArgs` for
  /// the clause above is `_naturalKeyOf(txn).values.toList()`, which holds
  /// because Dart maps iterate in insertion order.
  ///
  /// [ExpenseTxn.rawMerchant], not `merchant`: this key has to match the row as
  /// stored. Under a merge the two differ, and the displayed name would find
  /// nothing — leaving a tombstone that keeps out an SMS nobody deleted while
  /// the row it was meant to remove stayed put.
  static Map<String, Object?> _naturalKeyOf(ExpenseTxn txn) => <String, Object?>{
        'amount': txn.amount,
        'merchant': txn.rawMerchant,
        'date': txn.date.millisecondsSinceEpoch,
        'direction': txn.direction.name,
        'reference': txn.reference,
      };

  /// The full tombstone row: the natural key plus everything needed to put the
  /// transaction back exactly as it was.
  static Map<String, Object?> _tombstoneOf(ExpenseTxn txn, DateTime at) =>
      <String, Object?>{
        ..._naturalKeyOf(txn),
        // Raw again: restore replays this straight back into the row, and the
        // merge will rename it on the way out as it did the first time.
        'payment_type': txn.rawPaymentType,
        'category_id': txn.categoryId,
        'original_id': txn.id,
        'deleted_at': at.millisecondsSinceEpoch,
        // The split lines cascade away with the row itself, so unless they are
        // carried here a delete-and-undo would quietly return the transaction
        // under a single category and lose the breakdown entirely.
        'splits_json': encodeSplits(txn.splits),
        // For the same reason as the lines above it: the note lives on the row
        // and goes with it, so a delete-and-undo would hand back the charge
        // with the one part of it nobody could reconstruct missing.
        'note': txn.note,
      };

  /// Removes the rows and records that they were removed, all in one SQL
  /// transaction so a row can never be deleted without leaving the tombstone
  /// that keeps it deleted — and so a bulk delete is all or nothing.
  Future<void> deleteTransactions(List<ExpenseTxn> transactions) async {
    if (transactions.isEmpty) return;
    final db = await database;
    final at = DateTime.now();
    await db.transaction((txn) async {
      for (final transaction in transactions) {
        await txn.insert(
          'deleted_transactions',
          _tombstoneOf(transaction, at),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
        await txn.delete(
          'transactions',
          where: 'id = ?',
          whereArgs: <Object?>[transaction.id],
        );
      }
    });
  }

  Future<void> deleteTransaction(ExpenseTxn transaction) =>
      deleteTransactions(<ExpenseTxn>[transaction]);

  /// Every deleted transaction, newest first. The join is a LEFT one because a
  /// tombstone written before v4 carries no `category_id` at all.
  Future<List<DeletedTxn>> deletedTransactions() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT d.amount, d.merchant, d.date, d.direction, d.reference,
             d.payment_type, d.category_id, d.original_id, d.deleted_at,
             d.splits_json, d.note,
             c.name AS category_name
      FROM deleted_transactions d
      LEFT JOIN categories c ON c.id = d.category_id
      ORDER BY d.deleted_at DESC, d.date DESC
    ''');
    return rows.map(DeletedTxn.fromMap).toList();
  }

  /// Lifts the tombstones and puts the rows back — under their original ids
  /// where the tombstone recorded one, so a restored transaction is the same
  /// one and not a copy. `AUTOINCREMENT` never reuses ids, so reinstating one
  /// cannot collide with a row created since.
  Future<void> restoreTransactions(List<DeletedTxn> deleted) async {
    if (deleted.isEmpty) return;
    final db = await database;
    // A pre-v4 tombstone has no category; it comes back as Uncategorized.
    final fallbackCategory = await uncategorizedId();
    await db.transaction((txn) async {
      for (final row in deleted) {
        await txn.delete(
          'deleted_transactions',
          where: _naturalKeyWhere,
          whereArgs: <Object?>[
            row.amount,
            row.merchant,
            row.date.millisecondsSinceEpoch,
            row.direction.name,
            row.reference,
          ],
        );
        final int restoredId = await txn.insert(
          'transactions',
          <String, Object?>{
            if (row.originalId != null) 'id': row.originalId,
            'amount': row.amount,
            'merchant': row.merchant,
            'date': row.date.millisecondsSinceEpoch,
            'direction': row.direction.name,
            'reference': row.reference,
            'payment_type': row.paymentType,
            'category_id': row.categoryId ?? fallbackCategory,
            'note': row.note,
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );

        // `ignore` returns 0 when a row on this natural key already exists, so
        // the insert above did nothing and there is no transaction to hang
        // lines off. Writing them anyway — worse, against `original_id` — would
        // attach a stranger's split to whatever is living at that id.
        if (restoredId == 0 || row.splits.isEmpty) continue;

        // A category deleted while the transaction was in the bin would leave a
        // split that no longer sums. Coming back whole under one category is
        // recoverable; coming back broken is not.
        final Set<int> known = (await txn.query('categories',
                columns: <String>['id']))
            .map((Map<String, Object?> c) => c['id'] as int)
            .toSet();
        if (!row.splits.every((TxnSplit s) => known.contains(s.categoryId))) {
          continue;
        }

        for (var i = 0; i < row.splits.length; i++) {
          await txn.insert('transaction_splits', <String, Object?>{
            'transaction_id': restoredId,
            'category_id': row.splits[i].categoryId,
            'amount': row.splits[i].amount,
            'position': i,
          });
        }
      }
    });
  }

  Future<void> restoreTransaction(DeletedTxn deleted) =>
      restoreTransactions(<DeletedTxn>[deleted]);

  // -------------------------------------------------------------------------
  // 7. INBOX SCAN WATERMARK
  // -------------------------------------------------------------------------

  static const String _lastScannedKey = 'last_scanned_sms_date';

  /// The `date` of the newest inbox message already processed, or null when the
  /// inbox has never been scanned — which is what makes the first scan a full
  /// one.
  Future<DateTime?> lastScannedSmsDate() async {
    final db = await database;
    final rows = await db.query(
      'app_meta',
      columns: <String>['value'],
      where: 'key = ?',
      whereArgs: <Object?>[_lastScannedKey],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    final millis = int.tryParse(rows.first['value'] as String);
    return millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);
  }

  Future<void> setLastScannedSmsDate(DateTime value) async {
    final db = await database;
    await db.insert(
      'app_meta',
      <String, Object?>{
        'key': _lastScannedKey,
        'value': value.millisecondsSinceEpoch.toString(),
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // -------------------------------------------------------------------------
  // 2f. BACKUP
  // -------------------------------------------------------------------------

  /// Every table, verbatim.
  ///
  /// Pointedly *not* built on [transactions]: that one resolves merged names on
  /// the way out, and the merchant it would hand back is not the string the
  /// column holds. Since the merchant is part of the natural key that finds a
  /// row again, exporting the merged spelling would produce a backup whose
  /// tombstones no longer match their transactions — a fault that shows up only
  /// on the rescan after a restore, as deleted rows quietly coming back.
  Future<BackupData> exportAll() async {
    final db = await database;
    final PackageInfo info = await PackageInfo.fromPlatform();

    final List<Map<String, Object?>> categories =
        await db.query('categories', orderBy: 'id');
    final List<Map<String, Object?>> merchantMappings =
        await db.query('merchant_mappings', orderBy: 'merchant_name');
    final List<Map<String, Object?>> transactions =
        await db.query('transactions', orderBy: 'date DESC, id DESC');
    final List<Map<String, Object?>> splits = await db.query(
      'transaction_splits',
      orderBy: 'transaction_id, position, id',
    );
    final List<Map<String, Object?>> deleted =
        await db.query('deleted_transactions', orderBy: 'deleted_at DESC');
    final List<Map<String, Object?>> aliases =
        await db.query('name_aliases', orderBy: 'kind, alias');
    final List<Map<String, Object?>> appMeta =
        await db.query('app_meta', orderBy: 'key');

    return BackupData(
      categories: categories,
      merchantMappings: merchantMappings,
      transactions: transactions,
      splits: splits,
      deleted: deleted,
      aliases: aliases,
      appMeta: appMeta,
      meta: buildBackupMeta(
        appVersion: info.version,
        appBuild: info.buildNumber,
        exportedAt: DateTime.now(),
        transactions: transactions.length,
        splits: splits.length,
        categories: categories.length,
        merchantDefaults: merchantMappings.length,
        nameAliases: aliases.length,
        deleted: deleted.length,
      ),
    );
  }

  /// Throws away everything and writes [data] in its place.
  ///
  /// One `db.transaction`, so a failure anywhere leaves the database exactly as
  /// it was rather than half replaced. Validate with [validateBackup] first:
  /// the foreign keys would catch most corruption too, but only part-way
  /// through, and a rolled-back transaction cannot say which row was at fault.
  ///
  /// Order matters in both halves, because `PRAGMA foreign_keys` is on and
  /// cannot be turned off inside a transaction — deletes run children-first and
  /// inserts parents-first.
  ///
  /// Ids are written explicitly. `deleted_transactions.original_id` points at
  /// `transactions.id`, and a tombstone restores its row under that id, so
  /// renumbering on the way in would break undo for every deleted transaction
  /// in the backup.
  Future<void> replaceAll(BackupData data) async {
    final db = await database;
    await db.transaction((Transaction txn) async {
      for (final String table in const <String>[
        'transaction_splits',
        'transactions',
        'merchant_mappings',
        'deleted_transactions',
        'name_aliases',
        'app_meta',
        'categories',
      ]) {
        await txn.delete(table);
      }

      // AUTOINCREMENT counters only ever climb, so without this a restored
      // database would keep issuing ids from wherever the old one had got to.
      // Clearing them makes the result identical to the database that was
      // exported, rather than merely equivalent.
      await txn.delete(
        'sqlite_sequence',
        where: 'name IN (?, ?, ?)',
        whereArgs: const <Object?>[
          'categories',
          'transactions',
          'transaction_splits',
        ],
      );

      final Batch batch = txn.batch();
      for (final Map<String, Object?> row in data.categories) {
        batch.insert('categories', row);
      }
      for (final Map<String, Object?> row in data.merchantMappings) {
        batch.insert('merchant_mappings', row);
      }
      for (final Map<String, Object?> row in data.transactions) {
        batch.insert('transactions', row);
      }
      for (final Map<String, Object?> row in data.splits) {
        batch.insert('transaction_splits', row);
      }
      for (final Map<String, Object?> row in data.deleted) {
        batch.insert('deleted_transactions', row);
      }
      for (final Map<String, Object?> row in data.aliases) {
        batch.insert('name_aliases', row);
      }
      for (final Map<String, Object?> row in data.appMeta) {
        batch.insert('app_meta', row);
      }
      await batch.commit(noResult: true);
    });

    // The id was cached from the categories table that has just been thrown
    // away. Left stale, every later categorisation would point at whatever row
    // now happens to hold that id.
    _uncategorizedId = null;
  }
}

// ---------------------------------------------------------------------------
// SMS SOURCE (Android only; degrades quietly everywhere else)
// ---------------------------------------------------------------------------

/// An SMS body together with when it landed on the device. The arrival time is
/// what gives UPI alerts — which carry a date but no clock time — a sensible
/// position in the ledger.
class InboxSms {
  const InboxSms(this.body, this.receivedAt);

  final String body;
  final DateTime? receivedAt;
}

class SmsSource {
  final Telephony _telephony = Telephony.instance;

  bool get isSupported => defaultTargetPlatform == TargetPlatform.android;

  Future<bool> requestPermission() async {
    if (!isSupported) return false;
    final status = await Permission.sms.request();
    return status.isGranted;
  }

  /// Live listener for new alerts while the app is in the foreground.
  void listen(void Function(InboxSms sms) onMessage) {
    if (!isSupported) return;
    try {
      _telephony.listenIncomingSms(
        onNewMessage: (SmsMessage message) {
          final body = message.body;
          if (body != null) onMessage(InboxSms(body, _timestampOf(message)));
        },
        listenInBackground: false,
      );
    } catch (_) {
      // Plugin unavailable (e.g. running on a desktop target) — ignore.
    }
  }

  /// Reads the inbox. With [since] the query is narrowed to messages newer than
  /// that instant, which is what turns every scan after the first into a cheap
  /// look at only what has arrived. The filter is a real `WHERE` on the SMS
  /// content provider, not a fetch-everything-then-discard.
  Future<List<InboxSms>> readInbox({DateTime? since}) async {
    if (!isSupported) return const <InboxSms>[];
    try {
      final messages = await _telephony.getInboxSms(
        columns: <SmsColumn>[SmsColumn.ADDRESS, SmsColumn.BODY, SmsColumn.DATE],
        filter: since == null
            ? null
            : SmsFilter.where(SmsColumn.DATE)
                .greaterThan(since.millisecondsSinceEpoch.toString()),
      );
      return messages
          .map((SmsMessage m) {
            final body = m.body;
            return body == null ? null : InboxSms(body, _timestampOf(m));
          })
          .whereType<InboxSms>()
          .toList();
    } catch (_) {
      return const <InboxSms>[];
    }
  }

  /// `SmsMessage.date` is epoch milliseconds, or null when the provider did not
  /// supply it.
  static DateTime? _timestampOf(SmsMessage message) {
    final date = message.date;
    return date == null ? null : DateTime.fromMillisecondsSinceEpoch(date);
  }
}

// ---------------------------------------------------------------------------
// 4. UPDATES
// ---------------------------------------------------------------------------

/// The repository releases are published to. `release.yml` tags a commit,
/// builds the APK and attaches it to a GitHub Release, so `releases/latest` is
/// the only thing the app ever has to ask about.
const String kUpdateRepo = 'unstopablejay/TU-Expense-Manager';

/// How long an automatic check waits before looking again.
const Duration kUpdateCheckInterval = Duration(days: 7);

/// A dotted version, compared number by number rather than as text — 1.10.0 is
/// newer than 1.9.0, which a string comparison gets backwards.
///
/// Parsing is forgiving because the two ends disagree on shape: the git tag
/// reads `v1.2.0`, package_info_plus reports `1.2.0`, and pubspec.yaml writes
/// `1.2.0+2`. All three have to land on the same three numbers.
class AppVersion implements Comparable<AppVersion> {
  const AppVersion(this.major, [this.minor = 0, this.patch = 0]);

  final int major;
  final int minor;
  final int patch;

  static final RegExp _pattern = RegExp(r'(\d+)(?:\.(\d+))?(?:\.(\d+))?');

  /// Returns null when [text] holds no digits at all, which is the only case
  /// where there is nothing sensible to compare against.
  static AppVersion? parse(String text) {
    final match = _pattern.firstMatch(text);
    if (match == null) return null;
    int at(int group) => int.tryParse(match.group(group) ?? '') ?? 0;
    return AppVersion(at(1), at(2), at(3));
  }

  @override
  int compareTo(AppVersion other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    return patch.compareTo(other.patch);
  }

  @override
  bool operator ==(Object other) =>
      other is AppVersion && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch);

  @override
  String toString() => '$major.$minor.$patch';
}

/// Whether [latest] is worth offering. Anything unparseable on either side
/// means staying quiet: a version the app cannot read is not grounds for
/// telling someone to reinstall.
bool isUpdateAvailable({
  required AppVersion? current,
  required AppVersion? latest,
}) {
  if (current == null || latest == null) return false;
  return latest.compareTo(current) > 0;
}

/// Whether an automatic check is due. Pure, so the weekly rule can be tested
/// without waiting a week.
bool isCheckDue({
  required DateTime? lastChecked,
  required DateTime now,
  Duration interval = kUpdateCheckInterval,
}) {
  if (lastChecked == null) return true; // Never checked — check on this launch.
  // A stamp in the future means the clock moved backwards (a timezone change,
  // or the date set by hand). Treating it as due beats parking the next check
  // weeks out.
  if (lastChecked.isAfter(now)) return true;
  return now.difference(lastChecked) >= interval;
}

/// A published release with an installable APK attached.
class AppRelease {
  const AppRelease({
    required this.version,
    required this.tag,
    required this.apkUrl,
    required this.notes,
  });

  final AppVersion version;
  final String tag;
  final String apkUrl;
  final String notes;

  /// Reads GitHub's `releases/latest` payload.
  ///
  /// Returns null when the release carries no APK. A tag whose build failed
  /// still leaves a Release object behind, and announcing an update that
  /// cannot be downloaded is worse than announcing nothing.
  static AppRelease? fromJson(Map<String, dynamic> json) {
    final tag = (json['tag_name'] as String? ?? '').trim();
    final version = AppVersion.parse(tag);
    if (version == null) return null;

    String? apkUrl;
    final assets = json['assets'];
    if (assets is List) {
      for (final Object? asset in assets) {
        if (asset is! Map) continue;
        final name = asset['name'] as String? ?? '';
        final url = asset['browser_download_url'] as String?;
        if (url != null && name.toLowerCase().endsWith('.apk')) {
          apkUrl = url;
          break;
        }
      }
    }
    if (apkUrl == null) return null;

    return AppRelease(
      version: version,
      tag: tag,
      apkUrl: apkUrl,
      notes: (json['body'] as String? ?? '').trim(),
    );
  }
}

/// What one check found. A check has exactly three outcomes, so they are three
/// constructors rather than a bag of nullable fields to interpret at each call
/// site.
class UpdateCheck {
  const UpdateCheck.upToDate(this.currentVersion)
      : release = null,
        error = null;
  const UpdateCheck.available(this.currentVersion, AppRelease this.release)
      : error = null;
  const UpdateCheck.failed(this.currentVersion, String this.error)
      : release = null;

  final String currentVersion;
  final AppRelease? release;
  final String? error;

  bool get hasUpdate => release != null;
  bool get failed => error != null;
}

/// The stored half of the feature: whether automatic checking is on, and when
/// the last one succeeded.
class UpdatePrefs {
  const UpdatePrefs();

  static const UpdatePrefs instance = UpdatePrefs();

  static const String _autoCheckKey = 'updates.auto_check';
  static const String _lastCheckedKey = 'updates.last_checked_ms';

  Future<bool> autoCheckEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    // Absent means a fresh install, where the feature ships switched on.
    return prefs.getBool(_autoCheckKey) ?? true;
  }

  Future<void> setAutoCheckEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoCheckKey, value);
  }

  Future<DateTime?> lastChecked() async {
    final prefs = await SharedPreferences.getInstance();
    final millis = prefs.getInt(_lastCheckedKey);
    return millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);
  }

  Future<void> setLastChecked(DateTime value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastCheckedKey, value.millisecondsSinceEpoch);
  }
}

/// Checks GitHub for a newer release, downloads its APK, and hands it to
/// Android's installer.
class UpdateService {
  UpdateService({http.Client? client}) : _client = client ?? http.Client();

  static final UpdateService instance = UpdateService();

  final http.Client _client;

  Future<String> currentVersion() async =>
      (await PackageInfo.fromPlatform()).version;

  /// Asks GitHub what the newest release is.
  ///
  /// The last-checked stamp only moves on a call that actually reached the
  /// API. A launch with no connectivity should try again next time rather than
  /// going quiet for another week.
  Future<UpdateCheck> check() async {
    final current = await currentVersion();
    try {
      final response = await _client.get(
        Uri.https('api.github.com', '/repos/$kUpdateRepo/releases/latest'),
        headers: const <String, String>{
          'Accept': 'application/vnd.github+json',
        },
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        return UpdateCheck.failed(
          current,
          'GitHub answered with ${response.statusCode}.',
        );
      }

      final Object? json = jsonDecode(response.body);
      final release =
          json is Map<String, dynamic> ? AppRelease.fromJson(json) : null;
      await UpdatePrefs.instance.setLastChecked(DateTime.now());

      if (isUpdateAvailable(
        current: AppVersion.parse(current),
        latest: release?.version,
      )) {
        return UpdateCheck.available(current, release!);
      }
      return UpdateCheck.upToDate(current);
    } on TimeoutException {
      return UpdateCheck.failed(current, 'The check timed out.');
    } catch (_) {
      return UpdateCheck.failed(current, 'Could not reach GitHub.');
    }
  }

  /// The launch-time check, which is silent by design: it returns a release
  /// only when there is something to install. Switched off, not yet due,
  /// offline, or already current all come back null and say nothing.
  Future<AppRelease?> checkOnLaunch() async {
    if (!await UpdatePrefs.instance.autoCheckEnabled()) return null;
    final due = isCheckDue(
      lastChecked: await UpdatePrefs.instance.lastChecked(),
      now: DateTime.now(),
    );
    if (!due) return null;
    return (await check()).release;
  }

  /// Downloads the APK, reporting progress as a 0..1 fraction.
  ///
  /// Streamed rather than buffered so a 40 MB APK never sits in memory, and so
  /// the dialog has something to show while it arrives.
  Future<File> download(
    AppRelease release, {
    void Function(double progress)? onProgress,
  }) async {
    // App-specific external storage: writable without a storage permission,
    // and reachable by the package installer through open_filex's provider.
    final directory = await getExternalStorageDirectory() ??
        await getApplicationSupportDirectory();
    final folder = Directory(p.join(directory.path, 'updates'));
    await folder.create(recursive: true);
    // Each APK is tens of megabytes and is dead weight the moment it has been
    // installed, so the folder holds at most the one being fetched right now.
    await for (final FileSystemEntity stale in folder.list()) {
      try {
        await stale.delete(recursive: true);
      } catch (_) {
        // A file the installer still has open can wait for the next attempt.
      }
    }
    final file =
        File(p.join(folder.path, 'tu-expense-tracker-${release.tag}.apk'));

    final response =
        await _client.send(http.Request('GET', Uri.parse(release.apkUrl)));
    if (response.statusCode != 200) {
      throw HttpException('The download failed (${response.statusCode}).');
    }

    final total = response.contentLength ?? 0;
    var received = 0;
    final sink = file.openWrite();
    try {
      await for (final List<int> chunk in response.stream) {
        sink.add(chunk);
        received += chunk.length;
        // A release asset redirects to a CDN that need not send a length. With
        // no total to divide by, the bar stays indeterminate rather than lying.
        if (total > 0) onProgress?.call(received / total);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    return file;
  }

  /// Opens [file] with the package installer. Returns null on success, or a
  /// message to show when the handover could not happen.
  ///
  /// The install itself is a system dialog that cannot be skipped, and the APK
  /// is signed with the same key as the running build, so it installs over the
  /// top rather than demanding an uninstall first.
  Future<String?> install(File file) async {
    final status = await Permission.requestInstallPackages.request();
    if (!status.isGranted) {
      return 'Android needs permission to install apps from this one. '
          'Allow it in Settings, then try again.';
    }
    final result = await OpenFilex.open(
      file.path,
      type: 'application/vnd.android.package-archive',
    );
    return result.type == ResultType.done ? null : result.message;
  }
}

// ---------------------------------------------------------------------------
// 5. UI
// ---------------------------------------------------------------------------

class TuExpenseTrackerApp extends StatelessWidget {
  const TuExpenseTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TU Expense Tracker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00518F)),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00518F),
          brightness: Brightness.dark,
        ),
      ),
      home: const HomeShell(),
    );
  }
}

// ---------------------------------------------------------------------------
// 4b. BACKUP WORKBOOK
// ---------------------------------------------------------------------------

/// Sheet names. Constants because both the writer and the reader need them to
/// agree exactly, and a typo in one of the two would only show up at restore.
const String kSheetTransactions = 'Transactions';
const String kSheetSplits = 'Splits';
const String kSheetCategories = 'Categories';
const String kSheetMerchantDefaults = 'Merchant defaults';
const String kSheetAliases = 'Name aliases';
const String kSheetDeleted = 'Deleted';
const String kSheetMeta = 'Meta';

/// The columns a restore actually reads, per sheet. Everything else in a sheet
/// is there for the human — a merged name, a joined category, a formatted date
/// — and is regenerated on the next export rather than imported.
///
/// The importer looks these up **by header name, not by position**. That is
/// what lets someone reorder or hide columns in Sheets, or insert a column of
/// their own notes, and still restore the file afterwards.
const Map<String, List<String>> kRequiredHeaders = <String, List<String>>{
  kSheetTransactions: <String>[
    'id',
    'Timestamp (ms)',
    'Amount',
    'Direction',
    'Merchant (as stored)',
    'Card (as stored)',
    'Category id',
    'Note',
    'Reference',
  ],
  kSheetSplits: <String>[
    'id',
    'transaction_id',
    'Category id',
    'Amount',
    'position',
  ],
  kSheetCategories: <String>['id', 'Name'],
  kSheetMerchantDefaults: <String>['Merchant', 'Category id'],
  kSheetAliases: <String>['Kind', 'Alias', 'Canonical'],
  kSheetDeleted: <String>[
    'Amount',
    'Merchant',
    'Timestamp (ms)',
    'Direction',
    'Reference',
    'Card / account',
    'Category id',
    'Original id',
    'Deleted at (ms)',
    'Note',
    'Splits (JSON)',
  ],
  kSheetMeta: <String>['Key', 'Value'],
};

// --- cell helpers ----------------------------------------------------------
//
// Reading is deliberately forgiving about *which* numeric cell type turned up,
// because the excel package is not consistent about it in one specific and
// entirely silent way: it writes a double via `toString()`, so a whole-rupee
// 1200.0 goes out as "1200.0" — and then reads it back as an `IntCellValue`,
// because its parser treats a fractional part of all zeroes as an integer.
// An amount column therefore has to accept both, or every round amount in the
// ledger would fail to restore.

String? _cellText(CellValue? cell) => switch (cell) {
      null => null,
      TextCellValue() => cell.value.toString(),
      IntCellValue() => cell.value.toString(),
      DoubleCellValue() => cell.value.toString(),
      BoolCellValue() => cell.value.toString(),
      _ => cell.toString(),
    };

/// Blank means blank. Used for the nullable text columns, where the database
/// genuinely holds NULL — a tombstone written before v7 has no note at all.
String? _cellTextOrNull(CellValue? cell) {
  final String? text = _cellText(cell);
  return (text == null || text.isEmpty) ? null : text;
}

int? _cellInt(CellValue? cell) => switch (cell) {
      IntCellValue() => cell.value,
      DoubleCellValue() => cell.value.round(),
      TextCellValue() => int.tryParse(cell.value.toString().trim()),
      _ => null,
    };

double? _cellDouble(CellValue? cell) => switch (cell) {
      DoubleCellValue() => cell.value,
      IntCellValue() => cell.value.toDouble(),
      TextCellValue() => double.tryParse(cell.value.toString().trim()),
      _ => null,
    };

/// A nullable text column on the way out. Null and empty are written the same
/// way — as an empty cell — so that export → import → export is a fixed point
/// rather than flipping a value between `''` and NULL on every pass.
CellValue? _textOrBlank(Object? value) {
  final String text = (value as String?) ?? '';
  return text.isEmpty ? null : TextCellValue(text);
}

CellValue? _intOrBlank(Object? value) =>
    value == null ? null : IntCellValue((value as num).toInt());

/// A date the spreadsheet understands, so Sheets sorts and filters it as a date
/// rather than as text. Purely for reading: the authoritative value is always
/// the neighbouring epoch-millis column, because an Excel serial date carries no
/// timezone and this one sits inside a unique index.
CellValue? _dateCell(Object? millis) => millis == null
    ? null
    : DateTimeCellValue.fromDateTime(
        DateTime.fromMillisecondsSinceEpoch((millis as num).toInt()),
      );

/// The split lines as one readable phrase — `Grocery 1200.00; Food 800.00`.
/// Display only; the Splits sheet is what a restore reads.
String splitSummary(List<Map<String, Object?>> lines, Map<int, String> names) {
  if (lines.isEmpty) return '';
  return lines.map((Map<String, Object?> line) {
    final String name =
        names[(line['category_id'] as num?)?.toInt()] ?? kUncategorized;
    final double amount = (line['amount'] as num?)?.toDouble() ?? 0;
    return '$name ${amount.toStringAsFixed(2)}';
  }).join('; ');
}

// --- writing ---------------------------------------------------------------

/// The whole database as a workbook, ready to be written to disk.
///
/// Seven sheets, each with a header row the importer keys off. The readable
/// columns come first and the machinery is pushed to the right, so that opening
/// the file lands you on dates, amounts and merchant names rather than on ids.
Uint8List encodeBackupWorkbook(BackupData data) {
  final Excel excel = Excel.createExcel();

  // Category and alias lookups for the display-only columns. Built once here
  // rather than queried per row, and never consulted on the way back in.
  final Map<int, String> categoryNames = <int, String>{
    for (final Map<String, Object?> row in data.categories)
      (row['id'] as num).toInt(): row['name'] as String,
  };
  final Map<String, String> merchantAliases = <String, String>{
    for (final Map<String, Object?> row in data.aliases)
      if (row['kind'] == NameKind.merchant.column)
        (row['alias'] as String).toLowerCase(): row['canonical'] as String,
  };
  final Map<String, String> cardAliases = <String, String>{
    for (final Map<String, Object?> row in data.aliases)
      if (row['kind'] == NameKind.card.column)
        (row['alias'] as String).toLowerCase(): row['canonical'] as String,
  };
  final Map<int, List<Map<String, Object?>>> splitsByTxn =
      <int, List<Map<String, Object?>>>{};
  for (final Map<String, Object?> row in data.splits) {
    (splitsByTxn[(row['transaction_id'] as num).toInt()] ??=
            <Map<String, Object?>>[])
        .add(row);
  }

  String merged(Map<String, String> aliases, String? raw) =>
      raw == null ? '' : (aliases[raw.toLowerCase()] ?? raw);

  void sheet(String name, List<String> headers,
      List<List<CellValue?>> Function() rows) {
    final Sheet target = excel[name];
    target.appendRow(
      headers.map<CellValue?>((String h) => TextCellValue(h)).toList(),
    );
    for (int i = 0; i < headers.length; i++) {
      target
          .cell(CellIndex.indexByColumnRow(columnIndex: i, rowIndex: 0))
          .cellStyle = CellStyle(bold: true);
    }
    for (final List<CellValue?> row in rows()) {
      target.appendRow(row);
    }
    for (int i = 0; i < headers.length; i++) {
      target.setColumnAutoFit(i);
    }
  }

  sheet(
    kSheetTransactions,
    const <String>[
      'Date',
      'Amount',
      'Direction',
      'Merchant',
      'Category',
      'Card / account',
      'Note',
      'Split',
      'Reference',
      'id',
      'Timestamp (ms)',
      'Merchant (as stored)',
      'Card (as stored)',
      'Category id',
    ],
    () => data.transactions.map((Map<String, Object?> row) {
      final int id = (row['id'] as num).toInt();
      final int categoryId = (row['category_id'] as num).toInt();
      return <CellValue?>[
        _dateCell(row['date']),
        DoubleCellValue((row['amount'] as num).toDouble()),
        TextCellValue(row['direction'] as String),
        TextCellValue(merged(merchantAliases, row['merchant'] as String)),
        TextCellValue(categoryNames[categoryId] ?? ''),
        TextCellValue(merged(cardAliases, row['payment_type'] as String?)),
        _textOrBlank(row['note']),
        _textOrBlank(
          splitSummary(
            splitsByTxn[id] ?? const <Map<String, Object?>>[],
            categoryNames,
          ),
        ),
        _textOrBlank(row['reference']),
        IntCellValue(id),
        IntCellValue((row['date'] as num).toInt()),
        TextCellValue(row['merchant'] as String),
        _textOrBlank(row['payment_type']),
        IntCellValue(categoryId),
      ];
    }).toList(),
  );

  sheet(
    kSheetSplits,
    const <String>[
      'transaction_id',
      'position',
      'Category',
      'Amount',
      'Category id',
      'id',
    ],
    () => data.splits.map((Map<String, Object?> row) {
      final int categoryId = (row['category_id'] as num).toInt();
      return <CellValue?>[
        IntCellValue((row['transaction_id'] as num).toInt()),
        IntCellValue((row['position'] as num).toInt()),
        TextCellValue(categoryNames[categoryId] ?? ''),
        DoubleCellValue((row['amount'] as num).toDouble()),
        IntCellValue(categoryId),
        IntCellValue((row['id'] as num).toInt()),
      ];
    }).toList(),
  );

  sheet(
    kSheetCategories,
    const <String>['id', 'Name'],
    () => data.categories
        .map((Map<String, Object?> row) => <CellValue?>[
              IntCellValue((row['id'] as num).toInt()),
              TextCellValue(row['name'] as String),
            ])
        .toList(),
  );

  sheet(
    kSheetMerchantDefaults,
    const <String>['Merchant', 'Category', 'Category id'],
    () => data.merchantMappings.map((Map<String, Object?> row) {
      final int categoryId = (row['category_id'] as num).toInt();
      return <CellValue?>[
        TextCellValue(row['merchant_name'] as String),
        TextCellValue(categoryNames[categoryId] ?? ''),
        IntCellValue(categoryId),
      ];
    }).toList(),
  );

  sheet(
    kSheetAliases,
    const <String>['Kind', 'Alias', 'Canonical'],
    () => data.aliases
        .map((Map<String, Object?> row) => <CellValue?>[
              TextCellValue(row['kind'] as String),
              TextCellValue(row['alias'] as String),
              TextCellValue(row['canonical'] as String),
            ])
        .toList(),
  );

  sheet(
    kSheetDeleted,
    const <String>[
      'Deleted at',
      'Amount',
      'Merchant',
      'Direction',
      'Card / account',
      'Note',
      'Reference',
      'Timestamp (ms)',
      'Deleted at (ms)',
      'Category id',
      'Original id',
      'Splits (JSON)',
    ],
    () => data.deleted
        .map((Map<String, Object?> row) => <CellValue?>[
              _dateCell(row['deleted_at']),
              DoubleCellValue((row['amount'] as num).toDouble()),
              TextCellValue(row['merchant'] as String),
              TextCellValue(row['direction'] as String),
              _textOrBlank(row['payment_type']),
              _textOrBlank(row['note']),
              _textOrBlank(row['reference']),
              IntCellValue((row['date'] as num).toInt()),
              _intOrBlank(row['deleted_at']),
              _intOrBlank(row['category_id']),
              _intOrBlank(row['original_id']),
              _textOrBlank(row['splits_json']),
            ])
        .toList(),
  );

  sheet(
    kSheetMeta,
    const <String>['Key', 'Value'],
    () => <List<CellValue?>>[
      for (final MapEntry<String, String> entry in data.meta.entries)
        <CellValue?>[TextCellValue(entry.key), TextCellValue(entry.value)],
      // `app_meta` rides here under a prefix rather than in a sheet of its own.
      // It holds one key — the inbox scan watermark — and a whole tab for it
      // would be a tab of noise.
      for (final Map<String, Object?> row in data.appMeta)
        <CellValue?>[
          TextCellValue('app_meta.${row['key']}'),
          TextCellValue(row['value'] as String),
        ],
    ],
  );

  // createExcel() opens with a stock 'Sheet1'. It can only go once the seven
  // real sheets exist, since a workbook may not be left with none.
  excel.delete('Sheet1');
  excel.setDefaultSheet(kSheetTransactions);

  final List<int>? bytes = excel.encode();
  if (bytes == null) {
    throw const BackupFormatException('The workbook could not be written.');
  }
  return Uint8List.fromList(bytes);
}

// --- reading ---------------------------------------------------------------

/// One sheet, reduced to a header-name → column-index map plus its data rows.
class _SheetReader {
  _SheetReader(this.name, this._headers, this._rows);

  factory _SheetReader.of(Excel excel, String name) {
    final Sheet? sheet = excel.tables[name];
    if (sheet == null) {
      throw BackupFormatException(
        'This workbook has no "$name" sheet, so it is not a backup this app '
        'can read.',
      );
    }
    final List<List<Data?>> rows = sheet.rows;
    if (rows.isEmpty) {
      throw BackupFormatException('The "$name" sheet is empty — not even a '
          'header row.');
    }
    final Map<String, int> headers = <String, int>{};
    for (int i = 0; i < rows.first.length; i++) {
      final String? label = _cellText(rows.first[i]?.value)?.trim();
      if (label != null && label.isNotEmpty) headers[label] = i;
    }
    for (final String required in kRequiredHeaders[name]!) {
      if (!headers.containsKey(required)) {
        throw BackupFormatException(
          'The "$name" sheet has no "$required" column. It is one of the '
          'columns a restore reads, so the file cannot be imported.',
        );
      }
    }
    return _SheetReader(name, headers, rows.skip(1).toList());
  }

  final String name;
  final Map<String, int> _headers;
  final List<List<Data?>> _rows;

  int get length => _rows.length;

  /// True when every cell in the row is empty. Sheets pads a table out with
  /// blank rows the moment anyone scrolls, and importing those as transactions
  /// with a null amount would be absurd.
  bool _isBlank(List<Data?> row) =>
      row.every((Data? cell) => _cellText(cell?.value)?.isEmpty ?? true);

  /// Walks the data rows, handing [read] a cell-getter and the row's number as
  /// a spreadsheet would print it. Blank rows are skipped rather than failing
  /// the import.
  void forEach(
    void Function(CellValue? Function(String) cell, int rowNumber) read,
  ) {
    for (int i = 0; i < _rows.length; i++) {
      final List<Data?> row = _rows[i];
      if (_isBlank(row)) continue;
      CellValue? cell(String header) {
        final int? index = _headers[header];
        if (index == null || index >= row.length) return null;
        return row[index]?.value;
      }

      read(cell, i + 2); // +2: one-based, and past the header row
    }
  }

  /// [forEach], collecting what each row reads into a table.
  List<Map<String, Object?>> map(
    Map<String, Object?> Function(CellValue? Function(String) cell, int rowNumber)
        read,
  ) {
    final List<Map<String, Object?>> out = <Map<String, Object?>>[];
    forEach((CellValue? Function(String) cell, int rowNumber) {
      out.add(read(cell, rowNumber));
    });
    return out;
  }

  Never bad(int rowNumber, String problem) => throw BackupFormatException(
        '"$name" row $rowNumber: $problem',
      );
}

/// Reads a workbook written by [encodeBackupWorkbook] back into raw rows.
///
/// Throws [BackupFormatException] rather than returning half a database. Only
/// the columns a restore needs are read; the display ones are recomputed on the
/// next export, which is also why hand-editing a merchant name in the readable
/// column has no effect — the "(as stored)" column is the one that counts.
BackupData decodeBackupWorkbook(List<int> bytes) {
  final Excel excel;
  try {
    excel = Excel.decodeBytes(bytes);
  } catch (error) {
    throw BackupFormatException(
      'That file could not be opened as a spreadsheet ($error).',
    );
  }

  final _SheetReader metaSheet = _SheetReader.of(excel, kSheetMeta);
  final Map<String, String> meta = <String, String>{};
  final List<Map<String, Object?>> appMeta = <Map<String, Object?>>[];
  metaSheet.forEach((CellValue? Function(String) cell, int _) {
    final String key = _cellText(cell('Key'))?.trim() ?? '';
    final String value = _cellText(cell('Value')) ?? '';
    if (key.startsWith('app_meta.')) {
      appMeta.add(<String, Object?>{
        'key': key.substring('app_meta.'.length),
        'value': value,
      });
    } else if (key.isNotEmpty) {
      meta[key] = value;
    }
  });

  if (meta['format'] != kBackupFormat) {
    throw const BackupFormatException(
      'This spreadsheet was not written by this app, so restoring from it '
      'would be guesswork.',
    );
  }

  final _SheetReader categories = _SheetReader.of(excel, kSheetCategories);
  final _SheetReader mappings = _SheetReader.of(excel, kSheetMerchantDefaults);
  final _SheetReader transactions = _SheetReader.of(excel, kSheetTransactions);
  final _SheetReader splits = _SheetReader.of(excel, kSheetSplits);
  final _SheetReader deleted = _SheetReader.of(excel, kSheetDeleted);
  final _SheetReader aliases = _SheetReader.of(excel, kSheetAliases);

  return BackupData(
    meta: meta,
    appMeta: appMeta,
    categories: categories.map((CellValue? Function(String) cell, int row) {
      final int? id = _cellInt(cell('id'));
      final String? name = _cellText(cell('Name'));
      if (id == null) categories.bad(row, 'the id is missing or not a number.');
      if (name == null || name.isEmpty) categories.bad(row, 'the name is empty.');
      return <String, Object?>{'id': id, 'name': name};
    }),
    merchantMappings: mappings.map((CellValue? Function(String) cell, int row) {
      final String? merchant = _cellText(cell('Merchant'));
      final int? categoryId = _cellInt(cell('Category id'));
      if (merchant == null || merchant.isEmpty) {
        mappings.bad(row, 'the merchant is empty.');
      }
      if (categoryId == null) {
        mappings.bad(row, 'the category id is missing or not a number.');
      }
      return <String, Object?>{
        'merchant_name': merchant,
        'category_id': categoryId,
      };
    }),
    transactions:
        transactions.map((CellValue? Function(String) cell, int row) {
      final int? id = _cellInt(cell('id'));
      final int? date = _cellInt(cell('Timestamp (ms)'));
      final double? amount = _cellDouble(cell('Amount'));
      final String? merchant = _cellText(cell('Merchant (as stored)'));
      final int? categoryId = _cellInt(cell('Category id'));
      if (id == null) transactions.bad(row, 'the id is missing.');
      if (date == null) transactions.bad(row, 'the timestamp is missing.');
      if (amount == null) transactions.bad(row, 'the amount is not a number.');
      if (merchant == null || merchant.isEmpty) {
        transactions.bad(row, 'the stored merchant is empty.');
      }
      if (categoryId == null) transactions.bad(row, 'the category id is missing.');
      return <String, Object?>{
        'id': id,
        'amount': amount,
        'payment_type': _cellTextOrNull(cell('Card (as stored)')),
        'merchant': merchant,
        'date': date,
        'category_id': categoryId,
        'direction': _cellText(cell('Direction')) ?? TxnDirection.debit.name,
        'reference': _cellText(cell('Reference')) ?? '',
        'note': _cellText(cell('Note')) ?? '',
      };
    }),
    splits: splits.map((CellValue? Function(String) cell, int row) {
      final int? id = _cellInt(cell('id'));
      final int? transactionId = _cellInt(cell('transaction_id'));
      final int? categoryId = _cellInt(cell('Category id'));
      final double? amount = _cellDouble(cell('Amount'));
      if (id == null) splits.bad(row, 'the id is missing.');
      if (transactionId == null) splits.bad(row, 'the transaction id is missing.');
      if (categoryId == null) splits.bad(row, 'the category id is missing.');
      if (amount == null) splits.bad(row, 'the amount is not a number.');
      return <String, Object?>{
        'id': id,
        'transaction_id': transactionId,
        'category_id': categoryId,
        'amount': amount,
        'position': _cellInt(cell('position')) ?? 0,
      };
    }),
    deleted: deleted.map((CellValue? Function(String) cell, int row) {
      final double? amount = _cellDouble(cell('Amount'));
      final String? merchant = _cellText(cell('Merchant'));
      final int? date = _cellInt(cell('Timestamp (ms)'));
      if (amount == null) deleted.bad(row, 'the amount is not a number.');
      if (merchant == null || merchant.isEmpty) {
        deleted.bad(row, 'the merchant is empty.');
      }
      if (date == null) deleted.bad(row, 'the timestamp is missing.');
      return <String, Object?>{
        'amount': amount,
        'merchant': merchant,
        'date': date,
        'direction': _cellText(cell('Direction')) ?? TxnDirection.debit.name,
        'reference': _cellText(cell('Reference')) ?? '',
        'payment_type': _cellTextOrNull(cell('Card / account')),
        'category_id': _cellInt(cell('Category id')),
        'original_id': _cellInt(cell('Original id')),
        'deleted_at': _cellInt(cell('Deleted at (ms)')),
        'splits_json': _cellTextOrNull(cell('Splits (JSON)')),
        'note': _cellTextOrNull(cell('Note')),
      };
    }),
    aliases: aliases.map((CellValue? Function(String) cell, int row) {
      final String? kind = _cellText(cell('Kind'));
      final String? alias = _cellText(cell('Alias'));
      final String? canonical = _cellText(cell('Canonical'));
      if (kind == null || kind.isEmpty) aliases.bad(row, 'the kind is empty.');
      if (alias == null || alias.isEmpty) aliases.bad(row, 'the alias is empty.');
      if (canonical == null || canonical.isEmpty) {
        aliases.bad(row, 'the canonical name is empty.');
      }
      return <String, Object?>{
        'kind': kind,
        'alias': alias,
        'canonical': canonical,
      };
    }),
  );
}

// --- files, isolates and the share sheet -----------------------------------

/// What Android and Google Drive need to be told an `.xlsx` is, so that Sheets
/// offers to open it rather than the file being treated as an unknown blob.
const String kXlsxMimeType =
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

/// What a backup is called. Dated, because the first thing anyone wants to know
/// about a file found in Drive a year later is when it was taken.
///
/// The pre-restore copy carries the time as well: a restore that went wrong is
/// likely to be followed by another attempt within the minute, and two safety
/// copies from one afternoon must not overwrite each other.
String backupFileName(DateTime at, {bool beforeRestore = false}) =>
    beforeRestore
        ? 'tu-expense-before-restore-'
            '${DateFormat('yyyy-MM-dd-HHmm').format(at)}.xlsx'
        : 'tu-expense-${DateFormat('yyyy-MM-dd').format(at)}.xlsx';

/// Where backups land. App-specific external storage, for the same reasons the
/// updater uses it: writable without a storage permission, and readable by the
/// app a share hands the file on to.
Future<Directory> _backupFolder() async {
  final Directory base = await getExternalStorageDirectory() ??
      await getApplicationSupportDirectory();
  final Directory folder = Directory(p.join(base.path, 'backups'));
  await folder.create(recursive: true);
  return folder;
}

/// Builds the workbook and writes it, returning the file.
///
/// The encoding happens on a background isolate. A workbook is zipped XML built
/// a cell at a time, so a few thousand transactions is comfortably enough work
/// to freeze a spinner mid-spin if it were done here.
Future<File> writeBackup(BackupData data, String fileName) async {
  final Directory folder = await _backupFolder();
  final File file = File(p.join(folder.path, fileName));
  await file.writeAsBytes(await compute(encodeBackupWorkbook, data));
  return file;
}

/// [decodeBackupWorkbook] on a background isolate.
///
/// Returns the failure rather than throwing it: the message is written for the
/// user, and having it survive the isolate boundary as a plain string is surer
/// than trusting an exception object to.
Future<(BackupData?, String?)> decodeBackupInBackground(Uint8List bytes) =>
    compute(_decodeOrMessage, bytes);

(BackupData?, String?) _decodeOrMessage(Uint8List bytes) {
  try {
    return (decodeBackupWorkbook(bytes), null);
  } on BackupFormatException catch (error) {
    return (null, error.message);
  } catch (error) {
    return (null, 'That file could not be read as a backup ($error).');
  }
}

/// Asks before a restore throws the current ledger away.
///
/// Both counts are named because they are the one thing that makes the question
/// answerable — restoring 1,190 transactions over 1,284 is a very different
/// proposition from restoring them over none, and only the user knows which of
/// the two they meant. False for a dismissed dialog, so a tap outside cancels.
Future<bool> confirmRestore(
  BuildContext context, {
  required int replacing,
  required int incoming,
}) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) {
      final ColorScheme scheme = Theme.of(dialogContext).colorScheme;
      return AlertDialog(
        title: const Text('Restore from this backup?'),
        content: Text(
          replacing == 0
              ? 'This loads $incoming transactions. There is nothing in the '
                  'app to replace.'
              : 'This replaces all $replacing transactions currently in the '
                  'app with the $incoming in this file, along with their '
                  'categories, splits, merges and deleted rows.\n\n'
                  'A copy of what is here now is saved first, but nothing '
                  'else can undo it.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Replace'),
          ),
        ],
      );
    },
  );
  return confirmed ?? false;
}

/// Shows why a file was refused, having touched nothing.
///
/// Long lists are truncated: a workbook broken in one place is usually broken
/// in a hundred, and a dialog listing all hundred says less than one listing
/// five and a count.
Future<void> showBackupProblems(
  BuildContext context,
  List<String> problems,
) {
  const int shown = 5;
  final List<String> visible = problems.take(shown).toList();
  final int rest = problems.length - visible.length;
  return showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: const Text('This backup cannot be restored'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Text('Nothing in the app has been changed.'),
            const SizedBox(height: 12),
            for (final String problem in visible)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text('• $problem'),
              ),
            if (rest > 0)
              Text(
                'and $rest more.',
                style: Theme.of(dialogContext).textTheme.bodySmall,
              ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

/// What one pass over the inbox did. [skipped] counts alerts that parsed but
/// were already recorded or had been deleted.
class _ScanResult {
  const _ScanResult({
    required this.added,
    required this.skipped,
    required this.addedInView,
  });

  final int added;
  final int skipped;

  /// How many of [added] fall in the months the ledger is currently showing.
  /// Less than [added] means rows landed somewhere the user cannot see.
  final int addedInView;
}

/// The three destinations, **in bar order — which is also `IndexedStack` order**.
///
/// An enum rather than bare indices because four separate places used to
/// hardcode `0` and `1`, and inserting a tab between them is exactly the change
/// that makes such a number mean something else without saying so. Same move
/// [LedgerSort] and [NameKind] already make.
enum HomeTab {
  dashboard('Dashboard', Icons.pie_chart_outline, Icons.pie_chart),
  transactions('Transactions', Icons.receipt_long_outlined, Icons.receipt_long),
  settings('Settings', Icons.settings_outlined, Icons.settings);

  const HomeTab(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// One ledger, three screens: the charts over it, the list itself — filter,
/// sort, categorise, split and delete — and Settings. This shell owns the data
/// and the view over it; the tabs only render what they are handed.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final AppDatabase _db = AppDatabase.instance;
  final SmsSource _sms = SmsSource();

  final NumberFormat _money =
      NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 2);
  final DateFormat _dateFormat = DateFormat('dd MMM yyyy · h:mm a');

  List<ExpenseTxn> _transactions = <ExpenseTxn>[];
  List<ExpenseCategory> _categories = <ExpenseCategory>[];
  bool _loading = true;
  bool _scanning = false;
  HomeTab _tab = HomeTab.dashboard;

  /// The month the app considers "now". Refreshed on every load rather than
  /// read in `build`: it decides where Clear goes back to and which month is
  /// always on offer, and a `DateTime.now()` per build would roll those answers
  /// over mid-frame at midnight and be unpinnable in a test.
  YearMonth _currentMonth = YearMonth.current();

  /// How the ledger is narrowed and ordered. Held here rather than in the tab
  /// because the selection app bar — built here — has to know which rows are on
  /// screen before it can offer to select or delete "all" of them.
  ///
  /// Assigned in [initState] so it and [_currentMonth] cannot disagree — a
  /// field initialiser cannot refer to another field.
  late LedgerFilters _filters;
  LedgerSort _sort = LedgerSort.newest;

  /// The Dashboard's own period, deliberately not the ledger's.
  ///
  /// The charts exist to compare several months; the list opens on one and is
  /// scrubbed around in. Sharing one field would mean building a three-month
  /// comparison silently dumped three months of rows into the list, and a
  /// scrubbing session silently repointed the charts — and because the two tabs
  /// live in an `IndexedStack` and stay alive, neither would be noticed until
  /// the user switched back.
  late Set<YearMonth> _dashboardMonths;

  /// Ids marked for deletion. Lives here rather than in the tab because the app
  /// bar it takes over is built here.
  final Set<int> _selected = <int>{};

  @override
  void initState() {
    super.initState();
    // The `IndexedStack` in `build` is written out by hand while the
    // `NavigationBar` is generated from the enum, so a destination added
    // without a child would silently show the wrong screen. Fail loudly here
    // instead.
    assert(HomeTab.values.length == 3, 'HomeTab and IndexedStack are out of step');
    // One reading of the clock for all three, so they cannot disagree.
    _currentMonth = YearMonth.current();
    _filters = LedgerFilters.defaults(_currentMonth);
    _dashboardMonths = <YearMonth>{_currentMonth};
    _load();
    _startSms();
    _checkForUpdates();
  }

  Future<void> _load() async {
    final results = await Future.wait(<Future<Object>>[
      _db.transactions(),
      _db.categories(),
    ]);
    if (!mounted) return;
    setState(() {
      _transactions = results[0] as List<ExpenseTxn>;
      _categories = results[1] as List<ExpenseCategory>;
      // An app left open across midnight on the last of the month rolls over
      // here, on the next refresh, scan or return from Settings — deterministic
      // and never mid-build.
      _currentMonth = YearMonth.current();
      _loading = false;
    });
  }

  // -------------------------------------------------------------------------
  // SMS INTAKE
  // -------------------------------------------------------------------------

  /// Asks for the permission, registers the foreground listener, then catches
  /// up on the inbox — the whole of it on the very first run, and only what has
  /// arrived since on every run after that.
  Future<void> _startSms() async {
    if (!_sms.isSupported) return;
    final granted = await _sms.requestPermission();
    if (!granted) return;

    _sms.listen((InboxSms sms) async {
      final parsed = SmsParser.parse(sms.body, receivedAt: sms.receivedAt);
      if (parsed == null) return; // not a transaction alert
      await _db.insertParsed(parsed);
      await _load();
    });

    final since = await _db.lastScannedSmsDate();
    final result = await _scan(since: since);
    // Only the first import is worth announcing; later catch-ups are routine.
    if (result != null && since == null && result.added > 0) {
      _toast('Imported ${result.added} transaction(s) from your inbox.');
    }
  }

  /// One pass over the inbox. The caller owns the permission check. Returns
  /// null when a scan is already in flight.
  Future<_ScanResult?> _scan({DateTime? since}) async {
    if (_scanning) return null;
    setState(() => _scanning = true);
    try {
      final messages = await _sms.readInbox(since: since);

      DateTime? newest;
      var added = 0;
      var skipped = 0;
      // Counted so the toast can say how many of them the list will actually
      // show. A full rescan mostly imports older months, and "Imported 214"
      // over an unchanged list is alarming rather than informative.
      var addedInView = 0;
      for (final sms in messages) {
        final at = sms.receivedAt;
        if (at != null && (newest == null || at.isAfter(newest))) newest = at;

        final parsed = SmsParser.parse(sms.body, receivedAt: at);
        if (parsed == null) continue; // OTP, promo, statement alert
        final id = await _db.insertParsed(parsed);
        if (id == 0) {
          skipped++;
          continue;
        }
        added++;
        if (_filters.months.isEmpty ||
            _filters.months.contains(YearMonth.fromDate(parsed.date))) {
          addedInView++;
        }
      }

      // Advance from the newest message actually seen rather than from the
      // clock: a skewed device time would otherwise strand real messages behind
      // the watermark. Forwards only, and only now that the pass has finished —
      // a scan that threw leaves the watermark alone, so the next one covers
      // the same ground again.
      if (newest != null) {
        final current = await _db.lastScannedSmsDate();
        if (current == null || newest.isAfter(current)) {
          await _db.setLastScannedSmsDate(newest);
        }
      }

      await _load();
      return _ScanResult(
          added: added, skipped: skipped, addedInView: addedInView);
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  /// The toolbar action. [full] ignores the watermark and re-reads everything —
  /// safe to run at any time, since duplicates are caught by the natural key
  /// index and deliberately deleted rows by their tombstones. Worth doing after
  /// the parser learns a new template.
  Future<void> _scanFromToolbar({bool full = false}) async {
    if (!_sms.isSupported) {
      _toast('Inbox scanning is only available on Android.');
      return;
    }
    final granted = await _sms.requestPermission();
    if (!granted) {
      _toast('SMS permission denied.');
      return;
    }

    final since = full ? null : await _db.lastScannedSmsDate();
    final result = await _scan(since: since);
    if (result == null) return; // a scan was already running

    if (result.added == 0 && result.skipped == 0) {
      _toast('No new bank messages found.');
      return;
    }
    // Only worth saying when the two numbers differ — otherwise it is noise.
    final String elsewhere = result.added > result.addedInView
        ? ' · ${result.addedInView} in ${periodLabel(_filters.months)}'
        : '';
    _toast('Imported ${result.added} new transaction(s), skipped '
        '${result.skipped} already recorded or deleted.$elsewhere');
  }

  // -------------------------------------------------------------------------
  // EDITING
  // -------------------------------------------------------------------------

  /// Feeds an arbitrary SMS body through parse -> auto-categorize -> insert.
  Future<void> _ingest(String body) async {
    final parsed = SmsParser.parse(body);
    if (parsed == null) {
      _toast('Could not parse that SMS — no template matched.');
      return;
    }
    final id = await _db.insertParsed(parsed);
    await _load();
    final verb = parsed.isCredit ? 'Received' : 'Added';
    _toast(id == 0
        ? 'Already recorded or deleted: ${parsed.merchant}'
        : '$verb ${_money.format(parsed.amount)} · ${parsed.merchant}'
            '${_outOfViewSuffix(parsed.date)}');
  }

  /// Names the month when a row has just been imported into one the list is not
  /// showing.
  ///
  /// Without it, adding a transaction dated last month says "Added ₹450 ·
  /// SWIGGY" over a list where nothing appeared — which reads as the app having
  /// lost it. Saying where it went is better than silently widening the
  /// selection the user chose.
  String _outOfViewSuffix(DateTime date) {
    final YearMonth month = YearMonth.fromDate(date);
    if (_filters.months.isEmpty || _filters.months.contains(month)) return '';
    return ' · in ${month.label}';
  }

  /// Step 5: persist the merchant -> category mapping and backfill history.
  /// Categorises **this transaction** and, only if asked, makes the pick the
  /// merchant's default as well.
  ///
  /// Correcting one row used to re-tag every transaction from that merchant,
  /// which is far more than anyone means by it — and would silently flatten a
  /// split. The rule is now the narrow one, and the wider one is opt-in.
  Future<void> _pickCategory(ExpenseTxn txn) async {
    final chosen = await showModalBottomSheet<CategoryChoice>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => CategoryPickerSheet(
        merchant: txn.merchant,
        categories: _categories,
        selectedId: txn.isUncategorized ? null : txn.categoryId,
        subtitle: txn.isSplit
            ? 'This transaction is split. Picking a category replaces its '
                'split with one category.'
            : 'Applies to this transaction.',
        showMakeDefault: true,
      ),
    );
    if (chosen == null) return;

    await _db.setTransactionCategory(
      transactionId: txn.id,
      categoryId: chosen.category.id,
    );

    var updated = 0;
    if (chosen.makeDefault) {
      updated = await _setMerchantDefault(txn.merchant, chosen.category);
      if (!mounted) return;
    }

    await _load();
    _toast(chosen.makeDefault
        ? '${txn.merchant} → ${chosen.category.name} '
            '(default set${updated > 0 ? ', $updated updated' : ''})'
        : '${txn.merchant} → ${chosen.category.name}');
  }

  /// Writes what the user wants to remember about one charge — the context the
  /// bank's alert could never carry.
  ///
  /// Saving an empty field is how a note is removed, so there is no separate
  /// delete: clearing the box and pressing Save is the obvious gesture, and
  /// honouring it costs nothing.
  Future<void> _editNote(ExpenseTxn txn) async {
    final TextEditingController controller =
        TextEditingController(text: txn.note);
    // Selection parked at the end so an existing note is added to rather than
    // typed over, which is what reopening one is nearly always for.
    controller.selection =
        TextSelection.collapsed(offset: controller.text.length);

    final String? typed = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(txn.hasNote ? 'Edit note' : 'Add note'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          maxLength: kNoteMaxLength,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            hintText: 'What was this for?',
            helperText: '${txn.merchant} · ${_money.format(txn.amount)}',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || typed == null) return;

    final String note = cleanNote(typed);
    if (note == txn.note) return; // Opened, changed nothing, backed out.

    await _db.setTransactionNote(transactionId: txn.id, note: note);
    if (!mounted) return;
    await _load();
    _toast(note.isEmpty ? 'Note removed' : 'Note saved');
  }

  /// Saves the merchant default, asking first whether history should move with
  /// it. Returns how many past transactions were re-tagged.
  Future<int> _setMerchantDefault(
    String merchant,
    ExpenseCategory category,
  ) async {
    final int uncategorized = await _db.uncategorizedId();
    var backfill = false;

    // Uncategorized as a default means "always ask me", which is never applied
    // backwards — see [AppDatabase.setMerchantDefault].
    if (category.id != uncategorized) {
      final int n = await _db.backfillableCount(
        merchant: merchant,
        categoryId: category.id,
      );
      if (!mounted) return 0;
      if (n > 0) {
        backfill = await showDialog<bool>(
              context: context,
              builder: (BuildContext context) => AlertDialog(
                title: const Text('Apply to past transactions?'),
                content: Text(
                  '$n past transaction${n == 1 ? '' : 's'} from $merchant '
                  'would move to ${category.name}. Transactions you have '
                  'split are left alone.',
                ),
                actions: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Future only'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: Text('Apply to $n'),
                  ),
                ],
              ),
            ) ??
            false;
      }
    }
    if (!mounted) return 0;

    return _db.setMerchantDefault(
      merchant: merchant,
      categoryId: category.id,
      backfill: backfill,
    );
  }

  /// Deletes for good — the tombstones written by
  /// [AppDatabase.deleteTransactions] keep these rows from being re-imported by
  /// a later scan, and put them in the Deleted section for as long as it takes
  /// to change your mind.
  Future<void> _delete(List<ExpenseTxn> gone) async {
    if (gone.isEmpty) return;
    final ids = gone.map((ExpenseTxn t) => t.id).toSet();

    // Drop them from the list in this same frame: `Dismissible` has already
    // animated its row out and asserts if it is still in the tree on the next
    // build, which an awaited round trip to the database would allow.
    setState(() {
      _transactions =
          _transactions.where((ExpenseTxn t) => !ids.contains(t.id)).toList();
      _selected.removeAll(ids);
    });
    await _db.deleteTransactions(gone);
    if (!mounted) return;

    // Read them back so Undo restores from the tombstones themselves, which is
    // the same path the Deleted section uses.
    final tombstones = (await _db.deletedTransactions())
        .where((DeletedTxn d) => ids.contains(d.originalId))
        .toList();
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(gone.length == 1
            ? 'Deleted ${gone.single.merchant}'
            : 'Deleted ${gone.length} transactions'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            await _db.restoreTransactions(tombstones);
            await _load();
          },
        ),
      ));
  }

  // ---- Selection ----------------------------------------------------------

  /// Long-press starts marking; once anything is marked, plain taps toggle.
  void _toggleSelected(ExpenseTxn txn) {
    setState(() {
      if (!_selected.remove(txn.id)) _selected.add(txn.id);
    });
  }

  void _clearSelection() => setState(_selected.clear);

  /// Bulk delete asks first, through the same
  /// [confirmDeleteTransactions] a swipe goes through. The selection bar's
  /// delete sits exactly where the overflow menu is otherwise, so a reach for
  /// the menu can land on it.
  Future<void> _confirmBulkDelete() async {
    final gone = _transactions
        .where((ExpenseTxn t) => _selected.contains(t.id))
        .toList();
    if (gone.isEmpty) return;

    final bool confirmed = await confirmDeleteTransactions(context, gone.length);
    if (!mounted || !confirmed) return;
    await _delete(gone);
  }

  /// Everything that can be done from one row — categorise, split, merge its
  /// names, delete — in one sheet, so the list itself needs no per-row
  /// controls.
  Future<void> _openTransaction(ExpenseTxn txn) async {
    final action = await showModalBottomSheet<TxnAction>(
      context: context,
      showDragHandle: true,
      builder: (_) => TransactionActionsSheet(
        txn: txn,
        money: _money,
        dateFormat: _dateFormat,
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case TxnAction.categorize:
        await _pickCategory(txn);
      case TxnAction.note:
        await _editNote(txn);
      case TxnAction.split:
        await _splitTransaction(txn);
      case TxnAction.mergeMerchant:
        await _openMerge(NameKind.merchant, txn.merchant);
      case TxnAction.mergeCard:
        await _openMerge(NameKind.card, txn.paymentType);
      case TxnAction.delete:
        await _delete(<ExpenseTxn>[txn]);
    }
  }

  /// Opens the merge screen with [preselect] already ticked — the name on the
  /// row the user was looking at when they noticed the duplicate.
  Future<void> _openMerge(NameKind kind, String preselect) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => MergeNamesScreen(
        kind: kind,
        preselect: preselect,
        // Unlike the Settings route, this one comes off the transaction list,
        // which is still underneath and holding the old names.
        onChanged: _load,
      ),
    ));
  }

  Future<void> _splitTransaction(ExpenseTxn txn) async {
    final bool? changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => SplitScreen(
          txn: txn,
          categories: _categories,
          money: _money,
        ),
      ),
    );
    if (changed != true) return;
    await _load();
  }

  Future<void> _openDeleted() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => DeletedScreen(
        money: _money,
        dateFormat: _dateFormat,
        onChanged: _load,
      ),
    ));
  }

  /// The launch-time update check. Silent unless there is something to install:
  /// a check that is switched off, not yet due, offline or already current all
  /// pass without a word.
  Future<void> _checkForUpdates() async {
    final release = await UpdateService.instance.checkOnLaunch();
    if (!mounted || release == null) return;
    await showUpdateDialog(context, release);
  }

  Future<void> _addSmsManually() async {
    final controller = TextEditingController(text: kSampleSms);
    final body = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Paste an SMS'),
        content: TextField(
          controller: controller,
          maxLines: 6,
          minLines: 4,
          autofocus: true,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: 'Any Yes Bank / HDFC / ICICI spend or credit alert',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Parse'),
          ),
        ],
      ),
    );
    if (body != null && body.trim().isNotEmpty) {
      await _ingest(body);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ---- The view over the ledger -------------------------------------------

  /// Delegates to [deriveLedgerView] so the web build derives its view with
  /// this exact code rather than a second copy of it.
  LedgerView _derive() => deriveLedgerView(
        transactions: _transactions,
        allCategories: _categories,
        requested: _filters,
        currentMonth: _currentMonth,
        sort: _sort,
      );

  /// [visible] is what the filters currently leave on screen. Select all means
  /// all of *those* — marking rows a filter has hidden would hand the delete
  /// button transactions the user cannot see.
  AppBar _selectionAppBar(List<LedgerEntry> visible) {
    return AppBar(
      leading: IconButton(
        tooltip: 'Cancel',
        onPressed: _clearSelection,
        icon: const Icon(Icons.close),
      ),
      title: Text('${_selected.length} selected'),
      actions: <Widget>[
        IconButton(
          tooltip: 'Select all',
          onPressed: () => setState(() => _selected
            ..clear()
            ..addAll(visible.map((LedgerEntry e) => e.txn.id))),
          icon: const Icon(Icons.select_all),
        ),
        IconButton(
          tooltip: 'Delete',
          onPressed: _confirmBulkDelete,
          icon: const Icon(Icons.delete_outline),
        ),
      ],
    );
  }

  AppBar _normalAppBar() {
    return AppBar(
      title: const Text('Transactions'),
      actions: <Widget>[
        if (_scanning)
          const Center(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else
          IconButton(
            tooltip: 'Check for new SMS',
            onPressed: () => _scanFromToolbar(),
            icon: const Icon(Icons.sms_outlined),
          ),
        PopupMenuButton<String>(
          onSelected: (String value) {
            switch (value) {
              case 'rescan':
                _scanFromToolbar(full: true);
              case 'deleted':
                _openDeleted();
            }
          },
          itemBuilder: (_) => const <PopupMenuEntry<String>>[
            PopupMenuItem<String>(
              value: 'deleted',
              child: Text('Deleted transactions'),
            ),
            PopupMenuItem<String>(
              value: 'rescan',
              child: Text('Rescan all messages'),
            ),
          ],
        ),
      ],
    );
  }

  /// Settings can change what the ledger says — Merchants & defaults backfills
  /// a category over history — so coming back from it reloads rather than
  /// showing rows still carrying the categories they had on the way in.
  void _selectTab(HomeTab tab) {
    final bool leavingSettings =
        _tab == HomeTab.settings && tab != HomeTab.settings;
    setState(() {
      _tab = tab;
      // Marks are about rows on the ledger; leaving it drops them.
      _selected.clear();
    });
    if (leavingSettings) _load();
  }

  @override
  Widget build(BuildContext context) {
    final bool onLedger = _tab == HomeTab.transactions;
    final bool selecting = _selected.isNotEmpty;
    final view = _derive();

    return PopScope(
      // Back should leave selection mode before it leaves the app.
      canPop: !selecting,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) _clearSelection();
      },
      child: Scaffold(
        // Selection only ever happens on the ledger, so it outranks the tab.
        appBar: selecting
            ? _selectionAppBar(view.visible)
            : switch (_tab) {
                HomeTab.dashboard => AppBar(title: const Text('Dashboard')),
                // The scan and Deleted actions live here and only here. Two
                // entry points to a mutating action on two screens is a footgun.
                HomeTab.transactions => _normalAppBar(),
                HomeTab.settings => AppBar(title: const Text('Settings')),
              },
        // IndexedStack rather than a swap, so switching tabs keeps the ledger's
        // scroll position and Settings' loaded state.
        //
        // These children MUST stay in `HomeTab.values` order — position is the
        // index, and nothing in the type system says so. The assert in
        // `initState` catches a destination added without a child.
        body: IndexedStack(
          index: _tab.index,
          children: <Widget>[
            DashboardTab(
              transactions: _transactions,
              months: _dashboardMonths,
              monthChoices: monthOptions(
                _transactions,
                current: _currentMonth,
                keep: _dashboardMonths,
              ),
              currentMonth: _currentMonth,
              money: _money,
              loading: _loading,
              onMonthsChanged: (Set<YearMonth> m) =>
                  setState(() => _dashboardMonths = m),
              onRefresh: _load,
            ),
            TransactionsTab(
              entries: view.visible,
              filters: view.filters,
              sort: _sort,
              monthChoices: view.months,
              currentMonth: _currentMonth,
              categoryChoices: view.categories,
              merchantChoices: view.merchants,
              paymentTypeChoices: view.paymentTypes,
              money: _money,
              dateFormat: _dateFormat,
              loading: _loading,
              // The list can be empty because the ledger is, or because the
              // filters excluded everything — two different things to say.
              ledgerIsEmpty: _transactions.isEmpty,
              selected: _selected,
              onFiltersChanged: (LedgerFilters f) =>
                  setState(() => _filters = f),
              onSortChanged: (LedgerSort s) => setState(() => _sort = s),
              onRefresh: _load,
              onTap: _openTransaction,
              onToggleSelected: _toggleSelected,
              onDelete: (ExpenseTxn txn) => _delete(<ExpenseTxn>[txn]),
            ),
            const SettingsScreen(),
          ],
        ),
        floatingActionButton: onLedger && !selecting
            ? FloatingActionButton.extended(
                onPressed: _addSmsManually,
                icon: const Icon(Icons.content_paste_outlined),
                label: const Text('Paste an SMS'),
              )
            : null,
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab.index,
          onDestinationSelected: (int i) => _selectTab(HomeTab.values[i]),
          destinations: <NavigationDestination>[
            for (final HomeTab tab in HomeTab.values)
              NavigationDestination(
                icon: Icon(tab.icon),
                selectedIcon: Icon(tab.selectedIcon),
                label: tab.label,
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// SHARED CONTROLS — used by both the ledger and the charts
// ---------------------------------------------------------------------------

/// Lets the user tick several of [options] at once, returning the new selection
/// or null if they backed out.
///
/// Top-level rather than a method on one tab, because both tabs ask this same
/// question and a second copy would be a second thing to keep in step.
Future<Set<T>?> chooseMany<T>(
  BuildContext context, {
  required String title,
  required List<T> options,
  required Set<T> selected,
  required String Function(T) label,
  Widget Function(T)? leading,
}) =>
    showModalBottomSheet<Set<T>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (BuildContext context) => _MultiSelectSheet<T>(
        title: title,
        options: options,
        selected: selected,
        label: label,
        leading: leading,
      ),
    );

/// How many months may be compared at once. Past this the bars are too thin to
/// read, and the legend longer than the chart.
const int kMaxComparedMonths = 6;

/// The period control: which months a screen is showing, and the two ways to
/// change it.
///
/// Not a chip in the filter strip, for two reasons. The strip scrolls
/// horizontally and its first chip can read "Amount: high to low", so a fifth
/// item would sit past the fold — for the control that answers the very first
/// question anyone has about the screen, and on which every total now depends.
/// And a filter chip with nothing selected reads as "not filtering", which a
/// month never is: there is always one in force.
///
/// The steppers are here because moving one month at a time is the common
/// gesture and a modal sheet is a heavy way to do it. They are hidden rather
/// than disabled in a multi-selection, where "the previous month" means nothing.
class PeriodBar extends StatelessWidget {
  const PeriodBar({
    super.key,
    required this.months,
    required this.options,
    required this.currentMonth,
    required this.onChanged,
  });

  final Set<YearMonth> months;
  final List<YearMonth> options;
  final YearMonth currentMonth;
  final ValueChanged<Set<YearMonth>> onChanged;

  bool get _single => months.length == 1;

  Future<void> _pick(BuildContext context) async {
    final Set<YearMonth>? picked = await chooseMany<YearMonth>(
      context,
      title: 'Months',
      options: options,
      selected: months,
      label: (YearMonth m) => m.label,
    );
    if (picked == null) return;
    // Nothing ticked reads as "show me everything", which is what an empty set
    // already means everywhere else.
    onChanged(picked.length <= kMaxComparedMonths
        ? picked
        // Keep the most recent, since that is what anyone comparing wants.
        : (picked.toList()
              ..sort((YearMonth a, YearMonth b) => b.compareTo(a)))
            .take(kMaxComparedMonths)
            .toSet());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final YearMonth? only = _single ? months.first : null;
    // Offering the future is offering the empty.
    final bool canGoForward = only != null && only.compareTo(currentMonth) < 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: <Widget>[
          if (only != null)
            IconButton(
              tooltip: 'Previous month',
              icon: const Icon(Icons.chevron_left),
              onPressed: () => onChanged(<YearMonth>{only.plus(-1)}),
            ),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _pick(context),
              icon: const Icon(Icons.calendar_month_outlined, size: 18),
              label: Text(
                periodLabel(months),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge,
              ),
            ),
          ),
          if (only != null)
            IconButton(
              tooltip: 'Next month',
              icon: const Icon(Icons.chevron_right),
              onPressed:
                  canGoForward ? () => onChanged(<YearMonth>{only.plus(1)}) : null,
            ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// DASHBOARD TAB — the same ledger as charts: where the money went, per month
// ---------------------------------------------------------------------------

/// Where the money went over a chosen period.
///
/// Reads the whole ledger and narrows it by month **and nothing else**. It
/// deliberately does not inherit the transaction list's category, merchant,
/// card or search filters: a breakdown steered by a working list's filter state
/// is not a report, and a pie chart of a single category is not a chart.
class DashboardTab extends StatelessWidget {
  const DashboardTab({
    super.key,
    required this.transactions,
    required this.months,
    required this.monthChoices,
    required this.currentMonth,
    required this.money,
    required this.loading,
    required this.onMonthsChanged,
    required this.onRefresh,
  });

  final List<ExpenseTxn> transactions;
  final Set<YearMonth> months;
  final List<YearMonth> monthChoices;
  final YearMonth currentMonth;
  final NumberFormat money;
  final bool loading;
  final ValueChanged<Set<YearMonth>> onMonthsChanged;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final List<LedgerEntry> entries =
        applyFilters(transactions, months: months);
    final totals = periodTotals(entries);
    final Map<String, double> byCategory = spendByCategory(entries);

    return Column(
      children: <Widget>[
        PeriodBar(
          months: months,
          options: monthChoices,
          currentMonth: currentMonth,
          onChanged: onMonthsChanged,
        ),
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: onRefresh,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                    children: <Widget>[
                      _SpendHeadline(
                        spent: totals.spent,
                        received: totals.received,
                        count: totals.count,
                        period: periodLabel(months),
                        money: money,
                      ),
                      if (byCategory.isEmpty)
                        _NothingToChart(period: periodLabel(months))
                      // One month is a part-to-whole question and a donut
                      // answers it at a glance. Several months is a comparison,
                      // which a donut cannot answer at all — nobody can compare
                      // angles across two circles — so the shape changes.
                      else if (months.length <= 1)
                        _CategoryDonutCard(
                          byCategory: byCategory,
                          total: totals.spent,
                          money: money,
                        )
                      else
                        _MonthComparisonCard(
                          entries: entries,
                          months: months,
                          money: money,
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

/// The one number the screen leads with.
class _SpendHeadline extends StatelessWidget {
  const _SpendHeadline({
    required this.spent,
    required this.received,
    required this.count,
    required this.period,
    required this.money,
  });

  final double spent;
  final double received;
  final int count;
  final String period;
  final NumberFormat money;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('$period · Total spent', style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            Text(
              money.format(spent),
              style: theme.textTheme.headlineLarge?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
            ),
            if (received > 0) ...<Widget>[
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Text('Received ', style: theme.textTheme.bodyMedium),
                  Text(
                    money.format(received),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: creditColor(theme),
                    ),
                  ),
                  Text('  ·  Net ', style: theme.textTheme.bodyMedium),
                  Text(
                    money.format(spent - received),
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 4),
            Text(
              '$count transaction${count == 1 ? '' : 's'}',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// A donut over the period's categories, with the ranked amounts beside it.
///
/// The list is not decoration and not merely a legend. A donut is honest about
/// part-to-whole at a glance and useless for comparing two close values, so the
/// exact figures have to be readable somewhere — and that is also what keeps
/// the chart legible for anyone who cannot separate two of the hues.
class _CategoryDonutCard extends StatelessWidget {
  const _CategoryDonutCard({
    required this.byCategory,
    required this.total,
    required this.money,
  });

  final Map<String, double> byCategory;
  final double total;
  final NumberFormat money;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Brightness brightness = theme.brightness;
    final List<CategorySlice> slices = topCategories(byCategory);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Where it went', style: theme.textTheme.titleMedium),
            const SizedBox(height: 16),
            SizedBox(
              height: 180,
              child: PieChart(
                PieChartData(
                  sectionsSpace: 2, // a surface gap, so adjacent arcs separate
                  centerSpaceRadius: 52,
                  sections: <PieChartSectionData>[
                    for (final CategorySlice slice in slices)
                      PieChartSectionData(
                        value: slice.amount,
                        color: categoryColor(slice.name, brightness),
                        radius: 34,
                        showTitle: false,
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            for (final CategorySlice slice in slices)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: categoryColor(slice.name, brightness),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Icon(categoryIcon(slice.name),
                        size: 16, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        slice.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    Text(
                      '${(slice.share * 100).round()}%',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      money.format(slice.amount),
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The same spend, several months at a time: one group per category, one bar
/// per month within it.
///
/// Months are the series here, not categories — the question this chart answers
/// is "did this go up or down", so it is the months that have to be told apart.
class _MonthComparisonCard extends StatelessWidget {
  const _MonthComparisonCard({
    required this.entries,
    required this.months,
    required this.money,
  });

  final List<LedgerEntry> entries;
  final Set<YearMonth> months;
  final NumberFormat money;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Brightness brightness = theme.brightness;

    final Map<YearMonth, Map<String, double>> perMonth =
        spendByCategoryPerMonth(entries);
    final List<YearMonth> axis = comparedMonths(months);
    // The categories worth drawing, ranked over the whole period so the groups
    // are in a stable, meaningful order rather than one month's order.
    final List<CategorySlice> ranked = topCategories(
      spendByCategory(entries),
      limit: 6,
    );
    final List<Color> monthColors = chartHues(brightness);

    double amountFor(YearMonth m, String category) =>
        perMonth[m]?[category] ?? 0;

    // "Other" is a bucket, not a category, so it cannot be looked up per month.
    final List<CategorySlice> groups = ranked
        .where((CategorySlice s) => s.name != kOtherCategory)
        .toList();

    final double maxY = <double>[
      for (final CategorySlice s in groups)
        for (final YearMonth m in axis) amountFor(m, s.name),
      1,
    ].reduce((double a, double b) => a > b ? a : b);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Month by month', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Spend per category, one bar per month.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            // A legend is not optional with more than one series: it is the
            // only thing naming which bar is which month.
            Wrap(
              spacing: 12,
              runSpacing: 6,
              children: <Widget>[
                for (int i = 0; i < axis.length; i++)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: monthColors[i % monthColors.length],
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(axis[i].label, style: theme.textTheme.bodySmall),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 240,
              child: BarChart(
                BarChartData(
                  maxY: maxY * 1.15,
                  alignment: BarChartAlignment.spaceAround,
                  // Hairline horizontal grid only; vertical rules would just be
                  // noise between groups that are already separated by space.
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    getDrawingHorizontalLine: (double v) => FlLine(
                      color: theme.colorScheme.outlineVariant,
                      strokeWidth: 1,
                    ),
                  ),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    leftTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 42,
                        getTitlesWidget: (double value, TitleMeta meta) {
                          final int i = value.toInt();
                          if (i < 0 || i >= groups.length) {
                            return const SizedBox.shrink();
                          }
                          return Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              groups[i].name,
                              maxLines: 2,
                              textAlign: TextAlign.center,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  barTouchData: BarTouchData(
                    touchTooltipData: BarTouchTooltipData(
                      getTooltipItem: (BarChartGroupData group, int groupIndex,
                          BarChartRodData rod, int rodIndex) {
                        return BarTooltipItem(
                          '${axis[rodIndex].label}\n'
                          '${groups[groupIndex].name} ${money.format(rod.toY)}',
                          theme.textTheme.bodySmall ?? const TextStyle(),
                        );
                      },
                    ),
                  ),
                  barGroups: <BarChartGroupData>[
                    for (int g = 0; g < groups.length; g++)
                      BarChartGroupData(
                        x: g,
                        barsSpace: 2,
                        barRods: <BarChartRodData>[
                          for (int i = 0; i < axis.length; i++)
                            BarChartRodData(
                              toY: amountFor(axis[i], groups[g].name),
                              width: 10,
                              color: monthColors[i % monthColors.length],
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(4),
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A period with no spend in it. Says so plainly rather than drawing an empty
/// circle, which would read as a rendering failure.
class _NothingToChart extends StatelessWidget {
  const _NothingToChart({required this.period});

  final String period;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          children: <Widget>[
            Icon(Icons.pie_chart_outline,
                size: 56, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text(
              'Nothing spent in $period',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Pick another month, or add a transaction from the '
              'Transactions tab.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// TRANSACTIONS TAB — the whole ledger: filtered, sorted, and editable in place
// ---------------------------------------------------------------------------

/// Asks before [count] transactions are deleted. False for a dismissed dialog,
/// so a tap outside is a cancel.
///
/// One function for every route to a delete — the swipe on a row and the bulk
/// delete in the selection bar — so the two cannot end up making different
/// promises about what deleting means. It is a real question in both cases: the
/// rows go out of future inbox scans as well as out of the ledger, which is not
/// something a gesture should be able to do on its own.
Future<bool> confirmDeleteTransactions(BuildContext context, int count) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) {
      final ColorScheme scheme = Theme.of(dialogContext).colorScheme;
      return AlertDialog(
        title: Text(count == 1
            ? 'Delete this transaction?'
            : 'Delete $count transactions?'),
        content: Text(
          '${count == 1 ? 'It stays' : 'They stay'} out of future inbox scans, '
          'and can be brought back from Deleted transactions.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Delete'),
          ),
        ],
      );
    },
  );
  return confirmed ?? false;
}

/// The screen over the ledger itself. (The Dashboard tab is the same rows as
/// charts; this is the rows.)
///
/// It renders and nothing more: the shell works out which rows survive the
/// filters and in what order, and owns the marks, so that the app bar — which
/// the shell builds — and this list can never disagree about what "all of them"
/// means.
class TransactionsTab extends StatelessWidget {
  const TransactionsTab({
    super.key,
    required this.entries,
    required this.filters,
    required this.sort,
    required this.monthChoices,
    required this.currentMonth,
    required this.categoryChoices,
    required this.merchantChoices,
    required this.paymentTypeChoices,
    required this.money,
    required this.dateFormat,
    required this.loading,
    required this.ledgerIsEmpty,
    required this.selected,
    required this.onFiltersChanged,
    required this.onSortChanged,
    required this.onRefresh,
    required this.onTap,
    required this.onToggleSelected,
    required this.onDelete,
  });

  /// The rows to show: already filtered, already in order.
  final List<LedgerEntry> entries;

  final LedgerFilters filters;
  final LedgerSort sort;

  /// What each facet can still offer under the others.
  final List<YearMonth> monthChoices;
  final List<ExpenseCategory> categoryChoices;
  final List<String> merchantChoices;
  final List<String> paymentTypeChoices;

  /// The month the app considers "now" — where Clear goes back to, and the
  /// furthest the period stepper will go forward.
  final YearMonth currentMonth;

  final NumberFormat money;
  final DateFormat dateFormat;
  final bool loading;

  /// Whether the ledger itself is empty, as opposed to filtered down to
  /// nothing — the two want different things said about them.
  final bool ledgerIsEmpty;

  /// Ids currently marked. Non-empty means the list is in selection mode.
  final Set<int> selected;

  final ValueChanged<LedgerFilters> onFiltersChanged;
  final ValueChanged<LedgerSort> onSortChanged;
  final Future<void> Function() onRefresh;
  final void Function(ExpenseTxn) onTap;
  final void Function(ExpenseTxn) onToggleSelected;
  final void Function(ExpenseTxn) onDelete;

  /// Three filters and an order, two of which take several values at once, do
  /// not fit as dropdowns side by side — and Material has no multi-select one.
  /// A scrolling row of chips that each open a sheet does fit, and matches how
  /// the rest of the app asks for a choice.
  Widget _chipStrip(BuildContext context) {
    // Offered against the resting state rather than against `isEmpty`: a user
    // who widened to *all* months has an empty filter set and very much wants a
    // way back to this month.
    final bool atRest = filters.isDefaultFor(currentMonth);

    return SizedBox(
      height: 56,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        children: <Widget>[
          // First in the strip, because this is the way out of a filter set that
          // has narrowed the ledger to nothing and it cannot be the thing that
          // needs scrolling to. Behind the four facet chips it was reachable only
          // by scrolling past the very chips that caused the problem.
          //
          // Dead rather than absent when there is nothing to clear, for the same
          // reason the merge screen's app bar keeps its button: a chip that comes
          // and goes reshuffles everything behind it, and this one sits in front
          // of all four. It also has to be visible before it is needed, or
          // nobody learns it is there.
          ActionChip(
            avatar: const Icon(Icons.filter_alt_off_outlined, size: 18),
            label: const Text('Clear all'),
            onPressed: atRest
                ? null
                : () => onFiltersChanged(LedgerFilters.defaults(currentMonth)),
          ),
          const SizedBox(width: 8),
          ActionChip(
            avatar: const Icon(Icons.swap_vert, size: 18),
            // The order is always in force, so the chip names the current one
            // rather than saying "Sort" and leaving it to be guessed at.
            label: Text(sort.label),
            onPressed: () async {
              final LedgerSort? picked = await showModalBottomSheet<LedgerSort>(
                context: context,
                showDragHandle: true,
                builder: (_) => _SortSheet(selected: sort),
              );
              if (picked != null) onSortChanged(picked);
            },
          ),
          const SizedBox(width: 8),
          _FilterChip(
            label: 'Category',
            count: filters.categoryIds.length,
            onPressed: () async {
              final Set<int>? picked = await chooseMany<int>(
                context,
                title: 'Categories',
                options:
                    categoryChoices.map((ExpenseCategory c) => c.id).toList(),
                selected: filters.categoryIds,
                label: (int id) => categoryChoices
                    .firstWhere((ExpenseCategory c) => c.id == id)
                    .name,
                leading: (int id) => Icon(
                  categoryIcon(categoryChoices
                      .firstWhere((ExpenseCategory c) => c.id == id)
                      .name),
                ),
              );
              if (picked != null) {
                onFiltersChanged(filters.copyWith(categoryIds: picked));
              }
            },
          ),
          const SizedBox(width: 8),
          _FilterChip(
            label: 'Merchant',
            count: filters.merchants.length,
            onPressed: () async {
              final Set<String>? picked = await chooseMany<String>(
                context,
                title: 'Merchants',
                options: merchantChoices,
                selected: filters.merchants,
                label: (String m) => m,
              );
              if (picked != null) {
                onFiltersChanged(filters.copyWith(merchants: picked));
              }
            },
          ),
          const SizedBox(width: 8),
          _FilterChip(
            label: filters.paymentType ?? 'Card / account',
            count: filters.paymentType == null ? 0 : 1,
            onPressed: () async {
              final Set<String>? picked = await chooseMany<String>(
                context,
                title: 'Card / account',
                options: paymentTypeChoices,
                selected: <String>{?filters.paymentType},
                label: (String t) => t,
              );
              if (picked == null) return;
              onFiltersChanged(picked.isEmpty
                  ? filters.copyWith(clearPaymentType: true)
                  : filters.copyWith(paymentType: picked.first));
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool selecting = selected.isNotEmpty;

    return Column(
      children: <Widget>[
        // While marking, the filters go. Rows can then only be marked from what
        // is already on screen, which is what lets "Select all" and the delete
        // beside it mean one unambiguous thing. The search box goes with them,
        // for exactly the same reason.
        if (!selecting) ...<Widget>[
          PeriodBar(
            months: filters.months,
            options: monthChoices,
            currentMonth: currentMonth,
            onChanged: (Set<YearMonth> m) =>
                onFiltersChanged(filters.copyWith(months: m)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: _SearchField(
              value: filters.query,
              onChanged: (String q) =>
                  onFiltersChanged(filters.copyWith(query: q)),
            ),
          ),
          _chipStrip(context),
        ],
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: onRefresh,
                  child: entries.isEmpty
                      ? _EmptyLedgerState(
                          reason: emptyReason(filters,
                              ledgerIsEmpty: ledgerIsEmpty),
                          months: filters.months,
                          onClear: () =>
                              onFiltersChanged(LedgerFilters.defaults(currentMonth)),
                          onShowAllMonths: () => onFiltersChanged(
                              filters.copyWith(months: const <YearMonth>{})),
                        )
                      : ListView.builder(
                              // Bottom padding clears the FAB.
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                              itemCount: entries.length + 1,
                              itemBuilder: (context, index) {
                                if (index == 0) {
                                  return _SummaryHeader(
                                    entries: entries,
                                    period: periodLabel(filters.months),
                                    uncategorizedCount: entries
                                        .where((LedgerEntry e) =>
                                            e.txn.isUncategorized)
                                        .length,
                                    money: money,
                                  );
                                }
                                return _ledgerRow(
                                    context, entries[index - 1], selecting);
                              },
                            ),
                ),
        ),
      ],
    );
  }

  Widget _ledgerRow(BuildContext context, LedgerEntry entry, bool selecting) {
    final ExpenseTxn txn = entry.txn;

    // Under a category filter a split shows only the part that matched, but
    // deleting takes the whole transaction. Swipe is withheld from a row that is
    // showing less than it would remove, even with the confirmation behind it:
    // the dialog can say what is going but not what it was part of. The actions
    // sheet prints the full amount at the top and deletes them from there.
    final bool partial = entry.amount != txn.amount;

    return Dismissible(
      key: ValueKey<int>(txn.id),
      // Swipe is also off while marking, so a stray gesture can't delete
      // outside the selection flow.
      direction: selecting || partial
          ? DismissDirection.none
          : DismissDirection.endToStart,
      // Answered before the row animates out — a false springs it back, and
      // `onDismissed` never runs. The gesture is easy to make by accident on a
      // scrolling list, and what it does outlives the snackbar that offers to
      // undo it.
      confirmDismiss: (_) => confirmDeleteTransactions(context, 1),
      onDismissed: (_) => onDelete(txn),
      background: _DismissBackground(),
      child: _TransactionTile(
        txn: txn,
        money: money,
        dateFormat: dateFormat,
        // Under a category filter the row shows what it contributed, not what
        // was charged.
        shownAmount: entry.amount,
        shownLines: entry.lines,
        selected: selected.contains(txn.id),
        selecting: selecting,
        // While marking, a tap toggles rather than opens.
        onTap: selecting ? () => onToggleSelected(txn) : () => onTap(txn),
        onLongPress: () => onToggleSelected(txn),
      ),
    );
  }
}

/// The search box over the ledger, matching notes and merchant names.
///
/// Stateful only because the text has two owners: the shell holds the query in
/// its filters and rebuilds this widget on every keystroke, so a controller
/// rebuilt with it would fight the cursor. It is created once here instead, and
/// [didUpdateWidget] copies in a value that changed somewhere else — the Clear
/// chip is the only thing that does — while leaving ordinary typing alone.
///
/// No debounce: the ledger is already in memory and [applyFilters] runs on
/// every build regardless, so a keystroke costs one pass over a local list.
class _SearchField extends StatefulWidget {
  const _SearchField({required this.value, required this.onChanged});

  final String value;
  final ValueChanged<String> onChanged;

  @override
  State<_SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<_SearchField> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.value);

  @override
  void didUpdateWidget(_SearchField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != _controller.text) {
      _controller.value = TextEditingValue(
        text: widget.value,
        selection: TextSelection.collapsed(offset: widget.value.length),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      textInputAction: TextInputAction.search,
      onChanged: widget.onChanged,
      decoration: InputDecoration(
        isDense: true,
        hintText: 'Search notes or merchants',
        prefixIcon: const Icon(Icons.search),
        // Driven by the shell's value rather than the controller's: this widget
        // repaints when the shell rebuilds, and the shell is what knows the
        // query changed.
        suffixIcon: widget.value.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close),
                tooltip: 'Clear search',
                onPressed: () {
                  _controller.clear();
                  widget.onChanged('');
                },
              ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(24),
        ),
      ),
    );
  }
}

/// Picks one order. Single choice, so tapping a row is the answer — there is
/// nothing for an Apply button to confirm.
class _SortSheet extends StatelessWidget {
  const _SortSheet({required this.selected});

  final LedgerSort selected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
            child: Text('Sort by', style: theme.textTheme.titleLarge),
          ),
          for (final LedgerSort option in LedgerSort.values)
            ListTile(
              title: Text(option.label),
              trailing: option == selected
                  ? Icon(Icons.check, color: theme.colorScheme.primary)
                  : null,
              onTap: () => Navigator.pop(context, option),
            ),
          const SizedBox(height: 12),
        ],
      ),
    );
  }
}

/// A filter's entry point: its name, how many values are picked, and a tap that
/// opens the sheet to change them.
class _FilterChip extends StatelessWidget {
  const _FilterChip({
    required this.label,
    required this.count,
    required this.onPressed,
  });

  final String label;
  final int count;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final bool active = count > 0;
    return FilterChip(
      selected: active,
      showCheckmark: false,
      label: Text(count > 1 ? '$label · $count' : label),
      avatar: active ? null : const Icon(Icons.arrow_drop_down, size: 20),
      onSelected: (_) => onPressed(),
    );
  }
}

/// Ticks any number of [options] and returns the new selection on Apply, or
/// null if it was dismissed.
///
/// Selection is held locally so backing out changes nothing — the filter only
/// moves when Apply says so.
class _MultiSelectSheet<T> extends StatefulWidget {
  const _MultiSelectSheet({
    super.key,
    required this.title,
    required this.options,
    required this.selected,
    required this.label,
    this.leading,
  });

  final String title;
  final List<T> options;
  final Set<T> selected;
  final String Function(T) label;
  final Widget Function(T)? leading;

  @override
  State<_MultiSelectSheet<T>> createState() => _MultiSelectSheetState<T>();
}

class _MultiSelectSheetState<T> extends State<_MultiSelectSheet<T>> {
  late Set<T> _selected = <T>{...widget.selected};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 12, 4),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(widget.title, style: theme.textTheme.titleLarge),
                ),
                if (_selected.isNotEmpty)
                  TextButton(
                    onPressed: () => setState(() => _selected = <T>{}),
                    child: const Text('Clear'),
                  ),
              ],
            ),
          ),
          Flexible(
            child: widget.options.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      'Nothing to choose from under the current filters.',
                      style: theme.textTheme.bodyMedium,
                    ),
                  )
                : ListView.builder(
                    shrinkWrap: true,
                    itemCount: widget.options.length,
                    itemBuilder: (BuildContext context, int index) {
                      final T option = widget.options[index];
                      return CheckboxListTile(
                        value: _selected.contains(option),
                        secondary: widget.leading?.call(option),
                        title: Text(
                          widget.label(option),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        onChanged: (bool? on) => setState(() {
                          if (on ?? false) {
                            _selected.add(option);
                          } else {
                            _selected.remove(option);
                          }
                        }),
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Row(
              children: <Widget>[
                const Spacer(),
                FilledButton(
                  onPressed: () => Navigator.pop(context, _selected),
                  child: const Text('Apply'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// What a row slides away to reveal: the delete it is on its way to.
class _DismissBackground extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      alignment: Alignment.centerRight,
      decoration: BoxDecoration(
        color: theme.colorScheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        Icons.delete_outline,
        color: theme.colorScheme.onErrorContainer,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// TRANSACTION ACTIONS — everything one row can be told to do
// ---------------------------------------------------------------------------

enum TxnAction { categorize, note, split, mergeMerchant, mergeCard, delete }

class TransactionActionsSheet extends StatelessWidget {
  const TransactionActionsSheet({
    super.key,
    required this.txn,
    required this.money,
    required this.dateFormat,
  });

  final ExpenseTxn txn;
  final NumberFormat money;
  final DateFormat dateFormat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        // A scrolling list rather than a `Column`, because the sheet has
        // outgrown a short screen: a header, any note, a chip per split line
        // and six actions is more than a default bottom sheet's height, and a
        // `Column` that does not fit simply clips — silently taking Delete off
        // the bottom rather than saying anything. `shrinkWrap` keeps it as
        // short as its contents whenever they do fit.
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    txn.merchant,
                    style: theme.textTheme.titleLarge,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  txn.isCredit
                      ? '+${money.format(txn.amount)}'
                      : money.format(txn.amount),
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: txn.isCredit ? creditColor(theme) : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${txn.paymentType} · ${dateFormat.format(txn.date)}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: <Widget>[
                for (final TxnSplit line in txn.effectiveSplits)
                  Chip(
                    avatar: Icon(categoryIcon(line.categoryName), size: 18),
                    label: Text(
                      txn.isSplit
                          ? '${line.categoryName} ${money.format(line.amount)}'
                          : line.categoryName,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            // The tile shows the note on one ellipsised line, so this is where
            // a long one is actually read.
            if (txn.hasNote) ...<Widget>[
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    Icons.sticky_note_2_outlined,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      txn.note,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontStyle: FontStyle.italic,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const Divider(height: 28),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.label_outline),
              title: const Text('Change category'),
              onTap: () => Navigator.pop(context, TxnAction.categorize),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.sticky_note_2_outlined),
              title: Text(txn.hasNote ? 'Edit note' : 'Add note'),
              subtitle: const Text('Why this one happened'),
              onTap: () => Navigator.pop(context, TxnAction.note),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.call_split),
              title: Text(txn.isSplit ? 'Edit split' : 'Split'),
              subtitle: const Text('Across several categories'),
              onTap: () => Navigator.pop(context, TxnAction.split),
            ),
            const Divider(height: 28),
            // These two act on the name, not on this transaction — the row is
            // just where a duplicate is usually noticed.
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.merge_type),
              title: const Text('Merge merchant'),
              subtitle: Text(
                txn.merchant,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => Navigator.pop(context, TxnAction.mergeMerchant),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.credit_card),
              title: const Text('Merge card / account'),
              subtitle: Text(
                txn.paymentType,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => Navigator.pop(context, TxnAction.mergeCard),
            ),
            const Divider(height: 28),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.delete_outline, color: theme.colorScheme.error),
              title: Text(
                'Delete',
                style: TextStyle(color: theme.colorScheme.error),
              ),
              subtitle: const Text('Kept out of future scans; restorable'),
              onTap: () => Navigator.pop(context, TxnAction.delete),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// DELETED SECTION — every tombstone, and the way back
// ---------------------------------------------------------------------------

class DeletedScreen extends StatefulWidget {
  const DeletedScreen({
    super.key,
    required this.money,
    required this.dateFormat,
    required this.onChanged,
  });

  final NumberFormat money;
  final DateFormat dateFormat;

  /// Lets the shell underneath reload, so a restored transaction is already in
  /// the ledger by the time this screen is popped.
  final Future<void> Function() onChanged;

  @override
  State<DeletedScreen> createState() => _DeletedScreenState();
}

class _DeletedScreenState extends State<DeletedScreen> {
  final AppDatabase _db = AppDatabase.instance;

  List<DeletedTxn> _deleted = <DeletedTxn>[];
  bool _loading = true;

  /// Marked rows, held by natural key — a tombstone has no id of its own.
  final Set<String> _selected = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await _db.deletedTransactions();
    if (!mounted) return;
    setState(() {
      _deleted = rows;
      _loading = false;
      // Anything restored elsewhere is no longer here to stay marked.
      _selected.retainAll(rows.map((DeletedTxn d) => d.key));
    });
  }

  void _toggle(DeletedTxn row) {
    setState(() {
      if (!_selected.remove(row.key)) _selected.add(row.key);
    });
  }

  void _clearSelection() => setState(_selected.clear);

  Future<void> _restore(List<DeletedTxn> rows) async {
    if (rows.isEmpty) return;
    await _db.restoreTransactions(rows);
    setState(_selected.clear);
    await Future.wait(<Future<void>>[_load(), widget.onChanged()]);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(rows.length == 1
            ? 'Restored ${rows.single.merchant}'
            : 'Restored ${rows.length} transactions'),
      ));
  }

  AppBar _appBar() {
    if (_selected.isEmpty) {
      return AppBar(title: const Text('Deleted transactions'));
    }
    return AppBar(
      leading: IconButton(
        tooltip: 'Cancel',
        onPressed: _clearSelection,
        icon: const Icon(Icons.close),
      ),
      title: Text('${_selected.length} selected'),
      actions: <Widget>[
        IconButton(
          tooltip: 'Select all',
          onPressed: () => setState(() => _selected
            ..clear()
            ..addAll(_deleted.map((DeletedTxn d) => d.key))),
          icon: const Icon(Icons.select_all),
        ),
        IconButton(
          tooltip: 'Restore',
          onPressed: () => _restore(_deleted
              .where((DeletedTxn d) => _selected.contains(d.key))
              .toList()),
          icon: const Icon(Icons.restore),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selecting = _selected.isNotEmpty;

    return PopScope(
      // Back should leave selection mode before it leaves the screen.
      canPop: !selecting,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) _clearSelection();
      },
      child: Scaffold(
        appBar: _appBar(),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _deleted.isEmpty
                ? _DeletedEmptyState()
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                    itemCount: _deleted.length,
                    itemBuilder: (context, index) {
                      final row = _deleted[index];
                      final selected = _selected.contains(row.key);

                      // Laid out by hand rather than with `ListTile`, whose
                      // trailing slot is too short for an amount stacked over a
                      // button.
                      return Card(
                        key: ValueKey<String>(row.key),
                        margin: const EdgeInsets.only(bottom: 8),
                        clipBehavior: Clip.antiAlias,
                        color:
                            selected ? theme.colorScheme.primaryContainer : null,
                        child: InkWell(
                          // Long-press starts marking; once anything is marked,
                          // a plain tap toggles.
                          onTap: selecting ? () => _toggle(row) : null,
                          onLongPress: () => _toggle(row),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                if (selecting) ...<Widget>[
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Icon(
                                      selected
                                          ? Icons.check_circle
                                          : Icons.circle_outlined,
                                      color: selected
                                          ? theme.colorScheme.primary
                                          : theme.colorScheme.outline,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                ],
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(
                                        row.merchant,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w600),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '${row.paymentType} · '
                                        '${widget.dateFormat.format(row.date)}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodySmall,
                                      ),
                                      Text(
                                        row.deletedAt == null
                                            // A tombstone from before v4.
                                            ? '${row.categoryName} · deleted'
                                            : '${row.categoryName} · deleted '
                                                '${widget.dateFormat.format(row.deletedAt!)}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodySmall,
                                      ),
                                      // Two charges of the same amount at the
                                      // same shop are told apart by the note or
                                      // not at all — and this is the screen
                                      // where one of them is chosen to restore.
                                      if (row.note.isNotEmpty)
                                        Text(
                                          row.note,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                            fontStyle: FontStyle.italic,
                                            color: theme
                                                .colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: <Widget>[
                                    Padding(
                                      padding: EdgeInsets.only(
                                          top: selecting ? 2 : 0),
                                      child: Text(
                                        row.isCredit
                                            ? '+${widget.money.format(row.amount)}'
                                            : widget.money.format(row.amount),
                                        style: theme.textTheme.titleSmall
                                            ?.copyWith(
                                          fontWeight: FontWeight.bold,
                                          color: row.isCredit
                                              ? creditColor(theme)
                                              : null,
                                        ),
                                      ),
                                    ),
                                    // The per-row button would be a second,
                                    // conflicting way to act while marking.
                                    if (!selecting)
                                      TextButton.icon(
                                        onPressed: () =>
                                            _restore(<DeletedTxn>[row]),
                                        icon:
                                            const Icon(Icons.restore, size: 18),
                                        label: const Text('Restore'),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}

class _DeletedEmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(32),
      children: <Widget>[
        const SizedBox(height: 100),
        Icon(Icons.delete_outline, size: 64, color: theme.colorScheme.outline),
        const SizedBox(height: 16),
        Text(
          'Nothing deleted',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'Deleting a transaction also keeps it from being imported again by a '
          'later inbox scan. Anything you delete lands here, and restoring it '
          'undoes both.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// The one empty list, saying whichever of the four true things applies.
///
/// One widget rather than several because the four cases differ only in their
/// words and their buttons, and because the choice between them is [emptyReason]
/// — a pure function that can be tested, unlike a nest of ternaries in a build
/// method.
class _EmptyLedgerState extends StatelessWidget {
  const _EmptyLedgerState({
    required this.reason,
    required this.months,
    required this.onClear,
    required this.onShowAllMonths,
  });

  final EmptyReason reason;
  final Set<YearMonth> months;
  final VoidCallback onClear;
  final VoidCallback onShowAllMonths;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final (IconData icon, String title, String? detail) = switch (reason) {
      EmptyReason.ledgerEmpty => (
          Icons.receipt_long_outlined,
          'No transactions yet',
          'Scan your SMS inbox, or paste a bank alert to test the parser.',
        ),
      EmptyReason.search => (
          Icons.search_off,
          'No transactions match this search',
          null,
        ),
      EmptyReason.facets => (
          Icons.filter_alt_off_outlined,
          'No transactions match these filters',
          null,
        ),
      EmptyReason.month => (
          Icons.calendar_month_outlined,
          'Nothing in ${periodLabel(months)} yet',
          'Transactions appear here as your bank texts arrive.',
        ),
    };

    return ListView(
      // A scrollable child keeps pull-to-refresh working on an empty list.
      padding: const EdgeInsets.all(32),
      children: <Widget>[
        SizedBox(height: reason == EmptyReason.ledgerEmpty ? 120 : 100),
        Icon(icon, size: 64, color: theme.colorScheme.outline),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
        if (detail != null) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 20),
        // An empty ledger gets no button: the "Paste an SMS" FAB is already on
        // screen and the toolbar offers the inbox scan. An empty *month* gets
        // "Show all months" rather than "Clear filters", because clearing would
        // reset to the very month that is empty — a button that visibly does
        // nothing reads as a bug.
        if (reason == EmptyReason.month)
          Center(
            child: FilledButton.tonalIcon(
              onPressed: onShowAllMonths,
              icon: const Icon(Icons.event_repeat_outlined),
              label: const Text('Show all months'),
            ),
          )
        else if (reason != EmptyReason.ledgerEmpty)
          Center(
            child: FilledButton.tonalIcon(
              onPressed: onClear,
              icon: const Icon(Icons.clear),
              label: const Text('Clear filters'),
            ),
          ),
      ],
    );
  }
}

class _SummaryHeader extends StatelessWidget {
  const _SummaryHeader({
    required this.entries,
    required this.period,
    required this.uncategorizedCount,
    required this.money,
  });

  final List<LedgerEntry> entries;

  /// What the totals below are the totals *of*. Named on the card rather than
  /// only in the period bar, so a screenshot of it is self-describing.
  final String period;

  final int uncategorizedCount;
  final NumberFormat money;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // The headline totals add the *entry* amount, which under a category filter
    // is only the part that matched — and which for an unfiltered split is the
    // whole charge, since its lines sum to it by construction.
    final totals = periodTotals(entries);
    final double spent = totals.spent;
    final double received = totals.received;

    // Only debits are broken down by category — a refund is not spending.
    final breakdown = spendByCategory(entries).entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('$period · Total spent', style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            Text(
              money.format(spent),
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
            ),
            if (received > 0) ...<Widget>[
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  Text('Received ', style: theme.textTheme.bodyMedium),
                  Text(
                    money.format(received),
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: creditColor(theme),
                    ),
                  ),
                  Text('  ·  Net ', style: theme.textTheme.bodyMedium),
                  Text(
                    money.format(spent - received),
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 4),
            Text(
              '${entries.length} transaction'
              '${entries.length == 1 ? '' : 's'}'
              '${uncategorizedCount > 0 ? ' · $uncategorizedCount need a category' : ''}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final entry in breakdown.take(6))
                  Chip(
                    avatar: Icon(categoryIcon(entry.key), size: 18),
                    label: Text('${entry.key} · ${money.format(entry.value)}'),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// `ColorScheme` has no dependable green role, so money-in gets an explicit
/// colour picked for contrast against the current brightness.
Color creditColor(ThemeData theme) => theme.brightness == Brightness.dark
    ? Colors.greenAccent.shade200
    : Colors.green.shade800;

class _TransactionTile extends StatelessWidget {
  const _TransactionTile({
    required this.txn,
    required this.money,
    required this.dateFormat,
    this.shownAmount,
    this.shownLines,
    this.onTap,
    this.onLongPress,
    this.selected = false,
    this.selecting = false,
  });

  final ExpenseTxn txn;
  final NumberFormat money;
  final DateFormat dateFormat;

  /// What this row contributed to the view it is being shown in. Null means the
  /// whole transaction. Under a category filter a split contributes only its
  /// matching lines, and printing the full charge beside a total that counted
  /// less than that would simply look wrong.
  final double? shownAmount;

  /// The lines behind [shownAmount]. Null means all of them.
  final List<TxnSplit>? shownLines;

  /// Null where the row is not interactive — `ListTile` renders itself
  /// non-interactive when there is nothing to tap.
  final VoidCallback? onTap;

  /// Starts (or extends) a selection on the Expenses tab. Null elsewhere.
  final VoidCallback? onLongPress;

  /// Marked as part of a selection.
  final bool selected;

  /// The list is in selection mode, so a tap marks rather than categorises.
  final bool selecting;

  /// The pill's text. A split names its first line and counts the rest —
  /// "Grocery +2" — since three full names would not fit and the sheet shows
  /// them all anyway.
  String get _categoryLabel {
    final List<TxnSplit> lines = shownLines ?? txn.effectiveSplits;
    if (lines.length <= 1) {
      return lines.isEmpty ? txn.categoryName : lines.first.categoryName;
    }
    return '${lines.first.categoryName} +${lines.length - 1}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final needsCategory = txn.isUncategorized;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      color: selected ? theme.colorScheme.primaryContainer : null,
      child: ListTile(
        onTap: onTap,
        onLongPress: onLongPress,
        selected: selected,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        leading: selected
            ? CircleAvatar(
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: theme.colorScheme.onPrimary,
                child: const Icon(Icons.check),
              )
            : CircleAvatar(
                backgroundColor: needsCategory
                    ? theme.colorScheme.errorContainer
                    : theme.colorScheme.secondaryContainer,
                foregroundColor: needsCategory
                    ? theme.colorScheme.onErrorContainer
                    : theme.colorScheme.onSecondaryContainer,
                child: Icon(
                  txn.isCredit
                      ? Icons.south_west
                      : categoryIcon(txn.categoryName),
                ),
              ),
        title: Text(
          txn.merchant,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const SizedBox(height: 2),
            Text(
              '${txn.paymentType} · ${dateFormat.format(txn.date)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    color: needsCategory
                        ? theme.colorScheme.errorContainer
                        : theme.colorScheme.surfaceContainerHighest,
                  ),
                  child: Text(
                    !needsCategory
                        ? _categoryLabel
                        // Only promise what a tap will actually do: nothing on
                        // a read-only list, and marking while selecting.
                        : onTap == null || selecting
                            ? kUncategorized
                            : 'Tap to categorize or split',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: needsCategory
                          ? theme.colorScheme.onErrorContainer
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
                // Sits beside the category rather than on a line of its own, so
                // a note costs the row no height and an unnoted row looks
                // exactly as it did. `Flexible`, not `Expanded`, because this
                // Row is `MainAxisSize.min` — and it is what keeps a long note
                // ellipsising instead of shouldering the amount off the tile.
                if (txn.hasNote) ...<Widget>[
                  const SizedBox(width: 6),
                  Icon(
                    Icons.sticky_note_2_outlined,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 3),
                  Flexible(
                    child: Text(
                      txn.note,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontStyle: FontStyle.italic,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
        trailing: Text(
          txn.isCredit
              ? '+${money.format(shownAmount ?? txn.amount)}'
              : money.format(shownAmount ?? txn.amount),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: txn.isCredit ? creditColor(theme) : null,
          ),
        ),
      ),
    );
  }
}

/// Bottom sheet that picks (or creates) the category for a merchant.
/// One editable row of the split screen. The controller lives here rather than
/// in a list beside the data so that deleting a row cannot leave the two out of
/// step.
class _SplitRow {
  _SplitRow({this.category, double? amount})
      : controller = TextEditingController(
          text: amount == null ? '' : _plain(amount),
        );

  /// Two decimals, no grouping separators and no symbol — this is a text field
  /// being typed into, not a figure being displayed.
  static String _plain(double v) => v.toStringAsFixed(2);

  ExpenseCategory? category;
  final TextEditingController controller;

  double get amount => double.tryParse(controller.text.trim()) ?? 0;

  set amount(double v) => controller.text = _plain(v);

  void dispose() => controller.dispose();
}

/// Splits one transaction across several categories.
///
/// A single Amazon charge covers groceries, snacks and shopping, but the bank
/// only ever says "₹2,000". Tagging the whole amount three times would count it
/// three times over; splitting it into lines that sum to the charge keeps every
/// total honest.
///
/// The last row always carries whatever is left over, so filling in the rows
/// above is enough — type 1,200 against a ₹2,000 charge and the second row
/// becomes 800 on its own.
class SplitScreen extends StatefulWidget {
  const SplitScreen({
    super.key,
    required this.txn,
    required this.categories,
    required this.money,
  });

  final ExpenseTxn txn;
  final List<ExpenseCategory> categories;
  final NumberFormat money;

  @override
  State<SplitScreen> createState() => _SplitScreenState();
}

class _SplitScreenState extends State<SplitScreen> {
  late List<_SplitRow> _rows;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.txn.isSplit) {
      _rows = widget.txn.splits
          .map((TxnSplit s) => _SplitRow(
                category: _categoryById(s.categoryId),
                amount: s.amount,
              ))
          .toList();
    } else {
      // Two rows to start: one to fill in, and one already holding the whole
      // charge as the balance, so the arithmetic is visible before anything is
      // typed.
      _rows = <_SplitRow>[
        _SplitRow(),
        _SplitRow(amount: widget.txn.amount),
      ];
    }
  }

  @override
  void dispose() {
    for (final _SplitRow row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  ExpenseCategory? _categoryById(int id) => widget.categories
      .where((ExpenseCategory c) => c.id == id)
      .firstOrNull;

  List<double> get _amounts =>
      _rows.map((_SplitRow r) => r.amount).toList();

  /// Rewrites the last row to the balance. Called after any edit to a row above
  /// it — editing the last row itself is left alone, so it can be corrected by
  /// hand even if that leaves the split unbalanced.
  void _rebalance({required int editedIndex}) {
    if (editedIndex == _rows.length - 1) {
      setState(() {});
      return;
    }
    final List<double> next = withRemainderInLast(_amounts, widget.txn.amount);
    setState(() => _rows.last.amount = next.last);
  }

  Future<void> _pickCategoryFor(_SplitRow row) async {
    final CategoryChoice? chosen = await showModalBottomSheet<CategoryChoice>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => CategoryPickerSheet(
        merchant: widget.txn.merchant,
        categories: widget.categories,
        selectedId: row.category?.id,
        title: 'Category for this line',
      ),
    );
    if (chosen == null) return;
    setState(() => row.category = chosen.category);
  }

  void _addRow() => setState(() {
        // The new row takes the balance, which means the one that was holding
        // it keeps whatever was typed there.
        final double remainder = unallocated(_amounts, widget.txn.amount);
        _rows.add(_SplitRow(amount: remainder > 0 ? remainder : 0));
      });

  void _removeRow(int index) => setState(() {
        _rows.removeAt(index).dispose();
        if (_rows.isNotEmpty) {
          _rows.last.amount =
              withRemainderInLast(_amounts, widget.txn.amount).last;
        }
      });

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);

    // The last line absorbs the rounding drift, so what is stored sums to the
    // charge exactly rather than to within a tolerance of it.
    final List<double> exact =
        withRemainderInLast(_amounts, widget.txn.amount);
    final List<TxnSplit> lines = <TxnSplit>[
      for (var i = 0; i < _rows.length; i++)
        TxnSplit(
          categoryId: _rows[i].category!.id,
          categoryName: _rows[i].category!.name,
          amount: exact[i],
        ),
    ];

    await AppDatabase.instance.saveSplits(widget.txn, lines);
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  Future<void> _removeSplit() async {
    setState(() => _saving = true);
    await AppDatabase.instance.clearSplits(widget.txn.id);
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final double left = unallocated(_amounts, widget.txn.amount);
    final bool balanced = isBalanced(_amounts, widget.txn.amount);
    final bool complete =
        _rows.isNotEmpty && _rows.every((_SplitRow r) => r.category != null);
    final bool positive = _rows.every((_SplitRow r) => r.amount > 0);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Split'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    widget.txn.merchant,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                Text(
                  widget.money.format(widget.txn.amount),
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        itemCount: _rows.length + 1,
        itemBuilder: (BuildContext context, int index) {
          if (index == _rows.length) {
            return Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _addRow,
                icon: const Icon(Icons.add),
                label: const Text('Add row'),
              ),
            );
          }
          final _SplitRow row = _rows[index];
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  flex: 3,
                  child: OutlinedButton(
                    onPressed: () => _pickCategoryFor(row),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          categoryIcon(row.category?.name ?? ''),
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            row.category?.name ?? 'Choose category',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: row.category == null
                                ? TextStyle(color: theme.colorScheme.error)
                                : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: row.controller,
                    textAlign: TextAlign.end,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      prefixText: '₹',
                    ),
                    onChanged: (_) => _rebalance(editedIndex: index),
                  ),
                ),
                IconButton(
                  tooltip: 'Remove row',
                  // Below two rows there is nothing left to split.
                  onPressed:
                      _rows.length > 2 ? () => _removeRow(index) : null,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                balanced
                    ? 'Allocated ${widget.money.format(widget.txn.amount)} '
                        'of ${widget.money.format(widget.txn.amount)}'
                    : left > 0
                        ? '${widget.money.format(left)} unallocated'
                        : '${widget.money.format(left.abs())} over',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: balanced
                      ? theme.colorScheme.primary
                      : theme.colorScheme.error,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (!complete)
                Text(
                  'Every row needs a category.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  if (widget.txn.isSplit)
                    TextButton(
                      onPressed: _saving ? null : _removeSplit,
                      child: const Text('Remove split'),
                    ),
                  const Spacer(),
                  FilledButton(
                    onPressed:
                        balanced && complete && positive && !_saving
                            ? _save
                            : null,
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// What came back from [CategoryPickerSheet]: the category, and whether the
/// user also asked for it to become the merchant's default.
///
/// The two are separate because picking a category is now a statement about
/// *this transaction* — making it the merchant's rule as well is a second,
/// deliberate act.
class CategoryChoice {
  const CategoryChoice({required this.category, this.makeDefault = false});

  final ExpenseCategory category;
  final bool makeDefault;
}

/// Picks a category, and — where the caller asks for it — offers to make that
/// pick the merchant's default too.
///
/// Used in three places: correcting one transaction, filling a row of a split,
/// and setting a merchant's default outright. [showMakeDefault] and
/// [alwaysAskLabel] are what separate them.
class CategoryPickerSheet extends StatefulWidget {
  const CategoryPickerSheet({
    super.key,
    required this.merchant,
    required this.categories,
    this.selectedId,
    this.title = 'Categorize',
    this.subtitle,
    this.showMakeDefault = false,
    this.alwaysAskLabel,
  });

  final String merchant;
  final List<ExpenseCategory> categories;
  final int? selectedId;
  final String title;
  final String? subtitle;

  /// Shows the "also make this the default" checkbox. Off for a split row,
  /// where the pick describes one line of one transaction and nothing more.
  final bool showMakeDefault;

  /// When set, an entry with this label appears first and returns the
  /// Uncategorized category — how "always ask me" is chosen and stored.
  final String? alwaysAskLabel;

  @override
  State<CategoryPickerSheet> createState() => _CategoryPickerSheetState();
}

class _CategoryPickerSheetState extends State<CategoryPickerSheet> {
  final TextEditingController _newCategory = TextEditingController();
  bool _creating = false;
  bool _makeDefault = false;

  @override
  void dispose() {
    _newCategory.dispose();
    super.dispose();
  }

  void _choose(ExpenseCategory category) => Navigator.pop(
        context,
        CategoryChoice(category: category, makeDefault: _makeDefault),
      );

  Future<void> _createAndSelect() async {
    final name = _newCategory.text.trim();
    if (name.isEmpty || _creating) return;
    setState(() => _creating = true);
    final category = await AppDatabase.instance.addCategory(name);
    if (!mounted) return;
    _choose(category);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ExpenseCategory? uncategorized = widget.categories
        .where((ExpenseCategory c) => c.name == kUncategorized)
        .firstOrNull;

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(widget.title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              widget.merchant,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.primary),
            ),
            if (widget.subtitle != null) ...<Widget>[
              const SizedBox(height: 4),
              Text(widget.subtitle!, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 16),
            if (widget.alwaysAskLabel != null && uncategorized != null) ...[
              ActionChip(
                avatar: const Icon(Icons.help_outline, size: 18),
                label: Text(widget.alwaysAskLabel!),
                onPressed: () => _choose(uncategorized),
              ),
              const SizedBox(height: 12),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final category in widget.categories)
                  // Uncategorized is not a category anyone means to pick; where
                  // it is meaningful it is offered above, in the words that
                  // actually describe what it does.
                  if (category.name != kUncategorized)
                    ChoiceChip(
                      avatar: Icon(categoryIcon(category.name), size: 18),
                      label: Text(category.name),
                      selected: category.id == widget.selectedId,
                      onSelected: (_) => _choose(category),
                    ),
              ],
            ),
            if (widget.showMakeDefault) ...<Widget>[
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
                value: _makeDefault,
                onChanged: (bool? v) =>
                    setState(() => _makeDefault = v ?? false),
                title: const Text('Also make this the default'),
                subtitle: Text(
                  'Future transactions from ${widget.merchant} will use it.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
            const Divider(height: 32),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _newCategory,
                    textCapitalization: TextCapitalization.words,
                    onSubmitted: (_) => _createAndSelect(),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      labelText: 'New category',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: _creating ? null : _createAndSelect,
                  child: const Text('Add'),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

IconData categoryIcon(String category) {
  switch (category.toLowerCase()) {
    case 'grocery':
      return Icons.local_grocery_store_outlined;
    case 'food':
      return Icons.restaurant_outlined;
    case 'fuel':
      return Icons.local_gas_station_outlined;
    case 'shopping':
      return Icons.shopping_bag_outlined;
    case 'bills & utilities':
      return Icons.receipt_outlined;
    case 'travel':
      return Icons.flight_takeoff_outlined;
    case 'entertainment':
      return Icons.movie_outlined;
    case 'health':
      return Icons.medical_services_outlined;
    case 'uncategorized':
      return Icons.help_outline;
    default:
      return Icons.label_outline;
  }
}

/// The eight categorical chart colours, light and dark.
///
/// A validated set rather than a pretty one: the order is the colour-blind
/// safety mechanism, and the dark row is the same eight hues *re-stepped* for a
/// dark surface — not the light row lightened programmatically, which is how
/// palettes lose their separation.
const List<Color> _chartHuesLight = <Color>[
  Color(0xFF2A78D6), // blue
  Color(0xFFEB6834), // orange
  Color(0xFF1BAF7A), // aqua
  Color(0xFFEDA100), // yellow
  Color(0xFFE87BA4), // magenta
  Color(0xFF008300), // green
  Color(0xFF4A3AA7), // violet
  Color(0xFFE34948), // red
];

const List<Color> _chartHuesDark = <Color>[
  Color(0xFF3987E5),
  Color(0xFFD95926),
  Color(0xFF199E70),
  Color(0xFFC98500),
  Color(0xFFD55181),
  Color(0xFF008300),
  Color(0xFF9085E9),
  Color(0xFFE66767),
];

/// The hues for [brightness]. The two lists are separate palettes rather than
/// one lightened programmatically, so callers ask for a brightness and never
/// have to know which list answered.
List<Color> chartHues(Brightness brightness) =>
    brightness == Brightness.dark ? _chartHuesDark : _chartHuesLight;

/// The seeded categories' fixed slots. Everything else hashes its name.
const Map<String, int> _seededCategorySlots = <String, int>{
  'grocery': 0,
  'food': 1,
  'fuel': 2,
  'shopping': 3,
  'bills & utilities': 4,
  'travel': 5,
  'entertainment': 6,
  'health': 7,
};

/// A stable colour for [category], in the given [brightness].
///
/// **Assigned from the name, never from the rank.** This is the whole point:
/// were slots handed out by position in the sorted-by-spend list, Food would be
/// blue in a month it led and orange in a month it did not, and the eye would
/// read a colour change as a change in the data. A category keeps its colour
/// across every month and every chart on the screen.
///
/// [kOtherCategory] and Uncategorized are deliberately grey — they are not a
/// category anyone spent money "on", and giving them a hue would let the tail
/// of the breakdown compete with the real answers.
Color categoryColor(String category, Brightness brightness) {
  final List<Color> hues = chartHues(brightness);
  final String key = category.toLowerCase();
  if (key == kOtherCategory.toLowerCase() ||
      key == kUncategorized.toLowerCase()) {
    return brightness == Brightness.dark
        ? const Color(0xFF898781)
        : const Color(0xFFC3C2B7);
  }
  final int? seeded = _seededCategorySlots[key];
  if (seeded != null) return hues[seeded];
  // `hashCode` on a String is stable within a run but not guaranteed across
  // them, so spell the hash out — a category must not change colour when the
  // app restarts.
  var hash = 0;
  for (final int unit in key.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return hues[hash % hues.length];
}

// ---------------------------------------------------------------------------
// MERGING DUPLICATE NAMES
// ---------------------------------------------------------------------------

/// Folds several labels for one real card, account or merchant into one name.
///
/// The banks are not consistent — the same account arrives as `BANK A/c
/// XX0444`, `HDFC Bank A/C *0444` and `HDFC Bank A/c XX0444` depending on which
/// template the alert matched — so the filter offers three choices where there
/// is one account, and the totals split across them.
///
/// Nothing here rewrites a transaction. A merge is a standing rule kept in
/// `name_aliases` and applied when rows are read, which is what lets a future
/// alert in the old format fold in by itself, and what makes [_separate]
/// possible at all.
class MergeNamesScreen extends StatefulWidget {
  const MergeNamesScreen({
    super.key,
    required this.kind,
    this.preselect,
    this.onChanged,
  });

  final NameKind kind;

  /// Ticked on arrival — set when this was opened from a transaction, so the
  /// name the user was looking at is already in the selection.
  final String? preselect;

  /// Reloads whoever pushed this. Null from Settings, where the shell already
  /// reloads on leaving the tab.
  final Future<void> Function()? onChanged;

  @override
  State<MergeNamesScreen> createState() => _MergeNamesScreenState();
}

class _MergeNamesScreenState extends State<MergeNamesScreen> {
  final AppDatabase _db = AppDatabase.instance;

  bool _loading = true;
  NameAliases _aliases = NameAliases.empty;

  /// Current name → how many transactions are under it.
  Map<String, int> _counts = <String, int>{};

  /// Current name → the spellings actually stored beneath it. Read from the
  /// ledger rather than from the alias table, which cannot tell two labels
  /// differing only in case apart.
  Map<String, Set<String>> _labels = <String, Set<String>>{};

  final Set<String> _selected = <String>{};

  @override
  void initState() {
    super.initState();
    final String? preselect = widget.preselect;
    if (preselect != null) _selected.add(preselect);
    _load();
  }

  String _nameOf(ExpenseTxn t) =>
      widget.kind == NameKind.merchant ? t.merchant : t.paymentType;

  String _rawOf(ExpenseTxn t) =>
      widget.kind == NameKind.merchant ? t.rawMerchant : t.rawPaymentType;

  Future<void> _load() async {
    final results = await Future.wait(<Future<Object>>[
      _db.transactions(),
      _db.aliases(),
    ]);
    if (!mounted) return;

    final counts = <String, int>{};
    final labels = <String, Set<String>>{};
    for (final ExpenseTxn t in results[0] as List<ExpenseTxn>) {
      final String name = _nameOf(t);
      counts[name] = (counts[name] ?? 0) + 1;
      (labels[name] ??= <String>{}).add(_rawOf(t));
    }

    setState(() {
      _aliases = results[1] as NameAliases;
      _counts = counts;
      _labels = labels;
      _loading = false;
      // A name can stop existing while this screen is open — its last
      // transaction deleted, or it was folded into something else.
      _selected.retainAll(counts.keys);
    });
  }

  void _toggle(String name) {
    setState(() {
      if (!_selected.remove(name)) _selected.add(name);
    });
  }

  void _clearSelection() => setState(_selected.clear);

  /// Writes [rows] as the whole alias set, reloads, and offers to put back
  /// whatever was there before.
  Future<void> _apply(Map<String, String> rows, String message) async {
    final Map<String, String> before = _aliases.rowsFor(widget.kind);
    await _db.setAliases(widget.kind, rows);
    setState(_selected.clear);
    await Future.wait(<Future<void>>[
      _load(),
      if (widget.onChanged != null) widget.onChanged!(),
    ]);
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            await _db.setAliases(widget.kind, before);
            await Future.wait(<Future<void>>[
              _load(),
              if (widget.onChanged != null) widget.onChanged!(),
            ]);
          },
        ),
      ));
  }

  Future<void> _mergeSelected() async {
    // Most-used first, so the sheet can offer the winning spelling as the name.
    final List<String> members = _selected.toList()
      ..sort((String a, String b) {
        final int byCount = (_counts[b] ?? 0).compareTo(_counts[a] ?? 0);
        return byCount != 0 ? byCount : a.compareTo(b);
      });
    if (members.length < 2) return;

    final String? name = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _MergeNameSheet(
        kind: widget.kind,
        members: members,
        counts: _counts,
      ),
    );
    if (!mounted || name == null || name.trim().isEmpty) return;

    final int moved =
        members.fold<int>(0, (int sum, String m) => sum + (_counts[m] ?? 0));
    await _apply(
      mergePlan(_aliases.rowsFor(widget.kind), members.toSet(), name.trim()),
      'Merged ${members.length} labels · $moved '
      'transaction${moved == 1 ? '' : 's'}',
    );
  }

  Future<void> _mergeSuggested(List<String> group) async {
    setState(() {
      _selected
        ..clear()
        ..addAll(group);
    });
    await _mergeSelected();
  }

  Future<void> _separate(String canonical) async {
    final Map<String, String> rows =
        Map<String, String>.of(_aliases.rowsFor(widget.kind))
          ..removeWhere((_, String c) => c == canonical);
    await _apply(rows, 'Separated $canonical');
  }

  AppBar _appBar() {
    if (_selected.isEmpty) {
      return AppBar(title: Text('Merge ${widget.kind.plural}'));
    }
    return AppBar(
      leading: IconButton(
        tooltip: 'Cancel',
        onPressed: _clearSelection,
        icon: const Icon(Icons.close),
      ),
      title: Text('${_selected.length} selected'),
      actions: <Widget>[
        IconButton(
          tooltip: 'Merge',
          // One name is not a merge. Left visible but dead so the bar does not
          // reshuffle as the second one is ticked.
          onPressed: _selected.length < 2 ? null : _mergeSelected,
          icon: const Icon(Icons.merge_type),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final List<String> names = _counts.keys.toList()..sort();
    final List<String> merged = _aliases
        .mergedNames(widget.kind)
        // A merge whose transactions have all been deleted is still a rule
        // worth being able to drop, so it stays listed.
        .toList();
    final List<List<String>> suggestions =
        suggestGroups(names, widget.kind).where((List<String> group) {
      // Never suggest what is already one name.
      return group.length > 1;
    }).toList();

    return PopScope(
      canPop: _selected.isEmpty,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) _clearSelection();
      },
      child: Scaffold(
        appBar: _appBar(),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : names.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        'Nothing to merge yet — no transactions have been '
                        'recorded.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.only(bottom: 24),
                    children: <Widget>[
                      if (merged.isNotEmpty) ...<Widget>[
                        SettingsHeader('Merged'),
                        for (final String canonical in merged)
                          _MergedTile(
                            canonical: canonical,
                            labels: _labels[canonical] ?? <String>{},
                            onSeparate: () => _separate(canonical),
                          ),
                        const Divider(height: 32),
                      ],
                      if (suggestions.isNotEmpty) ...<Widget>[
                        SettingsHeader('Looks like duplicates'),
                        for (final List<String> group in suggestions)
                          _SuggestionCard(
                            group: group,
                            counts: _counts,
                            onMerge: () => _mergeSuggested(group),
                          ),
                        const Divider(height: 32),
                      ],
                      SettingsHeader('All ${widget.kind.plural}'),
                      for (final String name in names)
                        _NameTile(
                          name: name,
                          count: _counts[name] ?? 0,
                          selected: _selected.contains(name),
                          selecting: _selected.isNotEmpty,
                          onTap: () => _toggle(name),
                        ),
                    ],
                  ),
      ),
    );
  }
}

/// One name already standing for several, and the way to undo that.
class _MergedTile extends StatelessWidget {
  const _MergedTile({
    required this.canonical,
    required this.labels,
    required this.onSeparate,
  });

  final String canonical;
  final Set<String> labels;
  final VoidCallback onSeparate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final List<String> sorted = labels.toList()..sort();

    return ListTile(
      leading: const Icon(Icons.merge_type),
      title: Text(canonical),
      subtitle: Text(
        sorted.isEmpty
            ? 'No transactions under it right now'
            : 'Covers ${sorted.join(' · ')}',
        style: theme.textTheme.bodySmall,
      ),
      isThreeLine: sorted.length > 1,
      trailing: TextButton(
        onPressed: onSeparate,
        child: const Text('Separate'),
      ),
    );
  }
}

/// A group the app thinks is one thing under several labels. Shown already
/// ticked, but merged only when the button is pressed — the heuristics can be
/// wrong, and two cards really can end in the same four digits.
class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({
    required this.group,
    required this.counts,
    required this.onMerge,
  });

  final List<String> group;
  final Map<String, int> counts;
  final VoidCallback onMerge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (final String name in group)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.check_circle,
                        size: 18, color: theme.colorScheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                    Text('${counts[name] ?? 0}',
                        style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                onPressed: onMerge,
                child: Text('Merge these ${group.length}'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One current name, tickable.
class _NameTile extends StatelessWidget {
  const _NameTile({
    required this.name,
    required this.count,
    required this.selected,
    required this.selecting,
    required this.onTap,
  });

  final String name;
  final int count;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      selected: selected,
      selectedTileColor: theme.colorScheme.primaryContainer,
      leading: Icon(
        selected ? Icons.check_circle : Icons.circle_outlined,
        color: selected ? theme.colorScheme.primary : theme.colorScheme.outline,
      ),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('$count transaction${count == 1 ? '' : 's'}'),
      onTap: onTap,
    );
  }
}

/// Names the result of a merge.
///
/// This sheet is the confirmation — typing a name and pressing Merge is a
/// deliberate enough act that a dialog after it would only be in the way, and
/// the snackbar behind it carries Undo.
class _MergeNameSheet extends StatefulWidget {
  const _MergeNameSheet({
    required this.kind,
    required this.members,
    required this.counts,
  });

  final NameKind kind;

  /// Most-used first — [_MergeNamesScreenState._mergeSelected] sorts them, and
  /// the first is offered as the name.
  final List<String> members;
  final Map<String, int> counts;

  @override
  State<_MergeNameSheet> createState() => _MergeNameSheetState();
}

class _MergeNameSheetState extends State<_MergeNameSheet> {
  late final TextEditingController _name =
      TextEditingController(text: widget.members.first);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final String name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final int moved = widget.members
        .fold<int>(0, (int sum, String m) => sum + (widget.counts[m] ?? 0));

    return Padding(
      // Lifts the field clear of the keyboard.
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Merge ${widget.members.length} ${widget.kind.plural}',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              '$moved transaction${moved == 1 ? '' : 's'} will be filed under '
              'one name. Nothing is rewritten — this can be undone.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            for (final String member in widget.members)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('· $member',
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
            const Divider(height: 28),
            TextField(
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                labelText: 'Call them',
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                const Spacer(),
                FilledButton(onPressed: _submit, child: const Text('Merge')),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// SETTINGS
// ---------------------------------------------------------------------------

/// Every merchant the ledger has seen, and what each one is filed under by
/// default.
///
/// Three states, and the difference between the first two is the point of the
/// screen: a merchant with no default at all has simply never been set up,
/// while one set to "always ask me" has been looked at and deliberately left
/// uncategorised — because its charges cover several categories at once and
/// always need splitting by hand.
class MerchantDefaultsScreen extends StatefulWidget {
  const MerchantDefaultsScreen({super.key});

  @override
  State<MerchantDefaultsScreen> createState() => _MerchantDefaultsScreenState();
}

class _MerchantDefaultsScreenState extends State<MerchantDefaultsScreen> {
  final NumberFormat _money =
      NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 0);

  List<MerchantSummary> _merchants = <MerchantSummary>[];
  List<ExpenseCategory> _categories = <ExpenseCategory>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait(<Future<Object>>[
      AppDatabase.instance.merchants(),
      AppDatabase.instance.categories(),
    ]);
    if (!mounted) return;
    setState(() {
      _merchants = results[0] as List<MerchantSummary>;
      _categories = results[1] as List<ExpenseCategory>;
      _loading = false;
    });
  }

  Future<void> _setDefault(MerchantSummary merchant) async {
    final CategoryChoice? chosen = await showModalBottomSheet<CategoryChoice>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => CategoryPickerSheet(
        merchant: merchant.merchant,
        categories: _categories,
        selectedId: merchant.defaultCategoryId,
        title: 'Default category',
        subtitle: 'Used for transactions imported from now on.',
        alwaysAskLabel: 'Always ask me',
      ),
    );
    if (chosen == null || !mounted) return;

    final int uncategorized = await AppDatabase.instance.uncategorizedId();
    var backfill = false;

    // "Always ask me" is never applied backwards — doing so would wipe out
    // exactly the per-transaction work it exists to protect.
    if (chosen.category.id != uncategorized) {
      final int n = await AppDatabase.instance.backfillableCount(
        merchant: merchant.merchant,
        categoryId: chosen.category.id,
      );
      if (!mounted) return;
      if (n > 0) {
        backfill = await showDialog<bool>(
              context: context,
              builder: (BuildContext context) => AlertDialog(
                title: const Text('Apply to past transactions?'),
                content: Text(
                  '$n past transaction${n == 1 ? '' : 's'} from '
                  '${merchant.merchant} would move to '
                  '${chosen.category.name}. Transactions you have split are '
                  'left alone.',
                ),
                actions: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Future only'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: Text('Apply to $n'),
                  ),
                ],
              ),
            ) ??
            false;
      }
    }
    if (!mounted) return;

    final int updated = await AppDatabase.instance.setMerchantDefault(
      merchant: merchant.merchant,
      categoryId: chosen.category.id,
      backfill: backfill,
    );
    await _load();
    if (!mounted) return;
    final String label = chosen.category.id == uncategorized
        ? 'Always ask me'
        : chosen.category.name;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(
          '${merchant.merchant} → $label'
          '${updated > 0 ? ' ($updated updated)' : ''}',
        ),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Merchants & defaults')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _merchants.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      'No merchants yet. They appear here as transactions '
                      'arrive.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: _merchants.length,
                  itemBuilder: (BuildContext context, int index) {
                    final MerchantSummary m = _merchants[index];
                    final bool alwaysAsk =
                        m.defaultCategoryName == kUncategorized;
                    final bool unset = m.defaultCategoryId == null;

                    return ListTile(
                      leading: CircleAvatar(
                        backgroundColor: unset
                            ? theme.colorScheme.surfaceContainerHighest
                            : theme.colorScheme.primaryContainer,
                        foregroundColor: unset
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.onPrimaryContainer,
                        child: Icon(
                          alwaysAsk
                              ? Icons.help_outline
                              : unset
                                  ? Icons.help_outline
                                  : categoryIcon(m.defaultCategoryName!),
                          size: 20,
                        ),
                      ),
                      title: Text(
                        m.merchant,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${m.txnCount} transaction'
                        '${m.txnCount == 1 ? '' : 's'} · '
                        '${_money.format(m.totalSpent)}',
                      ),
                      trailing: Text(
                        unset
                            ? 'Not set'
                            : alwaysAsk
                                ? 'Always ask me'
                                : m.defaultCategoryName!,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: unset
                              ? theme.colorScheme.onSurfaceVariant
                              : theme.colorScheme.primary,
                        ),
                      ),
                      onTap: () => _setDefault(m),
                    );
                  },
                ),
    );
  }
}

/// Every category, what is filed under it, and the two ways to change the list:
/// add one, or be rid of one.
///
/// Deleting is never destructive of transactions: the delete has to name
/// somewhere for its rows to go, they move there whole, and the snackbar behind
/// it puts every one of them back. Uncategorized is not on offer — it is where
/// everything else falls back to, including the rows a delete moves when the
/// user picks nothing better.
///
/// Adding is here as well as in the picker on a transaction because the two
/// answer different questions. The picker adds a category because *this* charge
/// needs one and there is a keyboard already open; this screen is where someone
/// sets up the handful they intend to use before any of it arrives.
class CategoriesScreen extends StatefulWidget {
  const CategoriesScreen({super.key});

  @override
  State<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends State<CategoriesScreen> {
  final AppDatabase _db = AppDatabase.instance;

  List<CategoryUsage> _usage = const <CategoryUsage>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final List<CategoryUsage> usage = await _db.categoryUsage();
    if (!mounted) return;
    setState(() {
      _usage = usage;
      _loading = false;
    });
  }

  static bool _isFallback(CategoryUsage usage) =>
      usage.category.name == kUncategorized;

  Future<void> _add() async {
    final String? name = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _NewCategorySheet(
        taken: <String>[
          for (final CategoryUsage usage in _usage) usage.category.name,
        ],
      ),
    );
    if (name == null || !mounted) return;

    final ExpenseCategory added = await _db.addCategory(name);
    await _load();
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Added ${added.name}')));
  }

  Future<void> _delete(CategoryUsage usage) async {
    final List<ExpenseCategory> destinations = <ExpenseCategory>[
      for (final CategoryUsage other in _usage)
        if (other.category.id != usage.category.id) other.category,
    ];
    // Uncategorized is never deletable, so there is always somewhere left for
    // the rows to go. Checked rather than trusted.
    if (destinations.isEmpty) return;

    final ExpenseCategory? into = await showModalBottomSheet<ExpenseCategory>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) =>
          _DeleteCategorySheet(usage: usage, destinations: destinations),
    );
    if (into == null || !mounted) return;

    final CategoryDeletion deletion = await _db.deleteCategory(
      category: usage.category,
      moveToId: into.id,
    );
    await _load();
    if (!mounted) return;

    final int moved = usage.txnCount;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(
          moved == 0
              ? 'Deleted ${usage.category.name}'
              : 'Deleted ${usage.category.name} · $moved '
                  'transaction${moved == 1 ? '' : 's'} now under ${into.name}',
        ),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            await _db.restoreCategory(deletion);
            await _load();
          },
        ),
      ));
  }

  String _subtitle(CategoryUsage usage) {
    final int n = usage.txnCount;
    return <String>[
      n == 0 ? 'Nothing filed under it' : '$n transaction${n == 1 ? '' : 's'}',
      if (usage.splitCount > 0) '${usage.splitCount} of them split',
      if (usage.merchantDefaultCount > 0)
        'default for ${usage.merchantDefaultCount} '
            'merchant${usage.merchantDefaultCount == 1 ? '' : 's'}',
      if (_isFallback(usage)) 'the fallback, so it stays',
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Brightness brightness = theme.brightness;

    return Scaffold(
      appBar: AppBar(title: const Text('Categories')),
      floatingActionButton: _loading
          ? null
          : FloatingActionButton.extended(
              onPressed: _add,
              icon: const Icon(Icons.add),
              label: const Text('New category'),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              // Clear of the button, which floats over the last row otherwise.
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: _usage.length,
              itemBuilder: (BuildContext context, int index) {
                final CategoryUsage usage = _usage[index];
                final String name = usage.category.name;

                return ListTile(
                  leading: Icon(
                    categoryIcon(name),
                    color: categoryColor(name, brightness),
                  ),
                  title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(_subtitle(usage)),
                  trailing: _isFallback(usage)
                      ? null
                      : IconButton(
                          tooltip: 'Delete $name',
                          icon: const Icon(Icons.delete_outline),
                          color: theme.colorScheme.error,
                          onPressed: () => _delete(usage),
                        ),
                );
              },
            ),
    );
  }
}

/// Names a new category.
///
/// The names already in use come in so a collision is caught while it is still
/// being typed. [AppDatabase.addCategory] would quietly hand back the existing
/// row instead — exactly right for the picker on a transaction, where the user
/// wants *a* category by that name and does not care whether it had to be
/// created, and wrong here, where the list is the subject and an Add that
/// appears to do nothing is the whole confusion.
class _NewCategorySheet extends StatefulWidget {
  const _NewCategorySheet({required this.taken});

  final List<String> taken;

  @override
  State<_NewCategorySheet> createState() => _NewCategorySheetState();
}

class _NewCategorySheetState extends State<_NewCategorySheet> {
  final TextEditingController _name = TextEditingController();

  /// Lower-cased name to the spelling on screen, so a clash can be reported in
  /// the words the list actually shows.
  ///
  /// Case-insensitive because the column is `UNIQUE COLLATE NOCASE` — "grocery"
  /// would not be a second category, it would be a failed insert. Dart's
  /// lower-casing is the Unicode one and SQLite's NOCASE only folds ASCII, so
  /// this can refuse a name the table would have taken; erring towards refusing
  /// is the harmless direction.
  late final Map<String, String> _taken = <String, String>{
    for (final String name in widget.taken) name.toLowerCase(): name,
  };

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final String name = _name.text.trim();
    if (name.isEmpty || _taken.containsKey(name.toLowerCase())) return;
    Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final String typed = _name.text.trim();
    final String? clash = _taken[typed.toLowerCase()];

    return Padding(
      // Lifts the field clear of the keyboard.
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('New category', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'It joins the picker on every transaction and can be set as a '
              "merchant's default.",
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                labelText: 'Call it',
                errorText: clash == null ? null : '$clash already exists',
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                const Spacer(),
                FilledButton(
                  // Dead until there is a name that can actually be inserted,
                  // rather than pressable and silently ineffective.
                  onPressed: typed.isEmpty || clash != null ? null : _submit,
                  child: const Text('Add'),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// Says where a deleted category's transactions go, and is the confirmation for
/// deleting it.
///
/// One step rather than two. The destination and the consequence of choosing it
/// are on screen together, so a dialog after this would be asking again about
/// something already spelled out — and the snackbar behind it carries Undo.
class _DeleteCategorySheet extends StatefulWidget {
  const _DeleteCategorySheet({required this.usage, required this.destinations});

  final CategoryUsage usage;

  /// Every category except the one being deleted, in [AppDatabase.categories]
  /// order — so Uncategorized, the default pick, is first.
  final List<ExpenseCategory> destinations;

  @override
  State<_DeleteCategorySheet> createState() => _DeleteCategorySheetState();
}

class _DeleteCategorySheetState extends State<_DeleteCategorySheet> {
  /// Uncategorized where it is there to be had. It is the honest default: the
  /// app cannot know which of the remaining categories these transactions
  /// belonged in, and quietly filing them under a real one would invent an
  /// answer the ledger would then show as fact.
  late ExpenseCategory _into = widget.destinations.firstWhere(
    (ExpenseCategory c) => c.name == kUncategorized,
    orElse: () => widget.destinations.first,
  );

  /// What the delete will do, in the numbers actually at stake.
  String get _consequence {
    final CategoryUsage usage = widget.usage;
    if (!usage.inUse) return 'Nothing is filed under it, so nothing moves.';

    final int n = usage.txnCount;
    final List<String> moving = <String>[
      if (n > 0) '$n transaction${n == 1 ? '' : 's'}',
      if (usage.merchantDefaultCount > 0)
        '${usage.merchantDefaultCount} merchant '
            'default${usage.merchantDefaultCount == 1 ? '' : 's'}',
    ];
    return '${moving.join(' and ')} move to the category you pick. '
        'Nothing is thrown away, and this can be undone.'
        '${usage.splitCount > 0 ? ' The '
            '${usage.splitCount} split one${usage.splitCount == 1 ? '' : 's'} '
            'keep their other lines and still add up.' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Brightness brightness = theme.brightness;
    final CategoryUsage usage = widget.usage;

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Delete ${usage.category.name}',
                style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(_consequence, style: theme.textTheme.bodySmall),
            if (usage.inUse) ...<Widget>[
              const SizedBox(height: 16),
              Text('Move them to', style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final ExpenseCategory category in widget.destinations)
                    ChoiceChip(
                      avatar: Icon(
                        categoryIcon(category.name),
                        size: 18,
                        color: categoryColor(category.name, brightness),
                      ),
                      label: Text(category.name),
                      selected: category.id == _into.id,
                      onSelected: (_) => setState(() => _into = category),
                    ),
                ],
              ),
            ],
            const Divider(height: 32),
            Row(
              children: <Widget>[
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.error,
                    foregroundColor: theme.colorScheme.onError,
                  ),
                  onPressed: () => Navigator.pop(context, _into),
                  child: const Text('Delete'),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

/// The second destination. A body only — the shell it sits in supplies the
/// Scaffold and the app bar, so there is no second one of either here.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final DateFormat _checkedFormat = DateFormat('d MMM yyyy, h:mm a');

  bool _autoCheck = true;
  String _version = '';
  String _build = '';
  DateTime? _lastChecked;
  bool _loading = true;
  bool _checking = false;

  /// One at a time, and neither while the other runs: both walk the whole
  /// database, and a restore landing halfway through an export would write a
  /// workbook of two different ledgers.
  bool _exporting = false;
  bool _restoring = false;

  bool get _busyWithData => _exporting || _restoring;

  /// The release a check on this screen turned up, kept so the Install button
  /// survives dismissing the dialog.
  AppRelease? _available;

  /// The outcome of the last manual check, in one line. Null before anything
  /// has been asked for, and while an update is being offered instead.
  String? _status;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final info = await PackageInfo.fromPlatform();
    final auto = await UpdatePrefs.instance.autoCheckEnabled();
    final last = await UpdatePrefs.instance.lastChecked();
    if (!mounted) return;
    setState(() {
      _version = info.version;
      _build = info.buildNumber;
      _autoCheck = auto;
      _lastChecked = last;
      _loading = false;
    });
  }

  Future<void> _setAutoCheck(bool value) async {
    // Optimistic: the switch is the only writer, so there is nothing to lose a
    // race against and no reason to make it lag a disk write.
    setState(() => _autoCheck = value);
    await UpdatePrefs.instance.setAutoCheckEnabled(value);
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  /// Writes the whole database to a workbook and offers it to the share sheet,
  /// which is how it reaches Drive — and from Drive, Google Sheets.
  Future<void> _export() async {
    if (_busyWithData) return;
    setState(() => _exporting = true);
    try {
      final BackupData data = await AppDatabase.instance.exportAll();
      final File file =
          await writeBackup(data, backupFileName(DateTime.now()));
      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(
          files: <XFile>[XFile(file.path, mimeType: kXlsxMimeType)],
          subject: 'TU Expense Tracker backup',
          text: '${data.meta['transactions']} transactions, exported '
              '${DateFormat('d MMM yyyy').format(DateTime.now())}.',
        ),
      );
    } catch (error) {
      _say('The export failed: $error');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// Reads a workbook back over the top of everything.
  ///
  /// Nothing is deleted until the file has been decoded, validated and
  /// confirmed, and a copy of what is about to be replaced has been written —
  /// so every way this can fail is a way that leaves the ledger alone.
  Future<void> _restore() async {
    if (_busyWithData) return;

    final PlatformFile? picked = await FilePicker.pickFile(
      dialogTitle: 'Choose a backup workbook',
      type: FileType.custom,
      allowedExtensions: const <String>['xlsx'],
    );
    if (picked == null || !mounted) return;

    setState(() => _restoring = true);
    try {
      final (BackupData? backup, String? unreadable) =
          await decodeBackupInBackground(await picked.readAsBytes());
      if (!mounted) return;
      if (backup == null) {
        await showBackupProblems(context, <String>[unreadable!]);
        return;
      }

      final List<String> problems = validateBackup(
        backup,
        appSchemaVersion: kSchemaVersion,
      );
      if (problems.isNotEmpty) {
        await showBackupProblems(context, problems);
        return;
      }

      // Read before asking, so the question can name what is about to go.
      final BackupData current = await AppDatabase.instance.exportAll();
      if (!mounted) return;
      final bool go = await confirmRestore(
        context,
        replacing: current.transactions.length,
        incoming: backup.transactions.length,
      );
      if (!go || !mounted) return;

      // The one irreversible action in the app, made reversible. Written before
      // the wipe rather than after, so a crash in between still leaves it.
      final File safety = await writeBackup(
        current,
        backupFileName(DateTime.now(), beforeRestore: true),
      );
      await AppDatabase.instance.replaceAll(backup);
      if (!mounted) return;

      await showDialog<void>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: const Text('Restored'),
          content: Text(
            '${backup.transactions.length} transactions, '
            '${backup.categories.length} categories and '
            '${backup.deleted.length} deleted rows are back.\n\n'
            'What was here before was saved as ${p.basename(safety.path)}.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    } catch (error) {
      _say('The restore failed: $error');
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  /// The explicit check. Unlike the launch one this always reports back, so a
  /// press of the button is never met with silence.
  Future<void> _checkNow() async {
    setState(() {
      _checking = true;
      _status = null;
      _available = null;
    });

    final result = await UpdateService.instance.check();
    final last = await UpdatePrefs.instance.lastChecked();
    if (!mounted) return;

    setState(() {
      _checking = false;
      _lastChecked = last;
      _available = result.release;
      _status = result.failed
          ? result.error
          : result.hasUpdate
              ? null
              : 'Up to date.';
    });

    if (result.hasUpdate) await showUpdateDialog(context, result.release!);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final release = _available;

    return _loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            children: <Widget>[
              SettingsHeader('Categorization'),
                ListTile(
                  leading: const Icon(Icons.storefront_outlined),
                  title: const Text('Merchants & defaults'),
                  subtitle: const Text(
                    'What each merchant is categorised as by default',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const MerchantDefaultsScreen(),
                    ),
                  ),
                ),
                const Divider(height: 32),
                SettingsHeader('Cleanup'),
                ListTile(
                  leading: const Icon(Icons.merge_type),
                  title: const Text('Merge merchants'),
                  subtitle: const Text(
                    'Fold several spellings of one shop into a single name',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          const MergeNamesScreen(kind: NameKind.merchant),
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.credit_card),
                  title: const Text('Merge cards & accounts'),
                  subtitle: const Text(
                    'One account can arrive labelled differently by each alert',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          const MergeNamesScreen(kind: NameKind.card),
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.label_outline),
                  title: const Text('Categories'),
                  subtitle: const Text(
                    'Add one, or drop one you never use — its transactions '
                    'move, not go',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const CategoriesScreen(),
                    ),
                  ),
                ),
                const Divider(height: 32),
                SettingsHeader('Data'),
                ListTile(
                  leading: const Icon(Icons.table_view_outlined),
                  title: const Text('Export data'),
                  subtitle: const Text(
                    'A spreadsheet of everything — and the same file a '
                    'restore reads back',
                  ),
                  trailing: _exporting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : FilledButton.tonal(
                          onPressed: _busyWithData ? null : _export,
                          child: const Text('Export'),
                        ),
                ),
                ListTile(
                  leading: const Icon(Icons.settings_backup_restore),
                  title: const Text('Restore from backup'),
                  subtitle: const Text(
                    'Replaces everything in the app with an exported '
                    'workbook',
                  ),
                  trailing: _restoring
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : FilledButton.tonal(
                          onPressed: _busyWithData ? null : _restore,
                          child: const Text('Restore'),
                        ),
                ),
                const Divider(height: 32),
                SettingsHeader('Updates'),
                SwitchListTile(
                  value: _autoCheck,
                  onChanged: _setAutoCheck,
                  title: const Text('Check automatically'),
                  subtitle: const Text(
                    'On launch, at most once a week. Nothing is downloaded '
                    'without asking.',
                  ),
                ),
                ListTile(
                  title: const Text('Check for updates'),
                  subtitle: Text(
                    _status ??
                        (_lastChecked == null
                            ? 'Not checked yet'
                            : 'Last checked '
                                '${_checkedFormat.format(_lastChecked!)}'),
                  ),
                  trailing: _checking
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : FilledButton.tonal(
                          onPressed: _checkNow,
                          child: const Text('Check now'),
                        ),
                ),
                if (release != null)
                  ListTile(
                    leading: Icon(
                      Icons.system_update_alt,
                      color: theme.colorScheme.primary,
                    ),
                    title: Text('Version ${release.version} available'),
                    subtitle: const Text('Downloads, then Android installs it'),
                    trailing: FilledButton(
                      onPressed: () => showUpdateDialog(context, release),
                      child: const Text('Install'),
                    ),
                  ),
                const Divider(height: 32),
                SettingsHeader('About'),
                ListTile(
                  title: const Text('TU Expense Tracker'),
                  subtitle: const Text(
                    'Turns bank SMS alerts into a categorised expense ledger.',
                  ),
                ),
                ListTile(
                  title: const Text('Version'),
                  // The build number distinguishes two APKs that report the
                  // same version, which matters while diagnosing an install.
                  subtitle: Text('$_version (build $_build)'),
                ),
                ListTile(
                  title: const Text('Releases'),
                  subtitle: const Text('github.com/$kUpdateRepo'),
                ),
                const SizedBox(height: 24),
              ],
            );
  }
}

class SettingsHeader extends StatelessWidget {
  const SettingsHeader(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        label,
        style: theme.textTheme.labelLarge
            ?.copyWith(color: theme.colorScheme.primary),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// UPDATE DIALOG
// ---------------------------------------------------------------------------

/// Offers [release], and on acceptance downloads and installs it without
/// leaving the dialog.
Future<void> showUpdateDialog(BuildContext context, AppRelease release) {
  return showDialog<void>(
    context: context,
    // A tap outside must not abandon a download in flight; Later is the way out.
    barrierDismissible: false,
    builder: (_) => UpdateDialog(release: release),
  );
}

class UpdateDialog extends StatefulWidget {
  const UpdateDialog({super.key, required this.release});

  final AppRelease release;

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  bool _downloading = false;

  /// Fraction downloaded, or null while the server has given no total to
  /// measure against — the bar then spins instead of filling.
  double? _progress;

  String? _error;

  Future<void> _install() async {
    setState(() {
      _downloading = true;
      _progress = null;
      _error = null;
    });

    try {
      final file = await UpdateService.instance.download(
        widget.release,
        onProgress: (double value) {
          if (mounted) setState(() => _progress = value);
        },
      );
      final problem = await UpdateService.instance.install(file);
      if (!mounted) return;
      if (problem != null) {
        setState(() {
          _downloading = false;
          _error = problem;
        });
        return;
      }
      // The system installer is in front of the app now; this dialog would
      // otherwise be waiting underneath it for a decision it no longer owns.
      Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error = 'The download failed. Check your connection and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final notes = widget.release.notes;

    return PopScope(
      // Back must not walk out on a half-written APK either.
      canPop: !_downloading,
      child: AlertDialog(
        title: Text('Version ${widget.release.version} available'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (notes.isNotEmpty)
              // Release notes are arbitrary length, so they scroll inside a
              // bounded box rather than pushing the buttons off screen.
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: SingleChildScrollView(
                  child: Text(notes, style: theme.textTheme.bodyMedium),
                ),
              )
            else
              const Text('A newer build is ready to install.'),
            if (_downloading) ...<Widget>[
              const SizedBox(height: 20),
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 8),
              Text(
                _progress == null
                    ? 'Downloading…'
                    : 'Downloading… ${(_progress! * 100).round()}%',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (_error != null) ...<Widget>[
              const SizedBox(height: 16),
              Text(
                _error!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ],
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed:
                _downloading ? null : () => Navigator.of(context).pop(),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: _downloading ? null : _install,
            child: Text(_error == null ? 'Update' : 'Retry'),
          ),
        ],
      ),
    );
  }
}
