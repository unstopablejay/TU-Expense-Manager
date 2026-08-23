import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:tu_expense_tracker/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Category Emoji Resolver & Smart Matcher', () {
    test('standard seeded categories map to default emojis', () {
      expect(categoryEmoji('Grocery'), '🛒');
      expect(categoryEmoji('Food'), '🍔');
      expect(categoryEmoji('Fuel'), '⛽');
      expect(categoryEmoji('Shopping'), '🛍️');
      expect(categoryEmoji('Bills & Utilities'), '💡');
      expect(categoryEmoji('Travel'), '✈️');
      expect(categoryEmoji('Entertainment'), '🎬');
      expect(categoryEmoji('Health'), '💊');
      expect(categoryEmoji('Uncategorized'), '❓');
      expect(categoryEmoji('Income'), '💰');
    });

    test('explicit icon takes precedence over default and keyword matching', () {
      expect(categoryEmoji('Food', explicitIcon: '🍕'), '🍕');
      expect(categoryEmoji('Custom Random', explicitIcon: '🏖️'), '🏖️');
    });

    test('smart keyword auto-matching maps common category concepts', () {
      expect(suggestCategoryEmoji('Coffee & Snacks'), '☕');
      expect(suggestCategoryEmoji('House Rent'), '🏠');
      expect(suggestCategoryEmoji('Gym Membership'), '🏋️');
      expect(suggestCategoryEmoji('Uber & Ola Cabs'), '🚕');
      expect(suggestCategoryEmoji('Dog & Cat Vet'), '🐾');
      expect(suggestCategoryEmoji('Steam Games'), '🎮');
      expect(suggestCategoryEmoji('Netflix Subscription'), '📺');
      expect(suggestCategoryEmoji('College Books'), '📚');
      expect(suggestCategoryEmoji('Hair Salon'), '✂️');
      expect(suggestCategoryEmoji('Mobile Recharge'), '📱');
      expect(suggestCategoryEmoji('Mutual Funds & Stocks'), '📈');
      expect(suggestCategoryEmoji('Life Insurance'), '🛡️');
      expect(suggestCategoryEmoji('Beer & Wine Bar'), '🍻');
      expect(suggestCategoryEmoji('Unknown Random Name'), '🏷️');
    });

    test('curated emoji list contains popular emojis', () {
      expect(kCuratedCategoryEmojis, contains('🛒'));
      expect(kCuratedCategoryEmojis, contains('🍔'));
      expect(kCuratedCategoryEmojis, contains('☕'));
      expect(kCuratedCategoryEmojis, contains('🏠'));
      expect(kCuratedCategoryEmojis.length, greaterThanOrEqualTo(30));
    });
  });

  group('ExpenseCategory Model with Icon', () {
    test('fromMap and toMap preserve icon', () {
      const cat = ExpenseCategory(id: 42, name: 'Coffee', icon: '☕');
      final map = cat.toMap();
      expect(map['id'], 42);
      expect(map['name'], 'Coffee');
      expect(map['icon'], '☕');

      final from = ExpenseCategory.fromMap(map);
      expect(from.id, 42);
      expect(from.name, 'Coffee');
      expect(from.icon, '☕');
    });

    test('fromMap handles missing or null icon gracefully', () {
      final from = ExpenseCategory.fromMap(const <String, Object?>{
        'id': 10,
        'name': 'Shopping',
      });
      expect(from.icon, '');
    });
  });

  group('TransactionsTab & Card Rendering', () {
    testWidgets('TransactionsTab renders modern fintech card with category squircle emoji badge',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      addTearDown(tester.view.resetPhysicalSize);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetDevicePixelRatio);

      final txn = ExpenseTxn(
        id: 1,
        amount: 450.0,
        merchant: 'Swiggy',
        date: DateTime(2026, 8, 23, 12, 30),
        categoryName: 'Food',
        categoryId: 3,
        paymentType: 'HDFC Card',
        direction: TxnDirection.debit,
        reference: 'UPI/12345',
        note: 'Lunch order',
      );

      final entry = LedgerEntry(
        txn: txn,
        lines: txn.effectiveSplits,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          home: Scaffold(
            body: TransactionsTab(
              entries: <LedgerEntry>[entry],
              filters: const LedgerFilters(),
              sort: LedgerSort.newest,
              monthChoices: const <YearMonth>[],
              currentMonth: YearMonth(2026, 8),
              categoryChoices: const <ExpenseCategory>[
                ExpenseCategory(id: 3, name: 'Food', icon: '🍔'),
              ],
              merchantChoices: const <String>['Swiggy'],
              paymentTypeChoices: const <String>['HDFC Card'],
              money: NumberFormat.currency(symbol: '₹', decimalDigits: 2),
              dateFormat: DateFormat('d MMM yyyy'),
              loading: false,
              ledgerIsEmpty: false,
              selected: const <int>{},
              onFiltersChanged: (_) {},
              onSortChanged: (_) {},
              onRefresh: () async {},
              onTap: (_) {},
              onToggleSelected: (_) {},
              onDelete: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify merchant name and amount
      expect(find.text('Swiggy'), findsOneWidget);
      expect(find.textContaining('450.00'), findsWidgets);
      expect(find.text('Lunch order'), findsOneWidget);

      // Verify vibrant squircle emoji
      expect(find.text('🍔'), findsWidgets);

      // Verify Card has rounded corners
      final Card card = tester
          .widgetList<Card>(find.byType(Card))
          .firstWhere((Card c) => c.shape != null);
      final RoundedRectangleBorder shape =
          card.shape! as RoundedRectangleBorder;
      expect(shape.borderRadius, BorderRadius.circular(16));
    });

    testWidgets('TransactionsTab renders credit transaction with credit badge',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      addTearDown(tester.view.resetPhysicalSize);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetDevicePixelRatio);

      final txn = ExpenseTxn(
        id: 2,
        amount: 2500.0,
        merchant: 'Salary Credit',
        date: DateTime(2026, 8, 23, 10, 0),
        categoryName: 'Income',
        categoryId: 10,
        paymentType: 'Salary A/C',
        direction: TxnDirection.credit,
        reference: 'UTR/998877',
        note: 'Monthly salary',
      );

      final entry = LedgerEntry(
        txn: txn,
        lines: txn.effectiveSplits,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.light(),
          home: Scaffold(
            body: TransactionsTab(
              entries: <LedgerEntry>[entry],
              filters: const LedgerFilters(),
              sort: LedgerSort.newest,
              monthChoices: const <YearMonth>[],
              currentMonth: YearMonth(2026, 8),
              categoryChoices: const <ExpenseCategory>[
                ExpenseCategory(id: 10, name: 'Income', icon: '💰'),
              ],
              merchantChoices: const <String>['Salary Credit'],
              paymentTypeChoices: const <String>['Salary A/C'],
              money: NumberFormat.currency(symbol: '₹', decimalDigits: 2),
              dateFormat: DateFormat('d MMM yyyy'),
              loading: false,
              ledgerIsEmpty: false,
              selected: const <int>{},
              onFiltersChanged: (_) {},
              onSortChanged: (_) {},
              onRefresh: () async {},
              onTap: (_) {},
              onToggleSelected: (_) {},
              onDelete: (_) {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Salary Credit'), findsOneWidget);
      expect(find.textContaining('2,500.00'), findsWidgets);
      expect(find.text('💰'), findsOneWidget);
    });
  });
}
