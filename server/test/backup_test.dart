import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'package:tu_expense_server/backup_manager.dart';
import 'package:tu_expense_server/backup_scheduler.dart';
import 'package:tu_expense_server/json_store.dart';

import 'server_test.dart';

void main() {
  const String password = 'a test passphrase for backup tests';

  group('BackupScheduler', () {
    test('calculateNextRun targets future time today or tomorrow', () {
      final DateTime morning = DateTime(2026, 8, 22, 10, 0, 0);
      final DateTime targetSameDay = BackupScheduler.calculateNextRun(
        now: morning,
        targetHour: 21,
        targetMinute: 0,
      );
      expect(targetSameDay, DateTime(2026, 8, 22, 21, 0, 0));

      final DateTime lateNight = DateTime(2026, 8, 22, 22, 0, 0);
      final DateTime targetNextDay = BackupScheduler.calculateNextRun(
        now: lateNight,
        targetHour: 21,
        targetMinute: 0,
      );
      expect(targetNextDay, DateTime(2026, 8, 23, 21, 0, 0));
    });

    test('start and cancel manage timer correctly', () async {
      final Directory dir =
          await Directory.systemTemp.createTemp('scheduler-test');
      final Paths paths = Paths(dir.path);
      final WriteLock lock = WriteLock();
      final BackupManager manager = BackupManager(
        paths: paths,
        lock: lock,
        backupDir: '${dir.path}/backups',
        keep: 10,
      );

      final BackupScheduler scheduler = BackupScheduler(
        manager: manager,
        hour: 21,
        minute: 0,
        enabled: true,
      );

      expect(scheduler.isRunning, isFalse);
      scheduler.start();
      expect(scheduler.isRunning, isTrue);
      expect(scheduler.nextRun, isNotNull);

      scheduler.cancel();
      expect(scheduler.isRunning, isFalse);
      expect(scheduler.nextRun, isNull);

      await dir.delete(recursive: true);
    });
  });

  group('BackupManager & API', () {
    late Harness h;
    late String token;

    setUp(() async {
      h = await Harness.start(backupKeep: 3);
      await h.auth.addUser('jay', password);
      token = await h.login('jay', password, device: 'pixel');
    });

    tearDown(() async => h.dispose());

    test('creates full server backup and lists it with metadata', () async {
      // Push a snapshot first
      final Response push = await h.send(
        'POST',
        '/api/v1/snapshot',
        token: token,
        device: 'pixel',
        body: snapshotBody(5, merchant: 'AMAZON'),
      );
      expect(push.statusCode, 201);

      // List backups before any creation
      final Response emptyList = await h.send(
        'GET',
        '/api/v1/backups',
        token: token,
      );
      expect(emptyList.statusCode, 200);
      final Map<String, Object?> emptyJson = await h.json(emptyList);
      expect(emptyJson['ok'], isTrue);
      expect((emptyJson['backups']! as List), isEmpty);
      expect((emptyJson['schedule']! as Map)['keep'], 3);

      // Create a manual backup via API
      final Response create = await h.send(
        'POST',
        '/api/v1/backups',
        token: token,
        body: <String, Object?>{'note': 'Initial test backup'},
      );
      expect(create.statusCode, 201);
      final Map<String, Object?> createJson = await h.json(create);
      expect(createJson['ok'], isTrue);
      final Map<String, Object?> backup =
          createJson['backup']! as Map<String, Object?>;
      expect(backup['type'], 'manual');
      expect(backup['note'], 'Initial test backup');
      expect((backup['counts']! as Map)['transactions'], '5');

      // List backups again
      final Response listResp = await h.send(
        'GET',
        '/api/v1/backups',
        token: token,
      );
      expect(listResp.statusCode, 200);
      final Map<String, Object?> listJson = await h.json(listResp);
      final List<Object?> backups = listJson['backups']! as List<Object?>;
      expect(backups.length, 1);
    });

    test('enforces FIFO rolling limit (backupKeep) deleting oldest auto/manual backups', () async {
      // h was started with backupKeep: 3
      // Create 5 backups in sequence
      for (int i = 1; i <= 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final Response res = await h.send(
          'POST',
          '/api/v1/backups',
          token: token,
          body: <String, Object?>{'note': 'Backup #$i'},
        );
        expect(res.statusCode, 201);
      }

      final Response listResp = await h.send(
        'GET',
        '/api/v1/backups',
        token: token,
      );
      final Map<String, Object?> listJson = await h.json(listResp);
      final List<Object?> backups = listJson['backups']! as List<Object?>;

      // Exactly 3 backups kept (newest 3: #5, #4, #3)
      expect(backups.length, 3);
      final List<String?> notes = backups
          .map((b) => (b as Map<String, Object?>)['note'] as String?)
          .toList();
      expect(notes, contains('Backup #5'));
      expect(notes, contains('Backup #4'));
      expect(notes, contains('Backup #3'));
      expect(notes, isNot(contains('Backup #1')));
      expect(notes, isNot(contains('Backup #2')));
    });

    test('restoration creates pre-restore safety snapshot and restores state', () async {
      // 1. Push state A (3 transactions)
      await h.send(
        'POST',
        '/api/v1/snapshot',
        token: token,
        device: 'pixel',
        body: snapshotBody(3, merchant: 'STATE_A'),
      );

      // Create backup of state A
      final Response resA = await h.send(
        'POST',
        '/api/v1/backups',
        token: token,
        body: <String, Object?>{'note': 'State A'},
      );
      final String backupIdA =
          ((await h.json(resA))['backup']! as Map<String, Object?>)['id']!
              as String;

      // 2. Modify to state B (10 transactions)
      await h.send(
        'POST',
        '/api/v1/snapshot',
        token: token,
        device: 'pixel',
        body: snapshotBody(10, merchant: 'STATE_B'),
      );

      // Verify state B is current
      final Response pullB = await h.send(
        'GET',
        '/api/v1/snapshot',
        token: token,
        device: 'pixel',
      );
      expect((jsonDecode(await pullB.readAsString())['transactions'] as List).length, 10);

      // 3. Restore state A from backupIdA
      final Response restoreRes = await h.send(
        'POST',
        '/api/v1/backups/$backupIdA/restore',
        token: token,
      );
      expect(restoreRes.statusCode, 200);
      final Map<String, Object?> restoreJson = await h.json(restoreRes);
      expect(restoreJson['ok'], isTrue);
      final Map<String, Object?> result =
          restoreJson['result']! as Map<String, Object?>;
      expect(result['restored_backup_id'], backupIdA);
      expect(result['safety_backup_id'], isNotNull);
      expect((result['safety_backup_id'] as String).startsWith('safety_'), isTrue);

      // 4. Verify ledger pulled is back to state A (3 transactions)
      final Response pullRestored = await h.send(
        'GET',
        '/api/v1/snapshot',
        token: token,
        device: 'pixel',
      );
      final Map<String, Object?> restoredSnap =
          jsonDecode(await pullRestored.readAsString()) as Map<String, Object?>;
      expect((restoredSnap['transactions'] as List).length, 3);
      expect(
        ((restoredSnap['transactions'] as List).first as Map)['merchant'],
        'STATE_A-0',
      );

      // 5. Verify safety backup exists in list with type 'pre_restore'
      final Response listResp = await h.send(
        'GET',
        '/api/v1/backups',
        token: token,
      );
      final List<Object?> allBackups =
          (await h.json(listResp))['backups']! as List<Object?>;
      final bool hasSafety = allBackups.any(
        (b) => (b as Map<String, Object?>)['type'] == 'pre_restore',
      );
      expect(hasSafety, isTrue);
    });
  });
}
