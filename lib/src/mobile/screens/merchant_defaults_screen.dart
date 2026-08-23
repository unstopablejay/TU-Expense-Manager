/// Every merchant the ledger has seen, and what each one files itself under.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/constants.dart';
import '../../core/models.dart';
import '../../ui_shared/palette.dart';
import '../database.dart';
import 'category_picker_sheet.dart';

/// Every merchant the ledger has seen, and what each one is filed under by
/// default.
///
/// Three states, and the difference between the first two is the point of the
/// screen: a merchant with no default at all has simply never been set up,
/// while one set to "always ask me" has been looked at and deliberately left
/// uncategorised — because its charges cover several categories at once and
/// always need splitting by hand.
class MerchantDefaultsScreen extends StatefulWidget {
  const MerchantDefaultsScreen({super.key});

  @override
  State<MerchantDefaultsScreen> createState() => _MerchantDefaultsScreenState();
}

class _MerchantDefaultsScreenState extends State<MerchantDefaultsScreen> {
  final NumberFormat _money =
      NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 0);

  List<MerchantSummary> _merchants = <MerchantSummary>[];
  List<ExpenseCategory> _categories = <ExpenseCategory>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final results = await Future.wait(<Future<Object>>[
      AppDatabase.instance.merchants(),
      AppDatabase.instance.categories(),
    ]);
    if (!mounted) return;
    setState(() {
      _merchants = results[0] as List<MerchantSummary>;
      _categories = results[1] as List<ExpenseCategory>;
      _loading = false;
    });
  }

  Future<void> _setDefault(MerchantSummary merchant) async {
    final CategoryChoice? chosen = await showModalBottomSheet<CategoryChoice>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => CategoryPickerSheet(
        merchant: merchant.merchant,
        categories: _categories,
        selectedId: merchant.defaultCategoryId,
        title: 'Default category',
        subtitle: 'Used for transactions imported from now on.',
        alwaysAskLabel: 'Always ask me',
      ),
    );
    if (chosen == null || !mounted) return;

    final int uncategorized = await AppDatabase.instance.uncategorizedId();
    var backfill = false;

    // "Always ask me" is never applied backwards — doing so would wipe out
    // exactly the per-transaction work it exists to protect.
    if (chosen.category.id != uncategorized) {
      final int n = await AppDatabase.instance.backfillableCount(
        merchant: merchant.merchant,
        categoryId: chosen.category.id,
      );
      if (!mounted) return;
      if (n > 0) {
        backfill = await showDialog<bool>(
              context: context,
              builder: (BuildContext context) => AlertDialog(
                title: const Text('Apply to past transactions?'),
                content: Text(
                  '$n past transaction${n == 1 ? '' : 's'} from '
                  '${merchant.merchant} would move to '
                  '${chosen.category.name}. Transactions you have split are '
                  'left alone.',
                ),
                actions: <Widget>[
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Future only'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: Text('Apply to $n'),
                  ),
                ],
              ),
            ) ??
            false;
      }
    }
    if (!mounted) return;

    final int updated = await AppDatabase.instance.setMerchantDefault(
      merchant: merchant.merchant,
      categoryId: chosen.category.id,
      backfill: backfill,
    );
    await _load();
    if (!mounted) return;
    final String label = chosen.category.id == uncategorized
        ? 'Always ask me'
        : chosen.category.name;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(
        content: Text(
          '${merchant.merchant} → $label'
          '${updated > 0 ? ' ($updated updated)' : ''}',
        ),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Merchants & defaults')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _merchants.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(32),
                    child: Text(
                      'No merchants yet. They appear here as transactions '
                      'arrive.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: _merchants.length,
                  itemBuilder: (BuildContext context, int index) {
                    final MerchantSummary m = _merchants[index];
                    final bool alwaysAsk =
                        m.defaultCategoryName == kUncategorized;
                    final bool unset = m.defaultCategoryId == null;

                    return ListTile(
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: unset || alwaysAsk
                              ? theme.colorScheme.surfaceContainerHighest
                              : categoryColor(m.defaultCategoryName!, theme.brightness)
                                  .withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(11),
                          border: Border.all(
                            color: unset || alwaysAsk
                                ? theme.colorScheme.outlineVariant
                                    .withValues(alpha: 0.4)
                                : categoryColor(m.defaultCategoryName!, theme.brightness)
                                    .withValues(alpha: 0.3),
                            width: 1,
                          ),
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          alwaysAsk || unset
                              ? '❓'
                              : categoryEmoji(m.defaultCategoryName!),
                          style: const TextStyle(fontSize: 20),
                        ),
                      ),
                      title: Text(
                        m.merchant,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        '${m.txnCount} transaction'
                        '${m.txnCount == 1 ? '' : 's'} · '
                        '${_money.format(m.totalSpent)}',
                      ),
                      trailing: Text(
                        unset
                            ? 'Not set'
                            : alwaysAsk
                                ? 'Always ask me'
                                : m.defaultCategoryName!,
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: unset
                              ? theme.colorScheme.onSurfaceVariant
                              : theme.colorScheme.primary,
                        ),
                      ),
                      onTap: () => _setDefault(m),
                    );
                  },
                ),
    );
  }
}
