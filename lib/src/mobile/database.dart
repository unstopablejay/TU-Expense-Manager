/// The SQLite ledger: every table, every migration, every query.
///
/// The one data-access class in the app — no repository layer above it, and no
/// SQL anywhere else. Mobile-only by nature: sqflite has no web implementation,
/// which is exactly why the web build reads a snapshot instead.
library;

import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

import '../core/aliases.dart';
import '../core/backup_data.dart';
import '../core/constants.dart';
import '../core/models.dart';
import '../core/parser.dart';
import '../core/splits.dart';

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
