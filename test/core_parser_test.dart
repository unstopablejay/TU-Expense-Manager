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
  });
}
