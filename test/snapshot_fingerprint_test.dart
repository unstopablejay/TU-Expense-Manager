// Telling a ledger that changed from one that only has a newer clock on it.
//
// VM only: `sync_client.dart` imports dart:io for the socket errors it turns
// into sentences.
@TestOn('vm')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tu_expense_tracker/main.dart';

BackupData ledger({
  double amount = 500.0,
  String note = '',
  DateTime? exportedAt,
}) =>
    BackupData(
      categories: <Map<String, Object?>>[
        <String, Object?>{'id': 1, 'name': kUncategorized},
      ],
      merchantMappings: const <Map<String, Object?>>[],
      transactions: <Map<String, Object?>>[
        <String, Object?>{
          'id': 1,
          'amount': amount,
          'payment_type': 'CARD X1',
          'merchant': 'SWIGGY',
          'date': 1755000000000,
          'category_id': 1,
          'direction': 'debit',
          'reference': '',
          'note': note,
        },
      ],
      splits: const <Map<String, Object?>>[],
      deleted: const <Map<String, Object?>>[],
      aliases: const <Map<String, Object?>>[],
      appMeta: const <Map<String, Object?>>[],
      meta: buildBackupMeta(
        appVersion: '1.1.0',
        appBuild: '2',
        exportedAt: exportedAt ?? DateTime.utc(2026, 8, 19, 10),
        transactions: 1,
        splits: 0,
        categories: 1,
        merchantDefaults: 0,
        nameAliases: 0,
        deleted: 0,
      ),
    );

void main() {
  group('the fingerprint', () {
    test('does not move when only the export time does', () {
      // The whole point. The body carries the instant it was taken, so hashing
      // it directly would make every ledger look new and an automatic sync would
      // upload a fresh copy of the same data every quarter of an hour — thirty
      // identical snapshots, and the history that is the backup gone.
      final String morning =
          encodeSnapshotForPush(ledger(exportedAt: DateTime.utc(2026, 8, 19, 9)))
              .fingerprint;
      final String evening =
          encodeSnapshotForPush(ledger(exportedAt: DateTime.utc(2026, 8, 19, 21)))
              .fingerprint;

      expect(morning, evening);
    });

    test('moves when a transaction does', () {
      expect(
        encodeSnapshotForPush(ledger(amount: 500.0)).fingerprint,
        isNot(encodeSnapshotForPush(ledger(amount: 500.5)).fingerprint),
      );
    });

    test('moves for a note, which changes no count and no total', () {
      // A cheaper fingerprint built from row counts and sums would miss this,
      // and a note typed on the phone would never reach the browser.
      expect(
        encodeSnapshotForPush(ledger(note: '')).fingerprint,
        isNot(encodeSnapshotForPush(ledger(note: 'split with Ravi')).fingerprint),
      );
    });

    test('is stable across two encodings of the same ledger', () {
      expect(
        encodeSnapshotForPush(ledger()).fingerprint,
        encodeSnapshotForPush(ledger()).fingerprint,
      );
    });
  });

  group('the body that goes with it', () {
    test('is the real snapshot, export time and all', () {
      final ({String body, String fingerprint}) encoded =
          encodeSnapshotForPush(ledger(exportedAt: DateTime.utc(2026, 8, 19, 9)));

      expect(encoded.body, contains('2026-08-19T09:00:00.000Z'));
      // Round-trips as a snapshot, which is what the server will insist on.
      final BackupData back = decodeBackupJson(encoded.body);
      expect(back.transactions, hasLength(1));
      expect(validateBackup(back, appSchemaVersion: kSchemaVersion), isEmpty);
    });
  });

  group('what the phone remembers about the last upload', () {
    test('round-trips', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      const SyncPrefs prefs = SyncPrefs.instance;

      expect(await prefs.lastPush(), isNull);

      await prefs.setLastPush(const PushMemory(
        fingerprint: 'abc123',
        snapshotId: '2026-08-19T10-00-00-000Z',
        target: 'http://192.168.1.99:8099|abcdefabcdefabcd',
      ));

      final PushMemory? back = await prefs.lastPush();
      expect(back?.fingerprint, 'abc123');
      expect(back?.snapshotId, '2026-08-19T10-00-00-000Z');
      expect(back?.target, 'http://192.168.1.99:8099|abcdefabcdefabcd');
    });

    test('names the server and the device, not just the ledger', () {
      // Pointing the app at a second server, or a reinstall that mints a new
      // device id, has to push in full — a fingerprint that matches describes a
      // ledger sitting somewhere else.
      expect(
        pushTarget(Uri.parse('http://192.168.1.99:8099'), 'device-a'),
        isNot(pushTarget(Uri.parse('http://192.168.1.99:8099'), 'device-b')),
      );
      expect(
        pushTarget(Uri.parse('http://nas.local:8099'), 'device-a'),
        isNot(pushTarget(Uri.parse('http://192.168.1.99:8099'), 'device-a')),
      );
    });
  });
}
