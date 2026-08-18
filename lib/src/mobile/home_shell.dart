/// The app itself: the root widget and the shell the tabs live in.
///
/// `_HomeShellState` is the app's de facto store. It owns the loaded ledger and
/// hands it down to two stateless tabs, reloading the whole thing after every
/// mutation rather than patching rows in place — which is what keeps a merge
/// rule or a backfilled default from leaving a stale row on screen.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../core/aliases.dart';
import '../core/constants.dart';
import '../core/ledger.dart';
import '../core/ledger_view.dart';
import '../core/models.dart';
import '../core/parser.dart';
import '../ui_shared/dashboard_tab.dart';
import '../ui_shared/formats.dart';
import '../ui_shared/theme.dart';
import '../ui_shared/transactions_tab.dart';
import 'database.dart';
import 'screens/category_picker_sheet.dart';
import 'screens/deleted_screen.dart';
import 'screens/merge_names_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/split_screen.dart';
import 'screens/transaction_actions_sheet.dart';
import 'screens/update_dialog.dart';
import 'sms_source.dart';
import 'sync_client.dart';
import 'sync_prefs.dart';
import 'update_service.dart';


class TuExpenseTrackerApp extends StatelessWidget {
  const TuExpenseTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TU Expense Tracker',
      debugShowCheckedModeBanner: false,
      theme: appTheme(Brightness.light),
      darkTheme: appTheme(Brightness.dark),
      home: const HomeShell(),
    );
  }
}

/// What one pass over the inbox did. [skipped] counts alerts that parsed but
/// were already recorded or had been deleted.
class _ScanResult {
  const _ScanResult({
    required this.added,
    required this.skipped,
    required this.addedInView,
  });

  final int added;
  final int skipped;

  /// How many of [added] fall in the months the ledger is currently showing.
  /// Less than [added] means rows landed somewhere the user cannot see.
  final int addedInView;
}

/// The three destinations, **in bar order — which is also `IndexedStack` order**.
///
/// An enum rather than bare indices because four separate places used to
/// hardcode `0` and `1`, and inserting a tab between them is exactly the change
/// that makes such a number mean something else without saying so. Same move
/// [LedgerSort] and [NameKind] already make.
enum HomeTab {
  dashboard('Dashboard', Icons.pie_chart_outline, Icons.pie_chart),
  transactions('Transactions', Icons.receipt_long_outlined, Icons.receipt_long),
  settings('Settings', Icons.settings_outlined, Icons.settings);

  const HomeTab(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

/// One ledger, three screens: the charts over it, the list itself — filter,
/// sort, categorise, split and delete — and Settings. This shell owns the data
/// and the view over it; the tabs only render what they are handed.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final AppDatabase _db = AppDatabase.instance;
  final SmsSource _sms = SmsSource();

  final NumberFormat _money = appMoneyFormat();
  final DateFormat _dateFormat = appDateFormat();

  List<ExpenseTxn> _transactions = <ExpenseTxn>[];
  List<ExpenseCategory> _categories = <ExpenseCategory>[];
  bool _loading = true;
  bool _scanning = false;
  HomeTab _tab = HomeTab.dashboard;

  /// The month the app considers "now". Refreshed on every load rather than
  /// read in `build`: it decides where Clear goes back to and which month is
  /// always on offer, and a `DateTime.now()` per build would roll those answers
  /// over mid-frame at midnight and be unpinnable in a test.
  YearMonth _currentMonth = YearMonth.current();

  /// How the ledger is narrowed and ordered. Held here rather than in the tab
  /// because the selection app bar — built here — has to know which rows are on
  /// screen before it can offer to select or delete "all" of them.
  ///
  /// Assigned in [initState] so it and [_currentMonth] cannot disagree — a
  /// field initialiser cannot refer to another field.
  late LedgerFilters _filters;
  LedgerSort _sort = LedgerSort.newest;

  /// The Dashboard's own period, deliberately not the ledger's.
  ///
  /// The charts exist to compare several months; the list opens on one and is
  /// scrubbed around in. Sharing one field would mean building a three-month
  /// comparison silently dumped three months of rows into the list, and a
  /// scrubbing session silently repointed the charts — and because the two tabs
  /// live in an `IndexedStack` and stay alive, neither would be noticed until
  /// the user switched back.
  late Set<YearMonth> _dashboardMonths;

  /// Ids marked for deletion. Lives here rather than in the tab because the app
  /// bar it takes over is built here.
  final Set<int> _selected = <int>{};

  @override
  void initState() {
    super.initState();
    // The `IndexedStack` in `build` is written out by hand while the
    // `NavigationBar` is generated from the enum, so a destination added
    // without a child would silently show the wrong screen. Fail loudly here
    // instead.
    assert(HomeTab.values.length == 3, 'HomeTab and IndexedStack are out of step');
    // One reading of the clock for all three, so they cannot disagree.
    _currentMonth = YearMonth.current();
    _filters = LedgerFilters.defaults(_currentMonth);
    _dashboardMonths = <YearMonth>{_currentMonth};
    _load();
    _startSms();
    _checkForUpdates();
  }

  Future<void> _load() async {
    final results = await Future.wait(<Future<Object>>[
      _db.transactions(),
      _db.categories(),
    ]);
    if (!mounted) return;
    setState(() {
      _transactions = results[0] as List<ExpenseTxn>;
      _categories = results[1] as List<ExpenseCategory>;
      // An app left open across midnight on the last of the month rolls over
      // here, on the next refresh, scan or return from Settings — deterministic
      // and never mid-build.
      _currentMonth = YearMonth.current();
      _loading = false;
    });
  }

  // -------------------------------------------------------------------------
  // SMS INTAKE
  // -------------------------------------------------------------------------

  /// Asks for the permission, registers the foreground listener, then catches
  /// up on the inbox — the whole of it on the very first run, and only what has
  /// arrived since on every run after that.
  Future<void> _startSms() async {
    if (!_sms.isSupported) return;
    final granted = await _sms.requestPermission();
    if (!granted) return;

    _sms.listen((InboxSms sms) async {
      final parsed = SmsParser.parse(sms.body, receivedAt: sms.receivedAt);
      if (parsed == null) return; // not a transaction alert
      await _db.insertParsed(parsed);
      await _load();
    });

    final since = await _db.lastScannedSmsDate();
    final result = await _scan(since: since);
    // Only the first import is worth announcing; later catch-ups are routine.
    if (result != null && since == null && result.added > 0) {
      _toast('Imported ${result.added} transaction(s) from your inbox.');
    }
  }

  /// One pass over the inbox. The caller owns the permission check. Returns
  /// null when a scan is already in flight.
  Future<_ScanResult?> _scan({DateTime? since}) async {
    if (_scanning) return null;
    setState(() => _scanning = true);
    try {
      final messages = await _sms.readInbox(since: since);

      DateTime? newest;
      var added = 0;
      var skipped = 0;
      // Counted so the toast can say how many of them the list will actually
      // show. A full rescan mostly imports older months, and "Imported 214"
      // over an unchanged list is alarming rather than informative.
      var addedInView = 0;
      for (final sms in messages) {
        final at = sms.receivedAt;
        if (at != null && (newest == null || at.isAfter(newest))) newest = at;

        final parsed = SmsParser.parse(sms.body, receivedAt: at);
        if (parsed == null) continue; // OTP, promo, statement alert
        final id = await _db.insertParsed(parsed);
        if (id == 0) {
          skipped++;
          continue;
        }
        added++;
        if (_filters.months.isEmpty ||
            _filters.months.contains(YearMonth.fromDate(parsed.date))) {
          addedInView++;
        }
      }

      // Advance from the newest message actually seen rather than from the
      // clock: a skewed device time would otherwise strand real messages behind
      // the watermark. Forwards only, and only now that the pass has finished —
      // a scan that threw leaves the watermark alone, so the next one covers
      // the same ground again.
      if (newest != null) {
        final current = await _db.lastScannedSmsDate();
        if (current == null || newest.isAfter(current)) {
          await _db.setLastScannedSmsDate(newest);
        }
      }

      await _load();

      // Fire and forget, deliberately outside the scan's own timing. Awaiting it
      // would leave the scan spinner turning on a dead VPN for as long as the
      // push takes to give up, for a step the user did not ask to wait for.
      if (added > 0) unawaited(_autoSync());

      return _ScanResult(
          added: added, skipped: skipped, addedInView: addedInView);
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
  }

  /// Uploads after a scan, if that was asked for and a server is configured.
  ///
  /// Silent either way. This runs without the user having pressed anything, so a
  /// SnackBar about a VPN that is not connected would be an interruption rather
  /// than news — Settings shows the last result for anyone who wants to know.
  Future<void> _autoSync() async {
    if (!await SyncPrefs.instance.autoAfterScan()) return;
    if (!await SyncPrefs.instance.isConfigured) return;
    await SyncClient.instance.syncNow();
  }

  /// The toolbar action. [full] ignores the watermark and re-reads everything —
  /// safe to run at any time, since duplicates are caught by the natural key
  /// index and deliberately deleted rows by their tombstones. Worth doing after
  /// the parser learns a new template.
  Future<void> _scanFromToolbar({bool full = false}) async {
    if (!_sms.isSupported) {
      _toast('Inbox scanning is only available on Android.');
      return;
    }
    final granted = await _sms.requestPermission();
    if (!granted) {
      _toast('SMS permission denied.');
      return;
    }

    final since = full ? null : await _db.lastScannedSmsDate();
    final result = await _scan(since: since);
    if (result == null) return; // a scan was already running

    if (result.added == 0 && result.skipped == 0) {
      _toast('No new bank messages found.');
      return;
    }
    // Only worth saying when the two numbers differ — otherwise it is noise.
    final String elsewhere = result.added > result.addedInView
        ? ' · ${result.addedInView} in ${periodLabel(_filters.months)}'
        : '';
    _toast('Imported ${result.added} new transaction(s), skipped '
        '${result.skipped} already recorded or deleted.$elsewhere');
  }

  // -------------------------------------------------------------------------
  // EDITING
  // -------------------------------------------------------------------------

  /// Feeds an arbitrary SMS body through parse -> auto-categorize -> insert.
  Future<void> _ingest(String body) async {
    final parsed = SmsParser.parse(body);
    if (parsed == null) {
      _toast('Could not parse that SMS — no template matched.');
      return;
    }
    final id = await _db.insertParsed(parsed);
    await _load();
    final verb = parsed.isCredit ? 'Received' : 'Added';
    _toast(id == 0
        ? 'Already recorded or deleted: ${parsed.merchant}'
        : '$verb ${_money.format(parsed.amount)} · ${parsed.merchant}'
            '${_outOfViewSuffix(parsed.date)}');
  }

  /// Names the month when a row has just been imported into one the list is not
  /// showing.
  ///
  /// Without it, adding a transaction dated last month says "Added ₹450 ·
  /// SWIGGY" over a list where nothing appeared — which reads as the app having
  /// lost it. Saying where it went is better than silently widening the
  /// selection the user chose.
  String _outOfViewSuffix(DateTime date) {
    final YearMonth month = YearMonth.fromDate(date);
    if (_filters.months.isEmpty || _filters.months.contains(month)) return '';
    return ' · in ${month.label}';
  }

  /// Step 5: persist the merchant -> category mapping and backfill history.
  /// Categorises **this transaction** and, only if asked, makes the pick the
  /// merchant's default as well.
  ///
  /// Correcting one row used to re-tag every transaction from that merchant,
  /// which is far more than anyone means by it — and would silently flatten a
  /// split. The rule is now the narrow one, and the wider one is opt-in.
  Future<void> _pickCategory(ExpenseTxn txn) async {
    final chosen = await showModalBottomSheet<CategoryChoice>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => CategoryPickerSheet(
        merchant: txn.merchant,
        categories: _categories,
        selectedId: txn.isUncategorized ? null : txn.categoryId,
        subtitle: txn.isSplit
            ? 'This transaction is split. Picking a category replaces its '
                'split with one category.'
            : 'Applies to this transaction.',
        showMakeDefault: true,
      ),
    );
    if (chosen == null) return;

    await _db.setTransactionCategory(
      transactionId: txn.id,
      categoryId: chosen.category.id,
    );

    var updated = 0;
    if (chosen.makeDefault) {
      updated = await _setMerchantDefault(txn.merchant, chosen.category);
      if (!mounted) return;
    }

    await _load();
    _toast(chosen.makeDefault
        ? '${txn.merchant} → ${chosen.category.name} '
            '(default set${updated > 0 ? ', $updated updated' : ''})'
        : '${txn.merchant} → ${chosen.category.name}');
  }

  /// Writes what the user wants to remember about one charge — the context the
  /// bank's alert could never carry.
  ///
  /// Saving an empty field is how a note is removed, so there is no separate
  /// delete: clearing the box and pressing Save is the obvious gesture, and
  /// honouring it costs nothing.
  Future<void> _editNote(ExpenseTxn txn) async {
    final TextEditingController controller =
        TextEditingController(text: txn.note);
    // Selection parked at the end so an existing note is added to rather than
    // typed over, which is what reopening one is nearly always for.
    controller.selection =
        TextSelection.collapsed(offset: controller.text.length);

    final String? typed = await showDialog<String>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(txn.hasNote ? 'Edit note' : 'Add note'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          maxLength: kNoteMaxLength,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            hintText: 'What was this for?',
            helperText: '${txn.merchant} · ${_money.format(txn.amount)}',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted || typed == null) return;

    final String note = cleanNote(typed);
    if (note == txn.note) return; // Opened, changed nothing, backed out.

    await _db.setTransactionNote(transactionId: txn.id, note: note);
    if (!mounted) return;
    await _load();
    _toast(note.isEmpty ? 'Note removed' : 'Note saved');
  }

  /// Saves the merchant default, asking first whether history should move with
  /// it. Returns how many past transactions were re-tagged.
  Future<int> _setMerchantDefault(
    String merchant,
    ExpenseCategory category,
  ) async {
    final int uncategorized = await _db.uncategorizedId();
    var backfill = false;

    // Uncategorized as a default means "always ask me", which is never applied
    // backwards — see [AppDatabase.setMerchantDefault].
    if (category.id != uncategorized) {
      final int n = await _db.backfillableCount(
        merchant: merchant,
        categoryId: category.id,
      );
      if (!mounted) return 0;
      if (n > 0) {
        backfill = await showDialog<bool>(
              context: context,
              builder: (BuildContext context) => AlertDialog(
                title: const Text('Apply to past transactions?'),
                content: Text(
                  '$n past transaction${n == 1 ? '' : 's'} from $merchant '
                  'would move to ${category.name}. Transactions you have '
                  'split are left alone.',
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
    if (!mounted) return 0;

    return _db.setMerchantDefault(
      merchant: merchant,
      categoryId: category.id,
      backfill: backfill,
    );
  }

  /// Deletes for good — the tombstones written by
  /// [AppDatabase.deleteTransactions] keep these rows from being re-imported by
  /// a later scan, and put them in the Deleted section for as long as it takes
  /// to change your mind.
  Future<void> _delete(List<ExpenseTxn> gone) async {
    if (gone.isEmpty) return;
    final ids = gone.map((ExpenseTxn t) => t.id).toSet();

    // Drop them from the list in this same frame: `Dismissible` has already
    // animated its row out and asserts if it is still in the tree on the next
    // build, which an awaited round trip to the database would allow.
    setState(() {
      _transactions =
          _transactions.where((ExpenseTxn t) => !ids.contains(t.id)).toList();
      _selected.removeAll(ids);
    });
    await _db.deleteTransactions(gone);
    if (!mounted) return;

    // Read them back so Undo restores from the tombstones themselves, which is
    // the same path the Deleted section uses.
    final tombstones = (await _db.deletedTransactions())
        .where((DeletedTxn d) => ids.contains(d.originalId))
        .toList();
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(gone.length == 1
            ? 'Deleted ${gone.single.merchant}'
            : 'Deleted ${gone.length} transactions'),
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () async {
            await _db.restoreTransactions(tombstones);
            await _load();
          },
        ),
      ));
  }

  // ---- Selection ----------------------------------------------------------

  /// Long-press starts marking; once anything is marked, plain taps toggle.
  void _toggleSelected(ExpenseTxn txn) {
    setState(() {
      if (!_selected.remove(txn.id)) _selected.add(txn.id);
    });
  }

  void _clearSelection() => setState(_selected.clear);

  /// Bulk delete asks first, through the same
  /// [confirmDeleteTransactions] a swipe goes through. The selection bar's
  /// delete sits exactly where the overflow menu is otherwise, so a reach for
  /// the menu can land on it.
  Future<void> _confirmBulkDelete() async {
    final gone = _transactions
        .where((ExpenseTxn t) => _selected.contains(t.id))
        .toList();
    if (gone.isEmpty) return;

    final bool confirmed = await confirmDeleteTransactions(context, gone.length);
    if (!mounted || !confirmed) return;
    await _delete(gone);
  }

  /// Everything that can be done from one row — categorise, split, merge its
  /// names, delete — in one sheet, so the list itself needs no per-row
  /// controls.
  Future<void> _openTransaction(ExpenseTxn txn) async {
    final action = await showModalBottomSheet<TxnAction>(
      context: context,
      showDragHandle: true,
      builder: (_) => TransactionActionsSheet(
        txn: txn,
        money: _money,
        dateFormat: _dateFormat,
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case TxnAction.categorize:
        await _pickCategory(txn);
      case TxnAction.note:
        await _editNote(txn);
      case TxnAction.split:
        await _splitTransaction(txn);
      case TxnAction.mergeMerchant:
        await _openMerge(NameKind.merchant, txn.merchant);
      case TxnAction.mergeCard:
        await _openMerge(NameKind.card, txn.paymentType);
      case TxnAction.delete:
        await _delete(<ExpenseTxn>[txn]);
    }
  }

  /// Opens the merge screen with [preselect] already ticked — the name on the
  /// row the user was looking at when they noticed the duplicate.
  Future<void> _openMerge(NameKind kind, String preselect) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => MergeNamesScreen(
        kind: kind,
        preselect: preselect,
        // Unlike the Settings route, this one comes off the transaction list,
        // which is still underneath and holding the old names.
        onChanged: _load,
      ),
    ));
  }

  Future<void> _splitTransaction(ExpenseTxn txn) async {
    final bool? changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute<bool>(
        builder: (_) => SplitScreen(
          txn: txn,
          categories: _categories,
          money: _money,
        ),
      ),
    );
    if (changed != true) return;
    await _load();
  }

  Future<void> _openDeleted() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => DeletedScreen(
        money: _money,
        dateFormat: _dateFormat,
        onChanged: _load,
      ),
    ));
  }

  /// The launch-time update check. Silent unless there is something to install:
  /// a check that is switched off, not yet due, offline or already current all
  /// pass without a word.
  Future<void> _checkForUpdates() async {
    final release = await UpdateService.instance.checkOnLaunch();
    if (!mounted || release == null) return;
    await showUpdateDialog(context, release);
  }

  Future<void> _addSmsManually() async {
    final controller = TextEditingController(text: kSampleSms);
    final body = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Paste an SMS'),
        content: TextField(
          controller: controller,
          maxLines: 6,
          minLines: 4,
          autofocus: true,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: 'Any Yes Bank / HDFC / ICICI spend or credit alert',
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('Parse'),
          ),
        ],
      ),
    );
    if (body != null && body.trim().isNotEmpty) {
      await _ingest(body);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  // ---- The view over the ledger -------------------------------------------

  /// Delegates to [deriveLedgerView] so the web build derives its view with
  /// this exact code rather than a second copy of it.
  LedgerView _derive() => deriveLedgerView(
        transactions: _transactions,
        allCategories: _categories,
        requested: _filters,
        currentMonth: _currentMonth,
        sort: _sort,
      );

  /// [visible] is what the filters currently leave on screen. Select all means
  /// all of *those* — marking rows a filter has hidden would hand the delete
  /// button transactions the user cannot see.
  AppBar _selectionAppBar(List<LedgerEntry> visible) {
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
            ..addAll(visible.map((LedgerEntry e) => e.txn.id))),
          icon: const Icon(Icons.select_all),
        ),
        IconButton(
          tooltip: 'Delete',
          onPressed: _confirmBulkDelete,
          icon: const Icon(Icons.delete_outline),
        ),
      ],
    );
  }

  AppBar _normalAppBar() {
    return AppBar(
      title: const Text('Transactions'),
      actions: <Widget>[
        if (_scanning)
          const Center(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          )
        else
          IconButton(
            tooltip: 'Check for new SMS',
            onPressed: () => _scanFromToolbar(),
            icon: const Icon(Icons.sms_outlined),
          ),
        PopupMenuButton<String>(
          onSelected: (String value) {
            switch (value) {
              case 'rescan':
                _scanFromToolbar(full: true);
              case 'deleted':
                _openDeleted();
            }
          },
          itemBuilder: (_) => const <PopupMenuEntry<String>>[
            PopupMenuItem<String>(
              value: 'deleted',
              child: Text('Deleted transactions'),
            ),
            PopupMenuItem<String>(
              value: 'rescan',
              child: Text('Rescan all messages'),
            ),
          ],
        ),
      ],
    );
  }

  /// Settings can change what the ledger says — Merchants & defaults backfills
  /// a category over history — so coming back from it reloads rather than
  /// showing rows still carrying the categories they had on the way in.
  void _selectTab(HomeTab tab) {
    final bool leavingSettings =
        _tab == HomeTab.settings && tab != HomeTab.settings;
    setState(() {
      _tab = tab;
      // Marks are about rows on the ledger; leaving it drops them.
      _selected.clear();
    });
    if (leavingSettings) _load();
  }

  @override
  Widget build(BuildContext context) {
    final bool onLedger = _tab == HomeTab.transactions;
    final bool selecting = _selected.isNotEmpty;
    final view = _derive();

    return PopScope(
      // Back should leave selection mode before it leaves the app.
      canPop: !selecting,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (!didPop) _clearSelection();
      },
      child: Scaffold(
        // Selection only ever happens on the ledger, so it outranks the tab.
        appBar: selecting
            ? _selectionAppBar(view.visible)
            : switch (_tab) {
                HomeTab.dashboard => AppBar(title: const Text('Dashboard')),
                // The scan and Deleted actions live here and only here. Two
                // entry points to a mutating action on two screens is a footgun.
                HomeTab.transactions => _normalAppBar(),
                HomeTab.settings => AppBar(title: const Text('Settings')),
              },
        // IndexedStack rather than a swap, so switching tabs keeps the ledger's
        // scroll position and Settings' loaded state.
        //
        // These children MUST stay in `HomeTab.values` order — position is the
        // index, and nothing in the type system says so. The assert in
        // `initState` catches a destination added without a child.
        body: IndexedStack(
          index: _tab.index,
          children: <Widget>[
            DashboardTab(
              transactions: _transactions,
              months: _dashboardMonths,
              monthChoices: monthOptions(
                _transactions,
                current: _currentMonth,
                keep: _dashboardMonths,
              ),
              currentMonth: _currentMonth,
              money: _money,
              loading: _loading,
              onMonthsChanged: (Set<YearMonth> m) =>
                  setState(() => _dashboardMonths = m),
              onRefresh: _load,
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
              // The list can be empty because the ledger is, or because the
              // filters excluded everything — two different things to say.
              ledgerIsEmpty: _transactions.isEmpty,
              selected: _selected,
              onFiltersChanged: (LedgerFilters f) =>
                  setState(() => _filters = f),
              onSortChanged: (LedgerSort s) => setState(() => _sort = s),
              onRefresh: _load,
              onTap: _openTransaction,
              onToggleSelected: _toggleSelected,
              onDelete: (ExpenseTxn txn) => _delete(<ExpenseTxn>[txn]),
            ),
            // Not const any more, and it needs the callback: a sync applies
            // edits made in a browser, so Settings can now change the ledger.
            // IndexedStack keeps this alive, so relying on the leaving-Settings
            // reload alone would leave stale rows on screen until then.
            SettingsScreen(onChanged: _load),
          ],
        ),
        floatingActionButton: onLedger && !selecting
            ? FloatingActionButton.extended(
                onPressed: _addSmsManually,
                icon: const Icon(Icons.content_paste_outlined),
                label: const Text('Paste an SMS'),
              )
            : null,
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tab.index,
          onDestinationSelected: (int i) => _selectTab(HomeTab.values[i]),
          destinations: <NavigationDestination>[
            for (final HomeTab tab in HomeTab.values)
              NavigationDestination(
                icon: Icon(tab.icon),
                selectedIcon: Icon(tab.selectedIcon),
                label: tab.label,
              ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// TRANSACTION ACTIONS — everything one row can be told to do
// ---------------------------------------------------------------------------
