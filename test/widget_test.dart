import 'package:excel/excel.dart' hide Border, BorderStyle, TextSpan;
import 'package:flutter/material.dart';
import 'package:tu_expense_tracker/main.dart';
import 'package:flutter_test/flutter_test.dart';

/// A button that asks [confirmDeleteTransactions] about [count] rows and hands
/// the answer to [onAnswer] — the dialog needs a route to sit in and a context to
/// be shown from, and this is the smallest thing that provides both.
Widget deleteAsker(int count, void Function(bool) onAnswer) => MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async =>
                onAnswer(await confirmDeleteTransactions(context, count)),
            child: const Text('ask'),
          ),
        ),
      ),
    );

/// The same idea as [deleteAsker], for the restore confirmation.
Widget restoreAsker(
  int replacing,
  int incoming,
  void Function(bool) onAnswer,
) =>
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async => onAnswer(
              await confirmRestore(
                context,
                replacing: replacing,
                incoming: incoming,
              ),
            ),
            child: const Text('ask'),
          ),
        ),
      ),
    );

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

  group('AppVersion', () {
    test('parses the three shapes the app has to reconcile', () {
      // The git tag, package_info_plus, and pubspec.yaml respectively.
      expect(AppVersion.parse('v1.2.3'), const AppVersion(1, 2, 3));
      expect(AppVersion.parse('1.2.3'), const AppVersion(1, 2, 3));
      expect(AppVersion.parse('1.2.3+7'), const AppVersion(1, 2, 3));
      expect(AppVersion.parse('V1.2.3'), const AppVersion(1, 2, 3));
    });

    test('missing parts read as zero', () {
      expect(AppVersion.parse('2'), const AppVersion(2, 0, 0));
      expect(AppVersion.parse('v2.1'), const AppVersion(2, 1, 0));
    });

    test('returns null when there is no number to compare', () {
      expect(AppVersion.parse(''), isNull);
      expect(AppVersion.parse('nightly'), isNull);
    });

    // The whole reason versions are not compared as strings.
    test('1.10.0 is newer than 1.9.0', () {
      expect(
        const AppVersion(1, 10, 0).compareTo(const AppVersion(1, 9, 0)),
        greaterThan(0),
      );
    });

    test('orders by major, then minor, then patch', () {
      expect(const AppVersion(2, 0, 0).compareTo(const AppVersion(1, 9, 9)),
          greaterThan(0));
      expect(const AppVersion(1, 2, 0).compareTo(const AppVersion(1, 2, 1)),
          lessThan(0));
      expect(const AppVersion(1, 2, 3).compareTo(const AppVersion(1, 2, 3)), 0);
    });
  });

  group('isUpdateAvailable', () {
    test('only a strictly newer release counts', () {
      expect(
        isUpdateAvailable(
          current: const AppVersion(1, 1, 0),
          latest: const AppVersion(1, 2, 0),
        ),
        isTrue,
      );
      expect(
        isUpdateAvailable(
          current: const AppVersion(1, 1, 0),
          latest: const AppVersion(1, 1, 0),
        ),
        isFalse,
      );
    });

    // A local build running ahead of the last release must not be told to
    // "update" itself backwards.
    test('an older release is not an update', () {
      expect(
        isUpdateAvailable(
          current: const AppVersion(1, 2, 0),
          latest: const AppVersion(1, 1, 0),
        ),
        isFalse,
      );
    });

    test('an unreadable version on either side stays quiet', () {
      expect(
        isUpdateAvailable(current: null, latest: const AppVersion(9, 0, 0)),
        isFalse,
      );
      expect(
        isUpdateAvailable(current: const AppVersion(1, 0, 0), latest: null),
        isFalse,
      );
    });
  });

  group('isCheckDue', () {
    final now = DateTime(2026, 8, 14, 12);

    test('a first run has never checked, so it checks', () {
      expect(isCheckDue(lastChecked: null, now: now), isTrue);
    });

    test('waits out the interval', () {
      expect(
        isCheckDue(lastChecked: now.subtract(const Duration(days: 6)), now: now),
        isFalse,
      );
      expect(
        isCheckDue(lastChecked: now.subtract(const Duration(days: 7)), now: now),
        isTrue,
      );
    });

    test('a stamp in the future means the clock moved, not a check to skip', () {
      expect(
        isCheckDue(lastChecked: now.add(const Duration(days: 30)), now: now),
        isTrue,
      );
    });
  });

  group('AppRelease.fromJson', () {
    Map<String, dynamic> payload({
      String tag = 'v1.2.0',
      List<Object?>? assets,
    }) =>
        <String, dynamic>{
          'tag_name': tag,
          'body': 'Fixed the thing.',
          'assets': assets ??
              <Object?>[
                <String, dynamic>{
                  'name': 'app-release.apk',
                  'browser_download_url': 'https://example.test/app.apk',
                },
              ],
        };

    test('reads the tag, notes and APK asset', () {
      final release = AppRelease.fromJson(payload());

      expect(release, isNotNull);
      expect(release!.version, const AppVersion(1, 2, 0));
      expect(release.tag, 'v1.2.0');
      expect(release.notes, 'Fixed the thing.');
      expect(release.apkUrl, 'https://example.test/app.apk');
    });

    test('picks the APK out of a release with several assets', () {
      final release = AppRelease.fromJson(payload(assets: <Object?>[
        <String, dynamic>{
          'name': 'mapping.txt',
          'browser_download_url': 'https://example.test/mapping.txt',
        },
        <String, dynamic>{
          'name': 'TU-Expense-Tracker-1.2.0.APK',
          'browser_download_url': 'https://example.test/app.apk',
        },
      ]));

      expect(release!.apkUrl, 'https://example.test/app.apk');
    });

    // A tag whose build failed still leaves a Release behind. Offering it would
    // announce an update that cannot be downloaded.
    test('a release with no APK is not offered', () {
      expect(AppRelease.fromJson(payload(assets: <Object?>[])), isNull);
      expect(
        AppRelease.fromJson(payload(assets: <Object?>[
          <String, dynamic>{
            'name': 'notes.txt',
            'browser_download_url': 'https://example.test/notes.txt',
          },
        ])),
        isNull,
      );
    });

    test('a tag with no version in it is not offered', () {
      expect(AppRelease.fromJson(payload(tag: 'nightly')), isNull);
    });
  });

  group('YearMonth', () {
    // These two are first for a reason. If == or hashCode is wrong, the month
    // filter's `contains` misses every time and the ledger renders empty with
    // nothing thrown — the one failure in this feature that looks like no
    // failure at all.
    test('two readings of the same month are the same value', () {
      expect(YearMonth.fromDate(DateTime(2026, 8, 1)),
          YearMonth.fromDate(DateTime(2026, 8, 31, 23, 59)));
      expect(const YearMonth(2026, 8), YearMonth.fromDate(DateTime(2026, 8, 16)));
    });

    test('works as a Set member, which is how the filter uses it', () {
      final set = <YearMonth>{const YearMonth(2026, 8), const YearMonth(2026, 7)};
      expect(set.contains(YearMonth.fromDate(DateTime(2026, 8, 16, 4, 30))), isTrue);
      expect(set.contains(const YearMonth(2026, 9)), isFalse);
      // A duplicate must collapse, or the "3 months" label would lie.
      expect(<YearMonth>{...set, const YearMonth(2026, 8)}, hasLength(2));
    });

    test('orders by year then month', () {
      expect(const YearMonth(2026, 8).compareTo(const YearMonth(2026, 9)),
          lessThan(0));
      expect(const YearMonth(2026, 1).compareTo(const YearMonth(2025, 12)),
          greaterThan(0));
      final months = <YearMonth>[
        const YearMonth(2026, 1),
        const YearMonth(2025, 12),
        const YearMonth(2026, 8),
      ]..sort();
      expect(months.map((YearMonth m) => m.month), <int>[12, 1, 8]);
    });

    test('stepping crosses the year boundary in both directions', () {
      expect(const YearMonth(2026, 12).plus(1), const YearMonth(2027, 1));
      expect(const YearMonth(2026, 1).plus(-1), const YearMonth(2025, 12));
      expect(const YearMonth(2026, 8).plus(0), const YearMonth(2026, 8));
      expect(const YearMonth(2026, 6).plus(12), const YearMonth(2027, 6));
      expect(const YearMonth(2026, 6).plus(-12), const YearMonth(2025, 6));
    });

    test('monthsUntil counts the gap, signed', () {
      expect(const YearMonth(2026, 6).monthsUntil(const YearMonth(2026, 8)), 2);
      expect(const YearMonth(2026, 1).monthsUntil(const YearMonth(2025, 12)), -1);
      expect(const YearMonth(2026, 8).monthsUntil(const YearMonth(2026, 8)), 0);
    });

    test('contains is inclusive of the whole month and nothing either side', () {
      const august = YearMonth(2026, 8);
      expect(august.contains(DateTime(2026, 8, 1)), isTrue);
      expect(august.contains(DateTime(2026, 8, 31, 23, 59, 59)), isTrue);
      expect(august.contains(DateTime(2026, 7, 31, 23, 59, 59)), isFalse);
      expect(august.contains(DateTime(2026, 9, 1)), isFalse);
    });

    test('current reads the month off an injected clock', () {
      expect(YearMonth.current(DateTime(2026, 8, 16)), const YearMonth(2026, 8));
    });
  });

  group('periodLabel', () {
    test('no months means every month', () {
      expect(periodLabel(const <YearMonth>{}), 'All time');
    });

    test('one month is named', () {
      expect(periodLabel(<YearMonth>{const YearMonth(2026, 8)}), 'Aug 2026');
    });

    test('several are counted rather than listed', () {
      expect(
        periodLabel(<YearMonth>{
          const YearMonth(2026, 8),
          const YearMonth(2026, 7),
          const YearMonth(2026, 6),
        }),
        '3 months',
      );
    });
  });

  group('applyFilters', () {
    ExpenseTxn txn({
      required int id,
      required String paymentType,
      required int categoryId,
      required String categoryName,
      TxnDirection direction = TxnDirection.debit,
      double amount = 100,
      String? merchant,
      String note = '',
      DateTime? date,
      List<TxnSplit> splits = const <TxnSplit>[],
    }) =>
        ExpenseTxn(
          id: id,
          amount: amount,
          paymentType: paymentType,
          merchant: merchant ?? 'MERCHANT $id',
          date: date ?? DateTime(2026, 8, id),
          categoryId: categoryId,
          categoryName: categoryName,
          direction: direction,
          reference: '',
          note: note,
          splits: splits,
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

    /// A ₹2,000 Amazon order broken into groceries, snacks and shopping — the
    /// case splits exist for.
    final amazon = txn(
      id: 5,
      paymentType: 'YES BANK Card X2858',
      merchant: 'AMAZON PAY IN G',
      amount: 2000,
      categoryId: 6,
      categoryName: 'Grocery',
      splits: const <TxnSplit>[
        TxnSplit(categoryId: 6, categoryName: 'Grocery', amount: 1200),
        TxnSplit(categoryId: 7, categoryName: 'Snacks', amount: 500),
        TxnSplit(categoryId: 8, categoryName: 'Shopping', amount: 300),
      ],
    );

    List<int> idsOf(List<LedgerEntry> rows) =>
        rows.map((LedgerEntry e) => e.txn.id).toList();

    test('no filters returns every row', () {
      expect(idsOf(applyFilters(ledger)), <int>[1, 2, 3, 4]);
    });

    test('filters by category alone', () {
      expect(idsOf(applyFilters(ledger, categoryIds: <int>{2})), <int>[1, 2]);
    });

    test('filters by card or account alone', () {
      expect(
        idsOf(applyFilters(ledger, paymentTypes: <String>{'HDFC Bank A/C *0444'})),
        <int>[2, 4],
      );
    });

    test('filters by multiple cards at once as an OR within the facet', () {
      expect(
        idsOf(applyFilters(ledger, paymentTypes: <String>{'YES BANK Card X2858', 'HDFC Bank A/C *0444'})),
        <int>[1, 2, 3, 4],
      );
    });

    test('filters by merchant alone', () {
      expect(
        idsOf(applyFilters(ledger, merchants: <String>{'MERCHANT 3'})),
        <int>[3],
      );
    });

    test('several categories at once are an OR within the facet', () {
      expect(
        idsOf(applyFilters(ledger, categoryIds: <int>{2, 3})),
        <int>[1, 2, 3],
      );
    });

    test('credits are filtered like any other row', () {
      expect(idsOf(applyFilters(ledger, categoryIds: <int>{4})), <int>[4]);
    });

    test('separate facets are an AND, not an OR', () {
      expect(
        idsOf(applyFilters(
          ledger,
          categoryIds: <int>{2},
          paymentTypes: <String>{'YES BANK Card X2858'},
        )),
        <int>[1],
      );
    });

    test('a combination nothing matches yields an empty list', () {
      expect(
        applyFilters(
          ledger,
          categoryIds: <int>{3}, // Fuel, only ever on the YES card
          paymentTypes: <String>{'HDFC Bank A/C *0444'},
        ),
        isEmpty,
      );
    });

    test('an unfiltered split contributes its whole amount', () {
      final entry = applyFilters(<ExpenseTxn>[amazon]).single;
      expect(entry.lines, hasLength(3));
      expect(entry.amount, 2000);
    });

    test('a category filter narrows a split to the matching line', () {
      final entry =
          applyFilters(<ExpenseTxn>[amazon], categoryIds: <int>{6}).single;
      expect(entry.amount, 1200);
      expect(entry.lines.single.categoryName, 'Grocery');
    });

    test('a split matching on two lines contributes both', () {
      final entry =
          applyFilters(<ExpenseTxn>[amazon], categoryIds: <int>{6, 8}).single;
      expect(entry.amount, 1500);
    });

    test('a split matching no line drops out entirely', () {
      expect(
        applyFilters(<ExpenseTxn>[amazon], categoryIds: <int>{2}),
        isEmpty,
      );
    });

    test('a split is found by the category of a minor line', () {
      // Shopping is the smallest of the three and is not the dominant category
      // cached on the transaction, so matching on it proves the filter reads
      // the lines rather than `category_id`.
      expect(
        idsOf(applyFilters(<ExpenseTxn>[amazon], categoryIds: <int>{8})),
        <int>[5],
      );
    });

    group('months', () {
      const august = YearMonth(2026, 8);
      const july = YearMonth(2026, 7);
      const june = YearMonth(2026, 6);

      // Every row in `ledger` is already August 2026 (the builder dates them
      // `DateTime(2026, 8, id)`), so only the older rows need spelling out.
      final spread = <ExpenseTxn>[
        ...ledger,
        txn(
          id: 10,
          paymentType: 'HDFC Bank A/C *0444',
          categoryId: 2,
          categoryName: 'Food',
          date: DateTime(2026, 7, 4),
        ),
        txn(
          id: 11,
          paymentType: 'YES BANK Card X2858',
          categoryId: 3,
          categoryName: 'Fuel',
          date: DateTime(2026, 6, 9),
        ),
      ];

      test('no month filter is every month', () {
        expect(idsOf(applyFilters(spread)), <int>[1, 2, 3, 4, 10, 11]);
        expect(idsOf(applyFilters(spread, months: const <YearMonth>{})),
            <int>[1, 2, 3, 4, 10, 11]);
      });

      test('one month keeps only that month', () {
        expect(idsOf(applyFilters(spread, months: <YearMonth>{july})), <int>[10]);
      });

      test('several months are an OR within the facet', () {
        expect(
          idsOf(applyFilters(spread, months: <YearMonth>{july, june})),
          <int>[10, 11],
        );
      });

      test('a month nothing falls in yields an empty list, not everything', () {
        // The heart of the feature: an empty month must read as "nothing here",
        // never as "no filter".
        expect(
          applyFilters(spread, months: <YearMonth>{const YearMonth(2026, 1)}),
          isEmpty,
        );
      });

      test('the boundary days of a month are inside it', () {
        final edges = <ExpenseTxn>[
          txn(id: 20, paymentType: 'X', categoryId: 2, categoryName: 'Food',
              date: DateTime(2026, 8, 1)),
          txn(id: 21, paymentType: 'X', categoryId: 2, categoryName: 'Food',
              date: DateTime(2026, 8, 31, 23, 59, 59)),
          txn(id: 22, paymentType: 'X', categoryId: 2, categoryName: 'Food',
              date: DateTime(2026, 7, 31, 23, 59, 59)),
        ];
        expect(idsOf(applyFilters(edges, months: <YearMonth>{august})),
            <int>[20, 21]);
      });

      test('a month ANDs with a category filter', () {
        expect(
          idsOf(applyFilters(spread,
              months: <YearMonth>{july}, categoryIds: <int>{2})),
          <int>[10],
        );
        expect(
          applyFilters(spread, months: <YearMonth>{july}, categoryIds: <int>{3}),
          isEmpty,
        );
      });

      test('a month ANDs with the search query', () {
        expect(
          idsOf(applyFilters(spread,
              months: <YearMonth>{july}, query: 'MERCHANT 10')),
          <int>[10],
        );
        expect(
          applyFilters(spread,
              months: <YearMonth>{august}, query: 'MERCHANT 10'),
          isEmpty,
        );
      });

      // The month says nothing about categories, so it must not narrow lines.
      test('a matching split keeps its whole breakdown', () {
        final entry =
            applyFilters(<ExpenseTxn>[amazon], months: <YearMonth>{august})
                .single;
        expect(entry.lines, hasLength(3));
        expect(entry.amount, 2000);
      });

      test('a category filter still narrows a split within a month', () {
        final entry = applyFilters(
          <ExpenseTxn>[amazon],
          months: <YearMonth>{august},
          categoryIds: <int>{6},
        ).single;
        expect(entry.amount, 1200);
      });
    });

    group('search query', () {
      final noted = <ExpenseTxn>[
        txn(
          id: 1,
          paymentType: 'YES BANK Card X2858',
          categoryId: 2,
          categoryName: 'Food',
          merchant: 'SWIGGY',
          note: 'Team lunch',
        ),
        txn(
          id: 2,
          paymentType: 'HDFC Bank A/C *0444',
          categoryId: 3,
          categoryName: 'Fuel',
          merchant: 'INDIAN OIL',
          note: 'Trip to Pune',
        ),
        txn(
          id: 3,
          paymentType: 'YES BANK Card X2858',
          categoryId: 2,
          categoryName: 'Food',
          merchant: 'LUNCHBOX',
        ),
      ];

      test('matches note text', () {
        expect(idsOf(applyFilters(noted, query: 'Team')), <int>[1]);
      });

      test('matches merchant text', () {
        expect(idsOf(applyFilters(noted, query: 'INDIAN')), <int>[2]);
      });

      test('is case-insensitive on both', () {
        expect(idsOf(applyFilters(noted, query: 'team LUNCH')), <int>[1]);
        expect(idsOf(applyFilters(noted, query: 'swiggy')), <int>[1]);
      });

      // A row matching on its merchant and one matching on its note are both
      // answers to the same question, and neither is more of one.
      test('matches a note and a merchant in the one pass', () {
        expect(idsOf(applyFilters(noted, query: 'lunch')), <int>[1, 3]);
      });

      test('matches on part of a word, not only on a whole one', () {
        expect(idsOf(applyFilters(noted, query: 'unch')), <int>[1, 3]);
      });

      test('an empty or blank query matches everything', () {
        expect(idsOf(applyFilters(noted, query: '')), <int>[1, 2, 3]);
        expect(idsOf(applyFilters(noted, query: '   ')), <int>[1, 2, 3]);
        expect(idsOf(applyFilters(noted)), <int>[1, 2, 3]);
      });

      test('surrounding whitespace does not stop a match', () {
        expect(idsOf(applyFilters(noted, query: '  Pune ')), <int>[2]);
      });

      test('a query nothing matches yields an empty list', () {
        expect(applyFilters(noted, query: 'zzz'), isEmpty);
      });

      // The query and the chips narrow together; one does not replace the
      // other.
      test('a query ANDs with a category filter', () {
        expect(
          idsOf(applyFilters(noted, query: 'lunch', categoryIds: <int>{2})),
          <int>[1, 3],
        );
        expect(
          applyFilters(noted, query: 'lunch', categoryIds: <int>{3}),
          isEmpty,
        );
      });

      // A search term says nothing about categories, so a split it matches
      // still reports the whole breakdown — only a category filter may narrow
      // which lines survive.
      test('a matching split keeps all of its lines', () {
        final entry = applyFilters(<ExpenseTxn>[amazon], query: 'amazon').single;
        expect(entry.lines, hasLength(3));
        expect(entry.amount, 2000);
      });

      test('a query still leaves a category filter to narrow a split', () {
        final entry = applyFilters(
          <ExpenseTxn>[amazon],
          query: 'amazon',
          categoryIds: <int>{6},
        ).single;
        expect(entry.amount, 1200);
      });

      test('a split whose merchant and note both miss drops out', () {
        expect(applyFilters(<ExpenseTxn>[amazon], query: 'swiggy'), isEmpty);
      });
    });

    group('amountIn', () {
      test('is the full amount with no category filter', () {
        expect(amountIn(amazon, null), 2000);
        expect(amountIn(amazon, <int>{}), 2000);
      });

      test('is the full amount for an unsplit transaction that matches', () {
        expect(amountIn(ledger[0], <int>{2}), 100);
      });

      test('is the matching portion of a split', () {
        expect(amountIn(amazon, <int>{7}), 500);
      });

      test('is zero when nothing matches', () {
        expect(amountIn(amazon, <int>{99}), 0);
      });
    });

    group('spendByCategory', () {
      test('attributes a split across all of its lines', () {
        final breakdown = spendByCategory(applyFilters(<ExpenseTxn>[amazon]));
        expect(breakdown, <String, double>{
          'Grocery': 1200,
          'Snacks': 500,
          'Shopping': 300,
        });
      });

      test('the breakdown sums to what was spent, never more', () {
        final breakdown = spendByCategory(applyFilters(<ExpenseTxn>[amazon]));
        final total = breakdown.values.fold<double>(0, (a, b) => a + b);
        expect(total, amazon.amount);
      });

      test('credits are left out of the breakdown', () {
        // id 4 is the only credit, and the only thing under Salary.
        expect(spendByCategory(applyFilters(ledger)).containsKey('Salary'),
            isFalse);
      });

      test('adds up rows sharing a category', () {
        expect(spendByCategory(applyFilters(ledger))['Food'], 200);
      });
    });

    group('monthOptions', () {
      const august = YearMonth(2026, 8);

      // This is the regression the whole design turns on. On the 1st of a
      // month nothing has landed in it yet; drop it from the options and the
      // selection gets pruned to empty, and empty means EVERY month — so
      // asking for one quiet month would show years.
      test('the current month is offered even when nothing is in it', () {
        expect(monthOptions(const <ExpenseTxn>[], current: august),
            <YearMonth>[august]);
        expect(
          monthOptions(ledger, current: const YearMonth(2027, 3)),
          <YearMonth>[const YearMonth(2027, 3), august],
        );
      });

      test('whatever is selected stays on offer, however stale', () {
        // Without this a user who navigated to a month that has since been
        // emptied could not navigate back out of it.
        expect(
          monthOptions(ledger,
              current: august, keep: <YearMonth>{const YearMonth(2024, 1)}),
          <YearMonth>[august, const YearMonth(2024, 1)],
        );
      });

      test('newest first, de-duplicated', () {
        final spread = <ExpenseTxn>[
          ...ledger, // four rows, all August 2026
          txn(id: 10, paymentType: 'X', categoryId: 2, categoryName: 'Food',
              date: DateTime(2026, 6, 4)),
          txn(id: 11, paymentType: 'X', categoryId: 2, categoryName: 'Food',
              date: DateTime(2026, 7, 4)),
        ];
        expect(
          monthOptions(spread, current: august),
          <YearMonth>[august, const YearMonth(2026, 7), const YearMonth(2026, 6)],
        );
      });

      test('applies the other facets, so it cannot offer a dead end', () {
        final spread = <ExpenseTxn>[
          ...ledger,
          txn(id: 10, paymentType: 'X', categoryId: 3, categoryName: 'Fuel',
              date: DateTime(2026, 6, 4)),
        ];
        // Only the June row is Fuel-and-card-X; August survives only because it
        // is the current month.
        expect(
          monthOptions(spread, current: august, categoryIds: <int>{3},
              paymentTypes: <String>{'X'}),
          <YearMonth>[august, const YearMonth(2026, 6)],
        );
      });
    });

    group('spendByCategoryPerMonth', () {
      test('buckets by month and keeps the category rules', () {
        final spread = <ExpenseTxn>[
          ...ledger, // Food 100 + Food 100 + Fuel 100 + a Salary credit
          txn(id: 10, paymentType: 'X', categoryId: 2, categoryName: 'Food',
              amount: 250, date: DateTime(2026, 7, 4)),
        ];
        final byMonth = spendByCategoryPerMonth(applyFilters(spread));
        expect(byMonth[const YearMonth(2026, 8)],
            <String, double>{'Food': 200, 'Fuel': 100});
        expect(byMonth[const YearMonth(2026, 7)], <String, double>{'Food': 250});
      });

      test('credits are left out, so a month of refunds is absent', () {
        final credits = <ExpenseTxn>[
          txn(id: 4, paymentType: 'X', categoryId: 4, categoryName: 'Salary',
              direction: TxnDirection.credit, date: DateTime(2026, 7, 1)),
        ];
        expect(spendByCategoryPerMonth(applyFilters(credits)),
            <YearMonth, Map<String, double>>{const YearMonth(2026, 7): <String, double>{}});
      });

      test('a split is attributed across its lines in its own month', () {
        expect(
          spendByCategoryPerMonth(applyFilters(<ExpenseTxn>[amazon])),
          <YearMonth, Map<String, double>>{
            const YearMonth(2026, 8): <String, double>{
              'Grocery': 1200,
              'Snacks': 500,
              'Shopping': 300,
            },
          },
        );
      });
    });

    group('periodTotals', () {
      test('separates spend from money in, and counts the rows', () {
        final totals = periodTotals(applyFilters(ledger));
        expect(totals.spent, 300); // Food 100 + Food 100 + Fuel 100
        expect(totals.received, 100); // the Salary credit
        expect(totals.count, 4);
      });

      test('an empty period is all zeroes, not a crash', () {
        final totals = periodTotals(const <LedgerEntry>[]);
        expect(totals.spent, 0);
        expect(totals.received, 0);
        expect(totals.count, 0);
      });

      test('under a category filter it totals only what matched', () {
        final totals =
            periodTotals(applyFilters(<ExpenseTxn>[amazon], categoryIds: <int>{6}));
        expect(totals.spent, 1200);
      });
    });

    group('facet options', () {
      const all = <ExpenseCategory>[
        ExpenseCategory(id: 1, name: 'Uncategorized'),
        ExpenseCategory(id: 2, name: 'Food'),
        ExpenseCategory(id: 3, name: 'Fuel'),
        ExpenseCategory(id: 4, name: 'Salary'),
        ExpenseCategory(id: 5, name: 'Travel'),
        ExpenseCategory(id: 6, name: 'Grocery'),
        ExpenseCategory(id: 7, name: 'Snacks'),
        ExpenseCategory(id: 8, name: 'Shopping'),
      ];

      List<String> namesOf(List<ExpenseCategory> rows) =>
          rows.map((ExpenseCategory c) => c.name).toList();

      test('drops categories no transaction uses', () {
        expect(namesOf(categoryOptions(ledger, all)),
            <String>['Food', 'Fuel', 'Salary']);
      });

      test('keeps the order of the full list', () {
        final shuffled = <ExpenseTxn>[ledger[3], ledger[2], ledger[0]];
        expect(namesOf(categoryOptions(shuffled, all)),
            <String>['Food', 'Fuel', 'Salary']);
      });

      test('a category used only by a credit still counts', () {
        expect(namesOf(categoryOptions(<ExpenseTxn>[ledger[3]], all)),
            <String>['Salary']);
      });

      test('an empty ledger uses no categories', () {
        expect(categoryOptions(<ExpenseTxn>[], all), isEmpty);
      });

      test('a category appearing only as a minor split line is offered', () {
        // Shopping is neither the dominant category nor a whole transaction's
        // — reading `category_id` alone would hide it, and the filter would
        // then be able to match something it never offered.
        expect(
          namesOf(categoryOptions(<ExpenseTxn>[amazon], all)),
          <String>['Grocery', 'Snacks', 'Shopping'],
        );
      });

      test('picking a merchant narrows the categories on offer', () {
        expect(
          namesOf(categoryOptions(
            <ExpenseTxn>[...ledger, amazon],
            all,
            merchants: <String>{'MERCHANT 3'},
          )),
          <String>['Fuel'],
        );
      });

      test('picking a category narrows the merchants on offer', () {
        expect(
          merchantOptions(
            <ExpenseTxn>[...ledger, amazon],
            categoryIds: <int>{7},
          ),
          <String>['AMAZON PAY IN G'],
        );
      });

      test('a facet ignores its own selection, so it cannot empty itself', () {
        // Fuel is only ever on MERCHANT 3. If the merchant facet applied the
        // merchant filter as well, picking MERCHANT 3 would leave the merchant
        // list holding only the row already chosen — and picking a second
        // merchant would become impossible.
        expect(
          merchantOptions(ledger, categoryIds: <int>{2}),
          <String>['MERCHANT 1', 'MERCHANT 2'],
        );
      });
    });

    group('pruneSelection', () {
      test('drops what is no longer available', () {
        expect(pruneSelection(<int>{1, 2, 3}, <int>[2, 3, 4]), <int>{2, 3});
      });

      test('keeps everything when all of it survives', () {
        expect(pruneSelection(<int>{1, 2}, <int>[1, 2, 3]), <int>{1, 2});
      });

      test('an empty selection stays empty', () {
        expect(pruneSelection(<int>{}, <int>[1]), isEmpty);
      });
    });
  });

  group('merging duplicate names', () {
    /// The labels the emulator's ledger actually holds — one account and one
    /// card each split across templates, plus names that must stay apart.
    const List<String> cards = <String>[
      'BANK A/c XX0444',
      'HDFC Bank A/C *0444',
      'HDFC Bank A/c XX0444',
      'BANK Card XX8008',
      'ICICI Bank Card XX8008',
      'YES BANK Card X2858',
      'HDFC Bank Card 6824',
      'HDFC Bank Card x2227',
    ];

    NameAliases aliasesOf(NameKind kind, Map<String, String> rows) =>
        NameAliases.fromRows(<Map<String, Object?>>[
          for (final MapEntry<String, String> e in rows.entries)
            <String, Object?>{
              'kind': kind.column,
              'alias': e.key,
              'canonical': e.value,
            },
        ]);

    group('NameAliases', () {
      final aliases = aliasesOf(NameKind.card, <String, String>{
        'bank a/c xx0444': 'HDFC 0444',
        'hdfc bank a/c *0444': 'HDFC 0444',
      });

      test('a name nothing was merged into resolves to itself', () {
        expect(aliases.resolve(NameKind.card, 'YES BANK Card X2858'),
            'YES BANK Card X2858');
      });

      test('an alias resolves to what it was merged into', () {
        expect(aliases.resolve(NameKind.card, 'BANK A/c XX0444'), 'HDFC 0444');
      });

      test('resolution ignores case, as the column does', () {
        expect(aliases.resolve(NameKind.card, 'HDFC Bank A/C *0444'),
            'HDFC 0444');
      });

      test('a kind is not confused with the other one', () {
        expect(aliases.resolve(NameKind.merchant, 'BANK A/c XX0444'),
            'BANK A/c XX0444');
      });

      test('membersOf covers the aliases and the canonical itself', () {
        expect(
          aliases.membersOf(NameKind.card, 'HDFC 0444'),
          <String>{'HDFC 0444', 'bank a/c xx0444', 'hdfc bank a/c *0444'},
        );
      });

      test('membersOf an unmerged name is just that name', () {
        expect(aliases.membersOf(NameKind.card, 'HDFC Bank Card 6824'),
            <String>{'HDFC Bank Card 6824'});
      });
    });

    group('mergePlan', () {
      test('folds a fresh set under the new name', () {
        final plan = mergePlan(
          const <String, String>{},
          <String>{'BANK A/c XX0444', 'HDFC Bank A/c XX0444'},
          'HDFC 0444',
        );
        expect(plan, <String, String>{
          'bank a/c xx0444': 'HDFC 0444',
          'hdfc bank a/c xx0444': 'HDFC 0444',
        });
      });

      test('a name is never made an alias of itself', () {
        // Keeping the winning spelling is the common case, and a self-alias
        // would be a one-hop loop.
        final plan = mergePlan(
          const <String, String>{},
          <String>{'RAPIDO', 'Rapido'},
          'RAPIDO',
        );
        expect(plan, <String, String>{'rapido': 'RAPIDO'});
      });

      test('merging a merge carries its earlier members along', () {
        // The heart of it: M1 and M2 already point at Rapido. Folding Rapido
        // into a new name has to re-point them too, or they resurface the
        // moment Rapido stops being a canonical.
        final first = mergePlan(
          const <String, String>{},
          <String>{'M1', 'M2'},
          'Rapido',
        );
        final second = mergePlan(first, <String>{'Rapido', 'M3'}, 'Rapido Rides');

        expect(second, <String, String>{
          'm1': 'Rapido Rides',
          'm2': 'Rapido Rides',
          'm3': 'Rapido Rides',
          'rapido': 'Rapido Rides',
        });
      });

      test('after a chained merge nothing resolves in two hops', () {
        final first = mergePlan(const <String, String>{}, <String>{'M1', 'M2'}, 'Rapido');
        final second = mergePlan(first, <String>{'Rapido', 'M3'}, 'Rapido Rides');

        // The property that matters is idempotence: resolving a canonical
        // hands back that same canonical, so no lookup ever needs a second
        // one. A canonical *may* appear as a key — 'rapido' -> 'RAPIDO' is
        // how a case-only merge holds its chosen spelling — and that is fine
        // precisely because it still resolves to itself.
        for (final String canonical in second.values) {
          expect(second[canonical.toLowerCase()] ?? canonical, canonical,
              reason: '$canonical does not resolve to itself');
        }
      });

      test('an unrelated earlier merge is left alone', () {
        final existing = mergePlan(
            const <String, String>{}, <String>{'A1', 'A2'}, 'Alpha');
        final plan = mergePlan(existing, <String>{'B1', 'B2'}, 'Beta');
        expect(plan['a1'], 'Alpha');
        expect(plan['a2'], 'Alpha');
        expect(plan['b1'], 'Beta');
      });

      test('the new name is trimmed of nothing the caller left behind', () {
        // mergePlan takes the name as given; trimming is the caller's job and
        // AppDatabase.mergeNames does it. Guards against double-trimming.
        final plan = mergePlan(const <String, String>{}, <String>{'X', 'Y'}, 'Z');
        expect(plan.values.toSet(), <String>{'Z'});
      });
    });

    group('suggestGroups', () {
      test('groups cards by their trailing digits', () {
        expect(suggestGroups(cards, NameKind.card), <List<String>>[
          <String>['BANK A/c XX0444', 'HDFC Bank A/C *0444', 'HDFC Bank A/c XX0444'],
          <String>['BANK Card XX8008', 'ICICI Bank Card XX8008'],
        ]);
      });

      test('a card sharing no digits with another is not suggested', () {
        final flat = suggestGroups(cards, NameKind.card).expand((g) => g);
        expect(flat, isNot(contains('YES BANK Card X2858')));
        expect(flat, isNot(contains('HDFC Bank Card 6824')));
      });

      test('nothing to group yields nothing', () {
        expect(suggestGroups(<String>['YES BANK Card X2858'], NameKind.card),
            isEmpty);
      });

      test('a UPI tag does not make a merchant a different shop', () {
        expect(
          suggestGroups(
            <String>['UPI_GEORGE EGG CENTRE', 'GEORGE EGG CENTRE', 'SWIGGY'],
            NameKind.merchant,
          ),
          <List<String>>[
            <String>['GEORGE EGG CENTRE', 'UPI_GEORGE EGG CENTRE'],
          ],
        );
      });

      test('merchants differing only in case and punctuation group', () {
        expect(
          suggestGroups(<String>['RAPIDO', 'Rapido.', 'Zomato'],
              NameKind.merchant),
          <List<String>>[
            <String>['RAPIDO', 'Rapido.'],
          ],
        );
      });

      test('genuinely different merchants stay apart', () {
        expect(
          suggestGroups(<String>['SWIGGY INSTAMART', 'BIG BAZAAR GROCERY'],
              NameKind.merchant),
          isEmpty,
        );
      });
    });

    group('canonicaliseLedger', () {
      ExpenseTxn txn({
        required int id,
        required String merchant,
        required String paymentType,
      }) =>
          ExpenseTxn(
            id: id,
            amount: 100,
            paymentType: paymentType,
            merchant: merchant,
            date: DateTime(2026, 8, id),
            categoryId: 2,
            categoryName: 'Food',
            direction: TxnDirection.debit,
            reference: '',
          );

      test('applies aliases to both names', () {
        final out = canonicaliseLedger(
          <ExpenseTxn>[
            txn(id: 1, merchant: 'M1', paymentType: 'BANK A/c XX0444'),
          ],
          NameAliases.fromRows(<Map<String, Object?>>[
            <String, Object?>{
              'kind': 'merchant',
              'alias': 'm1',
              'canonical': 'Rapido'
            },
            <String, Object?>{
              'kind': 'payment_type',
              'alias': 'bank a/c xx0444',
              'canonical': 'HDFC 0444'
            },
          ]),
        );
        expect(out.single.merchant, 'Rapido');
        expect(out.single.paymentType, 'HDFC 0444');
      });

      test('keeps the stored spellings, which are still the row key', () {
        final out = canonicaliseLedger(
          <ExpenseTxn>[
            txn(id: 1, merchant: 'M1', paymentType: 'BANK A/c XX0444'),
          ],
          aliasesOf(NameKind.merchant, <String, String>{'m1': 'Rapido'}),
        );
        expect(out.single.rawMerchant, 'M1');
        expect(out.single.rawPaymentType, 'BANK A/c XX0444');
      });

      test('case-only merchant variants fold onto the most common spelling',
          () {
        final out = canonicaliseLedger(
          <ExpenseTxn>[
            txn(id: 1, merchant: 'RAPIDO', paymentType: 'X'),
            txn(id: 2, merchant: 'RAPIDO', paymentType: 'X'),
            txn(id: 3, merchant: 'Rapido', paymentType: 'X'),
          ],
          NameAliases.empty,
        );
        // Two RAPIDO to one Rapido — the majority spelling wins, not the
        // alphabetically-first one, which would have been 'RAPIDO' here by
        // luck. See the tie test below for the distinction.
        expect(out.map((ExpenseTxn t) => t.merchant),
            everyElement('RAPIDO'));
      });

      test('the majority wins even when it sorts last', () {
        final out = canonicaliseLedger(
          <ExpenseTxn>[
            txn(id: 1, merchant: 'Rapido', paymentType: 'X'),
            txn(id: 2, merchant: 'Rapido', paymentType: 'X'),
            txn(id: 3, merchant: 'RAPIDO', paymentType: 'X'),
          ],
          NameAliases.empty,
        );
        expect(out.map((ExpenseTxn t) => t.merchant), everyElement('Rapido'));
      });

      test('an even split falls back to alphabetical, not row order', () {
        final out = canonicaliseLedger(
          <ExpenseTxn>[
            txn(id: 1, merchant: 'Rapido', paymentType: 'X'),
            txn(id: 2, merchant: 'RAPIDO', paymentType: 'X'),
          ],
          NameAliases.empty,
        );
        expect(out.map((ExpenseTxn t) => t.merchant), everyElement('RAPIDO'));
      });

      test('payment types are not case-folded, only merged', () {
        // Cards are merged deliberately, never guessed at: two labels that
        // differ only in case are still two until the user says otherwise.
        final out = canonicaliseLedger(
          <ExpenseTxn>[
            txn(id: 1, merchant: 'A', paymentType: 'HDFC Bank A/c XX0444'),
            txn(id: 2, merchant: 'A', paymentType: 'HDFC BANK A/C XX0444'),
          ],
          NameAliases.empty,
        );
        expect(out.map((ExpenseTxn t) => t.paymentType).toSet(), hasLength(2));
      });

      test('an empty ledger stays empty', () {
        expect(canonicaliseLedger(<ExpenseTxn>[], NameAliases.empty), isEmpty);
      });
    });
  });

  group('sortEntries', () {
    ExpenseTxn txn({
      required int id,
      required String merchant,
      required DateTime date,
      double amount = 100,
      List<TxnSplit> splits = const <TxnSplit>[],
    }) =>
        ExpenseTxn(
          id: id,
          amount: amount,
          paymentType: 'YES BANK Card X2858',
          merchant: merchant,
          date: date,
          categoryId: 2,
          categoryName: 'Food',
          direction: TxnDirection.debit,
          reference: '',
          splits: splits,
        );

    LedgerEntry entryOf(ExpenseTxn t) =>
        LedgerEntry(txn: t, lines: t.effectiveSplits);

    final zomato = txn(
      id: 1,
      merchant: 'ZOMATO',
      date: DateTime(2026, 8, 1),
      amount: 500,
    );
    final blinkit = txn(
      id: 2,
      merchant: 'blinkit',
      date: DateTime(2026, 8, 3),
      amount: 100,
    );
    final amazon = txn(
      id: 3,
      merchant: 'AMAZON',
      date: DateTime(2026, 8, 2),
      amount: 2000,
    );

    final ledger = <LedgerEntry>[
      entryOf(zomato),
      entryOf(blinkit),
      entryOf(amazon),
    ];

    List<int> idsOf(List<LedgerEntry> rows) =>
        rows.map((LedgerEntry e) => e.txn.id).toList();

    test('newest first is the default reading of the ledger', () {
      expect(idsOf(sortEntries(ledger, LedgerSort.newest)), <int>[2, 3, 1]);
    });

    test('oldest first is the exact reverse', () {
      expect(idsOf(sortEntries(ledger, LedgerSort.oldest)), <int>[1, 3, 2]);
    });

    test('largest first orders by amount, not date', () {
      expect(idsOf(sortEntries(ledger, LedgerSort.largest)), <int>[3, 1, 2]);
    });

    test('smallest first is the other way up', () {
      expect(idsOf(sortEntries(ledger, LedgerSort.smallest)), <int>[2, 1, 3]);
    });

    test('merchant order ignores case', () {
      // blinkit is lower-case: sorting on the raw string would put it last,
      // after both capitalised names.
      expect(idsOf(sortEntries(ledger, LedgerSort.merchant)), <int>[3, 2, 1]);
    });

    test('the input list is left alone', () {
      sortEntries(ledger, LedgerSort.largest);
      expect(idsOf(ledger), <int>[1, 2, 3]);
    });

    group('ties', () {
      final sameDay = <LedgerEntry>[
        entryOf(txn(id: 10, merchant: 'A', date: DateTime(2026, 8, 5))),
        entryOf(txn(id: 11, merchant: 'A', date: DateTime(2026, 8, 5))),
        entryOf(txn(id: 12, merchant: 'A', date: DateTime(2026, 8, 5))),
      ];

      test('newest first breaks a shared timestamp by id, highest first', () {
        expect(idsOf(sortEntries(sameDay, LedgerSort.newest)), <int>[12, 11, 10]);
      });

      test('oldest first breaks it the other way, so it is a true reverse', () {
        expect(idsOf(sortEntries(sameDay, LedgerSort.oldest)), <int>[10, 11, 12]);
      });

      test('equal amounts fall back to newest first', () {
        expect(
          idsOf(sortEntries(sameDay, LedgerSort.largest)),
          <int>[12, 11, 10],
        );
      });
    });

    group('under a category filter', () {
      /// A ₹2,000 order whose grocery line is smaller than a ₹700 standalone
      /// charge, though the order as a whole is far bigger.
      final order = txn(
        id: 20,
        merchant: 'AMAZON PAY IN G',
        date: DateTime(2026, 8, 10),
        amount: 2000,
        splits: const <TxnSplit>[
          TxnSplit(categoryId: 6, categoryName: 'Grocery', amount: 400),
          TxnSplit(categoryId: 7, categoryName: 'Snacks', amount: 1600),
        ],
      );
      final corner = txn(
        id: 21,
        merchant: 'CORNER STORE',
        date: DateTime(2026, 8, 11),
        amount: 700,
      );

      test('amount sorts use the shown portion, not the whole charge', () {
        // Narrowed to Grocery, the order contributes 400 — less than the 700
        // beside it — so it sorts below, despite being a ₹2,000 transaction.
        final narrowed = applyFilters(
          <ExpenseTxn>[order, corner],
          categoryIds: <int>{6, 2},
        );
        expect(idsOf(sortEntries(narrowed, LedgerSort.largest)), <int>[21, 20]);
      });

      test('unfiltered, the same two sort the other way round', () {
        final all = applyFilters(<ExpenseTxn>[order, corner]);
        expect(idsOf(sortEntries(all, LedgerSort.largest)), <int>[20, 21]);
      });
    });
  });

  group('split arithmetic', () {
    test('the balance of a fresh split is the whole charge', () {
      expect(unallocated(<double>[0], 2000), 2000);
    });

    test('typing the first line leaves the rest for the second', () {
      // 2,000 with 1,200 against Grocery leaves 800.
      expect(withRemainderInLast(<double>[1200, 0], 2000).last, 800);
    });

    test('a third line takes what the first two leave', () {
      // 1,200 and 300 of 2,000 leaves 500 for the row just added.
      expect(withRemainderInLast(<double>[1200, 300, 0], 2000).last, 500);
    });

    test('the rows above the last are left exactly as typed', () {
      expect(
        withRemainderInLast(<double>[1200, 300, 999], 2000),
        <double>[1200, 300, 500],
      );
    });

    test('over-allocating drives the last line negative', () {
      expect(withRemainderInLast(<double>[1800, 400, 0], 2000).last, -200);
      expect(unallocated(<double>[1800, 400], 2000), -200);
    });

    test('lines that add up are balanced', () {
      expect(isBalanced(<double>[1200, 500, 300], 2000), isTrue);
    });

    test('lines that fall short or overshoot are not', () {
      expect(isBalanced(<double>[1200, 500], 2000), isFalse);
      expect(isBalanced(<double>[1200, 900], 2000), isFalse);
    });

    test('no lines at all is never balanced', () {
      expect(isBalanced(<double>[], 0), isFalse);
    });

    test('a single line covering the charge is balanced', () {
      expect(isBalanced(<double>[2000], 2000), isTrue);
    });

    test('paise-level drift is tolerated', () {
      // Ten paise three ways cannot land exactly in binary floating point.
      final third = 0.1 / 3;
      expect(isBalanced(<double>[third, third, third], 0.1), isTrue);
    });

    test('the last line absorbs the drift, so the stored set sums exactly', () {
      final third = 0.1 / 3;
      final exact = withRemainderInLast(<double>[third, third, third], 0.1);
      expect(exact.fold<double>(0, (a, b) => a + b), 0.1);
    });

    test('a rupee out is not drift', () {
      expect(isBalanced(<double>[1999], 2000), isFalse);
    });
  });

  group('encodeSplits / decodeSplits', () {
    const lines = <TxnSplit>[
      TxnSplit(categoryId: 6, categoryName: 'Grocery', amount: 1200),
      TxnSplit(categoryId: 8, categoryName: 'Shopping', amount: 800),
    ];

    test('round-trips through the tombstone', () {
      final restored = decodeSplits(encodeSplits(lines));
      expect(restored, hasLength(2));
      expect(restored.first.categoryId, 6);
      expect(restored.first.categoryName, 'Grocery');
      expect(restored.first.amount, 1200);
      expect(restored.last.amount, 800);
    });

    test('no splits encode to null, keeping the column empty', () {
      expect(encodeSplits(const <TxnSplit>[]), isNull);
    });

    test('a tombstone written before v5 decodes to no splits', () {
      expect(decodeSplits(null), isEmpty);
      expect(decodeSplits(''), isEmpty);
    });

    test('unreadable payload decodes to no splits rather than throwing', () {
      // Coming back whole under one category is recoverable; throwing on the
      // way out of the Deleted screen is not.
      expect(decodeSplits('not json'), isEmpty);
      expect(decodeSplits('{"not":"a list"}'), isEmpty);
    });
  });

  group('comparedMonths', () {
    test('runs oldest first, whatever order they were picked in', () {
      expect(
        comparedMonths(
            <YearMonth>{const YearMonth(2026, 8), const YearMonth(2026, 7)}),
        <YearMonth>[const YearMonth(2026, 7), const YearMonth(2026, 8)],
      );
    });

    test('sorts across a year boundary', () {
      expect(
        comparedMonths(
            <YearMonth>{const YearMonth(2026, 2), const YearMonth(2025, 12)}),
        <YearMonth>[const YearMonth(2025, 12), const YearMonth(2026, 2)],
      );
    });

    // An unpicked month between two picked ones is not a zero — it is a month
    // nobody asked about, and a zero bar would claim no spend.
    test('does not invent the months between the ones picked', () {
      expect(
        comparedMonths(
            <YearMonth>{const YearMonth(2026, 3), const YearMonth(2026, 6)}),
        <YearMonth>[const YearMonth(2026, 3), const YearMonth(2026, 6)],
      );
    });

    test('no selection is no series', () {
      expect(comparedMonths(const <YearMonth>{}), isEmpty);
    });
  });

  group('topCategories', () {
    test('ranks descending with shares that sum to one', () {
      final slices = topCategories(<String, double>{
        'Food': 300,
        'Fuel': 100,
        'Grocery': 600,
      });
      expect(slices.map((CategorySlice s) => s.name), <String>['Grocery', 'Food', 'Fuel']);
      expect(slices.first.share, closeTo(0.6, 0.0001));
      expect(
        slices.fold<double>(0, (double sum, CategorySlice s) => sum + s.share),
        closeTo(1, 0.0001),
      );
    });

    test('a breakdown within the cap invents no Other', () {
      final slices = topCategories(<String, double>{'Food': 300, 'Fuel': 100});
      expect(slices, hasLength(2));
      expect(slices.map((CategorySlice s) => s.name), isNot(contains('Other')));
    });

    test('the tail folds into one Other, and the total stays honest', () {
      final slices = topCategories(<String, double>{
        'A': 100, 'B': 90, 'C': 80, 'D': 70, 'E': 60, 'F': 50, 'G': 40, 'H': 30,
      });
      expect(slices, hasLength(6));
      expect(slices.last.name, 'Other');
      expect(slices.last.amount, 120); // F + G + H
      expect(
        slices.fold<double>(0, (double sum, CategorySlice s) => sum + s.amount),
        520, // the whole of it — nothing dropped
      );
    });

    test('respects a different limit', () {
      final slices = topCategories(
        <String, double>{'A': 100, 'B': 90, 'C': 80, 'D': 70},
        limit: 3,
      );
      expect(slices, hasLength(3));
      expect(slices.last.name, 'Other');
      expect(slices.last.amount, 150); // C + D
    });

    test('nothing spent is no slices, not a division by zero', () {
      expect(topCategories(const <String, double>{}), isEmpty);
      expect(topCategories(<String, double>{'Food': 0}), isEmpty);
    });
  });

  group('emptyReason', () {
    const august = YearMonth(2026, 8);

    test('an empty ledger outranks every filter', () {
      expect(
        emptyReason(
          LedgerFilters(months: <YearMonth>{august}, query: 'swiggy'),
          ledgerIsEmpty: true,
        ),
        EmptyReason.ledgerEmpty,
      );
    });

    // The month is always in force, so blaming it first would blame it for
    // everything — and send the user off to change the wrong thing.
    test('a search term is blamed before the month', () {
      expect(
        emptyReason(
          LedgerFilters(months: <YearMonth>{august}, query: 'zzz'),
          ledgerIsEmpty: false,
        ),
        EmptyReason.search,
      );
    });

    test('a chip is blamed before the month', () {
      expect(
        emptyReason(
          LedgerFilters(months: <YearMonth>{august}, categoryIds: const <int>{2}),
          ledgerIsEmpty: false,
        ),
        EmptyReason.facets,
      );
    });

    test('the month is blamed only when nothing else narrows anything', () {
      expect(
        emptyReason(
          LedgerFilters(months: <YearMonth>{august}),
          ledgerIsEmpty: false,
        ),
        EmptyReason.month,
      );
    });

    test('whitespace in the search box is not a search', () {
      expect(
        emptyReason(
          LedgerFilters(months: <YearMonth>{august}, query: '   '),
          ledgerIsEmpty: false,
        ),
        EmptyReason.month,
      );
    });
  });

  group('cleanNote', () {
    test('keeps an ordinary note as it was typed', () {
      expect(cleanNote('Team lunch with the QA folks'),
          'Team lunch with the QA folks');
    });

    test('trims the ends', () {
      expect(cleanNote('  Team lunch  '), 'Team lunch');
    });

    // A note pasted out of a chat arrives with line breaks in it. The tile
    // shows one line, so the breaks are flattened on the way in rather than
    // left for every reader of the field to cope with.
    test('collapses inner runs of whitespace onto single spaces', () {
      expect(cleanNote('Team    lunch'), 'Team lunch');
      expect(cleanNote('Team\nlunch'), 'Team lunch');
      expect(cleanNote('Team \t\n lunch'), 'Team lunch');
    });

    test('a whitespace-only note is no note at all', () {
      expect(cleanNote(''), '');
      expect(cleanNote('   '), '');
      expect(cleanNote('\n\t'), '');
    });

    test('caps a long note at 140 characters', () {
      final String long = 'a' * 200;
      expect(cleanNote(long), hasLength(140));
    });

    test('a note of exactly the cap is left alone', () {
      final String exact = 'b' * 140;
      expect(cleanNote(exact), exact);
    });

    // Cutting mid-sentence can land on a space, and a note ending in one would
    // render with a gap before the ellipsis.
    test('a cut that lands on a space does not leave one trailing', () {
      final String long = '${'a' * 139} tail';
      expect(cleanNote(long), 'a' * 139);
    });

    test('is idempotent — cleaning a stored note changes nothing', () {
      const String raw = '  Trip   to \n Pune  ';
      expect(cleanNote(cleanNote(raw)), cleanNote(raw));
    });
  });

  group('CategoryUsage', () {
    CategoryUsage usage({
      int unsplit = 0,
      int split = 0,
      int defaults = 0,
    }) =>
        CategoryUsage.fromMap(<String, Object?>{
          'id': 4,
          'name': 'Food',
          'unsplit_count': unsplit,
          'split_count': split,
          'merchant_default_count': defaults,
        });

    test('reads the row the usage query returns', () {
      final CategoryUsage food = usage(unsplit: 7, split: 2, defaults: 1);
      expect(food.category.id, 4);
      expect(food.category.name, 'Food');
      expect(food.unsplitCount, 7);
      expect(food.splitCount, 2);
      expect(food.merchantDefaultCount, 1);
    });

    // The two counts come from queries that cannot both see the same row — one
    // takes transactions with no split lines, the other only ones with them —
    // so the total a delete quotes is their sum and not a guess at an overlap.
    test('the transaction count is the unsplit and the split ones together', () {
      expect(usage(unsplit: 7, split: 2).txnCount, 9);
      expect(usage(unsplit: 7).txnCount, 7);
      expect(usage(split: 2).txnCount, 2);
      expect(usage().txnCount, 0);
    });

    test('a category nothing points at is not in use', () {
      expect(usage().inUse, isFalse);
    });

    // Each of the three on its own is enough to make a delete a move rather
    // than a plain removal. A merchant default especially: it names no
    // transaction, so counting only those would drop it silently.
    test('any one thing pointing at it counts as in use', () {
      expect(usage(unsplit: 1).inUse, isTrue);
      expect(usage(split: 1).inUse, isTrue);
      expect(usage(defaults: 1).inUse, isTrue);
    });
  });

  // What decides whether the ledger's "Clear all" chip is live or dead, and
  // what it hands back when pressed.
  group('LedgerFilters.isDefaultFor', () {
    const YearMonth august = YearMonth(2026, 8);
    const YearMonth july = YearMonth(2026, 7);

    test('this month and nothing else is the resting state', () {
      expect(LedgerFilters.defaults(august).isDefaultFor(august), isTrue);
    });

    // The asymmetry the chip depends on: an empty month set means *every* month,
    // which is `isEmpty` but is the opposite of resting — and is precisely the
    // state a user most needs a way back from.
    test('widened to all months is not resting, though it is empty', () {
      const LedgerFilters all = LedgerFilters();
      expect(all.isEmpty, isTrue);
      expect(all.isDefaultFor(august), isFalse);
    });

    test('some other month is not resting', () {
      expect(LedgerFilters.defaults(july).isDefaultFor(august), isFalse);
      expect(
        LedgerFilters(months: <YearMonth>{august, july}).isDefaultFor(august),
        isFalse,
      );
    });

    test('any one facet narrowing anything is not resting', () {
      for (final LedgerFilters filters in <LedgerFilters>[
        LedgerFilters(months: <YearMonth>{august}, categoryIds: <int>{3}),
        LedgerFilters(months: <YearMonth>{august}, merchants: <String>{'Amazon'}),
        LedgerFilters(months: <YearMonth>{august}, paymentTypes: <String>{'HDFC'}),
        LedgerFilters(months: <YearMonth>{august}, query: 'fuel'),
      ]) {
        expect(filters.isDefaultFor(august), isFalse);
      }
    });

    test('clearing drops every facet, the search box included', () {
      final LedgerFilters busy = LedgerFilters(
        months: <YearMonth>{july},
        categoryIds: <int>{3, 4},
        merchants: <String>{'Amazon'},
        paymentTypes: <String>{'HDFC Bank A/c *0444'},
        query: 'fuel',
      );
      expect(busy.isDefaultFor(august), isFalse);

      final LedgerFilters cleared = LedgerFilters.defaults(august);
      expect(cleared.isDefaultFor(august), isTrue);
      expect(cleared.categoryIds, isEmpty);
      expect(cleared.merchants, isEmpty);
      expect(cleared.paymentTypes, isEmpty);
      expect(cleared.query, isEmpty);
      expect(cleared.months, <YearMonth>{august});
    });
  });

  group('backup workbook', () {
    /// A database with one of everything awkward in it: a split transaction, a
    /// credit, a null card, an empty note and an empty reference, a merchant
    /// that has been merged, a tombstone carrying splits, and a tombstone from
    /// before schema v4 with nulls in every optional column.
    BackupData sample() => BackupData(
          meta: <String, String>{
            'format': kBackupFormat,
            'format_version': '$kBackupFormatVersion',
            'schema_version': '$kSchemaVersion',
            'app_version': '1.1.0',
            'exported_at': '2026-08-17T14:32:10+05:30',
          },
          appMeta: <Map<String, Object?>>[
            <String, Object?>{
              'key': 'last_scanned_sms_date',
              'value': '1755417600000',
            },
          ],
          categories: <Map<String, Object?>>[
            <String, Object?>{'id': 1, 'name': 'Uncategorized', 'icon': ''},
            <String, Object?>{'id': 2, 'name': 'Grocery', 'icon': ''},
            <String, Object?>{'id': 3, 'name': 'Food', 'icon': ''},
          ],
          merchantMappings: <Map<String, Object?>>[
            <String, Object?>{'merchant_name': 'SWIGGY', 'category_id': 3},
          ],
          transactions: <Map<String, Object?>>[
            // A whole-rupee amount, which the excel package writes as "204.0"
            // and reads back as an int. The one that would break quietly.
            <String, Object?>{
              'id': 1,
              'amount': 204.0,
              'payment_type': 'YES BANK Card X2858',
              'merchant': 'UPI_GEORGE EGG CENTRE',
              'date': 1755070895000,
              'category_id': 2,
              'direction': 'debit',
              'reference': '',
              'note': '',
            },
            // Split across two categories, and a credit, and no card at all.
            <String, Object?>{
              'id': 2,
              'amount': 2000.0,
              'payment_type': null,
              'merchant': 'Big Bazaar',
              'date': 1755157295000,
              'category_id': 2,
              'direction': 'credit',
              'reference': 'UPI/123456789',
              'note': 'Split with Ravi',
            },
          ],
          splits: <Map<String, Object?>>[
            <String, Object?>{
              'id': 1,
              'transaction_id': 2,
              'category_id': 2,
              'amount': 1200.0,
              'position': 0,
            },
            <String, Object?>{
              'id': 2,
              'transaction_id': 2,
              'category_id': 3,
              'amount': 800.0,
              'position': 1,
            },
          ],
          deleted: <Map<String, Object?>>[
            <String, Object?>{
              'amount': 99.5,
              'merchant': 'Zomato',
              'date': 1754000000000,
              'direction': 'debit',
              'reference': 'UPI/999',
              'payment_type': 'HDFC Bank A/c *0444',
              'category_id': 3,
              'original_id': 17,
              'deleted_at': 1755200000000,
              'splits_json':
                  '[{"category_id":3,"name":"Food","amount":99.5}]',
              'note': 'ordered twice',
            },
            // Written by schema v3: everything optional is genuinely absent.
            <String, Object?>{
              'amount': 12.0,
              'merchant': 'Unknown Shop',
              'date': 1753000000000,
              'direction': 'debit',
              'reference': '',
              'payment_type': null,
              'category_id': null,
              'original_id': null,
              'deleted_at': null,
              'splits_json': null,
              'note': null,
            },
          ],
          aliases: <Map<String, Object?>>[
            <String, Object?>{
              'kind': 'merchant',
              'alias': 'swiggy ltd',
              'canonical': 'Swiggy',
            },
            <String, Object?>{
              'kind': 'payment_type',
              'alias': 'hdfc bank a/c *0444',
              'canonical': 'HDFC *0444',
            },
          ],
        );

    BackupData roundTrip(BackupData data) =>
        decodeBackupWorkbook(encodeBackupWorkbook(data));

    test('every row survives a round trip unchanged', () {
      final BackupData before = sample();
      final BackupData after = roundTrip(before);

      expect(after.categories, before.categories);
      expect(after.merchantMappings, before.merchantMappings);
      expect(after.transactions, before.transactions);
      expect(after.splits, before.splits);
      expect(after.deleted, before.deleted);
      expect(after.aliases, before.aliases);
      expect(after.appMeta, before.appMeta);
      expect(after.meta['format'], kBackupFormat);
      expect(after.schemaVersion, 8);
    });

    // The one that would fail silently. `transactions.amount` is a REAL that
    // sits inside a UNIQUE index, and `deleted_transactions` repeats it as part
    // of its PRIMARY KEY. An amount that comes back as a different double stops
    // a tombstone matching its transaction, and a rescan quietly resurrects a
    // row the user deleted.
    test('an awkward amount keeps every bit of its precision', () {
      const double awkward = 1234.5678901234567;
      final BackupData before = sample();
      final BackupData data = BackupData(
        meta: before.meta,
        appMeta: before.appMeta,
        categories: before.categories,
        merchantMappings: before.merchantMappings,
        splits: const <Map<String, Object?>>[],
        aliases: before.aliases,
        transactions: <Map<String, Object?>>[
          <String, Object?>{
            'id': 1,
            'amount': awkward,
            'payment_type': 'Card',
            'merchant': 'Odd Shop',
            'date': 1755070895000,
            'category_id': 1,
            'direction': 'debit',
            'reference': 'R1',
            'note': '',
          },
        ],
        deleted: <Map<String, Object?>>[
          <String, Object?>{
            'amount': awkward,
            'merchant': 'Odd Shop',
            'date': 1755070895000,
            'direction': 'debit',
            'reference': 'R1',
            'payment_type': 'Card',
            'category_id': 1,
            'original_id': 1,
            'deleted_at': 1755200000000,
            'splits_json': null,
            'note': null,
          },
        ],
      );

      final BackupData after = roundTrip(data);
      expect(after.transactions.single['amount'], awkward);
      expect(after.deleted.single['amount'], awkward);
      // And the two still agree, which is the thing that actually matters.
      expect(
        after.transactions.single['amount'] == after.deleted.single['amount'],
        isTrue,
      );
    });

    test('a whole-rupee amount comes back as a double, not an int', () {
      final BackupData after = roundTrip(sample());
      expect(after.transactions.first['amount'], isA<double>());
      expect(after.transactions.first['amount'], 204.0);
      expect(after.splits.first['amount'], isA<double>());
    });

    test('case is preserved exactly on merchants, aliases and categories', () {
      final BackupData after = roundTrip(sample());
      expect(after.transactions.first['merchant'], 'UPI_GEORGE EGG CENTRE');
      expect(after.merchantMappings.single['merchant_name'], 'SWIGGY');
      // Aliases are stored already-lowercased; export must not "tidy" them.
      expect(after.aliases.first['alias'], 'swiggy ltd');
      expect(after.aliases.first['canonical'], 'Swiggy');
    });

    test('an empty database round trips', () {
      final BackupData empty = BackupData(
        meta: <String, String>{
          'format': kBackupFormat,
          'format_version': '$kBackupFormatVersion',
          'schema_version': '7',
        },
        appMeta: const <Map<String, Object?>>[],
        categories: <Map<String, Object?>>[
          <String, Object?>{'id': 1, 'name': 'Uncategorized'},
        ],
        merchantMappings: const <Map<String, Object?>>[],
        transactions: const <Map<String, Object?>>[],
        splits: const <Map<String, Object?>>[],
        deleted: const <Map<String, Object?>>[],
        aliases: const <Map<String, Object?>>[],
      );
      final BackupData after = roundTrip(empty);
      expect(after.transactions, isEmpty);
      expect(after.categories, hasLength(1));
      expect(validateBackup(after, appSchemaVersion: 7), isEmpty);
    });

    test('exporting what was imported changes nothing', () {
      final BackupData once = roundTrip(sample());
      final BackupData twice = roundTrip(once);
      expect(twice.transactions, once.transactions);
      expect(twice.deleted, once.deleted);
      expect(twice.appMeta, once.appMeta);
    });

    /// Rewrites the sample workbook, passing every row of [sheetName] — header
    /// row included, at index 0 — through [transform], and appending [extra]
    /// rows to the end.
    ///
    /// Sheets are rebuilt rather than edited in place because the excel
    /// package's `insertColumn` and `removeColumn` silently empty a sheet that
    /// came from `decodeBytes`, which is every sheet here. Rebuilding produces
    /// the same file a spreadsheet app would have written and tests our reader
    /// rather than their bug.
    List<int> rewritten(
      String sheetName,
      List<CellValue?> Function(List<CellValue?> row, int index) transform, {
      List<List<CellValue?>> extra = const <List<CellValue?>>[],
    }) {
      final Excel from = Excel.decodeBytes(encodeBackupWorkbook(sample()));
      final Excel to = Excel.createExcel();
      for (final MapEntry<String, Sheet> entry in from.tables.entries) {
        final Sheet target = to[entry.key];
        final List<List<Data?>> rows = entry.value.rows;
        for (int i = 0; i < rows.length; i++) {
          final List<CellValue?> values =
              rows[i].map((Data? cell) => cell?.value).toList();
          target.appendRow(
            entry.key == sheetName ? transform(values, i) : values,
          );
        }
        if (entry.key == sheetName) {
          for (final List<CellValue?> row in extra) {
            target.appendRow(row);
          }
        }
      }
      to.delete('Sheet1');
      return to.encode()!;
    }

    // The importer reads columns by header name, never by position. This is
    // what lets someone sort, hide or annotate the sheet in Google Sheets and
    // still restore the file afterwards — which they will, because the whole
    // point of the format is that it is a spreadsheet you actually use.
    test('columns in a different order still import', () {
      final BackupData after = decodeBackupWorkbook(
        rewritten(
          kSheetTransactions,
          (List<CellValue?> row, int _) => row.reversed.toList(),
        ),
      );
      expect(after.transactions, sample().transactions);
    });

    test('a column the user added of their own is ignored', () {
      final BackupData after = decodeBackupWorkbook(
        rewritten(
          kSheetTransactions,
          (List<CellValue?> row, int index) => <CellValue?>[
            TextCellValue(index == 0 ? 'Claimed?' : 'yes'),
            ...row,
          ],
        ),
      );
      expect(after.transactions, sample().transactions);
    });

    test('a display column the user typed over is ignored', () {
      // 'Merchant' at index 3 is the merged, display-only column. The
      // '(as stored)' one beside it is what a restore actually reads.
      final BackupData after = decodeBackupWorkbook(
        rewritten(kSheetTransactions, (List<CellValue?> row, int index) {
          if (index == 0) return row;
          return <CellValue?>[
            ...row.take(3),
            TextCellValue('TYPED OVER'),
            ...row.skip(4),
          ];
        }),
      );
      expect(after.transactions, sample().transactions);
    });

    // Sheets pads a table out with blank rows the moment anyone scrolls in it.
    test('trailing blank rows are skipped, not imported', () {
      final BackupData after = decodeBackupWorkbook(
        rewritten(
          kSheetTransactions,
          (List<CellValue?> row, int _) => row,
          extra: <List<CellValue?>>[
            <CellValue?>[null, null, null],
            <CellValue?>[TextCellValue(''), null],
          ],
        ),
      );
      expect(after.transactions, hasLength(2));
    });

    test('a sheet that has lost a required column says which one', () {
      expect(
        () => decodeBackupWorkbook(
          rewritten(
            kSheetTransactions,
            // Index 10 is 'Timestamp (ms)', the authoritative date.
            (List<CellValue?> row, int _) => <CellValue?>[
              ...row.take(10),
              ...row.skip(11),
            ],
          ),
        ),
        throwsA(
          isA<BackupFormatException>().having(
            (BackupFormatException e) => e.message,
            'message',
            allOf(contains('Timestamp (ms)'), contains('Transactions')),
          ),
        ),
      );
    });

    test('a file that is not a workbook is refused, not guessed at', () {
      expect(
        () => decodeBackupWorkbook(<int>[1, 2, 3, 4]),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('somebody else\'s spreadsheet is refused', () {
      final BackupData data = sample();
      final BackupData stripped = BackupData(
        meta: const <String, String>{'something': 'else'},
        appMeta: data.appMeta,
        categories: data.categories,
        merchantMappings: data.merchantMappings,
        transactions: data.transactions,
        splits: data.splits,
        deleted: data.deleted,
        aliases: data.aliases,
      );
      expect(
        () => roundTrip(stripped),
        throwsA(
          isA<BackupFormatException>().having(
            (BackupFormatException e) => e.message,
            'message',
            contains('not written by this app'),
          ),
        ),
      );
    });
  });

  group('validateBackup', () {
    /// The smallest valid backup, which each test then breaks in one way.
    BackupData valid({
      List<Map<String, Object?>>? categories,
      List<Map<String, Object?>>? transactions,
      List<Map<String, Object?>>? splits,
      List<Map<String, Object?>>? merchantMappings,
      List<Map<String, Object?>>? aliases,
      List<Map<String, Object?>>? deleted,
      Map<String, String>? meta,
    }) =>
        BackupData(
          meta: meta ??
              <String, String>{
                'format': kBackupFormat,
                'format_version': '$kBackupFormatVersion',
                'schema_version': '7',
              },
          appMeta: const <Map<String, Object?>>[],
          categories: categories ??
              <Map<String, Object?>>[
                <String, Object?>{'id': 1, 'name': 'Uncategorized'},
                <String, Object?>{'id': 2, 'name': 'Grocery'},
              ],
          merchantMappings: merchantMappings ?? const <Map<String, Object?>>[],
          transactions: transactions ??
              <Map<String, Object?>>[
                <String, Object?>{
                  'id': 1,
                  'amount': 100.0,
                  'payment_type': 'Card',
                  'merchant': 'Shop',
                  'date': 1755070895000,
                  'category_id': 2,
                  'direction': 'debit',
                  'reference': '',
                  'note': '',
                },
              ],
          splits: splits ?? const <Map<String, Object?>>[],
          deleted: deleted ?? const <Map<String, Object?>>[],
          aliases: aliases ?? const <Map<String, Object?>>[],
        );

    test('a clean backup has nothing to say about itself', () {
      expect(validateBackup(valid(), appSchemaVersion: 7), isEmpty);
    });

    // A newer schema may have columns this build has never heard of. Importing
    // it hopefully would drop them, which turns a backup into a lossy one at
    // exactly the moment it is being relied on.
    test('a backup from a newer app is refused outright', () {
      final List<String> problems = validateBackup(
        valid(
          meta: <String, String>{
            'format': kBackupFormat,
            'format_version': '$kBackupFormatVersion',
            'schema_version': '9',
          },
        ),
        appSchemaVersion: 7,
      );
      expect(problems, hasLength(1));
      expect(problems.single, contains('newer version of the app'));
    });

    test('an older backup is fine — that is what migrations are for', () {
      expect(
        validateBackup(
          valid(
            meta: <String, String>{
              'format': kBackupFormat,
              'format_version': '$kBackupFormatVersion',
              'schema_version': '5',
            },
          ),
          appSchemaVersion: 7,
        ),
        isEmpty,
      );
    });

    test('a transaction in a category that is not there is caught', () {
      final List<String> problems = validateBackup(
        valid(
          transactions: <Map<String, Object?>>[
            <String, Object?>{
              'id': 1,
              'amount': 100.0,
              'payment_type': null,
              'merchant': 'Shop',
              'date': 1755070895000,
              'category_id': 99,
              'direction': 'debit',
              'reference': '',
              'note': '',
            },
          ],
        ),
        appSchemaVersion: 7,
      );
      expect(problems.single, contains('category 99'));
    });

    test('a duplicate transaction id is caught', () {
      Map<String, Object?> txn(int id, double amount) => <String, Object?>{
            'id': id,
            'amount': amount,
            'payment_type': null,
            'merchant': 'Shop',
            'date': 1755070895000,
            'category_id': 2,
            'direction': 'debit',
            'reference': '',
            'note': '',
          };
      final List<String> problems = validateBackup(
        valid(transactions: <Map<String, Object?>>[txn(1, 100), txn(1, 200)]),
        appSchemaVersion: 7,
      );
      expect(problems.single, contains('share the id 1'));
    });

    // The unique natural-key index is what stops a rescan piling up duplicates.
    // Two rows that collide on it would fail halfway through the insert.
    test('two transactions with the same natural key are caught', () {
      Map<String, Object?> txn(int id) => <String, Object?>{
            'id': id,
            'amount': 100.0,
            'payment_type': null,
            'merchant': 'Shop',
            'date': 1755070895000,
            'category_id': 2,
            'direction': 'debit',
            'reference': '',
            'note': '',
          };
      final List<String> problems = validateBackup(
        valid(transactions: <Map<String, Object?>>[txn(1), txn(2)]),
        appSchemaVersion: 7,
      );
      expect(problems.single, contains('same amount, merchant, timestamp'));
    });

    test('the natural key compares merchants case-insensitively', () {
      Map<String, Object?> txn(int id, String merchant) => <String, Object?>{
            'id': id,
            'amount': 100.0,
            'payment_type': null,
            'merchant': merchant,
            'date': 1755070895000,
            'category_id': 2,
            'direction': 'debit',
            'reference': '',
            'note': '',
          };
      final List<String> problems = validateBackup(
        valid(
          transactions: <Map<String, Object?>>[txn(1, 'Shop'), txn(2, 'SHOP')],
        ),
        appSchemaVersion: 7,
      );
      expect(problems.single, contains('same amount, merchant, timestamp'));
    });

    test('split lines that do not add up are caught', () {
      final List<String> problems = validateBackup(
        valid(
          splits: <Map<String, Object?>>[
            <String, Object?>{
              'id': 1,
              'transaction_id': 1,
              'category_id': 2,
              'amount': 60.0,
              'position': 0,
            },
            <String, Object?>{
              'id': 2,
              'transaction_id': 1,
              'category_id': 1,
              'amount': 20.0,
              'position': 1,
            },
          ],
        ),
        appSchemaVersion: 7,
      );
      expect(problems.single, contains('add up to 80.00'));
    });

    test('split lines within the rounding tolerance are accepted', () {
      expect(
        validateBackup(
          valid(
            splits: <Map<String, Object?>>[
              <String, Object?>{
                'id': 1,
                'transaction_id': 1,
                'category_id': 2,
                'amount': 33.33,
                'position': 0,
              },
              <String, Object?>{
                'id': 2,
                'transaction_id': 1,
                'category_id': 1,
                'amount': 66.67,
                'position': 1,
              },
            ],
          ),
          appSchemaVersion: 7,
        ),
        isEmpty,
      );
    });

    test('a missing Uncategorized is caught', () {
      final List<String> problems = validateBackup(
        valid(
          categories: <Map<String, Object?>>[
            <String, Object?>{'id': 2, 'name': 'Grocery'},
          ],
        ),
        appSchemaVersion: 7,
      );
      expect(problems.single, contains('Uncategorized'));
    });

    test('a direction that is neither debit nor credit is caught', () {
      final List<String> problems = validateBackup(
        valid(
          transactions: <Map<String, Object?>>[
            <String, Object?>{
              'id': 1,
              'amount': 100.0,
              'payment_type': null,
              'merchant': 'Shop',
              'date': 1755070895000,
              'category_id': 2,
              'direction': 'sideways',
              'reference': '',
              'note': '',
            },
          ],
        ),
        appSchemaVersion: 7,
      );
      expect(problems.single, contains('must be debit or credit'));
    });

    test('a merchant default pointing nowhere is caught', () {
      final List<String> problems = validateBackup(
        valid(
          merchantMappings: <Map<String, Object?>>[
            <String, Object?>{'merchant_name': 'Swiggy', 'category_id': 99},
          ],
        ),
        appSchemaVersion: 7,
      );
      expect(problems.single, contains('category 99'));
    });

    // Nullable by design: a tombstone written before schema v4 has no category
    // and restores into Uncategorized. That must not read as corruption.
    test('a pre-v4 tombstone with nulls throughout is accepted', () {
      expect(
        validateBackup(
          valid(
            deleted: <Map<String, Object?>>[
              <String, Object?>{
                'amount': 12.0,
                'merchant': 'Old Shop',
                'date': 1753000000000,
                'direction': 'debit',
                'reference': '',
                'payment_type': null,
                'category_id': null,
                'original_id': null,
                'deleted_at': null,
                'splits_json': null,
                'note': null,
              },
            ],
          ),
          appSchemaVersion: 7,
        ),
        isEmpty,
      );
    });
  });

  group('backupFileName', () {
    test('an export is named for the day it was taken', () {
      expect(
        backupFileName(DateTime(2026, 8, 17, 14, 32)),
        'tu-expense-2026-08-17.xlsx',
      );
    });

    // A restore that went wrong is usually followed by another attempt within
    // the minute. Two safety copies from one afternoon must not collide.
    test('a pre-restore copy carries the time too', () {
      expect(
        backupFileName(DateTime(2026, 8, 17, 14, 32), beforeRestore: true),
        'tu-expense-before-restore-2026-08-17-1432.xlsx',
      );
      expect(
        backupFileName(DateTime(2026, 8, 17, 14, 33), beforeRestore: true),
        isNot(backupFileName(
          DateTime(2026, 8, 17, 14, 32),
          beforeRestore: true,
        )),
      );
    });
  });

  group('confirmRestore', () {
    Future<void> open(
      WidgetTester tester,
      int replacing,
      int incoming,
      List<bool> answers,
    ) async {
      await tester.pumpWidget(
        restoreAsker(replacing, incoming, answers.add),
      );
      await tester.tap(find.text('ask'));
      await tester.pumpAndSettle();
    }

    // The counts are the whole question. Restoring 1,190 rows over 1,284 is a
    // different decision from restoring them over nothing.
    testWidgets('names both counts', (tester) async {
      await open(tester, 1284, 1190, <bool>[]);
      expect(find.textContaining('all 1284 transactions'), findsOneWidget);
      expect(find.textContaining('the 1190 in this file'), findsOneWidget);
    });

    testWidgets('says so when there is nothing to replace', (tester) async {
      await open(tester, 0, 1190, <bool>[]);
      expect(find.textContaining('nothing in the app to replace'),
          findsOneWidget);
    });

    testWidgets('Replace is a yes', (tester) async {
      final List<bool> answers = <bool>[];
      await open(tester, 10, 20, answers);
      await tester.tap(find.text('Replace'));
      await tester.pumpAndSettle();
      expect(answers, <bool>[true]);
    });

    testWidgets('Cancel is a no', (tester) async {
      final List<bool> answers = <bool>[];
      await open(tester, 10, 20, answers);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(answers, <bool>[false]);
    });

    // Nothing about a restore should be reachable by accident, least of all by
    // a stray tap landing outside the dialog.
    testWidgets('a tap outside is a no', (tester) async {
      final List<bool> answers = <bool>[];
      await open(tester, 10, 20, answers);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(answers, <bool>[false]);
    });
  });

  group('showBackupProblems', () {
    Future<void> open(WidgetTester tester, List<String> problems) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => TextButton(
                onPressed: () => showBackupProblems(context, problems),
                child: const Text('show'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('show'));
      await tester.pumpAndSettle();
    }

    testWidgets('promises that nothing was changed', (tester) async {
      await open(tester, <String>['Something is wrong.']);
      expect(find.textContaining('Nothing in the app has been changed'),
          findsOneWidget);
      expect(find.textContaining('Something is wrong.'), findsOneWidget);
    });

    // A workbook broken in one place is usually broken in a hundred, and a
    // dialog listing all hundred says less than one listing five and a count.
    testWidgets('truncates a long list rather than filling the screen',
        (tester) async {
      await open(
        tester,
        List<String>.generate(12, (int i) => 'Problem number $i.'),
      );
      expect(find.textContaining('Problem number 4.'), findsOneWidget);
      expect(find.textContaining('Problem number 5.'), findsNothing);
      expect(find.textContaining('and 7 more.'), findsOneWidget);
    });
  });

  group('confirmDeleteTransactions', () {
    /// Opens the dialog and leaves it open, with [answers] waiting for whatever
    /// it eventually returns.
    Future<void> open(
      WidgetTester tester,
      int count,
      List<bool> answers,
    ) async {
      await tester.pumpWidget(deleteAsker(count, answers.add));
      await tester.tap(find.text('ask'));
      await tester.pumpAndSettle();
      expect(answers, isEmpty, reason: 'nothing is answered until it is asked');
    }

    testWidgets('asks about one row in the singular', (tester) async {
      await open(tester, 1, <bool>[]);
      expect(find.text('Delete this transaction?'), findsOneWidget);
      expect(
        find.textContaining('It stays out of future inbox scans'),
        findsOneWidget,
      );
    });

    testWidgets('counts them when there are several', (tester) async {
      await open(tester, 4, <bool>[]);
      expect(find.text('Delete 4 transactions?'), findsOneWidget);
      expect(
        find.textContaining('They stay out of future inbox scans'),
        findsOneWidget,
      );
    });

    testWidgets('Delete is a yes', (tester) async {
      final List<bool> answers = <bool>[];
      await open(tester, 1, answers);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
      expect(answers, <bool>[true]);
    });

    testWidgets('Cancel is a no', (tester) async {
      final List<bool> answers = <bool>[];
      await open(tester, 1, answers);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(answers, <bool>[false]);
    });

    // The swipe hands this straight to `Dismissible.confirmDismiss`, where a
    // null would be read as neither yes nor no. Everything that is not the
    // Delete button has to come back false, or a dialog waved away would take
    // the row with it.
    testWidgets('a tap outside is a no, not an unanswered question',
        (tester) async {
      final List<bool> answers = <bool>[];
      await open(tester, 1, answers);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(answers, <bool>[false]);
    });
  });

  group('Filter Controls and Tokens', () {
    testWidgets('FilterTriggerButton renders inactive and active states with count badge',
        (WidgetTester tester) async {
      int tapped = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Row(
            children: <Widget>[
              FilterTriggerButton(
                label: 'Classification',
                count: 0,
                active: false,
                onPressed: () => tapped++,
              ),
              FilterTriggerButton(
                label: 'Entity',
                count: 3,
                active: true,
                onPressed: () => tapped++,
              ),
            ],
          ),
        ),
      ));

      expect(find.text('Classification'), findsOneWidget);
      expect(find.text('Entity'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);

      await tester.tap(find.text('Classification'));
      await tester.pump();
      expect(tapped, 1);
    });

    testWidgets('ActiveFiltersBar renders token chips and triggers callback on delete',
        (WidgetTester tester) async {
      LedgerFilters current = LedgerFilters(
        months: <YearMonth>{const YearMonth(2026, 8)},
        categoryIds: const <int>{2},
        merchants: const <String>{'SWIGGY'},
        paymentTypes: const <String>{'YES BANK Card X2858'},
        query: 'dinner',
      );

      final List<ExpenseCategory> categories = <ExpenseCategory>[
        const ExpenseCategory(id: 1, name: 'Uncategorized'),
        const ExpenseCategory(id: 2, name: 'Grocery'),
      ];

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (BuildContext context, StateSetter setState) {
              return ActiveFiltersBar(
                filters: current,
                currentMonth: const YearMonth(2026, 8),
                categoryChoices: categories,
                onFiltersChanged: (LedgerFilters f) => setState(() => current = f),
              );
            },
          ),
        ),
      ));

      // Chips for query, category, merchant, card should be visible
      expect(find.text('"dinner"'), findsOneWidget);
      expect(find.text('Grocery'), findsOneWidget);
      expect(find.text('SWIGGY'), findsOneWidget);
      expect(find.text('YES BANK Card X2858'), findsOneWidget);
      expect(find.text('Clear all'), findsOneWidget);

      // Remove Grocery chip
      final Finder closeButtons = find.byIcon(Icons.close);
      expect(closeButtons, findsNWidgets(4));

      // Tap close on first chip (dinner)
      await tester.tap(closeButtons.first);
      await tester.pumpAndSettle();

      expect(find.text('"dinner"'), findsNothing);
      expect(current.query, isEmpty);

      // Tap Clear all
      await tester.tap(find.text('Clear all'));
      await tester.pumpAndSettle();

      expect(find.byType(ActiveFilterChipToken), findsNothing);
      expect(current.isDefaultFor(const YearMonth(2026, 8)), isTrue);
    });

    test('paymentTypeOptions narrows to cards matching selected merchant and category', () {
      final List<ExpenseTxn> transactions = <ExpenseTxn>[
        ExpenseTxn(
          id: 1,
          date: DateTime(2026, 8, 10),
          amount: 500,
          merchant: 'SWIGGY',
          categoryId: 2,
          categoryName: 'Food',
          paymentType: 'Card Alpha',
          direction: TxnDirection.debit,
          reference: 'ref1',
        ),
        ExpenseTxn(
          id: 2,
          date: DateTime(2026, 8, 12),
          amount: 1500,
          merchant: 'AMAZON',
          categoryId: 3,
          categoryName: 'Shopping',
          paymentType: 'Card Beta',
          direction: TxnDirection.debit,
          reference: 'ref2',
        ),
      ];

      // Unfiltered shows all cards
      expect(
        paymentTypeOptions(transactions),
        <String>['Card Alpha', 'Card Beta'],
      );

      // Filtering by merchant SWIGGY only offers Card Alpha
      expect(
        paymentTypeOptions(transactions, merchants: <String>{'SWIGGY'}),
        <String>['Card Alpha'],
      );

      // Filtering by merchant AMAZON only offers Card Beta
      expect(
        paymentTypeOptions(transactions, merchants: <String>{'AMAZON'}),
        <String>['Card Beta'],
      );
    });
  });
}
