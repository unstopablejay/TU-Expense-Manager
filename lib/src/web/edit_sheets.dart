/// The browser's editing surfaces.
///
/// Deliberately not the phone's screens. Those write through `AppDatabase`, and
/// a browser has none — every edit here is a record of *intent* that the phone
/// applies later. Two consequences shape the UI:
///
///   * Only existing categories can be chosen. Creating one is not among the
///     four queued operations, and offering it would mean building a category
///     that no phone had agreed to make.
///   * Every action says that it will happen on the next sync, rather than
///     pretending it already has.
///
/// The arithmetic is *not* reimplemented: [unallocated], [isBalanced] and
/// [withRemainderInLast] come from `core/splits.dart`, the same functions the
/// phone's split editor uses and the same ones `saveSplits` checks against. A
/// second implementation here is how a browser would come to disagree with a
/// phone about whether a split adds up.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../core/constants.dart';
import '../core/models.dart';
import '../core/splits.dart';
import '../ui_shared/palette.dart';

/// What the user picked out of the actions dialog.
enum WebTxnAction { setCategory, setNote, split, delete }

/// The actions a row offers in a browser.
///
/// The phone's sheet also offers merging merchants and cards, which are standing
/// rules over the whole ledger rather than edits to one row — they are not one of
/// the queued operations and are left to the phone.
///
/// A centred dialog rather than the bottom sheet this used to be. A sheet rising
/// from the bottom edge of a 1080px browser window is a phone gesture answered by
/// a phone shape, and the row it belongs to is a thousand pixels away from it.
/// Every caller and every one of the four handlers is unchanged — this returns the
/// same [WebTxnAction], so only the shape of the question moved.
Future<WebTxnAction?> showWebTxnActions(
  BuildContext context,
  ExpenseTxn txn,
  NumberFormat money,
) =>
    showDialog<WebTxnAction>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        // Zero, because the content is a column of ListTiles and each brings its
        // own padding. The dialog's default would inset them all again and the
        // tap targets would stop reaching the edges.
        contentPadding: EdgeInsets.zero,
        title: Text(txn.merchant),
        content: ConstrainedBox(
          // Wide enough for a long category name beside an amount, narrow enough
          // that the four options still read as one short list rather than a
          // page. Dialogs get no width from their content otherwise.
          constraints: const BoxConstraints(maxWidth: 420),
          // Scrollable for the same reason the sheet was: five rows plus a
          // footnote is taller than a short browser window, where a plain Column
          // overflows rather than scrolling.
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                  child: Text(
                    '${money.format(txn.amount)} · ${txn.categoryName}',
                    style: Theme.of(dialogContext).textTheme.bodyMedium,
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.label_outline),
                  title: const Text('Change category'),
                  onTap: () =>
                      Navigator.pop(dialogContext, WebTxnAction.setCategory),
                ),
                ListTile(
                  leading: const Icon(Icons.notes_outlined),
                  title: Text(txn.note.isEmpty ? 'Add a note' : 'Edit the note'),
                  subtitle: txn.note.isEmpty ? null : Text(txn.note),
                  onTap: () => Navigator.pop(dialogContext, WebTxnAction.setNote),
                ),
                ListTile(
                  leading: const Icon(Icons.call_split),
                  title: Text(
                    txn.splits.isEmpty
                        ? 'Split across categories'
                        : 'Edit the split',
                  ),
                  onTap: () => Navigator.pop(dialogContext, WebTxnAction.split),
                ),
                ListTile(
                  leading: const Icon(Icons.delete_outline),
                  title: const Text('Delete'),
                  onTap: () => Navigator.pop(dialogContext, WebTxnAction.delete),
                ),
                const Divider(height: 1),
                const Padding(
                  padding: EdgeInsets.fromLTRB(24, 12, 24, 4),
                  child: Text(
                    'Changes are queued, and applied on that phone next sync — '
                    'which it does by itself while its app is open.',
                    style: TextStyle(fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
        ),
        actions: <Widget>[
          // A dialog needs a way out that is not the Escape key or a click on the
          // scrim — neither of which announces itself. The sheet had its drag
          // handle for this.
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );

/// Picks one of [categories], returning its id.
///
/// No "create a new category" option, unlike the phone's picker: creating one is
/// not a queued operation, and a category the phone has never heard of could not
/// be applied.
Future<int?> pickWebCategory(
  BuildContext context, {
  required List<ExpenseCategory> categories,
  required int selectedId,
}) =>
    showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(sheetContext).size.height * 0.7,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              const ListTile(title: Text('Choose a category')),
              const Divider(height: 1),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: <Widget>[
                    for (final ExpenseCategory category in categories)
                      ListTile(
                        leading: Icon(
                          categoryIcon(category.name),
                          color: categoryColor(
                            category.name,
                            Theme.of(sheetContext).brightness,
                          ),
                        ),
                        title: Text(category.name),
                        trailing: category.id == selectedId
                            ? const Icon(Icons.check)
                            : null,
                        onTap: () => Navigator.pop(sheetContext, category.id),
                      ),
                  ],
                ),
              ),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text(
                  'New categories are made on the phone.',
                  style: TextStyle(fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ),
    );

/// Edits a note, returning the new text — `''` to remove it — or null if
/// cancelled.
///
/// Empty and cancelled are genuinely different answers here: clearing the field
/// is how a note is deleted, so it cannot also mean "changed my mind".
Future<String?> editWebNote(BuildContext context, ExpenseTxn txn) =>
    showDialog<String>(
      context: context,
      builder: (BuildContext dialogContext) => _NoteDialog(txn: txn),
    );

/// The note dialog, stateful so that it owns its controller.
///
/// **Not a controller created beside `showDialog` and disposed after it awaits.**
/// showDialog completes when the route *starts* closing, and the dialog is still
/// being built through its exit animation — so disposing there throws "A
/// TextEditingController was used after being disposed". A State's dispose runs
/// when the route is actually gone, which is the only safe moment.
class _NoteDialog extends StatefulWidget {
  const _NoteDialog({required this.txn});

  final ExpenseTxn txn;

  @override
  State<_NoteDialog> createState() => _NoteDialogState();
}

class _NoteDialogState extends State<_NoteDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.txn.note,
  )..selection = TextSelection.collapsed(offset: widget.txn.note.length);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Note'),
        content: TextField(
          controller: _controller,
          autofocus: true,
          maxLength: kNoteMaxLength,
          maxLines: 3,
          minLines: 1,
          decoration: const InputDecoration(
            hintText: 'Why this charge — the bank never says',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (String value) => Navigator.pop(context, value),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          if (widget.txn.note.isNotEmpty)
            TextButton(
              // An explicit way out, rather than expecting someone to work out
              // that clearing the field and saving is how a note is removed.
              onPressed: () => Navigator.pop(context, ''),
              child: const Text('Remove'),
            ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _controller.text),
            child: const Text('Save'),
          ),
        ],
      );
}

/// Confirms a delete. False for a dismissed dialog, so a click outside cancels.
Future<bool> confirmWebDelete(BuildContext context, ExpenseTxn txn) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: const Text('Delete this transaction?'),
      content: Text(
        'It will be deleted on the phone the next time it syncs, and a '
        'later inbox scan will not bring it back.\n\n'
        '${txn.merchant} · ${txn.amount.toStringAsFixed(2)}',
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(dialogContext).colorScheme.error,
          ),
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('Delete'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// Edits the split lines of [txn], returning them or null if cancelled.
///
/// An empty list is a meaningful answer: it clears the split and hands the whole
/// amount back to the transaction's own category.
Future<List<TxnSplit>?> editWebSplits(
  BuildContext context, {
  required ExpenseTxn txn,
  required List<ExpenseCategory> categories,
  required NumberFormat money,
}) =>
    showDialog<List<TxnSplit>>(
      context: context,
      builder: (BuildContext dialogContext) => _WebSplitDialog(
        txn: txn,
        categories: categories,
        money: money,
      ),
    );

class _WebSplitDialog extends StatefulWidget {
  const _WebSplitDialog({
    required this.txn,
    required this.categories,
    required this.money,
  });

  final ExpenseTxn txn;
  final List<ExpenseCategory> categories;
  final NumberFormat money;

  @override
  State<_WebSplitDialog> createState() => _WebSplitDialogState();
}

/// One editable line. The controller lives with the data rather than in a list
/// beside it, so deleting a row cannot leave the two out of step — the same
/// reason the phone's `_SplitRow` is shaped this way.
class _Line {
  _Line({required this.categoryId, required this.categoryName, double? amount})
      : controller = TextEditingController(
          text: amount == null ? '' : amount.toStringAsFixed(2),
        );

  int categoryId;
  String categoryName;
  final TextEditingController controller;

  double get amount => double.tryParse(controller.text.trim()) ?? 0;

  void dispose() => controller.dispose();
}

class _WebSplitDialogState extends State<_WebSplitDialog> {
  late List<_Line> _lines;

  @override
  void initState() {
    super.initState();
    final List<TxnSplit> existing = widget.txn.splits;
    _lines = existing.isEmpty
        // Opening on an unsplit transaction offers two lines: its own category
        // with everything on it, and an empty one to move some of it to.
        ? <_Line>[
            _Line(
              categoryId: widget.txn.categoryId,
              categoryName: widget.txn.categoryName,
              amount: widget.txn.amount,
            ),
            _Line(
              categoryId: _otherCategory(widget.txn.categoryId),
              categoryName: _nameOf(_otherCategory(widget.txn.categoryId)),
            ),
          ]
        : <_Line>[
            for (final TxnSplit split in existing)
              _Line(
                categoryId: split.categoryId,
                categoryName: split.categoryName,
                amount: split.amount,
              ),
          ];
  }

  @override
  void dispose() {
    for (final _Line line in _lines) {
      line.dispose();
    }
    super.dispose();
  }

  int _otherCategory(int besides) {
    for (final ExpenseCategory c in widget.categories) {
      if (c.id != besides) return c.id;
    }
    return besides;
  }

  String _nameOf(int id) {
    for (final ExpenseCategory c in widget.categories) {
      if (c.id == id) return c.name;
    }
    return kUncategorized;
  }

  List<double> get _amounts => _lines.map((_Line l) => l.amount).toList();

  double get _left => unallocated(_amounts, widget.txn.amount);

  bool get _balanced => isBalanced(_amounts, widget.txn.amount);

  /// Puts whatever is left on the last line, so filling in the ones above is
  /// enough. The same helper the phone's editor uses.
  void _balance() {
    final List<double> settled =
        withRemainderInLast(_amounts, widget.txn.amount);
    setState(() {
      for (int i = 0; i < _lines.length; i++) {
        _lines[i].controller.text = settled[i].toStringAsFixed(2);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return AlertDialog(
      title: const Text('Split across categories'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              Text(
                '${widget.txn.merchant} · '
                '${widget.money.format(widget.txn.amount)}',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 12),
              for (int i = 0; i < _lines.length; i++) _row(i),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  TextButton.icon(
                    onPressed: () => setState(() => _lines.add(_Line(
                          categoryId: _otherCategory(_lines.last.categoryId),
                          categoryName:
                              _nameOf(_otherCategory(_lines.last.categoryId)),
                        ))),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add a line'),
                  ),
                  const Spacer(),
                  if (!_balanced)
                    TextButton(
                      onPressed: _balance,
                      child: const Text('Balance'),
                    ),
                ],
              ),
              const Divider(),
              Text(
                _balanced
                    ? 'Adds up.'
                    : _left > 0
                        ? '${widget.money.format(_left)} still to allocate.'
                        : '${widget.money.format(-_left)} over.',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: _balanced
                      ? theme.colorScheme.primary
                      : theme.colorScheme.error,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        if (widget.txn.splits.isNotEmpty)
          TextButton(
            // An empty list clears the split, handing the whole amount back to
            // the transaction's own category.
            onPressed: () => Navigator.pop(context, <TxnSplit>[]),
            child: const Text('Remove split'),
          ),
        FilledButton(
          // Disabled until it adds up, rather than accepted and refused later by
          // the phone: the arithmetic is the same either way, and finding out now
          // is better than finding out at the next sync.
          onPressed: _balanced ? _save : null,
          child: const Text('Save'),
        ),
      ],
    );
  }

  Widget _row(int index) {
    final _Line line = _lines[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: <Widget>[
          Expanded(
            flex: 3,
            child: DropdownButtonFormField<int>(
              initialValue: line.categoryId,
              isDense: true,
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              ),
              items: <DropdownMenuItem<int>>[
                for (final ExpenseCategory c in widget.categories)
                  DropdownMenuItem<int>(
                    value: c.id,
                    child: Text(c.name, overflow: TextOverflow.ellipsis),
                  ),
              ],
              onChanged: (int? id) {
                if (id == null) return;
                setState(() {
                  line.categoryId = id;
                  line.categoryName = _nameOf(id);
                });
              },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 2,
            child: TextField(
              controller: line.controller,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              inputFormatters: <TextInputFormatter>[
                FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              ],
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              ),
              // Rebuilds so the running total below is live rather than stale.
              onChanged: (_) => setState(() {}),
            ),
          ),
          IconButton(
            tooltip: 'Remove this line',
            // Two lines is the minimum a split can be; below that it is not a
            // split, and Remove split is the way to say so.
            onPressed: _lines.length <= 2
                ? null
                : () => setState(() => _lines.removeAt(index).dispose()),
            icon: const Icon(Icons.close, size: 18),
          ),
        ],
      ),
    );
  }

  void _save() => Navigator.pop(
        context,
        <TxnSplit>[
          for (final _Line line in _lines)
            TxnSplit(
              categoryId: line.categoryId,
              categoryName: line.categoryName,
              amount: line.amount,
            ),
        ],
      );
}
