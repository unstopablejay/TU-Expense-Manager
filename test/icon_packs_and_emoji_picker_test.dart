import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tu_expense_tracker/main.dart';
import 'package:tu_expense_tracker/src/ui_shared/emoji_picker_sheet.dart';

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

  group('Icon Pack Models and Persistence', () {
    test('AppIconPack parsing and properties', () {
      expect(AppIconPack.fromName('emojis'), AppIconPack.emojis);
      expect(AppIconPack.fromName('outlined'), AppIconPack.outlined);
      expect(AppIconPack.fromName('filled'), AppIconPack.filled);
      expect(AppIconPack.fromName('unknown'), AppIconPack.emojis);

      expect(AppIconPack.emojis.label, 'Vibrant Emojis');
      expect(AppIconPack.outlined.label, 'Minimalist Outlined');
      expect(AppIconPack.filled.label, 'Modern Filled');
    });

    test('ThemeController updates and notifies on icon pack change', () async {
      final controller = ThemeController.instance;
      await controller.setIconPack(AppIconPack.emojis);
      expect(controller.appIconPack, AppIconPack.emojis);

      bool notified = false;
      controller.addListener(() {
        notified = true;
      });

      await controller.setIconPack(AppIconPack.outlined);
      expect(controller.appIconPack, AppIconPack.outlined);
      expect(notified, isTrue);

      await controller.setIconPack(AppIconPack.filled);
      expect(controller.appIconPack, AppIconPack.filled);
    });
  });

  group('Category Vector Icons & CategoryAvatar', () {
    test('categoryVectorIcon resolves icons for known categories', () {
      expect(
        categoryVectorIcon('Food & Dining', filled: false),
        Icons.restaurant_outlined,
      );
      expect(
        categoryVectorIcon('Food & Dining', filled: true),
        Icons.restaurant,
      );
      expect(
        categoryVectorIcon('Transportation', filled: false),
        Icons.directions_car_outlined,
      );
      expect(
        categoryVectorIcon('Groceries', filled: true),
        Icons.local_grocery_store,
      );
      expect(
        categoryVectorIcon('Salary', filled: false),
        Icons.account_balance_wallet_outlined,
      );
      expect(
        categoryVectorIcon('Loans', filled: false),
        Icons.account_balance_outlined,
      );
      expect(
        categoryVectorIcon('Loans', filled: true),
        Icons.account_balance,
      );
      expect(
        categoryVectorIcon('Egg', filled: false),
        Icons.egg_outlined,
      );
      expect(
        categoryVectorIcon('Egg', filled: true),
        Icons.egg,
      );
      expect(
        categoryVectorIcon('Non Veg', filled: false),
        Icons.kebab_dining_outlined,
      );
      expect(
        categoryVectorIcon('Non Veg', filled: true),
        Icons.kebab_dining,
      );
      expect(
        categoryVectorIcon('Fish & Seafood', filled: false),
        Icons.set_meal_outlined,
      );
      expect(
        categoryVectorIcon('Fish & Seafood', filled: true),
        Icons.set_meal,
      );
      expect(
        categoryVectorIcon('papa', filled: false),
        Icons.person_outline,
      );
      expect(
        categoryVectorIcon('papa', filled: true),
        Icons.person,
      );
      expect(
        categoryVectorIcon('Savings', filled: false),
        Icons.savings_outlined,
      );
      expect(
        categoryVectorIcon('Savings', filled: true),
        Icons.savings,
      );
      expect(
        categoryVectorIcon('Cosmetics', filled: false),
        Icons.face_outlined,
      );
      expect(
        categoryVectorIcon('Cosmetics', filled: true),
        Icons.face,
      );
      expect(
        categoryVectorIcon('milk', filled: false),
        Icons.local_drink_outlined,
      );
      expect(
        categoryVectorIcon('milk', filled: true),
        Icons.local_drink,
      );
      expect(
        categoryVectorIcon('snacks', filled: false),
        Icons.fastfood_outlined,
      );
      expect(
        categoryVectorIcon('snacks', filled: true),
        Icons.fastfood,
      );
      expect(
        categoryVectorIcon('veggies and fruits', filled: false),
        Icons.eco_outlined,
      );
      expect(
        categoryVectorIcon('veggies and fruits', filled: true),
        Icons.eco,
      );
      expect(
        categoryVectorIcon('Bills and Utilities', filled: false),
        Icons.receipt_long_outlined,
      );
      expect(
        categoryVectorIcon('Bills and Utilities', filled: true),
        Icons.receipt_long,
      );
    });

    testWidgets('CategoryAvatar renders emoji in emojis pack and vector icon in outlined/filled pack',
        (WidgetTester tester) async {
      final controller = ThemeController.instance;
      await controller.setIconPack(AppIconPack.emojis);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: const <Widget>[
                CategoryAvatar(
                  category: 'Food & Dining',
                  size: 44,
                ),
                CategoryAvatar(
                  category: 'Credit',
                  isCredit: true,
                  size: 44,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      // Under emojis pack, should find Text widgets containing emoji
      expect(find.text('🍔'), findsOneWidget);
      expect(find.text('💰'), findsOneWidget);
      expect(find.byType(Icon), findsNothing);

      // Now switch to outlined pack
      await controller.setIconPack(AppIconPack.outlined);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: const <Widget>[
                CategoryAvatar(
                  category: 'Food & Dining',
                  size: 44,
                ),
                CategoryAvatar(
                  category: 'Credit',
                  isCredit: true,
                  size: 44,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      // Under outlined pack, should render vector Icons
      expect(find.byIcon(Icons.restaurant_outlined), findsOneWidget);
      expect(find.byIcon(Icons.account_balance_wallet_outlined), findsOneWidget);

      // Now switch to filled pack
      await controller.setIconPack(AppIconPack.filled);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: const <Widget>[
                CategoryAvatar(
                  category: 'Food & Dining',
                  size: 44,
                ),
                CategoryAvatar(
                  category: 'Credit',
                  isCredit: true,
                  size: 44,
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pump();

      // Under filled pack, should render filled vector Icons
      expect(find.byIcon(Icons.restaurant), findsOneWidget);
      expect(find.byIcon(Icons.account_balance_wallet), findsOneWidget);
    });
  });

  group('Settings Icon Pack Selector', () {
    testWidgets('SettingsScreen allows switching Icon Pack', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      final controller = ThemeController.instance;
      await controller.setIconPack(AppIconPack.emojis);

      await tester.pumpWidget(
        MaterialApp(
          theme: controller.lightTheme,
          home: const Scaffold(
            body: SettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Icon pack'), findsOneWidget);
      expect(find.text('Emojis'), findsOneWidget);
      expect(find.text('Outlined'), findsOneWidget);
      expect(find.text('Filled'), findsOneWidget);

      // Tap Outlined
      await tester.tap(find.text('Outlined'));
      await tester.pumpAndSettle();
      expect(controller.appIconPack, AppIconPack.outlined);

      // Tap Filled
      await tester.tap(find.text('Filled'));
      await tester.pumpAndSettle();
      expect(controller.appIconPack, AppIconPack.filled);
    });
  });

  group('WhatsApp Emoji Catalog and Picker', () {
    test('Catalog contains comprehensive categories and emojis', () {
      expect(kWhatsAppEmojiCategories.length, greaterThanOrEqualTo(8));
      final names = kWhatsAppEmojiCategories.map((c) => c.name).toList();
      expect(names, contains('Smileys & Emotion'));
      expect(names, contains('Food & Drink'));
      expect(names, contains('Travel & Places'));
      expect(names, contains('Objects & Tools'));
      expect(names, contains('Symbols & Finance'));
    });

    testWidgets('showEmojiPickerSheet renders categories and allows selection',
        (WidgetTester tester) async {
      String? selectedEmoji;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  selectedEmoji = await showEmojiPickerSheet(context);
                },
                child: const Text('Open Picker'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Open Picker'));
      await tester.pumpAndSettle();

      expect(find.text('Choose Emoji'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);

      // Enter search query
      await tester.enterText(find.byType(TextField), 'coffee');
      await tester.pumpAndSettle();

      expect(find.text('☕️'), findsWidgets);

      // Tap the coffee emoji
      await tester.tap(find.text('☕️').first);
      await tester.pumpAndSettle();

      // Picker sheet should dismiss and return selected emoji
      expect(selectedEmoji, anyOf('☕️', '☕'));
    });

    testWidgets('showEmojiPickerSheet searches for egg, non veg, and loan emojis',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => showEmojiPickerSheet(context),
                child: const Text('Open Picker'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Open Picker'));
      await tester.pumpAndSettle();

      // Search egg
      await tester.enterText(find.byType(TextField), 'egg');
      await tester.pumpAndSettle();
      expect(find.text('🥚'), findsWidgets);

      // Search non veg / chicken
      await tester.enterText(find.byType(TextField), 'chicken');
      await tester.pumpAndSettle();
      expect(find.text('🍗'), findsWidgets);

      // Search loan / bank
      await tester.enterText(find.byType(TextField), 'loan');
      await tester.pumpAndSettle();
      expect(find.text('🏦'), findsWidgets);
    });
  });
}
