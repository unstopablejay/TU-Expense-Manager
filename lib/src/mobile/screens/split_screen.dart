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
  final GlobalKey key = GlobalKey();

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
  bool _attemptedSave = false;
  late String _initialSnapshot;

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
    _initialSnapshot = _takeSnapshot();
  }

  @override
  void dispose() {
    for (final _SplitRow row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  String _takeSnapshot() {
    return _rows.map((r) => '${r.category?.id}:${r.controller.text}').join('|');
  }

  bool get _isDirty => _takeSnapshot() != _initialSnapshot;

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
    setState(() => _attemptedSave = true);

    final bool complete = _rows.isNotEmpty && _rows.every((_SplitRow r) => r.category != null);
    final bool positive = _rows.every((_SplitRow r) => r.amount > 0);
    final bool balanced = isBalanced(_amounts, widget.txn.amount);

    if (!complete || !positive || !balanced) {
      // Find first error and scroll to it
      for (final _SplitRow row in _rows) {
        if (row.category == null || row.amount <= 0) {
          if (row.key.currentContext != null) {
            Scrollable.ensureVisible(
              row.key.currentContext!,
              duration: const Duration(milliseconds: 300),
              alignment: 0.1,
            );
          }
          break;
        }
      }
      return;
    }

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

  Future<void> _showConfirmDialog() async {
    final bool? leave = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text("Your changes haven't been saved."),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Stay'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Leave'),
          ),
        ],
      ),
    );
    if (leave == true && mounted) {
      Navigator.pop(context, false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double left = unallocated(_amounts, widget.txn.amount);
    final bool balanced = isBalanced(_amounts, widget.txn.amount);

    return PopScope(
      canPop: !_isDirty || _saving,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;
        _showConfirmDialog();
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Split'),
          actions: <Widget>[
            if (_saving)
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Center(
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else
              TextButton(
                onPressed: _save,
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.primary,
                ),
                child: const Text('Save'),
              ),
          ],
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
            final bool catError = _attemptedSave && row.category == null;
            final bool amtError = _attemptedSave && row.amount <= 0;

            return Padding(
              key: row.key,
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    flex: 3,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        OutlinedButton(
                          style: catError
                              ? OutlinedButton.styleFrom(
                                  side: BorderSide(color: theme.colorScheme.error),
                                )
                              : null,
                          onPressed: () => _pickCategoryFor(row),
                          child: Row(
                            children: <Widget>[
                              if (row.category != null)
                                CategoryAvatar(
                                  category: row.category!.name,
                                  explicitIcon: row.category!.icon,
                                  size: 24,
                                  fontSize: 14,
                                  iconSize: 14,
                                  borderRadius: 6,
                                )
                              else
                                Icon(
                                  Icons.category_outlined,
                                  size: 18,
                                  color: theme.colorScheme.primary,
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
                        if (catError)
                          Padding(
                            padding: const EdgeInsets.only(left: 12, top: 4),
                            child: Text(
                              'Required',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: theme.colorScheme.error,
                                fontSize: 11,
                              ),
                            ),
                          ),
                      ],
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
                      decoration: InputDecoration(
                        isDense: true,
                        border: const OutlineInputBorder(),
                        prefixText: '₹',
                        errorText: amtError ? 'Must be > 0' : null,
                      ),
                      onChanged: (_) => _rebalance(editedIndex: index),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: IconButton(
                      tooltip: 'Remove row',
                      // Below two rows there is nothing left to split.
                      onPressed:
                          _rows.length > 2 ? () => _removeRow(index) : null,
                      icon: const Icon(Icons.close),
                    ),
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
                if (!balanced && _attemptedSave)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      'Amounts must add up to the total.',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.error),
                    ),
                  ),
                if (widget.txn.isSplit) ...<Widget>[
                  const SizedBox(height: 8),
                  Row(
                    children: <Widget>[
                      TextButton(
                        onPressed: _saving ? null : _removeSplit,
                        child: const Text('Remove split'),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
