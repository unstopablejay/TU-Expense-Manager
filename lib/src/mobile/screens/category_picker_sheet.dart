/// Picking a category, and optionally making it a merchant's default.
library;

import 'package:flutter/material.dart';
import '../../core/constants.dart';
import '../../core/models.dart';
import '../../ui_shared/palette.dart';
import '../database.dart';

/// What came back from [CategoryPickerSheet]: the category, and whether the
/// user also asked for it to become the merchant's default.
///
/// The two are separate because picking a category is now a statement about
/// *this transaction* — making it the merchant's rule as well is a second,
/// deliberate act.
class CategoryChoice {
  const CategoryChoice({required this.category, this.makeDefault = false});

  final ExpenseCategory category;
  final bool makeDefault;
}

/// Picks a category, and — where the caller asks for it — offers to make that
/// pick the merchant's default too.
///
/// Used in three places: correcting one transaction, filling a row of a split,
/// and setting a merchant's default outright. [showMakeDefault] and
/// [alwaysAskLabel] are what separate them.
class CategoryPickerSheet extends StatefulWidget {
  const CategoryPickerSheet({
    super.key,
    required this.merchant,
    required this.categories,
    this.selectedId,
    this.title = 'Categorize',
    this.subtitle,
    this.showMakeDefault = false,
    this.alwaysAskLabel,
  });

  final String merchant;
  final List<ExpenseCategory> categories;
  final int? selectedId;
  final String title;
  final String? subtitle;

  /// Shows the "also make this the default" checkbox. Off for a split row,
  /// where the pick describes one line of one transaction and nothing more.
  final bool showMakeDefault;

  /// When set, an entry with this label appears first and returns the
  /// Uncategorized category — how "always ask me" is chosen and stored.
  final String? alwaysAskLabel;

  @override
  State<CategoryPickerSheet> createState() => _CategoryPickerSheetState();
}

class _CategoryPickerSheetState extends State<CategoryPickerSheet> {
  final TextEditingController _newCategory = TextEditingController();
  bool _creating = false;
  bool _makeDefault = false;

  @override
  void dispose() {
    _newCategory.dispose();
    super.dispose();
  }

  void _choose(ExpenseCategory category) => Navigator.pop(
        context,
        CategoryChoice(category: category, makeDefault: _makeDefault),
      );

  Future<void> _createAndSelect() async {
    final name = _newCategory.text.trim();
    if (name.isEmpty || _creating) return;
    setState(() => _creating = true);
    final category = await AppDatabase.instance.addCategory(
      name,
      icon: suggestCategoryEmoji(name),
    );
    if (!mounted) return;
    _choose(category);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ExpenseCategory? uncategorized = widget.categories
        .where((ExpenseCategory c) => c.name == kUncategorized)
        .firstOrNull;

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(widget.title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              widget.merchant,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.primary),
            ),
            if (widget.subtitle != null) ...<Widget>[
              const SizedBox(height: 4),
              Text(widget.subtitle!, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 16),
            if (widget.alwaysAskLabel != null && uncategorized != null) ...<Widget>[
              ActionChip(
                avatar: const Text('❓', style: TextStyle(fontSize: 16)),
                label: Text(widget.alwaysAskLabel!),
                onPressed: () => _choose(uncategorized),
              ),
              const SizedBox(height: 12),
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final category in widget.categories)
                  // Uncategorized is not a category anyone means to pick; where
                  // it is meaningful it is offered above, in the words that
                  // actually describe what it does.
                  if (category.name != kUncategorized)
                    ChoiceChip(
                      avatar: Text(
                        categoryEmoji(
                          category.name,
                          explicitIcon: category.icon,
                        ),
                        style: const TextStyle(fontSize: 16),
                      ),
                      label: Text(category.name),
                      selected: category.id == widget.selectedId,
                      onSelected: (_) => _choose(category),
                    ),
              ],
            ),
            if (widget.showMakeDefault) ...<Widget>[
              const SizedBox(height: 8),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                dense: true,
                value: _makeDefault,
                onChanged: (bool? v) =>
                    setState(() => _makeDefault = v ?? false),
                title: const Text('Also make this the default'),
                subtitle: Text(
                  'Future transactions from ${widget.merchant} will use it.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
            const Divider(height: 32),
            Row(
              children: <Widget>[
                Expanded(
                  child: TextField(
                    controller: _newCategory,
                    textCapitalization: TextCapitalization.words,
                    onSubmitted: (_) => _createAndSelect(),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      labelText: 'New category',
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton(
                  onPressed: _creating ? null : _createAndSelect,
                  child: const Text('Add'),
                ),
              ],
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// MERGING DUPLICATE NAMES
// ---------------------------------------------------------------------------
