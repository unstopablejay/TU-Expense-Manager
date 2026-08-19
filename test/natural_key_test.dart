// The natural key, spelled the same on the phone and in a browser.
//
// **Run this suite on both targets.** `flutter test` proves nothing here on its
// own: the bug this file exists for was a difference between the two, and the VM
// half of it was always right. CI runs `flutter test --platform chrome` for
// exactly this reason.
//
// What went wrong: `double.toString()` is round-trip exact on both targets but
// does not spell a double the same way on each. On the VM 500.0 prints as
// "500.0"; on the web a double is a JavaScript number and prints as "500". The
// natural key is composed in a browser, carried in an edit, and matched against
// the ledger on the phone — so every browser edit to a whole-rupee transaction
// addressed a row that, as far as the phone could tell, was not there. It came
// back as "skipped, no longer matched" and the user's edit disappeared. An
// amount ending in paise worked, which is what made it look intermittent.
//
// The assertions below are deliberately about the *characters* of the key rather
// than about two keys agreeing with each other. Two keys built by the same
// runtime agree even when both are wrong.

import 'package:flutter_test/flutter_test.dart';
import 'package:tu_expense_tracker/main.dart';

/// The NUL that separates the fields.
///
/// Built from its code unit rather than written as an escape, so this file
/// carries no invisible control character and no reader has to wonder whether
/// what they are looking at is one character or six.
final String nul = String.fromCharCode(0);

ExpenseTxn txn({
  int id = 1,
  double amount = 500.0,
  String merchant = 'SWIGGY',
  int dateMillis = 1755000000000,
}) =>
    ExpenseTxn(
      id: id,
      amount: amount,
      paymentType: 'CARD X1',
      merchant: merchant,
      date: DateTime.fromMillisecondsSinceEpoch(dateMillis),
      categoryId: 2,
      categoryName: 'Grocery',
      direction: TxnDirection.debit,
      reference: '',
    );

void main() {
  group('canonicalAmountKey', () {
    test('an integral amount keeps the fractional part the VM prints', () {
      // The whole bug, in one line. On the web `500.0.toString()` is "500".
      expect(canonicalAmountKey(500.0), '500.0');
      expect(canonicalAmountKey(0.0), '0.0');
      expect(canonicalAmountKey(1.0), '1.0');
      expect(canonicalAmountKey(1000000.0), '1000000.0');
    });

    test('an amount with paise in it is left exactly as it is', () {
      expect(canonicalAmountKey(499.99), '499.99');
      expect(canonicalAmountKey(0.01), '0.01');
      expect(canonicalAmountKey(249.5), '249.5');
      expect(canonicalAmountKey(1234567.89), '1234567.89');
    });

    test('a value in exponent form is left alone, since both targets agree', () {
      // Not money, but the guard has to hold for whatever a corrupt row carries:
      // appending ".0" to "1e+21" would produce something unparseable.
      expect(canonicalAmountKey(1e21), '1e+21');
      expect(canonicalAmountKey(1e-7), '1e-7');
    });

    test('a negative amount keeps its sign', () {
      expect(canonicalAmountKey(-500.0), '-500.0');
      expect(canonicalAmountKey(-0.5), '-0.5');
    });
  });

  group('transactionNaturalKey', () {
    test('a whole-rupee transaction spells its amount with the .0', () {
      final String key = txn(amount: 500.0).naturalKey;
      expect(key.split(nul).first, '500.0');
      expect(key, '500.0${nul}swiggy${nul}1755000000000${nul}debit$nul');
    });

    test('the merchant is lower-cased and the fields are NUL-separated', () {
      expect(
        txn(amount: 12.5, merchant: 'Big Bazaar').naturalKey.split(nul),
        <String>['12.5', 'big bazaar', '1755000000000', 'debit', ''],
      );
    });

    test('two different amounts never produce the same key', () {
      expect(txn(amount: 500.0).naturalKey == txn(amount: 500.5).naturalKey,
          isFalse);
    });
  });

  group('resolving an edit against a ledger', () {
    final ExpenseTxn target = txn(amount: 500.0);

    LedgerEdit editWithKey(String naturalKey) => LedgerEdit(
          editId: 'e1',
          op: EditOp.setCategory,
          txnId: target.id,
          naturalKey: naturalKey,
          createdAt: DateTime.utc(2026, 8, 19),
          payload: const <String, Object?>{'category_id': 3},
        );

    test('an edit composed against this row finds it', () {
      expect(
        editWithKey(target.naturalKey).resolve(<ExpenseTxn>[target]),
        same(target),
      );
    });

    test('a key from a browser build that spelled 500.0 as 500 still finds it',
        () {
      // What is already sitting in the queues on a running server. Updating the
      // phone must apply those edits, not report a week of them as missing.
      final String legacy =
          '500${nul}swiggy${nul}1755000000000${nul}debit$nul';
      expect(editWithKey(legacy).resolve(<ExpenseTxn>[target]), same(target));
      expect(editWithKey(legacy).matches(target), isTrue);
    });

    test('a genuinely different row is still refused', () {
      final ExpenseTxn other = txn(id: 2, amount: 501.0);
      final String legacy =
          '500${nul}swiggy${nul}1755000000000${nul}debit$nul';
      expect(editWithKey(legacy).resolve(<ExpenseTxn>[other]), isNull);
    });

    test('an unreadable key is compared as it always was, not rewritten', () {
      expect(editWithKey('not-a-key').resolve(<ExpenseTxn>[target]), isNull);
    });
  });
}
