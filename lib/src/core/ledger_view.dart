/// One build's worth of derived ledger state, shared by both targets.
library;

import 'ledger.dart';
import 'models.dart';

/// What [deriveLedgerView] hands back.
///
/// A typedef rather than a class: records are structural, so the shell can go on
/// reading `view.visible` exactly as it did when this was an inline return type.
typedef LedgerView = ({
  List<YearMonth> months,
  List<ExpenseCategory> categories,
  List<String> merchants,
  List<String> paymentTypes,
  LedgerFilters filters,
  List<LedgerEntry> visible,
});

/// Everything the list and its chips are built from, worked out once per
/// build: what each facet can still offer, the filters with anything stale
/// dropped, and the rows that survive them in the chosen order.
///
/// Top-level and parameterised rather than a method, because the web build has
/// to derive exactly the same view from a snapshot. Two copies of this would
/// drift, and the drift would show up as the two targets disagreeing about
/// which rows a filter leaves on screen.
LedgerView deriveLedgerView({
  required List<ExpenseTxn> transactions,
  required List<ExpenseCategory> allCategories,
  required LedgerFilters requested,
  required YearMonth currentMonth,
  required LedgerSort sort,
}) {
  // Every card and account within the chosen months. Derived from the loaded
  // rows rather than queried, so it stays in step with the list for free.
  final List<String> paymentTypes = applyFilters(
    transactions,
    months: requested.months,
  ).map((LedgerEntry e) => e.txn.paymentType).toSet().toList()
    ..sort();

  // Each facet offers what the *other* filters leave available, so they
  // narrow each other without any one being able to empty itself out from
  // under a selection already made in it.
  //
  // The month is one of those filters, unlike the search query. The reason
  // the query is excluded is a mechanism, not a rule about filters: it is
  // free text changing on every keystroke, so pruning driven by it would
  // destroy a deliberate chip choice with no way back. A month is a discrete,
  // sticky choice from a list — structurally the card facet. And excluding it
  // would break this function's own promise, since in August the category
  // chip would go on offering every category the ledger has ever seen.
  final List<ExpenseCategory> categories = categoryOptions(
    transactions,
    allCategories,
    months: requested.months,
    merchants: requested.merchants,
    paymentType: requested.paymentType,
  );
  final List<String> merchants = merchantOptions(
    transactions,
    months: requested.months,
    categoryIds: requested.categoryIds,
    paymentType: requested.paymentType,
  );
  final List<YearMonth> months = monthOptions(
    transactions,
    current: currentMonth,
    keep: requested.months,
    categoryIds: requested.categoryIds,
    merchants: requested.merchants,
    paymentType: requested.paymentType,
  );

  // A selection can outlive its data — delete the last transaction on a card
  // and that card is gone from the list. Drop anything no longer on offer for
  // this build rather than filtering on a value nothing carries.
  final LedgerFilters filters = LedgerFilters(
    categoryIds: pruneSelection(
      requested.categoryIds,
      categories.map((ExpenseCategory c) => c.id),
    ),
    merchants: pruneSelection(requested.merchants, merchants),
    paymentType: paymentTypes.contains(requested.paymentType)
        ? requested.paymentType
        : null,
    // Carried, never pruned — and this is the load-bearing line of the whole
    // month feature. For the other facets a stale selection means filtering
    // on a value nothing carries. A month matching nothing is not stale:
    // "nothing yet this month" is true, useful, and the right answer on the
    // 1st of every month. Prune it and the set goes empty, and an empty set
    // means *every* month — so asking for one quiet month would show years.
    months: requested.months,
    // Rebuilt field by field, so the query has to be carried explicitly too.
    query: requested.query,
  );

  return (
    months: months,
    categories: categories,
    merchants: merchants,
    paymentTypes: paymentTypes,
    filters: filters,
    visible: sortEntries(
      applyFilters(
        transactions,
        months: filters.months,
        categoryIds: filters.categoryIds,
        merchants: filters.merchants,
        paymentType: filters.paymentType,
        query: filters.query,
      ),
      sort,
    ),
  );
}
