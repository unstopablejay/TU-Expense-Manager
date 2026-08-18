import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';

import 'src/core/aliases.dart';
import 'src/core/backup_data.dart';
import 'src/core/backup_validate.dart';
import 'src/core/constants.dart';
import 'src/core/ledger.dart';
import 'src/core/ledger_view.dart';
import 'src/core/models.dart';
import 'src/core/parser.dart';
import 'src/core/splits.dart';
import 'src/mobile/backup_dialogs.dart';
import 'src/mobile/backup_files.dart';
import 'src/mobile/database.dart';
import 'src/mobile/sms_source.dart';
import 'src/mobile/update_service.dart';
import 'src/ui_shared/dashboard_tab.dart';
import 'src/ui_shared/formats.dart';
import 'src/ui_shared/palette.dart';
import 'src/ui_shared/theme.dart';
import 'src/ui_shared/transactions_tab.dart';

// Re-exported so `package:tu_expense_tracker/main.dart` still resolves every
// name it did as one file. The test suite imports exactly that, and outside
// callers should not have to know which file a symbol ended up in.

export 'src/core/aliases.dart';
export 'src/core/backup_data.dart';
export 'src/core/backup_validate.dart';
export 'src/core/constants.dart';
export 'src/core/ledger.dart';
export 'src/core/ledger_view.dart';
export 'src/core/models.dart';
export 'src/core/parser.dart';
export 'src/core/splits.dart';
export 'src/mobile/backup_dialogs.dart';
export 'src/mobile/backup_files.dart';
export 'src/mobile/backup_xlsx.dart';
export 'src/mobile/database.dart';
export 'src/mobile/sms_source.dart';
export 'src/mobile/update_service.dart';
export 'src/ui_shared/dashboard_tab.dart';
export 'src/ui_shared/formats.dart';
export 'src/ui_shared/palette.dart';
export 'src/ui_shared/shared_controls.dart';
export 'src/ui_shared/theme.dart';
export 'src/ui_shared/transactions_tab.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TuExpenseTrackerApp());
}

// ---------------------------------------------------------------------------
// 5. UI
// ---------------------------------------------------------------------------

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
      return _ScanResult(
          added: added, skipped: skipped, addedInView: addedInView);
    } finally {
      if (mounted) setState(() => _scanning = false);
    }
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
            const SettingsScreen(),
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

enum TxnAction { categorize, note, split, mergeMerchant, mergeCard, delete }

class TransactionActionsSheet extends StatelessWidget {
  const TransactionActionsSheet({
    super.key,
    required this.txn,
    required this.money,
    required this.dateFormat,
  });

  final ExpenseTxn txn;
  final NumberFormat money;
  final DateFormat dateFormat;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        // A scrolling list rather than a `Column`, because the sheet has
        // outgrown a short screen: a header, any note, a chip per split line
        // and six actions is more than a default bottom sheet's height, and a
        // `Column` that does not fit simply clips — silently taking Delete off
        // the bottom rather than saying anything. `shrinkWrap` keeps it as
        // short as its contents whenever they do fit.
        child: ListView(
          shrinkWrap: true,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    txn.merchant,
                    style: theme.textTheme.titleLarge,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  txn.isCredit
                      ? '+${money.format(txn.amount)}'
                      : money.format(txn.amount),
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: txn.isCredit ? creditColor(theme) : null,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${txn.paymentType} · ${dateFormat.format(txn.date)}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: <Widget>[
                for (final TxnSplit line in txn.effectiveSplits)
                  Chip(
                    avatar: Icon(categoryIcon(line.categoryName), size: 18),
                    label: Text(
                      txn.isSplit
                          ? '${line.categoryName} ${money.format(line.amount)}'
                          : line.categoryName,
                    ),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            // The tile shows the note on one ellipsised line, so this is where
            // a long one is actually read.
            if (txn.hasNote) ...<Widget>[
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    Icons.sticky_note_2_outlined,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      txn.note,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontStyle: FontStyle.italic,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const Divider(height: 28),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.label_outline),
              title: const Text('Change category'),
              onTap: () => Navigator.pop(context, TxnAction.categorize),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.sticky_note_2_outlined),
              title: Text(txn.hasNote ? 'Edit note' : 'Add note'),
              subtitle: const Text('Why this one happened'),
              onTap: () => Navigator.pop(context, TxnAction.note),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.call_split),
              title: Text(txn.isSplit ? 'Edit split' : 'Split'),
              subtitle: const Text('Across several categories'),
              onTap: () => Navigator.pop(context, TxnAction.split),
            ),
            const Divider(height: 28),
            // These two act on the name, not on this transaction — the row is
            // just where a duplicate is usually noticed.
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.merge_type),
              title: const Text('Merge merchant'),
              subtitle: Text(
                txn.merchant,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => Navigator.pop(context, TxnAction.mergeMerchant),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.credit_card),
              title: const Text('Merge card / account'),
              subtitle: Text(
                txn.paymentType,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: () => Navigator.pop(context, TxnAction.mergeCard),
            ),
            const Divider(height: 28),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.delete_outline, color: theme.colorScheme.error),
              title: Text(
                'Delete',
                style: TextStyle(color: theme.colorScheme.error),
              ),
              subtitle: const Text('Kept out of future scans; restorable'),
              onTap: () => Navigator.pop(context, TxnAction.delete),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// DELETED SECTION — every tombstone, and the way back
// ---------------------------------------------------------------------------

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

/// One editable row of the split screen. The controller lives here rather than
/// in a list beside the data so that deleting a row cannot leave the two out of
/// step.
class _SplitRow {
  _SplitRow({this.category, double? amount})
      : controller = TextEditingController(
          text: amount == null ? '' : _plain(amount),
        );

  /// Two decimals, no grouping separators and no symbol — this is a text field
  /// being typed into, not a figure being displayed.
  static String _plain(double v) => v.toStringAsFixed(2);

  ExpenseCategory? category;
  final TextEditingController controller;

  double get amount => double.tryParse(controller.text.trim()) ?? 0;

  set amount(double v) => controller.text = _plain(v);

  void dispose() => controller.dispose();
}

/// Splits one transaction across several categories.
///
/// A single Amazon charge covers groceries, snacks and shopping, but the bank
/// only ever says "₹2,000". Tagging the whole amount three times would count it
/// three times over; splitting it into lines that sum to the charge keeps every
/// total honest.
///
/// The last row always carries whatever is left over, so filling in the rows
/// above is enough — type 1,200 against a ₹2,000 charge and the second row
/// becomes 800 on its own.
class SplitScreen extends StatefulWidget {
  const SplitScreen({
    super.key,
    required this.txn,
    required this.categories,
    required this.money,
  });

  final ExpenseTxn txn;
  final List<ExpenseCategory> categories;
  final NumberFormat money;

  @override
  State<SplitScreen> createState() => _SplitScreenState();
}

class _SplitScreenState extends State<SplitScreen> {
  late List<_SplitRow> _rows;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    if (widget.txn.isSplit) {
      _rows = widget.txn.splits
          .map((TxnSplit s) => _SplitRow(
                category: _categoryById(s.categoryId),
                amount: s.amount,
              ))
          .toList();
    } else {
      // Two rows to start: one to fill in, and one already holding the whole
      // charge as the balance, so the arithmetic is visible before anything is
      // typed.
      _rows = <_SplitRow>[
        _SplitRow(),
        _SplitRow(amount: widget.txn.amount),
      ];
    }
  }

  @override
  void dispose() {
    for (final _SplitRow row in _rows) {
      row.dispose();
    }
    super.dispose();
  }

  ExpenseCategory? _categoryById(int id) => widget.categories
      .where((ExpenseCategory c) => c.id == id)
      .firstOrNull;

  List<double> get _amounts =>
      _rows.map((_SplitRow r) => r.amount).toList();

  /// Rewrites the last row to the balance. Called after any edit to a row above
  /// it — editing the last row itself is left alone, so it can be corrected by
  /// hand even if that leaves the split unbalanced.
  void _rebalance({required int editedIndex}) {
    if (editedIndex == _rows.length - 1) {
      setState(() {});
      return;
    }
    final List<double> next = withRemainderInLast(_amounts, widget.txn.amount);
    setState(() => _rows.last.amount = next.last);
  }

  Future<void> _pickCategoryFor(_SplitRow row) async {
    final CategoryChoice? chosen = await showModalBottomSheet<CategoryChoice>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => CategoryPickerSheet(
        merchant: widget.txn.merchant,
        categories: widget.categories,
        selectedId: row.category?.id,
        title: 'Category for this line',
      ),
    );
    if (chosen == null) return;
    setState(() => row.category = chosen.category);
  }

  void _addRow() => setState(() {
        // The new row takes the balance, which means the one that was holding
        // it keeps whatever was typed there.
        final double remainder = unallocated(_amounts, widget.txn.amount);
        _rows.add(_SplitRow(amount: remainder > 0 ? remainder : 0));
      });

  void _removeRow(int index) => setState(() {
        _rows.removeAt(index).dispose();
        if (_rows.isNotEmpty) {
          _rows.last.amount =
              withRemainderInLast(_amounts, widget.txn.amount).last;
        }
      });

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);

    // The last line absorbs the rounding drift, so what is stored sums to the
    // charge exactly rather than to within a tolerance of it.
    final List<double> exact =
        withRemainderInLast(_amounts, widget.txn.amount);
    final List<TxnSplit> lines = <TxnSplit>[
      for (var i = 0; i < _rows.length; i++)
        TxnSplit(
          categoryId: _rows[i].category!.id,
          categoryName: _rows[i].category!.name,
          amount: exact[i],
        ),
    ];

    await AppDatabase.instance.saveSplits(widget.txn, lines);
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  Future<void> _removeSplit() async {
    setState(() => _saving = true);
    await AppDatabase.instance.clearSplits(widget.txn.id);
    if (!mounted) return;
    Navigator.pop(context, true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final double left = unallocated(_amounts, widget.txn.amount);
    final bool balanced = isBalanced(_amounts, widget.txn.amount);
    final bool complete =
        _rows.isNotEmpty && _rows.every((_SplitRow r) => r.category != null);
    final bool positive = _rows.every((_SplitRow r) => r.amount > 0);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Split'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(28),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    widget.txn.merchant,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium,
                  ),
                ),
                Text(
                  widget.money.format(widget.txn.amount),
                  style: theme.textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        ),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
        itemCount: _rows.length + 1,
        itemBuilder: (BuildContext context, int index) {
          if (index == _rows.length) {
            return Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _addRow,
                icon: const Icon(Icons.add),
                label: const Text('Add row'),
              ),
            );
          }
          final _SplitRow row = _rows[index];
          return Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  flex: 3,
                  child: OutlinedButton(
                    onPressed: () => _pickCategoryFor(row),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          categoryIcon(row.category?.name ?? ''),
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            row.category?.name ?? 'Choose category',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: row.category == null
                                ? TextStyle(color: theme.colorScheme.error)
                                : null,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 2,
                  child: TextField(
                    controller: row.controller,
                    textAlign: TextAlign.end,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      prefixText: '₹',
                    ),
                    onChanged: (_) => _rebalance(editedIndex: index),
                  ),
                ),
                IconButton(
                  tooltip: 'Remove row',
                  // Below two rows there is nothing left to split.
                  onPressed:
                      _rows.length > 2 ? () => _removeRow(index) : null,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                balanced
                    ? 'Allocated ${widget.money.format(widget.txn.amount)} '
                        'of ${widget.money.format(widget.txn.amount)}'
                    : left > 0
                        ? '${widget.money.format(left)} unallocated'
                        : '${widget.money.format(left.abs())} over',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: balanced
                      ? theme.colorScheme.primary
                      : theme.colorScheme.error,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (!complete)
                Text(
                  'Every row needs a category.',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.error),
                ),
              const SizedBox(height: 8),
              Row(
                children: <Widget>[
                  if (widget.txn.isSplit)
                    TextButton(
                      onPressed: _saving ? null : _removeSplit,
                      child: const Text('Remove split'),
                    ),
                  const Spacer(),
                  FilledButton(
                    onPressed:
                        balanced && complete && positive && !_saving
                            ? _save
                            : null,
                    child: const Text('Save'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

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
    final category = await AppDatabase.instance.addCategory(name);
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
            if (widget.alwaysAskLabel != null && uncategorized != null) ...[
              ActionChip(
                avatar: const Icon(Icons.help_outline, size: 18),
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
                      avatar: Icon(categoryIcon(category.name), size: 18),
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

  /// Writes [rows] as the whole alias set, reloads, and offers to put back
  /// whatever was there before.
  Future<void> _apply(Map<String, String> rows, String message) async {
    final Map<String, String> before = _aliases.rowsFor(widget.kind);
    await _db.setAliases(widget.kind, rows);
    setState(_selected.clear);
    await Future.wait(<Future<void>>[
      _load(),
      if (widget.onChanged != null) widget.onChanged!(),
    ]);
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
                      leading: CircleAvatar(
                        backgroundColor: unset
                            ? theme.colorScheme.surfaceContainerHighest
                            : theme.colorScheme.primaryContainer,
                        foregroundColor: unset
                            ? theme.colorScheme.onSurfaceVariant
                            : theme.colorScheme.onPrimaryContainer,
                        child: Icon(
                          alwaysAsk
                              ? Icons.help_outline
                              : unset
                                  ? Icons.help_outline
                                  : categoryIcon(m.defaultCategoryName!),
                          size: 20,
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
    final String? name = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _NewCategorySheet(
        taken: <String>[
          for (final CategoryUsage usage in _usage) usage.category.name,
        ],
      ),
    );
    if (name == null || !mounted) return;

    final ExpenseCategory added = await _db.addCategory(name);
    await _load();
    if (!mounted) return;

    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text('Added ${added.name}')));
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
    final Brightness brightness = theme.brightness;

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
                  leading: Icon(
                    categoryIcon(name),
                    color: categoryColor(name, brightness),
                  ),
                  title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text(_subtitle(usage)),
                  trailing: _isFallback(usage)
                      ? null
                      : IconButton(
                          tooltip: 'Delete $name',
                          icon: const Icon(Icons.delete_outline),
                          color: theme.colorScheme.error,
                          onPressed: () => _delete(usage),
                        ),
                );
              },
            ),
    );
  }
}

/// Names a new category.
///
/// The names already in use come in so a collision is caught while it is still
/// being typed. [AppDatabase.addCategory] would quietly hand back the existing
/// row instead — exactly right for the picker on a transaction, where the user
/// wants *a* category by that name and does not care whether it had to be
/// created, and wrong here, where the list is the subject and an Add that
/// appears to do nothing is the whole confusion.
class _NewCategorySheet extends StatefulWidget {
  const _NewCategorySheet({required this.taken});

  final List<String> taken;

  @override
  State<_NewCategorySheet> createState() => _NewCategorySheetState();
}

class _NewCategorySheetState extends State<_NewCategorySheet> {
  final TextEditingController _name = TextEditingController();

  /// Lower-cased name to the spelling on screen, so a clash can be reported in
  /// the words the list actually shows.
  ///
  /// Case-insensitive because the column is `UNIQUE COLLATE NOCASE` — "grocery"
  /// would not be a second category, it would be a failed insert. Dart's
  /// lower-casing is the Unicode one and SQLite's NOCASE only folds ASCII, so
  /// this can refuse a name the table would have taken; erring towards refusing
  /// is the harmless direction.
  late final Map<String, String> _taken = <String, String>{
    for (final String name in widget.taken) name.toLowerCase(): name,
  };

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final String name = _name.text.trim();
    if (name.isEmpty || _taken.containsKey(name.toLowerCase())) return;
    Navigator.pop(context, name);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final String typed = _name.text.trim();
    final String? clash = _taken[typed.toLowerCase()];

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
            Text('New category', style: theme.textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'It joins the picker on every transaction and can be set as a '
              "merchant's default.",
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              onChanged: (_) => setState(() {}),
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                isDense: true,
                border: const OutlineInputBorder(),
                labelText: 'Call it',
                errorText: clash == null ? null : '$clash already exists',
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: <Widget>[
                const Spacer(),
                FilledButton(
                  // Dead until there is a name that can actually be inserted,
                  // rather than pressable and silently ineffective.
                  onPressed: typed.isEmpty || clash != null ? null : _submit,
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
    final Brightness brightness = theme.brightness;
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
                      avatar: Icon(
                        categoryIcon(category.name),
                        size: 18,
                        color: categoryColor(category.name, brightness),
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

/// The second destination. A body only — the shell it sits in supplies the
/// Scaffold and the app bar, so there is no second one of either here.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final DateFormat _checkedFormat = DateFormat('d MMM yyyy, h:mm a');

  bool _autoCheck = true;
  String _version = '';
  String _build = '';
  DateTime? _lastChecked;
  bool _loading = true;
  bool _checking = false;

  /// One at a time, and neither while the other runs: both walk the whole
  /// database, and a restore landing halfway through an export would write a
  /// workbook of two different ledgers.
  bool _exporting = false;
  bool _restoring = false;

  bool get _busyWithData => _exporting || _restoring;

  /// The release a check on this screen turned up, kept so the Install button
  /// survives dismissing the dialog.
  AppRelease? _available;

  /// The outcome of the last manual check, in one line. Null before anything
  /// has been asked for, and while an update is being offered instead.
  String? _status;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final info = await PackageInfo.fromPlatform();
    final auto = await UpdatePrefs.instance.autoCheckEnabled();
    final last = await UpdatePrefs.instance.lastChecked();
    if (!mounted) return;
    setState(() {
      _version = info.version;
      _build = info.buildNumber;
      _autoCheck = auto;
      _lastChecked = last;
      _loading = false;
    });
  }

  Future<void> _setAutoCheck(bool value) async {
    // Optimistic: the switch is the only writer, so there is nothing to lose a
    // race against and no reason to make it lag a disk write.
    setState(() => _autoCheck = value);
    await UpdatePrefs.instance.setAutoCheckEnabled(value);
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  /// Writes the whole database to a workbook and offers it to the share sheet,
  /// which is how it reaches Drive — and from Drive, Google Sheets.
  Future<void> _export() async {
    if (_busyWithData) return;
    setState(() => _exporting = true);
    try {
      final BackupData data = await AppDatabase.instance.exportAll();
      final File file =
          await writeBackup(data, backupFileName(DateTime.now()));
      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(
          files: <XFile>[XFile(file.path, mimeType: kXlsxMimeType)],
          subject: 'TU Expense Tracker backup',
          text: '${data.meta['transactions']} transactions, exported '
              '${DateFormat('d MMM yyyy').format(DateTime.now())}.',
        ),
      );
    } catch (error) {
      _say('The export failed: $error');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// Reads a workbook back over the top of everything.
  ///
  /// Nothing is deleted until the file has been decoded, validated and
  /// confirmed, and a copy of what is about to be replaced has been written —
  /// so every way this can fail is a way that leaves the ledger alone.
  Future<void> _restore() async {
    if (_busyWithData) return;

    final PlatformFile? picked = await FilePicker.pickFile(
      dialogTitle: 'Choose a backup workbook',
      type: FileType.custom,
      allowedExtensions: const <String>['xlsx'],
    );
    if (picked == null || !mounted) return;

    setState(() => _restoring = true);
    try {
      final (BackupData? backup, String? unreadable) =
          await decodeBackupInBackground(await picked.readAsBytes());
      if (!mounted) return;
      if (backup == null) {
        await showBackupProblems(context, <String>[unreadable!]);
        return;
      }

      final List<String> problems = validateBackup(
        backup,
        appSchemaVersion: kSchemaVersion,
      );
      if (problems.isNotEmpty) {
        await showBackupProblems(context, problems);
        return;
      }

      // Read before asking, so the question can name what is about to go.
      final BackupData current = await AppDatabase.instance.exportAll();
      if (!mounted) return;
      final bool go = await confirmRestore(
        context,
        replacing: current.transactions.length,
        incoming: backup.transactions.length,
      );
      if (!go || !mounted) return;

      // The one irreversible action in the app, made reversible. Written before
      // the wipe rather than after, so a crash in between still leaves it.
      final File safety = await writeBackup(
        current,
        backupFileName(DateTime.now(), beforeRestore: true),
      );
      await AppDatabase.instance.replaceAll(backup);
      if (!mounted) return;

      await showDialog<void>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: const Text('Restored'),
          content: Text(
            '${backup.transactions.length} transactions, '
            '${backup.categories.length} categories and '
            '${backup.deleted.length} deleted rows are back.\n\n'
            'What was here before was saved as ${p.basename(safety.path)}.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    } catch (error) {
      _say('The restore failed: $error');
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  /// The explicit check. Unlike the launch one this always reports back, so a
  /// press of the button is never met with silence.
  Future<void> _checkNow() async {
    setState(() {
      _checking = true;
      _status = null;
      _available = null;
    });

    final result = await UpdateService.instance.check();
    final last = await UpdatePrefs.instance.lastChecked();
    if (!mounted) return;

    setState(() {
      _checking = false;
      _lastChecked = last;
      _available = result.release;
      _status = result.failed
          ? result.error
          : result.hasUpdate
              ? null
              : 'Up to date.';
    });

    if (result.hasUpdate) await showUpdateDialog(context, result.release!);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final release = _available;

    return _loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            children: <Widget>[
              SettingsHeader('Categorization'),
                ListTile(
                  leading: const Icon(Icons.storefront_outlined),
                  title: const Text('Merchants & defaults'),
                  subtitle: const Text(
                    'What each merchant is categorised as by default',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const MerchantDefaultsScreen(),
                    ),
                  ),
                ),
                const Divider(height: 32),
                SettingsHeader('Cleanup'),
                ListTile(
                  leading: const Icon(Icons.merge_type),
                  title: const Text('Merge merchants'),
                  subtitle: const Text(
                    'Fold several spellings of one shop into a single name',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          const MergeNamesScreen(kind: NameKind.merchant),
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.credit_card),
                  title: const Text('Merge cards & accounts'),
                  subtitle: const Text(
                    'One account can arrive labelled differently by each alert',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          const MergeNamesScreen(kind: NameKind.card),
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.label_outline),
                  title: const Text('Categories'),
                  subtitle: const Text(
                    'Add one, or drop one you never use — its transactions '
                    'move, not go',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const CategoriesScreen(),
                    ),
                  ),
                ),
                const Divider(height: 32),
                SettingsHeader('Data'),
                ListTile(
                  leading: const Icon(Icons.table_view_outlined),
                  title: const Text('Export data'),
                  subtitle: const Text(
                    'A spreadsheet of everything — and the same file a '
                    'restore reads back',
                  ),
                  trailing: _exporting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : FilledButton.tonal(
                          onPressed: _busyWithData ? null : _export,
                          child: const Text('Export'),
                        ),
                ),
                ListTile(
                  leading: const Icon(Icons.settings_backup_restore),
                  title: const Text('Restore from backup'),
                  subtitle: const Text(
                    'Replaces everything in the app with an exported '
                    'workbook',
                  ),
                  trailing: _restoring
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : FilledButton.tonal(
                          onPressed: _busyWithData ? null : _restore,
                          child: const Text('Restore'),
                        ),
                ),
                const Divider(height: 32),
                SettingsHeader('Updates'),
                SwitchListTile(
                  value: _autoCheck,
                  onChanged: _setAutoCheck,
                  title: const Text('Check automatically'),
                  subtitle: const Text(
                    'On launch, at most once a week. Nothing is downloaded '
                    'without asking.',
                  ),
                ),
                ListTile(
                  title: const Text('Check for updates'),
                  subtitle: Text(
                    _status ??
                        (_lastChecked == null
                            ? 'Not checked yet'
                            : 'Last checked '
                                '${_checkedFormat.format(_lastChecked!)}'),
                  ),
                  trailing: _checking
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : FilledButton.tonal(
                          onPressed: _checkNow,
                          child: const Text('Check now'),
                        ),
                ),
                if (release != null)
                  ListTile(
                    leading: Icon(
                      Icons.system_update_alt,
                      color: theme.colorScheme.primary,
                    ),
                    title: Text('Version ${release.version} available'),
                    subtitle: const Text('Downloads, then Android installs it'),
                    trailing: FilledButton(
                      onPressed: () => showUpdateDialog(context, release),
                      child: const Text('Install'),
                    ),
                  ),
                const Divider(height: 32),
                SettingsHeader('About'),
                ListTile(
                  title: const Text('TU Expense Tracker'),
                  subtitle: const Text(
                    'Turns bank SMS alerts into a categorised expense ledger.',
                  ),
                ),
                ListTile(
                  title: const Text('Version'),
                  // The build number distinguishes two APKs that report the
                  // same version, which matters while diagnosing an install.
                  subtitle: Text('$_version (build $_build)'),
                ),
                ListTile(
                  title: const Text('Releases'),
                  subtitle: const Text('github.com/$kUpdateRepo'),
                ),
                const SizedBox(height: 24),
              ],
            );
  }
}

class SettingsHeader extends StatelessWidget {
  const SettingsHeader(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        label,
        style: theme.textTheme.labelLarge
            ?.copyWith(color: theme.colorScheme.primary),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// UPDATE DIALOG
// ---------------------------------------------------------------------------

/// Offers [release], and on acceptance downloads and installs it without
/// leaving the dialog.
Future<void> showUpdateDialog(BuildContext context, AppRelease release) {
  return showDialog<void>(
    context: context,
    // A tap outside must not abandon a download in flight; Later is the way out.
    barrierDismissible: false,
    builder: (_) => UpdateDialog(release: release),
  );
}

class UpdateDialog extends StatefulWidget {
  const UpdateDialog({super.key, required this.release});

  final AppRelease release;

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  bool _downloading = false;

  /// Fraction downloaded, or null while the server has given no total to
  /// measure against — the bar then spins instead of filling.
  double? _progress;

  String? _error;

  Future<void> _install() async {
    setState(() {
      _downloading = true;
      _progress = null;
      _error = null;
    });

    try {
      final file = await UpdateService.instance.download(
        widget.release,
        onProgress: (double value) {
          if (mounted) setState(() => _progress = value);
        },
      );
      final problem = await UpdateService.instance.install(file);
      if (!mounted) return;
      if (problem != null) {
        setState(() {
          _downloading = false;
          _error = problem;
        });
        return;
      }
      // The system installer is in front of the app now; this dialog would
      // otherwise be waiting underneath it for a decision it no longer owns.
      Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _downloading = false;
        _error = 'The download failed. Check your connection and try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final notes = widget.release.notes;

    return PopScope(
      // Back must not walk out on a half-written APK either.
      canPop: !_downloading,
      child: AlertDialog(
        title: Text('Version ${widget.release.version} available'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (notes.isNotEmpty)
              // Release notes are arbitrary length, so they scroll inside a
              // bounded box rather than pushing the buttons off screen.
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: SingleChildScrollView(
                  child: Text(notes, style: theme.textTheme.bodyMedium),
                ),
              )
            else
              const Text('A newer build is ready to install.'),
            if (_downloading) ...<Widget>[
              const SizedBox(height: 20),
              LinearProgressIndicator(value: _progress),
              const SizedBox(height: 8),
              Text(
                _progress == null
                    ? 'Downloading…'
                    : 'Downloading… ${(_progress! * 100).round()}%',
                style: theme.textTheme.bodySmall,
              ),
            ],
            if (_error != null) ...<Widget>[
              const SizedBox(height: 16),
              Text(
                _error!,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: theme.colorScheme.error),
              ),
            ],
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed:
                _downloading ? null : () => Navigator.of(context).pop(),
            child: const Text('Later'),
          ),
          FilledButton(
            onPressed: _downloading ? null : _install,
            child: Text(_error == null ? 'Update' : 'Retry'),
          ),
        ],
      ),
    );
  }
}
