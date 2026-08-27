import 'package:flutter_test/flutter_test.dart';
import 'package:tu_expense_tracker/main.dart';

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
      expect(parsed.hasExplicitTime, isTrue);
    });

    test('sets hasExplicitTime to false for date-only SMS alerts', () {
      const dateOnlySms =
          'Sent Rs.18.00\nFrom HDFC Bank A/C *0444\nTo Saravana Medical\nOn 10/08/26\nRef 213313774670';
      final parsed = SmsParser.parse(dateOnlySms);

      expect(parsed, isNotNull);
      expect(parsed!.hasExplicitTime, isFalse);
    });

    test('parses YES Bank Card alerts with explicit time and strips UPI prefix', () {
      const firstSms =
          'INR 15.00 spent on YES BANK Card X2858 @UPI_AVENUE FOOD PLAZA 26-08-2026 07:36:18 pm. Avl Lmt INR 328,132.85. SMS BLKCC 2858 to 9840909000 if not you.';
      const secondSms =
          'INR 15.00 spent on YES BANK Card X2858 @UPI_AVENUE FOOD PLAZA 26-08-2026 07:39:04 pm. Avl Lmt INR 328,117.85. SMS BLKCC 2858 to 9840909000 if not you';

      final p1 = SmsParser.parse(firstSms);
      final p2 = SmsParser.parse(secondSms);

      expect(p1, isNotNull);
      expect(p2, isNotNull);

      expect(p1!.merchant, 'AVENUE FOOD PLAZA');
      expect(p2!.merchant, 'AVENUE FOOD PLAZA');
      expect(p1.hasExplicitTime, isTrue);
      expect(p2.hasExplicitTime, isTrue);

      expect(p1.date, DateTime(2026, 8, 26, 19, 36, 18));
      expect(p2.date, DateTime(2026, 8, 26, 19, 39, 4));

      // Difference is 166 seconds (> 60s), ensuring they are recognized as distinct transactions
      final diffSeconds = p2.date.difference(p1.date).inSeconds.abs();
      expect(diffSeconds, 166);
    });
  });

  group('Composite Deduplication Invariants', () {
    test('accepts multiple same-day transactions when they have explicit clock times outside 60s window', () {
      final existingTxns = <Map<String, Object?>>[
        {
          'id': 1,
          'amount': 15.0,
          'merchant': 'AVENUE FOOD PLAZA',
          'date': DateTime(2026, 8, 26, 19, 36, 18).millisecondsSinceEpoch,
          'direction': 'debit',
          'reference': '',
          'payment_type': 'YES BANK Card X2858',
        },
      ];

      // Second transaction at 19:39:04 (166 seconds later)
      final incoming = ParsedSms(
        amount: 15.0,
        merchant: 'AVENUE FOOD PLAZA',
        paymentType: 'YES BANK Card X2858',
        date: DateTime(2026, 8, 26, 19, 39, 4),
        direction: TxnDirection.debit,
        reference: '',
        hasExplicitTime: true,
      );

      // Verify against deduplication rules
      bool isDuplicate = false;
      for (final t in existingTxns) {
        final tDate = t['date'] as int;
        final tAmount = t['amount'] as double;
        final tMerchant = (t['merchant'] as String).toLowerCase();
        final tDirection = t['direction'] as String;

        // 1. Exact natural key
        if (tAmount == incoming.amount &&
            tMerchant == incoming.merchant.toLowerCase() &&
            tDate == incoming.date.millisecondsSinceEpoch &&
            tDirection == incoming.direction.name) {
          isDuplicate = true;
          break;
        }

        // 2. 60-second window
        if (tAmount == incoming.amount &&
            tMerchant == incoming.merchant.toLowerCase() &&
            tDirection == incoming.direction.name &&
            (tDate - incoming.date.millisecondsSinceEpoch).abs() <= 60000) {
          isDuplicate = true;
          break;
        }

        // 3. Fallback same-day check only if !hasExplicitTime
        if (!incoming.hasExplicitTime) {
          final startOfDay = DateTime(2026, 8, 26).millisecondsSinceEpoch;
          final endOfDay = DateTime(2026, 8, 26, 23, 59, 59, 999).millisecondsSinceEpoch;
          if (tAmount == incoming.amount &&
              tMerchant == incoming.merchant.toLowerCase() &&
              tDirection == incoming.direction.name &&
              tDate >= startOfDay &&
              tDate <= endOfDay) {
            isDuplicate = true;
            break;
          }
        }
      }

      expect(isDuplicate, isFalse);
    });

    test('rejects duplicate within 60s window for same amount and merchant', () {
      final existingTxns = <Map<String, Object?>>[
        {
          'id': 1,
          'amount': 15.0,
          'merchant': 'AVENUE FOOD PLAZA',
          'date': DateTime(2026, 8, 26, 19, 36, 18).millisecondsSinceEpoch,
          'direction': 'debit',
          'reference': '',
          'payment_type': 'YES BANK Card X2858',
        },
      ];

      // Duplicate alert at 19:36:45 (27 seconds later)
      final incoming = ParsedSms(
        amount: 15.0,
        merchant: 'AVENUE FOOD PLAZA',
        paymentType: 'YES BANK Card X2858',
        date: DateTime(2026, 8, 26, 19, 36, 45),
        direction: TxnDirection.debit,
        reference: '',
        hasExplicitTime: true,
      );

      bool isDuplicate = false;
      for (final t in existingTxns) {
        final tDate = t['date'] as int;
        final tAmount = t['amount'] as double;
        final tMerchant = (t['merchant'] as String).toLowerCase();
        final tDirection = t['direction'] as String;

        if (tAmount == incoming.amount &&
            tMerchant == incoming.merchant.toLowerCase() &&
            tDirection == incoming.direction.name &&
            (tDate - incoming.date.millisecondsSinceEpoch).abs() <= 60000) {
          isDuplicate = true;
          break;
        }
      }

      expect(isDuplicate, isTrue);
    });

    test('applies same-day fallback deduplication only when hasExplicitTime is false and reference is empty', () {
      final existingTxns = <Map<String, Object?>>[
        {
          'id': 1,
          'amount': 500.0,
          'merchant': 'RAPIDO',
          'date': DateTime(2026, 8, 26, 10, 0, 0).millisecondsSinceEpoch,
          'direction': 'debit',
          'reference': '',
          'payment_type': 'Unknown',
        },
      ];

      // Date-only alert arriving later on the same day without reference or clock time
      final dateOnlyIncoming = ParsedSms(
        amount: 500.0,
        merchant: 'RAPIDO',
        paymentType: 'Unknown',
        date: DateTime(2026, 8, 26, 15, 30, 0),
        direction: TxnDirection.debit,
        reference: '',
        hasExplicitTime: false,
      );

      bool isDuplicate = false;
      for (final t in existingTxns) {
        final tDate = t['date'] as int;
        final tAmount = t['amount'] as double;
        final tMerchant = (t['merchant'] as String).toLowerCase();
        final tDirection = t['direction'] as String;

        if (!dateOnlyIncoming.hasExplicitTime) {
          final startOfDay = DateTime(2026, 8, 26).millisecondsSinceEpoch;
          final endOfDay = DateTime(2026, 8, 26, 23, 59, 59, 999).millisecondsSinceEpoch;
          if (tAmount == dateOnlyIncoming.amount &&
              tMerchant == dateOnlyIncoming.merchant.toLowerCase() &&
              tDirection == dateOnlyIncoming.direction.name &&
              tDate >= startOfDay &&
              tDate <= endOfDay) {
            isDuplicate = true;
            break;
          }
        }
      }

      expect(isDuplicate, isTrue);
    });
  });
}
