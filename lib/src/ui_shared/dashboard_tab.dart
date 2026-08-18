/// The dashboard: the same ledger as charts.
///
/// Stateless and entirely prop-driven, which is what lets the web build render
/// this exact screen from a snapshot instead of from SQLite.
library;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/ledger.dart';
import '../core/models.dart';
import 'palette.dart';
import 'shared_controls.dart';


/// Where the money went over a chosen period.
///
/// Reads the whole ledger and narrows it by month **and nothing else**. It
/// deliberately does not inherit the transaction list's category, merchant,
/// card or search filters: a breakdown steered by a working list's filter state
/// is not a report, and a pie chart of a single category is not a chart.
class DashboardTab extends StatelessWidget {
  const DashboardTab({
    super.key,
    required this.transactions,
    required this.months,
    required this.monthChoices,
    required this.currentMonth,
    required this.money,
    required this.loading,
    required this.onMonthsChanged,
    required this.onRefresh,
  });

  final List<ExpenseTxn> transactions;
  final Set<YearMonth> months;
  final List<YearMonth> monthChoices;
  final YearMonth currentMonth;
  final NumberFormat money;
  final bool loading;
  final ValueChanged<Set<YearMonth>> onMonthsChanged;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    final List<LedgerEntry> entries =
        applyFilters(transactions, months: months);
    final totals = periodTotals(entries);
    final Map<String, double> byCategory = spendByCategory(entries);

    return Column(
      children: <Widget>[
        PeriodBar(
          months: months,
          options: monthChoices,
          currentMonth: currentMonth,
          onChanged: onMonthsChanged,
        ),
        Expanded(
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: onRefresh,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                    children: <Widget>[
                      _SpendHeadline(
                        spent: totals.spent,
                        received: totals.received,
                        count: totals.count,
                        period: periodLabel(months),
                        money: money,
                      ),
                      if (byCategory.isEmpty)
                        _NothingToChart(period: periodLabel(months))
                      // One month is a part-to-whole question and a donut
                      // answers it at a glance. Several months is a comparison,
                      // which a donut cannot answer at all — nobody can compare
                      // angles across two circles — so the shape changes.
                      else if (months.length <= 1)
                        _CategoryDonutCard(
                          byCategory: byCategory,
                          total: totals.spent,
                          money: money,
                        )
                      else
                        _MonthComparisonCard(
                          entries: entries,
                          months: months,
                          money: money,
                        ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }
}

/// The one number the screen leads with.
class _SpendHeadline extends StatelessWidget {
  const _SpendHeadline({
    required this.spent,
    required this.received,
    required this.count,
    required this.period,
    required this.money,
  });

  final double spent;
  final double received;
  final int count;
  final String period;
  final NumberFormat money;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
              style: theme.textTheme.headlineLarge?.copyWith(
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
              '$count transaction${count == 1 ? '' : 's'}',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

/// A donut over the period's categories, with the ranked amounts beside it.
///
/// The list is not decoration and not merely a legend. A donut is honest about
/// part-to-whole at a glance and useless for comparing two close values, so the
/// exact figures have to be readable somewhere — and that is also what keeps
/// the chart legible for anyone who cannot separate two of the hues.
class _CategoryDonutCard extends StatelessWidget {
  const _CategoryDonutCard({
    required this.byCategory,
    required this.total,
    required this.money,
  });

  final Map<String, double> byCategory;
  final double total;
  final NumberFormat money;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Brightness brightness = theme.brightness;
    final List<CategorySlice> slices = topCategories(byCategory);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Where it went', style: theme.textTheme.titleMedium),
            const SizedBox(height: 16),
            SizedBox(
              height: 180,
              child: PieChart(
                PieChartData(
                  sectionsSpace: 2, // a surface gap, so adjacent arcs separate
                  centerSpaceRadius: 52,
                  sections: <PieChartSectionData>[
                    for (final CategorySlice slice in slices)
                      PieChartSectionData(
                        value: slice.amount,
                        color: categoryColor(slice.name, brightness),
                        radius: 34,
                        showTitle: false,
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            for (final CategorySlice slice in slices)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: <Widget>[
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: categoryColor(slice.name, brightness),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Icon(categoryIcon(slice.name),
                        size: 16, color: theme.colorScheme.onSurfaceVariant),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        slice.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    Text(
                      '${(slice.share * 100).round()}%',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      money.format(slice.amount),
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The same spend, several months at a time: one group per category, one bar
/// per month within it.
///
/// Months are the series here, not categories — the question this chart answers
/// is "did this go up or down", so it is the months that have to be told apart.
class _MonthComparisonCard extends StatelessWidget {
  const _MonthComparisonCard({
    required this.entries,
    required this.months,
    required this.money,
  });

  final List<LedgerEntry> entries;
  final Set<YearMonth> months;
  final NumberFormat money;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Brightness brightness = theme.brightness;

    final Map<YearMonth, Map<String, double>> perMonth =
        spendByCategoryPerMonth(entries);
    final List<YearMonth> axis = comparedMonths(months);
    // The categories worth drawing, ranked over the whole period so the groups
    // are in a stable, meaningful order rather than one month's order.
    final List<CategorySlice> ranked = topCategories(
      spendByCategory(entries),
      limit: 6,
    );
    final List<Color> monthColors = chartHues(brightness);

    double amountFor(YearMonth m, String category) =>
        perMonth[m]?[category] ?? 0;

    // "Other" is a bucket, not a category, so it cannot be looked up per month.
    final List<CategorySlice> groups = ranked
        .where((CategorySlice s) => s.name != kOtherCategory)
        .toList();

    final double maxY = <double>[
      for (final CategorySlice s in groups)
        for (final YearMonth m in axis) amountFor(m, s.name),
      1,
    ].reduce((double a, double b) => a > b ? a : b);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Month by month', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Spend per category, one bar per month.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            // A legend is not optional with more than one series: it is the
            // only thing naming which bar is which month.
            Wrap(
              spacing: 12,
              runSpacing: 6,
              children: <Widget>[
                for (int i = 0; i < axis.length; i++)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: monthColors[i % monthColors.length],
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(axis[i].label, style: theme.textTheme.bodySmall),
                    ],
                  ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              height: 240,
              child: BarChart(
                BarChartData(
                  maxY: maxY * 1.15,
                  alignment: BarChartAlignment.spaceAround,
                  // Hairline horizontal grid only; vertical rules would just be
                  // noise between groups that are already separated by space.
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    getDrawingHorizontalLine: (double v) => FlLine(
                      color: theme.colorScheme.outlineVariant,
                      strokeWidth: 1,
                    ),
                  ),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    leftTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 42,
                        getTitlesWidget: (double value, TitleMeta meta) {
                          final int i = value.toInt();
                          if (i < 0 || i >= groups.length) {
                            return const SizedBox.shrink();
                          }
                          return Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              groups[i].name,
                              maxLines: 2,
                              textAlign: TextAlign.center,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.labelSmall,
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  barTouchData: BarTouchData(
                    touchTooltipData: BarTouchTooltipData(
                      getTooltipItem: (BarChartGroupData group, int groupIndex,
                          BarChartRodData rod, int rodIndex) {
                        return BarTooltipItem(
                          '${axis[rodIndex].label}\n'
                          '${groups[groupIndex].name} ${money.format(rod.toY)}',
                          theme.textTheme.bodySmall ?? const TextStyle(),
                        );
                      },
                    ),
                  ),
                  barGroups: <BarChartGroupData>[
                    for (int g = 0; g < groups.length; g++)
                      BarChartGroupData(
                        x: g,
                        barsSpace: 2,
                        barRods: <BarChartRodData>[
                          for (int i = 0; i < axis.length; i++)
                            BarChartRodData(
                              toY: amountFor(axis[i], groups[g].name),
                              width: 10,
                              color: monthColors[i % monthColors.length],
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(4),
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A period with no spend in it. Says so plainly rather than drawing an empty
/// circle, which would read as a rendering failure.
class _NothingToChart extends StatelessWidget {
  const _NothingToChart({required this.period});

  final String period;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          children: <Widget>[
            Icon(Icons.pie_chart_outline,
                size: 56, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text(
              'Nothing spent in $period',
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'Pick another month, or add a transaction from the '
              'Transactions tab.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
