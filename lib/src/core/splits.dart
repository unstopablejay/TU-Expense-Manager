/// A split transaction's category/amount lines, and the arithmetic over them.
///
/// [TxnSplit] lives here rather than with the other models because
/// `DeletedTxn.fromMap` decodes splits, and [decodeSplits] returns them — put
/// the two in separate files and they import each other.
library;

import 'dart:convert';

import 'constants.dart';

/// One category/amount line of a split transaction.
///
/// Carries the category *name* as well as its id so a tombstone snapshot and
/// the Deleted screen can render without a join, and so a line still reads
/// correctly if the category is renamed afterwards.
class TxnSplit {
  const TxnSplit({
    required this.categoryId,
    required this.categoryName,
    this.categoryIcon = '',
    required this.amount,
  });

  factory TxnSplit.fromMap(Map<String, Object?> map) => TxnSplit(
        categoryId: map['category_id'] as int,
        categoryName: (map['category_name'] ?? map['name']) as String,
        categoryIcon: (map['category_icon'] as String?) ??
            (map['icon'] as String?) ??
            '',
        amount: (map['amount'] as num).toDouble(),
      );

  final int categoryId;
  final String categoryName;
  final String categoryIcon;
  final double amount;

  Map<String, Object?> toJson() => <String, Object?>{
        'category_id': categoryId,
        'name': categoryName,
        'icon': categoryIcon,
        'amount': amount,
      };
}


/// How much of [total] the lines have not accounted for. Negative means they
/// have over-allocated it.
double unallocated(List<double> amounts, double total) =>
    total - amounts.fold<double>(0, (double sum, double a) => sum + a);

bool isBalanced(
  List<double> amounts,
  double total, {
  double tolerance = kSplitTolerance,
}) =>
    amounts.isNotEmpty && unallocated(amounts, total).abs() <= tolerance;

/// The same amounts with the last line rewritten to whatever is left over, so
/// filling in the rows above always leaves the last one holding the balance.
///
/// Typing 1200 against a ₹2,000 charge leaves 800 in the second row; adding a
/// third and typing 300 in the second leaves 500 in the third. The last line
/// also absorbs any rounding drift, which is what makes the stored lines sum to
/// the transaction exactly.
List<double> withRemainderInLast(List<double> amounts, double total) {
  if (amounts.isEmpty) return amounts;
  final List<double> out = List<double>.of(amounts);
  final double allocated = out
      .take(out.length - 1)
      .fold<double>(0, (double sum, double a) => sum + a);
  out[out.length - 1] = total - allocated;
  return out;
}

/// Splits as a tombstone carries them — null when there are none, so the column
/// stays empty for the unsplit transactions that are the overwhelming majority.
String? encodeSplits(List<TxnSplit> splits) => splits.isEmpty
    ? null
    : jsonEncode(splits.map((TxnSplit s) => s.toJson()).toList());

/// The inverse of [encodeSplits]. Anything unreadable decodes to no splits: a
/// transaction that restores under one category is recoverable, one that throws
/// on the way out of the Deleted screen is not.
List<TxnSplit> decodeSplits(String? json) {
  if (json == null || json.isEmpty) return const <TxnSplit>[];
  try {
    final Object? decoded = jsonDecode(json);
    if (decoded is! List) return const <TxnSplit>[];
    return decoded
        .whereType<Map<String, Object?>>()
        .map(TxnSplit.fromMap)
        .toList();
  } on FormatException {
    return const <TxnSplit>[];
  }
}

// ---------------------------------------------------------------------------
// NOTES
// ---------------------------------------------------------------------------
