import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tu_expense_tracker/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PackageInfo.setMockInitialValues(
    appName: 'TU Expense Tracker',
    packageName: 'com.tu.expense.manager',
    version: '1.0.0',
    buildNumber: '1',
    buildSignature: '',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('Custom Category Icons in Core Models', () {
    test('ExpenseTxn.fromMap parses category_icon', () {
      final txn = ExpenseTxn.fromMap(<String, Object?>{
        'id': 1,
        'amount': 250.0,
        'payment_type': 'UPI',
        'merchant': 'Swiggy',
        'date': 1700000000000,
        'category_id': 2,
        'category_name': 'Food & Dining',
        'category_icon': '🍜',
        'direction': 'debit',
        'reference': 'REF123',
        'note': '',
      });

      expect(txn.categoryName, 'Food & Dining');
      expect(txn.categoryIcon, '🍜');
    });

    test('TxnSplit.fromMap parses category_icon and serializes to JSON', () {
      final split = TxnSplit.fromMap(<String, Object?>{
        'category_id': 3,
        'category_name': 'Groceries',
        'category_icon': '🥑',
        'amount': 150.0,
      });

      expect(split.categoryName, 'Groceries');
      expect(split.categoryIcon, '🥑');
      expect(split.toJson()['icon'], '🥑');
    });

    test('SnapshotStore preserves category icons in transactions and splits', () {
      final backup = BackupData(
        meta: <String, String>{'exported_at': '2026-08-23T10:00:00Z'},
        categories: <Map<String, Object?>>[
          <String, Object?>{'id': 1, 'name': 'Groceries', 'icon': '🥑'},
          <String, Object?>{'id': 2, 'name': 'Coffee', 'icon': '☕️'},
        ],
        transactions: <Map<String, Object?>>[
          <String, Object?>{
            'id': 101,
            'amount': 500.0,
            'payment_type': 'UPI',
            'merchant': 'Nature Basket',
            'date': 1700000000000,
            'category_id': 1,
            'direction': 'debit',
            'reference': 'REF01',
          },
        ],
        splits: <Map<String, Object?>>[
          <String, Object?>{
            'transaction_id': 101,
            'category_id': 2,
            'amount': 200.0,
            'position': 0,
          },
        ],
        aliases: const <Map<String, Object?>>[],
        merchantMappings: const <Map<String, Object?>>[],
        deleted: const <Map<String, Object?>>[],
        appMeta: const <Map<String, Object?>>[],
      );

      final store = SnapshotStore.fromBackup(backup);
      expect(store.transactions.length, 1);
      final txn = store.transactions.first;
      expect(txn.categoryName, 'Groceries');
      expect(txn.categoryIcon, '🥑');

      expect(txn.splits.length, 1);
      expect(txn.splits.first.categoryName, 'Coffee');
      expect(txn.splits.first.categoryIcon, '☕️');
    });

    test('CategoryAvatar upgrades legacy tag icon in transactions for Loans, Egg, Non Veg', () {
      final backup = BackupData(
        meta: <String, String>{'exported_at': '2026-08-23T10:00:00Z'},
        categories: <Map<String, Object?>>[
          <String, Object?>{'id': 10, 'name': 'Loans', 'icon': '🏷️'},
          <String, Object?>{'id': 11, 'name': 'Egg', 'icon': ''},
          <String, Object?>{'id': 12, 'name': 'Non Veg', 'icon': '🏷️'},
        ],
        transactions: <Map<String, Object?>>[
          <String, Object?>{
            'id': 201,
            'amount': 15000.0,
            'payment_type': 'NetBanking',
            'merchant': 'HDFC Home Loan',
            'date': 1700000000000,
            'category_id': 10,
            'direction': 'debit',
            'reference': 'REF_LOAN',
          },
          <String, Object?>{
            'id': 202,
            'amount': 120.0,
            'payment_type': 'UPI',
            'merchant': 'Egg Store',
            'date': 1700000000000,
            'category_id': 11,
            'direction': 'debit',
            'reference': 'REF_EGG',
          },
          <String, Object?>{
            'id': 203,
            'amount': 850.0,
            'payment_type': 'UPI',
            'merchant': 'Bawarchi Biryani',
            'date': 1700000000000,
            'category_id': 12,
            'direction': 'debit',
            'reference': 'REF_NONVEG',
          },
        ],
        splits: const <Map<String, Object?>>[],
        aliases: const <Map<String, Object?>>[],
        merchantMappings: const <Map<String, Object?>>[],
        deleted: const <Map<String, Object?>>[],
        appMeta: const <Map<String, Object?>>[],
      );

      final store = SnapshotStore.fromBackup(backup);
      expect(store.transactions.length, 3);

      final loanTxn = store.transactions.firstWhere((t) => t.id == 201);
      expect(loanTxn.categoryName, 'Loans');
      expect(categoryEmoji(loanTxn.categoryName, explicitIcon: loanTxn.categoryIcon), '🏦');

      final eggTxn = store.transactions.firstWhere((t) => t.id == 202);
      expect(eggTxn.categoryName, 'Egg');
      expect(categoryEmoji(eggTxn.categoryName, explicitIcon: eggTxn.categoryIcon), '🥚');

      final nonVegTxn = store.transactions.firstWhere((t) => t.id == 203);
      expect(nonVegTxn.categoryName, 'Non Veg');
      expect(categoryEmoji(nonVegTxn.categoryName, explicitIcon: nonVegTxn.categoryIcon), '🍗');
    });

    test('ExpenseTxn.effectiveSplits retains categoryIcon for unsplit transactions', () {
      final txn = ExpenseTxn(
        id: 100,
        amount: 50.0,
        paymentType: 'UPI',
        merchant: 'Milk Dairy',
        date: DateTime(2026, 8, 27),
        categoryId: 5,
        categoryName: 'milk',
        categoryIcon: '🥛',
        direction: TxnDirection.debit,
        reference: 'REF_1',
      );

      expect(txn.effectiveSplits.length, 1);
      expect(txn.effectiveSplits.first.categoryName, 'milk');
      expect(txn.effectiveSplits.first.categoryIcon, '🥛');
    });

    test('SnapshotStore preserves mobile user custom category icons across all categories', () {
      final backup = BackupData(
        meta: <String, String>{'exported_at': '2026-08-27T10:00:00Z'},
        categories: <Map<String, Object?>>[
          <String, Object?>{'id': 1, 'name': 'papa', 'icon': '👨'},
          <String, Object?>{'id': 2, 'name': 'Savings', 'icon': '💰'},
          <String, Object?>{'id': 3, 'name': 'Cosmetics', 'icon': '💄'},
          <String, Object?>{'id': 4, 'name': 'milk', 'icon': '🥛'},
          <String, Object?>{'id': 5, 'name': 'snacks', 'icon': '🍿'},
          <String, Object?>{'id': 6, 'name': 'veegies and fruits', 'icon': '🥗'},
        ],
        transactions: <Map<String, Object?>>[
          <String, Object?>{
            'id': 1,
            'amount': 500.0,
            'payment_type': 'UPI',
            'merchant': 'Papa Transfer',
            'date': 1700000000000,
            'category_id': 1,
            'direction': 'debit',
            'reference': 'REF_1',
          },
          <String, Object?>{
            'id': 2,
            'amount': 2000.0,
            'payment_type': 'UPI',
            'merchant': 'Savings Deposit',
            'date': 1700000000000,
            'category_id': 2,
            'direction': 'debit',
            'reference': 'REF_2',
          },
        ],
        splits: const <Map<String, Object?>>[],
        aliases: const <Map<String, Object?>>[],
        merchantMappings: const <Map<String, Object?>>[],
        deleted: const <Map<String, Object?>>[],
        appMeta: const <Map<String, Object?>>[],
      );

      final store = SnapshotStore.fromBackup(backup);
      final t1 = store.transactions.firstWhere((t) => t.id == 1);
      expect(t1.categoryName, 'papa');
      expect(t1.categoryIcon, '👨');
      expect(t1.effectiveSplits.first.categoryIcon, '👨');

      final t2 = store.transactions.firstWhere((t) => t.id == 2);
      expect(t2.categoryName, 'Savings');
      expect(t2.categoryIcon, '💰');
      expect(t2.effectiveSplits.first.categoryIcon, '💰');
    });
  });

  group('CategoryAvatar & Transaction Tiles with Custom Icons', () {
    testWidgets('CategoryAvatar renders custom explicit emoji in emojis pack',
        (WidgetTester tester) async {
      final controller = ThemeController.instance;
      await controller.setIconPack(AppIconPack.emojis);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: const <Widget>[
                // Custom avocado emoji for Groceries
                CategoryAvatar(
                  category: 'Groceries',
                  explicitIcon: '🥑',
                  size: 44,
                ),
                // Custom ramen emoji for Food & Dining
                CategoryAvatar(
                  category: 'Food & Dining',
                  explicitIcon: '🍜',
                  size: 44,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('🥑'), findsOneWidget);
      expect(find.text('🍜'), findsOneWidget);
    });

    testWidgets('CategoryAvatar renders vector icons in outlined & filled packs even with explicit emoji',
        (WidgetTester tester) async {
      final controller = ThemeController.instance;
      await controller.setIconPack(AppIconPack.outlined);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: const <Widget>[
                CategoryAvatar(
                  category: 'Groceries',
                  explicitIcon: '🥑',
                  size: 44,
                ),
                CategoryAvatar(
                  category: 'Food & Dining',
                  explicitIcon: '🍜',
                  size: 44,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      // In outlined mode, vector icons are rendered
      expect(find.byIcon(Icons.local_grocery_store_outlined), findsOneWidget);
      expect(find.byIcon(Icons.restaurant_outlined), findsOneWidget);

      // In filled mode, filled vector icons are rendered
      await controller.setIconPack(AppIconPack.filled);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: const <Widget>[
                CategoryAvatar(
                  category: 'Groceries',
                  explicitIcon: '🥑',
                  size: 44,
                ),
                CategoryAvatar(
                  category: 'Food & Dining',
                  explicitIcon: '🍜',
                  size: 44,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      expect(find.byIcon(Icons.local_grocery_store), findsOneWidget);
      expect(find.byIcon(Icons.restaurant), findsOneWidget);
    });
  });
}
