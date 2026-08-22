import 'package:flutter_test/flutter_test.dart';
import 'package:tu_expense_tracker/main.dart';
import 'package:tu_expense_tracker/src/mobile/sms_source.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SmsSource Ingestion Deduplication', () {
    test('drops duplicate broadcast events within window', () {
      final source = SmsSource();
      final received = <InboxSms>[];
      source.listen((InboxSms sms) {
        received.add(sms);
      });

      final time = DateTime(2026, 8, 22, 10, 0, 0);
      final sms1 = InboxSms(
        'Spent Rs.100.00 On HDFC Bank Card 6824 At SWIGGY On 2026-08-22:10:00:00.',
        time,
      );
      final sms2 = InboxSms(
        'Spent Rs.100.00 On HDFC Bank Card 6824 At SWIGGY On 2026-08-22:10:00:00.',
        time,
      );

      source.simulateIncomingSms(sms1);
      source.simulateIncomingSms(sms2);

      expect(received.length, 1);
    });

    test('delivers distinct messages from different merchants', () {
      final source = SmsSource();
      final received = <InboxSms>[];
      source.listen((InboxSms sms) {
        received.add(sms);
      });

      final time = DateTime(2026, 8, 22, 10, 0, 0);
      final sms1 = InboxSms(
        'Spent Rs.100.00 On HDFC Bank Card 6824 At SWIGGY On 2026-08-22:10:00:00.',
        time,
      );
      final sms2 = InboxSms(
        'Spent Rs.200.00 On HDFC Bank Card 6824 At ZOMATO On 2026-08-22:10:00:00.',
        time,
      );

      source.simulateIncomingSms(sms1);
      source.simulateIncomingSms(sms2);

      expect(received.length, 2);
    });
  });

  group('SmsParser Deduplication Attributes', () {
    test('normalizes whitespace in merchant and reference', () {
      const smsBody =
          'Sent Rs.18.00\nFrom HDFC Bank A/C *0444\nTo  Saravana   Medical \nOn 10/08/26\nRef  213313774670 ';
      final parsed = SmsParser.parse(smsBody);

      expect(parsed, isNotNull);
      expect(parsed!.merchant, 'Saravana Medical');
      expect(parsed.reference, '213313774670');
    });

    test('parses direction and amounts reliably for dedupe', () {
      const debitBody =
          'Spent Rs.39791.72 From HDFC Bank Card x2227 At PZCREDIT9772829 On 2026-08-11:06:08:24 Bal Rs.210943.42';
      final parsed = SmsParser.parse(debitBody);

      expect(parsed, isNotNull);
      expect(parsed!.direction, TxnDirection.debit);
      expect(parsed.amount, 39791.72);
      expect(parsed.merchant, 'PZCREDIT9772829');
    });
  });
}
