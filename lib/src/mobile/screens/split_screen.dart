/// Splitting one transaction across several categories.
///
/// A single Amazon charge covers groceries, snacks and shopping, but the bank
/// only ever says the total. Tagging the whole amount three times would count it
/// three times over; lines that sum to the charge keep every total honest.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/models.dart';
import '../../core/splits.dart';
import '../../ui_shared/palette.dart';
import '../database.dart';
import 'category_picker_sheet.dart';

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
                    child: _saving
                        ? const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Colors.white,
                                ),
                              ),
                              SizedBox(width: 8),
                              Text('Saving…'),
                            ],
                          )
                        : const Text('Save'),
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
