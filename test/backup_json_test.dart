// The JSON snapshot codec.
//
// The interesting cases are all about types rather than values. JSON has one
// number type and SQLite has two, and the seam between them is where a snapshot
// can be syntactically perfect and still fail to restore — so most of what is
// asserted here is `runtimeType`, not equality.

import 'package:flutter_test/flutter_test.dart';
import 'package:tu_expense_tracker/main.dart';

/// A snapshot with one of everything, so a round trip exercises every table.
///
/// Amounts are deliberately whole rupees. `1200.0` is the value that survives
/// `jsonEncode` as `1200.0` but comes back as an `int` from anything that
/// re-serialises it, and it is the exact shape of the bug this codec exists to
/// prevent.
BackupData sample() => BackupData(
      categories: <Map<String, Object?>>[
        <String, Object?>{'id': 1, 'name': kUncategorized},
        <String, Object?>{'id': 2, 'name': 'Grocery'},
      ],
      merchantMappings: <Map<String, Object?>>[
        <String, Object?>{'merchant_name': 'SWIGGY', 'category_id': 2},
      ],
      transactions: <Map<String, Object?>>[
        <String, Object?>{
          'id': 7,
          'amount': 1200.0,
          'payment_type': 'YES BANK Card X2858',
          'merchant': 'SWIGGY',
          'date': 1755000000000,
          'category_id': 2,
          'direction': 'debit',
          'reference': '',
          'note': 'dinner',
        },
        <String, Object?>{
          'id': 8,
          'amount': 39.5,
          'payment_type': null,
          'merchant': 'PZCREDIT9772829',
          'date': 1755000600000,
          'category_id': 1,
          'direction': 'credit',
          'reference': '213313774670',
          'note': '',
        },
      ],
      splits: <Map<String, Object?>>[
        <String, Object?>{
          'id': 3,
          'transaction_id': 7,
          'category_id': 2,
          'amount': 800.0,
          'position': 0,
        },
        <String, Object?>{
          'id': 4,
          'transaction_id': 7,
          'category_id': 1,
          'amount': 400.0,
          'position': 1,
        },
      ],
      deleted: <Map<String, Object?>>[
        <String, Object?>{
          'amount': 500.0,
          'merchant': 'AMAZON',
          'date': 1754000000000,
          'direction': 'debit',
          'reference': '',
          'payment_type': 'HDFC A/c XX0444',
          'category_id': 2,
          'original_id': 5,
          'deleted_at': 1754100000000,
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
      ],
      appMeta: <Map<String, Object?>>[
        <String, Object?>{
          'key': 'last_scanned_sms_date',
          'value': '1755000600000',
        },
      ],
      meta: buildBackupMeta(
        appVersion: '1.1.0',
        appBuild: '2',
        exportedAt: DateTime.utc(2026, 8, 18, 21, 4, 33),
        transactions: 2,
        splits: 2,
        categories: 2,
        merchantDefaults: 1,
        nameAliases: 1,
        deleted: 1,
      ),
    );

BackupData roundTrip(BackupData data) =>
    decodeBackupJson(encodeBackupJson(data));

void main() {
  group('encodeBackupJson / decodeBackupJson', () {
    test('every table survives a round trip', () {
      final BackupData out = roundTrip(sample());
      final BackupData once = sample();

      expect(out.categories, once.categories);
      expect(out.merchantMappings, once.merchantMappings);
      expect(out.transactions, once.transactions);
      expect(out.splits, once.splits);
      expect(out.deleted, once.deleted);
      expect(out.aliases, once.aliases);
      expect(out.appMeta, once.appMeta);
      expect(out.meta, once.meta);
    });

    test('a second round trip changes nothing further', () {
      // Encoding what was decoded is what a server does when it stores a
      // snapshot and hands it back, so it must be a fixed point.
      final BackupData twice = roundTrip(roundTrip(sample()));
      expect(twice.transactions, sample().transactions);
      expect(twice.deleted, sample().deleted);
    });

    test('the format marker is at the top level, not only in meta', () {
      // So a reader can reject a body it has no business parsing without
      // having to understand the meta block first.
      expect(encodeBackupJson(sample()), contains('"format":"$kBackupFormat"'));
    });

    test('a round trip is still valid, with no problems to report', () {
      expect(
        validateBackup(roundTrip(sample()), appSchemaVersion: kSchemaVersion),
        isEmpty,
      );
    });
  });

  group('column types survive JSON, where JSON has only one number type', () {
    test('a whole-rupee amount comes back a double, not an int', () {
      final Map<String, Object?> txn = roundTrip(sample()).transactions.first;
      expect(txn['amount'], isA<double>());
      expect(txn['amount'], 1200.0);
    });

    test('an amount re-serialised as a bare integer is still a double', () {
      // What any other writer, a hand edit or a jq filter produces. Left as an
      // int it would throw a CastError inside validateBackup, before validation
      // could report anything a user could read.
      final BackupData out = decodeBackupJson('''
{"format":"$kBackupFormat","format_version":1,
 "transactions":[{"id":7,"amount":1200,"merchant":"SWIGGY","date":1755000000000,
                  "category_id":2,"direction":"debit","reference":"","note":""}]}
''');
      expect(out.transactions.single['amount'], isA<double>());
      expect(out.transactions.single['amount'], 1200.0);
    });

    test('without the coercion, an int amount would crash validateBackup', () {
      // The negative control for this whole group, and the reason the codec
      // carries a per-column type table at all. Verified, not assumed: an int
      // where a double is expected throws
      // "type 'int' is not a subtype of type 'double' in type cast"
      // out of validateBackup's natural-key check, before validation can
      // report anything a user could read.
      //
      // Two rows, because it is the duplicate-key comparison that reaches for
      // `as double`.
      Map<String, Object?> txn(int id, Object amount, String merchant) =>
          <String, Object?>{
            'id': id,
            'amount': amount,
            'merchant': merchant,
            'date': id,
            'category_id': 1,
            'direction': 'debit',
            'reference': '',
            'note': '',
          };
      BackupData withAmounts(Object a, Object b) => BackupData(
            categories: <Map<String, Object?>>[
              <String, Object?>{'id': 1, 'name': kUncategorized},
            ],
            merchantMappings: const <Map<String, Object?>>[],
            transactions: <Map<String, Object?>>[
              txn(1, a, 'X'),
              txn(2, b, 'Y'),
            ],
            splits: const <Map<String, Object?>>[],
            deleted: const <Map<String, Object?>>[],
            aliases: const <Map<String, Object?>>[],
            appMeta: const <Map<String, Object?>>[],
            meta: <String, String>{
              'format': kBackupFormat,
              'format_version': '1',
              'schema_version': '$kSchemaVersion',
            },
          );

      expect(
        () => validateBackup(withAmounts(1200, 1300),
            appSchemaVersion: kSchemaVersion),
        throwsA(isA<TypeError>()),
        reason: 'raw ints out of jsonDecode are what the codec has to prevent',
      );

      // And the same snapshot, once it has been through the codec, is fine.
      expect(
        validateBackup(
          roundTrip(withAmounts(1200.0, 1300.0)),
          appSchemaVersion: kSchemaVersion,
        ),
        isEmpty,
      );
    });

    test('a date written as a double comes back an int, to the millisecond', () {
      final BackupData out = decodeBackupJson('''
{"format":"$kBackupFormat","format_version":1,
 "transactions":[{"id":7,"amount":10.5,"merchant":"X","date":1755000000000.0,
                  "category_id":1,"direction":"debit","reference":"","note":""}]}
''');
      expect(out.transactions.single['date'], isA<int>());
      expect(out.transactions.single['date'], 1755000000000);
    });

    test('every column of every table has the type its column holds', () {
      final BackupData out = roundTrip(sample());

      for (final Map<String, Object?> row in out.transactions) {
        expect(row['id'], isA<int>());
        expect(row['amount'], isA<double>());
        expect(row['date'], isA<int>());
        expect(row['category_id'], isA<int>());
        expect(row['direction'], isA<String>());
        expect(row['reference'], isA<String>());
        expect(row['note'], isA<String>());
      }
      for (final Map<String, Object?> row in out.splits) {
        expect(row['id'], isA<int>());
        expect(row['transaction_id'], isA<int>());
        expect(row['category_id'], isA<int>());
        expect(row['amount'], isA<double>());
        expect(row['position'], isA<int>());
      }
      for (final Map<String, Object?> row in out.deleted) {
        expect(row['amount'], isA<double>());
        expect(row['date'], isA<int>());
        expect(row['original_id'], isA<int>());
        expect(row['deleted_at'], isA<int>());
      }
      for (final Map<String, Object?> row in out.categories) {
        expect(row['id'], isA<int>());
        expect(row['name'], isA<String>());
      }
      expect(out.merchantMappings.single['category_id'], isA<int>());
    });

    test('a null in a nullable column stays null, and does not become zero', () {
      final BackupData out = roundTrip(sample());
      expect(out.transactions[1]['payment_type'], isNull);
      expect(out.deleted.single['splits_json'], isNull);
      expect(out.deleted.single['note'], isNull);
    });

    test('a string holding a number is read as the number', () {
      final BackupData out = decodeBackupJson('''
{"format":"$kBackupFormat","format_version":1,
 "transactions":[{"id":"7","amount":"1200.50","merchant":"X","date":"1755000000000",
                  "category_id":"2","direction":"debit","reference":"","note":""}]}
''');
      final Map<String, Object?> txn = out.transactions.single;
      expect(txn['id'], 7);
      expect(txn['amount'], 1200.50);
      expect(txn['date'], 1755000000000);
      expect(txn['category_id'], 2);
    });

    test('a value that is no kind of number is left for validation to name', () {
      // Coercing this to 0 would turn a describable problem into a silently
      // wrong row, which is the one outcome a backup must never produce.
      final BackupData out = decodeBackupJson('''
{"format":"$kBackupFormat","format_version":1,
 "transactions":[{"id":7,"amount":"not a number","merchant":"X",
                  "date":1755000000000,"category_id":1,"direction":"debit",
                  "reference":"","note":""}]}
''');
      expect(out.transactions.single['amount'], 'not a number');
    });

    test('an unknown column is carried through untouched', () {
      // A snapshot from a newer schema has to survive decoding, so that
      // validateBackup can refuse it with a sentence rather than a crash.
      final BackupData out = decodeBackupJson('''
{"format":"$kBackupFormat","format_version":1,"meta":{"schema_version":"99"},
 "transactions":[{"id":7,"amount":10.0,"merchant":"X","date":1,"category_id":1,
                  "direction":"debit","reference":"","note":"","tags":"a,b"}]}
''');
      expect(out.transactions.single['tags'], 'a,b');
      expect(
        validateBackup(out, appSchemaVersion: kSchemaVersion),
        isNotEmpty,
        reason: 'a newer schema must be refused, not imported hopefully',
      );
    });
  });

  group('meta', () {
    test('a numeric format_version in meta still parses', () {
      final BackupData out = decodeBackupJson(
        '{"format":"$kBackupFormat","meta":{"format_version":1,'
        '"schema_version":7}}',
      );
      expect(out.formatVersion, 1);
      expect(out.schemaVersion, 7);
    });

    test('an absent meta block is empty rather than fatal', () {
      final BackupData out =
          decodeBackupJson('{"format":"$kBackupFormat","format_version":1}');
      expect(out.meta, isEmpty);
      expect(out.schemaVersion, isNull);
    });

    test('the row counts describe the snapshot', () {
      final BackupData out = roundTrip(sample());
      expect(out.meta['transactions'], '2');
      expect(out.meta['splits'], '2');
      expect(out.meta['deleted'], '1');
      expect(out.meta['exported_at'], '2026-08-18T21:04:33.000Z');
    });
  });

  group('what a snapshot is refused for', () {
    test('a body that is not JSON at all', () {
      expect(
        () => decodeBackupJson('<html>404</html>'),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('a body that is JSON but not an object', () {
      expect(
        () => decodeBackupJson('[1, 2, 3]'),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('somebody else\'s JSON, with no marker', () {
      expect(
        () => decodeBackupJson('{"transactions":[]}'),
        throwsA(
          isA<BackupFormatException>().having(
            (BackupFormatException e) => e.message,
            'message',
            contains('not a TU Expense Tracker snapshot'),
          ),
        ),
      );
    });

    test('a truncated body, which is what a dropped download looks like', () {
      final String whole = encodeBackupJson(sample());
      expect(
        () => decodeBackupJson(whole.substring(0, whole.length ~/ 2)),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('a table that is not a list', () {
      expect(
        () => decodeBackupJson(
          '{"format":"$kBackupFormat","transactions":{"id":1}}',
        ),
        throwsA(isA<BackupFormatException>()),
      );
    });

    test('a row that is not an object, named by its position', () {
      expect(
        () => decodeBackupJson(
          '{"format":"$kBackupFormat","transactions":[{"id":1},"nope"]}',
        ),
        throwsA(
          isA<BackupFormatException>().having(
            (BackupFormatException e) => e.message,
            'message',
            contains('row 2'),
          ),
        ),
      );
    });

    test('an absent table is empty, not an error', () {
      // Every table but categories is legitimately empty in a fresh install.
      final BackupData out =
          decodeBackupJson('{"format":"$kBackupFormat","format_version":1}');
      expect(out.transactions, isEmpty);
      expect(out.splits, isEmpty);
      expect(out.aliases, isEmpty);
    });
  });
}
