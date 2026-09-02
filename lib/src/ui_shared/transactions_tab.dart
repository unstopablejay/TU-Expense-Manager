/// The transactions list: the whole ledger, filtered and sorted.
///
/// Stateless and prop-driven like the dashboard, so the web build renders this
/// exact screen from a snapshot. The three write callbacks are the only part
/// that differs between the targets, and a later commit makes them nullable so
/// a read-only list is expressible rather than merely undocumented.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/constants.dart';
import '../core/ledger.dart';
import '../core/models.dart';
import '../core/splits.dart';
import 'palette.dart';
import 'shared_controls.dart';


/// Asks before [count] transactions are deleted. False for a dismissed dialog,
/// so a tap outside is a cancel.
///
/// One function for every route to a delete — the swipe on a row and the bulk
/// delete in the selection bar — so the two cannot end up making different
/// promises about what deleting means. It is a real question in both cases: the
/// rows go out of future inbox scans as well as out of the ledger, which is not
/// something a gesture should be able to do on its own.
Future<bool> confirmDeleteTransactions(BuildContext context, int count) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) {
      final ColorScheme scheme = Theme.of(dialogContext).colorScheme;
      return AlertDialog(
        title: Text(count == 1
            ? 'Delete this transaction?'
            : 'Delete $count transactions?'),
        content: Text(
          '${count == 1 ? 'It stays' : 'They stay'} out of future inbox scans, '
          'and can be brought back from Deleted transactions.',
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
  return confirmed ?? false;
}

/// The screen over the ledger itself. (The Dashboard tab is the same rows as
/// charts; this is the rows.)
///
/// It renders and nothing more: the shell works out which rows survive the
/// filters and in what order, and owns the marks, so that the app bar — which
/// the shell builds — and this list can never disagree about what "all of them"
/// means.
class TransactionsTab extends StatelessWidget {
  const TransactionsTab({
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
    required this.selected,
    required this.onFiltersChanged,
    required this.onSortChanged,
    required this.onRefresh,
    required this.onTap,
    required this.onToggleSelected,
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

  /// The month the app considers "now" — where Clear goes back to, and the
  /// furthest the period stepper will go forward.
  final YearMonth currentMonth;

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

  /// The three ways this list writes. **Null means the list is read-only.**
  ///
  /// Nullable rather than a `readOnly` flag, because a flag would be a second
  /// source of truth — what should `readOnly: true` with a non-null `onDelete`
  /// do? — and because it is already this file's idiom for a tile that does not
  /// act. Filtering, sorting and searching stay available either way: they are
  /// local to the view and useful wherever it is shown.
  final void Function(ExpenseTxn)? onTap;
  final void Function(ExpenseTxn)? onToggleSelected;
  final void Function(ExpenseTxn)? onDelete;

  /// What to say under "No transactions yet" instead of the app's own advice.
  ///
  /// The default tells the reader to scan their SMS inbox, which is true on a
  /// phone and nonsense in a browser.
  final String? emptyDetail;

  /// Three filters and an order, two of which take several values at once, do
  /// not fit as dropdowns side by side — and Material has no multi-select one.
  /// A scrolling row of chips that each open a sheet does fit, and matches how
  /// the rest of the app asks for a choice.
  Widget _chipStrip(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
        children: <Widget>[
          FilterTriggerButton(
            label: 'Sort: ${sort.label}',
            active: false,
            onPressed: () async {
              final LedgerSort? picked = await showModalBottomSheet<LedgerSort>(
                context: context,
                showDragHandle: true,
                builder: (_) => _SortSheet(selected: sort),
              );
              if (picked != null) onSortChanged(picked);
            },
          ),
          const SizedBox(width: 6),
          FilterTriggerButton(
            label: 'Category',
            count: filters.categoryIds.length,
            onPressed: () async {
              final Set<int>? picked = await chooseMany<int>(
                context,
                title: 'Categories',
                options:
                    categoryChoices.map((ExpenseCategory c) => c.id).toList(),
                selected: filters.categoryIds,
                label: (int id) => categoryChoices
                    .firstWhere((ExpenseCategory c) => c.id == id)
                    .name,
                leading: (int id) {
                  final cat = categoryChoices
                      .firstWhere((ExpenseCategory c) => c.id == id);
                  return CategoryAvatar(
                    category: cat.name,
                    explicitIcon: cat.icon,
                    size: 24,
                    fontSize: 16,
                    iconSize: 16,
                    borderRadius: 6,
                  );
                },
              );
              if (picked != null) {
                onFiltersChanged(filters.copyWith(categoryIds: picked));
              }
            },
          ),
          const SizedBox(width: 6),
          FilterTriggerButton(
            label: 'Merchant',
            count: filters.merchants.length,
            onPressed: () async {
              final Set<String>? picked = await chooseMany<String>(
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
          const SizedBox(width: 6),
          FilterTriggerButton(
            label: 'Card / account',
            count: filters.paymentTypes.length,
            onPressed: () async {
              final Set<String>? picked = await chooseMany<String>(
                context,
                title: 'Card / account',
                options: paymentTypeChoices,
                selected: filters.paymentTypes,
                label: (String t) => t,
              );
              if (picked != null) {
                onFiltersChanged(filters.copyWith(paymentTypes: picked));
              }
            },
          ),
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
          PeriodBar(
            months: filters.months,
            options: monthChoices,
            currentMonth: currentMonth,
            onChanged: (Set<YearMonth> m) =>
                onFiltersChanged(filters.copyWith(months: m)),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: _SearchField(
              value: filters.query,
              onChanged: (String q) =>
                  onFiltersChanged(filters.copyWith(query: q)),
            ),
          ),
          _chipStrip(context),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
            child: ActiveFiltersBar(
              filters: filters,
              currentMonth: currentMonth,
              categoryChoices: categoryChoices,
              onFiltersChanged: onFiltersChanged,
            ),
          ),
        ],
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: onRefresh,
                  child: entries.isEmpty
                      ? _EmptyLedgerState(
                          reason: emptyReason(filters,
                              ledgerIsEmpty: ledgerIsEmpty),
                          months: filters.months,
                          onClear: () =>
                              onFiltersChanged(LedgerFilters.defaults(currentMonth)),
                          onShowAllMonths: () => onFiltersChanged(
                              filters.copyWith(months: const <YearMonth>{})),
                          detailOverride: emptyDetail,
                        )
                      : ListView.builder(
                              // Bottom padding clears the FAB.
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 96),
                              itemCount: entries.length + 1,
                              itemBuilder: (context, index) {
                                if (index == 0) {
                                  return _SummaryHeader(
                                    entries: entries,
                                    period: periodLabel(filters.months),
                                    uncategorizedCount: entries
                                        .where((LedgerEntry e) =>
                                            e.txn.isUncategorized)
                                        .length,
                                    money: money,
                                  );
                                }
                                return _ledgerRow(
                                    context, entries[index - 1], selecting);
                              },
                            ),
                ),
        ),
      ],
    );
  }

  Widget _ledgerRow(BuildContext context, LedgerEntry entry, bool selecting) {
    final ExpenseTxn txn = entry.txn;

    // Under a category filter a split shows only the part that matched, but
    // deleting takes the whole transaction. Swipe is withheld from a row that is
    // showing less than it would remove, even with the confirmation behind it:
    // the dialog can say what is going but not what it was part of. The actions
    // sheet prints the full amount at the top and deletes them from there.
    final bool partial = entry.amount != txn.amount;

    return Dismissible(
      key: ValueKey<int>(txn.id),
      // Swipe is also off while marking, so a stray gesture can't delete
      // outside the selection flow.
      // `.none` also covers a read-only list, where onDelete is null. With no
      // direction, neither confirmDismiss nor onDismissed can fire, which is what
      // makes the `!` below safe rather than hopeful.
      direction: selecting || partial || onDelete == null
          ? DismissDirection.none
          : DismissDirection.endToStart,
      // Answered before the row animates out — a false springs it back, and
      // `onDismissed` never runs. The gesture is easy to make by accident on a
      // scrolling list, and what it does outlives the snackbar that offers to
      // undo it.
      confirmDismiss: (_) => confirmDeleteTransactions(context, 1),
      onDismissed: (_) => onDelete!(txn),
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
        // While marking, a tap toggles rather than opens. A null callback stays
        // null, so the tile renders itself non-interactive — which it already
        // knows how to do, and already says the right thing about.
        onTap: switch ((selecting, onToggleSelected, onTap)) {
          (true, final void Function(ExpenseTxn) toggle, _) => () => toggle(txn),
          (false, _, final void Function(ExpenseTxn) open) => () => open(txn),
          _ => null,
        },
        onLongPress: onToggleSelected == null
            ? null
            : () => onToggleSelected!(txn),
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

/// The one empty list, saying whichever of the four true things applies.
///
/// One widget rather than several because the four cases differ only in their
/// words and their buttons, and because the choice between them is [emptyReason]
/// — a pure function that can be tested, unlike a nest of ternaries in a build
/// method.
class _EmptyLedgerState extends StatelessWidget {
  const _EmptyLedgerState({
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

  /// Replaces the advice under the title where the caller knows better.
  ///
  /// The default tells the reader to scan their SMS inbox, which is right on a
  /// phone and wrong anywhere the ledger arrived over a network.
  final String? detailOverride;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final (IconData icon, String title, String? defaultDetail) = switch (reason) {
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

    return ListView(
      // A scrollable child keeps pull-to-refresh working on an empty list.
      padding: const EdgeInsets.all(32),
      children: <Widget>[
        SizedBox(height: reason == EmptyReason.ledgerEmpty ? 120 : 100),
        Icon(icon, size: 64, color: theme.colorScheme.outline),
        const SizedBox(height: 16),
        Text(
          title,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
        if (detail != null) ...<Widget>[
          const SizedBox(height: 8),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ],
        const SizedBox(height: 20),
        // An empty ledger gets no button: the "Add Transaction" FAB is already on
        // screen and the toolbar offers the inbox scan. An empty *month* gets
        // "Show all months" rather than "Clear filters", because clearing would
        // reset to the very month that is empty — a button that visibly does
        // nothing reads as a bug.
        if (reason == EmptyReason.month)
          Center(
            child: FilledButton.tonalIcon(
              onPressed: onShowAllMonths,
              icon: const Icon(Icons.event_repeat_outlined),
              label: const Text('Show all months'),
            ),
          )
        else if (reason != EmptyReason.ledgerEmpty)
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
    required this.entries,
    required this.period,
    required this.uncategorizedCount,
    required this.money,
  });

  final List<LedgerEntry> entries;

  /// What the totals below are the totals *of*. Named on the card rather than
  /// only in the period bar, so a screenshot of it is self-describing.
  final String period;

  final int uncategorizedCount;
  final NumberFormat money;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // The headline totals add the *entry* amount, which under a category filter
    // is only the part that matched — and which for an unfiltered split is the
    // whole charge, since its lines sum to it by construction.
    final totals = periodTotals(entries);
    final double spent = totals.spent;
    final double received = totals.received;

    // Only debits are broken down by category — a refund is not spending.
    final breakdown = spendByCategory(entries).entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final Map<String, String> categoryIcons = <String, String>{
      for (final LedgerEntry e in entries) ...<String, String>{
        if (e.txn.categoryIcon.isNotEmpty) e.txn.categoryName: e.txn.categoryIcon,
        for (final TxnSplit l in e.lines)
          if (l.categoryIcon.isNotEmpty) l.categoryName: l.categoryIcon,
      },
    };

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('$period · Total spent', style: theme.textTheme.labelLarge),
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
                    avatar: CategoryAvatar(
                      category: entry.key.name,
                      explicitIcon: categoryIcons[entry.key.name],
                      explicitColor: entry.key.color,
                      size: 20,
                      fontSize: 14,
                      iconSize: 14,
                      borderRadius: 4,
                      backgroundColor: Colors.transparent,
                      borderColor: Colors.transparent,
                    ),
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
    final Color credColor = creditColor(theme);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: selected
              ? theme.colorScheme.primary
              : theme.colorScheme.outlineVariant.withValues(
                  alpha: theme.brightness == Brightness.dark ? 0.25 : 0.5,
                ),
          width: selected ? 1.5 : 1,
        ),
      ),
      color: selected
          ? theme.colorScheme.primaryContainer.withValues(alpha: 0.6)
          : null,
      child: ListTile(
        onTap: onTap,
        onLongPress: onLongPress,
        selected: selected,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        leading: selected
            ? Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary,
                  borderRadius: BorderRadius.circular(12),
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.check,
                  color: theme.colorScheme.onPrimary,
                  size: 22,
                ),
              )
            : CategoryAvatar(
                category: txn.categoryName,
                explicitIcon: txn.categoryIcon,
                isCredit: txn.isCredit,
                size: 44,
              ),
        title: Text(
          txn.merchant,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const SizedBox(height: 2),
            Text(
              '${txn.paymentType} · ${dateFormat.format(txn.date)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(8),
                    color: needsCategory
                        ? theme.colorScheme.errorContainer
                        : theme.colorScheme.surfaceContainerHighest,
                    border: Border.all(
                      color: needsCategory
                          ? theme.colorScheme.error.withValues(alpha: 0.4)
                          : theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                      width: 0.8,
                    ),
                  ),
                  child: Text(
                    !needsCategory
                        ? _categoryLabel
                        // Only promise what a tap will actually do: nothing on
                        // a read-only list, and marking while selecting.
                        : onTap == null || selecting
                            ? kUncategorized
                            : 'Tap to categorize or split',
                    style: theme.textTheme.labelSmall?.copyWith(
                      fontWeight: FontWeight.w500,
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
              : '-${money.format(shownAmount ?? txn.amount)}',
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
            letterSpacing: -0.3,
            color: txn.isCredit
                ? credColor
                : theme.colorScheme.onSurface,
          ),
        ),
      ),
    );
  }
}
