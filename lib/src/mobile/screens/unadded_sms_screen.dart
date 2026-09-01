/// The inbox of bank SMS the parser couldn't turn into a transaction on its
/// own — reviewed one at a time: add it, or dismiss it.
///
/// Read messages stay listed rather than disappearing — only dismissing (the
/// close icon) or adding one removes it. "Mark all as read" only ever clears
/// the unread badge upstream; it is not a bulk dismiss.
library;

import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../database.dart';
import 'add_transaction_screen.dart';

class UnaddedSmsScreen extends StatefulWidget {
  const UnaddedSmsScreen({
    super.key,
    required this.categories,
    required this.merchants,
    required this.paymentTypes,
    required this.onChanged,
  });

  final List<ExpenseCategory> categories;
  final List<String> merchants;
  final List<String> paymentTypes;

  /// Lets the shell underneath refresh its own copy (and the inbox badge)
  /// once something here has changed — the same role `DeletedScreen.onChanged`
  /// plays.
  final Future<void> Function() onChanged;

  @override
  State<UnaddedSmsScreen> createState() => _UnaddedSmsScreenState();
}

class _UnaddedSmsScreenState extends State<UnaddedSmsScreen> {
  final AppDatabase _db = AppDatabase.instance;

  List<UnaddedSms> _messages = <UnaddedSms>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final List<UnaddedSms> rows = await _db.unaddedSms();
    if (!mounted) return;
    setState(() {
      _messages = rows;
      _loading = false;
    });
  }

  Future<void> _dismiss(UnaddedSms msg) async {
    await _db.deleteUnaddedSms(msg.id);
    await Future.wait(<Future<void>>[_load(), widget.onChanged()]);
  }

  Future<void> _markAllRead() async {
    await _db.markAllUnaddedSmsRead();
    await Future.wait(<Future<void>>[_load(), widget.onChanged()]);
  }

  Future<void> _open(UnaddedSms msg) async {
    // AddTransactionScreen pops `true` on a successful save (see
    // home_shell.dart's _openAddTransaction, the normal "+" flow) — never an
    // ExpenseCategory. Awaiting it as anything else throws a type error the
    // moment the pop happens, after the transaction has already been
    // inserted: the save "fails" with an error that the user sees, but the
    // transaction is there anyway.
    final bool? added = await Navigator.push<bool>(
      context,
      MaterialPageRoute<bool>(
        builder: (_) => AddTransactionScreen(
          categories: widget.categories,
          merchants: widget.merchants,
          paymentTypes: widget.paymentTypes,
          initialSmsBody: msg.body,
        ),
      ),
    );
    if (added == true) await _dismiss(msg);
  }

  @override
  Widget build(BuildContext context) {
    final bool hasUnread = _messages.any((UnaddedSms m) => !m.isRead);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Unadded SMS'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Mark all as read',
            icon: const Icon(Icons.done_all),
            onPressed: hasUnread ? _markAllRead : null,
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _messages.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'No pending unadded SMS.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: _messages.length,
                  itemBuilder: (context, i) {
                    final UnaddedSms msg = _messages[i];
                    return ListTile(
                      title: Text(
                        msg.body,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: msg.isRead
                            ? null
                            : const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      subtitle: Text(msg.receivedAt.toString()),
                      trailing: IconButton(
                        icon: const Icon(Icons.close),
                        onPressed: () => _dismiss(msg),
                      ),
                      onTap: () => _open(msg),
                    );
                  },
                ),
    );
  }
}
