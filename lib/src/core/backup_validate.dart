/// Checking a snapshot over before anything is written.
///
/// Pure, and deliberately exhaustive: it runs before a single row is deleted, so
/// every way a restore can fail is a way that leaves the ledger alone. The web
/// build runs it too, where it turns a truncated download into a readable
/// sentence rather than a red screen.
library;

import 'aliases.dart';
import 'backup_data.dart';
import 'constants.dart';
import 'models.dart';

/// Everything wrong with [data], as sentences fit to show the user. Empty means
/// it is safe to import.
///
/// This runs *before* anything is deleted, and a single entry is enough to
/// abandon the restore — which is the whole point. The database's own foreign
/// keys would catch most of these too, but only halfway through the write, and
/// "which row was it?" is not a question a rolled-back transaction can answer.
List<String> validateBackup(BackupData data, {required int appSchemaVersion}) {
  final List<String> problems = <String>[];

  final int? formatVersion = data.formatVersion;
  if (formatVersion == null) {
    problems.add('The file does not say which backup format it uses.');
  } else if (formatVersion > kBackupFormatVersion) {
    problems.add(
      'This backup is in format version $formatVersion, and this app '
      'understands up to $kBackupFormatVersion. Update the app first.',
    );
  }

  final int? schemaVersion = data.schemaVersion;
  if (schemaVersion == null) {
    problems.add('The file does not say which database version wrote it.');
  } else if (schemaVersion > appSchemaVersion) {
    // Refused outright rather than imported hopefully. A newer version may have
    // columns this build has never heard of, and dropping them silently would
    // turn a backup into a lossy one at the moment it is most needed.
    problems.add(
      'This backup came from a newer version of the app (database v'
      '$schemaVersion, this app reads up to v$appSchemaVersion). Update the '
      'app, then restore.',
    );
  }

  final Set<int> categoryIds = <int>{};
  final Set<String> categoryNames = <String>{};
  for (final Map<String, Object?> row in data.categories) {
    final int id = row['id'] as int;
    if (!categoryIds.add(id)) {
      problems.add('Two categories share the id $id.');
    }
    // The column is UNIQUE COLLATE NOCASE, so two spellings differing only in
    // case would collide on insert rather than both landing.
    if (!categoryNames.add((row['name'] as String).toLowerCase())) {
      problems.add('Two categories are named "${row['name']}".');
    }
  }
  // Every uncategorised transaction points at it, deleting a category moves its
  // rows to it, and the picker pins it to the top. A backup without it cannot
  // produce a working app.
  if (!categoryNames.contains(kUncategorized.toLowerCase())) {
    problems.add(
      'The Categories sheet has no "$kUncategorized" row, which '
      'the app cannot run without.',
    );
  }

  const Set<String> directions = <String>{'debit', 'credit'};
  final Set<int> transactionIds = <int>{};
  final Set<String> naturalKeys = <String>{};
  for (final Map<String, Object?> row in data.transactions) {
    final int id = row['id'] as int;
    if (!transactionIds.add(id)) {
      problems.add('Two transactions share the id $id.');
    }
    if (!categoryIds.contains(row['category_id'])) {
      problems.add(
        'Transaction $id is in category ${row['category_id']}, which is not in '
        'the Categories sheet.',
      );
    }
    if (!directions.contains(row['direction'])) {
      problems.add(
        'Transaction $id has direction "${row['direction']}" — it must be '
        'debit or credit.',
      );
    }
    if (!naturalKeys.add(_naturalKeyString(row))) {
      problems.add(
        'Two transactions have the same amount, merchant, timestamp, direction '
        'and reference, which the database forbids (see transaction $id).',
      );
    }
  }

  final Map<int, double> splitTotals = <int, double>{};
  final Set<int> splitIds = <int>{};
  for (final Map<String, Object?> row in data.splits) {
    final int id = row['id'] as int;
    final int transactionId = row['transaction_id'] as int;
    if (!splitIds.add(id)) problems.add('Two split lines share the id $id.');
    if (!transactionIds.contains(transactionId)) {
      problems.add(
        'A split line belongs to transaction $transactionId, which is not in '
        'the Transactions sheet.',
      );
    }
    if (!categoryIds.contains(row['category_id'])) {
      problems.add(
        'A split line on transaction $transactionId is in category '
        '${row['category_id']}, which is not in the Categories sheet.',
      );
    }
    splitTotals[transactionId] =
        (splitTotals[transactionId] ?? 0) + (row['amount'] as double);
  }

  // SQLite cannot express this as a CHECK, so it is enforced in Dart on the way
  // in — exactly as `saveSplits` does on the way out.
  final Map<int, double> amounts = <int, double>{
    for (final Map<String, Object?> row in data.transactions)
      row['id'] as int: row['amount'] as double,
  };
  splitTotals.forEach((int transactionId, double total) {
    final double? amount = amounts[transactionId];
    if (amount != null && (total - amount).abs() > kSplitTolerance) {
      problems.add(
        'The split lines on transaction $transactionId add up to '
        '${total.toStringAsFixed(2)}, but the transaction is '
        '${amount.toStringAsFixed(2)}.',
      );
    }
  });

  final Set<String> mappedMerchants = <String>{};
  for (final Map<String, Object?> row in data.merchantMappings) {
    if (!mappedMerchants.add((row['merchant_name'] as String).toLowerCase())) {
      problems.add(
        'Two merchant defaults are set for "${row['merchant_name']}".',
      );
    }
    if (!categoryIds.contains(row['category_id'])) {
      problems.add(
        'The default for "${row['merchant_name']}" points at category '
        '${row['category_id']}, which is not in the Categories sheet.',
      );
    }
  }

  final Set<String> kinds =
      NameKind.values.map((NameKind k) => k.column).toSet();
  final Set<String> aliasKeys = <String>{};
  for (final Map<String, Object?> row in data.aliases) {
    final String kind = row['kind'] as String;
    if (!kinds.contains(kind)) {
      problems.add('"$kind" is not a kind of name the app merges.');
    }
    if (!aliasKeys.add('$kind\u0000${(row['alias'] as String).toLowerCase()}')) {
      problems.add('The alias "${row['alias']}" is listed twice.');
    }
  }

  final Set<String> deletedKeys = <String>{};
  for (final Map<String, Object?> row in data.deleted) {
    if (!deletedKeys.add(_naturalKeyString(row))) {
      problems.add(
        'Two deleted rows have the same amount, merchant, timestamp, direction '
        'and reference (see "${row['merchant']}").',
      );
    }
    if (!directions.contains(row['direction'])) {
      problems.add(
        'A deleted row for "${row['merchant']}" has direction '
        '"${row['direction']}" — it must be debit or credit.',
      );
    }
    final Object? categoryId = row['category_id'];
    // Nullable by design: a tombstone written before schema v4 has no category,
    // and restores into Uncategorized. A category that is *named* but missing is
    // a different matter.
    if (categoryId != null && !categoryIds.contains(categoryId)) {
      problems.add(
        'A deleted row for "${row['merchant']}" is in category $categoryId, '
        'which is not in the Categories sheet.',
      );
    }
  }

  return problems;
}

/// [transactionNaturalKey] for a raw database row.
String _naturalKeyString(Map<String, Object?> row) => transactionNaturalKey(
      amount: row['amount'] as double,
      merchant: row['merchant'] as String,
      dateMillis: row['date'] as int,
      direction: row['direction'] as String,
      reference: row['reference'] as String,
    );
