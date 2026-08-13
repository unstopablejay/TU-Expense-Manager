import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
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
      version: 2,
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

  /// v1 predates any notion of spend-vs-receive, so every existing row is a
  /// debit with no reference — which is exactly what the column defaults say.
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
  /// Returns the new row id, or 0 when the SMS was a duplicate.
  ///
  /// Credits go through the same mapping lookup on purpose — a refund from
  /// AMAZON landing back in Shopping is the useful behaviour.
  Future<int> insertParsed(ParsedSms sms) async {
    final db = await database;

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

  /// One-off import of everything already sitting in the inbox.
  Future<List<InboxSms>> readInbox() async {
    if (!isSupported) return const <InboxSms>[];
    try {
      final messages = await _telephony.getInboxSms(
        columns: <SmsColumn>[SmsColumn.ADDRESS, SmsColumn.BODY, SmsColumn.DATE],
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
// 4. UI
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
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final AppDatabase _db = AppDatabase.instance;
  final SmsSource _sms = SmsSource();

  final NumberFormat _money =
      NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 2);
  final DateFormat _dateFormat = DateFormat('dd MMM yyyy · h:mm a');

  List<ExpenseTxn> _transactions = <ExpenseTxn>[];
  List<ExpenseCategory> _categories = <ExpenseCategory>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    _startListening();
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

  Future<void> _startListening() async {
    if (!_sms.isSupported) return;
    final granted = await _sms.requestPermission();
    if (!granted) return;
    _sms.listen((InboxSms sms) async {
      final parsed = SmsParser.parse(sms.body, receivedAt: sms.receivedAt);
      if (parsed == null) return; // not a transaction alert
      await _db.insertParsed(parsed);
      await _load();
    });
  }

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
        ? 'Already recorded: ${parsed.merchant}'
        : '$verb ${_money.format(parsed.amount)} · ${parsed.merchant}');
  }

  Future<void> _scanInbox() async {
    if (!_sms.isSupported) {
      _toast('Inbox scanning is only available on Android.');
      return;
    }
    final granted = await _sms.requestPermission();
    if (!granted) {
      _toast('SMS permission denied.');
      return;
    }

    final messages = await _sms.readInbox();
    var added = 0;
    var skipped = 0;
    for (final sms in messages) {
      final parsed = SmsParser.parse(sms.body, receivedAt: sms.receivedAt);
      if (parsed == null) continue;
      final id = await _db.insertParsed(parsed);
      id == 0 ? skipped++ : added++;
    }
    await _load();
    _toast('Imported $added new transaction(s), skipped $skipped duplicate(s).');
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

  @override
  Widget build(BuildContext context) {
    final uncategorizedCount =
        _transactions.where((ExpenseTxn t) => t.isUncategorized).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Expenses'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Scan SMS inbox',
            onPressed: _scanInbox,
            icon: const Icon(Icons.sms_outlined),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addSmsManually,
        icon: const Icon(Icons.add),
        label: const Text('Add SMS'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _transactions.isEmpty
                  ? _EmptyState(onAdd: _addSmsManually)
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                      itemCount: _transactions.length + 1,
                      itemBuilder: (context, index) {
                        if (index == 0) {
                          return _SummaryHeader(
                            transactions: _transactions,
                            uncategorizedCount: uncategorizedCount,
                            money: _money,
                          );
                        }
                        final txn = _transactions[index - 1];
                        return _TransactionTile(
                          txn: txn,
                          money: _money,
                          dateFormat: _dateFormat,
                          onTap: () => _pickCategory(txn),
                        );
                      },
                    ),
            ),
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
    required this.onTap,
  });

  final ExpenseTxn txn;
  final NumberFormat money;
  final DateFormat dateFormat;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final needsCategory = txn.isUncategorized;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        leading: CircleAvatar(
          backgroundColor: needsCategory
              ? theme.colorScheme.errorContainer
              : theme.colorScheme.secondaryContainer,
          foregroundColor: needsCategory
              ? theme.colorScheme.onErrorContainer
              : theme.colorScheme.onSecondaryContainer,
          child: Icon(
            txn.isCredit ? Icons.south_west : categoryIcon(txn.categoryName),
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
                    needsCategory ? 'Tap to categorize' : txn.categoryName,
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
  const _EmptyState({required this.onAdd});

  final VoidCallback onAdd;

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
        const SizedBox(height: 20),
        Center(
          child: FilledButton.tonalIcon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('Paste an SMS'),
          ),
        ),
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
