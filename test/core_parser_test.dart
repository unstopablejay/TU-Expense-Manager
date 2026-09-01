import 'package:flutter_test/flutter_test.dart';
import 'package:tu_expense_tracker/src/core/parser.dart';

void main() {
  group('SmsParser', () {
    test('looksLikeTransaction matches HDFC loose templates', () {
      const sms1 = 'Amt Deducted! Rs.11500 from your HDFC Bank A/c XX0444 for NEFT txn via HDFC Bank Online Banking Not you?Call 18002586161/SMS BLOCK OB to 7308080808';
      const sms2 = 'Txn Rs.755.00\nOn HDFC Bank Card 8174\nAt hathwaymobileapp.76062993 \nby UPI 250214536533\nOn 01-09\nNot You?';
      
      expect(SmsParser.looksLikeTransaction(sms1), isTrue);
      expect(SmsParser.looksLikeTransaction(sms2), isTrue);
    });
    
    test('looksLikeTransaction ignores random texts', () {
      expect(SmsParser.looksLikeTransaction('Hey, how are you?'), isFalse);
      expect(SmsParser.looksLikeTransaction('Your OTP is 123456'), isFalse);
    });

    test('extractAmountOnly finds the amount in a message a full parse would reject', () {
      // No recognisable merchant/date shape, so SmsParser.parse returns null —
      // this is exactly what ends up in the unadded-SMS inbox.
      const sms = 'Amt Deducted! Rs.11500 from your HDFC Bank A/c XX0444 for '
          'something the date/merchant patterns do not recognise';
      expect(SmsParser.parse(sms), isNull);
      expect(SmsParser.extractAmountOnly(sms), 11500);
    });

    test('extractAmountOnly handles Indian grouping and decimals', () {
      expect(SmsParser.extractAmountOnly('INR 3,99,614.00 blocked'), 399614.00);
      expect(SmsParser.extractAmountOnly('₹53 spent'), 53);
    });

    test('extractAmountOnly returns null when there is nothing to find', () {
      expect(SmsParser.extractAmountOnly('Your OTP is 123456'), isNull);
      expect(SmsParser.extractAmountOnly(''), isNull);
    });
  });
}
