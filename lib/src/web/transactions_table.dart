/// The ledger as a table, for a browser on a real screen.
///
/// The phone's [TransactionsTab] is a column of cards, which is right on a phone
/// and wrong on a 1920px window: one short line of text per transaction, the
/// amount marooned at the far right, filters hidden behind a horizontally
/// scrolling strip of chips that each open a bottom sheet. This is the same
/// ledger, the same filters and the same orders, laid out as the table the data
/// has always been.
///
/// **It is a presentation, not a second implementation.** Every number here comes
/// from the same functions the phone calls — [periodTotals], [spendByCategory],
/// [emptyReason], [LedgerSort] — and the rows arrive already filtered and sorted
/// by [deriveLedgerView] in the shell. Nothing in this file decides what the
/// ledger says; it only decides how it is drawn. That is the line that keeps the
/// two targets from disagreeing about the totals.
///
/// Below [kWideLayoutBreakpoint] this delegates to the phone's own widget. A
/// browser window can be any width, and a second narrow layout would be a third
/// thing to keep in step for no gain.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/constants.dart';
import '../core/ledger.dart';
import '../core/models.dart';
import '../core/splits.dart';
import '../ui_shared/palette.dart';
import '../ui_shared/shared_controls.dart';
import '../ui_shared/transactions_tab.dart';

/// The width at which the table replaces the phone's card list.
///
/// 900 because the five columns plus the actions gutter need roughly 860px before
/// the merchant column starts ellipsising names that matter, and because it is
/// comfortably above every phone in portrait and below every laptop.
const double kWideLayoutBreakpoint = 900;

/// How tall a facet menu may get before it scrolls inside itself.
const double _kMenuMaxHeight = 360;

/// The height of one option in a facet menu.
///
/// Fixed, and fixed *here*, because the menu panel's height is computed from it
/// rather than measured. A `MenuAnchor` asks its contents for an intrinsic height,
/// and a lazily-built list cannot answer that question without building every
/// child â which is the one thing it exists not to do. Giving the panel an exact
/// height instead means the list stays lazy and the menu still sizes itself to
/// however few options there are.
const double _kMenuRowHeight = 44;

/// The ledger screen the browser shows.
///
/// Takes the same props the shell already passed to [TransactionsTab], minus the
/// selection pair — the browser has always passed `selected: {}` and
/// `onToggleSelected: null`, so asking for them here would be asking for two
/// values that can only have one answer.
class WebTransactionsView extends StatelessWidget {
  const WebTransactionsView({
    super.key,
    required this.entries,
    required this.filters,
    required this.sort,
    required this.monthChoices,
    required this.currentMonth,
    required this.categoryChoices,
    required this.merchantChoices,
    required this.paymentTypeChoices,
    required this.money,
    required this.dateFormat,
    required this.loading,
    required this.ledgerIsEmpty,
    required this.onFiltersChanged,
    required this.onSortChanged,
    required this.onRefresh,
    required this.onTap,
    required this.onDelete,
    this.emptyDetail,
  });

  /// The rows to show: already filtered, already in order.
  final List<LedgerEntry> entries;

  final LedgerFilters filters;
  final LedgerSort sort;

  /// What each facet can still offer under the others.
  final List<YearMonth> monthChoices;
  final List<ExpenseCategory> categoryChoices;
  final List<String> merchantChoices;
  final List<String> paymentTypeChoices;

  final YearMonth currentMonth;
  final NumberFormat money;
  final DateFormat dateFormat;
  final bool loading;

  /// Whether the ledger itself is empty, as opposed to filtered down to nothing.
  final bool ledgerIsEmpty;

  final ValueChanged<LedgerFilters> onFiltersChanged;
  final ValueChanged<LedgerSort> onSortChanged;
  final Future<void> Function() onRefresh;

  /// Null means the table is read-only, the same contract [TransactionsTab] has.
  final void Function(ExpenseTxn)? onTap;
  final void Function(ExpenseTxn)? onDelete;

  /// What to say under "No transactions yet" instead of the app's own advice.
  final String? emptyDetail;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          if (constraints.maxWidth < kWideLayoutBreakpoint) {
            // The phone's screen, unchanged. It is already the right answer at
            // this width, and it is still the same widget the phone renders.
            return TransactionsTab(
              entries: entries,
              filters: filters,
              sort: sort,
              monthChoices: monthChoices,
              currentMonth: currentMonth,
              categoryChoices: categoryChoices,
              merchantChoices: merchantChoices,
              paymentTypeChoices: paymentTypeChoices,
              money: money,
              dateFormat: dateFormat,
              loading: loading,
              ledgerIsEmpty: ledgerIsEmpty,
              selected: const <int>{},
              onFiltersChanged: onFiltersChanged,
              onSortChanged: onSortChanged,
              onRefresh: onRefresh,
              onTap: onTap,
              onToggleSelected: null,
              onDelete: onDelete,
              emptyDetail: emptyDetail,
            );
          }

          return Column(
            // Stretch, because a Column centres its children on the cross axis by
            // default and the toolbar and summary strip size themselves to their
            // content. Left at the default they float in the middle of the window
            // with their bottom borders stopping short of both edges, while the
            // table under them goes edge to edge — the two read as different
            // pages.
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _FilterToolbar(
                filters: filters,
                currentMonth: currentMonth,
                monthChoices: monthChoices,
                categoryChoices: categoryChoices,
                merchantChoices: merchantChoices,
                paymentTypeChoices: paymentTypeChoices,
                onFiltersChanged: onFiltersChanged,
              ),
              if (!loading && entries.isNotEmpty)
                _SummaryStrip(
                  entries: entries,
                  period: periodLabel(filters.months),
                  money: money,
                ),
              Expanded(
                child: loading
                    ? const Center(child: CircularProgressIndicator())
                    : entries.isEmpty
                        ? _EmptyState(
                            reason: emptyReason(filters,
                                ledgerIsEmpty: ledgerIsEmpty),
                            months: filters.months,
                            detailOverride: emptyDetail,
                            onClear: () => onFiltersChanged(
                                LedgerFilters.defaults(currentMonth)),
                            onShowAllMonths: () => onFiltersChanged(
                                filters.copyWith(months: const <YearMonth>{})),
                          )
                        : _Table(
                            entries: entries,
                            sort: sort,
                            money: money,
                            dateFormat: dateFormat,
                            onSortChanged: onSortChanged,
                            onTap: onTap,
                            onDelete: onDelete,
                          ),
              ),
            ],
          );
        },
      );
}

// ---------------------------------------------------------------------------
// The column spec
// ---------------------------------------------------------------------------

/// One column of the table.
///
/// The header and every row are laid out from this same list by [_laidOut], so a
/// column cannot end up one width in the header and another in the rows — the
/// failure that makes a hand-rolled table look broken.
class _Column {
  const _Column(
    this.label, {
    this.width,
    this.flex,
    this.numeric = false,
    this.sorts = const <LedgerSort>[],
  }) : assert(width != null || flex != null, 'a column needs a width or a flex');

  final String label;

  /// Fixed width, for the columns whose content has a known size.
  final double? width;

  /// Share of what is left, for the columns that should absorb the window.
  final int? flex;

  /// Right-aligned and tabular. Only the amount.
  final bool numeric;

  /// The orders this column offers, cycled on each click of its header. Empty
  /// means the header does not respond — there is no [LedgerSort] for it.
  final List<LedgerSort> sorts;
}

const List<_Column> _columns = <_Column>[
  // 184 because the app's date format is `dd MMM yyyy · h:mm a` — "17 Aug 2026 ·
  // 11:00 PM", 22 characters. Sized to the format rather than to the word "Date",
  // which is how this column came to be clipping the year off every row.
  _Column('Date', width: 184, sorts: <LedgerSort>[
    LedgerSort.newest,
    LedgerSort.oldest,
  ]),
  _Column('Merchant', flex: 5, sorts: <LedgerSort>[LedgerSort.merchant]),
  _Column('Category', flex: 3),
  _Column('Card / account', flex: 3),
  _Column('Amount', width: 148, numeric: true, sorts: <LedgerSort>[
    LedgerSort.largest,
    LedgerSort.smallest,
  ]),
  // No label: the gutter the hover delete lives in. A column rather than a
  // trailing widget, so it takes width away from the header too and the amounts
  // stay aligned with their heading.
  _Column('', width: 44),
];

/// Puts [cells] under the column spec.
Widget _laidOut(List<Widget> cells) {
  assert(cells.length == _columns.length);
  return Row(
    crossAxisAlignment: CrossAxisAlignment.center,
    children: <Widget>[
      for (int i = 0; i < cells.length; i++)
        if (_columns[i].width case final double width)
          SizedBox(width: width, child: cells[i])
        else
          Expanded(flex: _columns[i].flex!, child: cells[i]),
    ],
  );
}

/// Which way the arrow points for [sort].
///
/// A switch over the enum rather than "index 0 is descending", so adding an order
/// to [LedgerSort] is a compile error here rather than an arrow that quietly
/// points the wrong way.
IconData _arrowFor(LedgerSort sort) => switch (sort) {
      LedgerSort.newest || LedgerSort.largest => Icons.arrow_downward,
      LedgerSort.oldest ||
      LedgerSort.smallest ||
      LedgerSort.merchant =>
        Icons.arrow_upward,
    };

// ---------------------------------------------------------------------------
// The table
// ---------------------------------------------------------------------------

class _Table extends StatelessWidget {
  const _Table({
    required this.entries,
    required this.sort,
    required this.money,
    required this.dateFormat,
    required this.onSortChanged,
    required this.onTap,
    required this.onDelete,
  });

  final List<LedgerEntry> entries;
  final LedgerSort sort;
  final NumberFormat money;
  final DateFormat dateFormat;
  final ValueChanged<LedgerSort> onSortChanged;
  final void Function(ExpenseTxn)? onTap;
  final void Function(ExpenseTxn)? onDelete;

  @override
  Widget build(BuildContext context) => Column(
        children: <Widget>[
          _TableHeader(sort: sort, onSortChanged: onSortChanged),
          Expanded(
            // A browser can select text, and a table of amounts is the one place
            // in this app where someone plainly wants to copy a figure out. The
            // phone's list has no reason to offer it.
            child: SelectionArea(
              child: ListView.builder(
                // Built lazily, unlike a `DataTable`, which lays out every row it
                // is given. A ledger is thousands of rows and only a screenful is
                // ever visible.
                itemCount: entries.length,
                // See the facet menu's list: two scrollables claiming the one
                // inherited controller is an assertion, and an open menu puts a
                // second one on screen.
                primary: false,
                itemBuilder: (BuildContext context, int index) => _TableRow(
                  entry: entries[index],
                  money: money,
                  dateFormat: dateFormat,
                  striped: index.isOdd,
                  onTap: onTap,
                  onDelete: onDelete,
                ),
              ),
            ),
          ),
        ],
      );
}

class _TableHeader extends StatelessWidget {
  const _TableHeader({required this.sort, required this.onSortChanged});

  final LedgerSort sort;
  final ValueChanged<LedgerSort> onSortChanged;

  /// The order a click on [column] should move to: the next one it offers, or its
  /// first if the table is not currently ordered by this column at all.
  LedgerSort _next(_Column column) {
    final int at = column.sorts.indexOf(sort);
    return at == -1
        ? column.sorts.first
        : column.sorts[(at + 1) % column.sorts.length];
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: _laidOut(<Widget>[
        for (final _Column column in _columns)
          _HeaderCell(
            column: column,
            active: column.sorts.contains(sort) ? sort : null,
            onPressed: column.sorts.isEmpty
                ? null
                : () => onSortChanged(_next(column)),
          ),
      ]),
    );
  }
}

class _HeaderCell extends StatelessWidget {
  const _HeaderCell({
    required this.column,
    required this.active,
    required this.onPressed,
  });

  final _Column column;

  /// The order in force, when it is one of this column's. Null otherwise.
  final LedgerSort? active;

  /// Null where the column offers no order, so it renders as a plain label
  /// rather than promising a click that would do nothing.
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final LedgerSort? active = this.active;

    final Widget label = Row(
      mainAxisAlignment:
          column.numeric ? MainAxisAlignment.end : MainAxisAlignment.start,
      children: <Widget>[
        Flexible(
          child: Text(
            column.label.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
              color: active == null
                  ? theme.colorScheme.onSurfaceVariant
                  : theme.colorScheme.primary,
            ),
          ),
        ),
        if (active != null) ...<Widget>[
          const SizedBox(width: 4),
          Icon(_arrowFor(active), size: 14, color: theme.colorScheme.primary),
        ],
      ],
    );

    if (onPressed == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
        child: label,
      );
    }

    return InkWell(
      onTap: onPressed,
      // The whole heading is the target, not just its text — the same size the
      // eye reads it as.
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 14),
        child: label,
      ),
    );
  }
}

class _TableRow extends StatefulWidget {
  const _TableRow({
    required this.entry,
    required this.money,
    required this.dateFormat,
    required this.striped,
    required this.onTap,
    required this.onDelete,
  });

  final LedgerEntry entry;
  final NumberFormat money;
  final DateFormat dateFormat;

  /// Alternating background. At this row height the eye needs help tracking
  /// across five columns, which is the whole reason a ledger is ruled.
  final bool striped;

  final void Function(ExpenseTxn)? onTap;
  final void Function(ExpenseTxn)? onDelete;

  @override
  State<_TableRow> createState() => _TableRowState();
}

class _TableRowState extends State<_TableRow> {
  bool _hovering = false;

  /// The pill's text. A split names its first line and counts the rest —
  /// "Grocery +2" — exactly as the phone's tile does, since the two are showing
  /// the same thing and a second rule would be a second answer.
  String get _categoryLabel {
    final List<TxnSplit> lines = widget.entry.lines;
    if (lines.length <= 1) {
      return lines.isEmpty
          ? widget.entry.txn.categoryName
          : lines.first.categoryName;
    }
    return '${lines.first.categoryName} +${lines.length - 1}';
  }

  String get _categoryIcon {
    final List<TxnSplit> lines = widget.entry.lines;
    if (lines.isEmpty) return widget.entry.txn.categoryIcon;
    if (lines.first.categoryIcon.isNotEmpty) return lines.first.categoryIcon;
    return widget.entry.txn.categoryIcon;
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ExpenseTxn txn = widget.entry.txn;
    final bool needsCategory = txn.isUncategorized;

    // Under a category filter a row shows what it contributed, not what was
    // charged — and a delete would take the whole transaction. So the row that
    // is showing less than a delete would remove does not offer one: the
    // confirmation can say what is going, but not what it was part of. The
    // actions dialog prints the full amount and deletes from there.
    final bool partial = widget.entry.amount != txn.amount;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: InkWell(
        onTap: widget.onTap == null ? null : () => widget.onTap!(txn),
        child: Container(
          decoration: BoxDecoration(
            color: _hovering
                ? theme.colorScheme.primaryContainer.withValues(alpha: 0.35)
                : widget.striped
                    // A wash of the foreground rather than a named surface role:
                    // `surfaceContainerLowest` sits almost on top of the dark
                    // background, so the stripe was invisible in dark mode — the
                    // half of the job it was added to do.
                    ? theme.colorScheme.onSurface.withValues(alpha: 0.035)
                    : null,
            border: Border(
              bottom: BorderSide(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
              ),
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: _laidOut(<Widget>[
            _cell(
              Text(
                widget.dateFormat.format(txn.date),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
            _cell(_merchant(theme, txn)),
            _cell(_categoryPill(theme, needsCategory)),
            _cell(
              Text(
                txn.paymentType,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
            _cell(
              Text(
                txn.isCredit
                    ? '+${widget.money.format(widget.entry.amount)}'
                    : widget.money.format(widget.entry.amount),
                textAlign: TextAlign.right,
                maxLines: 1,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: txn.isCredit ? creditColor(theme) : null,
                  // The reason a table beats a list for money: the decimal points
                  // line up, so the eye can compare magnitudes down the column
                  // without reading a single figure.
                  fontFeatures: const <FontFeature>[
                    FontFeature.tabularFigures(),
                  ],
                ),
              ),
            ),
            // Revealed on hover rather than always drawn: a delete on every row
            // of a dense table is a lot of red, and a lot of ways to misclick.
            widget.onDelete == null || partial
                ? const SizedBox.shrink()
                : Opacity(
                    opacity: _hovering ? 1 : 0,
                    child: IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18),
                      tooltip: 'Delete this transaction',
                      visualDensity: VisualDensity.compact,
                      // Kept interactive while invisible would be a trap; kept
                      // absent would reflow the row on every hover.
                      onPressed:
                          _hovering ? () => widget.onDelete!(txn) : null,
                    ),
                  ),
          ]),
        ),
      ),
    );
  }

  Widget _cell(Widget child) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        child: child,
      );

  /// The merchant, with its note beside it rather than under it — a note costs
  /// the row no height, and an unnoted row looks exactly as it did.
  Widget _merchant(ThemeData theme, ExpenseTxn txn) => Row(
        children: <Widget>[
          Flexible(
            child: Text(
              txn.merchant,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
          if (txn.hasNote) ...<Widget>[
            const SizedBox(width: 8),
            Icon(
              Icons.sticky_note_2_outlined,
              size: 13,
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
      );

  Widget _categoryPill(ThemeData theme, bool needsCategory) {
    final String label = needsCategory ? kUncategorized : _categoryLabel;
    final String? icon = needsCategory ? null : _categoryIcon;
    final Color hue = categoryColor(label, theme.brightness);

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          color: needsCategory
              ? theme.colorScheme.errorContainer
              : hue.withValues(alpha: 0.16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            CategoryAvatar(
              category: label,
              explicitIcon: icon,
              size: 16,
              fontSize: 12,
              iconSize: 12,
              borderRadius: 4,
              backgroundColor: Colors.transparent,
              borderColor: Colors.transparent,
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: needsCategory
                      ? theme.colorScheme.onErrorContainer
                      : theme.colorScheme.onSurface,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// The filter toolbar
// ---------------------------------------------------------------------------

/// Search, period and the three facets, across the top.
///
/// A [Wrap] rather than the phone's horizontally scrolling strip: at this width
/// everything fits on one line, and if it ever does not it reflows onto a second
/// rather than hiding a control past an edge nobody can see.
///
/// The menus hold no state of their own. They read [filters] and report through
/// [onFiltersChanged], so the shell stays the only place a filter lives — which
/// is why ticking a box narrows the table immediately instead of waiting for an
/// Apply button. That button existed on the phone because a bottom sheet covers
/// the list it is filtering; a dropdown does not.
class _FilterToolbar extends StatelessWidget {
  const _FilterToolbar({
    required this.filters,
    required this.currentMonth,
    required this.monthChoices,
    required this.categoryChoices,
    required this.merchantChoices,
    required this.paymentTypeChoices,
    required this.onFiltersChanged,
  });

  final LedgerFilters filters;
  final YearMonth currentMonth;
  final List<YearMonth> monthChoices;
  final List<ExpenseCategory> categoryChoices;
  final List<String> merchantChoices;
  final List<String> paymentTypeChoices;
  final ValueChanged<LedgerFilters> onFiltersChanged;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool atRest = filters.isDefaultFor(currentMonth);

    final YearMonth? onlyMonth =
        filters.months.length == 1 ? filters.months.first : null;

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow.withValues(alpha: 0.35),
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              SizedBox(
                width: 280,
                child: _SearchField(
                  value: filters.query,
                  onChanged: (String q) =>
                      onFiltersChanged(filters.copyWith(query: q)),
                ),
              ),
              if (onlyMonth != null)
                IconButton(
                  tooltip: 'Previous month',
                  icon: const Icon(Icons.chevron_left),
                  visualDensity: VisualDensity.compact,
                  onPressed: () => onFiltersChanged(
                      filters.copyWith(months: <YearMonth>{onlyMonth.plus(-1)})),
                ),
              _FacetMenu<YearMonth>(
                label: 'Date',
                options: monthChoices,
                selected: filters.months,
                optionLabel: (YearMonth m) => m.label,
                showCount: false,
                active: !atRest || filters.months.isEmpty,
                onChanged: (Set<YearMonth> months) =>
                    onFiltersChanged(filters.copyWith(months: months)),
              ),
              if (onlyMonth != null)
                IconButton(
                  tooltip: 'Next month',
                  icon: const Icon(Icons.chevron_right),
                  visualDensity: VisualDensity.compact,
                  onPressed: onlyMonth.compareTo(currentMonth) < 0
                      ? () => onFiltersChanged(
                          filters.copyWith(months: <YearMonth>{onlyMonth.plus(1)}))
                      : null,
                ),
              _FacetMenu<int>(
                label: 'Category',
                options:
                    categoryChoices.map((ExpenseCategory c) => c.id).toList(),
                selected: filters.categoryIds,
                count: filters.categoryIds.length,
                optionLabel: (int id) => _categoryName(id),
                optionLeading: (int id) => CategoryAvatar(
                  category: _categoryName(id),
                  explicitIcon: _categoryIcon(id),
                  size: 20,
                  fontSize: 14,
                  iconSize: 14,
                  borderRadius: 4,
                  backgroundColor: Colors.transparent,
                  borderColor: Colors.transparent,
                ),
                onChanged: (Set<int> picked) =>
                    onFiltersChanged(filters.copyWith(categoryIds: picked)),
              ),
              _FacetMenu<String>(
                label: 'Merchant',
                options: merchantChoices,
                selected: filters.merchants,
                count: filters.merchants.length,
                optionLabel: (String m) => m,
                searchable: true,
                onChanged: (Set<String> picked) =>
                    onFiltersChanged(filters.copyWith(merchants: picked)),
              ),
              _FacetMenu<String>(
                label: 'Card / account',
                options: paymentTypeChoices,
                selected: filters.paymentTypes,
                count: filters.paymentTypes.length,
                optionLabel: (String t) => t,
                onChanged: (Set<String> picked) =>
                    onFiltersChanged(filters.copyWith(paymentTypes: picked)),
              ),
            ],
          ),
          ActiveFiltersBar(
            filters: filters,
            currentMonth: currentMonth,
            categoryChoices: categoryChoices,
            onFiltersChanged: onFiltersChanged,
          ),
        ],
      ),
    );
  }

  String _categoryName(int id) => categoryChoices
      .firstWhere((ExpenseCategory c) => c.id == id,
          orElse: () => const ExpenseCategory(id: -1, name: kUncategorized))
      .name;

  String _categoryIcon(int id) => categoryChoices
      .firstWhere((ExpenseCategory c) => c.id == id,
          orElse: () => const ExpenseCategory(id: -1, name: kUncategorized))
      .icon;
}

/// A facet as a dropdown: a button that says what is picked, and a menu of the
/// options with the picked ones ticked.
class _FacetMenu<T> extends StatefulWidget {
  const _FacetMenu({
    required this.label,
    required this.options,
    required this.selected,
    required this.optionLabel,
    required this.onChanged,
    this.optionLeading,
    this.searchable = false,
    this.single = false,
    this.showCount = true,
    this.count,
    this.active,
  });

  final String label;
  final List<T> options;
  final Set<T> selected;
  final String Function(T) optionLabel;
  final Widget Function(T)? optionLeading;
  final ValueChanged<Set<T>> onChanged;
  final bool searchable;
  final bool single;
  final bool showCount;
  final int? count;
  final bool? active;

  @override
  State<_FacetMenu<T>> createState() => _FacetMenuState<T>();
}

class _FacetMenuState<T> extends State<_FacetMenu<T>> {
  String _query = '';
  final MenuController _controller = MenuController();

  List<T> get _shown {
    final String query = _query.trim().toLowerCase();
    if (query.isEmpty) return widget.options;
    return widget.options
        .where((T o) => widget.optionLabel(o).toLowerCase().contains(query))
        .toList();
  }

  void _toggle(T option) {
    if (widget.single) {
      _controller.close();
      widget.onChanged(
        widget.selected.contains(option) ? <T>{} : <T>{option},
      );
      return;
    }
    final Set<T> next = <T>{...widget.selected};
    if (!next.remove(option)) next.add(option);
    widget.onChanged(next);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool active = widget.active ?? widget.selected.isNotEmpty;
    final int count = widget.count ?? widget.selected.length;

    return MenuAnchor(
      controller: _controller,
      onClose: () {
        if (_query.isNotEmpty) setState(() => _query = '');
      },
      menuChildren: <Widget>[
        SizedBox(
          width: 320,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (widget.searchable)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: TextField(
                    autofocus: true,
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'Find a ${widget.label.toLowerCase()}',
                      prefixIcon: const Icon(Icons.search, size: 18),
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (String q) => setState(() => _query = q),
                  ),
                ),
              if (widget.selected.isNotEmpty)
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: TextButton(
                      onPressed: () => widget.onChanged(<T>{}),
                      child: const Text('Clear'),
                    ),
                  ),
                ),
              if (_shown.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(20),
                  child: Text(
                    widget.options.isEmpty
                        ? 'Nothing to choose from under the current filters.'
                        : 'No match.',
                    style: theme.textTheme.bodySmall,
                  ),
                )
              else
                SizedBox(
                  height:
                      (_shown.length * _kMenuRowHeight).clamp(0, _kMenuMaxHeight),
                  child: ListView.builder(
                    itemExtent: _kMenuRowHeight,
                    primary: false,
                    itemCount: _shown.length,
                    itemBuilder: (BuildContext context, int index) {
                      final T option = _shown[index];
                      final bool on = widget.selected.contains(option);

                      return ListTile(
                        dense: true,
                        leading: widget.single
                            ? Icon(
                                on
                                    ? Icons.radio_button_checked
                                    : Icons.radio_button_unchecked,
                                size: 18,
                              )
                            : Icon(
                                on
                                    ? Icons.check_box
                                    : Icons.check_box_outline_blank,
                                size: 18,
                              ),
                        title: Row(
                          children: <Widget>[
                            if (widget.optionLeading != null) ...<Widget>[
                              widget.optionLeading!(option),
                              const SizedBox(width: 8),
                            ],
                            Expanded(
                              child: Text(
                                widget.optionLabel(option),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        onTap: () => _toggle(option),
                      );
                    },
                  ),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ],
      builder: (BuildContext context, MenuController controller, Widget? _) {
        void onPressed() =>
            controller.isOpen ? controller.close() : controller.open();

        return FilterTriggerButton(
          label: widget.label,
          count: widget.showCount ? count : 0,
          active: active,
          onPressed: onPressed,
        );
      },
    );
  }
}

/// The search box over the ledger, matching notes and merchant names.
///
/// Stateful only because the text has two owners: the shell holds the query in
/// its filters and rebuilds this widget on every keystroke, so a controller
/// rebuilt with it would fight the cursor. It is created once here instead, and
/// [didUpdateWidget] copies in a value that changed somewhere else — Clear all is
/// the only thing that does — while leaving ordinary typing alone.
///
/// The same reasoning, and the same shape, as the phone's field. Copied rather
/// than shared because it is four lines of mechanism around a different-looking
/// box, and the phone's is private to its own file.
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
  Widget build(BuildContext context) => TextField(
        controller: _controller,
        textInputAction: TextInputAction.search,
        onChanged: widget.onChanged,
        decoration: InputDecoration(
          isDense: true,
          hintText: 'Search notes or merchants',
          prefixIcon: const Icon(Icons.search, size: 20),
          // Driven by the shell's value rather than the controller's: this widget
          // repaints when the shell rebuilds, and the shell is what knows the
          // query changed.
          suffixIcon: widget.value.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Clear search',
                  onPressed: () {
                    _controller.clear();
                    widget.onChanged('');
                  },
                ),
          border: const OutlineInputBorder(),
        ),
      );
}

// ---------------------------------------------------------------------------
// The summary strip
// ---------------------------------------------------------------------------

/// The totals, on one line.
///
/// The same figures the phone's summary card shows, from the same [periodTotals]
/// and [spendByCategory] — a fifth of the height, and no longer the first item of
/// the list, so it does not scroll away from the rows it is describing.
class _SummaryStrip extends StatelessWidget {
  const _SummaryStrip({
    required this.entries,
    required this.period,
    required this.money,
  });

  final List<LedgerEntry> entries;

  /// What the figures are the figures *of*.
  final String period;

  final NumberFormat money;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    // The entry amount, which under a category filter is only the part that
    // matched — the rule the summary header has always followed.
    final ({double spent, double received, int count}) totals =
        periodTotals(entries);
    final int uncategorized =
        entries.where((LedgerEntry e) => e.txn.isUncategorized).length;

    // Only debits are broken down: a refund is not spending.
    final List<MapEntry<CategoryIdentity, double>> breakdown =
        spendByCategory(entries).entries.toList()
          ..sort((MapEntry<CategoryIdentity, double> a, MapEntry<CategoryIdentity, double> b) =>
              b.value.compareTo(a.value));

    final Map<String, String> categoryIcons = <String, String>{
      for (final LedgerEntry e in entries) ...<String, String>{
        if (e.txn.categoryIcon.isNotEmpty) e.txn.categoryName: e.txn.categoryIcon,
        for (final TxnSplit l in e.lines)
          if (l.categoryIcon.isNotEmpty) l.categoryName: l.categoryIcon,
      },
    };

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(color: theme.colorScheme.outlineVariant),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Wrap(
        spacing: 22,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          _figure(
            theme,
            '$period · spent',
            money.format(totals.spent),
            theme.colorScheme.primary,
            large: true,
          ),
          if (totals.received > 0) ...<Widget>[
            _figure(theme, 'Received', money.format(totals.received),
                creditColor(theme)),
            _figure(theme, 'Net',
                money.format(totals.spent - totals.received), null),
          ],
          _figure(
            theme,
            totals.count == 1 ? 'Transaction' : 'Transactions',
            '${totals.count}',
            null,
          ),
          if (uncategorized > 0)
            _figure(theme, 'Need a category', '$uncategorized',
                theme.colorScheme.error),
          for (final MapEntry<CategoryIdentity, double> item in breakdown.take(3))
            Chip(
              avatar: CategoryAvatar(
                category: item.key.name,
                explicitIcon: categoryIcons[item.key.name],
                explicitColor: item.key.color,
                size: 18,
                fontSize: 13,
                iconSize: 13,
                borderRadius: 4,
                backgroundColor: Colors.transparent,
                borderColor: Colors.transparent,
              ),
              label: Text('${item.key.name} · ${money.format(item.value)}'),
              visualDensity: VisualDensity.compact,
              side: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
        ],
      ),
    );
  }

  /// A label over its number. Stacked rather than "Label: value", so the eye can
  /// run along the row reading only the figures.
  Widget _figure(
    ThemeData theme,
    String label,
    String value,
    Color? color, {
    bool large = false,
  }) =>
      Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label.toUpperCase(),
            style: theme.textTheme.labelSmall?.copyWith(
              letterSpacing: 0.6,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Text(
            value,
            style: (large
                    ? theme.textTheme.titleLarge
                    : theme.textTheme.titleMedium)
                ?.copyWith(
              fontWeight: FontWeight.bold,
              color: color,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ],
      );
}

// ---------------------------------------------------------------------------
// Empty
// ---------------------------------------------------------------------------

/// The one empty table, saying whichever of the four true things applies.
///
/// The choice between them is [emptyReason] — the same pure function the phone's
/// empty state calls, so the two cannot come to blame different things for the
/// same empty list.
class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.reason,
    required this.months,
    required this.onClear,
    required this.onShowAllMonths,
    this.detailOverride,
  });

  final EmptyReason reason;
  final Set<YearMonth> months;
  final VoidCallback onClear;
  final VoidCallback onShowAllMonths;
  final String? detailOverride;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    final (IconData icon, String title, String? defaultDetail) =
        switch (reason) {
      EmptyReason.ledgerEmpty => (
          Icons.receipt_long_outlined,
          'No transactions yet',
          'Scan your SMS inbox, or paste a bank alert to test the parser.',
        ),
      EmptyReason.search => (
          Icons.search_off,
          'No transactions match this search',
          null,
        ),
      EmptyReason.facets => (
          Icons.filter_alt_off_outlined,
          'No transactions match these filters',
          null,
        ),
      EmptyReason.month => (
          Icons.calendar_month_outlined,
          'Nothing in ${periodLabel(months)} yet',
          'Transactions appear here as your bank texts arrive.',
        ),
    };
    final String? detail = detailOverride ?? defaultDetail;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(icon, size: 56, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text(title, textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium),
            if (detail != null) ...<Widget>[
              const SizedBox(height: 8),
              Text(detail,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 20),
            // An empty *month* gets "Show all months" rather than "Clear
            // filters", because clearing would reset to the very month that is
            // empty — a button that visibly does nothing reads as a bug. An empty
            // ledger gets neither: there is nothing here to widen to.
            if (reason == EmptyReason.month)
              FilledButton.tonalIcon(
                onPressed: onShowAllMonths,
                icon: const Icon(Icons.event_repeat_outlined),
                label: const Text('Show all months'),
              )
            else if (reason != EmptyReason.ledgerEmpty)
              FilledButton.tonalIcon(
                onPressed: onClear,
                icon: const Icon(Icons.clear),
                label: const Text('Clear filters'),
              ),
          ],
        ),
      ),
    );
  }
}
