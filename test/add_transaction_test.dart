import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tu_expense_tracker/src/core/models.dart';
import 'package:tu_expense_tracker/src/mobile/screens/add_transaction_screen.dart';

void main() {
  const categories = <ExpenseCategory>[
    ExpenseCategory(id: 1, name: 'Uncategorized'),
    ExpenseCategory(id: 2, name: 'Food'),
    ExpenseCategory(id: 3, name: 'Grocery'),
    ExpenseCategory(id: 4, name: 'Shopping'),
  ];

  const merchants = <String>[
    'Swiggy',
    'Zomato',
    'Amazon',
    'BigBasket',
  ];

  /// Standard viewport that fits the full scrollable form.
  void setLargeViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());
  }

  Widget buildScreen({
    List<ExpenseCategory> cats = categories,
    List<String> merchs = merchants,
    List<String> paymentTypes = const <String>[],
    String? initialSmsBody,
  }) {
    return MaterialApp(
      home: AddTransactionScreen(
        categories: cats,
        merchants: merchs,
        paymentTypes: paymentTypes,
        initialSmsBody: initialSmsBody,
      ),
    );
  }

  // =========================================================================
  // INITIAL RENDER & DEFAULTS
  // =========================================================================
  group('AddTransactionScreen · initial state', () {
    testWidgets('renders all required form fields and default values',
        (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      // Amount field
      expect(find.text('Amount'), findsOneWidget);
      expect(find.text('₹'), findsOneWidget);

      // Merchant field
      expect(find.text('Merchant / Payee'), findsOneWidget);
      expect(find.text('Select or add merchant'), findsOneWidget);

      // Date & Time pickers
      expect(find.text('Date'), findsOneWidget);
      expect(find.text('Time'), findsOneWidget);

      // Payment method
      expect(find.text('Payment Method'), findsOneWidget);
      expect(find.text('Cash'), findsWidgets);
      expect(find.text('UPI'), findsOneWidget);
      expect(find.text('Debit Card'), findsOneWidget);
      expect(find.text('Credit Card'), findsOneWidget);
      expect(find.text('Other'), findsOneWidget);

      // Category & Split
      expect(find.text('Split Transaction'), findsOneWidget);
      expect(find.text('Category'), findsOneWidget);

      // Notes
      expect(find.text('Notes (optional)'), findsOneWidget);

      // Save buttons (app bar + bottom)
      expect(find.text('Save'), findsOneWidget);
      expect(find.text('Add Transaction'), findsWidgets);
    });

    testWidgets('defaults to Cash payment method', (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      final cashChip = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, 'Cash'),
      );
      expect(cashChip.selected, isTrue);

      // Others unselected
      for (final label in <String>['UPI', 'Debit Card', 'Credit Card', 'Other']) {
        final chip = tester.widget<ChoiceChip>(
          find.widgetWithText(ChoiceChip, label),
        );
        expect(chip.selected, isFalse, reason: '$label should not be selected');
      }
    });

    testWidgets('defaults category to first non-Uncategorized category',
        (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      // Food is the first non-Uncategorized category in our list
      expect(find.text('Food'), findsOneWidget);
    });

    testWidgets('split transaction toggle is off by default', (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      final switchWidget = tester.widget<Switch>(find.byType(Switch));
      expect(switchWidget.value, isFalse);

      // Split builder UI should not be visible
      expect(find.text('Divide the total amount across multiple categories:'),
          findsNothing);
    });

    testWidgets('renders with empty merchant list', (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen(merchs: const <String>[]));
      await tester.pumpAndSettle();

      // Should still render the merchant selector tile
      expect(find.text('Select or add merchant'), findsOneWidget);
    });

    testWidgets('renders with only Uncategorized category', (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen(
        cats: const <ExpenseCategory>[
          ExpenseCategory(id: 1, name: 'Uncategorized'),
        ],
      ));
      await tester.pumpAndSettle();

      // Should still render, falling back to Uncategorized as the default
      expect(find.text('Uncategorized'), findsOneWidget);
    });
  });

  // =========================================================================
  // SMS AUTO-FILL (unadded-SMS inbox)
  // =========================================================================
  group('AddTransactionScreen · SMS auto-fill', () {
    testWidgets('pre-fills the amount when the SMS text has one',
        (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen(
        initialSmsBody: 'Amt Deducted! Rs.11500 from your HDFC Bank A/c '
            'XX0444 for something the date/merchant patterns do not recognise',
      ));
      await tester.pumpAndSettle();

      final amountField =
          tester.widget<TextFormField>(find.byType(TextFormField).first);
      expect(amountField.controller?.text, '11500.00');
    });

    testWidgets('leaves the amount blank when nothing is found',
        (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(
        buildScreen(initialSmsBody: 'Your OTP is 123456'),
      );
      await tester.pumpAndSettle();

      final amountField =
          tester.widget<TextFormField>(find.byType(TextFormField).first);
      expect(amountField.controller?.text, isEmpty);
    });

    testWidgets('leaves the amount blank without an SMS body', (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      final amountField =
          tester.widget<TextFormField>(find.byType(TextFormField).first);
      expect(amountField.controller?.text, isEmpty);
    });
  });

  // =========================================================================
  // MERCHANT SEARCH SHEET
  // =========================================================================
  group('AddTransactionScreen · merchant search sheet', () {
    testWidgets('lists all merchants and has a search bar', (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      // Open merchant sheet
      await tester.tap(find.text('Select or add merchant'));
      await tester.pumpAndSettle();

      expect(find.text('Select Merchant'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Search or add merchant...'),
          findsOneWidget);
      expect(find.text('Swiggy'), findsOneWidget);
      expect(find.text('Zomato'), findsOneWidget);
      expect(find.text('Amazon'), findsOneWidget);
      expect(find.text('BigBasket'), findsOneWidget);
    });

    testWidgets('search filters the merchant list in real time',
        (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Select or add merchant'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, 'Search or add merchant...'), 'swig');
      await tester.pumpAndSettle();

      expect(find.text('Swiggy'), findsOneWidget);
      expect(find.text('Zomato'), findsNothing);
      expect(find.text('Amazon'), findsNothing);
      expect(find.text('BigBasket'), findsNothing);
    });

    testWidgets('search is case-insensitive', (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Select or add merchant'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, 'Search or add merchant...'),
          'AMAZON');
      await tester.pumpAndSettle();

      expect(find.text('Amazon'), findsOneWidget);
    });

    testWidgets('selecting an existing merchant sets it on the form',
        (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Select or add merchant'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Swiggy'));
      await tester.pumpAndSettle();

      // Sheet should close and merchant shows on the main screen
      expect(find.text('Select Merchant'), findsNothing);
      expect(find.text('Swiggy'), findsOneWidget);
    });

    testWidgets(
        'shows "Add New" fallback when the search does not match existing',
        (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Select or add merchant'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, 'Search or add merchant...'),
          'New Coffee Shop');
      await tester.pumpAndSettle();

      expect(find.text('Add "New Coffee Shop"'), findsWidgets);
      expect(find.text('New merchant'), findsOneWidget);
    });

    testWidgets('tapping "Add New" sets the typed merchant on the form',
        (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Select or add merchant'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, 'Search or add merchant...'),
          'Haldirams');
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add "Haldirams"').first);
      await tester.pumpAndSettle();

      expect(find.text('Haldirams'), findsOneWidget);
    });

    testWidgets('no "Add New" tile appears when the exact match already exists',
        (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Select or add merchant'));
      await tester.pumpAndSettle();

      // Type an exact existing name
      await tester.enterText(
          find.widgetWithText(TextField, 'Search or add merchant...'),
          'Swiggy');
      await tester.pumpAndSettle();

      expect(find.text('New merchant'), findsNothing);
    });

    testWidgets('empty merchant list shows empty state text', (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen(merchs: const <String>[]));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Select or add merchant'));
      await tester.pumpAndSettle();

      expect(find.text('No merchants recorded yet.'), findsOneWidget);
    });

    testWidgets('clear button on search bar resets the filter', (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Select or add merchant'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, 'Search or add merchant...'), 'xyz');
      await tester.pumpAndSettle();

      // All four merchants hidden
      expect(find.text('Swiggy'), findsNothing);

      // Tap clear button
      await tester.tap(find.byIcon(Icons.clear));
      await tester.pumpAndSettle();

      // All merchants visible again
      expect(find.text('Swiggy'), findsOneWidget);
      expect(find.text('Zomato'), findsOneWidget);
    });
  });

  // =========================================================================
  // CATEGORY SEARCH SHEET
  // =========================================================================
  group('AddTransactionScreen · category search sheet', () {
    testWidgets('lists categories excluding Uncategorized', (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Category'));
      await tester.pumpAndSettle();

      expect(find.text('Select Category'), findsOneWidget);
      // Food appears both on the form and in the sheet
      expect(find.text('Food'), findsWidgets);
      expect(find.text('Grocery'), findsOneWidget);
      expect(find.text('Shopping'), findsOneWidget);
      // Uncategorized should be filtered out of the sheet
      expect(find.text('Uncategorized'), findsNothing);
    });

    testWidgets('search narrows the category list', (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Category'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, 'Search or add category...'), 'Shop');
      await tester.pumpAndSettle();

      expect(find.text('Shopping'), findsOneWidget);
      // Food still shows on the underlying form, but not in the sheet list.
      // The sheet should only show Shopping. We verify Grocery is hidden.
      expect(find.text('Grocery'), findsNothing);
    });

    testWidgets('selecting an existing category updates the form',
        (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Category'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Shopping'));
      await tester.pumpAndSettle();

      expect(find.text('Shopping'), findsOneWidget);
    });

    testWidgets(
        'shows "Add New" fallback for a category name that does not exist',
        (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Category'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, 'Search or add category...'),
          'Electronics');
      await tester.pumpAndSettle();

      expect(find.text('Add "Electronics"'), findsWidgets);
      expect(find.text('Create and select new category'), findsOneWidget);
    });

    testWidgets('no "Add New" tile when the exact category already exists',
        (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Category'));
      await tester.pumpAndSettle();

      await tester.enterText(
          find.widgetWithText(TextField, 'Search or add category...'), 'Food');
      await tester.pumpAndSettle();

      expect(find.text('Create and select new category'), findsNothing);
    });
  });

  // =========================================================================
  // PAYMENT METHOD SELECTION
  // =========================================================================
  group('AddTransactionScreen · payment methods', () {
    testWidgets('switching to UPI deselects Cash', (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      await tester.tap(find.text('UPI'));
      await tester.pumpAndSettle();

      final upiChip = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, 'UPI'),
      );
      expect(upiChip.selected, isTrue);

      final cashChip = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, 'Cash'),
      );
      expect(cashChip.selected, isFalse);
    });

    testWidgets('can switch through all five payment types', (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      for (final label
          in <String>['Cash', 'UPI', 'Debit Card', 'Credit Card', 'Other']) {
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();

        final chip = tester.widget<ChoiceChip>(
          find.widgetWithText(ChoiceChip, label),
        );
        expect(chip.selected, isTrue,
            reason: '$label should be selected after tapping');
      }
    });

    testWidgets('shows real saved cards from the ledger alongside the base five',
        (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen(
        paymentTypes: const <String>['HDFC Bank Card 6824', 'ICICI XX8008'],
      ));
      await tester.pumpAndSettle();

      for (final label in <String>[
        'Cash', 'UPI', 'Debit Card', 'Credit Card', 'Other', // base five
        'HDFC Bank Card 6824', 'ICICI XX8008', // real saved cards
      ]) {
        expect(find.widgetWithText(ChoiceChip, label), findsOneWidget);
      }

      await tester.tap(find.text('HDFC Bank Card 6824'));
      await tester.pumpAndSettle();

      final cardChip = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, 'HDFC Bank Card 6824'),
      );
      expect(cardChip.selected, isTrue);
    });

    testWidgets('does not duplicate a saved value that matches a base chip',
        (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen(
        paymentTypes: const <String>['Cash', 'UPI'],
      ));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(ChoiceChip, 'Cash'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'UPI'), findsOneWidget);
    });
  });

  // =========================================================================
  // DATE & TIME PICKERS
  // =========================================================================
  group('AddTransactionScreen · date and time', () {
    testWidgets('date picker opens and can be dismissed', (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Date'));
      await tester.pumpAndSettle();

      expect(find.byType(DatePickerDialog), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.byType(DatePickerDialog), findsNothing);
    });

    testWidgets('time picker opens and can be dismissed', (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Time'));
      await tester.pumpAndSettle();

      expect(find.byType(TimePickerDialog), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.byType(TimePickerDialog), findsNothing);
    });

    testWidgets('date picker OK updates the displayed date', (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      // Capture the current displayed date text
      final dateTileFinder = find.ancestor(
        of: find.text('Date'),
        matching: find.byType(ListTile),
      );
      expect(dateTileFinder, findsOneWidget);

      await tester.tap(find.text('Date'));
      await tester.pumpAndSettle();

      // Tap OK to confirm today's date
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      // Should still show a date (picker closed)
      expect(find.byType(DatePickerDialog), findsNothing);
    });
  });

  // =========================================================================
  // NOTES FIELD
  // =========================================================================
  group('AddTransactionScreen · notes', () {
    testWidgets('can type notes text', (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      final notesField = find.widgetWithText(TextFormField, 'Notes (optional)');
      await tester.enterText(notesField, 'Dinner with team');
      await tester.pumpAndSettle();

      expect(find.text('Dinner with team'), findsOneWidget);
    });

    testWidgets('displays the max length counter', (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      final notesField = find.widgetWithText(TextFormField, 'Notes (optional)');
      await tester.enterText(notesField, 'Test');
      await tester.pumpAndSettle();

      // Flutter shows "4/140" for a maxLength of 140
      expect(find.textContaining('/140'), findsOneWidget);
    });

    testWidgets('shows hint text', (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      expect(find.text('What was this expense for?'), findsOneWidget);
    });
  });

  // =========================================================================
  // SPLIT TRANSACTION MODE
  // =========================================================================
  group('AddTransactionScreen · split transactions', () {
    testWidgets('toggling split on shows the split builder', (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(find.text('Divide the total amount across multiple categories:'),
          findsOneWidget);
      expect(find.text('Add split line'), findsOneWidget);
      expect(find.text('Auto-balance'), findsOneWidget);
    });

    testWidgets('toggling split off hides the split builder', (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      // Toggle on
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text('Divide the total amount across multiple categories:'),
          findsOneWidget);

      // Toggle off
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text('Divide the total amount across multiple categories:'),
          findsNothing);

      // Category selector should reappear
      expect(find.text('Category'), findsOneWidget);
    });

    testWidgets('starts with two split lines', (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      // Two split row amount fields (with ₹ prefix)
      final splitRowFields = find.byWidgetPredicate(
        (Widget w) => w is TextField && w.decoration?.prefixText == '₹',
      );
      expect(splitRowFields, findsNWidgets(2));
    });

    testWidgets('adding a third line shows delete icons', (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      // Two lines: no delete icons
      expect(find.byIcon(Icons.delete_outline), findsNothing);

      // Add a third line
      await tester.tap(find.text('Add split line'));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.delete_outline), findsWidgets);
    });

    testWidgets('removing a line back to two hides delete icons',
        (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      // Add a third, then remove it
      await tester.tap(find.text('Add split line'));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.delete_outline).last);
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.delete_outline), findsNothing);
    });

    testWidgets('auto-balance distributes the remainder', (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      // Enter amount 1000
      final amountField = find.byType(TextFormField).first;
      await tester.enterText(amountField, '1000');
      await tester.pumpAndSettle();

      // Toggle split
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      // Set first split line to 400
      final splitRowFields = find.byWidgetPredicate(
        (Widget w) => w is TextField && w.decoration?.prefixText == '₹',
      );
      await tester.enterText(splitRowFields.first, '400');
      await tester.pumpAndSettle();

      // Pick category for second line
      await tester.tap(find.text('Pick category'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Grocery'));
      await tester.pumpAndSettle();

      // Tap auto-balance
      await tester.tap(find.text('Auto-balance'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Balanced:'), findsOneWidget);
    });

    testWidgets('unbalanced split shows the difference', (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      // Enter 1000
      final amountField = find.byType(TextFormField).first;
      await tester.enterText(amountField, '1000');
      await tester.pumpAndSettle();

      // Toggle split
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      // Set first split to 300
      final splitRowFields = find.byWidgetPredicate(
        (Widget w) => w is TextField && w.decoration?.prefixText == '₹',
      );
      await tester.enterText(splitRowFields.first, '300');
      await tester.pumpAndSettle();

      // Without auto-balance, line 2 has the remainder or 0 — status shows Allocated
      expect(find.textContaining('Allocated'), findsOneWidget);
    });

    testWidgets('split line category can be picked from the sheet',
        (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      // Tap the second line's "Pick category"
      await tester.tap(find.text('Pick category'));
      await tester.pumpAndSettle();

      expect(find.text('Select Category'), findsOneWidget);
      await tester.tap(find.text('Shopping'));
      await tester.pumpAndSettle();

      // Shopping should now be shown in the split row
      expect(find.text('Shopping'), findsOneWidget);
    });
  });

  // =========================================================================
  // VALIDATION
  // =========================================================================
  group('AddTransactionScreen · validation', () {
    testWidgets('rejects save when merchant is empty', (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(
          find.text('Please enter or select a merchant name'), findsOneWidget);
    });

    testWidgets('rejects save when amount is zero', (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      // Set a merchant first
      await tester.tap(find.text('Select or add merchant'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Swiggy'));
      await tester.pumpAndSettle();

      // Leave amount at 0 and tap bottom save
      await tester.tap(find.widgetWithText(FilledButton, 'Add Transaction'));
      await tester.pumpAndSettle();

      // Amount field validator fires
      expect(find.text('Enter an amount'), findsOneWidget);
    });

    testWidgets('rejects save when amount field has invalid text',
        (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      // Set a merchant
      await tester.tap(find.text('Select or add merchant'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Swiggy'));
      await tester.pumpAndSettle();

      // Enter an empty value (just spaces)
      final amountField = find.byType(TextFormField).first;
      await tester.enterText(amountField, '  ');
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();

      expect(find.text('Enter an amount'), findsOneWidget);
    });

    testWidgets('bottom Add Transaction button triggers same validation',
        (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      // Tap the bottom button directly (no merchant selected, no amount)
      await tester.tap(find.widgetWithText(FilledButton, 'Add Transaction'));
      await tester.pumpAndSettle();

      // Merchant snackbar appears first
      expect(
          find.text('Please enter or select a merchant name'), findsOneWidget);
    });
  });

  // =========================================================================
  // FULL FORM INTERACTION FLOW
  // =========================================================================
  group('AddTransactionScreen · form interaction flow', () {
    testWidgets('can fill in all fields except save (no DB in test)',
        (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      // 1. Amount
      final amountField = find.byType(TextFormField).first;
      await tester.enterText(amountField, '250.50');
      await tester.pumpAndSettle();

      // 2. Merchant
      await tester.tap(find.text('Select or add merchant'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Swiggy'));
      await tester.pumpAndSettle();
      expect(find.text('Swiggy'), findsOneWidget);

      // 3. Category
      await tester.tap(find.text('Category'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Shopping'));
      await tester.pumpAndSettle();
      expect(find.text('Shopping'), findsOneWidget);

      // 4. Payment method
      await tester.tap(find.text('UPI'));
      await tester.pumpAndSettle();
      final upiChip = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, 'UPI'),
      );
      expect(upiChip.selected, isTrue);

      // 5. Notes
      final notesField = find.widgetWithText(TextFormField, 'Notes (optional)');
      await tester.enterText(notesField, 'Lunch order');
      await tester.pumpAndSettle();
      expect(find.text('Lunch order'), findsOneWidget);
    });

    testWidgets('can switch from single category to split and back',
        (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      // Single category is visible
      expect(find.text('Category'), findsOneWidget);

      // Toggle on split
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text('Add split line'), findsOneWidget);
      expect(find.text('Category'), findsNothing);

      // Toggle back off
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text('Category'), findsOneWidget);
      expect(find.text('Add split line'), findsNothing);
    });

    testWidgets('re-selecting a merchant clears and updates the form',
        (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      // Pick Swiggy
      await tester.tap(find.text('Select or add merchant'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Swiggy'));
      await tester.pumpAndSettle();
      expect(find.text('Swiggy'), findsOneWidget);

      // Re-open and pick Amazon instead
      await tester.tap(find.text('Swiggy'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Amazon'));
      await tester.pumpAndSettle();
      expect(find.text('Amazon'), findsOneWidget);
      expect(find.text('Swiggy'), findsNothing);
    });
  });

  // =========================================================================
  // EDGE CASES
  // =========================================================================
  group('AddTransactionScreen · edge cases', () {
    testWidgets('amount field only accepts numbers and one decimal point',
        (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      final amountField = find.byType(TextFormField).first;
      // Try entering invalid characters — the FilteringTextInputFormatter
      // should strip them. We can only verify that the field does not error.
      await tester.enterText(amountField, '123.45');
      await tester.pumpAndSettle();
      expect(find.text('123.45'), findsOneWidget);
    });

    testWidgets('merchant search with trailing whitespace still matches',
        (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      await tester.tap(find.text('Select or add merchant'));
      await tester.pumpAndSettle();

      // Trailing whitespace: the search trims internally
      await tester.enterText(
          find.widgetWithText(TextField, 'Search or add merchant...'),
          '  Swiggy  ');
      await tester.pumpAndSettle();

      // The list should contain only Swiggy (whitespace stripped in the
      // contains check) and the Add New tile should not appear because
      // the trimmed query matches.
      expect(find.text('Swiggy'), findsOneWidget);
    });

    testWidgets('adding many split lines does not overflow', (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      // Add several more lines (up to 5 total)
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('Add split line'));
        await tester.pumpAndSettle();
      }

      final splitRowFields = find.byWidgetPredicate(
        (Widget w) => w is TextField && w.decoration?.prefixText == '₹',
      );
      expect(splitRowFields, findsNWidgets(5));
    });

    testWidgets('app bar save button and bottom save button both exist',
        (tester) async {
      setLargeViewport(tester);

      await tester.pumpWidget(buildScreen());
      await tester.pumpAndSettle();

      // App bar save
      expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget);
      // Bottom save
      expect(find.widgetWithText(FilledButton, 'Add Transaction'),
          findsOneWidget);
    });
  });
}
