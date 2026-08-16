import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:open_filex/open_filex.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';
// Maintained fork of `telephony` (identical API). The original 0.2.0 has no
// Gradle namespace and cannot build against AGP 8+.
import 'package:another_telephony/telephony.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TuExpenseTrackerApp());
}

/// A real YES Bank credit card alert, used to prefill the manual-entry dialog
/// so the whole pipeline can be exercised without SMS permission.
const String kSampleSms =
    'INR 204.00 spent on YES BANK Card X2858 @UPI_GEORGE EGG CENTRE '
    '13-08-2026 09:21:35 am. Avl Lmt INR 281,496.08. '
    'SMS BLKCC 2858 to 9840909000 if not you';

// ---------------------------------------------------------------------------
// 1. PARSER
// ---------------------------------------------------------------------------

/// Which way the money moved. Derived from *which template matched*, never
/// from scanning the body for words like "credit" — `PZCREDIT9772829` is a real
/// merchant name that appears in a message beginning "Spent Rs.39791.72", and a
/// keyword scan would book it as income.
enum TxnDirection { debit, credit }

/// One transaction pulled out of an SMS body, before it touches the database.
class ParsedSms {
  const ParsedSms({
    required this.amount,
    required this.paymentType,
    required this.merchant,
    required this.date,
    required this.direction,
    this.reference = '',
    this.templateId = '',
  });

  final double amount;
  final String paymentType;
  final String merchant;
  final DateTime date;
  final TxnDirection direction;

  /// UPI Ref / UTR / Refno when the message carries one, otherwise ''. Part of
  /// the dedupe key, because two same-day payments of the same amount to the
  /// same payee are otherwise indistinguishable (UPI alerts have no clock time).
  final String reference;

  /// Id of the [SmsTemplate] that matched. Diagnostic only.
  final String templateId;

  bool get isCredit => direction == TxnDirection.credit;

  @override
  String toString() => 'ParsedSms($amount, $paymentType, $merchant, '
      '${date.toIso8601String()}, ${direction.name}, $reference, $templateId)';
}

/// One recognised message shape. Every pattern is anchored end to end and uses
/// named groups, so the amount can only ever be captured from its position in
/// the sentence — the trailing "Avl Lmt", "Avl Limit" and "Bal" figures are
/// outside the capture and cannot be picked up by accident.
class SmsTemplate {
  const SmsTemplate({
    required this.id,
    required this.direction,
    required this.pattern,
  });

  final String id;

  /// The single source of truth for spend-vs-receive.
  final TxnDirection direction;

  /// Named groups: `amount`, `instrument`, `merchant`, `date`, optional `ref`.
  final RegExp pattern;
}

// --- Shared pattern fragments ---------------------------------------------

/// Currency prefix. `Rs.122.02` (no space), `Rs. 500.00`, `INR 204.00`, `₹53`.
const String _cur = r'(?:INR|Rs\.?|₹)\s*';

/// `122.02`, `39791.72`, `3,99,614.00` (Indian grouping), `150.0`, `500`.
const String _amt = r'(?<amount>[\d,]+(?:\.\d{1,2})?)';

/// Every date shape seen across issuers, longest first so a shape carrying a
/// time is never truncated to its bare date by an earlier alternative.
/// `_parseDate` reports whether the match actually included a clock time.
const String _date = r'(?<date>'
    r'\d{4}-\d{2}-\d{2}:\d{2}:\d{2}:\d{2}' //          2026-08-13:07:19:26
    r'|\d{1,2}[-/]\d{1,2}[-/]\d{2,4}\s+\d{1,2}:\d{2}:\d{2}\s*(?:am|pm)' // 13-08-2026 09:21:35 am
    r'|\d{1,2}[-/]\d{1,2}[-/]\d{2,4}\s+\d{1,2}:\d{2}:\d{2}' //  11-08-26 12:30:45
    r'|\d{1,2}-[A-Za-z]{3}-\d{2,4}' //                          11-Aug-26
    r'|\d{1,2}[A-Za-z]{3}\d{2,4}' //                            11Aug26
    r'|\d{1,2}[-/]\d{1,2}[-/]\d{2,4}' //                        10/08/26
    r')';

/// Optional "Ref 213313774670" / "Refno 123456789" / "UTR: 123456789" directly
/// after the date. `\s+` rather than `[^\n]*?` so it reaches across the newline
/// in HDFC's one-field-per-line UPI alerts.
const String _ref = r'(?:\s+(?:Ref(?:no)?|UTR)\.?\s*:?\s*(?<ref>\w+))?';

class SmsParser {
  /// Tried in order, first match wins. The four verified shapes come first so
  /// they always win over the broader unverified ones below them.
  static final List<SmsTemplate> templates = <SmsTemplate>[
    // -- Verified against real messages -----------------------------------

    /// `INR 204.00 spent on YES BANK Card X2858 @UPI_GEORGE EGG CENTRE
    ///  13-08-2026 09:21:35 am. Avl Lmt INR 281,496.08.`
    SmsTemplate(
      id: 'yes_card',
      direction: TxnDirection.debit,
      pattern: _re('$_cur$_amt\\s+(?:spent on|debited from)\\s+'
          r'(?<instrument>[^\n]*?)\s+@(?<merchant>[^\n]*?)\s+'
          '$_date'),
    ),

    /// `Spent Rs.122.02 On HDFC Bank Card 6824 At INNOVATIVE RETAIL CONC
    ///  On 2026-08-13:07:19:26.Not You?`
    /// `Spent Rs.39791.72 From HDFC Bank Card x2227 At PZCREDIT9772829
    ///  On 2026-08-11:06:08:24 Bal Rs.210943.42`
    SmsTemplate(
      id: 'hdfc_card',
      direction: TxnDirection.debit,
      pattern: _re('Spent\\s+$_cur$_amt\\s+(?:On|From)\\s+'
          r'(?<instrument>[^\n]*?)\s+At\s+(?<merchant>[^\n]*?)\s+On\s+'
          '$_date'),
    ),

    /// `Sent Rs.18.00 / From HDFC Bank A/C *0444 / To Saravana Medical /
    ///  On 10/08/26 / Ref 213313774670`  — one field per line. `.` does not
    /// cross a newline in Dart but `\s` does, hence `[^\n]*?` captures joined
    /// by `\s+`; the same pattern also matches the flattened single-line form.
    SmsTemplate(
      id: 'hdfc_upi_sent',
      direction: TxnDirection.debit,
      pattern: _re('Sent\\s+$_cur$_amt\\s+From\\s+'
          r'(?<instrument>[^\n]*?)\s+To\s+(?<merchant>[^\n]*?)\s+On\s+'
          '$_date$_ref'),
    ),

    /// `INR 160.00 spent using ICICI Bank Card XX8008 on 11-Aug-26 on
    ///  AMAZON PAY IN G. Avl Limit: INR 3,99,614.00.`
    SmsTemplate(
      id: 'icici_card',
      direction: TxnDirection.debit,
      pattern: _re('$_cur$_amt\\s+spent using\\s+'
          r'(?<instrument>[^\n]*?)\s+on\s+'
          '$_date'
          r'\s+on\s+(?<merchant>[^.\n]*?)\s*(?:[.\n]|$)'),
    ),

    // -- Unverified: written from each issuer's documented wording, not from
    //    a real message. Replace with the genuine body when one turns up.

    /// SBI UPI debit: `Dear UPI user A/C X1234 debited by 150.0 on date
    ///  11Aug26 trf to RAPIDO Refno 123456789`. No currency prefix, and SBI
    /// writes a single decimal place.
    SmsTemplate(
      id: 'sbi_upi_debit',
      direction: TxnDirection.debit,
      pattern: _re(r'(?<instrument>A/[Cc]\s*[Xx*]*\d+)\s+debited\s+by\s+'
          '$_amt'
          r'\s+on\s+date\s+'
          '$_date'
          r'\s+trf\s+to\s+(?<merchant>[^.\n]*?)\s+'
          r'(?:Ref(?:no)?|UTR)\.?\s*:?\s*(?<ref>\w+)'),
    ),

    /// Axis-style debit: `INR 500.00 debited from A/c no. XX1234 on
    ///  11-08-26 12:30:45 at AMAZON. Avl Bal INR 1000`
    SmsTemplate(
      id: 'axis_debit',
      direction: TxnDirection.debit,
      pattern: _re('$_cur$_amt\\s+debited\\s+from\\s+'
          r'(?<instrument>[^\n]*?)\s+on\s+'
          '$_date'
          r'\s+(?:at|to|towards)\s+(?<merchant>[^.\n]*?)\s*(?:[.\n]|$)'),
    ),

    /// Kotak-style card debit: `Rs.500.00 spent on Kotak Bank Card X1234 on
    ///  11-Aug-26 at RAPIDO. Avl Limit Rs.1000`
    SmsTemplate(
      id: 'kotak_card_debit',
      direction: TxnDirection.debit,
      pattern: _re('$_cur$_amt\\s+spent\\s+(?:on|using)\\s+'
          r'(?<instrument>[^\n]*?)\s+on\s+'
          '$_date'
          r'\s+at\s+(?<merchant>[^.\n]*?)\s*(?:[.\n]|$)'),
    ),

    /// `Rs.500.00 credited to HDFC Bank A/c XX0444 from RAPIDO on 11/08/26
    ///  Ref 123456789`
    SmsTemplate(
      id: 'generic_credit_to',
      direction: TxnDirection.credit,
      pattern: _re('$_cur$_amt\\s+(?:has been\\s+)?credited\\s+to\\s+'
          r'(?<instrument>[^\n]*?)\s+(?:from|by)\s+(?<merchant>[^.\n]*?)\s+on\s+'
          '$_date$_ref'),
    ),

    /// `Received Rs.500.00 in HDFC Bank A/c XX0444 from RAPIDO on 11/08/26
    ///  Ref 123456789`
    SmsTemplate(
      id: 'generic_received_in',
      direction: TxnDirection.credit,
      pattern: _re('Received\\s+$_cur$_amt\\s+(?:in|to|into)\\s+'
          r'(?<instrument>[^\n]*?)\s+from\s+(?<merchant>[^.\n]*?)\s+on\s+'
          '$_date$_ref'),
    ),

    /// SBI-style credit: `Your A/c XX1234 is credited with Rs.500 on 11-08-26
    ///  by RAPIDO`
    SmsTemplate(
      id: 'sbi_credit',
      direction: TxnDirection.credit,
      pattern: _re(r'(?<instrument>A/[Cc]\s*[Xx*]*\d+)\s+is\s+credited\s+with\s+'
          '$_cur$_amt'
          r'\s+on\s+'
          '$_date'
          r'\s+by\s+(?<merchant>[^.\n]*?)\s*(?:[.\n]|$)'),
    ),
  ];

  static RegExp _re(String source) => RegExp(source, caseSensitive: false);

  /// Returns `null` when no template matches, which is how OTPs, promos and
  /// statement alerts get filtered out.
  ///
  /// [receivedAt] is when the SMS landed on the device. UPI alerts carry a date
  /// but no clock time; for those the arrival time-of-day is adopted so same-day
  /// rows sort sensibly. Pass nothing (manual paste) and they fall to midnight.
  static ParsedSms? parse(String body, {DateTime? receivedAt}) {
    for (final template in templates) {
      final match = template.pattern.firstMatch(body);
      if (match == null) continue;

      // A template that matches but yields nonsense falls through to the next
      // one rather than rejecting the message outright.
      final amount =
          double.tryParse((_group(match, 'amount') ?? '').replaceAll(',', ''));
      if (amount == null || amount <= 0) continue;

      final stamp = _parseDate(_group(match, 'date') ?? '');
      if (stamp == null) continue;

      final merchant = _normalize(_group(match, 'merchant') ?? '');
      if (merchant.isEmpty) continue;

      final instrument = _normalize(_group(match, 'instrument') ?? '');

      return ParsedSms(
        amount: amount,
        paymentType: instrument.isEmpty ? 'Unknown' : instrument,
        merchant: merchant,
        date: stamp.hasTime
            ? stamp.date
            : _withArrivalTime(stamp.date, receivedAt),
        direction: template.direction,
        reference: _normalize(_group(match, 'ref') ?? ''),
        templateId: template.id,
      );
    }
    return null;
  }

  /// `namedGroup` throws when the pattern has no such group, and `ref` is only
  /// present on some templates.
  static String? _group(RegExpMatch match, String name) =>
      match.groupNames.contains(name) ? match.namedGroup(name) : null;

  /// Trim and collapse runs of whitespace so "GEORGE  EGG CENTRE" and
  /// "GEORGE EGG CENTRE" become the same mapping key.
  static String _normalize(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), ' ');

  /// Keeps the message's own date and borrows only the time of day, and only
  /// when the SMS arrived on that same date — a re-scan of the inbox therefore
  /// reproduces the identical timestamp and stays idempotent.
  static DateTime _withArrivalTime(DateTime date, DateTime? receivedAt) {
    if (receivedAt == null) return date;
    if (receivedAt.year != date.year ||
        receivedAt.month != date.month ||
        receivedAt.day != date.day) {
      return date;
    }
    return DateTime(date.year, date.month, date.day, receivedAt.hour,
        receivedAt.minute, receivedAt.second);
  }

  static const Map<String, int> _months = <String, int>{
    'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
    'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
  };

  /// `yyyy-MM-dd:HH:mm:ss`
  static final RegExp _isoish =
      RegExp(r'^(\d{4})-(\d{2})-(\d{2}):(\d{2}):(\d{2}):(\d{2})$');

  /// `dd-MM-yyyy`, `dd/MM/yy`, each with an optional `HH:mm:ss` and `am`/`pm`.
  static final RegExp _numeric = RegExp(
    r'^(\d{1,2})[-/](\d{1,2})[-/](\d{2,4})'
    r'(?:\s+(\d{1,2}):(\d{2}):(\d{2})\s*(am|pm)?)?$',
    caseSensitive: false,
  );

  /// `11-Aug-26`, `11Aug26`, `11-Aug-2026`, with an optional time.
  static final RegExp _named = RegExp(
    r'^(\d{1,2})-?([A-Za-z]{3})-?(\d{2,4})'
    r'(?:\s+(\d{1,2}):(\d{2}):(\d{2})\s*(am|pm)?)?$',
    caseSensitive: false,
  );

  /// Every date shape in [_date] -> a `DateTime` plus whether the message
  /// actually carried a clock time. Parsed by hand rather than through
  /// `DateFormat` so lowercase "am" and uppercase "AM" both work with no
  /// locale data initialised, and so a two-digit year can be pivoted to 2000+.
  static _Stamp? _parseDate(String raw) {
    final value = raw.trim();

    final iso = _isoish.firstMatch(value);
    if (iso != null) {
      return _build(
        year: int.parse(iso.group(1)!),
        month: int.parse(iso.group(2)!),
        day: int.parse(iso.group(3)!),
        hour: int.parse(iso.group(4)!),
        minute: int.parse(iso.group(5)!),
        second: int.parse(iso.group(6)!),
        hasTime: true,
      );
    }

    final numeric = _numeric.firstMatch(value);
    if (numeric != null) {
      return _fromParts(
        day: numeric.group(1)!,
        month: int.tryParse(numeric.group(2)!),
        year: numeric.group(3)!,
        match: numeric,
      );
    }

    final named = _named.firstMatch(value);
    if (named != null) {
      return _fromParts(
        day: named.group(1)!,
        month: _months[named.group(2)!.toLowerCase()],
        year: named.group(3)!,
        match: named,
      );
    }

    return null;
  }

  /// Shared tail of [_numeric] and [_named]: both put the optional time in
  /// groups 4-7, so the 12-hour conversion lives in one place.
  static _Stamp? _fromParts({
    required String day,
    required int? month,
    required String year,
    required RegExpMatch match,
  }) {
    if (month == null) return null;

    final hasTime = match.group(4) != null;
    var hour = hasTime ? int.parse(match.group(4)!) : 0;
    final meridiem = match.group(7)?.toLowerCase();
    if (meridiem == 'pm' && hour != 12) hour += 12;
    if (meridiem == 'am' && hour == 12) hour = 0;

    final parsedYear = int.parse(year);
    return _build(
      year: parsedYear < 100 ? 2000 + parsedYear : parsedYear,
      month: month,
      day: int.parse(day),
      hour: hour,
      minute: hasTime ? int.parse(match.group(5)!) : 0,
      second: hasTime ? int.parse(match.group(6)!) : 0,
      hasTime: hasTime,
    );
  }

  /// `DateTime` silently rolls over out-of-range values (month 13 becomes
  /// January of the next year), so the ranges are checked before constructing.
  static _Stamp? _build({
    required int year,
    required int month,
    required int day,
    required int hour,
    required int minute,
    required int second,
    required bool hasTime,
  }) {
    if (month < 1 || month > 12) return null;
    if (day < 1 || day > 31) return null;
    if (hour > 23 || minute > 59 || second > 59) return null;
    return _Stamp(
      DateTime(year, month, day, hour, minute, second),
      hasTime: hasTime,
    );
  }
}

/// A parsed timestamp, plus whether the SMS spelled out a clock time or only a
/// calendar date.
class _Stamp {
  const _Stamp(this.date, {required this.hasTime});

  final DateTime date;
  final bool hasTime;
}

// ---------------------------------------------------------------------------
// 2. DATABASE
// ---------------------------------------------------------------------------

class ExpenseCategory {
  const ExpenseCategory({required this.id, required this.name});

  factory ExpenseCategory.fromMap(Map<String, Object?> map) => ExpenseCategory(
        id: map['id'] as int,
        name: map['name'] as String,
      );

  final int id;
  final String name;
}

/// One category/amount line of a split transaction.
///
/// Carries the category *name* as well as its id so a tombstone snapshot and
/// the Deleted screen can render without a join, and so a line still reads
/// correctly if the category is renamed afterwards.
class TxnSplit {
  const TxnSplit({
    required this.categoryId,
    required this.categoryName,
    required this.amount,
  });

  factory TxnSplit.fromMap(Map<String, Object?> map) => TxnSplit(
        categoryId: map['category_id'] as int,
        categoryName: (map['category_name'] ?? map['name']) as String,
        amount: (map['amount'] as num).toDouble(),
      );

  final int categoryId;
  final String categoryName;
  final double amount;

  Map<String, Object?> toJson() => <String, Object?>{
        'category_id': categoryId,
        'name': categoryName,
        'amount': amount,
      };
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

  bool get isUncategorized => categoryName == AppDatabase.uncategorized;

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
            (map['category_name'] as String?) ?? AppDatabase.uncategorized,
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

class AppDatabase {
  AppDatabase._();

  static final AppDatabase instance = AppDatabase._();

  static const String uncategorized = 'Uncategorized';
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
      version: 7,
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
    if ((sum - transaction.amount).abs() > _splitTolerance) {
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

/// One row of the ledger as a filtered view sees it: a transaction, plus only
/// the split lines that survived the filter.
///
/// [amount] is the sum of *those* lines, not the transaction's total, which is
/// what keeps a filtered dashboard honest. Narrow to Grocery and a ₹2,000
/// Amazon order split three ways contributes its ₹1,200 grocery line and
/// nothing else — so the category totals still add up to what was really spent
/// instead of counting the same ₹2,000 under all three of its categories.
class LedgerEntry {
  const LedgerEntry({required this.txn, required this.lines});

  final ExpenseTxn txn;
  final List<TxnSplit> lines;

  double get amount =>
      lines.fold<double>(0, (double sum, TxnSplit l) => sum + l.amount);
}

/// Everything the ledger can be narrowed by — three facets and a search term —
/// as one value.
///
/// Together rather than as four loose fields because they travel together
/// everywhere: the shell holds them, the chip strip reads them, and every
/// change replaces the whole set.
class LedgerFilters {
  const LedgerFilters({
    this.categoryIds = const <int>{},
    this.merchants = const <String>{},
    this.paymentType,
    this.query = '',
  });

  final Set<int> categoryIds;
  final Set<String> merchants;

  /// One card or account at a time, unlike the other two.
  final String? paymentType;

  /// What is typed in the search box. Empty means "not searching" — and because
  /// it is never null, it needs no companion flag the way [paymentType] does.
  final String query;

  bool get isEmpty =>
      categoryIds.isEmpty &&
      merchants.isEmpty &&
      paymentType == null &&
      query.isEmpty;

  /// `clearPaymentType` because passing `paymentType: null` cannot say whether
  /// it means "leave it" or "drop it".
  LedgerFilters copyWith({
    Set<int>? categoryIds,
    Set<String>? merchants,
    String? paymentType,
    String? query,
    bool clearPaymentType = false,
  }) =>
      LedgerFilters(
        categoryIds: categoryIds ?? this.categoryIds,
        merchants: merchants ?? this.merchants,
        paymentType:
            clearPaymentType ? null : (paymentType ?? this.paymentType),
        query: query ?? this.query,
      );
}

/// Narrows the ledger to any combination of categories, merchants, one
/// card/account and a search term, and projects each surviving transaction down
/// to the split lines that matched. A null or empty filter means "everything".
///
/// [query] is matched case-insensitively, as a substring, against the note and
/// the merchant — the only free text a transaction has, one written by the user
/// and one sent by the bank. It decides which *transactions* survive and never
/// which lines do: a search term says nothing about categories, so a split that
/// matches still reports its whole breakdown.
///
/// Pure and top-level so it can be tested without a database behind it.
List<LedgerEntry> applyFilters(
  List<ExpenseTxn> all, {
  Set<int>? categoryIds,
  Set<String>? merchants,
  String? paymentType,
  String? query,
}) {
  final bool byCategory = categoryIds != null && categoryIds.isNotEmpty;
  final bool byMerchant = merchants != null && merchants.isNotEmpty;
  final String needle = (query ?? '').trim().toLowerCase();

  final List<LedgerEntry> entries = <LedgerEntry>[];
  for (final ExpenseTxn t in all) {
    if (paymentType != null && t.paymentType != paymentType) continue;
    if (byMerchant && !merchants.contains(t.merchant)) continue;
    if (needle.isNotEmpty &&
        !t.note.toLowerCase().contains(needle) &&
        !t.merchant.toLowerCase().contains(needle)) {
      continue;
    }

    final List<TxnSplit> lines = byCategory
        ? t.effectiveSplits
            .where((TxnSplit l) => categoryIds.contains(l.categoryId))
            .toList()
        : t.effectiveSplits;
    if (lines.isEmpty) continue;

    entries.add(LedgerEntry(txn: t, lines: lines));
  }
  return entries;
}

/// What [t] contributes to a view narrowed to [categoryIds] — the matching
/// portion of a split, or the full amount when unfiltered or unsplit.
///
/// The tile and the summary both need this so a filtered view never prints or
/// sums the whole of a transaction only part of which matched.
double amountIn(ExpenseTxn t, Set<int>? categoryIds) {
  if (categoryIds == null || categoryIds.isEmpty) return t.amount;
  return t.effectiveSplits
      .where((TxnSplit l) => categoryIds.contains(l.categoryId))
      .fold<double>(0, (double sum, TxnSplit l) => sum + l.amount);
}

/// Spend by category name over an already-filtered view. Debits only — a refund
/// is not spending.
///
/// Iterates split lines, so a transaction split across three categories is
/// attributed to all three rather than landing wholly under whichever one
/// happens to be its dominant line.
Map<String, double> spendByCategory(List<LedgerEntry> entries) {
  final Map<String, double> byCategory = <String, double>{};
  for (final LedgerEntry entry in entries) {
    if (entry.txn.isCredit) continue;
    for (final TxnSplit line in entry.lines) {
      byCategory[line.categoryName] =
          (byCategory[line.categoryName] ?? 0) + line.amount;
    }
  }
  return byCategory;
}

/// Every merchant the ledger has seen that survives *the other* filters,
/// alphabetically.
///
/// The category filter is deliberately applied here and the merchant filter is
/// not — see [categoryOptions] for why.
List<String> merchantOptions(
  List<ExpenseTxn> all, {
  Set<int>? categoryIds,
  String? paymentType,
}) {
  final List<String> merchants = applyFilters(
    all,
    categoryIds: categoryIds,
    paymentType: paymentType,
  ).map((LedgerEntry e) => e.txn.merchant).toSet().toList()
    ..sort();
  return merchants;
}

/// The subset of [all] that something under *the other* filters actually falls
/// under, in the same order — the filter offers these rather than every seeded
/// category, so it can never present a choice that filters to nothing.
///
/// Each facet applies every filter except its own. That is what lets the two
/// constrain each other without either collapsing: picking a merchant narrows
/// the categories on offer, but picking a category must not narrow — and so
/// possibly empty — the merchant list underneath a selection already made in
/// it.
///
/// Expands over split lines, so a category that only ever appears as a minor
/// line of a split is still offered. Matching on the dominant category alone
/// would let the filter hide a choice that would in fact have matched.
List<ExpenseCategory> categoryOptions(
  List<ExpenseTxn> all,
  List<ExpenseCategory> categories, {
  Set<String>? merchants,
  String? paymentType,
}) {
  final Set<int> used = <int>{};
  for (final LedgerEntry entry in applyFilters(
    all,
    merchants: merchants,
    paymentType: paymentType,
  )) {
    for (final TxnSplit line in entry.lines) {
      used.add(line.categoryId);
    }
  }
  return categories.where((ExpenseCategory c) => used.contains(c.id)).toList();
}

/// Drops selections that no longer exist among [available].
///
/// A selection can outlive its data — delete the last transaction on a card and
/// that card is gone from the list — and narrowing one facet can retire options
/// in another.
Set<T> pruneSelection<T>(Set<T> selected, Iterable<T> available) {
  final Set<T> keep = available.toSet();
  return selected.where(keep.contains).toSet();
}

/// The orders the ledger can be read in. [newest] is what the database already
/// hands back, so it is the default and costs nothing.
enum LedgerSort {
  newest('Newest first'),
  oldest('Oldest first'),
  largest('Amount: high to low'),
  smallest('Amount: low to high'),
  merchant('Merchant A–Z');

  const LedgerSort(this.label);

  /// What the chip and the sheet call this order.
  final String label;
}

/// Orders an already-filtered view.
///
/// The amount orders compare [LedgerEntry.amount] — the part of the transaction
/// this row actually shows — rather than the whole charge, so a view narrowed to
/// one category sorts by what it contributed to that category. Sorting by the
/// full amount would put a ₹2,000 order above a ₹1,500 one on the strength of
/// lines the user has filtered out and cannot see.
///
/// Pure and top-level so it can be tested without a database behind it.
List<LedgerEntry> sortEntries(List<LedgerEntry> entries, LedgerSort sort) {
  // A copy: the caller's list is derived per build and reused, and an in-place
  // sort would make the order depend on how many times this had been called.
  final List<LedgerEntry> ordered = List<LedgerEntry>.of(entries);

  // Two rows can tie on whatever is being sorted by — same amount, same
  // merchant — and several share a timestamp to the minute. Date then id
  // settles those, so the order is total and a rebuild cannot reshuffle it.
  int byNewest(LedgerEntry a, LedgerEntry b) {
    final int byDate = b.txn.date.compareTo(a.txn.date);
    return byDate != 0 ? byDate : b.txn.id.compareTo(a.txn.id);
  }

  ordered.sort((LedgerEntry a, LedgerEntry b) {
    // Zero means "these tie on what was asked for", and the fallback decides.
    final int primary = switch (sort) {
      // Reversed whole rather than by date alone, so oldest-first breaks its
      // ties oldest-first too.
      LedgerSort.newest || LedgerSort.oldest => 0,
      LedgerSort.largest => b.amount.compareTo(a.amount),
      LedgerSort.smallest => a.amount.compareTo(b.amount),
      LedgerSort.merchant =>
        a.txn.merchant.toLowerCase().compareTo(b.txn.merchant.toLowerCase()),
    };
    if (primary != 0) return primary;
    return sort == LedgerSort.oldest ? -byNewest(a, b) : byNewest(a, b);
  });
  return ordered;
}

// ---------------------------------------------------------------------------
// MERGING DUPLICATE NAMES — pure, so the folding rules are tested
// ---------------------------------------------------------------------------

/// The two kinds of name a ledger row carries that the banks spell
/// inconsistently, and that can therefore be merged.
enum NameKind {
  merchant('merchant', 'merchant', 'merchants'),
  card('payment_type', 'card / account', 'cards & accounts');

  const NameKind(this.column, this.label, this.plural);

  /// The `kind` written into `name_aliases`, which is also the column it names.
  final String column;

  /// What to call this in a sentence. Spelled out rather than pluralised by
  /// appending an s, which turns "card / account" into "card / accounts".
  final String label;
  final String plural;
}

/// Which labels have been agreed to mean the same thing.
///
/// Resolution is always a single hop. Merging into a name that is itself a
/// merge result re-points the older rows rather than chaining onto them (see
/// [mergePlan]), so there is never a path to follow and never a cycle to
/// guard against.
class NameAliases {
  const NameAliases(this._byKind);

  /// Nothing merged. The state every database starts in.
  static const NameAliases empty = NameAliases(<NameKind, Map<String, String>>{});

  /// alias → canonical, per kind. Aliases are compared case-insensitively, to
  /// match the `COLLATE NOCASE` on the column, so keys are held lower-cased.
  final Map<NameKind, Map<String, String>> _byKind;

  /// Builds from raw `name_aliases` rows.
  factory NameAliases.fromRows(List<Map<String, Object?>> rows) {
    final map = <NameKind, Map<String, String>>{};
    for (final Map<String, Object?> row in rows) {
      final String kindName = row['kind'] as String;
      final NameKind? kind = NameKind.values
          .where((NameKind k) => k.column == kindName)
          .firstOrNull;
      // A kind this build does not know about is skipped rather than crashing
      // the whole ledger load.
      if (kind == null) continue;
      (map[kind] ??= <String, String>{})[(row['alias'] as String).toLowerCase()] =
          row['canonical'] as String;
    }
    return NameAliases(map);
  }

  /// What [raw] is called now, or [raw] itself if it has not been merged.
  String resolve(NameKind kind, String raw) =>
      _byKind[kind]?[raw.toLowerCase()] ?? raw;

  /// Every label folded into [canonical], including [canonical] itself.
  ///
  /// This is what a query has to expand to when it needs the *stored* rows
  /// behind a merged name.
  Set<String> membersOf(NameKind kind, String canonical) => <String>{
        canonical,
        ...?_byKind[kind]
            ?.entries
            .where((MapEntry<String, String> e) => e.value == canonical)
            .map((MapEntry<String, String> e) => e.key),
      };

  /// The alias rows for [kind], as stored. Lower-cased keys.
  Map<String, String> rowsFor(NameKind kind) =>
      Map<String, String>.unmodifiable(
          _byKind[kind] ?? const <String, String>{});

  /// Canonical names that have something folded into them — what the "Merged"
  /// section lists.
  ///
  /// How many labels each covers is deliberately not answered here: one alias
  /// row can stand for two stored spellings that differ only in case, so the
  /// honest count comes from the ledger, not from this table.
  List<String> mergedNames(NameKind kind) =>
      (_byKind[kind]?.values.toSet().toList() ?? <String>[])..sort();
}

/// The alias rows for one kind after folding [members] into [newName].
///
/// Takes and returns the whole `alias → canonical` map so the rewrite is one
/// pure step the caller can simply save.
///
/// Two rules keep resolution single-hop:
///  * anything already pointing at one of [members] is re-pointed at
///    [newName] — merging a merge must carry its earlier members along, or
///    they would surface again the moment their canonical stopped existing;
///  * a row that says nothing — the alias and the canonical are the same
///    string — is dropped. Note that `rapido → RAPIDO` is *not* one of those:
///    keys are lower-cased, so that row is what holds the chosen spelling
///    against the other casing of it.
Map<String, String> mergePlan(
  Map<String, String> existing,
  Set<String> members,
  String newName,
) {
  final Set<String> lowerMembers =
      members.map((String m) => m.toLowerCase()).toSet();
  final plan = <String, String>{};

  for (final MapEntry<String, String> row in existing.entries) {
    // Re-point rather than leave a hop behind.
    final bool pointsAtMerged = lowerMembers.contains(row.value.toLowerCase());
    plan[row.key] = pointsAtMerged ? newName : row.value;
  }
  for (final String member in members) {
    plan[member.toLowerCase()] = newName;
  }

  plan.removeWhere((String alias, String canonical) => alias == canonical);
  return plan;
}

/// Applies [aliases] to every row, then folds merchant spellings that differ
/// only in case onto the most common one.
///
/// A list-level pass rather than a per-row one because "most common spelling"
/// is a fact about the whole ledger. The case fold is not cosmetic: the
/// database already treats `RAPIDO` and `Rapido` as one merchant — the column
/// and the mappings key are both COLLATE NOCASE — so leaving the two apart in
/// Dart means the filter offers a choice the rest of the system cannot honour.
///
/// The stored spellings are kept on [ExpenseTxn.rawMerchant] and
/// [ExpenseTxn.rawPaymentType], because they are still the key that finds the
/// row again.
List<ExpenseTxn> canonicaliseLedger(
  List<ExpenseTxn> rows,
  NameAliases aliases,
) {
  // Tally the post-alias merchant spellings before rewriting anything, so the
  // winner is decided over the whole ledger rather than row by row.
  final counts = <String, Map<String, int>>{};
  for (final ExpenseTxn t in rows) {
    final String merchant = aliases.resolve(NameKind.merchant, t.merchant);
    final byCase = counts[merchant.toLowerCase()] ??= <String, int>{};
    byCase[merchant] = (byCase[merchant] ?? 0) + 1;
  }

  final display = <String, String>{
    for (final MapEntry<String, Map<String, int>> group in counts.entries)
      group.key: (group.value.entries.toList()
            // Count first; alphabetical only to break a tie, so the result
            // does not depend on the order rows came back in.
            ..sort((MapEntry<String, int> a, MapEntry<String, int> b) {
              final int byCount = b.value.compareTo(a.value);
              return byCount != 0 ? byCount : a.key.compareTo(b.key);
            }))
          .first
          .key,
  };

  return <ExpenseTxn>[
    for (final ExpenseTxn t in rows)
      t.copyWith(
        merchant: display[
            aliases.resolve(NameKind.merchant, t.merchant).toLowerCase()],
        paymentType: aliases.resolve(NameKind.card, t.paymentType),
      ),
  ];
}

/// Groups of [names] that look like the same thing under different labels.
///
/// Only ever a suggestion — groups are offered pre-ticked and merged solely on
/// a confirmation, because both heuristics can be wrong: two genuinely
/// different cards can end in the same four digits, and two merchants can
/// squash to the same letters.
///
/// Singletons are not groups, so anything that matched nothing is left out.
List<List<String>> suggestGroups(List<String> names, NameKind kind) {
  final groups = <String, List<String>>{};
  for (final String name in names) {
    final String? key = _suggestionKey(name, kind);
    if (key == null) continue;
    (groups[key] ??= <String>[]).add(name);
  }

  final List<List<String>> out = groups.values
      .where((List<String> group) => group.length > 1)
      .map((List<String> group) => group..sort())
      .toList()
    ..sort((List<String> a, List<String> b) => a.first.compareTo(b.first));
  return out;
}

/// What two labels have to share to be worth suggesting, or null when a name
/// offers nothing to match on.
String? _suggestionKey(String name, NameKind kind) {
  switch (kind) {
    case NameKind.card:
      // The trailing digits are the account. Everything in front of them is
      // the part the templates disagree about — `BANK A/c XX0444`,
      // `HDFC Bank A/C *0444` and `HDFC Bank A/c XX0444` share only the 0444.
      final RegExpMatch? tail =
          RegExp(r'(\d{3,})\D*$').firstMatch(name);
      return tail?.group(1);

    case NameKind.merchant:
      // Case, punctuation, spacing and a leading UPI tag are all noise a bank
      // adds inconsistently: `UPI_GEORGE EGG CENTRE` and `GEORGE EGG CENTRE`
      // are one shop.
      final String squashed = name
          .toLowerCase()
          .replaceFirst(RegExp(r'^upi[\s_-]+'), '')
          .replaceAll(RegExp(r'[^a-z0-9]'), '');
      return squashed.isEmpty ? null : squashed;
  }
}

// ---------------------------------------------------------------------------
// SPLIT ARITHMETIC — pure, so the one fiddly calculation in the app is tested
// ---------------------------------------------------------------------------

/// Paise. Amounts are doubles, so three ways through ₹0.10 cannot land exactly;
/// anything under half a paisa is a rounding artefact rather than a real gap.
const double _splitTolerance = 0.005;

/// How much of [total] the lines have not accounted for. Negative means they
/// have over-allocated it.
double unallocated(List<double> amounts, double total) =>
    total - amounts.fold<double>(0, (double sum, double a) => sum + a);

bool isBalanced(
  List<double> amounts,
  double total, {
  double tolerance = _splitTolerance,
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

/// The longest note that is stored. Generous for the sentence a note actually
/// is, and short enough that no single one can dominate the tile it annotates.
const int _noteMaxLength = 140;

/// What actually gets stored for a typed note: trimmed, inner runs of
/// whitespace collapsed onto single spaces, and capped.
///
/// The collapsing is what makes a pasted two-line note render as one line on
/// the tile without the tile having to know it was ever anything else. Empty
/// out means there is no note — a whitespace-only note is not a note, and
/// storing one would light up the tile's indicator with nothing to show.
String cleanNote(String raw) {
  final String collapsed = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
  return collapsed.length <= _noteMaxLength
      ? collapsed
      : collapsed.substring(0, _noteMaxLength).trimRight();
}

/// What one pass over the inbox did. [skipped] counts alerts that parsed but
/// were already recorded or had been deleted.
class _ScanResult {
  const _ScanResult({required this.added, required this.skipped});

  final int added;
  final int skipped;
}

/// One ledger, one screen: filter it, sort it, categorise, split and delete
/// from it. Settings sits alongside as the only other destination. This shell
/// owns the data and the view over it; the tabs only render what they are
/// handed.
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
  int _tab = 0;

  /// How the ledger is narrowed and ordered. Held here rather than in the tab
  /// because the selection app bar — built here — has to know which rows are on
  /// screen before it can offer to select or delete "all" of them.
  LedgerFilters _filters = const LedgerFilters();
  LedgerSort _sort = LedgerSort.newest;

  /// Ids marked for deletion. Lives here rather than in the tab because the app
  /// bar it takes over is built here.
  final Set<int> _selected = <int>{};

  @override
  void initState() {
    super.initState();
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
      for (final sms in messages) {
        final at = sms.receivedAt;
        if (at != null && (newest == null || at.isAfter(newest))) newest = at;

        final parsed = SmsParser.parse(sms.body, receivedAt: at);
        if (parsed == null) continue; // OTP, promo, statement alert
        final id = await _db.insertParsed(parsed);
        id == 0 ? skipped++ : added++;
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
      return _ScanResult(added: added, skipped: skipped);
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

    _toast(result.added == 0 && result.skipped == 0
        ? 'No new bank messages found.'
        : 'Imported ${result.added} new transaction(s), skipped '
            '${result.skipped} already recorded or deleted.');
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
        : '$verb ${_money.format(parsed.amount)} · ${parsed.merchant}');
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
          maxLength: _noteMaxLength,
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

  /// Bulk delete asks first. The selection bar's delete sits exactly where the
  /// overflow menu is otherwise, so a reach for the menu can land on it — and
  /// unlike a swipe, nothing about tapping an app bar icon says "destructive".
  Future<void> _confirmBulkDelete() async {
    final gone = _transactions
        .where((ExpenseTxn t) => _selected.contains(t.id))
        .toList();
    if (gone.isEmpty) return;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final scheme = Theme.of(dialogContext).colorScheme;
        return AlertDialog(
          title: Text(gone.length == 1
              ? 'Delete this transaction?'
              : 'Delete ${gone.length} transactions?'),
          content: const Text(
            'They stay out of future inbox scans, and can be brought back from '
            'Deleted transactions.',
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
    if (!mounted || !(confirmed ?? false)) return;
    await _delete(gone);
  }

  /// Everything that can be done from one row — categorise, split, merge its
  /// names, delete — in one sheet, so the list itself needs no per-row
  /// controls.
  Future<void> _openTransaction(ExpenseTxn txn) async {
    final action = await showModalBottomSheet<_TxnAction>(
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
      case _TxnAction.categorize:
        await _pickCategory(txn);
      case _TxnAction.note:
        await _editNote(txn);
      case _TxnAction.split:
        await _splitTransaction(txn);
      case _TxnAction.mergeMerchant:
        await _openMerge(NameKind.merchant, txn.merchant);
      case _TxnAction.mergeCard:
        await _openMerge(NameKind.card, txn.paymentType);
      case _TxnAction.delete:
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
        // Unlike the Settings route, this one comes off the Dashboard, which is
        // still underneath and holding the old names.
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

  /// Everything the list and its chips are built from, worked out once per
  /// build: what each facet can still offer, the filters with anything stale
  /// dropped, and the rows that survive them in the chosen order.
  ({
    List<ExpenseCategory> categories,
    List<String> merchants,
    List<String> paymentTypes,
    LedgerFilters filters,
    List<LedgerEntry> visible,
  }) _derive() {
    // Every card and account the ledger has seen. Derived from the loaded rows
    // rather than queried, so it stays in step with the list for free.
    final List<String> paymentTypes = _transactions
        .map((ExpenseTxn t) => t.paymentType)
        .toSet()
        .toList()
      ..sort();

    // Each facet offers what the *other* filters leave available, so the two
    // narrow each other without either being able to empty itself out from
    // under a selection already made in it.
    //
    // The search query is deliberately not one of those filters. It feeds the
    // visible list below and nothing else: were it passed here it would retire
    // facet options as the user typed, and `pruneSelection` would then throw
    // away the category or merchant they had already picked — a keystroke
    // silently clearing a filter, and clearing the search box would not bring
    // it back.
    final List<ExpenseCategory> categories = categoryOptions(
      _transactions,
      _categories,
      merchants: _filters.merchants,
      paymentType: _filters.paymentType,
    );
    final List<String> merchants = merchantOptions(
      _transactions,
      categoryIds: _filters.categoryIds,
      paymentType: _filters.paymentType,
    );

    // A selection can outlive its data — delete the last transaction on a card
    // and that card is gone from the list. Drop anything no longer on offer for
    // this build rather than filtering on a value nothing carries.
    final LedgerFilters filters = LedgerFilters(
      categoryIds: pruneSelection(
        _filters.categoryIds,
        categories.map((ExpenseCategory c) => c.id),
      ),
      merchants: pruneSelection(_filters.merchants, merchants),
      paymentType: paymentTypes.contains(_filters.paymentType)
          ? _filters.paymentType
          : null,
      // Rebuilt field by field, so the query has to be carried explicitly.
      // Nothing prunes it: it is text the user is still typing, not a choice
      // made from a list that the data could retire underneath them.
      query: _filters.query,
    );

    return (
      categories: categories,
      merchants: merchants,
      paymentTypes: paymentTypes,
      filters: filters,
      visible: sortEntries(
        applyFilters(
          _transactions,
          categoryIds: filters.categoryIds,
          merchants: filters.merchants,
          paymentType: filters.paymentType,
          query: filters.query,
        ),
        _sort,
      ),
    );
  }

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
      title: const Text('Dashboard'),
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
  void _selectTab(int index) {
    final bool leavingSettings = _tab == 1 && index != 1;
    setState(() {
      _tab = index;
      // Marks are about rows on the ledger; leaving it drops them.
      _selected.clear();
    });
    if (leavingSettings) _load();
  }

  @override
  Widget build(BuildContext context) {
    final bool onLedger = _tab == 0;
    final bool selecting = _selected.isNotEmpty;
    final view = _derive();

    return PopScope(
      // Back should leave selection mode before it leaves the app.
      canPop: !selecting,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) _clearSelection();
      },
      child: Scaffold(
        appBar: selecting
            ? _selectionAppBar(view.visible)
            : onLedger
                ? _normalAppBar()
                : AppBar(title: const Text('Settings')),
        // IndexedStack rather than a swap, so switching tabs keeps the ledger's
        // scroll position and Settings' loaded state.
        body: IndexedStack(
          index: _tab,
          children: <Widget>[
            DashboardTab(
              entries: view.visible,
              filters: view.filters,
              sort: _sort,
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
          selectedIndex: _tab,
          onDestinationSelected: _selectTab,
          destinations: const <NavigationDestination>[
            NavigationDestination(
              icon: Icon(Icons.dashboard_outlined),
              selectedIcon: Icon(Icons.dashboard),
              label: 'Dashboard',
            ),
            NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'Settings',
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// DASHBOARD TAB — the whole ledger: filtered, sorted, and editable in place
// ---------------------------------------------------------------------------

/// The one screen over the ledger.
///
/// It renders and nothing more: the shell works out which rows survive the
/// filters and in what order, and owns the marks, so that the app bar — which
/// the shell builds — and this list can never disagree about what "all of them"
/// means.
class DashboardTab extends StatelessWidget {
  const DashboardTab({
    super.key,
    required this.entries,
    required this.filters,
    required this.sort,
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

  /// What each facet can still offer under the other two.
  final List<ExpenseCategory> categoryChoices;
  final List<String> merchantChoices;
  final List<String> paymentTypeChoices;

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

  /// Lets the user tick several of [options] at once, returning the new
  /// selection or null if they backed out.
  Future<Set<T>?> _chooseMany<T>(
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

  /// Three filters and an order, two of which take several values at once, do
  /// not fit as dropdowns side by side — and Material has no multi-select one.
  /// A scrolling row of chips that each open a sheet does fit, and matches how
  /// the rest of the app asks for a choice.
  Widget _chipStrip(BuildContext context) {
    return SizedBox(
      height: 56,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
        children: <Widget>[
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
              final Set<int>? picked = await _chooseMany<int>(
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
              final Set<String>? picked = await _chooseMany<String>(
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
              final Set<String>? picked = await _chooseMany<String>(
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
          if (!filters.isEmpty) ...<Widget>[
            const SizedBox(width: 8),
            ActionChip(
              avatar: const Icon(Icons.close, size: 18),
              label: const Text('Clear'),
              onPressed: () => onFiltersChanged(const LedgerFilters()),
            ),
          ],
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
                  child: ledgerIsEmpty
                      ? const _EmptyState()
                      : entries.isEmpty
                          ? _NoMatchState(
                              searching: filters.query.trim().isNotEmpty,
                              onClear: () =>
                                  onFiltersChanged(const LedgerFilters()),
                            )
                          : ListView.builder(
                              // Bottom padding clears the FAB.
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                              itemCount: entries.length + 1,
                              itemBuilder: (context, index) {
                                if (index == 0) {
                                  return _SummaryHeader(
                                    entries: entries,
                                    uncategorizedCount: entries
                                        .where((LedgerEntry e) =>
                                            e.txn.isUncategorized)
                                        .length,
                                    money: money,
                                  );
                                }
                                return _ledgerRow(entries[index - 1], selecting);
                              },
                            ),
                ),
        ),
      ],
    );
  }

  Widget _ledgerRow(LedgerEntry entry, bool selecting) {
    final ExpenseTxn txn = entry.txn;

    // Under a category filter a split shows only the part that matched, but
    // deleting takes the whole transaction. Swipe is the one delete with no
    // confirmation behind it, so it is withheld from rows that are showing
    // less than they would remove; the actions sheet, which prints the full
    // amount at the top, still deletes them.
    final bool partial = entry.amount != txn.amount;

    return Dismissible(
      key: ValueKey<int>(txn.id),
      // Swipe is also off while marking, so a stray gesture can't delete
      // outside the selection flow.
      direction: selecting || partial
          ? DismissDirection.none
          : DismissDirection.endToStart,
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

enum _TxnAction { categorize, note, split, mergeMerchant, mergeCard, delete }

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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
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
              onTap: () => Navigator.pop(context, _TxnAction.categorize),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.sticky_note_2_outlined),
              title: Text(txn.hasNote ? 'Edit note' : 'Add note'),
              subtitle: const Text('Why this one happened'),
              onTap: () => Navigator.pop(context, _TxnAction.note),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.call_split),
              title: Text(txn.isSplit ? 'Edit split' : 'Split'),
              subtitle: const Text('Across several categories'),
              onTap: () => Navigator.pop(context, _TxnAction.split),
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
              onTap: () => Navigator.pop(context, _TxnAction.mergeMerchant),
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
              onTap: () => Navigator.pop(context, _TxnAction.mergeCard),
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
              onTap: () => Navigator.pop(context, _TxnAction.delete),
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

/// Shown when there are transactions but the current filters exclude all of
/// them — distinct from [_EmptyState], which means the ledger itself is empty.
class _NoMatchState extends StatelessWidget {
  const _NoMatchState({required this.onClear, this.searching = false});

  final VoidCallback onClear;

  /// Whether a search term is part of why nothing matched. The button clears
  /// everything either way; this only decides what the screen says the reason
  /// was, so it does not blame the chips for a typo in the search box.
  final bool searching;

  @override
  Widget build(BuildContext context) {
    return ListView(
      // A scrollable child keeps pull-to-refresh working.
      padding: const EdgeInsets.all(32),
      children: <Widget>[
        const SizedBox(height: 100),
        Icon(searching ? Icons.search_off : Icons.filter_alt_off_outlined,
            size: 64, color: Theme.of(context).colorScheme.outline),
        const SizedBox(height: 16),
        Text(
          searching
              ? 'No transactions match this search'
              : 'No transactions match these filters',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 20),
        Center(
          child: FilledButton.tonalIcon(
            onPressed: onClear,
            icon: const Icon(Icons.clear),
            label: Text(searching ? 'Clear search' : 'Clear filters'),
          ),
        ),
      ],
    );
  }
}

class _SummaryHeader extends StatelessWidget {
  const _SummaryHeader({
    required this.entries,
    required this.uncategorizedCount,
    required this.money,
  });

  final List<LedgerEntry> entries;
  final int uncategorizedCount;
  final NumberFormat money;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    var spent = 0.0;
    var received = 0.0;
    for (final entry in entries) {
      // The headline totals add the *entry* amount, which under a category
      // filter is only the part that matched — and which for an unfiltered
      // split is the whole charge, since its lines sum to it by construction.
      if (entry.txn.isCredit) {
        received += entry.amount;
      } else {
        spent += entry.amount;
      }
    }
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
            Text('Total spent', style: theme.textTheme.labelLarge),
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
                            ? AppDatabase.uncategorized
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

/// No transactions at all. Carries no button of its own: the "Paste an SMS"
/// FAB is already on screen, and the toolbar offers the inbox scan.
class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return ListView(
      // A scrollable child keeps pull-to-refresh working on an empty list.
      padding: const EdgeInsets.all(32),
      children: <Widget>[
        const SizedBox(height: 120),
        Icon(Icons.receipt_long_outlined,
            size: 72, color: Theme.of(context).colorScheme.outline),
        const SizedBox(height: 16),
        Text(
          'No transactions yet',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'Scan your SMS inbox, or paste a bank alert to test the parser.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
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
        .where((ExpenseCategory c) => c.name == AppDatabase.uncategorized)
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
                  if (category.name != AppDatabase.uncategorized)
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
                        _SettingsHeader('Merged'),
                        for (final String canonical in merged)
                          _MergedTile(
                            canonical: canonical,
                            labels: _labels[canonical] ?? <String>{},
                            onSeparate: () => _separate(canonical),
                          ),
                        const Divider(height: 32),
                      ],
                      if (suggestions.isNotEmpty) ...<Widget>[
                        _SettingsHeader('Looks like duplicates'),
                        for (final List<String> group in suggestions)
                          _SuggestionCard(
                            group: group,
                            counts: _counts,
                            onMerge: () => _mergeSuggested(group),
                          ),
                        const Divider(height: 32),
                      ],
                      _SettingsHeader('All ${widget.kind.plural}'),
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
                        m.defaultCategoryName == AppDatabase.uncategorized;
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
              _SettingsHeader('Categorization'),
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
                _SettingsHeader('Cleanup'),
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
                const Divider(height: 32),
                _SettingsHeader('Updates'),
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
                _SettingsHeader('About'),
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

class _SettingsHeader extends StatelessWidget {
  const _SettingsHeader(this.label);

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
