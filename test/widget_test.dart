import 'package:tu_expense_tracker/main.dart';
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
      // "Spend", not "Spent" — a promo must not become a transaction.
      expect(
        SmsParser.parse('Spend Rs.500 and get cashback On HDFC Bank Card 6824'),
        isNull,
      );
    });
  });

  // Real message bodies, pasted verbatim from the device.
  group('SmsParser · HDFC card', () {
    const String body =
        'Spent Rs.122.02 On HDFC Bank Card 6824 At INNOVATIVE RETAIL CONC '
        'On 2026-08-13:07:19:26.Not You? To Block+Reissue Call '
        '18002586161/SMS BLOCK CC 6824 to 7308080808';

    test('parses amount, card, merchant and yyyy-MM-dd:HH:mm:ss date', () {
      final parsed = SmsParser.parse(body);

      expect(parsed, isNotNull);
      expect(parsed!.templateId, 'hdfc_card');
      expect(parsed.amount, 122.02);
      expect(parsed.paymentType, 'HDFC Bank Card 6824');
      expect(parsed.merchant, 'INNOVATIVE RETAIL CONC');
      expect(parsed.date, DateTime(2026, 8, 13, 7, 19, 26));
      expect(parsed.direction, TxnDirection.debit);
      expect(parsed.reference, '');
    });

    test('takes the spend and not the trailing balance', () {
      final parsed = SmsParser.parse(
        'Spent Rs.39791.72 From HDFC Bank Card x2227 At PZCREDIT9772829 '
        'On 2026-08-11:06:08:24 Bal Rs.210943.42 Not You? Call '
        '18002586161/SMS BLOCK DC  2227 to 7308080808',
      );

      expect(parsed!.amount, 39791.72); // not Bal Rs.210943.42
      expect(parsed.paymentType, 'HDFC Bank Card x2227');
      expect(parsed.merchant, 'PZCREDIT9772829');
      expect(parsed.date, DateTime(2026, 8, 11, 6, 8, 24));
    });

    // The regression that matters: this merchant name contains "CREDIT", so any
    // keyword scan of the body would book Rs.39,791.72 as money received.
    test('a merchant named PZCREDIT9772829 is still a debit', () {
      final parsed = SmsParser.parse(
        'Spent Rs.39791.72 From HDFC Bank Card x2227 At PZCREDIT9772829 '
        'On 2026-08-11:06:08:24 Bal Rs.210943.42',
      );

      expect(parsed!.direction, TxnDirection.debit);
      expect(parsed.isCredit, isFalse);
    });
  });

  group('SmsParser · HDFC UPI', () {
    // One field per line, exactly as the bank sends it.
    const String body = 'Sent Rs.18.00\n'
        'From HDFC Bank A/C *0444\n'
        'To Saravana Medical\n'
        'On 10/08/26\n'
        'Ref 213313774670\n'
        'Not You?\n'
        'Call 18002586161/SMS BLOCK UPI to 7308080808';

    test('parses the multi-line body including the Ref', () {
      final parsed = SmsParser.parse(body);

      expect(parsed, isNotNull);
      expect(parsed!.templateId, 'hdfc_upi_sent');
      expect(parsed.amount, 18.00);
      expect(parsed.paymentType, 'HDFC Bank A/C *0444');
      expect(parsed.merchant, 'Saravana Medical');
      expect(parsed.direction, TxnDirection.debit);
      expect(parsed.reference, '213313774670');
    });

    test('parses the flattened single-line form too', () {
      final parsed = SmsParser.parse(
        'Sent Rs.53.00 From HDFC Bank A/C *0444 To Rapido On 11/08/26 '
        'Ref 212968160467 Not You? Call 18002586161',
      );

      expect(parsed!.amount, 53.00);
      expect(parsed.merchant, 'Rapido');
      expect(parsed.reference, '212968160467');
    });

    test('a date with no clock time falls back to midnight', () {
      expect(SmsParser.parse(body)!.date, DateTime(2026, 8, 10));
    });

    test('adopts the SMS arrival time of day when it is the same date', () {
      final parsed = SmsParser.parse(
        body,
        receivedAt: DateTime(2026, 8, 10, 14, 32, 7),
      );

      expect(parsed!.date, DateTime(2026, 8, 10, 14, 32, 7));
    });

    test('ignores an arrival time from a different date', () {
      // A late inbox scan must not drag the transaction onto the scan day.
      final parsed = SmsParser.parse(
        body,
        receivedAt: DateTime(2026, 8, 13, 14, 32, 7),
      );

      expect(parsed!.date, DateTime(2026, 8, 10));
    });
  });

  group('SmsParser · ICICI card', () {
    test('parses a dd-MMM-yy date and stops the merchant at the period', () {
      final parsed = SmsParser.parse(
        'INR 160.00 spent using ICICI Bank Card XX8008 on 11-Aug-26 on '
        'AMAZON PAY IN G. Avl Limit: INR 3,99,614.00. If not you, call '
        '1800 2662/SMS BLOCK 8008 to 9215676766.',
      );

      expect(parsed, isNotNull);
      expect(parsed!.templateId, 'icici_card');
      expect(parsed.amount, 160.00); // not the 3,99,614.00 available limit
      expect(parsed.paymentType, 'ICICI Bank Card XX8008');
      expect(parsed.merchant, 'AMAZON PAY IN G');
      expect(parsed.date, DateTime(2026, 8, 11));
      expect(parsed.direction, TxnDirection.debit);
    });
  });

  // Written from each issuer's documented wording rather than a real message.
  group('SmsParser · unverified templates', () {
    test('SBI UPI debit', () {
      final parsed = SmsParser.parse(
        'Dear UPI user A/C X1234 debited by 150.0 on date 11Aug26 trf to '
        'RAPIDO Refno 123456789',
      );

      expect(parsed!.templateId, 'sbi_upi_debit');
      expect(parsed.amount, 150.0);
      expect(parsed.merchant, 'RAPIDO');
      expect(parsed.date, DateTime(2026, 8, 11));
      expect(parsed.direction, TxnDirection.debit);
      expect(parsed.reference, '123456789');
    });

    test('Axis-style debit with a 24-hour timestamp', () {
      final parsed = SmsParser.parse(
        'INR 500.00 debited from A/c no. XX1234 on 11-08-26 12:30:45 at '
        'AMAZON. Avl Bal INR 1000',
      );

      expect(parsed!.templateId, 'axis_debit');
      expect(parsed.amount, 500.00);
      expect(parsed.merchant, 'AMAZON');
      expect(parsed.date, DateTime(2026, 8, 11, 12, 30, 45));
      expect(parsed.direction, TxnDirection.debit);
    });

    test('Kotak-style card debit', () {
      final parsed = SmsParser.parse(
        'Rs.500.00 spent on Kotak Bank Card X1234 on 11-Aug-26 at RAPIDO. '
        'Avl Limit Rs.1000',
      );

      expect(parsed!.templateId, 'kotak_card_debit');
      expect(parsed.merchant, 'RAPIDO');
      expect(parsed.direction, TxnDirection.debit);
    });

    test('"credited to ... from" is money received', () {
      final parsed = SmsParser.parse(
        'Rs.500.00 credited to HDFC Bank A/c XX0444 from RAPIDO on 11/08/26 '
        'Ref 123456789',
      );

      expect(parsed!.templateId, 'generic_credit_to');
      expect(parsed.amount, 500.00);
      expect(parsed.paymentType, 'HDFC Bank A/c XX0444');
      expect(parsed.merchant, 'RAPIDO');
      expect(parsed.direction, TxnDirection.credit);
      expect(parsed.isCredit, isTrue);
      expect(parsed.reference, '123456789');
    });

    test('"Received ... in ... from" is money received', () {
      final parsed = SmsParser.parse(
        'Received Rs.750.50 in HDFC Bank A/c XX0444 from SALARY CREDIT on '
        '11/08/26 Ref 987654321',
      );

      expect(parsed!.templateId, 'generic_received_in');
      expect(parsed.amount, 750.50);
      expect(parsed.merchant, 'SALARY CREDIT');
      expect(parsed.direction, TxnDirection.credit);
    });

    test('SBI "is credited with" is money received', () {
      final parsed = SmsParser.parse(
        'Your A/c XX1234 is credited with Rs.500 on 11-08-26 by RAPIDO',
      );

      expect(parsed!.templateId, 'sbi_credit');
      expect(parsed.amount, 500);
      expect(parsed.paymentType, 'A/c XX1234');
      expect(parsed.merchant, 'RAPIDO');
      expect(parsed.direction, TxnDirection.credit);
    });
  });

  group('applyFilters', () {
    ExpenseTxn txn({
      required int id,
      required String paymentType,
      required int categoryId,
      required String categoryName,
      TxnDirection direction = TxnDirection.debit,
    }) =>
        ExpenseTxn(
          id: id,
          amount: 100,
          paymentType: paymentType,
          merchant: 'MERCHANT $id',
          date: DateTime(2026, 8, id),
          categoryId: categoryId,
          categoryName: categoryName,
          direction: direction,
          reference: '',
        );

    final ledger = <ExpenseTxn>[
      txn(id: 1, paymentType: 'YES BANK Card X2858', categoryId: 2, categoryName: 'Food'),
      txn(id: 2, paymentType: 'HDFC Bank A/C *0444', categoryId: 2, categoryName: 'Food'),
      txn(id: 3, paymentType: 'YES BANK Card X2858', categoryId: 3, categoryName: 'Fuel'),
      txn(
        id: 4,
        paymentType: 'HDFC Bank A/C *0444',
        categoryId: 4,
        categoryName: 'Salary',
        direction: TxnDirection.credit,
      ),
    ];

    List<int> idsOf(List<ExpenseTxn> rows) =>
        rows.map((ExpenseTxn t) => t.id).toList();

    test('no filters returns the list untouched', () {
      expect(identical(applyFilters(ledger), ledger), isTrue);
    });

    test('filters by category alone', () {
      expect(idsOf(applyFilters(ledger, categoryId: 2)), <int>[1, 2]);
    });

    test('filters by card or account alone', () {
      expect(
        idsOf(applyFilters(ledger, paymentType: 'HDFC Bank A/C *0444')),
        <int>[2, 4],
      );
    });

    test('credits are filtered like any other row', () {
      expect(idsOf(applyFilters(ledger, categoryId: 4)), <int>[4]);
    });

    test('both filters together are an AND, not an OR', () {
      expect(
        idsOf(applyFilters(
          ledger,
          categoryId: 2,
          paymentType: 'YES BANK Card X2858',
        )),
        <int>[1],
      );
    });

    test('a combination nothing matches yields an empty list', () {
      expect(
        applyFilters(
          ledger,
          categoryId: 3, // Fuel, only ever on the YES card
          paymentType: 'HDFC Bank A/C *0444',
        ),
        isEmpty,
      );
    });

    group('categoriesInUse', () {
      // The seed list, in the order the database hands it back: Uncategorized
      // pinned first, the rest alphabetical.
      const all = <ExpenseCategory>[
        ExpenseCategory(id: 1, name: 'Uncategorized'),
        ExpenseCategory(id: 2, name: 'Food'),
        ExpenseCategory(id: 3, name: 'Fuel'),
        ExpenseCategory(id: 4, name: 'Salary'),
        ExpenseCategory(id: 5, name: 'Travel'),
      ];

      List<String> namesOf(List<ExpenseCategory> rows) =>
          rows.map((ExpenseCategory c) => c.name).toList();

      test('drops categories no transaction uses', () {
        // The ledger uses 2 (Food), 3 (Fuel) and 4 (Salary) — never 1 or 5.
        expect(namesOf(categoriesInUse(ledger, all)),
            <String>['Food', 'Fuel', 'Salary']);
      });

      test('keeps the order of the full list', () {
        final shuffled = <ExpenseTxn>[ledger[3], ledger[2], ledger[0]];
        expect(namesOf(categoriesInUse(shuffled, all)),
            <String>['Food', 'Fuel', 'Salary']);
      });

      test('a category used only by a credit still counts', () {
        // id 4 (Salary) is worn by the single credit in the ledger.
        expect(namesOf(categoriesInUse(<ExpenseTxn>[ledger[3]], all)),
            <String>['Salary']);
      });

      test('an empty ledger uses no categories', () {
        expect(categoriesInUse(<ExpenseTxn>[], all), isEmpty);
      });
    });
  });
}
