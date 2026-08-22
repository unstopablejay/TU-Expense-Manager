@TestOn('vm')
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tu_expense_tracker/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PackageInfo.setMockInitialValues(
    appName: 'TU Expense Tracker',
    packageName: 'com.tu.expense.manager',
    version: '1.0.0',
    buildNumber: '1',
    buildSignature: '',
  );

  group('ServerBackup models', () {
    test('ServerBackupItem parses json and exposes helper properties', () {
      final ServerBackupItem item = ServerBackupItem.fromJson(<String, Object?>{
        'id': '2026-08-22T21-00-00-000Z',
        'at': '2026-08-22T21:00:00.000Z',
        'bytes': 10240,
        'type': 'auto',
        'note': 'Daily snapshot',
        'counts': <String, String>{'transactions': '42'},
        'server_version': '1.0.0',
      });

      expect(item.id, '2026-08-22T21-00-00-000Z');
      expect(item.bytes, 10240);
      expect(item.type, 'auto');
      expect(item.isAuto, isTrue);
      expect(item.isManual, isFalse);
      expect(item.isSafetyBackup, isFalse);
      expect(item.transactionsCount, 42);
      expect(item.note, 'Daily snapshot');
    });

    test('ServerBackupSchedule formats time and parses json', () {
      final ServerBackupSchedule schedule =
          ServerBackupSchedule.fromJson(<String, Object?>{
        'enabled': true,
        'hour': 21,
        'minute': 0,
        'keep': 10,
        'path': '/data/backups',
        'next_run': '2026-08-22T21:00:00.000Z',
      });

      expect(schedule.enabled, isTrue);
      expect(schedule.hour, 21);
      expect(schedule.minute, 0);
      expect(schedule.keep, 10);
      expect(schedule.path, '/data/backups');
      expect(schedule.timeFormatted, '9:00 PM');
      expect(schedule.nextRun, isNotNull);
    });
  });

  group('SyncClient backup methods', () {
    test('fetchServerBackups parses backups and schedule', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'sync.base_url': 'http://192.168.1.99:8099',
        'sync.token': 'test-session-token',
        'sync.username': 'jay',
      });

      final http.Client mockClient = MockClient((http.Request request) async {
        if (request.url.path == '/api/v1/backups') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'ok': true,
              'backups': <Map<String, Object?>>[
                <String, Object?>{
                  'id': 'backup_1',
                  'at': '2026-08-22T21:00:00.000Z',
                  'bytes': 5000,
                  'type': 'auto',
                  'counts': <String, String>{'transactions': '10'},
                },
              ],
              'schedule': <String, Object?>{
                'enabled': true,
                'hour': 21,
                'minute': 0,
                'keep': 10,
                'path': '/data/backups',
              },
            }),
            200,
          );
        }
        return http.Response('Not found', 404);
      });

      final SyncClient client = SyncClient(client: mockClient);
      final result = await client.fetchServerBackups();

      expect(result.error, isNull);
      expect(result.backups.length, 1);
      expect(result.backups.first.id, 'backup_1');
      expect(result.schedule, isNotNull);
      expect(result.schedule!.timeFormatted, '9:00 PM');
    });

    test('createServerBackup posts and returns created item', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'sync.base_url': 'http://192.168.1.99:8099',
        'sync.token': 'test-session-token',
      });

      final http.Client mockClient = MockClient((http.Request request) async {
        if (request.url.path == '/api/v1/backups' && request.method == 'POST') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'ok': true,
              'backup': <String, Object?>{
                'id': 'new_backup',
                'at': '2026-08-22T21:05:00.000Z',
                'bytes': 6200,
                'type': 'manual',
                'counts': <String, String>{'transactions': '15'},
              },
            }),
            201,
          );
        }
        return http.Response('Not found', 404);
      });

      final SyncClient client = SyncClient(client: mockClient);
      final result = await client.createServerBackup(note: 'Test note');

      expect(result.error, isNull);
      expect(result.backup, isNotNull);
      expect(result.backup!.id, 'new_backup');
      expect(result.backup!.type, 'manual');
    });

    test('restoreServerBackup posts and returns restored details', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'sync.base_url': 'http://192.168.1.99:8099',
        'sync.token': 'test-session-token',
      });

      final http.Client mockClient = MockClient((http.Request request) async {
        if (request.url.path == '/api/v1/backups/target_id/restore' &&
            request.method == 'POST') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'ok': true,
              'result': <String, Object?>{
                'ok': true,
                'restored_backup_id': 'target_id',
                'safety_backup_id': 'safety_123',
              },
            }),
            200,
          );
        }
        return http.Response('Not found', 404);
      });

      final SyncClient client = SyncClient(client: mockClient);
      final result = await client.restoreServerBackup('target_id');

      expect(result.ok, isTrue);
      expect(result.restoredId, 'target_id');
      expect(result.safetyId, 'safety_123');
    });
  });

  group('ServerBackupsSheet UI', () {
    testWidgets('displays schedule info and backup snapshots',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      SharedPreferences.setMockInitialValues(<String, Object>{
        'sync.base_url': 'http://192.168.1.99:8099',
        'sync.token': 'test-session-token',
        'sync.username': 'jay',
        'sync.device_id': 'device123',
      });

      final http.Client mockClient = MockClient((http.Request request) async {
        if (request.url.path == '/api/v1/backups') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'ok': true,
              'backups': <Map<String, Object?>>[
                <String, Object?>{
                  'id': 'backup_2026_08_22',
                  'at': '2026-08-22T21:00:00.000Z',
                  'bytes': 10240,
                  'type': 'auto',
                  'note': 'Scheduled nightly backup',
                  'counts': <String, String>{'transactions': '50'},
                },
              ],
              'schedule': <String, Object?>{
                'enabled': true,
                'hour': 21,
                'minute': 0,
                'keep': 10,
                'path': '/data/backups',
              },
            }),
            200,
          );
        }
        return http.Response('Not found', 404);
      });

      final SyncClient client = SyncClient(client: mockClient);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => Center(
                child: ElevatedButton(
                  onPressed: () => showServerBackupsSheet(context, client: client),
                  child: const Text('Open Backups'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Backups'));
      await tester.pumpAndSettle();

      expect(find.text('Server Rolling Backups'), findsOneWidget);
      expect(find.textContaining('Daily Schedule: 9:00 PM'), findsOneWidget);
      expect(find.textContaining('Retention: 10 rolling snapshots'), findsOneWidget);
      expect(find.text('Backup now'), findsOneWidget);
      expect(find.text('Daily Auto'), findsOneWidget);
      expect(find.textContaining('50 transactions'), findsOneWidget);
      expect(find.text('Restore'), findsOneWidget);
    });

    testWidgets('Backup now triggers snapshot creation and refreshes list',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      SharedPreferences.setMockInitialValues(<String, Object>{
        'sync.base_url': 'http://192.168.1.99:8099',
        'sync.token': 'test-session-token',
        'sync.username': 'jay',
        'sync.device_id': 'device123',
      });

      int backupPostCalls = 0;
      final http.Client mockClient = MockClient((http.Request request) async {
        if (request.url.path == '/api/v1/backups' && request.method == 'GET') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'ok': true,
              'backups': <Map<String, Object?>>[
                if (backupPostCalls > 0)
                  <String, Object?>{
                    'id': 'newly_created',
                    'at': '2026-08-22T21:05:00.000Z',
                    'bytes': 12000,
                    'type': 'manual',
                    'note': 'Manual snapshot from mobile settings',
                    'counts': <String, String>{'transactions': '55'},
                  },
              ],
              'schedule': <String, Object?>{
                'enabled': true,
                'hour': 21,
                'minute': 0,
                'keep': 10,
                'path': '/data/backups',
              },
            }),
            200,
          );
        }
        if (request.url.path == '/api/v1/backups' && request.method == 'POST') {
          backupPostCalls++;
          return http.Response(
            jsonEncode(<String, Object?>{
              'ok': true,
              'backup': <String, Object?>{
                'id': 'newly_created',
                'at': '2026-08-22T21:05:00.000Z',
                'bytes': 12000,
                'type': 'manual',
                'note': 'Manual snapshot from mobile settings',
                'counts': <String, String>{'transactions': '55'},
              },
            }),
            201,
          );
        }
        return http.Response('Not found', 404);
      });

      final SyncClient client = SyncClient(client: mockClient);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => Center(
                child: ElevatedButton(
                  onPressed: () => showServerBackupsSheet(context, client: client),
                  child: const Text('Open Backups'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Backups'));
      await tester.pumpAndSettle();

      expect(find.text('No server snapshots yet.\nTap "Backup now" to create one.'), findsOneWidget);

      await tester.tap(find.text('Backup now'));
      await tester.pumpAndSettle();

      expect(backupPostCalls, 1);
      expect(find.text('Manual'), findsOneWidget);
      expect(find.textContaining('55 transactions'), findsOneWidget);
    });

    testWidgets('Restore button shows confirmation dialog and cancels on Cancel',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      SharedPreferences.setMockInitialValues(<String, Object>{
        'sync.base_url': 'http://192.168.1.99:8099',
        'sync.token': 'test-session-token',
        'sync.username': 'jay',
        'sync.device_id': 'device123',
      });

      final http.Client mockClient = MockClient((http.Request request) async {
        if (request.url.path == '/api/v1/backups') {
          return http.Response(
            jsonEncode(<String, Object?>{
              'ok': true,
              'backups': <Map<String, Object?>>[
                <String, Object?>{
                  'id': 'backup_target',
                  'at': '2026-08-22T21:00:00.000Z',
                  'bytes': 8000,
                  'type': 'auto',
                  'counts': <String, String>{'transactions': '30'},
                },
              ],
              'schedule': <String, Object?>{
                'enabled': true,
                'hour': 21,
                'minute': 0,
                'keep': 10,
                'path': '/data/backups',
              },
            }),
            200,
          );
        }
        return http.Response('Not found', 404);
      });

      final SyncClient client = SyncClient(client: mockClient);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => Center(
                child: ElevatedButton(
                  onPressed: () => showServerBackupsSheet(context, client: client),
                  child: const Text('Open Backups'),
                ),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open Backups'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();

      expect(find.text('Restore Server Backup?'), findsOneWidget);
      expect(find.text('Restore Snapshot'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.text('Restore Server Backup?'), findsNothing);
    });
  });

  group('SettingsScreen integration', () {
    testWidgets('SettingsScreen displays Server rolling backups tile',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() => tester.view.resetPhysicalSize());

      SharedPreferences.setMockInitialValues(<String, Object>{
        'sync.base_url': 'http://192.168.1.99:8099',
        'sync.token': 'test-session-token',
        'sync.username': 'jay',
        'sync.device_id': 'device123',
        'sync.device_label': "Jay's Pixel",
        'sync.auto': true,
        'sync.auto_minutes': 15,
        'update.auto_check': false,
      });

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SettingsScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Server rolling backups'), findsOneWidget);
      expect(
        find.text('Daily 9:00 PM auto-backups, snapshot history and restore.'),
        findsOneWidget,
      );
    });
  });
}
