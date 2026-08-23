/// The app, in a browser.
///
/// The same [DashboardTab] the phone renders, fed from a snapshot instead of from
/// SQLite, and deriving its view with the same [deriveLedgerView] the phone's
/// shell calls. One implementation of the charts, the filters, the sort orders and
/// the category colours.
///
/// The ledger itself is the exception, and deliberately so. [WebTransactionsView]
/// draws it as a table on a window wide enough for one, because a column of cards
/// is right on a phone and wasteful on a desktop — and falls back to the phone's
/// own [TransactionsTab] below [kWideLayoutBreakpoint]. What is shared there is
/// the *logic*: it is handed the rows [deriveLedgerView] already filtered and
/// ordered, and it totals them with the same functions.
///
/// What else differs is only what a browser cannot own: it has no database and no
/// SMS, so an edit here is queued for the phone to apply rather than written.
library;

import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/edits.dart';
import '../core/ledger.dart';
import '../core/ledger_view.dart';
import '../core/link_state.dart';
import '../core/models.dart';
import '../core/snapshot_store.dart';
import '../core/splits.dart';
import '../ui_shared/connection_dot.dart';
import '../ui_shared/dashboard_tab.dart';
import '../ui_shared/formats.dart';
import '../ui_shared/theme_controller.dart';
import '../ui_shared/theme_models.dart';
import 'api_client.dart';
import 'edit_sheets.dart';
import 'session.dart';
import 'transactions_table.dart';

/// How stale a snapshot may be before it is called out.
///
/// The single most useful thing this screen can do is stop someone reading a
/// week-old number as today's.
const Duration kStaleAfter = Duration(hours: 24);

/// How often to re-read the device list, for the connection light and the count
/// of edits still waiting.
///
/// A few hundred bytes on a LAN. Deliberately only the device list: re-fetching
/// the ledger on a timer would pull a megabyte behind the user's back and move
/// the page under them while they were reading it.
const Duration kLinkPollInterval = Duration(seconds: 30);

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

  /// Whether the phone whose ledger is on screen is in touch with the server.
  ///
  /// Two ways to be red, and the tooltip says which: the server did not answer
  /// this browser, or it did and that phone has not reported for longer than its
  /// own sync interval explains.
  LinkStatus _link = const LinkStatus(LinkState.unknown, 'Not checked yet.');

  Timer? _poll;

  final Random _random = Random();

  @override
  void initState() {
    super.initState();
    _filters = LedgerFilters(months: <YearMonth>{_currentMonth});
    _load();
    // Only the device list, and only every half minute: a few hundred bytes, and
    // it is what keeps the light and the pending-edits banner from being as old
    // as the tab has been open. The ledger is deliberately not re-fetched —
    // pulling a megabyte behind the user's back is a different thing entirely.
    _poll = Timer.periodic(kLinkPollInterval, (Timer _) => unawaited(_refreshLink()));
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  /// Re-reads the device list and updates the light and the pending count.
  Future<void> _refreshLink() async {
    final ApiResult<List<RemoteDevice>> devices = await widget.api.devices();
    if (!mounted) return;

    if (devices.failed) {
      setState(() => _link = LinkStatus(LinkState.disconnected, devices.error!));
      return;
    }

    setState(() {
      _devices = devices.value!;
      final RemoteDevice? device = _shown(devices.value!);
      if (device != null) _pendingEdits = device.pendingEdits;
      _link = _statusFor(device);
    });
  }

  /// The device whose ledger is on screen, out of [devices].
  RemoteDevice? _shown(List<RemoteDevice> devices) {
    final String? chosen = _device;
    if (chosen == null) return null;
    for (final RemoteDevice device in devices) {
      if (device.id == chosen) return device;
    }
    return null;
  }

  /// What the light should say about [device].
  LinkStatus _statusFor(RemoteDevice? device) {
    if (device == null) {
      return const LinkStatus(
        LinkState.unknown,
        'No phone has synced to this account yet.',
      );
    }
    final LinkState state = deviceLinkState(
      lastSeen: device.lastSeen,
      syncMinutes: device.syncMinutes,
      now: DateTime.now(),
    );
    return LinkStatus(
      state,
      switch (state) {
        LinkState.connected =>
          '${device.label} is in touch — last synced ${_ago(device.lastSeen)}.',
        LinkState.disconnected =>
          '${device.label} has not synced since ${_ago(device.lastSeen)}. '
              'Open the app on that phone.',
        LinkState.unknown => '${device.label} has never synced.',
      },
    );
  }

  Future<void> _load({String? device}) async {
    setState(() {
      _loading = true;
      _error = null;
    });

    final ApiResult<List<RemoteDevice>> devices = await widget.api.devices();
    if (!mounted) return;
    if (devices.failed) {
      // This browser could not reach the server at all, which is the one failure
      // on this screen that the light is genuinely about. A snapshot that fails
      // to decode further down is a different problem and leaves it alone.
      setState(() => _link = LinkStatus(LinkState.disconnected, devices.error!));
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
      final RemoteDevice? shown = _shown(devices.value!);
      _pendingEdits = shown?.pendingEdits ?? 0;
      _link = _statusFor(shown);
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
    _toast('Queued. That phone applies it on its next sync, which it does by '
        'itself while the app is open there.');
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
          _themeMenu(context),
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
          // Last, so it is in the corner — the same place the phone puts it, and
          // the same widget, saying the same thing about the same link.
          ConnectionDot(
            state: _link.state,
            tooltip: _link.detail,
            onTap: _refreshLink,
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
        // The browser's own transactions screen: a table on a real window, and
        // the phone's card list below [kWideLayoutBreakpoint]. It decides which
        // internally, so this call site says nothing about width.
        //
        // Multi-select is not among its props at all. It exists to drive a bulk
        // delete, and a bulk delete would be one queued edit per row with no way
        // to undo the set as a set — so the browser has always passed null, and
        // a prop with one possible value is not a prop.
        WebTransactionsView(
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
          onFiltersChanged: (LedgerFilters f) => setState(() => _filters = f),
          onSortChanged: (LedgerSort s) => setState(() => _sort = s),
          onRefresh: () => _load(),
          onTap: _editTransaction,
          onDelete: _deleteTransaction,
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
                ? '1 edit waiting — that phone applies it on its next sync.'
                : '$_pendingEdits edits waiting — that phone applies them on '
                    'its next sync.',
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

  Widget _themeMenu(BuildContext context) {
    final ThemeController controller = ThemeController.instance;
    return PopupMenuButton<void>(
      tooltip: 'Appearance & Theme',
      icon: const Icon(Icons.palette_outlined),
      itemBuilder: (BuildContext context) => <PopupMenuEntry<void>>[
        const PopupMenuItem<void>(
          enabled: false,
          child: Text(
            'THEME MODE',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
          ),
        ),
        for (final AppThemeMode mode in AppThemeMode.values)
          PopupMenuItem<void>(
            onTap: () => controller.setThemeMode(mode),
            child: Row(
              children: <Widget>[
                Icon(
                  mode.icon,
                  size: 18,
                  color: controller.appThemeMode == mode
                      ? Theme.of(context).colorScheme.primary
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(mode.label)),
                if (controller.appThemeMode == mode)
                  Icon(
                    Icons.check,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  ),
              ],
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem<void>(
          enabled: false,
          child: Text(
            'ACCENT COLOR',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 11),
          ),
        ),
        for (final AppAccentColor accent in AppAccentColor.values)
          PopupMenuItem<void>(
            onTap: () => controller.setAccentColor(accent),
            child: Row(
              children: <Widget>[
                Container(
                  width: 16,
                  height: 16,
                  decoration: BoxDecoration(
                    color: accent.seedColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(child: Text(accent.label)),
                if (controller.accentColor == accent)
                  Icon(
                    Icons.check,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  ),
              ],
            ),
          ),
      ],
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
