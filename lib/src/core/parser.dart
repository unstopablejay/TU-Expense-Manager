/// Turning a bank SMS body into a transaction.
///
/// Pure: one ordered list of anchored regexes, tried top to bottom, first match
/// wins. Nothing here recognises a bank — the issuer text is captured, never
/// matched on.
library;

/// A real YES Bank credit card alert, used to prefill the manual-entry dialog
/// so the whole pipeline can be exercised without SMS permission.
const String kSampleSms =
    'INR 204.00 spent on YES BANK Card X2858 @UPI_GEORGE EGG CENTRE '
    '13-08-2026 09:21:35 am. Avl Lmt INR 281,496.08. '
    'SMS BLKCC 2858 to 9840909000 if not you';


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
    r'|\d{1,2}[-/]\d{1,2}[-/]\d{2,4}\s+(?:at\s+)?\d{1,2}:\d{2}(?::\d{2})?\s*(?:am|pm)?' // 13-08-2026 09:21:35 am, 23-08-2026 10:29 am
    r'|\d{1,2}-[A-Za-z]{3}-\d{2,4}\s+(?:at\s+)?\d{1,2}:\d{2}(?::\d{2})?\s*(?:am|pm)?' // 11-Aug-26 12:30 pm
    r'|\d{1,2}[A-Za-z]{3}\d{2,4}\s+(?:at\s+)?\d{1,2}:\d{2}(?::\d{2})?\s*(?:am|pm)?' // 11Aug26 12:30 pm
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
    /// `INR 750.00 spent on YES BANK Card X2858 @UPI_VALLI A 23-08-2026 10:29:37 am.`
    SmsTemplate(
      id: 'yes_card',
      direction: TxnDirection.debit,
      pattern: _re('$_cur$_amt\\s+(?:spent on|debited from)\\s+'
          r'(?<instrument>[^\n]*?)\s+(?:@|at|to)\s*(?<merchant>[^\n]*?)\s+'
          r'(?:on\s+)?'
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
          r'(?<instrument>[^\n]*?)\s+(?:At|@|to)\s*(?<merchant>[^\n]*?)\s+'
          r'(?:On\s+)?'
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
          r'(?<instrument>[^\n]*?)\s+(?:To|@|at)\s*(?<merchant>[^\n]*?)\s+'
          r'(?:On\s+)?'
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
          r'\s+(?:on|at|@|for)\s+(?<merchant>[^.\n]*?)\s*(?:[.\n]|$)'),
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
          r'\s+(?:on\s+date|on)\s+'
          '$_date'
          r'\s+(?:trf\s+to|to|at|@)\s+(?<merchant>[^.\n]*?)\s+'
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
          r'\s+(?:at|to|towards|@)\s+(?<merchant>[^.\n]*?)\s*(?:[.\n]|$)'),
    ),

    /// Kotak-style card debit: `Rs.500.00 spent on Kotak Bank Card X1234 on
    ///  11-Aug-26 at RAPIDO. Avl Limit Rs.1000`
    SmsTemplate(
      id: 'kotak_card_debit',
      direction: TxnDirection.debit,
      pattern: _re('$_cur$_amt\\s+spent\\s+(?:on|using)\\s+'
          r'(?<instrument>[^\n]*?)\s+on\s+'
          '$_date'
          r'\s+(?:at|to|@|towards)\s+(?<merchant>[^.\n]*?)\s*(?:[.\n]|$)'),
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
          r'(?<instrument>[^\n]*?)\s+(?:from|by)\s+(?<merchant>[^.\n]*?)\s+on\s+'
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
          r'\s+(?:by|from)\s+(?<merchant>[^.\n]*?)\s*(?:[.\n]|$)'),
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

  /// `dd-MM-yyyy`, `dd/MM/yy`, each with an optional `HH:mm[:ss]` and `am`/`pm`.
  static final RegExp _numeric = RegExp(
    r'^(\d{1,2})[-/](\d{1,2})[-/](\d{2,4})'
    r'(?:\s+(?:at\s+)?(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(am|pm)?)?$',
    caseSensitive: false,
  );

  /// `11-Aug-26`, `11Aug26`, `11-Aug-2026`, with an optional `HH:mm[:ss]` and `am`/`pm`.
  static final RegExp _named = RegExp(
    r'^(\d{1,2})-?([A-Za-z]{3})-?(\d{2,4})'
    r'(?:\s+(?:at\s+)?(\d{1,2}):(\d{2})(?::(\d{2}))?\s*(am|pm)?)?$',
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
      second: (hasTime && match.group(6) != null)
          ? int.parse(match.group(6)!)
          : 0,
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
