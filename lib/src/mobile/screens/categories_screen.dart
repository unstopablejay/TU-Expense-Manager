/// The categories themselves: adding, renaming and deleting them.
library;

import 'package:flutter/material.dart';
import '../../core/constants.dart';
import '../../core/models.dart';
import '../../ui_shared/emoji_picker_sheet.dart';
import '../../ui_shared/palette.dart';
import '../database.dart';

/// Every category, what is filed under it, and the two ways to change the list:
/// add one, or be rid of one.
///
/// Deleting is never destructive of transactions: the delete has to name
/// somewhere for its rows to go, they move there whole, and the snackbar behind
/// it puts every one of them back. Uncategorized is not on offer — it is where
/// everything else falls back to, including the rows a delete moves when the
/// user picks nothing better.
///
/// Adding is here as well as in the picker on a transaction because the two
/// answer different questions. The picker adds a category because *this* charge
/// needs one and there is a keyboard already open; this screen is where someone
/// sets up the handful they intend to use before any of it arrives.
class CategoriesScreen extends StatefulWidget {
  const CategoriesScreen({super.key});

  @override
  State<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends State<CategoriesScreen> {
  final AppDatabase _db = AppDatabase.instance;

  List<CategoryUsage> _usage = const <CategoryUsage>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final List<CategoryUsage> usage = await _db.categoryUsage();
    if (!mounted) return;
    setState(() {
      _usage = usage;
      _loading = false;
    });
  }

  static bool _isFallback(CategoryUsage usage) =>
      usage.category.name == kUncategorized;

  Future<void> _add() async {
    final _CategoryFormResult? result =
        await showModalBottomSheet<_CategoryFormResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CategoryEditorSheet(
        title: 'New category',
        buttonLabel: 'Add',
        taken: <String>[
          for (final CategoryUsage usage in _usage) usage.category.name,
        ],
      ),
    );
    if (result == null || !mounted) return;

    final ExpenseCategory added =
        await _db.addCategory(result.name, icon: result.icon);
    await _load();
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Added ${added.name}')));
  }

  Future<void> _edit(CategoryUsage usage) async {
    final _CategoryFormResult? result =
        await showModalBottomSheet<_CategoryFormResult>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _CategoryEditorSheet(
        title: 'Edit category',
        buttonLabel: 'Save',
        initialName: usage.category.name,
        initialIcon: usage.category.icon.isNotEmpty
            ? usage.category.icon
            : categoryEmoji(usage.category.name),
        taken: <String>[
          for (final CategoryUsage other in _usage)
            if (other.category.id != usage.category.id) other.category.name,
        ],
      ),
    );
    if (result == null || !mounted) return;

    await _db.updateCategory(
      usage.category.id,
      name: result.name,
      icon: result.icon,
    );
    await _load();
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Updated ${result.name}')));
  }

  Future<void> _delete(CategoryUsage usage) async {
    final List<ExpenseCategory> destinations = <ExpenseCategory>[
      for (final CategoryUsage other in _usage)
        if (other.category.id != usage.category.id) other.category,
    ];
    // Uncategorized is never deletable, so there is always somewhere left for
    // the rows to go. Checked rather than trusted.
    if (destinations.isEmpty) return;

    final ExpenseCategory? into = await showModalBottomSheet<ExpenseCategory>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) =>
          _DeleteCategorySheet(usage: usage, destinations: destinations),
    );
    if (into == null || !mounted) return;

    final CategoryDeletion deletion = await _db.deleteCategory(
      category: usage.category,
      moveToId: into.id,
    );
    await _load();
    if (!mounted) return;

    final int moved = usage.txnCount;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(
          moved == 0
              ? 'Deleted ${usage.category.name}'
              : 'Deleted ${usage.category.name} · $moved '
                  'transaction${moved == 1 ? '' : 's'} now under ${into.name}',
        ),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            await _db.restoreCategory(deletion);
            await _load();
          },
        ),
      ));
  }

  String _subtitle(CategoryUsage usage) {
    final int n = usage.txnCount;
    return <String>[
      n == 0 ? 'Nothing filed under it' : '$n transaction${n == 1 ? '' : 's'}',
      if (usage.splitCount > 0) '${usage.splitCount} of them split',
      if (usage.merchantDefaultCount > 0)
        'default for ${usage.merchantDefaultCount} '
            'merchant${usage.merchantDefaultCount == 1 ? '' : 's'}',
      if (_isFallback(usage)) 'the fallback, so it stays',
    ].join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Categories')),
      floatingActionButton: _loading
          ? null
          : FloatingActionButton.extended(
              onPressed: _add,
              icon: const Icon(Icons.add),
              label: const Text('New category'),
            ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              // Clear of the button, which floats over the last row otherwise.
              padding: const EdgeInsets.only(bottom: 88),
              itemCount: _usage.length,
              itemBuilder: (BuildContext context, int index) {
                final CategoryUsage usage = _usage[index];
                final String name = usage.category.name;

                return ListTile(
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  leading: CategoryAvatar(
                    category: name,
                    explicitIcon: usage.category.icon,
                    size: 44,
                  ),
                  title: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(_subtitle(usage)),
                  onTap: _isFallback(usage) ? null : () => _edit(usage),
                  trailing: _isFallback(usage)
                      ? null
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            IconButton(
                              tooltip: 'Edit $name',
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () => _edit(usage),
                            ),
                            IconButton(
                              tooltip: 'Delete $name',
                              icon: const Icon(Icons.delete_outline),
                              color: theme.colorScheme.error,
                              onPressed: () => _delete(usage),
                            ),
                          ],
                        ),
                );
              },
            ),
    );
  }
}

class _CategoryFormResult {
  const _CategoryFormResult({required this.name, required this.icon});

  final String name;
  final String icon;
}

/// Names and styles a category with an emoji.
class _CategoryEditorSheet extends StatefulWidget {
  const _CategoryEditorSheet({
    required this.title,
    required this.buttonLabel,
    required this.taken,
    this.initialName = '',
    this.initialIcon = '',
  });

  final String title;
  final String buttonLabel;
  final List<String> taken;
  final String initialName;
  final String initialIcon;

  @override
  State<_CategoryEditorSheet> createState() => _CategoryEditorSheetState();
}

class _CategoryEditorSheetState extends State<_CategoryEditorSheet> {
  late final TextEditingController _name =
      TextEditingController(text: widget.initialName);
  late final TextEditingController _customEmoji =
      TextEditingController(text: widget.initialIcon);
  late String _selectedEmoji;
  late bool _userPickedEmojiManually;

  late final Map<String, String> _taken = <String, String>{
    for (final String name in widget.taken) name.toLowerCase(): name,
  };

  @override
  void initState() {
    super.initState();
    _selectedEmoji = widget.initialIcon.trim().isNotEmpty
        ? widget.initialIcon.trim()
        : (widget.initialName.trim().isNotEmpty
            ? categoryEmoji(widget.initialName)
            : '🏷️');
    _userPickedEmojiManually = widget.initialIcon.trim().isNotEmpty;
  }

  @override
  void dispose() {
    _name.dispose();
    _customEmoji.dispose();
    super.dispose();
  }

  void _submit() {
    final String name = _name.text.trim();
    if (name.isEmpty || _taken.containsKey(name.toLowerCase())) return;
    final String icon = _selectedEmoji.trim().isNotEmpty
        ? _selectedEmoji.trim()
        : suggestCategoryEmoji(name);
    Navigator.pop(
      context,
      _CategoryFormResult(name: name, icon: icon),
    );
  }

  Future<void> _pickEmojiFromSheet() async {
    final picked = await showEmojiPickerSheet(
      context,
      initialEmoji: _selectedEmoji,
    );
    if (picked != null && picked.isNotEmpty) {
      setState(() {
        _selectedEmoji = picked;
        _customEmoji.text = picked;
        _userPickedEmojiManually = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final String typed = _name.text.trim();
    final String? clash = _taken[typed.toLowerCase()];
    final Color previewColor =
        categoryColor(typed.isEmpty ? 'Category' : typed, theme.brightness);

    return Padding(
      // Lifts the field clear of the keyboard.
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
              'Customize your category name and unique colourful emoji.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Tooltip(
                  message: 'Tap to browse all emojis',
                  child: InkWell(
                    onTap: _pickEmojiFromSheet,
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: previewColor.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: previewColor.withValues(alpha: 0.45),
                          width: 1.5,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        _selectedEmoji,
                        style: const TextStyle(fontSize: 28),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: TextField(
                    controller: _name,
                    autofocus: widget.initialName.isEmpty,
                    textCapitalization: TextCapitalization.words,
                    onChanged: (String val) {
                      if (!_userPickedEmojiManually) {
                        _selectedEmoji = suggestCategoryEmoji(val);
                      }
                      setState(() {});
                    },
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      isDense: true,
                      border: const OutlineInputBorder(),
                      labelText: 'Category name',
                      errorText: clash == null ? null : '$clash already exists',
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                Text(
                  'Quick emoji picker',
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                TextButton.icon(
                  onPressed: _pickEmojiFromSheet,
                  icon: const Icon(Icons.grid_view_outlined, size: 16),
                  label: const Text('Browse all'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            SizedBox(
              height: 48,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: kCuratedCategoryEmojis.length,
                separatorBuilder: (_, _) => const SizedBox(width: 8),
                itemBuilder: (BuildContext ctx, int i) {
                  final String emoji = kCuratedCategoryEmojis[i];
                  final bool isSelected = _selectedEmoji == emoji;
                  return InkWell(
                    onTap: () {
                      setState(() {
                        _selectedEmoji = emoji;
                        _customEmoji.text = emoji;
                        _userPickedEmojiManually = true;
                      });
                    },
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      width: 44,
                      height: 44,
                      decoration: BoxDecoration(
                        color: isSelected
                            ? theme.colorScheme.primaryContainer
                            : theme.colorScheme.surfaceContainerHighest
                                .withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isSelected
                              ? theme.colorScheme.primary
                              : theme.colorScheme.outlineVariant
                                  .withValues(alpha: 0.4),
                          width: isSelected ? 2 : 1,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        emoji,
                        style: const TextStyle(fontSize: 22),
                      ),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                SizedBox(
                  width: 140,
                  child: TextField(
                    controller: _customEmoji,
                    maxLength: 2,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      labelText: 'Custom emoji',
                      counterText: '',
                    ),
                    onChanged: (String val) {
                      if (val.trim().isNotEmpty) {
                        setState(() {
                          _selectedEmoji = val.trim();
                          _userPickedEmojiManually = true;
                        });
                      }
                    },
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: typed.isEmpty || clash != null ? null : _submit,
                  child: Text(widget.buttonLabel),
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

/// Says where a deleted category's transactions go, and is the confirmation for
/// deleting it.
///
/// One step rather than two. The destination and the consequence of choosing it
/// are on screen together, so a dialog after this would be asking again about
/// something already spelled out — and the snackbar behind it carries Undo.
class _DeleteCategorySheet extends StatefulWidget {
  const _DeleteCategorySheet({required this.usage, required this.destinations});

  final CategoryUsage usage;

  /// Every category except the one being deleted, in [AppDatabase.categories]
  /// order — so Uncategorized, the default pick, is first.
  final List<ExpenseCategory> destinations;

  @override
  State<_DeleteCategorySheet> createState() => _DeleteCategorySheetState();
}

class _DeleteCategorySheetState extends State<_DeleteCategorySheet> {
  /// Uncategorized where it is there to be had. It is the honest default: the
  /// app cannot know which of the remaining categories these transactions
  /// belonged in, and quietly filing them under a real one would invent an
  /// answer the ledger would then show as fact.
  late ExpenseCategory _into = widget.destinations.firstWhere(
    (ExpenseCategory c) => c.name == kUncategorized,
    orElse: () => widget.destinations.first,
  );

  /// What the delete will do, in the numbers actually at stake.
  String get _consequence {
    final CategoryUsage usage = widget.usage;
    if (!usage.inUse) return 'Nothing is filed under it, so nothing moves.';

    final int n = usage.txnCount;
    final List<String> moving = <String>[
      if (n > 0) '$n transaction${n == 1 ? '' : 's'}',
      if (usage.merchantDefaultCount > 0)
        '${usage.merchantDefaultCount} merchant '
            'default${usage.merchantDefaultCount == 1 ? '' : 's'}',
    ];
    return '${moving.join(' and ')} move to the category you pick. '
        'Nothing is thrown away, and this can be undone.'
        '${usage.splitCount > 0 ? ' The '
            '${usage.splitCount} split one${usage.splitCount == 1 ? '' : 's'} '
            'keep their other lines and still add up.' : ''}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final CategoryUsage usage = widget.usage;

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
            Text('Delete ${usage.category.name}',
                style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(_consequence, style: theme.textTheme.bodySmall),
            if (usage.inUse) ...<Widget>[
              const SizedBox(height: 16),
              Text('Move them to', style: theme.textTheme.labelLarge),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  for (final ExpenseCategory category in widget.destinations)
                    ChoiceChip(
                      avatar: Text(
                        categoryEmoji(
                          category.name,
                          explicitIcon: category.icon,
                        ),
                        style: const TextStyle(fontSize: 16),
                      ),
                      label: Text(category.name),
                      selected: category.id == _into.id,
                      onSelected: (_) => setState(() => _into = category),
                    ),
                ],
              ),
            ],
            const Divider(height: 32),
            Row(
              children: <Widget>[
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.colorScheme.error,
                    foregroundColor: theme.colorScheme.onError,
                  ),
                  onPressed: () => Navigator.pop(context, _into),
                  child: const Text('Delete'),
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
