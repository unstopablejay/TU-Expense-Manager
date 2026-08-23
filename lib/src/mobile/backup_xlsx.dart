/// The `.xlsx` backup codec.
///
/// Mobile-only, and staying that way: the workbook is what a human opens in
/// Sheets to read their own data, which is a different job from the JSON the
/// sync snapshot uses on the wire. Columns are matched by header *name*, so
/// sorting or hiding a column in Sheets does not stop a file restoring.
library;

import 'dart:typed_data';

// `Border`, `BorderStyle` and `TextSpan` all collide with Material's.
import 'package:excel/excel.dart' hide Border, BorderStyle, TextSpan;

import '../core/aliases.dart';
import '../core/backup_data.dart';
import '../core/constants.dart';
import '../core/parser.dart';

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
      final String? icon = _cellText(cell('Icon'));
      if (id == null) categories.bad(row, 'the id is missing or not a number.');
      if (name == null || name.isEmpty) categories.bad(row, 'the name is empty.');
      return <String, Object?>{'id': id, 'name': name, 'icon': icon ?? ''};
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
