import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tu_expense_tracker/main.dart';

class FakeDatabase implements AppDatabase {
  final List<ExpenseTxn> _txns = <ExpenseTxn>[];
  final List<ExpenseCategory> _cats = <ExpenseCategory>[
    const ExpenseCategory(id: 1, name: 'Uncategorized'),
    const ExpenseCategory(id: 2, name: 'Food'),
    const ExpenseCategory(id: 3, name: 'Grocery'),
    const ExpenseCategory(id: 4, name: 'Bills & Utilities'),
  ];
  final Map<String, int> _merchantMappings = <String, int>{};
  final Set<String> _tombstones = <String>{};
  DateTime? _watermark;
  int _nextId = 1;

  @override
  Future<List<ExpenseTxn>> transactions() async => List<ExpenseTxn>.from(_txns);

  @override
  Future<List<ExpenseCategory>> categories() async => List<ExpenseCategory>.from(_cats);

  @override
  Future<int> uncategorizedId() async => 1;

  @override
  Future<DateTime?> lastScannedSmsDate() async => _watermark;

  @override
  Future<void> setLastScannedSmsDate(DateTime date) async {
    _watermark = date;
  }

  @override
  Future<int> insertParsed(ParsedSms sms) async {
    final key = '${sms.amount}_${sms.merchant}_${sms.date.millisecondsSinceEpoch}_${sms.direction.name}_${sms.reference}';
    if (_tombstones.contains(key)) return 0;
    for (final t in _txns) {
      final existingKey = '${t.amount}_${t.merchant}_${t.date.millisecondsSinceEpoch}_${t.direction.name}_${t.reference}';
      if (existingKey == key) return 0;
    }

    final catId = _merchantMappings[sms.merchant.toLowerCase()] ?? 1;
    final catName = _cats.firstWhere((c) => c.id == catId).name;

    final id = _nextId++;
    _txns.insert(
      0,
      ExpenseTxn(
        id: id,
        amount: sms.amount,
        paymentType: sms.paymentType,
        merchant: sms.merchant,
        date: sms.date,
        categoryId: catId,
        categoryName: catName,
        direction: sms.direction,
        reference: sms.reference,
        note: '',
      ),
    );
    return id;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeSmsSource extends SmsSource {
  FakeSmsSource({
    this.supported = true,
    this.permissionGranted = true,
    List<InboxSms>? initialInbox,
  }) : inbox = initialInbox ?? <InboxSms>[];

  final bool supported;
  bool permissionGranted;
  final List<InboxSms> inbox;
  bool listenCalled = false;
  int readInboxCalls = 0;

  @override
  bool get isSupported => supported;

  @override
  Future<bool> requestPermission() async => isSupported && permissionGranted;

  @override
  void listen(void Function(InboxSms sms) onMessage) {
    listenCalled = true;
    super.listen(onMessage);
  }

  @override
  Future<List<InboxSms>> readInbox({DateTime? since}) async {
    readInboxCalls++;
    if (!isSupported || !permissionGranted) return const <InboxSms>[];
    if (since == null) return List<InboxSms>.from(inbox);
    return inbox.where((InboxSms m) {
      final at = m.receivedAt;
      return at != null && at.isAfter(since);
    }).toList();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SmsSource', () {
    test('simulateIncomingSms invokes the listener callback', () {
      final source = SmsSource();
      InboxSms? received;
      source.listen((InboxSms sms) {
        received = sms;
      });

      final testSms = InboxSms('Test body', DateTime(2026, 8, 21, 10, 0));
      source.simulateIncomingSms(testSms);

      expect(received, isNotNull);
      expect(received!.body, 'Test body');
      expect(received!.receivedAt, DateTime(2026, 8, 21, 10, 0));
    });
  });

  group('Real-Time Foreground SMS in HomeShell', () {
    void setLargeViewport(WidgetTester tester) {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());
    }

    testWidgets('incoming SMS parses and immediately updates UI with toast',
        (WidgetTester tester) async {
      setLargeViewport(tester);

      final db = FakeDatabase();
      final smsSource = FakeSmsSource();

      await tester.pumpWidget(TuExpenseTrackerApp(
        database: db,
        smsSource: smsSource,
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(smsSource.listenCalled, isTrue);

      // Switch to Transactions tab (Tab 2)
      await tester.tap(find.byIcon(Icons.receipt_long_outlined));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('STARBUCKS'), findsNothing);

      // Simulate real-time incoming SMS in foreground
      const smsBody =
          'Sent Rs.250.00 from HDFC Bank A/C **1234 to STARBUCKS on 21-08-26. UPI Ref 9876543210.';
      final arrivalTime = DateTime(2026, 8, 21, 10, 0);
      smsSource.simulateIncomingSms(InboxSms(smsBody, arrivalTime));

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Verify transaction appeared on screen
      expect(find.text('STARBUCKS'), findsOneWidget);
      expect(find.text('₹250.00'), findsWidgets);

      // Verify toast message was shown
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.textContaining('STARBUCKS'), findsWidgets);

      // Verify watermark was updated
      expect(await db.lastScannedSmsDate(), isNotNull);
    });

    testWidgets('non-transaction incoming SMS is ignored and does not change state',
        (WidgetTester tester) async {
      setLargeViewport(tester);

      final db = FakeDatabase();
      final smsSource = FakeSmsSource();

      await tester.pumpWidget(TuExpenseTrackerApp(
        database: db,
        smsSource: smsSource,
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Switch to Transactions tab
      await tester.tap(find.byIcon(Icons.receipt_long_outlined));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Simulate incoming OTP SMS
      smsSource.simulateIncomingSms(
        InboxSms('123456 is your OTP. Do not share it with anyone.', DateTime(2026, 8, 21, 10, 0)),
      );

      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.byType(SnackBar), findsNothing);
      final txns = await db.transactions();
      expect(txns, isEmpty);
    });

    testWidgets('duplicate incoming SMS is ignored safely',
        (WidgetTester tester) async {
      setLargeViewport(tester);

      final db = FakeDatabase();
      final smsSource = FakeSmsSource();

      await tester.pumpWidget(TuExpenseTrackerApp(
        database: db,
        smsSource: smsSource,
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Switch to Transactions tab
      await tester.tap(find.byIcon(Icons.receipt_long_outlined));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      const smsBody =
          'Spent Rs.122.02 On HDFC Bank Card 6824 At SWIGGY On 2026-08-21:07:19:26.';
      final arrivalTime = DateTime(2026, 8, 21, 7, 19, 26);

      // First delivery
      smsSource.simulateIncomingSms(InboxSms(smsBody, arrivalTime));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('SWIGGY'), findsOneWidget);
      expect((await db.transactions()).length, 1);

      // Second duplicate delivery
      smsSource.simulateIncomingSms(InboxSms(smsBody, arrivalTime));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect((await db.transactions()).length, 1);
    });

    testWidgets('app resume triggers catch-up scan and ensures listener is active',
        (WidgetTester tester) async {
      setLargeViewport(tester);

      final db = FakeDatabase();
      final smsSource = FakeSmsSource();

      await tester.pumpWidget(TuExpenseTrackerApp(
        database: db,
        smsSource: smsSource,
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final initialScanCount = smsSource.readInboxCalls;

      // Add a message into device inbox while app was paused/away
      final resumeMsgTime = DateTime(2026, 8, 21, 11, 0);
      smsSource.inbox.add(InboxSms(
        'INR 160.00 spent using ICICI Bank Card XX8008 on 21-Aug-26 on AMAZON. Avl Limit: INR 3,99,614.00.',
        resumeMsgTime,
      ));

      // Simulate App Lifecycle resume
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(smsSource.readInboxCalls, greaterThan(initialScanCount));

      // Switch to Transactions tab to verify AMAZON appeared
      await tester.tap(find.byIcon(Icons.receipt_long_outlined));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('AMAZON'), findsOneWidget);
    });
  });
}
