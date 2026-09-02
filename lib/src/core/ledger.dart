/// The ledger as the screens see it: months, filters, ordering and the totals
/// derived from them.
///
/// All pure. `intl` is the only package here — it is pure Dart with a web
/// implementation, and one `DateFormat` spells the month labels.
library;

import 'package:clock/clock.dart';

import 'package:intl/intl.dart';

import 'constants.dart';
import 'models.dart';
import 'splits.dart';

// ---------------------------------------------------------------------------
// PERIODS — the unit both the ledger and the charts are narrowed by
// ---------------------------------------------------------------------------

/// A calendar month, as a value.
///
/// A month is not a point in time and not a range: it is a (year, month) pair.
/// Holding it as a `DateTime` would drag along ten fields that must be promised
/// to be zero and an `isUtc` flag that takes part in equality — so a set built
/// from one source and probed from another would silently match nothing — and
/// would turn "is this in August" into range arithmetic with two boundaries to
/// get wrong. This is two ints and a comparison.
///
/// [==] and [hashCode] are load-bearing beyond the usual: the filter holds a
/// `Set<YearMonth>` and asks it `contains` once per transaction, so getting
/// them wrong does not throw — it renders an empty ledger. Same reason
/// [AppVersion] carries them.
class YearMonth implements Comparable<YearMonth> {
  const YearMonth(this.year, this.month);

  /// The month [date] falls in, read in local time — the same reading the tile
  /// prints, so a charge at half past midnight on the 1st is filed under the
  /// month its own row says it is. Never `toUtc()`: that would move some
  /// transactions a month for no reason the user can see.
  factory YearMonth.fromDate(DateTime date) => YearMonth(date.year, date.month);

  /// [now] is injectable so "the current month" can be tested without waiting
  /// for one.
  factory YearMonth.current([DateTime? now]) =>
      YearMonth.fromDate(now ?? clock.now());

  final int year;

  /// 1–12, as `DateTime` numbers them.
  final int month;

  /// Months since year zero. One number to compare and step by, which is what
  /// keeps December → January from needing a special case anywhere else.
  int get _ordinal => year * 12 + (month - 1);

  /// [count] months later, or earlier when negative.
  YearMonth plus(int count) {
    final int n = _ordinal + count;
    return YearMonth(n ~/ 12, n % 12 + 1);
  }

  /// How many months [other] is after this one. Negative when it is before.
  int monthsUntil(YearMonth other) => other._ordinal - _ordinal;

  bool contains(DateTime date) => date.year == year && date.month == month;

  static final DateFormat _labelFormat = DateFormat('MMM yyyy');

  /// What a chip, a sheet row and a chart axis all call this month.
  String get label => _labelFormat.format(DateTime(year, month));

  @override
  int compareTo(YearMonth other) => _ordinal.compareTo(other._ordinal);

  @override
  bool operator ==(Object other) =>
      other is YearMonth && other.year == year && other.month == month;

  @override
  int get hashCode => Object.hash(year, month);

  @override
  String toString() => label;
}

/// What a period is called in a heading. Empty means the filter is off, which
/// is every month there has ever been.
String periodLabel(Set<YearMonth> months) {
  if (months.isEmpty) return 'All time';
  if (months.length == 1) return months.first.label;
  return '${months.length} months';
}

/// One row of the ledger as a filtered view sees it: a transaction, plus only
/// the split lines that survived the filter.
///
/// [amount] is the sum of *those* lines, not the transaction's total, which is
/// what keeps a filtered ledger honest. Narrow to Grocery and a ₹2,000
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

/// Everything the ledger can be narrowed by — a period, three facets and a
/// search term — as one value.
///
/// Together rather than as five loose fields because they travel together
/// everywhere: the shell holds them, the chip strip reads them, and every
/// change replaces the whole set.
class LedgerFilters {
  const LedgerFilters({
    this.months = const <YearMonth>{},
    this.categoryIds = const <int>{},
    this.merchants = const <String>{},
    this.paymentTypes = const <String>{},
    this.query = '',
  });

  /// Where the ledger opens, and what Clear goes back to.
  ///
  /// The default month lives here rather than inside [applyFilters] on purpose:
  /// the function keeps "no filter means everything", which is what lets every
  /// test of it stay written as it was, and what makes "all months" expressible
  /// at all.
  factory LedgerFilters.defaults(YearMonth current) =>
      LedgerFilters(months: <YearMonth>{current});

  /// Which months are on show. Empty means every month, consistent with
  /// [categoryIds] and [merchants] — but unlike them, empty is *not* where the
  /// app starts. See [isDefaultFor].
  final Set<YearMonth> months;

  final Set<int> categoryIds;
  final Set<String> merchants;
  final Set<String> paymentTypes;

  /// What is typed in the search box. Empty means "not searching" — and because
  /// it is never null, it needs no companion flag the way [paymentType] did.
  final String query;

  bool get isEmpty =>
      months.isEmpty &&
      categoryIds.isEmpty &&
      merchants.isEmpty &&
      paymentTypes.isEmpty &&
      query.isEmpty;

  /// Whether this is the resting state — this month and nothing else — which is
  /// what decides whether there is a Clear worth offering.
  ///
  /// Deliberately not [isEmpty], and the difference matters at both ends. A user
  /// who has widened to *all* months has an empty set and so is `isEmpty`, yet
  /// has very much changed something and must be able to get back. A user
  /// sitting on the current month has a non-empty set and nothing worth
  /// clearing.
  bool isDefaultFor(YearMonth current) =>
      categoryIds.isEmpty &&
      merchants.isEmpty &&
      paymentTypes.isEmpty &&
      query.isEmpty &&
      months.length == 1 &&
      months.contains(current);

  LedgerFilters copyWith({
    Set<YearMonth>? months,
    Set<int>? categoryIds,
    Set<String>? merchants,
    Set<String>? paymentTypes,
    String? query,
  }) =>
      LedgerFilters(
        months: months ?? this.months,
        categoryIds: categoryIds ?? this.categoryIds,
        merchants: merchants ?? this.merchants,
        paymentTypes: paymentTypes ?? this.paymentTypes,
        query: query ?? this.query,
      );
}

/// Narrows the ledger to any combination of months, categories, merchants,
/// cards/accounts and a search term, and projects each surviving transaction down
/// to the split lines that matched. A null or empty filter means "everything".
///
/// [query] is matched case-insensitively, as a substring, against the note and
/// the merchant — the only free text a transaction has, one written by the user
/// and one sent by the bank.
///
/// [months] and [query] and the name facets all decide which *transactions*
/// survive and never which lines do. Only the category filter narrows lines,
/// because it is the only one that says anything about a category: a split that
/// matches on its month still reports its whole breakdown.
///
/// Pure and top-level so it can be tested without a database behind it.
List<LedgerEntry> applyFilters(
  List<ExpenseTxn> all, {
  Set<YearMonth>? months,
  Set<int>? categoryIds,
  Set<String>? merchants,
  Set<String>? paymentTypes,
  String? query,
}) {
  final bool byMonth = months != null && months.isNotEmpty;
  final bool byCategory = categoryIds != null && categoryIds.isNotEmpty;
  final bool byMerchant = merchants != null && merchants.isNotEmpty;
  final bool byPaymentType = paymentTypes != null && paymentTypes.isNotEmpty;
  final String needle = (query ?? '').trim().toLowerCase();

  final List<LedgerEntry> entries = <LedgerEntry>[];
  for (final ExpenseTxn t in all) {
    // First because a month is now nearly always in force, and it is both the
    // cheapest test and by far the most selective one.
    if (byMonth && !months.contains(YearMonth.fromDate(t.date))) continue;
    if (byPaymentType && !paymentTypes.contains(t.paymentType)) continue;
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

class CategoryIdentity {
  const CategoryIdentity(this.name, this.color);
  final String name;
  final int? color;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CategoryIdentity &&
          runtimeType == other.runtimeType &&
          name == other.name;

  @override
  int get hashCode => name.hashCode;
}

/// Spend by category over the whole period — what the doughnut chart plots.
///
/// Credits (income) are left out entirely. A chart of outgoings loses all shape
/// if it has to plot a huge money-in wedge beside them, and the question it
/// answers is what *was* spent, not whether it exceeds what was brought in: it
/// is a breakdown, not a budget. If nothing was spent, the map is empty, which
/// is not the same as a map summing to zero because there was as much income
/// as there was spending.
///
/// Iterates split lines, so a transaction split across three categories is
/// attributed to all three rather than landing wholly under whichever one
/// happens to be its dominant line.
Map<CategoryIdentity, double> spendByCategory(List<LedgerEntry> entries) {
  final Map<CategoryIdentity, double> byCategory = <CategoryIdentity, double>{};
  for (final LedgerEntry entry in entries) {
    if (entry.txn.isCredit) continue;
    for (final TxnSplit line in entry.lines) {
      final key = CategoryIdentity(line.categoryName, line.categoryColor);
      byCategory[key] = (byCategory[key] ?? 0) + line.amount;
    }
  }
  return byCategory;
}

/// Spend by category, per month — what the comparison chart plots.
///
/// Same two rules as [spendByCategory], which it defers to per bucket: credits
/// are left out, and a split is attributed to every category it touches, in the
/// month it happened.
Map<YearMonth, Map<CategoryIdentity, double>> spendByCategoryPerMonth(
  List<LedgerEntry> entries,
) {
  final Map<YearMonth, List<LedgerEntry>> byMonth =
      <YearMonth, List<LedgerEntry>>{};
  for (final LedgerEntry entry in entries) {
    (byMonth[YearMonth.fromDate(entry.txn.date)] ??= <LedgerEntry>[])
        .add(entry);
  }
  return byMonth.map((YearMonth m, List<LedgerEntry> rows) =>
      MapEntry<YearMonth, Map<CategoryIdentity, double>>(m, spendByCategory(rows)));
}

/// Spend by day-of-month, per month — what the trend chart plots.
///
/// Same rule as [spendByCategory]: credits are left out. The inner key is the
/// day of month (1–31), not a `DateTime`, so a trend line can be drawn
/// against a fixed day axis independent of which months were picked, and two
/// months can share an axis without their calendar dates lining up.
Map<YearMonth, Map<int, double>> spendByDayPerMonth(
  List<LedgerEntry> entries,
) {
  final Map<YearMonth, Map<int, double>> byMonth =
      <YearMonth, Map<int, double>>{};
  for (final LedgerEntry entry in entries) {
    if (entry.txn.isCredit) continue;
    final YearMonth month = YearMonth.fromDate(entry.txn.date);
    final Map<int, double> byDay =
        byMonth.putIfAbsent(month, () => <int, double>{});
    final int day = entry.txn.date.day;
    byDay[day] = (byDay[day] ?? 0) + entry.amount;
  }
  return byMonth;
}

/// Spent, received and the row count in one pass, so the header card and the
/// charts on the same screen cannot disagree about the totals.
///
/// Adds the *entry* amount, which under a category filter is only the part that
/// matched — the same rule the summary header has always followed.
({double spent, double received, int count}) periodTotals(
  List<LedgerEntry> entries,
) {
  var spent = 0.0;
  var received = 0.0;
  for (final LedgerEntry entry in entries) {
    if (entry.txn.isCredit) {
      received += entry.amount;
    } else {
      spent += entry.amount;
    }
  }
  return (spent: spent, received: received, count: entries.length);
}

/// The selected months in time order — the series of the comparison chart.
///
/// Deliberately *not* gap-filled. The months here are the ones the user picked
/// to compare, so a month between two of them is not a zero: it is a month they
/// did not ask about, and drawing it as an empty bar would claim no spend where
/// there may well have been plenty.
List<YearMonth> comparedMonths(Set<YearMonth> selected) =>
    selected.toList()..sort();

/// How much spend changed from [a] to [b]: positive means more was spent.
double deltaAmount(double a, double b) => b - a;

/// Percentage change from [a] to [b], or `null` when [a] is zero (no baseline).
double? deltaPercent(double a, double b) =>
    a == 0 ? null : (b - a) / a * 100;

/// One slice of the breakdown: a category, what went to it, and its share of
/// the whole.
class CategorySlice {
  const CategorySlice({
    required this.name,
    this.color,
    required this.amount,
    required this.share,
  });

  final String name;
  final int? color;
  final double amount;

  /// 0–1 of the period's spend. Zero when nothing was spent at all, rather
  /// than a division by zero.
  final double share;
}

/// The name the tail of the breakdown is folded under.
const String kOtherCategory = 'Other';

/// The breakdown as at most [limit] slices, descending: the largest
/// `limit - 1` categories and one "Other" holding everything else.
///
/// A donut with a thirtieth 0.2% sliver is unreadable, which is the whole
/// reason for the cap — but the remainder is shown rather than dropped, so the
/// slices still sum to what was spent and the chart cannot quietly disagree
/// with the total printed above it.
///
/// Nothing is invented: a breakdown already within the cap comes back as it is,
/// with no empty "Other" appended.
List<CategorySlice> topCategories(
  Map<CategoryIdentity, double> byCategory, {
  int limit = 6,
}) {
  final List<MapEntry<CategoryIdentity, double>> ranked = byCategory.entries
      .where((MapEntry<CategoryIdentity, double> e) => e.value > 0)
      .toList()
    ..sort((MapEntry<CategoryIdentity, double> a, MapEntry<CategoryIdentity, double> b) =>
        b.value.compareTo(a.value));
  if (ranked.isEmpty) return const <CategorySlice>[];

  final double total =
      ranked.fold<double>(0, (double sum, MapEntry<CategoryIdentity, double> e) => sum + e.value);
  double shareOf(double amount) => total == 0 ? 0 : amount / total;

  if (ranked.length <= limit) {
    return <CategorySlice>[
      for (final MapEntry<CategoryIdentity, double> e in ranked)
        CategorySlice(name: e.key.name, color: e.key.color, amount: e.value, share: shareOf(e.value)),
    ];
  }

  final List<MapEntry<CategoryIdentity, double>> head = ranked.take(limit - 1).toList();
  final double tail = ranked
      .skip(limit - 1)
      .fold<double>(0, (double sum, MapEntry<CategoryIdentity, double> e) => sum + e.value);
  return <CategorySlice>[
    for (final MapEntry<CategoryIdentity, double> e in head)
      CategorySlice(name: e.key.name, color: e.key.color, amount: e.value, share: shareOf(e.value)),
    CategorySlice(
      name: kOtherCategory,
      amount: tail,
      share: shareOf(tail),
    ),
  ];
}

/// Every merchant the ledger has seen that survives *the other* filters,
/// alphabetically.
///
/// The category filter is deliberately applied here and the merchant filter is
/// not — see [categoryOptions] for why.
List<String> merchantOptions(
  List<ExpenseTxn> all, {
  Set<YearMonth>? months,
  Set<int>? categoryIds,
  Set<String>? paymentTypes,
}) {
  final List<String> merchants = applyFilters(
    all,
    months: months,
    categoryIds: categoryIds,
    paymentTypes: paymentTypes,
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
  Set<YearMonth>? months,
  Set<String>? merchants,
  Set<String>? paymentTypes,
}) {
  final Set<int> used = <int>{};
  for (final LedgerEntry entry in applyFilters(
    all,
    months: months,
    merchants: merchants,
    paymentTypes: paymentTypes,
  )) {
    for (final TxnSplit line in entry.lines) {
      used.add(line.categoryId);
    }
  }
  return categories.where((ExpenseCategory c) => used.contains(c.id)).toList();
}

/// Every card and account the ledger has seen that survives *the other* filters,
/// alphabetically.
///
/// Each facet applies every filter except its own.
List<String> paymentTypeOptions(
  List<ExpenseTxn> all, {
  Set<YearMonth>? months,
  Set<int>? categoryIds,
  Set<String>? merchants,
}) {
  final List<String> paymentTypes = applyFilters(
    all,
    months: months,
    categoryIds: categoryIds,
    merchants: merchants,
  ).map((LedgerEntry e) => e.txn.paymentType).toSet().toList()
    ..sort();
  return paymentTypes;
}

/// The months on offer, newest first — every month the ledger touches under
/// *the other* filters, plus [current] and everything in [keep] whether or not
/// anything falls in them.
///
/// Those two extras are what stop the month filter from eating itself, and they
/// are not a nicety. A month with nothing in it is a legitimate answer —
/// "nothing yet this month" — and on the 1st it is the *default* answer. Derive
/// the list from the data alone and the default option would not exist; the
/// selection would then be pruned away, and an empty month set means *every*
/// month, so asking for one empty month would show the user three years.
///
/// [keep] holds whatever is currently selected, so a user who has navigated
/// back to March can always get to August again.
///
/// Newest first because recent months are the ones anyone wants.
List<YearMonth> monthOptions(
  List<ExpenseTxn> all, {
  required YearMonth current,
  Set<YearMonth> keep = const <YearMonth>{},
  Set<int>? categoryIds,
  Set<String>? merchants,
  Set<String>? paymentTypes,
}) {
  final Set<YearMonth> months = <YearMonth>{
    current,
    ...keep,
    ...applyFilters(
      all,
      categoryIds: categoryIds,
      merchants: merchants,
      paymentTypes: paymentTypes,
    ).map((LedgerEntry e) => YearMonth.fromDate(e.txn.date)),
  };
  return months.toList()..sort((YearMonth a, YearMonth b) => b.compareTo(a));
}

/// Drops selections that no longer exist among [available].
///
/// A selection can outlive its data — delete the last transaction on a card and
/// that card is gone from the list — and narrowing one facet can retire options
/// in another.
///
/// Months are deliberately never put through this — see [monthOptions].
Set<T> pruneSelection<T>(Set<T> selected, Iterable<T> available) {
  final Set<T> keep = available.toSet();
  return selected.where(keep.contains).toSet();
}

/// Why the list has nothing in it — the only thing that decides what the screen
/// says and what it offers to do about it.
enum EmptyReason { ledgerEmpty, search, facets, month }

/// Which of the four to blame.
///
/// The order is the point. A month is always in force now, so it would "explain"
/// every empty list if asked first — and sending someone off to change the month
/// when the real cause is a typo in the search box is worse than saying nothing.
/// So the month is blamed last, only once nothing else is narrowing anything.
EmptyReason emptyReason(
  LedgerFilters filters, {
  required bool ledgerIsEmpty,
}) {
  if (ledgerIsEmpty) return EmptyReason.ledgerEmpty;
  if (filters.query.trim().isNotEmpty) return EmptyReason.search;
  if (filters.categoryIds.isNotEmpty ||
      filters.merchants.isNotEmpty ||
      filters.paymentTypes.isNotEmpty) {
    return EmptyReason.facets;
  }
  return EmptyReason.month;
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

/// What actually gets stored for a typed note: trimmed, inner runs of
/// whitespace collapsed onto single spaces, and capped.
///
/// The collapsing is what makes a pasted two-line note render as one line on
/// the tile without the tile having to know it was ever anything else. Empty
/// out means there is no note — a whitespace-only note is not a note, and
/// storing one would light up the tile's indicator with nothing to show.
String cleanNote(String raw) {
  final String collapsed = raw.trim().replaceAll(RegExp(r'\s+'), ' ');
  return collapsed.length <= kNoteMaxLength
      ? collapsed
      : collapsed.substring(0, kNoteMaxLength).trimRight();
}
