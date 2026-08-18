/// Every tombstone, and the way back.
///
/// Restoring lifts the tombstone *and* re-inserts the row, which is why there is
/// no separate "make importable again" action — those are the same thing.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../core/models.dart';
import '../../ui_shared/palette.dart';
import '../database.dart';

class DeletedScreen extends StatefulWidget {
  const DeletedScreen({
    super.key,
    required this.money,
    required this.dateFormat,
    required this.onChanged,
  });

  final NumberFormat money;
  final DateFormat dateFormat;

  /// Lets the shell underneath reload, so a restored transaction is already in
  /// the ledger by the time this screen is popped.
  final Future<void> Function() onChanged;

  @override
  State<DeletedScreen> createState() => _DeletedScreenState();
}

class _DeletedScreenState extends State<DeletedScreen> {
  final AppDatabase _db = AppDatabase.instance;

  List<DeletedTxn> _deleted = <DeletedTxn>[];
  bool _loading = true;

  /// Marked rows, held by natural key — a tombstone has no id of its own.
  final Set<String> _selected = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = await _db.deletedTransactions();
    if (!mounted) return;
    setState(() {
      _deleted = rows;
      _loading = false;
      // Anything restored elsewhere is no longer here to stay marked.
      _selected.retainAll(rows.map((DeletedTxn d) => d.key));
    });
  }

  void _toggle(DeletedTxn row) {
    setState(() {
      if (!_selected.remove(row.key)) _selected.add(row.key);
    });
  }

  void _clearSelection() => setState(_selected.clear);

  Future<void> _restore(List<DeletedTxn> rows) async {
    if (rows.isEmpty) return;
    await _db.restoreTransactions(rows);
    setState(_selected.clear);
    await Future.wait(<Future<void>>[_load(), widget.onChanged()]);
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(rows.length == 1
            ? 'Restored ${rows.single.merchant}'
            : 'Restored ${rows.length} transactions'),
      ));
  }

  AppBar _appBar() {
    if (_selected.isEmpty) {
      return AppBar(title: const Text('Deleted transactions'));
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
          tooltip: 'Select all',
          onPressed: () => setState(() => _selected
            ..clear()
            ..addAll(_deleted.map((DeletedTxn d) => d.key))),
          icon: const Icon(Icons.select_all),
        ),
        IconButton(
          tooltip: 'Restore',
          onPressed: () => _restore(_deleted
              .where((DeletedTxn d) => _selected.contains(d.key))
              .toList()),
          icon: const Icon(Icons.restore),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selecting = _selected.isNotEmpty;

    return PopScope(
      // Back should leave selection mode before it leaves the screen.
      canPop: !selecting,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) _clearSelection();
      },
      child: Scaffold(
        appBar: _appBar(),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _deleted.isEmpty
                ? _DeletedEmptyState()
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                    itemCount: _deleted.length,
                    itemBuilder: (context, index) {
                      final row = _deleted[index];
                      final selected = _selected.contains(row.key);

                      // Laid out by hand rather than with `ListTile`, whose
                      // trailing slot is too short for an amount stacked over a
                      // button.
                      return Card(
                        key: ValueKey<String>(row.key),
                        margin: const EdgeInsets.only(bottom: 8),
                        clipBehavior: Clip.antiAlias,
                        color:
                            selected ? theme.colorScheme.primaryContainer : null,
                        child: InkWell(
                          // Long-press starts marking; once anything is marked,
                          // a plain tap toggles.
                          onTap: selecting ? () => _toggle(row) : null,
                          onLongPress: () => _toggle(row),
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                if (selecting) ...<Widget>[
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Icon(
                                      selected
                                          ? Icons.check_circle
                                          : Icons.circle_outlined,
                                      color: selected
                                          ? theme.colorScheme.primary
                                          : theme.colorScheme.outline,
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                ],
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: <Widget>[
                                      Text(
                                        row.merchant,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w600),
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '${row.paymentType} · '
                                        '${widget.dateFormat.format(row.date)}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodySmall,
                                      ),
                                      Text(
                                        row.deletedAt == null
                                            // A tombstone from before v4.
                                            ? '${row.categoryName} · deleted'
                                            : '${row.categoryName} · deleted '
                                                '${widget.dateFormat.format(row.deletedAt!)}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.bodySmall,
                                      ),
                                      // Two charges of the same amount at the
                                      // same shop are told apart by the note or
                                      // not at all — and this is the screen
                                      // where one of them is chosen to restore.
                                      if (row.note.isNotEmpty)
                                        Text(
                                          row.note,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: theme.textTheme.bodySmall
                                              ?.copyWith(
                                            fontStyle: FontStyle.italic,
                                            color: theme
                                                .colorScheme.onSurfaceVariant,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Column(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: <Widget>[
                                    Padding(
                                      padding: EdgeInsets.only(
                                          top: selecting ? 2 : 0),
                                      child: Text(
                                        row.isCredit
                                            ? '+${widget.money.format(row.amount)}'
                                            : widget.money.format(row.amount),
                                        style: theme.textTheme.titleSmall
                                            ?.copyWith(
                                          fontWeight: FontWeight.bold,
                                          color: row.isCredit
                                              ? creditColor(theme)
                                              : null,
                                        ),
                                      ),
                                    ),
                                    // The per-row button would be a second,
                                    // conflicting way to act while marking.
                                    if (!selecting)
                                      TextButton.icon(
                                        onPressed: () =>
                                            _restore(<DeletedTxn>[row]),
                                        icon:
                                            const Icon(Icons.restore, size: 18),
                                        label: const Text('Restore'),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
      ),
    );
  }
}

class _DeletedEmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(32),
      children: <Widget>[
        const SizedBox(height: 100),
        Icon(Icons.delete_outline, size: 64, color: theme.colorScheme.outline),
        const SizedBox(height: 16),
        Text(
          'Nothing deleted',
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'Deleting a transaction also keeps it from being imported again by a '
          'later inbox scan. Anything you delete lands here, and restoring it '
          'undoes both.',
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}
