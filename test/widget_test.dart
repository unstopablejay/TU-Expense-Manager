import 'package:expense_manager/main.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SmsParser', () {
    test('parses a YES Bank credit card spend alert', () {
      final parsed = SmsParser.parse(kSampleSms);

      expect(parsed, isNotNull);
      // 204.00, not the 281,496.08 available limit later in the message.
      expect(parsed!.amount, 204.00);
      expect(parsed.paymentType, 'YES BANK Card X2858');
      expect(parsed.merchant, 'UPI_GEORGE EGG CENTRE');
      expect(parsed.date, DateTime(2026, 8, 13, 9, 21, 35));
    });

    test('handles thousands separators and pm times', () {
      final parsed = SmsParser.parse(
        'INR 12,345.67 spent on YES BANK Card X2858 @AMAZON RETAIL '
        '01-12-2026 07:05:09 pm. Avl Lmt INR 100.00',
      );

      expect(parsed!.amount, 12345.67);
      expect(parsed.merchant, 'AMAZON RETAIL');
      expect(parsed.date, DateTime(2026, 12, 1, 19, 5, 9));
    });

    test('maps 12 am to midnight and 12 pm to noon', () {
      DateTime dateOf(String time) => SmsParser.parse(
            'INR 1.00 spent on YES BANK Card X2858 @SHOP 01-01-2026 $time',
          )!.date;

      expect(dateOf('12:00:00 am'), DateTime(2026, 1, 1, 0));
      expect(dateOf('12:00:00 pm'), DateTime(2026, 1, 1, 12));
    });

    test('supports the "debited from" variant', () {
      final parsed = SmsParser.parse(
        'Rs. 500.00 debited from YES BANK A/c X1234 @SWIGGY '
        '13-08-2026 09:21:35 AM',
      );

      expect(parsed!.amount, 500.00);
      expect(parsed.paymentType, 'YES BANK A/c X1234');
      expect(parsed.merchant, 'SWIGGY');
    });

    test('returns null for messages that are not spend alerts', () {
      expect(SmsParser.parse('123456 is your OTP. Do not share it.'), isNull);
      expect(
        SmsParser.parse('Your YES BANK statement of INR 4,500.00 is ready.'),
        isNull,
      );
    });
  });
}
