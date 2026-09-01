import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/ledger.dart';
import '../core/models.dart';
import '../core/parser.dart';
import 'palette.dart';
import 'shared_controls.dart';

class CompareMonthsScreen extends StatefulWidget {
  const CompareMonthsScreen({
    super.key,
    required this.transactions,
    required this.monthChoices,
    required this.money,
  });

  final List<ExpenseTxn> transactions;
  final List<YearMonth> monthChoices;
  final NumberFormat money;

  @override
  State<CompareMonthsScreen> createState() => _CompareMonthsScreenState();
}

class _CompareMonthsScreenState extends State<CompareMonthsScreen> {
  late Set<YearMonth> _selectedMonths;

  @override
  void initState() {
    super.initState();
    _selectedMonths = widget.monthChoices.take(2).toSet();
  }

  void _updateMonths(YearMonth month, bool selected) {
    setState(() {
      if (selected) {
        if (_selectedMonths.length >= kMaxComparedMonths) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Maximum 6 months')),
          );
          return;
        }
        _selectedMonths.add(month);
      } else {
        if (_selectedMonths.length <= 2) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Select at least 2 months to compare')),
          );
          return;
        }
        _selectedMonths.remove(month);
      }
    });
  }

  Future<void> _addMonth() async {
    final picked = await chooseMany<YearMonth>(
      context,
      title: 'Compare months',
      options: widget.monthChoices,
      selected: _selectedMonths,
      label: (m) => m.label,
    );
    if (picked != null) {
      if (picked.length < 2) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Select at least 2 months to compare')),
          );
        }
      } else if (picked.length > kMaxComparedMonths) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Maximum 6 months')),
          );
        }
        setState(() {
          _selectedMonths = picked.take(kMaxComparedMonths).toSet();
        });
      } else {
        setState(() {
          _selectedMonths = picked;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final axis = comparedMonths(_selectedMonths);
    final entries = applyFilters(widget.transactions, months: _selectedMonths);
    final perMonth = spendByCategoryPerMonth(entries);

    // Map icons and detect pure income categories
    final categoryIcons = <String, String>{};
    final pureIncome = <String>{};
    final allIncome = <String>{};
    final allExpense = <String>{};

    for (final entry in entries) {
      final t = entry.txn;
      if (t.categoryIcon.isNotEmpty) categoryIcons[t.categoryName] = t.categoryIcon;
      for (final s in t.effectiveSplits) {
        if (s.categoryIcon.isNotEmpty) categoryIcons[s.categoryName] = s.categoryIcon;
      }

      if (t.direction == TxnDirection.credit) {
        allIncome.add(t.categoryName);
      } else {
        allExpense.add(t.categoryName);
      }
    }
    pureIncome.addAll(allIncome.difference(allExpense));

    final categoryNames = <String>{
      for (final m in axis) ...?(perMonth[m]?.keys),
    }.where((c) => c != kOtherCategory).toList()
      ..sort((a, b) {
        final ta = axis.fold<double>(0, (s, m) => s + (perMonth[m]?[a] ?? 0));
        final tb = axis.fold<double>(0, (s, m) => s + (perMonth[m]?[b] ?? 0));
        return tb.compareTo(ta);
      });

    final totals = <YearMonth, double>{
      for (final m in axis)
        m: (perMonth[m] ?? {}).values.fold<double>(0, (s, v) => s + v),
    };

    return Scaffold(
      appBar: AppBar(title: const Text('Compare months')),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _CompareMonthsPicker(
            selectedMonths: _selectedMonths,
            axis: axis,
            onToggle: _updateMonths,
            onAdd: _addMonth,
          ),
          const SizedBox(height: 8),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SummaryHeader(axis: axis, totals: totals, money: widget.money),
                  const SizedBox(height: 16),
                  _CategoryCompareTable(
                    axis: axis,
                    categories: categoryNames,
                    perMonth: perMonth,
                    totals: totals,
                    money: widget.money,
                    categoryIcons: categoryIcons,
                    pureIncome: pureIncome,
                  ),
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CompareMonthsPicker extends StatelessWidget {
  const _CompareMonthsPicker({
    required this.selectedMonths,
    required this.axis,
    required this.onToggle,
    required this.onAdd,
  });

  final Set<YearMonth> selectedMonths;
  final List<YearMonth> axis;
  final void Function(YearMonth, bool) onToggle;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          for (final m in axis)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: FilterChip(
                label: Text(m.label),
                selected: selectedMonths.contains(m),
                onSelected: (val) => onToggle(m, val),
                showCheckmark: false,
                deleteIcon: const Icon(Icons.close, size: 16),
                onDeleted: () => onToggle(m, false),
              ),
            ),
          ActionChip(
            label: const Text('+ Add month'),
            onPressed: onAdd,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
              side: BorderSide(
                color: Theme.of(context).colorScheme.outline,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SummaryHeader extends StatelessWidget {
  const _SummaryHeader({
    required this.axis,
    required this.totals,
    required this.money,
  });

  final List<YearMonth> axis;
  final Map<YearMonth, double> totals;
  final NumberFormat money;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          for (final m in axis)
            Container(
              margin: const EdgeInsets.only(right: 12),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    m.label,
                    style: theme.textTheme.labelMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    money.format(totals[m] ?? 0),
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _CategoryCompareTable extends StatelessWidget {
  const _CategoryCompareTable({
    required this.axis,
    required this.categories,
    required this.perMonth,
    required this.totals,
    required this.money,
    required this.categoryIcons,
    required this.pureIncome,
  });

  final List<YearMonth> axis;
  final List<String> categories;
  final Map<YearMonth, Map<String, double>> perMonth;
  final Map<YearMonth, double> totals;
  final NumberFormat money;
  final Map<String, String> categoryIcons;
  final Set<String> pureIncome;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showDelta = axis.length == 2;
    const double catWidth = 140;
    const double monthWidth = 90;
    const double deltaAmtWidth = 90;
    const double deltaPctWidth = 70;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Header
        Row(
          children: [
            const SizedBox(width: 16),
            SizedBox(
              width: catWidth,
              child: Text('Category', style: theme.textTheme.labelSmall),
            ),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                physics: const ClampingScrollPhysics(),
                child: Row(
                  children: [
                    for (final m in axis)
                      SizedBox(
                        width: monthWidth,
                        child: Text(
                          m.label,
                          textAlign: TextAlign.right,
                          style: theme.textTheme.labelSmall,
                        ),
                      ),
                    if (showDelta) ...[
                      SizedBox(
                        width: deltaAmtWidth,
                        child: Text('Δ Amount', textAlign: TextAlign.right, style: theme.textTheme.labelSmall),
                      ),
                      SizedBox(
                        width: deltaPctWidth,
                        child: Text('Δ %', textAlign: TextAlign.right, style: theme.textTheme.labelSmall),
                      ),
                    ],
                    const SizedBox(width: 16),
                  ],
                ),
              ),
            ),
          ],
        ),
        const Divider(),
        // Rows
        for (final cat in categories) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                const SizedBox(width: 16),
                SizedBox(
                  width: catWidth,
                  child: Row(
                    children: [
                      CategoryAvatar(
                        category: cat,
                        explicitIcon: categoryIcons[cat],
                        size: 20,
                        fontSize: 14,
                        iconSize: 14,
                        borderRadius: 4,
                        backgroundColor: Colors.transparent,
                        borderColor: Colors.transparent,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          cat,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    physics: const ClampingScrollPhysics(),
                    child: Row(
                      children: [
                        for (final m in axis)
                          SizedBox(
                            width: monthWidth,
                            child: Text(
                              (perMonth[m]?[cat] ?? 0) > 0
                                  ? money.format(perMonth[m]![cat]!)
                                  : '—',
                              textAlign: TextAlign.right,
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                        if (showDelta)
                          _DeltaCells(
                            a: perMonth[axis[0]]?[cat] ?? 0,
                            b: perMonth[axis[1]]?[cat] ?? 0,
                            money: money,
                            isIncome: pureIncome.contains(cat),
                            amtWidth: deltaAmtWidth,
                            pctWidth: deltaPctWidth,
                          ),
                        const SizedBox(width: 16),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
        ],
        // Total Row
        Container(
          color: theme.colorScheme.surfaceContainerHighest,
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              const SizedBox(width: 16),
              SizedBox(
                width: catWidth,
                child: Text('Total', style: theme.textTheme.titleSmall),
              ),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  physics: const ClampingScrollPhysics(),
                  child: Row(
                    children: [
                      for (final m in axis)
                        SizedBox(
                          width: monthWidth,
                          child: Text(
                            money.format(totals[m] ?? 0),
                            textAlign: TextAlign.right,
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                      if (showDelta)
                        _DeltaCells(
                          a: totals[axis[0]] ?? 0,
                          b: totals[axis[1]] ?? 0,
                          money: money,
                          isIncome: false,
                          amtWidth: deltaAmtWidth,
                          pctWidth: deltaPctWidth,
                        ),
                      const SizedBox(width: 16),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _DeltaCells extends StatelessWidget {
  const _DeltaCells({
    required this.a,
    required this.b,
    required this.money,
    required this.isIncome,
    required this.amtWidth,
    required this.pctWidth,
  });

  final double a;
  final double b;
  final NumberFormat money;
  final bool isIncome;
  final double amtWidth;
  final double pctWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final deltaAmt = deltaAmount(a, b);
    final deltaPct = deltaPercent(a, b);

    Color color;
    if (deltaAmt > 0) {
      color = isIncome ? Colors.green.shade600 : theme.colorScheme.error;
    } else if (deltaAmt < 0) {
      color = isIncome ? theme.colorScheme.error : Colors.green.shade600;
    } else {
      color = theme.colorScheme.outline;
    }

    final style = theme.textTheme.bodyMedium?.copyWith(
      color: color,
      fontWeight: FontWeight.w600,
    );

    final String signAmt = deltaAmt > 0 ? '+' : '';
    final amtText = deltaAmt == 0 ? '—' : '$signAmt${money.format(deltaAmt)}';
    
    final String signPct = (deltaPct ?? 0) > 0 ? '+' : '';
    final pctText = deltaPct == null ? '—' : '$signPct${deltaPct.toStringAsFixed(0)}%';

    return Row(
      children: [
        SizedBox(
          width: amtWidth,
          child: Text(amtText, textAlign: TextAlign.right, style: style),
        ),
        SizedBox(
          width: pctWidth,
          child: Text(pctText, textAlign: TextAlign.right, style: style),
        ),
      ],
    );
  }
}
