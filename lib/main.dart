import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:sqflite/sqflite.dart';
// Maintained fork of `telephony` (identical API). The original 0.2.0 has no
// Gradle namespace and cannot build against AGP 8+.
import 'package:another_telephony/telephony.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TuExpenseTrackerApp());
}

/// A real YES Bank credit card alert, used to prefill the manual-entry dialog
/// so the whole pipeline can be exercised without SMS permission.
const String kSampleSms =
    'INR 204.00 spent on YES BANK Card X2858 @UPI_GEORGE EGG CENTRE '
    '13-08-2026 09:21:35 am. Avl Lmt INR 281,496.08. '
    'SMS BLKCC 2858 to 9840909000 if not you';

// ---------------------------------------------------------------------------
// 1. PARSER
// ---------------------------------------------------------------------------

/// One transaction pulled out of an SMS body, before it touches the database.
class ParsedSms {
  const ParsedSms({
    required this.amount,
    required this.paymentType,
    required this.merchant,
    required this.date,
  });

  final double amount;
  final String paymentType;
  final String merchant;
  final DateTime date;

  @override
  String toString() =>
      'ParsedSms($amount, $paymentType, $merchant, ${date.toIso8601String()})';
}

class SmsParser {
  /// Matches the *first* rupee figure in the body. Order matters: the spend
  /// amount always precedes "Avl Lmt INR 281,496.08" in this format, so
  /// `firstMatch` gives the charge and not the remaining limit.
  static final RegExp amountPattern = RegExp(r'(?:INR|Rs\.?)\s*([\d,]+\.\d{2})');

  /// "spent on YES BANK Card X2858 @" -> "YES BANK Card X2858"
  static final RegExp paymentTypePattern =
      RegExp(r'(?:spent on|debited from)\s+(.*?)\s+@');

  /// "@UPI_GEORGE EGG CENTRE 13-08-2026" -> "UPI_GEORGE EGG CENTRE"
  static final RegExp merchantPattern = RegExp(r'@(.*?)\s+\d{2}-\d{2}-\d{4}');

  /// "13-08-2026 09:21:35 am"
  ///
  /// Note: `[am|pmAM|PM]+` is a character class, not an alternation — it
  /// happily matches any run of a/m/p/A/M/P/|. It works on this format, so it
  /// is kept as specified; `(?:am|pm|AM|PM)` is the stricter equivalent if you
  /// ever want to tighten it.
  static final RegExp datePattern = RegExp(
      r'(\d{2}-\d{2}-\d{4}\s+\d{2}:\d{2}:\d{2}\s+[am|pmAM|PM]+)');

  /// Returns `null` when the body is not a spend alert in this format, which
  /// is how OTPs, promos and statement SMS get filtered out.
  static ParsedSms? parse(String body) {
    final amountMatch = amountPattern.firstMatch(body);
    final merchantMatch = merchantPattern.firstMatch(body);
    final dateMatch = datePattern.firstMatch(body);
    if (amountMatch == null || merchantMatch == null || dateMatch == null) {
      return null;
    }

    final amount = double.tryParse(amountMatch.group(1)!.replaceAll(',', ''));
    if (amount == null) return null;

    final date = _parseTimestamp(dateMatch.group(1)!);
    if (date == null) return null;

    final merchant = _normalize(merchantMatch.group(1) ?? '');
    if (merchant.isEmpty) return null;

    final paymentTypeMatch = paymentTypePattern.firstMatch(body);
    final paymentType = _normalize(paymentTypeMatch?.group(1) ?? 'Unknown');

    return ParsedSms(
      amount: amount,
      paymentType: paymentType.isEmpty ? 'Unknown' : paymentType,
      merchant: merchant,
      date: date,
    );
  }

  /// Trim and collapse runs of whitespace so "GEORGE  EGG CENTRE" and
  /// "GEORGE EGG CENTRE" become the same mapping key.
  static String _normalize(String value) =>
      value.trim().replaceAll(RegExp(r'\s+'), ' ');

  /// dd-MM-yyyy hh:mm:ss am/pm -> DateTime. Parsed by hand rather than through
  /// `DateFormat` so a lowercase "am" and an uppercase "AM" both work without
  /// depending on locale data being initialised.
  static DateTime? _parseTimestamp(String raw) {
    final match = RegExp(
      r'^(\d{2})-(\d{2})-(\d{4})\s+(\d{2}):(\d{2}):(\d{2})\s*([apAP])',
    ).firstMatch(raw.trim());
    if (match == null) return null;

    final day = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final year = int.parse(match.group(3)!);
    var hour = int.parse(match.group(4)!);
    final minute = int.parse(match.group(5)!);
    final second = int.parse(match.group(6)!);

    final isPm = match.group(7)!.toLowerCase() == 'p';
    if (isPm && hour != 12) hour += 12;
    if (!isPm && hour == 12) hour = 0;

    return DateTime(year, month, day, hour, minute, second);
  }
}

// ---------------------------------------------------------------------------
// 2. DATABASE
// ---------------------------------------------------------------------------

class ExpenseCategory {
  const ExpenseCategory({required this.id, required this.name});

  factory ExpenseCategory.fromMap(Map<String, Object?> map) => ExpenseCategory(
        id: map['id'] as int,
        name: map['name'] as String,
      );

  final int id;
  final String name;
}

/// A row of `transactions` joined to its category name.
/// (Named `ExpenseTxn` because sqflite already exports a `Transaction` type.)
class ExpenseTxn {
  const ExpenseTxn({
    required this.id,
    required this.amount,
    required this.paymentType,
    required this.merchant,
    required this.date,
    required this.categoryId,
    required this.categoryName,
  });

  factory ExpenseTxn.fromMap(Map<String, Object?> map) => ExpenseTxn(
        id: map['id'] as int,
        amount: (map['amount'] as num).toDouble(),
        paymentType: (map['payment_type'] as String?) ?? 'Unknown',
        merchant: map['merchant'] as String,
        date: DateTime.fromMillisecondsSinceEpoch(map['date'] as int),
        categoryId: map['category_id'] as int,
        categoryName: map['category_name'] as String,
      );

  final int id;
  final double amount;
  final String paymentType;
  final String merchant;
  final DateTime date;
  final int categoryId;
  final String categoryName;

  bool get isUncategorized => categoryName == AppDatabase.uncategorized;
}

class AppDatabase {
  AppDatabase._();

  static final AppDatabase instance = AppDatabase._();

  static const String uncategorized = 'Uncategorized';
  static const List<String> _defaultCategories = <String>[
    uncategorized, // inserted first so it always lands on id = 1
    'Grocery',
    'Food',
    'Fuel',
    'Shopping',
    'Bills & Utilities',
    'Travel',
    'Entertainment',
    'Health',
  ];

  // Assigned synchronously on first access, so concurrent callers await the
  // same open() future instead of racing to open the file twice.
  Future<Database>? _opening;
  int? _uncategorizedId;

  Future<Database> get database => _opening ??= _open();

  Future<Database> _open() async {
    final path = p.join(await getDatabasesPath(), 'expense_manager.db');
    return openDatabase(
      path,
      version: 1,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: _onCreate,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE categories (
        id   INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL UNIQUE COLLATE NOCASE
      )
    ''');

    // COLLATE NOCASE on the merchant key means "Swiggy" and "SWIGGY" resolve
    // to the same mapping without having to uppercase what we display.
    await db.execute('''
      CREATE TABLE merchant_mappings (
        merchant_name TEXT PRIMARY KEY COLLATE NOCASE,
        category_id   INTEGER NOT NULL,
        FOREIGN KEY (category_id) REFERENCES categories (id) ON DELETE CASCADE
      )
    ''');

    await db.execute('''
      CREATE TABLE transactions (
        id           INTEGER PRIMARY KEY AUTOINCREMENT,
        amount       REAL NOT NULL,
        payment_type TEXT,
        merchant     TEXT NOT NULL COLLATE NOCASE,
        date         INTEGER NOT NULL,
        category_id  INTEGER NOT NULL,
        FOREIGN KEY (category_id) REFERENCES categories (id)
      )
    ''');

    // Same charge, same merchant, same second = the same SMS. Lets an inbox
    // re-scan run repeatedly without piling up duplicates.
    await db.execute('''
      CREATE UNIQUE INDEX idx_transactions_natural_key
        ON transactions (amount, merchant, date)
    ''');

    final batch = db.batch();
    for (final name in _defaultCategories) {
      batch.insert('categories', <String, Object?>{'name': name});
    }
    await batch.commit(noResult: true);
  }

  Future<int> uncategorizedId() async {
    if (_uncategorizedId != null) return _uncategorizedId!;
    final db = await database;
    final rows = await db.query(
      'categories',
      columns: <String>['id'],
      where: 'name = ?',
      whereArgs: <Object?>[uncategorized],
      limit: 1,
    );
    return _uncategorizedId = rows.first['id'] as int;
  }

  Future<List<ExpenseCategory>> categories() async {
    final db = await database;
    // Uncategorized pinned to the top of the picker, rest alphabetical.
    final rows = await db.query(
      'categories',
      orderBy: "CASE WHEN name = '$uncategorized' THEN 0 ELSE 1 END, name ASC",
    );
    return rows.map(ExpenseCategory.fromMap).toList();
  }

  Future<ExpenseCategory> addCategory(String name) async {
    final db = await database;
    final clean = name.trim();
    final id = await db.insert(
      'categories',
      <String, Object?>{'name': clean},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    if (id != 0) return ExpenseCategory(id: id, name: clean);

    // Name already exists (UNIQUE NOCASE) — reuse the existing row.
    final rows = await db.query(
      'categories',
      where: 'name = ?',
      whereArgs: <Object?>[clean],
      limit: 1,
    );
    return ExpenseCategory.fromMap(rows.first);
  }

  Future<List<ExpenseTxn>> transactions() async {
    final db = await database;
    final rows = await db.rawQuery('''
      SELECT t.id, t.amount, t.payment_type, t.merchant, t.date, t.category_id,
             c.name AS category_name
      FROM transactions t
      JOIN categories c ON c.id = t.category_id
      ORDER BY t.date DESC, t.id DESC
    ''');
    return rows.map(ExpenseTxn.fromMap).toList();
  }

  // -------------------------------------------------------------------------
  // 3. AUTO-CATEGORIZE
  // -------------------------------------------------------------------------

  /// Looks the merchant up in `merchant_mappings`; falls back to
  /// 'Uncategorized' when this merchant has never been classified.
  /// Returns the new row id, or 0 when the SMS was a duplicate.
  Future<int> insertParsed(ParsedSms sms) async {
    final db = await database;

    final mapping = await db.query(
      'merchant_mappings',
      columns: <String>['category_id'],
      where: 'merchant_name = ?',
      whereArgs: <Object?>[sms.merchant],
      limit: 1,
    );

    final categoryId = mapping.isNotEmpty
        ? mapping.first['category_id'] as int
        : await uncategorizedId();

    return db.insert(
      'transactions',
      <String, Object?>{
        'amount': sms.amount,
        'payment_type': sms.paymentType,
        'merchant': sms.merchant,
        'date': sms.date.millisecondsSinceEpoch,
        'category_id': categoryId,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  // -------------------------------------------------------------------------
  // 5. LEARN THE MAPPING + BACKFILL
  // -------------------------------------------------------------------------

  /// Remembers `merchant -> categoryId` and retroactively re-tags every
  /// existing transaction from that merchant. Returns the number of rows
  /// updated. Both writes share one SQL transaction so the mapping can never
  /// be saved without the backfill.
  Future<int> assignCategory({
    required String merchant,
    required int categoryId,
  }) async {
    final db = await database;
    return db.transaction<int>((txn) async {
      await txn.insert(
        'merchant_mappings',
        <String, Object?>{
          'merchant_name': merchant,
          'category_id': categoryId,
        },
        conflictAlgorithm: ConflictAlgorithm.replace,
      );

      return txn.update(
        'transactions',
        <String, Object?>{'category_id': categoryId},
        where: 'merchant = ?',
        whereArgs: <Object?>[merchant],
      );
    });
  }
}

// ---------------------------------------------------------------------------
// SMS SOURCE (Android only; degrades quietly everywhere else)
// ---------------------------------------------------------------------------

class SmsSource {
  final Telephony _telephony = Telephony.instance;

  bool get isSupported => defaultTargetPlatform == TargetPlatform.android;

  Future<bool> requestPermission() async {
    if (!isSupported) return false;
    final status = await Permission.sms.request();
    return status.isGranted;
  }

  /// Live listener for new alerts while the app is in the foreground.
  void listen(void Function(String body) onBody) {
    if (!isSupported) return;
    try {
      _telephony.listenIncomingSms(
        onNewMessage: (SmsMessage message) {
          final body = message.body;
          if (body != null) onBody(body);
        },
        listenInBackground: false,
      );
    } catch (_) {
      // Plugin unavailable (e.g. running on a desktop target) — ignore.
    }
  }

  /// One-off import of everything already sitting in the inbox.
  Future<List<String>> readInbox() async {
    if (!isSupported) return const <String>[];
    try {
      final messages = await _telephony.getInboxSms(
        columns: <SmsColumn>[SmsColumn.ADDRESS, SmsColumn.BODY, SmsColumn.DATE],
      );
      return messages
          .map((SmsMessage m) => m.body)
          .whereType<String>()
          .toList();
    } catch (_) {
      return const <String>[];
    }
  }
}

// ---------------------------------------------------------------------------
// 4. UI
// ---------------------------------------------------------------------------

class TuExpenseTrackerApp extends StatelessWidget {
  const TuExpenseTrackerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TU Expense Tracker',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF00518F)),
      ),
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF00518F),
          brightness: Brightness.dark,
        ),
      ),
      home: const DashboardScreen(),
    );
  }
}

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final AppDatabase _db = AppDatabase.instance;
  final SmsSource _sms = SmsSource();

  final NumberFormat _money =
      NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 2);
  final DateFormat _dateFormat = DateFormat('dd MMM yyyy · h:mm a');

  List<ExpenseTxn> _transactions = <ExpenseTxn>[];
  List<ExpenseCategory> _categories = <ExpenseCategory>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    _startListening();
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
      _loading = false;
    });
  }

  Future<void> _startListening() async {
    if (!_sms.isSupported) return;
    final granted = await _sms.requestPermission();
    if (!granted) return;
    _sms.listen((String body) async {
      final parsed = SmsParser.parse(body);
      if (parsed == null) return; // not a spend alert
      await _db.insertParsed(parsed);
      await _load();
    });
  }

  /// Feeds an arbitrary SMS body through parse -> auto-categorize -> insert.
  Future<void> _ingest(String body) async {
    final parsed = SmsParser.parse(body);
    if (parsed == null) {
      _toast('Could not parse that SMS — the format did not match.');
      return;
    }
    final id = await _db.insertParsed(parsed);
    await _load();
    _toast(id == 0
        ? 'Already recorded: ${parsed.merchant}'
        : 'Added ${_money.format(parsed.amount)} · ${parsed.merchant}');
  }

  Future<void> _scanInbox() async {
    if (!_sms.isSupported) {
      _toast('Inbox scanning is only available on Android.');
      return;
    }
    final granted = await _sms.requestPermission();
    if (!granted) {
      _toast('SMS permission denied.');
      return;
    }

    final bodies = await _sms.readInbox();
    var added = 0;
    var skipped = 0;
    for (final body in bodies) {
      final parsed = SmsParser.parse(body);
      if (parsed == null) continue;
      final id = await _db.insertParsed(parsed);
      id == 0 ? skipped++ : added++;
    }
    await _load();
    _toast('Imported $added new transaction(s), skipped $skipped duplicate(s).');
  }

  /// Step 5: persist the merchant -> category mapping and backfill history.
  Future<void> _pickCategory(ExpenseTxn txn) async {
    final chosen = await showModalBottomSheet<ExpenseCategory>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => CategoryPickerSheet(
        merchant: txn.merchant,
        categories: _categories,
        selectedId: txn.isUncategorized ? null : txn.categoryId,
      ),
    );
    if (chosen == null) return;

    final updated = await _db.assignCategory(
      merchant: txn.merchant,
      categoryId: chosen.id,
    );
    await _load();
    _toast('${txn.merchant} → ${chosen.name} '
        '($updated transaction${updated == 1 ? '' : 's'} updated)');
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
            hintText: 'INR 204.00 spent on YES BANK Card ...',
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

  @override
  Widget build(BuildContext context) {
    final uncategorizedCount =
        _transactions.where((ExpenseTxn t) => t.isUncategorized).length;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Expenses'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Scan SMS inbox',
            onPressed: _scanInbox,
            icon: const Icon(Icons.sms_outlined),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addSmsManually,
        icon: const Icon(Icons.add),
        label: const Text('Add SMS'),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: _transactions.isEmpty
                  ? _EmptyState(onAdd: _addSmsManually)
                  : ListView.builder(
                      padding: const EdgeInsets.fromLTRB(12, 12, 12, 96),
                      itemCount: _transactions.length + 1,
                      itemBuilder: (context, index) {
                        if (index == 0) {
                          return _SummaryHeader(
                            transactions: _transactions,
                            uncategorizedCount: uncategorizedCount,
                            money: _money,
                          );
                        }
                        final txn = _transactions[index - 1];
                        return _TransactionTile(
                          txn: txn,
                          money: _money,
                          dateFormat: _dateFormat,
                          onTap: () => _pickCategory(txn),
                        );
                      },
                    ),
            ),
    );
  }
}

class _SummaryHeader extends StatelessWidget {
  const _SummaryHeader({
    required this.transactions,
    required this.uncategorizedCount,
    required this.money,
  });

  final List<ExpenseTxn> transactions;
  final int uncategorizedCount;
  final NumberFormat money;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = transactions.fold<double>(
        0, (double sum, ExpenseTxn t) => sum + t.amount);

    final byCategory = <String, double>{};
    for (final txn in transactions) {
      byCategory[txn.categoryName] =
          (byCategory[txn.categoryName] ?? 0) + txn.amount;
    }
    final breakdown = byCategory.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text('Total spent', style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            Text(
              money.format(total),
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
                color: theme.colorScheme.primary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '${transactions.length} transaction'
              '${transactions.length == 1 ? '' : 's'}'
              '${uncategorizedCount > 0 ? ' · $uncategorizedCount need a category' : ''}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final entry in breakdown.take(6))
                  Chip(
                    avatar: Icon(categoryIcon(entry.key), size: 18),
                    label: Text('${entry.key} · ${money.format(entry.value)}'),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _TransactionTile extends StatelessWidget {
  const _TransactionTile({
    required this.txn,
    required this.money,
    required this.dateFormat,
    required this.onTap,
  });

  final ExpenseTxn txn;
  final NumberFormat money;
  final DateFormat dateFormat;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final needsCategory = txn.isUncategorized;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: ListTile(
        onTap: onTap,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        leading: CircleAvatar(
          backgroundColor: needsCategory
              ? theme.colorScheme.errorContainer
              : theme.colorScheme.secondaryContainer,
          foregroundColor: needsCategory
              ? theme.colorScheme.onErrorContainer
              : theme.colorScheme.onSecondaryContainer,
          child: Icon(categoryIcon(txn.categoryName)),
        ),
        title: Text(
          txn.merchant,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const SizedBox(height: 2),
            Text(
              '${txn.paymentType} · ${dateFormat.format(txn.date)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(20),
                    color: needsCategory
                        ? theme.colorScheme.errorContainer
                        : theme.colorScheme.surfaceContainerHighest,
                  ),
                  child: Text(
                    needsCategory ? 'Tap to categorize' : txn.categoryName,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: needsCategory
                          ? theme.colorScheme.onErrorContainer
                          : theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        trailing: Text(
          money.format(txn.amount),
          style: theme.textTheme.titleMedium
              ?.copyWith(fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    return ListView(
      // A scrollable child keeps pull-to-refresh working on an empty list.
      padding: const EdgeInsets.all(32),
      children: <Widget>[
        const SizedBox(height: 120),
        Icon(Icons.receipt_long_outlined,
            size: 72, color: Theme.of(context).colorScheme.outline),
        const SizedBox(height: 16),
        Text(
          'No transactions yet',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        Text(
          'Scan your SMS inbox, or paste a bank alert to test the parser.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 20),
        Center(
          child: FilledButton.tonalIcon(
            onPressed: onAdd,
            icon: const Icon(Icons.add),
            label: const Text('Paste an SMS'),
          ),
        ),
      ],
    );
  }
}

/// Bottom sheet that picks (or creates) the category for a merchant.
class CategoryPickerSheet extends StatefulWidget {
  const CategoryPickerSheet({
    super.key,
    required this.merchant,
    required this.categories,
    this.selectedId,
  });

  final String merchant;
  final List<ExpenseCategory> categories;
  final int? selectedId;

  @override
  State<CategoryPickerSheet> createState() => _CategoryPickerSheetState();
}

class _CategoryPickerSheetState extends State<CategoryPickerSheet> {
  final TextEditingController _newCategory = TextEditingController();
  bool _creating = false;

  @override
  void dispose() {
    _newCategory.dispose();
    super.dispose();
  }

  Future<void> _createAndSelect() async {
    final name = _newCategory.text.trim();
    if (name.isEmpty || _creating) return;
    setState(() => _creating = true);
    final category = await AppDatabase.instance.addCategory(name);
    if (!mounted) return;
    Navigator.pop(context, category);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.only(
        left: 20,
        right: 20,
        bottom: MediaQuery.viewInsetsOf(context).bottom + 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text('Categorize', style: theme.textTheme.titleLarge),
          const SizedBox(height: 4),
          Text(
            widget.merchant,
            style: theme.textTheme.bodyMedium
                ?.copyWith(color: theme.colorScheme.primary),
          ),
          const SizedBox(height: 4),
          Text(
            'Every past and future transaction from this merchant will use '
            'the category you pick.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final category in widget.categories)
                ChoiceChip(
                  avatar: Icon(categoryIcon(category.name), size: 18),
                  label: Text(category.name),
                  selected: category.id == widget.selectedId,
                  onSelected: (_) => Navigator.pop(context, category),
                ),
            ],
          ),
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
    );
  }
}

IconData categoryIcon(String category) {
  switch (category.toLowerCase()) {
    case 'grocery':
      return Icons.local_grocery_store_outlined;
    case 'food':
      return Icons.restaurant_outlined;
    case 'fuel':
      return Icons.local_gas_station_outlined;
    case 'shopping':
      return Icons.shopping_bag_outlined;
    case 'bills & utilities':
      return Icons.receipt_outlined;
    case 'travel':
      return Icons.flight_takeoff_outlined;
    case 'entertainment':
      return Icons.movie_outlined;
    case 'health':
      return Icons.medical_services_outlined;
    case 'uncategorized':
      return Icons.help_outline;
    default:
      return Icons.label_outline;
  }
}
