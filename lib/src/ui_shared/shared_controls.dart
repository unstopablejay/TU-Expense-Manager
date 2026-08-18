/// Controls both the dashboard and the transactions list are built from.
library;

import 'package:flutter/material.dart';

import '../core/ledger.dart';


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
