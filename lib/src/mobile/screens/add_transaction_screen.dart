/// Adding a transaction manually — for cash entries and offline logging.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../core/constants.dart';
import '../../core/models.dart';
import '../../core/parser.dart';
import '../../core/splits.dart';
import '../../ui_shared/formats.dart';
import '../../ui_shared/palette.dart';
import '../database.dart';

/// An editable line in the split builder of [AddTransactionScreen].
class _ManualSplitLine {
  _ManualSplitLine({this.category, double? amount})
      : controller = TextEditingController(
          text: amount == null || amount == 0 ? '' : _plain(amount),
        );

  static String _plain(double v) => v.toStringAsFixed(2);

  ExpenseCategory? category;
  final TextEditingController controller;

  double get amount => double.tryParse(controller.text.trim()) ?? 0;
  set amount(double v) => controller.text = _plain(v);

  void dispose() => controller.dispose();
}

/// Screen for manually creating and inserting a transaction into the ledger.
class AddTransactionScreen extends StatefulWidget {
  const AddTransactionScreen({
    super.key,
    required this.categories,
    this.merchants = const <String>[],
  });

  final List<ExpenseCategory> categories;
  final List<String> merchants;

  @override
  State<AddTransactionScreen> createState() => _AddTransactionScreenState();
}

class _AddTransactionScreenState extends State<AddTransactionScreen> {
  final _formKey = GlobalKey<FormState>();
  final TextEditingController _amountController = TextEditingController();
  final TextEditingController _notesController = TextEditingController();

  final NumberFormat _money = appMoneyFormat();
  final DateFormat _dateFormat = DateFormat('EEE, d MMM yyyy');
  final DateFormat _timeFormat = DateFormat('h:mm a');

  late List<ExpenseCategory> _allCategories;
  late List<String> _allMerchants;

  String? _selectedMerchant;
  ExpenseCategory? _selectedCategory;
  DateTime _selectedDate = DateTime.now();
  String _paymentType = 'Cash';
  bool _isSplit = false;
  late List<_ManualSplitLine> _splitLines;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _allCategories = List<ExpenseCategory>.of(widget.categories);
    _allMerchants = List<String>.of(widget.merchants);

    // Default category to Uncategorized if available, or first non-empty category.
    _selectedCategory = _allCategories
            .where((ExpenseCategory c) => c.name != kUncategorized)
            .firstOrNull ??
        _allCategories.firstOrNull;

    _splitLines = <_ManualSplitLine>[
      _ManualSplitLine(category: _selectedCategory),
      _ManualSplitLine(),
    ];
  }

  @override
  void dispose() {
    _amountController.dispose();
    _notesController.dispose();
    for (final line in _splitLines) {
      line.dispose();
    }
    super.dispose();
  }

  double get _totalAmount =>
      double.tryParse(_amountController.text.trim()) ?? 0.0;

  List<double> get _splitAmounts =>
      _splitLines.map((_ManualSplitLine l) => l.amount).toList();

  double get _allocatedAmount =>
      _splitAmounts.fold<double>(0, (double sum, double a) => sum + a);

  double get _unallocatedAmount => unallocated(_splitAmounts, _totalAmount);

  bool get _isSplitValid =>
      _splitLines.every((_ManualSplitLine l) => l.category != null && l.amount > 0) &&
      isBalanced(_splitAmounts, _totalAmount);

  void _autoBalanceSplits() {
    if (_splitLines.isEmpty || _totalAmount <= 0) return;
    final next = withRemainderInLast(_splitAmounts, _totalAmount);
    setState(() {
      _splitLines.last.amount = next.last > 0 ? next.last : 0;
    });
  }

  Future<void> _pickDate() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _selectedDate = DateTime(
        picked.year,
        picked.month,
        picked.day,
        _selectedDate.hour,
        _selectedDate.minute,
        _selectedDate.second,
      );
    });
  }

  Future<void> _pickTime() async {
    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_selectedDate),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _selectedDate = DateTime(
        _selectedDate.year,
        _selectedDate.month,
        _selectedDate.day,
        picked.hour,
        picked.minute,
      );
    });
  }

  Future<void> _pickMerchant() async {
    final String? chosen = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => _MerchantSearchSheet(
        merchants: _allMerchants,
        selected: _selectedMerchant,
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() {
      _selectedMerchant = chosen;
      if (!_allMerchants.any((String m) => m.toLowerCase() == chosen.toLowerCase())) {
        _allMerchants.add(chosen);
      }
    });

    // Check if this merchant has a known default category in merchant_mappings
    _lookupMerchantDefault(chosen);
  }

  Future<void> _lookupMerchantDefault(String merchantName) async {
    try {
      final db = await AppDatabase.instance.database;
      final mappings = await db.query(
        'merchant_mappings',
        columns: <String>['category_id'],
        where: 'merchant_name = ? COLLATE NOCASE',
        whereArgs: <Object?>[merchantName],
        limit: 1,
      );
      if (mappings.isNotEmpty && mounted) {
        final catId = mappings.first['category_id'] as int;
        final matched = _allCategories
            .where((ExpenseCategory c) => c.id == catId)
            .firstOrNull;
        if (matched != null) {
          setState(() => _selectedCategory = matched);
        }
      }
    } catch (_) {
      // Best effort lookup; ignore lookup failure
    }
  }

  Future<void> _pickCategory() async {
    final ExpenseCategory? chosen =
        await showModalBottomSheet<ExpenseCategory>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => _CategorySearchSheet(
        categories: _allCategories,
        selected: _selectedCategory,
        onCategoryCreated: (ExpenseCategory newCat) {
          if (!_allCategories.any((c) => c.id == newCat.id)) {
            setState(() => _allCategories.add(newCat));
          }
        },
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() => _selectedCategory = chosen);
  }

  Future<void> _pickCategoryForSplitLine(_ManualSplitLine line) async {
    final ExpenseCategory? chosen =
        await showModalBottomSheet<ExpenseCategory>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => _CategorySearchSheet(
        categories: _allCategories,
        selected: line.category,
        onCategoryCreated: (ExpenseCategory newCat) {
          if (!_allCategories.any((c) => c.id == newCat.id)) {
            setState(() => _allCategories.add(newCat));
          }
        },
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() => line.category = chosen);
  }

  void _addSplitLine() {
    setState(() {
      final double remainder = _unallocatedAmount;
      _splitLines.add(
        _ManualSplitLine(
          amount: remainder > 0 ? remainder : 0,
        ),
      );
    });
  }

  void _removeSplitLine(int index) {
    if (_splitLines.length <= 2) return;
    setState(() {
      _splitLines.removeAt(index).dispose();
      _autoBalanceSplits();
    });
  }

  Future<void> _save() async {
    if (_saving) return;

    if (_selectedMerchant == null || _selectedMerchant!.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter or select a merchant name')),
      );
      return;
    }

    if (!_formKey.currentState!.validate()) return;

    final double amount = _totalAmount;
    if (amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid amount greater than 0')),
      );
      return;
    }

    if (_isSplit) {
      if (!_isSplitValid) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              _splitLines.any((l) => l.category == null || l.amount <= 0)
                  ? 'All split lines must have a category and amount > 0'
                  : 'Split amounts must equal the total amount (${_money.format(amount)})',
            ),
          ),
        );
        return;
      }
    } else {
      if (_selectedCategory == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please select a category')),
        );
        return;
      }
    }

    setState(() => _saving = true);

    try {
      final List<TxnSplit> splits = _isSplit
          ? _splitLines
              .map((_ManualSplitLine l) => TxnSplit(
                    categoryId: l.category!.id,
                    categoryName: l.category!.name,
                    amount: l.amount,
                  ))
              .toList()
          : const <TxnSplit>[];

      final int id = await AppDatabase.instance.insertManualTransaction(
        amount: amount,
        merchant: _selectedMerchant!,
        date: _selectedDate,
        categoryId: _isSplit ? _splitLines.first.category!.id : _selectedCategory!.id,
        paymentType: _paymentType,
        direction: TxnDirection.debit,
        note: _notesController.text.trim(),
        splits: splits,
      );

      if (!mounted) return;

      if (id > 0) {
        Navigator.pop(context, true);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not save transaction: duplicate entry found.'),
          ),
        );
        setState(() => _saving = false);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving transaction: $e')),
        );
        setState(() => _saving = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Add Transaction'),
        actions: <Widget>[
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.check, size: 18),
              label: const Text('Save'),
            ),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: <Widget>[
            // 1. AMOUNT FIELD
            Card(
              elevation: 0,
              color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(
                  color: colorScheme.outlineVariant.withValues(alpha: 0.7),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Amount',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      controller: _amountController,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      inputFormatters: <TextInputFormatter>[
                        FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
                      ],
                      autofocus: true,
                      style: theme.textTheme.headlineMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: colorScheme.primary,
                      ),
                      decoration: InputDecoration(
                        prefixIcon: Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: Text(
                            '₹',
                            style: theme.textTheme.headlineMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                              color: colorScheme.primary,
                            ),
                          ),
                        ),
                        prefixIconConstraints: const BoxConstraints(
                          minWidth: 0,
                          minHeight: 0,
                        ),
                        border: InputBorder.none,
                        hintText: '0.00',
                        hintStyle: theme.textTheme.headlineMedium?.copyWith(
                          color: colorScheme.outline.withValues(alpha: 0.5),
                        ),
                      ),
                      validator: (String? value) {
                        if (value == null || value.trim().isEmpty) {
                          return 'Enter an amount';
                        }
                        final parsed = double.tryParse(value.trim());
                        if (parsed == null || parsed <= 0) {
                          return 'Enter a positive amount';
                        }
                        return null;
                      },
                      onChanged: (String val) {
                        if (_isSplit) {
                          _autoBalanceSplits();
                        }
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            // 2. MERCHANT NAME (Searchable dropdown with Add New)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: colorScheme.outlineVariant),
              ),
              leading: Icon(Icons.storefront_outlined, color: colorScheme.primary),
              title: Text(
                _selectedMerchant != null && _selectedMerchant!.isNotEmpty
                    ? _selectedMerchant!
                    : 'Select or add merchant',
                style: _selectedMerchant != null && _selectedMerchant!.isNotEmpty
                    ? theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)
                    : theme.textTheme.titleMedium?.copyWith(
                        color: colorScheme.onSurfaceVariant,
                      ),
              ),
              subtitle: Text(
                'Merchant / Payee',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              trailing: const Icon(Icons.arrow_drop_down),
              onTap: _pickMerchant,
            ),
            const SizedBox(height: 16),

            // 3. DATE & TIME PICKER (Defaults to current, editable)
            Row(
              children: <Widget>[
                Expanded(
                  flex: 3,
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 2,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: colorScheme.outlineVariant),
                    ),
                    leading: Icon(
                      Icons.calendar_today_outlined,
                      size: 20,
                      color: colorScheme.primary,
                    ),
                    title: Text(
                      _dateFormat.format(_selectedDate),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: const Text('Date'),
                    onTap: _pickDate,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: ListTile(
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 2,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                      side: BorderSide(color: colorScheme.outlineVariant),
                    ),
                    leading: Icon(
                      Icons.access_time,
                      size: 20,
                      color: colorScheme.primary,
                    ),
                    title: Text(
                      _timeFormat.format(_selectedDate),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: const Text('Time'),
                    onTap: _pickTime,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // 4. PAYMENT TYPE (Defaults to Cash)
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Payment Method',
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  children: <String>['Cash', 'UPI', 'Debit Card', 'Credit Card', 'Other']
                      .map((String type) {
                    final isSelected = _paymentType == type;
                    return ChoiceChip(
                      label: Text(type),
                      selected: isSelected,
                      avatar: isSelected
                          ? const Icon(Icons.check, size: 16)
                          : Icon(
                              type == 'Cash'
                                  ? Icons.payments_outlined
                                  : type == 'UPI'
                                      ? Icons.qr_code
                                      : Icons.credit_card,
                              size: 16,
                            ),
                      onSelected: (bool selected) {
                        if (selected) setState(() => _paymentType = type);
                      },
                    );
                  }).toList(),
                ),
              ],
            ),
            const SizedBox(height: 20),

            // 5. CATEGORY & SPLIT SECTION
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: colorScheme.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Icon(
                              Icons.call_split_outlined,
                              size: 20,
                              color: colorScheme.primary,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              'Split Transaction',
                              style: theme.textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        Switch(
                          value: _isSplit,
                          onChanged: (bool val) {
                            setState(() {
                              _isSplit = val;
                              if (val) {
                                _autoBalanceSplits();
                              }
                            });
                          },
                        ),
                      ],
                    ),
                    if (!_isSplit) ...<Widget>[
                      const Divider(height: 20),
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: _selectedCategory != null
                            ? CircleAvatar(
                                radius: 18,
                                backgroundColor: colorScheme.primaryContainer,
                                child: Icon(
                                  categoryIcon(_selectedCategory!.name),
                                  size: 18,
                                  color: colorScheme.onPrimaryContainer,
                                ),
                              )
                            : Icon(Icons.category_outlined, color: colorScheme.primary),
                        title: Text(
                          _selectedCategory?.name ?? 'Select category',
                          style: theme.textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        subtitle: const Text('Category'),
                        trailing: const Icon(Icons.arrow_drop_down),
                        onTap: _pickCategory,
                      ),
                    ] else ...<Widget>[
                      const Divider(height: 20),
                      Text(
                        'Divide the total amount across multiple categories:',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 12),
                      for (int i = 0; i < _splitLines.length; i++) ...<Widget>[
                        _buildSplitRow(i, theme, colorScheme),
                        const SizedBox(height: 8),
                      ],
                      const SizedBox(height: 8),
                      Row(
                        children: <Widget>[
                          OutlinedButton.icon(
                            onPressed: _addSplitLine,
                            icon: const Icon(Icons.add, size: 18),
                            label: const Text('Add split line'),
                          ),
                          const Spacer(),
                          TextButton.icon(
                            onPressed: _autoBalanceSplits,
                            icon: const Icon(Icons.balance_outlined, size: 18),
                            label: const Text('Auto-balance'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: _isSplitValid
                              ? colorScheme.primaryContainer.withValues(alpha: 0.3)
                              : colorScheme.errorContainer.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: <Widget>[
                            Icon(
                              _isSplitValid
                                  ? Icons.check_circle_outline
                                  : Icons.info_outline,
                              size: 18,
                              color: _isSplitValid
                                  ? colorScheme.primary
                                  : colorScheme.error,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                _isSplitValid
                                    ? 'Balanced: ${_money.format(_allocatedAmount)} of ${_money.format(_totalAmount)}'
                                    : 'Allocated ${_money.format(_allocatedAmount)} of ${_money.format(_totalAmount)} (Difference: ${_money.format(_unallocatedAmount.abs())})',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: _isSplitValid
                                      ? colorScheme.primary
                                      : colorScheme.error,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),

            // 6. NOTES FIELD
            TextFormField(
              controller: _notesController,
              maxLines: 2,
              maxLength: kNoteMaxLength,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.sticky_note_2_outlined),
                labelText: 'Notes (optional)',
                hintText: 'What was this expense for?',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
            const SizedBox(height: 32),

            // 7. SAVE BUTTON
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              icon: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.check),
              label: Text(
                _saving ? 'Saving...' : 'Add Transaction',
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildSplitRow(int index, ThemeData theme, ColorScheme colorScheme) {
    final line = _splitLines[index];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            flex: 3,
            child: InkWell(
              onTap: () => _pickCategoryForSplitLine(line),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                child: Row(
                  children: <Widget>[
                    Icon(
                      line.category != null
                          ? categoryIcon(line.category!.name)
                          : Icons.category_outlined,
                      size: 18,
                      color: colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        line.category?.name ?? 'Pick category',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: line.category != null
                              ? FontWeight.w600
                              : FontWeight.normal,
                          color: line.category != null
                              ? colorScheme.onSurface
                              : colorScheme.onSurfaceVariant,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Icon(Icons.arrow_drop_down, size: 18),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: TextField(
              controller: line.controller,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,2}')),
              ],
              decoration: const InputDecoration(
                isDense: true,
                prefixText: '₹',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          if (_splitLines.length > 2) ...<Widget>[
            const SizedBox(width: 4),
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              color: colorScheme.error,
              tooltip: 'Remove split line',
              onPressed: () => _removeSplitLine(index),
            ),
          ],
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// MERCHANT SEARCHABLE DROPDOWN SHEET
// ---------------------------------------------------------------------------

class _MerchantSearchSheet extends StatefulWidget {
  const _MerchantSearchSheet({
    required this.merchants,
    this.selected,
  });

  final List<String> merchants;
  final String? selected;

  @override
  State<_MerchantSearchSheet> createState() => _MerchantSearchSheetState();
}

class _MerchantSearchSheetState extends State<_MerchantSearchSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final cleanQuery = _query.trim();

    final filtered = widget.merchants
        .where((String m) => m.toLowerCase().contains(cleanQuery.toLowerCase()))
        .toList();

    final bool exactMatch = widget.merchants.any(
      (String m) => m.toLowerCase() == cleanQuery.toLowerCase(),
    );

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (BuildContext sheetContext, ScrollController scrollController) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom + 20,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Select Merchant', style: theme.textTheme.titleLarge),
              const SizedBox(height: 12),
              TextField(
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Search or add merchant...',
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  suffixIcon: _query.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                        )
                      : null,
                ),
                onChanged: (String val) => setState(() => _query = val),
              ),
              const SizedBox(height: 12),
              if (cleanQuery.isNotEmpty && !exactMatch) ...<Widget>[
                ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: colorScheme.primary),
                  ),
                  tileColor: colorScheme.primaryContainer.withValues(alpha: 0.3),
                  leading: Icon(Icons.add_circle, color: colorScheme.primary),
                  title: Text(
                    'Add "$cleanQuery"',
                    style: TextStyle(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  subtitle: const Text('New merchant'),
                  onTap: () => Navigator.pop(sheetContext, cleanQuery),
                ),
                const SizedBox(height: 8),
              ],
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Icon(
                                Icons.storefront_outlined,
                                size: 48,
                                color: colorScheme.outline,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                cleanQuery.isEmpty
                                    ? 'No merchants recorded yet.'
                                    : 'No existing merchant matching "$cleanQuery"',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                              if (cleanQuery.isNotEmpty && !exactMatch) ...<Widget>[
                                const SizedBox(height: 16),
                                FilledButton.icon(
                                  onPressed: () =>
                                      Navigator.pop(sheetContext, cleanQuery),
                                  icon: const Icon(Icons.add),
                                  label: Text('Use "$cleanQuery"'),
                                ),
                              ],
                            ],
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: scrollController,
                        itemCount: filtered.length,
                        itemBuilder: (BuildContext ctx, int index) {
                          final merchant = filtered[index];
                          final isSelected = merchant == widget.selected;
                          return ListTile(
                            leading: const Icon(Icons.storefront_outlined),
                            title: Text(merchant),
                            trailing: isSelected
                                ? Icon(Icons.check, color: colorScheme.primary)
                                : null,
                            selected: isSelected,
                            onTap: () => Navigator.pop(sheetContext, merchant),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// CATEGORY SEARCHABLE DROPDOWN SHEET
// ---------------------------------------------------------------------------

class _CategorySearchSheet extends StatefulWidget {
  const _CategorySearchSheet({
    required this.categories,
    this.selected,
    required this.onCategoryCreated,
  });

  final List<ExpenseCategory> categories;
  final ExpenseCategory? selected;
  final ValueChanged<ExpenseCategory> onCategoryCreated;

  @override
  State<_CategorySearchSheet> createState() => _CategorySearchSheetState();
}

class _CategorySearchSheetState extends State<_CategorySearchSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _query = '';
  bool _creating = false;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _createAndSelect(String name) async {
    final clean = name.trim();
    if (clean.isEmpty || _creating) return;
    setState(() => _creating = true);
    try {
      final ExpenseCategory category =
          await AppDatabase.instance.addCategory(clean);
      widget.onCategoryCreated(category);
      if (mounted) Navigator.pop(context, category);
    } catch (_) {
      if (mounted) setState(() => _creating = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final cleanQuery = _query.trim();

    final filtered = widget.categories
        .where((ExpenseCategory c) =>
            c.name.toLowerCase().contains(cleanQuery.toLowerCase()) &&
            c.name != kUncategorized)
        .toList();

    final bool exactMatch = widget.categories.any(
      (ExpenseCategory c) => c.name.toLowerCase() == cleanQuery.toLowerCase(),
    );

    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (BuildContext sheetContext, ScrollController scrollController) {
        return Padding(
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom + 20,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Select Category', style: theme.textTheme.titleLarge),
              const SizedBox(height: 12),
              TextField(
                controller: _searchController,
                autofocus: true,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: 'Search or add category...',
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  suffixIcon: _query.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear),
                          onPressed: () {
                            _searchController.clear();
                            setState(() => _query = '');
                          },
                        )
                      : null,
                ),
                onChanged: (String val) => setState(() => _query = val),
              ),
              const SizedBox(height: 12),
              if (cleanQuery.isNotEmpty && !exactMatch) ...<Widget>[
                ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: BorderSide(color: colorScheme.primary),
                  ),
                  tileColor: colorScheme.primaryContainer.withValues(alpha: 0.3),
                  leading: _creating
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Icon(Icons.add_circle, color: colorScheme.primary),
                  title: Text(
                    'Add "$cleanQuery"',
                    style: TextStyle(
                      color: colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  subtitle: const Text('Create and select new category'),
                  onTap: _creating ? null : () => _createAndSelect(cleanQuery),
                ),
                const SizedBox(height: 8),
              ],
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: <Widget>[
                              Icon(
                                Icons.category_outlined,
                                size: 48,
                                color: colorScheme.outline,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                cleanQuery.isEmpty
                                    ? 'No categories available'
                                    : 'No categories matching "$cleanQuery"',
                                textAlign: TextAlign.center,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                              if (cleanQuery.isNotEmpty && !exactMatch) ...<Widget>[
                                const SizedBox(height: 16),
                                FilledButton.icon(
                                  onPressed: _creating
                                      ? null
                                      : () => _createAndSelect(cleanQuery),
                                  icon: const Icon(Icons.add),
                                  label: Text('Add "$cleanQuery"'),
                                ),
                              ],
                            ],
                          ),
                        ),
                      )
                    : ListView.builder(
                        controller: scrollController,
                        itemCount: filtered.length,
                        itemBuilder: (BuildContext ctx, int index) {
                          final category = filtered[index];
                          final isSelected = category.id == widget.selected?.id;
                          return ListTile(
                            leading: CircleAvatar(
                              radius: 16,
                              backgroundColor: colorScheme.surfaceContainerHighest,
                              child: Icon(
                                categoryIcon(category.name),
                                size: 16,
                                color: colorScheme.primary,
                              ),
                            ),
                            title: Text(category.name),
                            trailing: isSelected
                                ? Icon(Icons.check, color: colorScheme.primary)
                                : null,
                            selected: isSelected,
                            onTap: () => Navigator.pop(sheetContext, category),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}
