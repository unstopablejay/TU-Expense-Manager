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
  });

  factory ExpenseTxn.fromMap(Map<String, Object?> map) => ExpenseTxn(
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
      );

  final int id;
  final double amount;
  final String paymentType;
  final String merchant;
  final DateTime date;
  final int categoryId;
  final String categoryName;
  final TxnDirection direction;
  final String reference;

  bool get isUncategorized => categoryName == AppDatabase.uncategorized;

  bool get isCredit => direction == TxnDirection.credit;
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
      version: 4,
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
        FOREIGN KEY (category_id) REFERENCES categories (id)
      )
    ''');

    await db.execute(_createNaturalKeyIndex);
    await db.execute(_createDeletedTransactions);
    await db.execute(_createAppMeta);

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
        PRIMARY KEY (amount, merchant, date, direction, reference)
      )
    ''';

  /// Key/value scratch space. Currently holds only the inbox scan watermark.
  static const String _createAppMeta = '''
      CREATE TABLE app_meta (
        key   TEXT PRIMARY KEY,
        value TEXT NOT NULL
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
             t.direction, t.reference, c.name AS category_name
      FROM transactions t
      JOIN categories c ON c.id = t.category_id
      ORDER BY t.date DESC, t.id DESC
    ''');
    return rows.map(ExpenseTxn.fromMap).toList();
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

  /// Remembers `merchant -> categoryId` and retroactively re-tags every
  /// existing transaction from that merchant. Returns the number of rows
  /// updated. Both writes share one SQL transaction so the mapping can never
  /// be saved without the backfill.
  Future<int> assignCategory({
    required String merchant,
    required int categoryId,
  }) async {
    final db = await database;
    return db.transaction<int>((txn) async {
      await txn.insert(
        'merchant_mappings',
        <String, Object?>{
          'merchant_name': merchant,
          'category_id': categoryId,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      return txn.update(
        'transactions',
        <String, Object?>{'category_id': categoryId},
        where: 'merchant = ?',
        whereArgs: <Object?>[merchant],
      );
    });
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
  static Map<String, Object?> _naturalKeyOf(ExpenseTxn txn) => <String, Object?>{
        'amount': txn.amount,
        'merchant': txn.merchant,
        'date': txn.date.millisecondsSinceEpoch,
        'direction': txn.direction.name,
        'reference': txn.reference,
      };

  /// The full tombstone row: the natural key plus everything needed to put the
  /// transaction back exactly as it was.
  static Map<String, Object?> _tombstoneOf(ExpenseTxn txn, DateTime at) =>
      <String, Object?>{
        ..._naturalKeyOf(txn),
        'payment_type': txn.paymentType,
        'category_id': txn.categoryId,
        'original_id': txn.id,
        'deleted_at': at.millisecondsSinceEpoch,
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
        await txn.insert(
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
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
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

/// Narrows the ledger to one category and/or one card/account. A null filter
/// means "everything". Pure and top-level so it can be tested without a
/// database behind it.
List<ExpenseTxn> applyFilters(
  List<ExpenseTxn> all, {
  int? categoryId,
  String? paymentType,
}) {
  if (categoryId == null && paymentType == null) return all;
  return all
      .where((ExpenseTxn t) =>
          (categoryId == null || t.categoryId == categoryId) &&
          (paymentType == null || t.paymentType == paymentType))
      .toList();
}

/// The subset of [all] that at least one transaction actually uses, in the same
/// order — the filter dropdown offers these rather than every seeded category,
/// so it can never present a choice that filters to nothing.
///
/// Deliberately takes the *whole* ledger, not the currently filtered view:
/// narrowing to one card must not empty the category dropdown underneath the
/// selection already made in it.
List<ExpenseCategory> categoriesInUse(
  List<ExpenseTxn> transactions,
  List<ExpenseCategory> all,
) {
  final used = transactions.map((ExpenseTxn t) => t.categoryId).toSet();
  return all.where((ExpenseCategory c) => used.contains(c.id)).toList();
}

/// What one pass over the inbox did. [skipped] counts alerts that parsed but
/// were already recorded or had been deleted.
class _ScanResult {
  const _ScanResult({required this.added, required this.skipped});

  final int added;
  final int skipped;
}

/// Two tabs over one ledger: a read-only Dashboard with quick filters, and an
/// Expenses tab where rows can be categorised, deleted, or (eventually) added
/// by hand. This shell owns the data; the tabs only render it.
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

  /// Ids marked on the Expenses tab. Lives here rather than in the tab because
  /// the app bar it takes over is built here.
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
  Future<void> _pickCategory(ExpenseTxn txn) async {
    final chosen = await showModalBottomSheet<ExpenseCategory>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => CategoryPickerSheet(
        merchant: txn.merchant,
        categories: _categories,
        selectedId: txn.isUncategorized ? null : txn.categoryId,
      ),
    );
    if (chosen == null) return;

    final updated = await _db.assignCategory(
      merchant: txn.merchant,
      categoryId: chosen.id,
    );
    await _load();
    _toast('${txn.merchant} → ${chosen.name} '
        '($updated transaction${updated == 1 ? '' : 's'} updated)');
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

  /// Opens the transaction from the read-only dashboard on the tab where it can
  /// actually be changed, with its actions already in reach.
  Future<void> _openTransaction(ExpenseTxn txn) async {
    setState(() => _tab = 1);
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
      case _TxnAction.delete:
        await _delete(<ExpenseTxn>[txn]);
    }
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

  Future<void> _openSettings() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => const SettingsScreen(),
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

  AppBar _selectionAppBar() {
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
            ..addAll(_transactions.map((ExpenseTxn t) => t.id))),
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

  AppBar _normalAppBar({required bool onExpenses}) {
    return AppBar(
      title: Text(onExpenses ? 'Expenses' : 'Dashboard'),
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
        if (onExpenses)
          IconButton(
            tooltip: 'Paste an SMS',
            onPressed: _addSmsManually,
            icon: const Icon(Icons.content_paste_outlined),
          ),
        PopupMenuButton<String>(
          onSelected: (String value) {
            switch (value) {
              case 'rescan':
                _scanFromToolbar(full: true);
              case 'deleted':
                _openDeleted();
              case 'settings':
                _openSettings();
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
            PopupMenuDivider(),
            PopupMenuItem<String>(
              value: 'settings',
              child: Text('Settings'),
            ),
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool onExpenses = _tab == 1;
    final bool selecting = onExpenses && _selected.isNotEmpty;

    return PopScope(
      // Back should leave selection mode before it leaves the app.
      canPop: !selecting,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) _clearSelection();
      },
      child: Scaffold(
        appBar:
            selecting ? _selectionAppBar() : _normalAppBar(onExpenses: onExpenses),
        // IndexedStack rather than a swap, so switching tabs keeps each one's
        // scroll position and the dashboard's filter selections.
        body: IndexedStack(
          index: _tab,
          children: <Widget>[
            DashboardTab(
              transactions: _transactions,
              categories: _categories,
              money: _money,
              dateFormat: _dateFormat,
              loading: _loading,
              onRefresh: _load,
              onTap: _openTransaction,
            ),
            ExpensesTab(
              transactions: _transactions,
              money: _money,
              dateFormat: _dateFormat,
              loading: _loading,
              selected: _selected,
              onRefresh: _load,
              onTap: _pickCategory,
              onToggleSelected: _toggleSelected,
              onDelete: (ExpenseTxn txn) => _delete(<ExpenseTxn>[txn]),
              onAddSms: _addSmsManually,
            ),
          ],
        ),
        floatingActionButton: onExpenses && !selecting
            ? FloatingActionButton.extended(
                // Placeholder. Entering a payment by hand is its own piece of
                // work — this reserves the spot it will live in.
                onPressed: () => _toast('Manual payment entry is coming soon.'),
                icon: const Icon(Icons.add),
                label: const Text('Add payment'),
              )
            : null,
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab,
          onDestinationSelected: (int index) => setState(() {
            _tab = index;
            // Marks belong to the Expenses tab; leaving it drops them.
            _selected.clear();
          }),
          destinations: const <NavigationDestination>[
            NavigationDestination(
              icon: Icon(Icons.dashboard_outlined),
              selectedIcon: Icon(Icons.dashboard),
              label: 'Dashboard',
            ),
            NavigationDestination(
              icon: Icon(Icons.receipt_long_outlined),
              selectedIcon: Icon(Icons.receipt_long),
              label: 'Expenses',
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// DASHBOARD TAB — everything that happened, filtered, read-only
// ---------------------------------------------------------------------------

class DashboardTab extends StatefulWidget {
  const DashboardTab({
    super.key,
    required this.transactions,
    required this.categories,
    required this.money,
    required this.dateFormat,
    required this.loading,
    required this.onRefresh,
    required this.onTap,
  });

  final List<ExpenseTxn> transactions;
  final List<ExpenseCategory> categories;
  final NumberFormat money;
  final DateFormat dateFormat;
  final bool loading;
  final Future<void> Function() onRefresh;

  /// Hands the transaction to the Expenses tab, where it can be changed.
  final void Function(ExpenseTxn) onTap;

  @override
  State<DashboardTab> createState() => _DashboardTabState();
}

class _DashboardTabState extends State<DashboardTab> {
  int? _categoryId;
  String? _paymentType;

  void _clearFilters() => setState(() {
        _categoryId = null;
        _paymentType = null;
      });

  @override
  Widget build(BuildContext context) {
    // Every card and account the ledger has seen. Derived from the loaded rows
    // rather than queried, so it stays in step with the list for free.
    final List<String> paymentTypes = widget.transactions
        .map((ExpenseTxn t) => t.paymentType)
        .toSet()
        .toList()
      ..sort();

    // Only categories something actually falls under, so the dropdown can never
    // offer a choice that filters to nothing.
    final List<ExpenseCategory> categories =
        categoriesInUse(widget.transactions, widget.categories);

    // A selection can outlive its data — delete the last transaction on a card
    // and that card is gone from the list. Fall back to "all" for this build
    // rather than handing the dropdown a value no item carries.
    final String? paymentType =
        paymentTypes.contains(_paymentType) ? _paymentType : null;
    final int? categoryId =
        categories.any((ExpenseCategory c) => c.id == _categoryId)
            ? _categoryId
            : null;

    final List<ExpenseTxn> visible = applyFilters(
      widget.transactions,
      categoryId: categoryId,
      paymentType: paymentType,
    );

    return Column(
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          child: Row(
            children: <Widget>[
              Expanded(
                child: DropdownButtonFormField<int?>(
                  initialValue: categoryId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'Category',
                    border: OutlineInputBorder(),
                  ),
                  items: <DropdownMenuItem<int?>>[
                    const DropdownMenuItem<int?>(
                      child: Text('All categories'),
                    ),
                    for (final ExpenseCategory category in categories)
                      DropdownMenuItem<int?>(
                        value: category.id,
                        child: Text(
                          category.name,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (int? value) =>
                      setState(() => _categoryId = value),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<String?>(
                  initialValue: paymentType,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'Card / account',
                    border: OutlineInputBorder(),
                  ),
                  items: <DropdownMenuItem<String?>>[
                    const DropdownMenuItem<String?>(
                      child: Text('All'),
                    ),
                    for (final String type in paymentTypes)
                      DropdownMenuItem<String?>(
                        value: type,
                        child: Text(type, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  onChanged: (String? value) =>
                      setState(() => _paymentType = value),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: widget.loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: widget.onRefresh,
                  child: widget.transactions.isEmpty
                      ? const _EmptyState()
                      : visible.isEmpty
                          ? _NoMatchState(onClear: _clearFilters)
                          : ListView.builder(
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                              itemCount: visible.length + 1,
                              itemBuilder: (context, index) {
                                if (index == 0) {
                                  return _SummaryHeader(
                                    transactions: visible,
                                    uncategorizedCount: visible
                                        .where((ExpenseTxn t) =>
                                            t.isUncategorized)
                                        .length,
                                    money: widget.money,
                                  );
                                }
                                final txn = visible[index - 1];
                                return _TransactionTile(
                                  txn: txn,
                                  money: widget.money,
                                  dateFormat: widget.dateFormat,
                                  onTap: () => widget.onTap(txn),
                                );
                              },
                            ),
                ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// EXPENSES TAB — the same ledger, but editable
// ---------------------------------------------------------------------------

class ExpensesTab extends StatelessWidget {
  const ExpensesTab({
    super.key,
    required this.transactions,
    required this.money,
    required this.dateFormat,
    required this.loading,
    required this.selected,
    required this.onRefresh,
    required this.onTap,
    required this.onToggleSelected,
    required this.onDelete,
    required this.onAddSms,
  });

  final List<ExpenseTxn> transactions;
  final NumberFormat money;
  final DateFormat dateFormat;
  final bool loading;

  /// Ids currently marked. Non-empty means the list is in selection mode.
  final Set<int> selected;

  final Future<void> Function() onRefresh;
  final void Function(ExpenseTxn) onTap;
  final void Function(ExpenseTxn) onToggleSelected;
  final void Function(ExpenseTxn) onDelete;
  final VoidCallback onAddSms;

  @override
  Widget build(BuildContext context) {
    if (loading) return const Center(child: CircularProgressIndicator());

    final uncategorizedCount =
        transactions.where((ExpenseTxn t) => t.isUncategorized).length;
    final selecting = selected.isNotEmpty;

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: transactions.isEmpty
          ? _EmptyState(onAdd: onAddSms)
          : ListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
              itemCount: transactions.length + 1,
              itemBuilder: (context, index) {
                if (index == 0) {
                  return _SummaryHeader(
                    transactions: transactions,
                    uncategorizedCount: uncategorizedCount,
                    money: money,
                  );
                }
                final txn = transactions[index - 1];
                final tile = _TransactionTile(
                  txn: txn,
                  money: money,
                  dateFormat: dateFormat,
                  selected: selected.contains(txn.id),
                  selecting: selecting,
                  // While marking, a tap toggles rather than categorises.
                  onTap: selecting
                      ? () => onToggleSelected(txn)
                      : () => onTap(txn),
                  onLongPress: () => onToggleSelected(txn),
                );
                return Dismissible(
                  key: ValueKey<int>(txn.id),
                  // Swipe is off while marking, so a stray gesture can't delete
                  // outside the selection flow.
                  direction: selecting
                      ? DismissDirection.none
                      : DismissDirection.endToStart,
                  onDismissed: (_) => onDelete(txn),
                  background: _DismissBackground(),
                  child: tile,
                );
              },
            ),
    );
  }
}

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
// TRANSACTION ACTIONS — what a dashboard tap opens on the Expenses tab
// ---------------------------------------------------------------------------

enum _TxnAction { categorize, delete }

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
            Chip(
              avatar: Icon(categoryIcon(txn.categoryName), size: 18),
              label: Text(txn.categoryName),
              visualDensity: VisualDensity.compact,
            ),
            const Divider(height: 28),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.label_outline),
              title: const Text('Change category'),
              onTap: () => Navigator.pop(context, _TxnAction.categorize),
            ),
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
  const _NoMatchState({required this.onClear});

  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    return ListView(
      // A scrollable child keeps pull-to-refresh working.
      padding: const EdgeInsets.all(32),
      children: <Widget>[
        const SizedBox(height: 100),
        Icon(Icons.filter_alt_off_outlined,
            size: 64, color: Theme.of(context).colorScheme.outline),
        const SizedBox(height: 16),
        Text(
          'No transactions match these filters',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 20),
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
    required this.transactions,
    required this.uncategorizedCount,
    required this.money,
  });

  final List<ExpenseTxn> transactions;
  final int uncategorizedCount;
  final NumberFormat money;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    var spent = 0.0;
    var received = 0.0;
    // Only debits are broken down by category — a refund is not spending.
    final byCategory = <String, double>{};
    for (final txn in transactions) {
      if (txn.isCredit) {
        received += txn.amount;
      } else {
        spent += txn.amount;
        byCategory[txn.categoryName] =
            (byCategory[txn.categoryName] ?? 0) + txn.amount;
      }
    }
    final breakdown = byCategory.entries.toList()
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
              '${transactions.length} transaction'
              '${transactions.length == 1 ? '' : 's'}'
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
    this.onTap,
    this.onLongPress,
    this.selected = false,
    this.selecting = false,
  });

  final ExpenseTxn txn;
  final NumberFormat money;
  final DateFormat dateFormat;

  /// Null where the row is not interactive — `ListTile` renders itself
  /// non-interactive when there is nothing to tap.
  final VoidCallback? onTap;

  /// Starts (or extends) a selection on the Expenses tab. Null elsewhere.
  final VoidCallback? onLongPress;

  /// Marked as part of a selection.
  final bool selected;

  /// The list is in selection mode, so a tap marks rather than categorises.
  final bool selecting;

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
                        ? txn.categoryName
                        // Only promise what a tap will actually do: nothing on
                        // a read-only list, and marking while selecting.
                        : onTap == null || selecting
                            ? AppDatabase.uncategorized
                            : 'Tap to categorize',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: needsCategory
                          ? theme.colorScheme.onErrorContainer
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        trailing: Text(
          txn.isCredit
              ? '+${money.format(txn.amount)}'
              : money.format(txn.amount),
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
            color: txn.isCredit ? creditColor(theme) : null,
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({this.onAdd});

  /// Null on the dashboard, where there is nothing to press.
  final VoidCallback? onAdd;

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
        if (onAdd != null) ...<Widget>[
          const SizedBox(height: 20),
          Center(
            child: FilledButton.tonalIcon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Paste an SMS'),
            ),
          ),
        ],
      ],
    );
  }
}

/// Bottom sheet that picks (or creates) the category for a merchant.
class CategoryPickerSheet extends StatefulWidget {
  const CategoryPickerSheet({
    super.key,
    required this.merchant,
    required this.categories,
    this.selectedId,
  });

  final String merchant;
  final List<ExpenseCategory> categories;
  final int? selectedId;

  @override
  State<CategoryPickerSheet> createState() => _CategoryPickerSheetState();
}

class _CategoryPickerSheetState extends State<CategoryPickerSheet> {
  final TextEditingController _newCategory = TextEditingController();
  bool _creating = false;

  @override
  void dispose() {
    _newCategory.dispose();
    super.dispose();
  }

  Future<void> _createAndSelect() async {
    final name = _newCategory.text.trim();
    if (name.isEmpty || _creating) return;
    setState(() => _creating = true);
    final category = await AppDatabase.instance.addCategory(name);
    if (!mounted) return;
    Navigator.pop(context, category);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Categorize', style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            widget.merchant,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.primary),
          ),
          const SizedBox(height: 4),
          Text(
            'Every past and future transaction from this merchant will use '
            'the category you pick.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final category in widget.categories)
                ChoiceChip(
                  avatar: Icon(categoryIcon(category.name), size: 18),
                  label: Text(category.name),
                  selected: category.id == widget.selectedId,
                  onSelected: (_) => Navigator.pop(context, category),
                ),
            ],
          ),
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
// SETTINGS
// ---------------------------------------------------------------------------

/// Preferences and app information. Two sections today — the update controls
/// and an About block — reached from the kebab menu.
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

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              children: <Widget>[
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
            ),
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
