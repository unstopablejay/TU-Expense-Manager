import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:flutter/material.dart';
import 'package:tu_expense_tracker/src/core/ledger.dart';
import 'package:tu_expense_tracker/src/core/models.dart';
import 'package:tu_expense_tracker/src/ui_shared/compare_months_screen.dart';

void main() {
  group('CompareMonthsScreen', () {
    testWidgets('renders safely with minimum required inputs', (WidgetTester tester) async {
      final transactions = <ExpenseTxn>[];
      final monthChoices = <YearMonth>[
        const YearMonth(2026, 8),
        const YearMonth(2026, 7),
        const YearMonth(2026, 6),
      ];

      await tester.pumpWidget(
        MaterialApp(
          home: CompareMonthsScreen(
            transactions: transactions,
            monthChoices: monthChoices,
            money: NumberFormat.currency(symbol: '₹'),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Basic structure exists
      expect(find.text('Compare months'), findsOneWidget);
      // Pre-selects top 2 months
      expect(find.text('Aug 2026'), findsWidgets);
      expect(find.text('Jul 2026'), findsWidgets);
    });
  });
}
