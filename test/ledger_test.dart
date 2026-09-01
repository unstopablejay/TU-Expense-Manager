// spendByDayPerMonth: what the dashboard's trend view plots.
//
// Only the bucketing rules are pinned here — credits excluded, split-aware
// via LedgerEntry.amount, keyed by day-of-month within each YearMonth — the
// same rules spendByCategoryPerMonth already has tests-by-inspection for.

import 'package:flutter_test/flutter_test.dart';
import 'package:tu_expense_tracker/src/core/ledger.dart';
import 'package:tu_expense_tracker/src/core/models.dart';
import 'package:tu_expense_tracker/src/core/parser.dart';
import 'package:tu_expense_tracker/src/core/splits.dart';

ExpenseTxn _txn({
  required int id,
  required DateTime date,
  required double amount,
  TxnDirection direction = TxnDirection.debit,
  List<TxnSplit> splits = const <TxnSplit>[],
}) =>
    ExpenseTxn(
      id: id,
      amount: amount,
      paymentType: 'Card',
      merchant: 'Merchant $id',
      date: date,
      categoryId: 1,
      categoryName: 'Shopping',
      direction: direction,
      reference: '',
      splits: splits,
    );

LedgerEntry _entry(ExpenseTxn txn) =>
    LedgerEntry(txn: txn, lines: txn.effectiveSplits);

void main() {
  group('spendByDayPerMonth', () {
    test('buckets debits by day within each month', () {
      final List<LedgerEntry> entries = <LedgerEntry>[
        _entry(_txn(id: 1, date: DateTime(2026, 8, 3), amount: 100)),
        _entry(_txn(id: 2, date: DateTime(2026, 8, 3), amount: 50)),
        _entry(_txn(id: 3, date: DateTime(2026, 8, 20), amount: 25)),
      ];

      final Map<YearMonth, Map<int, double>> byDay =
          spendByDayPerMonth(entries);

      expect(byDay.keys, <YearMonth>[const YearMonth(2026, 8)]);
      expect(byDay[const YearMonth(2026, 8)], <int, double>{3: 150, 20: 25});
    });

    test('leaves credits out', () {
      final List<LedgerEntry> entries = <LedgerEntry>[
        _entry(_txn(id: 1, date: DateTime(2026, 8, 3), amount: 100)),
        _entry(_txn(
          id: 2,
          date: DateTime(2026, 8, 3),
          amount: 500,
          direction: TxnDirection.credit,
        )),
      ];

      final Map<YearMonth, Map<int, double>> byDay =
          spendByDayPerMonth(entries);

      expect(byDay[const YearMonth(2026, 8)], <int, double>{3: 100});
    });

    test('keeps months separate', () {
      final List<LedgerEntry> entries = <LedgerEntry>[
        _entry(_txn(id: 1, date: DateTime(2026, 7, 15), amount: 40)),
        _entry(_txn(id: 2, date: DateTime(2026, 8, 15), amount: 60)),
      ];

      final Map<YearMonth, Map<int, double>> byDay =
          spendByDayPerMonth(entries);

      expect(byDay[const YearMonth(2026, 7)], <int, double>{15: 40});
      expect(byDay[const YearMonth(2026, 8)], <int, double>{15: 60});
    });

    test('is split-aware, summing only the lines that survived the filter', () {
      final ExpenseTxn split = _txn(
        id: 1,
        date: DateTime(2026, 8, 5),
        amount: 300,
        splits: const <TxnSplit>[
          TxnSplit(categoryId: 1, categoryName: 'Grocery', amount: 200),
          TxnSplit(categoryId: 2, categoryName: 'Household', amount: 100),
        ],
      );
      // Only the Grocery line survived whatever narrowed this view.
      final LedgerEntry entry = LedgerEntry(
        txn: split,
        lines: <TxnSplit>[split.splits.first],
      );

      final Map<YearMonth, Map<int, double>> byDay =
          spendByDayPerMonth(<LedgerEntry>[entry]);

      expect(byDay[const YearMonth(2026, 8)], <int, double>{5: 200});
    });

    test('empty entries yield an empty map', () {
      expect(spendByDayPerMonth(const <LedgerEntry>[]), isEmpty);
    });
  });

  group('deltaAmount and deltaPercent', () {
    test('deltaAmount computes B - A', () {
      expect(deltaAmount(1000, 1100), 100);
      expect(deltaAmount(1100, 1000), -100);
      expect(deltaAmount(1000, 1000), 0);
    });

    test('deltaPercent computes percentage change', () {
      expect(deltaPercent(1000, 1100), 10.0);
      expect(deltaPercent(1000, 900), -10.0);
    });

    test('deltaPercent handles zero baseline', () {
      expect(deltaPercent(0, 500), isNull);
      expect(deltaPercent(0, 0), isNull);
    });
  });
}
