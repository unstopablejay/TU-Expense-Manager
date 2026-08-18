/// The app, in a browser.
///
/// The same [DashboardTab] and [TransactionsTab] the phone renders, fed from a
/// snapshot instead of from SQLite, and deriving their view with the same
/// [deriveLedgerView] the phone's shell calls. That is what makes "the same
/// screens on the PC" a fact about the code rather than a resemblance.
///
/// What differs is only what a browser cannot own: it has no database and no SMS,
/// so an edit here is queued for the phone to apply rather than written.
library;

import 'dart:math';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/edits.dart';
import '../core/ledger.dart';
import '../core/ledger_view.dart';
import '../core/models.dart';
import '../core/snapshot_store.dart';
import '../core/splits.dart';
import '../ui_shared/dashboard_tab.dart';
import '../ui_shared/formats.dart';
import '../ui_shared/transactions_tab.dart';
import 'api_client.dart';
import 'edit_sheets.dart';
import 'session.dart';

/// How stale a snapshot may be before it is called out.
///
/// The single most useful thing this screen can do is stop someone reading a
/// week-old number as today's.
const Duration kStaleAfter = Duration(hours: 24);

class WebShell extends StatefulWidget {
  const WebShell({super.key, required this.api, required this.session});

  final ApiClient api;
  final WebSession session;

  @override
  State<WebShell> createState() => _WebShellState();
}

enum _Tab { dashboard, transactions }

class _WebShellState extends State<WebShell> {
  final NumberFormat _money = appMoneyFormat();
  final DateFormat _dateFormat = appDateFormat();
  final DateFormat _syncedFormat = DateFormat('d MMM yyyy, h:mm a');

  SnapshotStore? _store;
  List<RemoteDevice> _devices = <RemoteDevice>[];
  String? _device;

  bool _loading = true;
  String? _error;
  _Tab _tab = _Tab.dashboard;

  /// Ledger state, exactly as the phone's shell holds it.
  late LedgerFilters _filters;
  LedgerSort _sort = LedgerSort.newest;
  Set<YearMonth> _dashboardMonths = <YearMonth>{YearMonth.current()};
  YearMonth _currentMonth = YearMonth.current();

  /// Edits queued from here that the phone has not applied yet.
  int _pendingEdits = 0;

  /// Which snapshot the on-screen ledger came from, carried on every edit so the
  /// phone can tell how stale the ids in it are.
  String? _snapshotId;

  final Random _random = Random();

  @override
  void initState() {
    super.initState();
    _filters = LedgerFilters(months: <YearMonth>{_currentMonth});
    _load();
  }

  Future<void> _load({String? device}) async {
    setState(() {
      _loading = true;
      _error = null;
    });

    final ApiResult<List<RemoteDevice>> devices = await widget.api.devices();
    if (!mounted) return;
    if (devices.failed) {
      return _fail(devices.error!);
    }

    final List<RemoteDevice> synced =
        devices.value!.where((RemoteDevice d) => d.hasSynced).toList();
    final String? chosen = device ??
        _device ??
        (synced.isEmpty ? null : synced.first.id);

    if (chosen == null) {
      setState(() {
        _devices = devices.value!;
        _loading = false;
        _error = devices.value!.isEmpty
            ? 'No device has synced to this account yet. Open the app on your '
                'phone, go to Settings, and tap Sync now.'
            : 'This device has not synced a ledger yet. Tap Sync now in the '
                "app's settings.";
      });
      return;
    }

    final ApiResult<SnapshotStore> snapshot =
        await widget.api.snapshot(device: chosen);
    if (!mounted) return;
    if (snapshot.failed) return _fail(snapshot.error!);

    setState(() {
      _devices = devices.value!;
      _device = chosen;
      _store = snapshot.value;
      _snapshotId = snapshot.value!.meta['snapshot_id'];
      _pendingEdits = devices.value!
          .firstWhere(
            (RemoteDevice d) => d.id == chosen,
            orElse: () => const RemoteDevice(
                id: '', label: '', lastSeen: null),
          )
          .pendingEdits;
      // Recomputed on every load rather than read in build, for the same reason
      // the phone does it: a DateTime.now() per build would roll the answer over
      // mid-frame at midnight and be unpinnable in a test.
      _currentMonth = YearMonth.current();
      _loading = false;
    });
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _loading = false;
      _error = message;
      if (message.contains('expired')) _store = null;
    });
    if (message.contains('expired')) widget.session.signOut();
  }

  /// A row was clicked: offer what can be done to it, then queue it.
  Future<void> _editTransaction(ExpenseTxn txn) async {
    final SnapshotStore? store = _store;
    if (store == null) return;

    final WebTxnAction? action =
        await showWebTxnActions(context, txn, _money);
    if (action == null || !mounted) return;

    switch (action) {
      case WebTxnAction.setCategory:
        final int? categoryId = await pickWebCategory(
          context,
          categories: store.categories,
          selectedId: txn.categoryId,
        );
        if (categoryId == null || categoryId == txn.categoryId) return;
        await _queue(EditOp.setCategory, txn, categoryId: categoryId);

      case WebTxnAction.setNote:
        final String? note = await editWebNote(context, txn);
        // Null is cancelled; empty is a note being removed. Different answers.
        if (note == null || note == txn.note) return;
        await _queue(EditOp.setNote, txn, note: note);

      case WebTxnAction.split:
        final List<TxnSplit>? lines = await editWebSplits(
          context,
          txn: txn,
          categories: store.categories,
          money: _money,
        );
        if (lines == null) return;
        await _queue(EditOp.saveSplits, txn, lines: lines);

      case WebTxnAction.delete:
        await _deleteTransaction(txn);
    }
  }

  /// The swipe and the sheet both land here.
  Future<void> _deleteTransaction(ExpenseTxn txn) async {
    if (!await confirmWebDelete(context, txn)) return;
    await _queue(EditOp.deleteTxn, txn);
  }

  /// Records the intent on the server, and says what will happen to it.
  ///
  /// The natural key comes from [ExpenseTxn.naturalKey], which reads the merchant
  /// as *stored* rather than as merged — a key written from a merged spelling
  /// would address a row that does not exist, and the phone would skip it for no
  /// visible reason.
  Future<void> _queue(
    EditOp op,
    ExpenseTxn txn, {
    int? categoryId,
    String? note,
    List<TxnSplit> lines = const <TxnSplit>[],
  }) async {
    final String? device = _device;
    if (device == null) return;

    final LedgerEdit edit = composeEdit(
      editId: newEditId(DateTime.now().toUtc(), _random),
      op: op,
      txn: txn,
      now: DateTime.now().toUtc(),
      snapshotId: _snapshotId,
      categoryId: categoryId,
      note: note,
      lines: lines,
    );

    final ApiResult<int> result =
        await widget.api.queueEdit(edit, device: device);
    if (!mounted) return;
    if (result.failed) {
      _toast(result.error!);
      return;
    }
    setState(() => _pendingEdits = result.value!);
    _toast('Queued. It will be applied the next time that phone syncs.');
  }

  void _toast(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final SnapshotStore? store = _store;
    final LedgerView? view = store == null
        ? null
        : deriveLedgerView(
            transactions: store.transactions,
            allCategories: store.categories,
            requested: _filters,
            currentMonth: _currentMonth,
            sort: _sort,
          );

    return Scaffold(
      appBar: AppBar(
        title: const Text('TU Expense Tracker'),
        bottom: _pendingEdits == 0 ? null : _pendingBanner(),
        actions: <Widget>[
          if (_devices.length > 1) _devicePicker(),
          _syncedLabel(),
          IconButton(
            // A mouse cannot pull to refresh, so the shared tabs'
            // RefreshIndicator is unreachable here and this is the way in.
            tooltip: 'Reload from the server',
            onPressed: _loading ? null : () => _load(),
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Sign out',
            onPressed: () async {
              await widget.api.logout();
              widget.session.signOut();
            },
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: _body(store, view),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab.index,
        onDestinationSelected: (int i) => setState(() => _tab = _Tab.values[i]),
        destinations: const <Widget>[
          NavigationDestination(
            icon: Icon(Icons.pie_chart_outline),
            selectedIcon: Icon(Icons.pie_chart),
            label: 'Dashboard',
          ),
          NavigationDestination(
            icon: Icon(Icons.receipt_long_outlined),
            selectedIcon: Icon(Icons.receipt_long),
            label: 'Transactions',
          ),
        ],
      ),
    );
  }

  Widget _body(SnapshotStore? store, LedgerView? view) {
    if (_error != null && store == null) {
      return _Message(
        icon: Icons.cloud_off_outlined,
        message: _error!,
        onRetry: () => _load(),
      );
    }
    if (store == null || view == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return IndexedStack(
      index: _tab.index,
      children: <Widget>[
        DashboardTab(
          transactions: store.transactions,
          months: _dashboardMonths,
          monthChoices: monthOptions(store.transactions, current: _currentMonth),
          currentMonth: _currentMonth,
          money: _money,
          loading: _loading,
          onMonthsChanged: (Set<YearMonth> months) =>
              setState(() => _dashboardMonths = months),
          onRefresh: () => _load(),
          emptyDetail: 'Transactions are added on your phone, from bank SMS '
              'alerts. This view reads what it last synced.',
        ),
        TransactionsTab(
          entries: view.visible,
          filters: view.filters,
          sort: _sort,
          monthChoices: view.months,
          currentMonth: _currentMonth,
          categoryChoices: view.categories,
          merchantChoices: view.merchants,
          paymentTypeChoices: view.paymentTypes,
          money: _money,
          dateFormat: _dateFormat,
          loading: _loading,
          ledgerIsEmpty: store.transactions.isEmpty,
          selected: const <int>{},
          onFiltersChanged: (LedgerFilters f) => setState(() => _filters = f),
          onSortChanged: (LedgerSort s) => setState(() => _sort = s),
          onRefresh: () => _load(),
          onTap: _editTransaction,
          onDelete: _deleteTransaction,
          // Still null: multi-select exists to drive a bulk delete, and a bulk
          // delete would be one queued edit per row with no way to undo the set
          // as a set. One row at a time here.
          onToggleSelected: null,
          emptyDetail: 'Transactions are added on your phone, from bank SMS '
              'alerts. This view reads what it last synced.',
        ),
      ],
    );
  }

  PreferredSizeWidget _pendingBanner() => PreferredSize(
        preferredSize: const Size.fromHeight(28),
        child: Container(
          width: double.infinity,
          color: Theme.of(context).colorScheme.tertiaryContainer,
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
          child: Text(
            _pendingEdits == 1
                ? '1 edit waiting — it will be applied the next time that phone '
                    'syncs.'
                : '$_pendingEdits edits waiting — they will be applied the next '
                    'time that phone syncs.',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onTertiaryContainer,
              fontSize: 12,
            ),
          ),
        ),
      );

  Widget _devicePicker() => PopupMenuButton<String>(
        tooltip: 'Which device to show',
        icon: const Icon(Icons.devices_outlined),
        onSelected: (String id) => _load(device: id),
        itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
          for (final RemoteDevice device in _devices)
            PopupMenuItem<String>(
              value: device.id,
              enabled: device.hasSynced,
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  device.id == _device
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                ),
                title: Text(device.label),
                subtitle: Text(
                  device.hasSynced
                      ? '${device.transactions ?? 0} transactions · '
                          '${_ago(device.lastSeen)}'
                      : 'never synced',
                ),
              ),
            ),
        ],
      );

  /// When the shown ledger was taken, greyed once it is stale.
  Widget _syncedLabel() {
    final DateTime? at = _store?.exportedAt;
    if (at == null) return const SizedBox.shrink();
    final bool stale = DateTime.now().difference(at) > kStaleAfter;
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return Tooltip(
      message: 'This ledger was taken on the phone at '
          '${_syncedFormat.format(at.toLocal())}',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          children: <Widget>[
            Icon(
              stale ? Icons.warning_amber_outlined : Icons.cloud_done_outlined,
              size: 16,
              color: stale ? scheme.error : scheme.onSurfaceVariant,
            ),
            const SizedBox(width: 4),
            Text(
              _ago(at),
              style: TextStyle(
                fontSize: 12,
                color: stale ? scheme.error : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _ago(DateTime? at) {
    if (at == null) return 'never';
    final Duration since = DateTime.now().difference(at);
    if (since.inMinutes < 1) return 'just now';
    if (since.inMinutes < 60) return '${since.inMinutes} min ago';
    if (since.inHours < 24) return '${since.inHours} h ago';
    return '${since.inDays} d ago';
  }
}

/// A centred message with a way out of it.
class _Message extends StatelessWidget {
  const _Message({
    required this.icon,
    required this.message,
    this.onRetry,
  });

  final IconData icon;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(icon, size: 48, color: Theme.of(context).colorScheme.outline),
                const SizedBox(height: 16),
                Text(message, textAlign: TextAlign.center),
                if (onRetry != null) ...<Widget>[
                  const SizedBox(height: 16),
                  FilledButton.tonal(
                    onPressed: onRetry,
                    child: const Text('Try again'),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
}
