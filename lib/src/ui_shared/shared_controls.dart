import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/ledger.dart';
import '../core/models.dart';


/// Lets the user tick several of [options] at once, returning the new selection
/// or null if they backed out.
///
/// Top-level rather than a method on one tab, because both tabs ask this same
/// question and a second copy would be a second thing to keep in step.
Future<Set<T>?> chooseMany<T>(
  BuildContext context, {
  required String title,
  required List<T> options,
  required Set<T> selected,
  required String Function(T) label,
  Widget Function(T)? leading,
  bool single = false,
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
        single: single,
      ),
    );

/// How many months may be compared at once. Past this the bars are too thin to
/// read, and the legend longer than the chart.
const int kMaxComparedMonths = 6;

/// The period control: which months a screen is showing, and the two ways to
/// change it.
///
/// Not a chip in the filter strip, for two reasons. The strip scrolls
/// horizontally and its first chip can read "Amount: high to low", so a fifth
/// item would sit past the fold — for the control that answers the very first
/// question anyone has about the screen, and on which every total now depends.
/// And a filter chip with nothing selected reads as "not filtering", which a
/// month never is: there is always one in force.
///
/// The steppers are here because moving one month at a time is the common
/// gesture and a modal sheet is a heavy way to do it. They are hidden rather
/// than disabled in a multi-selection, where "the previous month" means nothing.
class PeriodBar extends StatelessWidget {
  const PeriodBar({
    super.key,
    required this.months,
    required this.options,
    required this.currentMonth,
    required this.onChanged,
  });

  final Set<YearMonth> months;
  final List<YearMonth> options;
  final YearMonth currentMonth;
  final ValueChanged<Set<YearMonth>> onChanged;

  bool get _single => months.length == 1;

  Future<void> _pick(BuildContext context) async {
    final Set<YearMonth>? picked = await chooseMany<YearMonth>(
      context,
      title: 'Months',
      options: options,
      selected: months,
      label: (YearMonth m) => m.label,
    );
    if (picked == null) return;
    // Nothing ticked reads as "show me everything", which is what an empty set
    // already means everywhere else.
    onChanged(picked.length <= kMaxComparedMonths
        ? picked
        // Keep the most recent, since that is what anyone comparing wants.
        : (picked.toList()
              ..sort((YearMonth a, YearMonth b) => b.compareTo(a)))
            .take(kMaxComparedMonths)
            .toSet());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final YearMonth? only = _single ? months.first : null;
    // Offering the future is offering the empty.
    final bool canGoForward = only != null && only.compareTo(currentMonth) < 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      child: Row(
        children: <Widget>[
          if (only != null)
            IconButton(
              tooltip: 'Previous month',
              icon: const Icon(Icons.chevron_left),
              onPressed: () => onChanged(<YearMonth>{only.plus(-1)}),
            ),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: () => _pick(context),
              icon: const Icon(Icons.calendar_month_outlined, size: 18),
              label: Text(
                periodLabel(months),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge,
              ),
            ),
          ),
          if (only != null)
            IconButton(
              tooltip: 'Next month',
              icon: const Icon(Icons.chevron_right),
              onPressed:
                  canGoForward ? () => onChanged(<YearMonth>{only.plus(1)}) : null,
            ),
        ],
      ),
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
    this.single = false,
  });

  final String title;
  final List<T> options;
  final Set<T> selected;
  final String Function(T) label;
  final Widget Function(T)? leading;
  final bool single;

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
                      final bool isSelected = _selected.contains(option);
                      if (widget.single) {
                        final Widget radioIcon = Icon(
                          isSelected
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          color: isSelected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outline,
                        );
                        return ListTile(
                          leading: widget.leading?.call(option) ?? radioIcon,
                          trailing: widget.leading != null ? radioIcon : null,
                          title: Text(
                            widget.label(option),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => setState(() {
                            if (isSelected) {
                              _selected = <T>{};
                            } else {
                              _selected = <T>{option};
                            }
                          }),
                        );
                      }
                      return CheckboxListTile(
                        value: isSelected,
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

/// A modern trigger button for filters and facets with active pill styling,
/// count badge, and chevron icon.
class FilterTriggerButton extends StatelessWidget {
  const FilterTriggerButton({
    super.key,
    required this.label,
    this.count = 0,
    this.active = false,
    this.leading,
    this.onPressed,
  });

  final String label;
  final int count;
  final bool active;
  final Widget? leading;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool isDark = theme.brightness == Brightness.dark;
    final bool isActive = active || count > 0;

    final Color bgColor = isActive
        ? (isDark
            ? theme.colorScheme.primaryContainer.withValues(alpha: 0.4)
            : const Color(0xFFE8F1FC))
        : Colors.transparent;

    final Color fgColor = isActive
        ? (isDark
            ? theme.colorScheme.onPrimaryContainer
            : const Color(0xFF1E3A8A))
        : theme.colorScheme.onSurfaceVariant;

    return Material(
      color: bgColor,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (leading != null) ...<Widget>[
                leading!,
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                  color: fgColor,
                  fontSize: 13.5,
                ),
              ),
              if (count > 0) ...<Widget>[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                  decoration: BoxDecoration(
                    color: isDark
                        ? theme.colorScheme.surfaceContainerHighest
                        : Colors.white,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: isDark
                          ? theme.colorScheme.outlineVariant
                          : const Color(0xFFBFDBFE),
                      width: 1,
                    ),
                  ),
                  child: Text(
                    '$count',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: fgColor,
                      height: 1.1,
                    ),
                  ),
                ),
              ],
              const SizedBox(width: 4),
              Icon(
                Icons.keyboard_arrow_down,
                size: 18,
                color: fgColor,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A removable active filter token chip with border and close icon.
class ActiveFilterChipToken extends StatelessWidget {
  const ActiveFilterChipToken({
    super.key,
    required this.label,
    required this.onDeleted,
    this.leading,
  });

  final String label;
  final VoidCallback onDeleted;
  final Widget? leading;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool isDark = theme.brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: isDark ? theme.colorScheme.surfaceContainerLow : Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isDark
              ? theme.colorScheme.outlineVariant
              : const Color(0xFFE2E8F0),
          width: 1,
        ),
      ),
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (leading != null) ...<Widget>[
            leading!,
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurface,
              fontWeight: FontWeight.w500,
              fontSize: 12.5,
            ),
          ),
          const SizedBox(width: 2),
          InkWell(
            onTap: onDeleted,
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(3),
              child: Icon(
                Icons.close,
                size: 13,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Displays the active filter chips row along with the 'Clear all' button.
class ActiveFiltersBar extends StatelessWidget {
  const ActiveFiltersBar({
    super.key,
    required this.filters,
    required this.currentMonth,
    required this.categoryChoices,
    required this.onFiltersChanged,
  });

  final LedgerFilters filters;
  final YearMonth currentMonth;
  final List<ExpenseCategory> categoryChoices;
  final ValueChanged<LedgerFilters> onFiltersChanged;

  String _categoryName(int id) => categoryChoices
      .firstWhere((ExpenseCategory c) => c.id == id,
          orElse: () => const ExpenseCategory(id: -1, name: kUncategorized))
      .name;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final bool isDark = theme.brightness == Brightness.dark;

    final List<Widget> chips = <Widget>[];

    // Search query
    if (filters.query.trim().isNotEmpty) {
      chips.add(
        ActiveFilterChipToken(
          label: '"${filters.query.trim()}"',
          onDeleted: () => onFiltersChanged(filters.copyWith(query: '')),
        ),
      );
    }

    // Months (if non-default)
    final bool isDefaultMonths =
        filters.months.length == 1 && filters.months.contains(currentMonth);
    if (!isDefaultMonths) {
      if (filters.months.isEmpty) {
        chips.add(
          ActiveFilterChipToken(
            label: 'All time',
            onDeleted: () => onFiltersChanged(
              filters.copyWith(months: <YearMonth>{currentMonth}),
            ),
          ),
        );
      } else {
        for (final YearMonth m in filters.months) {
          chips.add(
            ActiveFilterChipToken(
              label: m.label,
              onDeleted: () {
                final Set<YearMonth> next = <YearMonth>{...filters.months}..remove(m);
                onFiltersChanged(filters.copyWith(
                  months: next.isEmpty ? <YearMonth>{currentMonth} : next,
                ));
              },
            ),
          );
        }
      }
    }

    // Categories
    for (final int id in filters.categoryIds) {
      final String name = _categoryName(id);
      chips.add(
        ActiveFilterChipToken(
          label: name,
          onDeleted: () {
            final Set<int> next = <int>{...filters.categoryIds}..remove(id);
            onFiltersChanged(filters.copyWith(categoryIds: next));
          },
        ),
      );
    }

    // Merchants
    for (final String m in filters.merchants) {
      chips.add(
        ActiveFilterChipToken(
          label: m,
          onDeleted: () {
            final Set<String> next = <String>{...filters.merchants}..remove(m);
            onFiltersChanged(filters.copyWith(merchants: next));
          },
        ),
      );
    }

    // Payment Types (Cards / Accounts)
    for (final String pt in filters.paymentTypes) {
      chips.add(
        ActiveFilterChipToken(
          label: pt,
          onDeleted: () {
            final Set<String> next = <String>{...filters.paymentTypes}
              ..remove(pt);
            onFiltersChanged(filters.copyWith(paymentTypes: next));
          },
        ),
      );
    }

    if (chips.isEmpty) return const SizedBox.shrink();

    final Widget clearAllButton = OutlinedButton(
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        minimumSize: Size.zero,
        side: BorderSide(
          color: isDark
              ? theme.colorScheme.outlineVariant
              : const Color(0xFFD1D5DB),
        ),
        foregroundColor: theme.colorScheme.onSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(6),
        ),
      ),
      onPressed: () => onFiltersChanged(LedgerFilters.defaults(currentMonth)),
      child: const Text('Clear all', style: TextStyle(fontSize: 12)),
    );

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: chips,
            ),
          ),
          const SizedBox(width: 8),
          clearAllButton,
        ],
      ),
    );
  }
}
