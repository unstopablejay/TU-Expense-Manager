/// The dashboard: the same ledger as charts.
///
/// Prop-driven for its data, which is what lets the web build render this
/// exact screen from a snapshot instead of from SQLite. It does hold one bit
/// of its own state — which view is on screen — but that is a drawing
/// preference, not data, and does not touch anything the snapshot has to
/// supply.
library;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/ledger.dart';
import '../core/models.dart';
import '../core/splits.dart';
import 'compare_months_screen.dart';
import 'palette.dart';
import 'shared_controls.dart';

/// The ways the breakdown card can draw the same period.
///
/// [icon] is what the collapsed selector and the empty state show; [label] is
/// what the menu spells each option as.
enum DashboardView {
  pie('Pie chart', Icons.pie_chart_outline),
  bars('Ranked bars', Icons.bar_chart_outlined),
  trend('Spend over time', Icons.show_chart),
  compareMonths('Compare months', Icons.stacked_bar_chart_outlined),
  table('Category list', Icons.view_list_outlined);

  const DashboardView(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// Which views make sense for [months].
///
/// [DashboardView.trend] needs an explicit month to lay a day axis against, so
/// it drops out for "All time" ([months] empty). [DashboardView.compareMonths]
/// only answers a question when there is more than one month to compare —
/// with one month it would just draw the same bars [DashboardView.bars]
/// already does, one series instead of several.
List<DashboardView> availableViews(Set<YearMonth> months) => <DashboardView>[
      DashboardView.pie,
      DashboardView.bars,
      if (months.isNotEmpty) DashboardView.trend,
      if (months.length > 1) DashboardView.compareMonths,
      DashboardView.table,
    ];

/// Where the money went over a chosen period.
///
/// Reads the whole ledger and narrows it by month **and nothing else**. It
/// deliberately does not inherit the transaction list's category, merchant,
/// card or search filters: a breakdown steered by a working list's filter state
/// is not a report, and a pie chart of a single category is not a chart.
class DashboardTab extends StatefulWidget {
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
    this.emptyDetail,
  });

  final List<ExpenseTxn> transactions;
  final Set<YearMonth> months;
  final List<YearMonth> monthChoices;
  final YearMonth currentMonth;
  final NumberFormat money;
  final bool loading;

  /// What to say when a period has nothing in it, where the default advice does
  /// not apply — a browser has no way to add a transaction.
  final String? emptyDetail;
  final ValueChanged<Set<YearMonth>> onMonthsChanged;
  final Future<void> Function() onRefresh;

  @override
  State<DashboardTab> createState() => _DashboardTabState();
}

class _DashboardTabState extends State<DashboardTab> {
  DashboardView _view = DashboardView.pie;

  @override
  Widget build(BuildContext context) {
    final List<LedgerEntry> entries =
        applyFilters(widget.transactions, months: widget.months);
    final totals = periodTotals(entries);
    final Map<CategoryIdentity, double> byCategory = spendByCategory(entries);
    final List<DashboardView> views = availableViews(widget.months);
    // The remembered choice can fall out of the offered list — "Compare
    // months" survives a narrow back to one month — so it is only ever
    // trusted when it is still on offer.
    final DashboardView view = views.contains(_view) ? _view : DashboardView.pie;

    final Map<String, String> categoryIcons = <String, String>{
      for (final ExpenseTxn t in widget.transactions) ...<String, String>{
        if (t.categoryIcon.isNotEmpty) t.categoryName: t.categoryIcon,
        for (final TxnSplit s in t.effectiveSplits)
          if (s.categoryIcon.isNotEmpty) s.categoryName: s.categoryIcon,
      },
    };

    return Column(
      children: <Widget>[
        PeriodBar(
          months: widget.months,
          options: widget.monthChoices,
          currentMonth: widget.currentMonth,
          onChanged: widget.onMonthsChanged,
        ),
        Expanded(
          child: widget.loading
              ? const Center(child: CircularProgressIndicator())
              : RefreshIndicator(
                  onRefresh: widget.onRefresh,
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                    children: <Widget>[
                      _SpendHeadline(
                        spent: totals.spent,
                        received: totals.received,
                        count: totals.count,
                        period: periodLabel(widget.months),
                        money: widget.money,
                      ),
                      if (byCategory.isEmpty)
                        _NothingToChart(
                          detail: widget.emptyDetail,
                          period: periodLabel(widget.months),
                        )
                      else
                        _DashboardChartCard(
                          view: view,
                          views: views,
                          onViewChanged: (DashboardView v) =>
                              setState(() => _view = v),
                          byCategory: byCategory,
                          categoryIcons: categoryIcons,
                          entries: entries,
                          months: widget.months,
                          money: widget.money,
                        ),
                      _CompareShortcutCard(
                        transactions: widget.transactions,
                        monthChoices: widget.monthChoices,
                        money: widget.money,
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

/// The one card the breakdown lives in: a title and a view-selector header
/// that stay the same shape across every view, and whichever body [view]
/// picks underneath.
///
/// Pulling the header out here rather than letting each body draw its own is
/// what makes the selector show up once, in the same place, for every view —
/// instead of five near-identical headers that could each drift.
class _DashboardChartCard extends StatelessWidget {
  const _DashboardChartCard({
    required this.view,
    required this.views,
    required this.onViewChanged,
    required this.byCategory,
    this.categoryIcons = const <String, String>{},
    required this.entries,
    required this.months,
    required this.money,
  });

  final DashboardView view;
  final List<DashboardView> views;
  final ValueChanged<DashboardView> onViewChanged;
  final Map<CategoryIdentity, double> byCategory;
  final Map<String, String> categoryIcons;
  final List<LedgerEntry> entries;
  final Set<YearMonth> months;
  final NumberFormat money;

  String get _title => switch (view) {
        DashboardView.pie ||
        DashboardView.bars ||
        DashboardView.table =>
          'Where it went',
        DashboardView.trend => 'Spend over time',
        DashboardView.compareMonths => 'Month by month',
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Widget body = switch (view) {
      DashboardView.pie => _PieBody(
          byCategory: byCategory,
          money: money,
          categoryIcons: categoryIcons,
        ),
      DashboardView.bars => _BarsBody(
          byCategory: byCategory,
          money: money,
          categoryIcons: categoryIcons,
        ),
      DashboardView.trend =>
        _TrendBody(entries: entries, months: months, money: money),
      DashboardView.compareMonths =>
        _CompareMonthsBody(entries: entries, months: months, money: money),
      DashboardView.table => _TableBody(
          byCategory: byCategory,
          money: money,
          categoryIcons: categoryIcons,
        ),
    };

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    _title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                const SizedBox(width: 8),
                _ViewMenuButton(
                  views: views,
                  selected: view,
                  onSelected: onViewChanged,
                ),
              ],
            ),
            const SizedBox(height: 16),
            body,
          ],
        ),
      ),
    );
  }
}

/// The dropdown itself: the active view's icon and name, opening a menu of
/// [views] on tap. Shaped like the app's other outlined controls (see
/// [PeriodBar]) so it reads as one more control in the same family rather
/// than a one-off.
class _ViewMenuButton extends StatelessWidget {
  const _ViewMenuButton({
    required this.views,
    required this.selected,
    required this.onSelected,
  });

  final List<DashboardView> views;
  final DashboardView selected;
  final ValueChanged<DashboardView> onSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopupMenuButton<DashboardView>(
      tooltip: 'Change view',
      initialValue: selected,
      onSelected: onSelected,
      itemBuilder: (BuildContext context) => <PopupMenuEntry<DashboardView>>[
        for (final DashboardView option in views)
          PopupMenuItem<DashboardView>(
            value: option,
            child: Row(
              children: <Widget>[
                Icon(
                  option.icon,
                  size: 18,
                  color: option == selected ? theme.colorScheme.primary : null,
                ),
                const SizedBox(width: 10),
                Text(option.label),
                if (option == selected) ...<Widget>[
                  const Spacer(),
                  Icon(Icons.check, size: 16, color: theme.colorScheme.primary),
                ],
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: theme.colorScheme.outline),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(selected.icon, size: 16),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                selected.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge,
              ),
            ),
            const Icon(Icons.arrow_drop_down, size: 18),
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
class _PieBody extends StatelessWidget {
  const _PieBody({
    required this.byCategory,
    required this.money,
    this.categoryIcons = const <String, String>{},
  });

  final Map<CategoryIdentity, double> byCategory;
  final NumberFormat money;
  final Map<String, String> categoryIcons;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Brightness brightness = theme.brightness;
    final List<CategorySlice> slices = topCategories(byCategory);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
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
                    color: categoryColor(slice.name, brightness, explicitColor: slice.color),
                    radius: 34,
                    showTitle: false,
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        for (final CategorySlice slice in slices)
          _CategoryRow(
            slice: slice,
            money: money,
            categoryIcons: categoryIcons,
          ),
      ],
    );
  }
}

/// The same breakdown as [_PieBody], but led with the bars rather than the
/// donut — easier than a slice angle for telling two close categories apart.
class _BarsBody extends StatelessWidget {
  const _BarsBody({
    required this.byCategory,
    required this.money,
    this.categoryIcons = const <String, String>{},
  });

  final Map<CategoryIdentity, double> byCategory;
  final NumberFormat money;
  final Map<String, String> categoryIcons;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Brightness brightness = theme.brightness;
    final List<CategorySlice> slices = topCategories(byCategory);
    final double maxAmount = slices.isEmpty
        ? 1
        : slices
            .map((CategorySlice s) => s.amount)
            .reduce((double a, double b) => a > b ? a : b);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final CategorySlice slice in slices)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    CategoryAvatar(
                      category: slice.name,
                      explicitIcon: categoryIcons[slice.name],
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
                        slice.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                    Text(
                      '${(slice.share * 100).round()}%',
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      money.format(slice.amount),
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LayoutBuilder(
                    builder: (BuildContext context, BoxConstraints c) => Stack(
                      children: <Widget>[
                        Container(
                          height: 8,
                          width: c.maxWidth,
                          color: theme.colorScheme.surfaceContainerHighest,
                        ),
                        Container(
                          height: 8,
                          width: c.maxWidth *
                              (maxAmount == 0 ? 0 : slice.amount / maxAmount),
                          color: categoryColor(slice.name, brightness, explicitColor: slice.color),
                        ),
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

/// The full breakdown as plain figures — every category, none folded into
/// "Other" — for whoever wants exact numbers rather than a shape.
class _TableBody extends StatelessWidget {
  const _TableBody({
    required this.byCategory,
    required this.money,
    this.categoryIcons = const <String, String>{},
  });

  final Map<CategoryIdentity, double> byCategory;
  final NumberFormat money;
  final Map<String, String> categoryIcons;

  @override
  Widget build(BuildContext context) {
    // No cap and so no "Other": the point of this view is the exact figures a
    // capped chart legend cannot show all of.
    final List<CategorySlice> slices = topCategories(
      byCategory,
      limit: byCategory.isEmpty ? 1 : byCategory.length,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final CategorySlice slice in slices)
          _CategoryRow(
            slice: slice,
            money: money,
            categoryIcons: categoryIcons,
          ),
      ],
    );
  }
}

/// One category, its share and its amount — the row [_PieBody] and
/// [_TableBody] both list, so the two can never disagree on how a category is
/// drawn.
class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.slice,
    required this.money,
    this.categoryIcons = const <String, String>{},
  });

  final CategorySlice slice;
  final NumberFormat money;
  final Map<String, String> categoryIcons;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Brightness brightness = theme.brightness;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: <Widget>[
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: categoryColor(slice.name, brightness, explicitColor: slice.color),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          const SizedBox(width: 10),
          CategoryAvatar(
            category: slice.name,
            explicitIcon: categoryIcons[slice.name],
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
            style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}

/// Daily spend, one line per selected month, laid over a shared day-of-month
/// axis rather than the calendar — so months of different lengths and
/// non-adjacent months overlay for comparison instead of needing a shared
/// timeline with gaps in it.
class _TrendBody extends StatelessWidget {
  const _TrendBody({
    required this.entries,
    required this.months,
    required this.money,
  });

  final List<LedgerEntry> entries;
  final Set<YearMonth> months;
  final NumberFormat money;

  static int _daysIn(YearMonth m) => DateTime(m.year, m.month + 1, 0).day;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Brightness brightness = theme.brightness;

    final Map<YearMonth, Map<int, double>> perMonth = spendByDayPerMonth(entries);
    final List<YearMonth> axis = comparedMonths(months);
    final List<Color> monthColors = chartHues(brightness);

    final int maxDays = axis.isEmpty
        ? 31
        : axis.map(_daysIn).reduce((int a, int b) => a > b ? a : b);

    double maxY = 1;
    for (final YearMonth m in axis) {
      for (final double v in (perMonth[m] ?? const <int, double>{}).values) {
        if (v > maxY) maxY = v;
      }
    }
    final int tickEvery = (maxDays / 6).ceil().clamp(1, maxDays);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        // A legend only earns its space once there is more than one line to
        // tell apart.
        if (axis.length > 1)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Wrap(
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
          ),
        SizedBox(
          height: 220,
          child: LineChart(
            LineChartData(
              minX: 1,
              maxX: maxDays.toDouble(),
              minY: 0,
              maxY: maxY * 1.15,
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
                topTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                leftTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    reservedSize: 28,
                    interval: tickEvery.toDouble(),
                    getTitlesWidget: (double value, TitleMeta meta) => Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        value.toInt().toString(),
                        style: theme.textTheme.labelSmall,
                      ),
                    ),
                  ),
                ),
              ),
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  getTooltipItems: (List<LineBarSpot> spots) => <LineTooltipItem>[
                    for (final LineBarSpot spot in spots)
                      LineTooltipItem(
                        '${axis[spot.barIndex].label} · day ${spot.x.toInt()}\n'
                        '${money.format(spot.y)}',
                        theme.textTheme.bodySmall ?? const TextStyle(),
                      ),
                  ],
                ),
              ),
              lineBarsData: <LineChartBarData>[
                for (int i = 0; i < axis.length; i++)
                  LineChartBarData(
                    spots: <FlSpot>[
                      for (int d = 1; d <= _daysIn(axis[i]); d++)
                        FlSpot(d.toDouble(), perMonth[axis[i]]?[d] ?? 0),
                    ],
                    isCurved: true,
                    color: monthColors[i % monthColors.length],
                    barWidth: 2,
                    dotData: const FlDotData(show: false),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// The same spend, several months at a time: one group per category, one bar
/// per month within it.
///
/// Months are the series here, not categories — the question this chart answers
/// is "did this go up or down", so it is the months that have to be told apart.
class _CompareMonthsBody extends StatelessWidget {
  const _CompareMonthsBody({
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

    final Map<YearMonth, Map<CategoryIdentity, double>> perMonth =
        spendByCategoryPerMonth(entries);
    final List<YearMonth> axis = comparedMonths(months);
    // The categories worth drawing, ranked over the whole period so the groups
    // are in a stable, meaningful order rather than one month's order.
    final List<CategorySlice> ranked = topCategories(
      spendByCategory(entries),
      limit: 6,
    );
    final List<Color> monthColors = chartHues(brightness);

    double amountFor(YearMonth m, CategorySlice s) =>
        perMonth[m]?[CategoryIdentity(s.name, s.color)] ?? 0;

    // "Other" is a bucket, not a category, so it cannot be looked up per month.
    final List<CategorySlice> groups = ranked
        .where((CategorySlice s) => s.name != kOtherCategory)
        .toList();

    final double maxY = <double>[
      for (final CategorySlice s in groups)
        for (final YearMonth m in axis) amountFor(m, s),
      1,
    ].reduce((double a, double b) => a > b ? a : b);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
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
                topTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                rightTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                leftTitles:
                    const AxisTitles(sideTitles: SideTitles(showTitles: false)),
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
                          toY: amountFor(axis[i], groups[g]),
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
    );
  }
}

/// A period with no spend in it. Says so plainly rather than drawing an empty
/// circle, which would read as a rendering failure.
class _NothingToChart extends StatelessWidget {
  const _NothingToChart({required this.period, this.detail});

  final String period;

  /// Replaces the advice under the title. The default points at the
  /// Transactions tab's add button, which a read-only view does not have.
  final String? detail;

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
              detail ??
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

class _CompareShortcutCard extends StatelessWidget {
  const _CompareShortcutCard({
    required this.transactions,
    required this.monthChoices,
    required this.money,
  });

  final List<ExpenseTxn> transactions;
  final List<YearMonth> monthChoices;
  final NumberFormat money;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(top: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        child: Row(
          children: <Widget>[
            Icon(
              Icons.stacked_bar_chart_outlined,
              color: theme.colorScheme.primary,
              size: 28,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Month-over-month breakdown',
                    style: theme.textTheme.titleSmall,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Compare category spending across 2–6 months',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonal(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => CompareMonthsScreen(
                    transactions: transactions,
                    monthChoices: monthChoices,
                    money: money,
                  ),
                ),
              ),
              child: const Text('Compare →'),
            ),
          ],
        ),
      ),
    );
  }
}
