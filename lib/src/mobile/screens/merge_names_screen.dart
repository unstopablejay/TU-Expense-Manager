/// Folding several labels for one real card, account or merchant into one name.
///
/// Nothing here rewrites a transaction. A merge is a standing rule kept in
/// `name_aliases` and applied when rows are read, which is what lets a future
/// alert in the old spelling fold in by itself.
library;

import 'package:flutter/material.dart';
import '../../core/aliases.dart';
import '../../core/models.dart';
import '../../ui_shared/loading_dialog.dart';
import '../database.dart';
import '../widgets/settings_header.dart';

/// Folds several labels for one real card, account or merchant into one name.
///
/// The banks are not consistent — the same account arrives as `BANK A/c
/// XX0444`, `HDFC Bank A/C *0444` and `HDFC Bank A/c XX0444` depending on which
/// template the alert matched — so the filter offers three choices where there
/// is one account, and the totals split across them.
///
/// Nothing here rewrites a transaction. A merge is a standing rule kept in
/// `name_aliases` and applied when rows are read, which is what lets a future
/// alert in the old format fold in by itself, and what makes [_separate]
/// possible at all.
class MergeNamesScreen extends StatefulWidget {
  const MergeNamesScreen({
    super.key,
    required this.kind,
    this.preselect,
    this.onChanged,
  });

  final NameKind kind;

  /// Ticked on arrival — set when this was opened from a transaction, so the
  /// name the user was looking at is already in the selection.
  final String? preselect;

  /// Reloads whoever pushed this. Null from Settings, where the shell already
  /// reloads on leaving the tab.
  final Future<void> Function()? onChanged;

  @override
  State<MergeNamesScreen> createState() => _MergeNamesScreenState();
}

class _MergeNamesScreenState extends State<MergeNamesScreen> {
  final AppDatabase _db = AppDatabase.instance;

  bool _loading = true;
  NameAliases _aliases = NameAliases.empty;

  /// Current name → how many transactions are under it.
  Map<String, int> _counts = <String, int>{};

  /// Current name → the spellings actually stored beneath it. Read from the
  /// ledger rather than from the alias table, which cannot tell two labels
  /// differing only in case apart.
  Map<String, Set<String>> _labels = <String, Set<String>>{};

  final Set<String> _selected = <String>{};

  @override
  void initState() {
    super.initState();
    final String? preselect = widget.preselect;
    if (preselect != null) _selected.add(preselect);
    _load();
  }

  String _nameOf(ExpenseTxn t) =>
      widget.kind == NameKind.merchant ? t.merchant : t.paymentType;

  String _rawOf(ExpenseTxn t) =>
      widget.kind == NameKind.merchant ? t.rawMerchant : t.rawPaymentType;

  Future<void> _load() async {
    final results = await Future.wait(<Future<Object>>[
      _db.transactions(),
      _db.aliases(),
    ]);
    if (!mounted) return;

    final counts = <String, int>{};
    final labels = <String, Set<String>>{};
    for (final ExpenseTxn t in results[0] as List<ExpenseTxn>) {
      final String name = _nameOf(t);
      counts[name] = (counts[name] ?? 0) + 1;
      (labels[name] ??= <String>{}).add(_rawOf(t));
    }

    setState(() {
      _aliases = results[1] as NameAliases;
      _counts = counts;
      _labels = labels;
      _loading = false;
      // A name can stop existing while this screen is open — its last
      // transaction deleted, or it was folded into something else.
      _selected.retainAll(counts.keys);
    });
  }

  void _toggle(String name) {
    setState(() {
      if (!_selected.remove(name)) _selected.add(name);
    });
  }

  void _clearSelection() => setState(_selected.clear);

  Future<void> _apply(Map<String, String> rows, String message) async {
    final Map<String, String> before = _aliases.rowsFor(widget.kind);
    await withLoadingModal<void>(
      context: context,
      message: 'Applying merge…',
      subtitle: 'Updating name aliases…',
      task: () async {
        await _db.setAliases(widget.kind, rows);
        setState(_selected.clear);
        await Future.wait(<Future<void>>[
          _load(),
          if (widget.onChanged != null) widget.onChanged!(),
        ]);
      },
    );
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(message),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            await _db.setAliases(widget.kind, before);
            await Future.wait(<Future<void>>[
              _load(),
              if (widget.onChanged != null) widget.onChanged!(),
            ]);
          },
        ),
      ));
  }

  Future<void> _mergeSelected() async {
    // Most-used first, so the sheet can offer the winning spelling as the name.
    final List<String> members = _selected.toList()
      ..sort((String a, String b) {
        final int byCount = (_counts[b] ?? 0).compareTo(_counts[a] ?? 0);
        return byCount != 0 ? byCount : a.compareTo(b);
      });
    if (members.length < 2) return;

    final String? name = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _MergeNameSheet(
        kind: widget.kind,
        members: members,
        counts: _counts,
      ),
    );
    if (!mounted || name == null || name.trim().isEmpty) return;

    final int moved =
        members.fold<int>(0, (int sum, String m) => sum + (_counts[m] ?? 0));
    await _apply(
      mergePlan(_aliases.rowsFor(widget.kind), members.toSet(), name.trim()),
      'Merged ${members.length} labels · $moved '
      'transaction${moved == 1 ? '' : 's'}',
    );
  }

  Future<void> _mergeSuggested(List<String> group) async {
    setState(() {
      _selected
        ..clear()
        ..addAll(group);
    });
    await _mergeSelected();
  }

  Future<void> _separate(String canonical) async {
    final Map<String, String> rows =
        Map<String, String>.of(_aliases.rowsFor(widget.kind))
          ..removeWhere((_, String c) => c == canonical);
    await _apply(rows, 'Separated $canonical');
  }

  AppBar _appBar() {
    if (_selected.isEmpty) {
      return AppBar(title: Text('Merge ${widget.kind.plural}'));
    }
    return AppBar(
      leading: IconButton(
        tooltip: 'Cancel',
        onPressed: _clearSelection,
        icon: const Icon(Icons.close),
      ),
      title: Text('${_selected.length} selected'),
      actions: <Widget>[
        IconButton(
          tooltip: 'Merge',
          // One name is not a merge. Left visible but dead so the bar does not
          // reshuffle as the second one is ticked.
          onPressed: _selected.length < 2 ? null : _mergeSelected,
          icon: const Icon(Icons.merge_type),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final List<String> names = _counts.keys.toList()..sort();
    final List<String> merged = _aliases
        .mergedNames(widget.kind)
        // A merge whose transactions have all been deleted is still a rule
        // worth being able to drop, so it stays listed.
        .toList();
    final List<List<String>> suggestions =
        suggestGroups(names, widget.kind).where((List<String> group) {
      // Never suggest what is already one name.
      return group.length > 1;
    }).toList();

    return PopScope(
      canPop: _selected.isEmpty,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) _clearSelection();
      },
      child: Scaffold(
        appBar: _appBar(),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : names.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        'Nothing to merge yet — no transactions have been '
                        'recorded.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.only(bottom: 24),
                    children: <Widget>[
                      if (merged.isNotEmpty) ...<Widget>[
                        SettingsHeader('Merged'),
                        for (final String canonical in merged)
                          _MergedTile(
                            canonical: canonical,
                            labels: _labels[canonical] ?? <String>{},
                            onSeparate: () => _separate(canonical),
                          ),
                        const Divider(height: 32),
                      ],
                      if (suggestions.isNotEmpty) ...<Widget>[
                        SettingsHeader('Looks like duplicates'),
                        for (final List<String> group in suggestions)
                          _SuggestionCard(
                            group: group,
                            counts: _counts,
                            onMerge: () => _mergeSuggested(group),
                          ),
                        const Divider(height: 32),
                      ],
                      SettingsHeader('All ${widget.kind.plural}'),
                      for (final String name in names)
                        _NameTile(
                          name: name,
                          count: _counts[name] ?? 0,
                          selected: _selected.contains(name),
                          selecting: _selected.isNotEmpty,
                          onTap: () => _toggle(name),
                        ),
                    ],
                  ),
      ),
    );
  }
}

/// One name already standing for several, and the way to undo that.
class _MergedTile extends StatelessWidget {
  const _MergedTile({
    required this.canonical,
    required this.labels,
    required this.onSeparate,
  });

  final String canonical;
  final Set<String> labels;
  final VoidCallback onSeparate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final List<String> sorted = labels.toList()..sort();

    return ListTile(
      leading: const Icon(Icons.merge_type),
      title: Text(canonical),
      subtitle: Text(
        sorted.isEmpty
            ? 'No transactions under it right now'
            : 'Covers ${sorted.join(' · ')}',
        style: theme.textTheme.bodySmall,
      ),
      isThreeLine: sorted.length > 1,
      trailing: TextButton(
        onPressed: onSeparate,
        child: const Text('Separate'),
      ),
    );
  }
}

/// A group the app thinks is one thing under several labels. Shown already
/// ticked, but merged only when the button is pressed — the heuristics can be
/// wrong, and two cards really can end in the same four digits.
class _SuggestionCard extends StatelessWidget {
  const _SuggestionCard({
    required this.group,
    required this.counts,
    required this.onMerge,
  });

  final List<String> group;
  final Map<String, int> counts;
  final VoidCallback onMerge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      margin: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (final String name in group)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  children: <Widget>[
                    Icon(Icons.check_circle,
                        size: 18, color: theme.colorScheme.primary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(name,
                          maxLines: 1, overflow: TextOverflow.ellipsis),
                    ),
                    Text('${counts[name] ?? 0}',
                        style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.tonal(
                onPressed: onMerge,
                child: Text('Merge these ${group.length}'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One current name, tickable.
class _NameTile extends StatelessWidget {
  const _NameTile({
    required this.name,
    required this.count,
    required this.selected,
    required this.selecting,
    required this.onTap,
  });

  final String name;
  final int count;
  final bool selected;
  final bool selecting;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      selected: selected,
      selectedTileColor: theme.colorScheme.primaryContainer,
      leading: Icon(
        selected ? Icons.check_circle : Icons.circle_outlined,
        color: selected ? theme.colorScheme.primary : theme.colorScheme.outline,
      ),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text('$count transaction${count == 1 ? '' : 's'}'),
      onTap: onTap,
    );
  }
}

/// Names the result of a merge.
///
/// This sheet is the confirmation — typing a name and pressing Merge is a
/// deliberate enough act that a dialog after it would only be in the way, and
/// the snackbar behind it carries Undo.
class _MergeNameSheet extends StatefulWidget {
  const _MergeNameSheet({
    required this.kind,
    required this.members,
    required this.counts,
  });

  final NameKind kind;

  /// Most-used first — [_MergeNamesScreenState._mergeSelected] sorts them, and
  /// the first is offered as the name.
  final List<String> members;
  final Map<String, int> counts;

  @override
  State<_MergeNameSheet> createState() => _MergeNameSheetState();
}

class _MergeNameSheetState extends State<_MergeNameSheet> {
  late final TextEditingController _name =
      TextEditingController(text: widget.members.first);

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final String name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final int moved = widget.members
        .fold<int>(0, (int sum, String m) => sum + (widget.counts[m] ?? 0));

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
            Text(
              'Merge ${widget.members.length} ${widget.kind.plural}',
              style: theme.textTheme.titleLarge,
            ),
            const SizedBox(height: 4),
            Text(
              '$moved transaction${moved == 1 ? '' : 's'} will be filed under '
              'one name. Nothing is rewritten — this can be undone.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            for (final String member in widget.members)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('· $member',
                    style: theme.textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis),
              ),
            const Divider(height: 28),
            TextField(
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              onSubmitted: (_) => _submit(),
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                labelText: 'Call them',
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                const Spacer(),
                FilledButton(onPressed: _submit, child: const Text('Merge')),
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
// SETTINGS
// ---------------------------------------------------------------------------
