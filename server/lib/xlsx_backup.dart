/// A minimal, write-only `.xlsx` export for the server's automated backups.
///
/// Deliberately a **trimmed, vendored copy** of the app's own backup codec
/// (`lib/src/core/backup_data.dart`, `lib/src/core/backup_json.dart`, and the
/// writing half of `lib/src/mobile/backup_xlsx.dart`), not a dependency on the
/// app package — the server stays a single native binary with no Flutter in
/// sight. This is the one deliberate exception to "the server has no schema
/// knowledge of the ledger": producing a readable spreadsheet needs to know
/// what a transaction row looks like. Everything else about the server (queues,
/// snapshots, auth) still treats a ledger as an opaque blob.
///
/// Only the write path is vendored — reading a workbook back is a phone-only
/// operation, so `decodeBackupWorkbook` and its sheet-reading machinery were
/// left behind. If the app's export format changes, this needs updating to
/// match by hand; there is no build step that keeps the two in sync.
library;

import 'dart:convert';
import 'dart:typed_data';

// `Border`, `BorderStyle` and `TextSpan` collide with names used elsewhere in
// a Flutter app; harmless here, kept only so a future merge from the app copy
// stays a clean diff.
import 'package:excel/excel.dart' hide Border, BorderStyle, TextSpan;

// --- from lib/src/core/constants.dart --------------------------------------

const String kUncategorized = 'Uncategorized';

// --- from lib/src/core/aliases.dart (NameKind only) -------------------------

enum NameKind {
  merchant('merchant', 'merchant', 'merchants'),
  card('payment_type', 'card / account', 'cards & accounts');

  const NameKind(this.column, this.label, this.plural);

  final String column;
  final String label;
  final String plural;
}

// --- from lib/src/core/backup_data.dart -------------------------------------

const String kBackupFormat = 'tu-expense-tracker-backup';

class BackupFormatException implements Exception {
  const BackupFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Every table, as the raw rows the phone's database holds.
class BackupData {
  const BackupData({
    required this.categories,
    required this.merchantMappings,
    required this.transactions,
    required this.splits,
    required this.deleted,
    required this.aliases,
    required this.appMeta,
    required this.meta,
  });

  final List<Map<String, Object?>> categories;
  final List<Map<String, Object?>> merchantMappings;
  final List<Map<String, Object?>> transactions;
  final List<Map<String, Object?>> splits;
  final List<Map<String, Object?>> deleted;
  final List<Map<String, Object?>> aliases;
  final List<Map<String, Object?>> appMeta;
  final Map<String, String> meta;
}

// --- from lib/src/core/backup_json.dart (decode only) -----------------------

const String _kJsonCategories = 'categories';
const String _kJsonMerchantMappings = 'merchant_mappings';
const String _kJsonTransactions = 'transactions';
const String _kJsonSplits = 'transaction_splits';
const String _kJsonDeleted = 'deleted_transactions';
const String _kJsonAliases = 'name_aliases';
const String _kJsonAppMeta = 'app_meta';
const String _kJsonMeta = 'meta';

enum _Col { int_, double_, text }

const Map<String, Map<String, _Col>> _columns = <String, Map<String, _Col>>{
  _kJsonCategories: <String, _Col>{
    'id': _Col.int_,
    'name': _Col.text,
    'icon': _Col.text,
  },
  _kJsonMerchantMappings: <String, _Col>{
    'merchant_name': _Col.text,
    'category_id': _Col.int_,
  },
  _kJsonTransactions: <String, _Col>{
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
  _kJsonSplits: <String, _Col>{
    'id': _Col.int_,
    'transaction_id': _Col.int_,
    'category_id': _Col.int_,
    'amount': _Col.double_,
    'position': _Col.int_,
  },
  _kJsonDeleted: <String, _Col>{
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
  _kJsonAliases: <String, _Col>{
    'kind': _Col.text,
    'alias': _Col.text,
    'canonical': _Col.text,
  },
  _kJsonAppMeta: <String, _Col>{
    'key': _Col.text,
    'value': _Col.text,
  },
};

/// [body] — a phone's snapshot, as already stored on disk by `SnapshotStore`
/// — decoded into a [BackupData], the shape [encodeBackupWorkbook] wants.
BackupData decodeBackupJson(String body) {
  final Object? parsed;
  try {
    parsed = jsonDecode(body);
  } on FormatException catch (error) {
    throw BackupFormatException('That is not valid JSON (${error.message}).');
  }

  if (parsed is! Map<String, Object?>) {
    throw const BackupFormatException(
      'A snapshot has to be a JSON object, and this is not one.',
    );
  }

  if (parsed['format'] != kBackupFormat) {
    throw const BackupFormatException(
      'This file is not a TU Expense Tracker snapshot.',
    );
  }

  return BackupData(
    categories: _rows(parsed, _kJsonCategories),
    merchantMappings: _rows(parsed, _kJsonMerchantMappings),
    transactions: _rows(parsed, _kJsonTransactions),
    splits: _rows(parsed, _kJsonSplits),
    deleted: _rows(parsed, _kJsonDeleted),
    aliases: _rows(parsed, _kJsonAliases),
    appMeta: _rows(parsed, _kJsonAppMeta),
    meta: _meta(parsed),
  );
}

Map<String, String> _meta(Map<String, Object?> parsed) {
  final Object? raw = parsed[_kJsonMeta];
  if (raw == null) return const <String, String>{};
  if (raw is! Map) {
    throw const BackupFormatException(
      "The snapshot's meta block is not an object.",
    );
  }
  return <String, String>{
    for (final MapEntry<Object?, Object?> e in raw.entries)
      if (e.key is String && e.value != null) e.key! as String: '${e.value}',
  };
}

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
      throw BackupFormatException('"$table" row ${i + 1} is not an object.');
    }
    rows.add(<String, Object?>{
      for (final MapEntry<Object?, Object?> e in row.entries)
        if (e.key is String) e.key! as String: _coerce(e.value, columns[e.key]),
    });
  }
  return rows;
}

Object? _coerce(Object? value, _Col? column) {
  if (value == null || column == null) return value;
  return switch (column) {
    _Col.int_ => _asInt(value),
    _Col.double_ => _asDouble(value),
    _Col.text => value is String ? value : '$value',
  };
}

Object? _asInt(Object value) {
  if (value is int) return value;
  if (value is double) return value.isFinite ? value.round() : value;
  if (value is String) return int.tryParse(value.trim()) ?? value;
  return value;
}

Object? _asDouble(Object value) {
  if (value is double) return value;
  if (value is int) return value.toDouble();
  if (value is String) return double.tryParse(value.trim()) ?? value;
  return value;
}

// --- from lib/src/mobile/backup_xlsx.dart (write path only) -----------------

const String kSheetTransactions = 'Transactions';
const String kSheetSplits = 'Splits';
const String kSheetCategories = 'Categories';
const String kSheetMerchantDefaults = 'Merchant defaults';
const String kSheetAliases = 'Name aliases';
const String kSheetDeleted = 'Deleted';
const String kSheetMeta = 'Meta';

CellValue? _textOrBlank(Object? value) {
  final String text = (value as String?) ?? '';
  return text.isEmpty ? null : TextCellValue(text);
}

CellValue? _intOrBlank(Object? value) =>
    value == null ? null : IntCellValue((value as num).toInt());

CellValue? _dateCell(Object? millis) => millis == null
    ? null
    : DateTimeCellValue.fromDateTime(
        DateTime.fromMillisecondsSinceEpoch((millis as num).toInt()),
      );

/// The split lines as one readable phrase — `Grocery 1200.00; Food 800.00`.
String splitSummary(List<Map<String, Object?>> lines, Map<int, String> names) {
  if (lines.isEmpty) return '';
  return lines.map((Map<String, Object?> line) {
    final String name =
        names[(line['category_id'] as num?)?.toInt()] ?? kUncategorized;
    final double amount = (line['amount'] as num?)?.toDouble() ?? 0;
    return '$name ${amount.toStringAsFixed(2)}';
  }).join('; ');
}

/// The whole ledger as a workbook, ready to be written to disk — the same
/// seven sheets and columns the phone's own "Export to Excel" produces, so a
/// file from either place opens and restores the same way.
Uint8List encodeBackupWorkbook(BackupData data) {
  final Excel excel = Excel.createExcel();

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
    const <String>['id', 'Name', 'Icon'],
    () => data.categories
        .map((Map<String, Object?> row) => <CellValue?>[
              IntCellValue((row['id'] as num).toInt()),
              TextCellValue(row['name'] as String),
              _textOrBlank(row['icon']),
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
      for (final Map<String, Object?> row in data.appMeta)
        <CellValue?>[
          TextCellValue('app_meta.${row['key']}'),
          TextCellValue(row['value'] as String),
        ],
    ],
  );

  excel.delete('Sheet1');
  excel.setDefaultSheet(kSheetTransactions);

  final List<int>? bytes = excel.encode();
  if (bytes == null) {
    throw const BackupFormatException('The workbook could not be written.');
  }
  return Uint8List.fromList(bytes);
}
