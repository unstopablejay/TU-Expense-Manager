import 'package:flutter_test/flutter_test.dart';
import 'package:tu_expense_tracker/src/core/parser.dart';

void main() {
  group('SmsParser', () {
    test('parses HDFC amt deducted without date (uses fallback)', () {
      const sms = 'Amt Deducted! Rs.11500 from your HDFC Bank A/c XX0444 for NEFT txn via HDFC Bank Online Banking Not you?Call 18002586161/SMS BLOCK OB to 7308080808';
      final receivedAt = DateTime(2026, 9, 1, 10, 0);
      final parsed = SmsParser.parse(sms, receivedAt: receivedAt);
      
      expect(parsed, isNotNull);
      expect(parsed!.merchant, 'NEFT txn via HDFC Bank Online Banking');
      expect(parsed.amount, 11500.0);
      expect(parsed.paymentType, 'HDFC Bank A/c XX0444');
      expect(parsed.date, receivedAt);
    });

    test('parses HDFC card txn with short date', () {
      const sms = 'Txn Rs.755.00\nOn HDFC Bank Card 8174\nAt hathwaymobileapp.76062993 \nby UPI 250214536533\nOn 01-09\nNot You?';
      final parsed = SmsParser.parse(sms);
      
      expect(parsed, isNotNull);
      expect(parsed!.merchant, 'hathwaymobileapp.76062993');
      expect(parsed.amount, 755.0);
      expect(parsed.paymentType, 'HDFC Bank Card 8174');
      // Year is inferred from DateTime.now().year which is 2026 during this test
      expect(parsed.date.month, 9);
      expect(parsed.date.day, 1);
    });
  });
}
