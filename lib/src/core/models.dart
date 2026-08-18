/// The domain types the ledger is made of.
///
/// Plain data with `fromMap` factories over raw database rows. No SQL, no
/// widgets — the app reads these from sqflite and the web build reads the same
/// types out of a snapshot.
library;

import 'constants.dart';
import 'parser.dart';
import 'splits.dart';


class ExpenseCategory {
  const ExpenseCategory({required this.id, required this.name});

  factory ExpenseCategory.fromMap(Map<String, Object?> map) => ExpenseCategory(
        id: map['id'] as int,
        name: map['name'] as String,
      );

  final int id;
  final String name;
}

/// A category together with everything filed under it — what the cleanup screen
/// lists, and what lets a delete describe its consequences before it happens.
class CategoryUsage {
  const CategoryUsage({
    required this.category,
    required this.unsplitCount,
    required this.splitCount,
    required this.merchantDefaultCount,
  });

  factory CategoryUsage.fromMap(Map<String, Object?> map) => CategoryUsage(
        category: ExpenseCategory.fromMap(map),
        unsplitCount: map['unsplit_count'] as int,
        splitCount: map['split_count'] as int,
        merchantDefaultCount: map['merchant_default_count'] as int,
      );

  final ExpenseCategory category;

  /// Transactions filed here outright, with no split lines of their own.
  final int unsplitCount;

  /// Split transactions with at least one line here — counted once each,
  /// however many of their lines land in this category.
  final int splitCount;

  /// `merchant_mappings` rows pointing here.
  final int merchantDefaultCount;

  /// How many transactions the ledger shows under a filter on this category.
  ///
  /// The two counts add rather than overlap: a transaction either has split
  /// lines or it does not, and only one of the two queries can see it.
  int get txnCount => unsplitCount + splitCount;

  bool get inUse => txnCount > 0 || merchantDefaultCount > 0;
}

/// What one [AppDatabase.deleteCategory] moved, and everything needed to move it
/// back.
///
/// Row ids rather than a predicate, and that is the whole point: rows already
/// sitting in the destination before the delete must not be dragged out of it by
/// an undo. Only what actually moved is listed here.
class CategoryDeletion {
  const CategoryDeletion({
    required this.categoryId,
    required this.categoryName,
    required this.transactionIds,
    required this.splitIds,
    required this.merchantNames,
    required this.tombstones,
  });

  final int categoryId;
  final String categoryName;
  final List<int> transactionIds;
  final List<int> splitIds;
  final List<String> merchantNames;

  /// The `deleted_transactions` rows that named the category, exactly as they
  /// read before the delete: the natural key plus the two columns that mentioned
  /// it. Kept whole because `splits_json` is rewritten rather than repointed,
  /// and putting the old text straight back is the only exact undo of that.
  final List<Map<String, Object?>> tombstones;
}

/// A merchant as the Merchants screen sees it: how much has gone through it and
/// what it defaults to.
///
/// [defaultCategoryId] carries three states. Null means no mapping row at all —
/// never configured. The Uncategorized id means a mapping was set deliberately
/// to "always ask me", for a merchant like Amazon that always needs splitting.
/// Anything else is a real default.
class MerchantSummary {
  const MerchantSummary({
    required this.merchant,
    required this.txnCount,
    required this.totalSpent,
    required this.lastSeen,
    required this.defaultCategoryId,
    required this.defaultCategoryName,
  });

  factory MerchantSummary.fromMap(Map<String, Object?> map) => MerchantSummary(
        merchant: map['merchant'] as String,
        txnCount: map['txn_count'] as int,
        totalSpent: ((map['total_spent'] as num?) ?? 0).toDouble(),
        lastSeen:
            DateTime.fromMillisecondsSinceEpoch((map['last_seen'] as int?) ?? 0),
        defaultCategoryId: map['default_category_id'] as int?,
        defaultCategoryName: map['default_category_name'] as String?,
      );

  final String merchant;
  final int txnCount;
  final double totalSpent;
  final DateTime lastSeen;
  final int? defaultCategoryId;
  final String? defaultCategoryName;
}

/// A row of `transactions` joined to its category name.
/// (Named `ExpenseTxn` because sqflite already exports a `Transaction` type.)
/// The five columns that uniquely identify a transaction, as one comparable
/// string.
///
/// This tuple is the app's real identity for a transaction: it is what makes SMS
/// ingestion idempotent, what `deleted_transactions` is keyed on, and the only
/// identity that means the same thing on two devices — row ids do not.
///
/// [merchant] is lower-cased because the real index is `COLLATE NOCASE`, and
/// must be the merchant **as stored**, never the merged spelling. See
/// [ExpenseTxn.rawMerchant]. [amount] goes through `toString` because that is
/// round-trip exact for a double.
///
/// The separator is NUL, which no field can contain, so no two different tuples
/// can join to the same string. Written as an escape rather than as the byte
/// itself: a literal NUL is invisible in an editor, and makes git treat a small
/// source file as binary.
///
/// Not to be confused with [DeletedTxn.key], which is a different spelling of
/// the same tuple used only for list selection inside one screen. This is the
/// one that crosses a wire; the two are not interchangeable.
String transactionNaturalKey({
  required double amount,
  required String merchant,
  required int dateMillis,
  required String direction,
  required String reference,
}) =>
    <String>[
      amount.toString(),
      merchant.toLowerCase(),
      dateMillis.toString(),
      direction,
      reference,
    ].join('\u0000');

class ExpenseTxn {
  const ExpenseTxn({
    required this.id,
    required this.amount,
    required this.paymentType,
    required this.merchant,
    required this.date,
    required this.categoryId,
    required this.categoryName,
    required this.direction,
    required this.reference,
    this.note = '',
    this.splits = const <TxnSplit>[],
    String? rawMerchant,
    String? rawPaymentType,
  })  : rawMerchant = rawMerchant ?? merchant,
        rawPaymentType = rawPaymentType ?? paymentType;

  factory ExpenseTxn.fromMap(
    Map<String, Object?> map, {
    List<TxnSplit> splits = const <TxnSplit>[],
  }) =>
      ExpenseTxn(
        splits: splits,
        id: map['id'] as int,
        amount: (map['amount'] as num).toDouble(),
        paymentType: (map['payment_type'] as String?) ?? 'Unknown',
        merchant: map['merchant'] as String,
        date: DateTime.fromMillisecondsSinceEpoch(map['date'] as int),
        categoryId: map['category_id'] as int,
        categoryName: map['category_name'] as String,
        direction: (map['direction'] as String?) == 'credit'
            ? TxnDirection.credit
            : TxnDirection.debit,
        reference: (map['reference'] as String?) ?? '',
        note: (map['note'] as String?) ?? '',
      );

  final int id;
  final double amount;

  /// What to show and filter by — already resolved through any merge.
  final String paymentType;
  final String merchant;

  final DateTime date;
  final int categoryId;
  final String categoryName;
  final TxnDirection direction;
  final String reference;

  /// Whatever the user wanted to remember about this charge that the bank had
  /// no way of saying. Empty means there is no note — never null.
  final String note;

  /// What the columns actually hold. Equal to the pair above until a merge
  /// renames them.
  ///
  /// These are not for display. They exist because the merchant is part of the
  /// natural key that finds this row again — writing a tombstone under the
  /// merged name would match nothing, and the delete would quietly not happen.
  final String rawMerchant;
  final String rawPaymentType;

  /// The lines this transaction was split into, or empty when it is not split.
  /// Read through [effectiveSplits] rather than directly.
  final List<TxnSplit> splits;

  /// Only the two merged names can be replaced; everything else about a
  /// transaction comes from the row and has no reason to be rewritten in
  /// memory. Passing null for either keeps it as it is.
  ExpenseTxn copyWith({String? merchant, String? paymentType}) => ExpenseTxn(
        id: id,
        amount: amount,
        paymentType: paymentType ?? this.paymentType,
        merchant: merchant ?? this.merchant,
        date: date,
        categoryId: categoryId,
        categoryName: categoryName,
        direction: direction,
        reference: reference,
        note: note,
        splits: splits,
        rawMerchant: rawMerchant,
        rawPaymentType: rawPaymentType,
      );

  /// This row's [transactionNaturalKey], from the columns as stored.
  ///
  /// Uses [rawMerchant] rather than [merchant], so a key composed while looking
  /// at a merged name still addresses the row the columns actually hold. Writing
  /// the merged spelling would address nothing, and the caller would be told the
  /// row had gone.
  String get naturalKey => transactionNaturalKey(
        amount: amount,
        merchant: rawMerchant,
        dateMillis: date.millisecondsSinceEpoch,
        direction: direction.name,
        reference: reference,
      );

  bool get isUncategorized => categoryName == kUncategorized;

  bool get hasNote => note.isNotEmpty;

  bool get isCredit => direction == TxnDirection.credit;

  bool get isSplit => splits.isNotEmpty;

  /// The transaction as a list of category/amount lines, whether or not it was
  /// ever split — an unsplit one is simply a single line for its full amount.
  ///
  /// Everything downstream (filters, tiles, the summary breakdown) iterates
  /// this, so none of it has to ask whether a transaction is split. That is the
  /// whole point: one code path, and no chance of the two drifting apart.
  List<TxnSplit> get effectiveSplits => splits.isEmpty
      ? <TxnSplit>[
          TxnSplit(
            categoryId: categoryId,
            categoryName: categoryName,
            amount: amount,
          ),
        ]
      : splits;
}

/// A row of `deleted_transactions`, joined to its category name. Everything the
/// Deleted screen needs to show a transaction and to put it back.
class DeletedTxn {
  const DeletedTxn({
    required this.amount,
    required this.merchant,
    required this.date,
    required this.direction,
    required this.reference,
    required this.paymentType,
    required this.categoryId,
    required this.originalId,
    required this.deletedAt,
    required this.categoryName,
    this.note = '',
    this.splits = const <TxnSplit>[],
  });

  /// Every column after the natural key is nullable: tombstones written before
  /// schema v4 recorded only enough to stay deleted.
  factory DeletedTxn.fromMap(Map<String, Object?> map) => DeletedTxn(
        amount: (map['amount'] as num).toDouble(),
        merchant: map['merchant'] as String,
        date: DateTime.fromMillisecondsSinceEpoch(map['date'] as int),
        direction: (map['direction'] as String?) == 'credit'
            ? TxnDirection.credit
            : TxnDirection.debit,
        reference: (map['reference'] as String?) ?? '',
        paymentType: (map['payment_type'] as String?) ?? 'Unknown',
        categoryId: map['category_id'] as int?,
        originalId: map['original_id'] as int?,
        deletedAt: map['deleted_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(map['deleted_at'] as int),
        categoryName:
            (map['category_name'] as String?) ?? kUncategorized,
        note: (map['note'] as String?) ?? '',
        splits: decodeSplits(map['splits_json'] as String?),
      );

  final double amount;
  final String merchant;
  final DateTime date;
  final TxnDirection direction;
  final String reference;
  final String paymentType;
  final int? categoryId;
  final int? originalId;
  final DateTime? deletedAt;
  final String categoryName;

  /// The note the transaction carried when it was deleted. Empty for a
  /// tombstone written before schema v7, which is the truth: there were no
  /// notes to lose then.
  final String note;

  /// The lines this transaction was split into when it was deleted, carried in
  /// the tombstone so restoring puts them back. Empty for an unsplit
  /// transaction and for every tombstone written before schema v5.
  final List<TxnSplit> splits;

  bool get isCredit => direction == TxnDirection.credit;

  /// Identity for list keys — the natural key, which is what the table is keyed
  /// on and therefore unique across tombstones.
  String get key => '$amount|$merchant|${date.millisecondsSinceEpoch}'
      '|${direction.name}|$reference';
}
