/// The JSON wire format: what a snapshot looks like crossing a network.
///
/// The `.xlsx` workbook is what a human opens to read their own data. This is
/// what the phone pushes to a self-hosted server and what the web build reads
/// back. Same [BackupData], same [kBackupFormat] marker, same `validateBackup`
/// — only the container differs, so neither format can drift into accepting
/// what the other would reject.
library;

import 'dart:convert';

import 'backup_data.dart';

/// The JSON keys each table's rows are carried under.
///
/// Deliberately the SQLite table names rather than the workbook's sheet names:
/// a snapshot is a database, and naming the keys after the tables means a reader
/// comparing a snapshot against the schema is comparing like with like.
const String kJsonCategories = 'categories';
const String kJsonMerchantMappings = 'merchant_mappings';
const String kJsonTransactions = 'transactions';
const String kJsonSplits = 'transaction_splits';
const String kJsonDeleted = 'deleted_transactions';
const String kJsonAliases = 'name_aliases';
const String kJsonAppMeta = 'app_meta';
const String kJsonMeta = 'meta';

/// A column's storage type, so the decoder can put back what JSON flattens.
enum _Col { int_, double_, text }

/// Every column of every table, by the type SQLite holds it as.
///
/// **This table is why the codec is not four lines long.** JSON has one number
/// type, so a value written as `1200.0` may come back as `1200` from anything
/// that re-serialises it — a hand edit, a jq filter, a non-Dart writer. That
/// matters twice over:
///
///  - `validateBackup` reaches a row's amount through `as double` and its date
///    through `as int`. A JSON `int` where a double is expected throws a
///    `CastError` *before* validation can report anything a user could read.
///  - `AppDatabase.replaceAll` inserts these maps straight into typed columns,
///    where `amount REAL` and `date INTEGER` are not interchangeable.
///
/// So the decoder coerces each column to the type its column actually holds,
/// exactly as the workbook reader already forgives the excel package's habit of
/// reading `1200.0` back as an integer. Columns absent here are passed through
/// untouched, which is what keeps a snapshot from a *newer* schema readable
/// enough for `validateBackup` to refuse it with a sentence rather than a crash.
const Map<String, Map<String, _Col>> _columns = <String, Map<String, _Col>>{
  kJsonCategories: <String, _Col>{
    'id': _Col.int_,
    'name': _Col.text,
    'icon': _Col.text,
  },
  kJsonMerchantMappings: <String, _Col>{
    'merchant_name': _Col.text,
    'category_id': _Col.int_,
  },
  kJsonTransactions: <String, _Col>{
    'id': _Col.int_,
    'amount': _Col.double_,
    'payment_type': _Col.text,
    'merchant': _Col.text,
    'date': _Col.int_,
    'category_id': _Col.int_,
    'direction': _Col.text,
    'reference': _Col.text,
    'note': _Col.text,
  },
  kJsonSplits: <String, _Col>{
    'id': _Col.int_,
    'transaction_id': _Col.int_,
    'category_id': _Col.int_,
    'amount': _Col.double_,
    'position': _Col.int_,
  },
  kJsonDeleted: <String, _Col>{
    'amount': _Col.double_,
    'merchant': _Col.text,
    'date': _Col.int_,
    'direction': _Col.text,
    'reference': _Col.text,
    'payment_type': _Col.text,
    'category_id': _Col.int_,
    'original_id': _Col.int_,
    'deleted_at': _Col.int_,
    'splits_json': _Col.text,
    'note': _Col.text,
  },
  kJsonAliases: <String, _Col>{
    'kind': _Col.text,
    'alias': _Col.text,
    'canonical': _Col.text,
  },
  kJsonAppMeta: <String, _Col>{
    'key': _Col.text,
    'value': _Col.text,
  },
};

/// [data] as a JSON string.
///
/// A top-level function of one argument so it can be handed to `compute()`, the
/// same way the workbook writer is: a few thousand transactions is enough
/// encoding to drop a frame if it happens on the UI isolate.
String encodeBackupJson(BackupData data) => jsonEncode(<String, Object?>{
      // Repeated outside `meta` as well as in it. A reader should be able to
      // reject a file it has no business parsing by looking at the first two
      // keys, without having to understand the meta block first.
      'format': kBackupFormat,
      'format_version': kBackupFormatVersion,
      kJsonMeta: data.meta,
      kJsonCategories: data.categories,
      kJsonMerchantMappings: data.merchantMappings,
      kJsonTransactions: data.transactions,
      kJsonSplits: data.splits,
      kJsonDeleted: data.deleted,
      kJsonAliases: data.aliases,
      kJsonAppMeta: data.appMeta,
    });

/// [body] back into a [BackupData].
///
/// Throws [BackupFormatException] with a sentence fit to show the user when the
/// body is not a snapshot at all. It does *not* judge the contents — that is
/// `validateBackup`'s job, and keeping the two apart is what lets one function
/// check both formats.
BackupData decodeBackupJson(String body) {
  final Object? parsed;
  try {
    parsed = jsonDecode(body);
  } on FormatException catch (error) {
    throw BackupFormatException(
      'That is not valid JSON (${error.message}).',
    );
  }

  if (parsed is! Map<String, Object?>) {
    throw const BackupFormatException(
      'A snapshot has to be a JSON object, and this is not one.',
    );
  }

  // The marker first, before anything else is read. A body without it is
  // somebody else's JSON, and guessing at it is how a restore corrupts a
  // ledger with data that was never ours.
  if (parsed['format'] != kBackupFormat) {
    throw const BackupFormatException(
      'This file is not a TU Expense Tracker snapshot.',
    );
  }

  return BackupData(
    categories: _rows(parsed, kJsonCategories),
    merchantMappings: _rows(parsed, kJsonMerchantMappings),
    transactions: _rows(parsed, kJsonTransactions),
    splits: _rows(parsed, kJsonSplits),
    deleted: _rows(parsed, kJsonDeleted),
    aliases: _rows(parsed, kJsonAliases),
    appMeta: _rows(parsed, kJsonAppMeta),
    meta: _meta(parsed),
  );
}

/// The Meta block, every value as a string.
///
/// `buildBackupMeta` writes strings throughout, but a hand-edited or
/// re-serialised snapshot can easily carry `"format_version": 1` as a number.
/// Stringifying whatever turned up keeps `BackupData.schemaVersion` — which
/// parses these with `int.tryParse` — working either way.
Map<String, String> _meta(Map<String, Object?> parsed) {
  final Object? raw = parsed[kJsonMeta];
  if (raw == null) return const <String, String>{};
  if (raw is! Map) {
    throw const BackupFormatException(
      'The snapshot\'s meta block is not an object.',
    );
  }
  return <String, String>{
    for (final MapEntry<Object?, Object?> e in raw.entries)
      if (e.key is String && e.value != null) e.key! as String: '${e.value}',
  };
}

/// One table's rows, each column coerced to the type its column holds.
///
/// A missing table decodes to no rows rather than throwing. Every table but
/// `categories` is legitimately empty in a fresh install, and an absent key is
/// indistinguishable from an empty list in intent; `validateBackup` is what
/// insists on a `categories` table with an Uncategorized row in it.
List<Map<String, Object?>> _rows(Map<String, Object?> parsed, String table) {
  final Object? raw = parsed[table];
  if (raw == null) return <Map<String, Object?>>[];
  if (raw is! List) {
    throw BackupFormatException('"$table" is not a list of rows.');
  }

  final Map<String, _Col> columns = _columns[table]!;
  final List<Map<String, Object?>> rows = <Map<String, Object?>>[];
  for (int i = 0; i < raw.length; i++) {
    final Object? row = raw[i];
    if (row is! Map) {
      // Row numbers are one-based and named, to match how the workbook reader
      // reports a bad row: this message may be all the user gets.
      throw BackupFormatException('"$table" row ${i + 1} is not an object.');
    }
    rows.add(<String, Object?>{
      for (final MapEntry<Object?, Object?> e in row.entries)
        if (e.key is String)
          e.key! as String: _coerce(e.value, columns[e.key]),
    });
  }
  return rows;
}

/// [value] as [column] holds it, or unchanged when the column is unknown.
///
/// Null passes through: a nullable column is genuinely null, and a non-nullable
/// one with a null in it is a problem for `validateBackup` to describe, not for
/// this function to paper over with a zero.
Object? _coerce(Object? value, _Col? column) {
  if (value == null || column == null) return value;
  return switch (column) {
    _Col.int_ => _asInt(value),
    _Col.double_ => _asDouble(value),
    _Col.text => value is String ? value : '$value',
  };
}

/// A whole number, from a number or from a string holding one.
///
/// `round()` rather than `toInt()` for a double: every int column here is an id,
/// an epoch-millisecond timestamp or a position, and `1755000000000.0` arriving
/// as a double should come back as that instant and not one truncated by a
/// millisecond. A value that is not a number at all is left alone so that
/// validation, which can name the row, is what reports it.
Object? _asInt(Object value) {
  if (value is int) return value;
  if (value is double) return value.isFinite ? value.round() : value;
  if (value is String) return int.tryParse(value.trim()) ?? value;
  return value;
}

/// A real number, from a number or from a string holding one.
Object? _asDouble(Object value) {
  if (value is double) return value;
  if (value is int) return value.toDouble();
  if (value is String) return double.tryParse(value.trim()) ?? value;
  return value;
}
