// The server, exercised through its HTTP surface.
//
// Driven through the real handler with real files in a temporary directory,
// rather than by unit-testing the stores behind it. Everything interesting here
// is about how the pieces meet — a 401 that should not be a 500, a queue that
// must not be shared between devices, a write that must not be observable
// half-done — and none of that shows up in a store tested on its own.
//
// Argon2id is deliberately expensive, so tests that log in are slow by design.
// A shared session is set up once and reused, and the few tests that need their
// own account say why.

import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import 'package:tu_expense_server/api.dart';
import 'package:tu_expense_server/auth.dart';
import 'package:tu_expense_server/config.dart';
import 'package:tu_expense_server/edit_queue.dart';
import 'package:tu_expense_server/json_store.dart';
import 'package:tu_expense_server/snapshots.dart';

/// A server on a fresh directory, plus everything needed to talk to it.
class Harness {
  Harness(this.dir, this.handler, this.auth, this.snapshots);

  static Future<Harness> start({int keep = 30, int maxUpload = 32 * 1024 * 1024}) async {
    final Directory dir =
        await Directory.systemTemp.createTemp('tu-expense-server-test');
    final Config config = Config.fromEnvironment(<String, String>{
      'DATA_DIR': dir.path,
      'WEB_ROOT': '${dir.path}/no-web-bundle-here',
      'SNAPSHOT_KEEP': '$keep',
      'MAX_UPLOAD_BYTES': '$maxUpload',
    });
    final Paths paths = Paths(config.dataDir);
    final WriteLock lock = WriteLock();
    final AuthStore auth = AuthStore(paths, lock);
    final SnapshotStore snapshots =
        SnapshotStore(paths, lock, keep: config.snapshotKeep);
    final Api api = Api(
      config: config,
      auth: auth,
      snapshots: snapshots,
      edits: EditQueueStore(paths, lock, expiry: config.editExpiry),
      version: 'test',
    );
    return Harness(dir, api.handler, auth, snapshots);
  }

  final Directory dir;
  final Handler handler;
  final AuthStore auth;
  final SnapshotStore snapshots;

  Future<void> dispose() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  Future<Response> send(
    String method,
    String path, {
    Object? body,
    String? token,
    String? device,
    String? label,
    String? syncInterval,
  }) async =>
      handler(Request(
        method,
        Uri.parse('http://localhost$path'),
        headers: <String, String>{
          if (token != null) 'Authorization': 'Bearer $token',
          if (device case final String d) kDeviceHeader: d,
          if (label case final String l) kDeviceLabelHeader: l,
          if (syncInterval case final String s) kSyncIntervalHeader: s,
          if (body != null) 'Content-Type': 'application/json',
        },
        body: body is String ? body : (body == null ? null : jsonEncode(body)),
      ));

  Future<Map<String, Object?>> json(Response response) async =>
      jsonDecode(await response.readAsString()) as Map<String, Object?>;

  /// Logs in and returns the token.
  Future<String> login(String user, String password, {String? device}) async {
    final Response response = await send(
      'POST',
      '/api/v1/login',
      body: <String, Object?>{'username': user, 'password': password},
      device: device,
      label: device == null ? null : 'Label for $device',
    );
    return (await json(response))['token']! as String;
  }
}

/// A snapshot body shaped like the app's, with [n] transactions.
String snapshotBody(int n, {String merchant = 'SWIGGY', int schema = 7}) =>
    jsonEncode(<String, Object?>{
      'format': kSnapshotFormat,
      'format_version': 1,
      'meta': <String, String>{
        'format': kSnapshotFormat,
        'format_version': '1',
        'schema_version': '$schema',
        'app_version': '1.1.0',
        'app_build': '2',
        'exported_at': DateTime.now().toUtc().toIso8601String(),
        'transactions': '$n',
      },
      'categories': <Map<String, Object?>>[
        <String, Object?>{'id': 1, 'name': 'Uncategorized'},
      ],
      'transactions': <Map<String, Object?>>[
        for (int i = 0; i < n; i++)
          <String, Object?>{
            'id': i + 1,
            'amount': 100.0 * (i + 1),
            'merchant': '$merchant-$i',
            'date': 1755000000000 + i,
            'category_id': 1,
            'direction': 'debit',
            'reference': '',
            'note': '',
          },
      ],
    });

Map<String, Object?> editBody(String id, {String op = 'set_note'}) =>
    <String, Object?>{
      'edit_id': id,
      'op': op,
      'txn_id': 1,
      'natural_key': 'a-natural-key',
      'payload': <String, Object?>{'note': 'typed on the PC'},
    };

void main() {
  const String password = 'a long test passphrase';

  group('health', () {
    late Harness h;
    setUp(() async => h = await Harness.start());
    tearDown(() async => h.dispose());

    test('answers without credentials', () async {
      // The Docker healthcheck has none, and the phone's Test-connection needs
      // to tell a wrong address apart from a wrong password.
      final Response response = await h.send('GET', '/api/health');
      expect(response.statusCode, 200);
      final Map<String, Object?> body = await h.json(response);
      expect(body['ok'], isTrue);
      expect(body['has_accounts'], isFalse);
    });

    test('says once an account exists, and nothing about the data', () async {
      await h.auth.addUser('jay', password);
      final Map<String, Object?> body =
          await h.json(await h.send('GET', '/api/health'));
      expect(body['has_accounts'], isTrue);
      expect(body.keys, isNot(contains('devices')));
      expect(body.keys, isNot(contains('transactions')));
    });
  });

  group('accounts', () {
    late Harness h;
    setUp(() async => h = await Harness.start());
    tearDown(() async => h.dispose());

    test('a username has to be lower case and plausible', () {
      expect(usernameProblem('jay'), isNull);
      expect(usernameProblem('jay.s_2'), isNull);
      expect(usernameProblem('Jay'), isNotNull);
      expect(usernameProblem('j'), isNotNull);
      expect(usernameProblem('.hidden'), isNotNull);
      expect(usernameProblem('../etc/passwd'), isNotNull);
      expect(usernameProblem(''), isNotNull);
    });

    test('a password has a length floor and no composition rules', () {
      // Composition rules push people towards Passw0rd! and away from the long
      // passphrase that actually resists an offline attack.
      expect(passwordProblem('a long test passphrase'), isNull);
      expect(passwordProblem('short'), isNotNull);
      expect(passwordProblem('all lower case words only'), isNull);
    });

    test('an account cannot be created twice', () async {
      expect(await h.auth.addUser('jay', password), isNull);
      expect(await h.auth.addUser('jay', 'another passphrase'), isNotNull);
    });

    test('the password is not stored, and neither is a reversible form', () async {
      await h.auth.addUser('jay', password);
      final String stored =
          await File('${h.dir.path}/users.json').readAsString();
      expect(stored, isNot(contains(password)));
      expect(stored, contains('"salt"'));
      expect(stored, contains('"hash"'));
    });

    test('two accounts with the same password get different hashes', () async {
      // Per-user salts, so one cracked hash says nothing about the other.
      await h.auth.addUser('jay', password);
      await h.auth.addUser('sam', password);
      final Map<String, User> users = await h.auth.users();
      expect(users['jay']!.hash, isNot(users['sam']!.hash));
      expect(users['jay']!.salt, isNot(users['sam']!.salt));
    });
  });

  group('signing in', () {
    late Harness h;
    setUp(() async {
      h = await Harness.start();
      await h.auth.addUser('jay', password);
    });
    tearDown(() async => h.dispose());

    test('the right password returns a token', () async {
      final Response response = await h.send('POST', '/api/v1/login',
          body: <String, Object?>{'username': 'jay', 'password': password});
      expect(response.statusCode, 200);
      final Map<String, Object?> body = await h.json(response);
      expect(body['token'], isA<String>());
      expect((body['token']! as String).length, greaterThan(32));
      expect(body['username'], 'jay');
    });

    test('a wrong password and an unknown user are indistinguishable', () async {
      // Same status and same words, so the response cannot be used to find out
      // which accounts exist.
      final Response wrong = await h.send('POST', '/api/v1/login',
          body: <String, Object?>{'username': 'jay', 'password': 'nope'});
      final Response missing = await h.send('POST', '/api/v1/login',
          body: <String, Object?>{'username': 'nobody', 'password': 'nope'});
      expect(wrong.statusCode, 401);
      expect(missing.statusCode, 401);
      expect(await h.json(wrong), await h.json(missing));
    });

    test('a username is matched case-insensitively', () async {
      final Response response = await h.send('POST', '/api/v1/login',
          body: <String, Object?>{'username': 'JAY', 'password': password});
      expect(response.statusCode, 200);
    });

    test('a malformed login is refused rather than crashing', () async {
      expect((await h.send('POST', '/api/v1/login', body: 'not json')).statusCode, 400);
      expect((await h.send('POST', '/api/v1/login', body: <String, Object?>{})).statusCode, 400);
      expect(
        (await h.send('POST', '/api/v1/login',
                body: <String, Object?>{'username': 1, 'password': 2}))
            .statusCode,
        400,
      );
    });

    test('changing a password signs every session out', () async {
      // What someone does when they think a credential has leaked. Leaving the
      // old sessions alive would make the act pointless.
      final String token = await h.login('jay', password);
      expect((await h.send('GET', '/api/v1/me', token: token)).statusCode, 200);

      await h.auth.setPassword('jay', 'a different passphrase');
      expect((await h.send('GET', '/api/v1/me', token: token)).statusCode, 401);
    });

    test('logging out ends that session', () async {
      final String token = await h.login('jay', password);
      expect((await h.send('POST', '/api/v1/logout', token: token)).statusCode, 200);
      expect((await h.send('GET', '/api/v1/me', token: token)).statusCode, 401);
    });
  });

  group('what an unauthenticated request gets', () {
    late Harness h;
    setUp(() async {
      h = await Harness.start();
      await h.auth.addUser('jay', password);
    });
    tearDown(() async => h.dispose());

    // Every authenticated route, so a new one cannot be added unguarded without
    // this failing. The first version of the wrapper returned 500 here, which is
    // the sort of thing that looks like it is working.
    for (final (String, String) route in <(String, String)>[
      ('GET', '/api/v1/me'),
      ('GET', '/api/v1/devices'),
      ('POST', '/api/v1/snapshot'),
      ('GET', '/api/v1/snapshot'),
      ('GET', '/api/v1/snapshots'),
      ('POST', '/api/v1/edits'),
      ('GET', '/api/v1/edits'),
      ('POST', '/api/v1/edits/ack'),
      ('GET', '/api/v1/edits/applied'),
      ('POST', '/api/v1/logout'),
    ]) {
      test('${route.$1} ${route.$2} is 401, not 500', () async {
        final Response none = await h.send(route.$1, route.$2, device: 'd1');
        expect(none.statusCode, 401, reason: 'no token');

        final Response junk =
            await h.send(route.$1, route.$2, token: 'nonsense', device: 'd1');
        expect(junk.statusCode, 401, reason: 'a token that is not one');
      });
    }
  });

  group('snapshots', () {
    late Harness h;
    late String token;
    setUp(() async {
      h = await Harness.start();
      await h.auth.addUser('jay', password);
      token = await h.login('jay', password);
    });
    tearDown(() async => h.dispose());

    test('a push is stored and can be read back byte for byte', () async {
      final String body = snapshotBody(3);
      final Response push = await h.send('POST', '/api/v1/snapshot',
          body: body, token: token, device: 'phone', label: 'Jays Pixel');
      expect(push.statusCode, 201);
      final Map<String, Object?> info = await h.json(push);
      expect(info['bytes'], body.length);
      expect((info['counts']! as Map<String, Object?>)['transactions'], '3');
      expect(info['schema_version'], 7);

      final Response pull =
          await h.send('GET', '/api/v1/snapshot', token: token, device: 'phone');
      expect(pull.statusCode, 200);
      expect(await pull.readAsString(), body);
    });

    test('a push needs to name its device', () async {
      final Response response = await h.send('POST', '/api/v1/snapshot',
          body: snapshotBody(1), token: token);
      expect(response.statusCode, 400);
      expect((await h.json(response))['error'], contains(kDeviceHeader));
    });

    test('a body that is not one of our snapshots is refused', () async {
      for (final String body in <String>[
        'not json at all',
        '[]',
        '{"hello":"world"}',
        '{"format":"some-other-app"}',
      ]) {
        final Response response = await h.send('POST', '/api/v1/snapshot',
            body: body, token: token, device: 'phone');
        expect(response.statusCode, 400, reason: body);
      }
    });

    test('an oversized push is refused, and nothing is stored', () async {
      // 1024 is the config's own floor: it refuses a limit lower than that as
      // nonsense, which is why this is not smaller.
      final Harness small = await Harness.start(maxUpload: 1024);
      addTearDown(small.dispose);
      await small.auth.addUser('jay', password);
      final String t = await small.login('jay', password);

      final Response response = await small.send('POST', '/api/v1/snapshot',
          body: snapshotBody(50), token: t, device: 'phone');
      expect(response.statusCode, 413);
      expect(
        (await small.send('GET', '/api/v1/snapshot', token: t, device: 'phone'))
            .statusCode,
        404,
        reason: 'a refused push must not become the current snapshot',
      );
    });

    test('before the first push there is nothing, and that is a 404', () async {
      final Response response =
          await h.send('GET', '/api/v1/snapshot', token: token, device: 'phone');
      expect(response.statusCode, 404);
    });

    test('history keeps every push, newest first', () async {
      for (int i = 1; i <= 3; i++) {
        await h.send('POST', '/api/v1/snapshot',
            body: snapshotBody(i), token: token, device: 'phone');
      }
      final Map<String, Object?> body = await h.json(
          await h.send('GET', '/api/v1/snapshots', token: token, device: 'phone'));
      final List<Object?> snapshots = body['snapshots']! as List<Object?>;
      expect(snapshots.length, 3);

      final List<String> ids = <String>[
        for (final Object? s in snapshots) (s! as Map<String, Object?>)['id']! as String,
      ];
      expect(ids, orderedEquals(<String>[...ids]..sort((String a, String b) => b.compareTo(a))));

      // The dates come from the ids rather than from file mtimes, which is what
      // the microsecond-aware parse is for.
      for (final Object? s in snapshots) {
        final String at = (s! as Map<String, Object?>)['at']! as String;
        expect(DateTime.parse(at).year, DateTime.now().year);
      }
    });

    test('retention keeps the newest and drops the rest', () async {
      final Harness small = await Harness.start(keep: 3);
      addTearDown(small.dispose);
      await small.auth.addUser('jay', password);
      final String t = await small.login('jay', password);

      for (int i = 1; i <= 6; i++) {
        await small.send('POST', '/api/v1/snapshot',
            body: snapshotBody(i), token: t, device: 'phone');
      }
      final Map<String, Object?> body = await small.json(
          await small.send('GET', '/api/v1/snapshots', token: t, device: 'phone'));
      expect((body['snapshots']! as List<Object?>).length, 3);

      // And the one that survived is the last one pushed, not the first.
      final Map<String, Object?> latest = await small.json(
          await small.send('GET', '/api/v1/snapshot', token: t, device: 'phone'));
      expect((latest['meta']! as Map<String, Object?>)['transactions'], '6');
    });

    test('an older snapshot can be fetched by id', () async {
      await h.send('POST', '/api/v1/snapshot',
          body: snapshotBody(1), token: token, device: 'phone');
      await h.send('POST', '/api/v1/snapshot',
          body: snapshotBody(2), token: token, device: 'phone');

      final Map<String, Object?> list = await h.json(
          await h.send('GET', '/api/v1/snapshots', token: token, device: 'phone'));
      final String older = ((list['snapshots']! as List<Object?>).last
          as Map<String, Object?>)['id']! as String;

      final Response response = await h.send('GET', '/api/v1/snapshot/$older',
          token: token, device: 'phone');
      expect(response.statusCode, 200);
      final Map<String, Object?> body =
          jsonDecode(await response.readAsString()) as Map<String, Object?>;
      expect((body['meta']! as Map<String, Object?>)['transactions'], '1');
    });

    test('a snapshot id cannot escape its directory', () async {
      // The id reaches the filesystem, so this is the path that matters.
      final Response response = await h.send(
        'GET',
        '/api/v1/snapshot/${Uri.encodeComponent('../../../../etc/passwd')}',
        token: token,
        device: 'phone',
      );
      expect(response.statusCode, 404);
    });
  });

  group('two devices on one account', () {
    late Harness h;
    late String token;
    setUp(() async {
      h = await Harness.start();
      await h.auth.addUser('jay', password);
      token = await h.login('jay', password);
    });
    tearDown(() async => h.dispose());

    test('neither can overwrite the other', () async {
      // The bug this layout exists to prevent. With one snapshot slot, the
      // second push would destroy the first device's ledger — which, with a
      // phone and an emulator, is real data loss on the first sync.
      await h.send('POST', '/api/v1/snapshot',
          body: snapshotBody(3, merchant: 'PHONE'),
          token: token,
          device: 'phone',
          label: 'Jays Pixel');
      await h.send('POST', '/api/v1/snapshot',
          body: snapshotBody(7, merchant: 'EMU'),
          token: token,
          device: 'emulator',
          label: 'Android Emulator');

      final Map<String, Object?> phone = jsonDecode(await (await h.send(
              'GET', '/api/v1/snapshot',
              token: token, device: 'phone'))
          .readAsString()) as Map<String, Object?>;
      final Map<String, Object?> emulator = jsonDecode(await (await h.send(
              'GET', '/api/v1/snapshot',
              token: token, device: 'emulator'))
          .readAsString()) as Map<String, Object?>;

      expect((phone['meta']! as Map<String, Object?>)['transactions'], '3');
      expect((emulator['meta']! as Map<String, Object?>)['transactions'], '7');
      expect(jsonEncode(phone), contains('PHONE-0'));
      expect(jsonEncode(emulator), contains('EMU-0'));
    });

    test('both are listed, most recently synced first, with their labels', () async {
      await h.send('POST', '/api/v1/snapshot',
          body: snapshotBody(1), token: token, device: 'emulator', label: 'Emulator');
      await h.send('POST', '/api/v1/snapshot',
          body: snapshotBody(1), token: token, device: 'phone', label: 'Jays Pixel');

      final Map<String, Object?> body =
          await h.json(await h.send('GET', '/api/v1/devices', token: token));
      final List<Object?> devices = body['devices']! as List<Object?>;
      expect(devices.length, 2);
      expect((devices.first! as Map<String, Object?>)['id'], 'phone');
      expect((devices.first! as Map<String, Object?>)['label'], 'Jays Pixel');
    });

    test('a device says how often it syncs, so the browser can tell quiet from '
        'broken', () async {
      // Recorded and handed back, never acted on. It is what lets the browser's
      // connection light judge a phone by its own schedule instead of guessing
      // at one — and be wrong for anybody who changed the setting.
      await h.send('POST', '/api/v1/snapshot',
          body: snapshotBody(1),
          token: token,
          device: 'phone',
          syncInterval: '60');

      final Map<String, Object?> body =
          await h.json(await h.send('GET', '/api/v1/devices', token: token));
      final Map<String, Object?> phone =
          (body['devices']! as List<Object?>).first! as Map<String, Object?>;
      expect(phone['sync_interval_minutes'], 60);
    });

    test('an interval already known survives a client that sends none', () async {
      // An older build checking in must not wipe what a newer one reported, or
      // the light would fall back to a guess for no reason the user could see.
      await h.send('POST', '/api/v1/snapshot',
          body: snapshotBody(1),
          token: token,
          device: 'phone',
          syncInterval: '30');
      await h.send('POST', '/api/v1/snapshot',
          body: snapshotBody(2), token: token, device: 'phone');

      final Map<String, Object?> body =
          await h.json(await h.send('GET', '/api/v1/devices', token: token));
      final Map<String, Object?> phone =
          (body['devices']! as List<Object?>).first! as Map<String, Object?>;
      expect(phone['sync_interval_minutes'], 30);
    });

    test('pulling the edit queue counts as checking in', () async {
      // The bug this exists to prevent: last_seen used to move only on a push,
      // and an automatic sync does not push an unchanged ledger. A phone syncing
      // perfectly every quarter of an hour looked dead to the browser as soon as
      // it had a quiet afternoon.
      await h.send('POST', '/api/v1/snapshot',
          body: snapshotBody(1), token: token, device: 'phone');
      final Map<String, Object?> before =
          await h.json(await h.send('GET', '/api/v1/devices', token: token));
      final String pushedAt = ((before['devices']! as List<Object?>).first!
          as Map<String, Object?>)['last_seen']! as String;

      await Future<void>.delayed(const Duration(milliseconds: 5));
      await h.send('GET', '/api/v1/edits',
          token: token, device: 'phone', syncInterval: '15');

      final Map<String, Object?> after =
          await h.json(await h.send('GET', '/api/v1/devices', token: token));
      final Map<String, Object?> phone =
          (after['devices']! as List<Object?>).first! as Map<String, Object?>;
      expect(
        DateTime.parse(phone['last_seen']! as String)
            .isAfter(DateTime.parse(pushedAt)),
        isTrue,
      );
      expect(phone['sync_interval_minutes'], 15);
    });

    test('checking in does not invent a device nobody has synced', () async {
      // A heartbeat must not be a way to create devices, or a typo in a header
      // would fill the browser's picker with entries that have no ledger.
      await h.send('GET', '/api/v1/edits', token: token, device: 'ghost');

      final Map<String, Object?> body =
          await h.json(await h.send('GET', '/api/v1/devices', token: token));
      expect(body['devices'], isEmpty);
    });

    test('a nonsense interval is dropped rather than stored', () async {
      // Zero would mean "quiet for no time at all is already too long", and the
      // light would be red for a phone that had just synced.
      for (final String bad in <String>['0', '-5', 'soon', '999999']) {
        await h.send('POST', '/api/v1/snapshot',
            body: snapshotBody(1),
            token: token,
            device: 'phone',
            syncInterval: bad);

        final Map<String, Object?> body =
            await h.json(await h.send('GET', '/api/v1/devices', token: token));
        final Map<String, Object?> phone =
            (body['devices']! as List<Object?>).first! as Map<String, Object?>;
        expect(phone['sync_interval_minutes'], isNull, reason: 'for "$bad"');
      }
    });

    test('a browser naming no device gets the one that synced last', () async {
      await h.send('POST', '/api/v1/snapshot',
          body: snapshotBody(3, merchant: 'OLD'), token: token, device: 'emulator');
      await h.send('POST', '/api/v1/snapshot',
          body: snapshotBody(9, merchant: 'NEW'), token: token, device: 'phone');

      final Response response = await h.send('GET', '/api/v1/snapshot', token: token);
      expect(response.statusCode, 200);
      expect(response.headers[kDeviceHeader.toLowerCase()], 'phone');
      expect(await response.readAsString(), contains('NEW-0'));
    });

    test('a device can be forgotten, and only that device goes', () async {
      await h.send('POST', '/api/v1/snapshot',
          body: snapshotBody(1), token: token, device: 'phone');
      await h.send('POST', '/api/v1/snapshot',
          body: snapshotBody(1), token: token, device: 'emulator');

      expect(
        (await h.send('DELETE', '/api/v1/devices/emulator', token: token)).statusCode,
        200,
      );
      final Map<String, Object?> body =
          await h.json(await h.send('GET', '/api/v1/devices', token: token));
      expect((body['devices']! as List<Object?>).length, 1);
      expect(
        (await h.send('GET', '/api/v1/snapshot', token: token, device: 'phone'))
            .statusCode,
        200,
        reason: 'forgetting one device must not touch another',
      );
    });

    test('forgetting a device that is not there is a 404', () async {
      expect(
        (await h.send('DELETE', '/api/v1/devices/ghost', token: token)).statusCode,
        404,
      );
    });
  });

  group('one account cannot see another', () {
    late Harness h;
    setUp(() async {
      h = await Harness.start();
      await h.auth.addUser('jay', password);
      await h.auth.addUser('sam', password);
    });
    tearDown(() async => h.dispose());

    test("sam's token cannot read jay's snapshot", () async {
      // The scoping comes from the token and never from the request, so there is
      // no parameter to tamper with — this pins that.
      final String jay = await h.login('jay', password);
      final String sam = await h.login('sam', password);

      await h.send('POST', '/api/v1/snapshot',
          body: snapshotBody(5, merchant: 'JAYS'), token: jay, device: 'phone');

      final Response asSam =
          await h.send('GET', '/api/v1/snapshot', token: sam, device: 'phone');
      expect(asSam.statusCode, 404);

      final Map<String, Object?> samsDevices =
          await h.json(await h.send('GET', '/api/v1/devices', token: sam));
      expect(samsDevices['devices'], isEmpty);
    });

    test('a device name shared between accounts stays separate', () async {
      final String jay = await h.login('jay', password);
      final String sam = await h.login('sam', password);
      await h.send('POST', '/api/v1/snapshot',
          body: snapshotBody(3, merchant: 'JAYS'), token: jay, device: 'phone');
      await h.send('POST', '/api/v1/snapshot',
          body: snapshotBody(8, merchant: 'SAMS'), token: sam, device: 'phone');

      expect(
        await (await h.send('GET', '/api/v1/snapshot', token: jay, device: 'phone'))
            .readAsString(),
        contains('JAYS-0'),
      );
      expect(
        await (await h.send('GET', '/api/v1/snapshot', token: sam, device: 'phone'))
            .readAsString(),
        contains('SAMS-0'),
      );
    });
  });

  group('the edit queue', () {
    late Harness h;
    late String token;
    setUp(() async {
      h = await Harness.start();
      await h.auth.addUser('jay', password);
      token = await h.login('jay', password);
      await h.send('POST', '/api/v1/snapshot',
          body: snapshotBody(3), token: token, device: 'phone');
    });
    tearDown(() async => h.dispose());

    test('an edit is queued and comes back to the device it names', () async {
      final Response response = await h.send('POST', '/api/v1/edits',
          body: editBody('e1'), token: token, device: 'phone');
      expect(response.statusCode, 201);

      final Map<String, Object?> pending = await h.json(
          await h.send('GET', '/api/v1/edits', token: token, device: 'phone'));
      final List<Object?> edits = pending['edits']! as List<Object?>;
      expect(edits.length, 1);
      expect((edits.single! as Map<String, Object?>)['edit_id'], 'e1');
      expect((edits.single! as Map<String, Object?>)['seq'], 1);
      expect((edits.single! as Map<String, Object?>)['queued_at'], isA<String>());
    });

    test('the same edit_id twice queues once', () async {
      // The idempotency key. A browser retrying a request it was unsure about
      // must not double-apply.
      await h.send('POST', '/api/v1/edits',
          body: editBody('e1'), token: token, device: 'phone');
      final Map<String, Object?> again = await h.json(await h.send(
          'POST', '/api/v1/edits',
          body: editBody('e1'), token: token, device: 'phone'));

      final Map<String, Object?> queued =
          (again['queued']! as List<Object?>).single! as Map<String, Object?>;
      expect(queued['duplicate'], isTrue);
      expect(queued['seq'], 1, reason: 'the original sequence number');
      expect(again['pending'], 1);
    });

    test('sequence numbers are assigned in order and never reused', () async {
      for (final String id in <String>['e1', 'e2', 'e3']) {
        await h.send('POST', '/api/v1/edits',
            body: editBody(id), token: token, device: 'phone');
      }
      await h.send('POST', '/api/v1/edits/ack',
          body: <String, Object?>{
            'outcomes': <Object?>[
              <String, Object?>{'edit_id': 'e1', 'outcome': 'applied'},
              <String, Object?>{'edit_id': 'e2', 'outcome': 'applied'},
              <String, Object?>{'edit_id': 'e3', 'outcome': 'applied'},
            ],
          },
          token: token,
          device: 'phone');

      // Draining must not reset the counter: a later edit reusing a number an
      // earlier one had would make ordering meaningless.
      await h.send('POST', '/api/v1/edits',
          body: editBody('e4'), token: token, device: 'phone');
      final Map<String, Object?> pending = await h.json(
          await h.send('GET', '/api/v1/edits', token: token, device: 'phone'));
      expect(
        ((pending['edits']! as List<Object?>).single! as Map<String, Object?>)['seq'],
        4,
      );
    });

    test('a batch with one bad edit queues none of it', () async {
      final Response response = await h.send('POST', '/api/v1/edits',
          body: <String, Object?>{
            'edits': <Object?>[editBody('good'), editBody('bad', op: 'rm_rf')],
          },
          token: token,
          device: 'phone');
      expect(response.statusCode, 400);

      final Map<String, Object?> pending = await h.json(
          await h.send('GET', '/api/v1/edits', token: token, device: 'phone'));
      expect(pending['edits'], isEmpty,
          reason: 'half a batch is worse than none of it');
    });

    test('an op this server does not know is refused', () async {
      for (final String op in <String>['drop_database', '', 'set_categories']) {
        final Response response = await h.send('POST', '/api/v1/edits',
            body: editBody('e', op: op), token: token, device: 'phone');
        expect(response.statusCode, 400, reason: op);
      }
    });

    test('an edit without a natural key is refused', () async {
      final Map<String, Object?> body = editBody('e1')..remove('natural_key');
      expect(
        (await h.send('POST', '/api/v1/edits',
                body: body, token: token, device: 'phone'))
            .statusCode,
        400,
      );
    });

    test('an edit_id that is empty or absurd is refused', () async {
      expect(
        (await h.send('POST', '/api/v1/edits',
                body: editBody(''), token: token, device: 'phone'))
            .statusCode,
        400,
      );
      expect(
        (await h.send('POST', '/api/v1/edits',
                body: editBody('x' * 200), token: token, device: 'phone'))
            .statusCode,
        400,
      );
    });

    test('one device cannot see another device queue', () async {
      // An edit names a row id that means something else on another device, so a
      // shared queue would be a way to apply an edit to the wrong ledger.
      await h.send('POST', '/api/v1/edits',
          body: editBody('for-the-phone'), token: token, device: 'phone');

      final Map<String, Object?> emulator = await h.json(
          await h.send('GET', '/api/v1/edits', token: token, device: 'emulator'));
      expect(emulator['edits'], isEmpty);
    });

    test('an ack removes the edit and records what happened', () async {
      await h.send('POST', '/api/v1/edits',
          body: editBody('e1'), token: token, device: 'phone');
      await h.send('POST', '/api/v1/edits',
          body: editBody('e2', op: 'set_category'), token: token, device: 'phone');

      final Map<String, Object?> ack = await h.json(await h.send(
          'POST', '/api/v1/edits/ack',
          body: <String, Object?>{
            'outcomes': <Object?>[
              <String, Object?>{'edit_id': 'e1', 'outcome': 'applied'},
              <String, Object?>{
                'edit_id': 'e2',
                'outcome': 'skipped_missing_row',
                'detail': 'That transaction was deleted on the phone.',
              },
            ],
          },
          token: token,
          device: 'phone'));
      expect(ack['acknowledged'], 2);
      expect(ack['pending'], 0);

      final Map<String, Object?> applied = await h.json(await h.send(
          'GET', '/api/v1/edits/applied',
          token: token, device: 'phone'));
      final List<Object?> log = applied['applied']! as List<Object?>;
      expect(log.length, 2);
      expect(
        log.map((Object? e) => (e! as Map<String, Object?>)['outcome']),
        containsAll(<String>['applied', 'skipped_missing_row']),
      );
      expect(jsonEncode(log), contains('deleted on the phone'));
    });

    test('acking an unknown id is counted, not an error', () async {
      // A phone acking an edit that expired in between is a race, not a mistake,
      // and failing the call would strand the edits that did apply.
      await h.send('POST', '/api/v1/edits',
          body: editBody('real'), token: token, device: 'phone');

      final Map<String, Object?> ack = await h.json(await h.send(
          'POST', '/api/v1/edits/ack',
          body: <String, Object?>{
            'outcomes': <Object?>[
              <String, Object?>{'edit_id': 'real', 'outcome': 'applied'},
              <String, Object?>{'edit_id': 'ghost', 'outcome': 'applied'},
            ],
          },
          token: token,
          device: 'phone'));
      expect(ack['acknowledged'], 1);
      expect(ack['unknown'], 1);
    });

    test('an outcome this server does not know is logged as a refusal', () async {
      // Never as applied. Telling the user their edit took when it may not have
      // is the one wrong answer here.
      await h.send('POST', '/api/v1/edits',
          body: editBody('e1'), token: token, device: 'phone');
      await h.send('POST', '/api/v1/edits/ack',
          body: <String, Object?>{
            'outcomes': <Object?>[
              <String, Object?>{'edit_id': 'e1', 'outcome': 'went_fine_probably'},
            ],
          },
          token: token,
          device: 'phone');

      final Map<String, Object?> applied = await h.json(await h.send(
          'GET', '/api/v1/edits/applied',
          token: token, device: 'phone'));
      expect(
        ((applied['applied']! as List<Object?>).single as Map<String, Object?>)['outcome'],
        'rejected_invalid',
      );
    });

    test('a malformed ack is refused', () async {
      expect(
        (await h.send('POST', '/api/v1/edits/ack',
                body: <String, Object?>{'nope': 1}, token: token, device: 'phone'))
            .statusCode,
        400,
      );
    });

    test('the pending count shows up against the device', () async {
      await h.send('POST', '/api/v1/edits',
          body: editBody('e1'), token: token, device: 'phone');
      final Map<String, Object?> body =
          await h.json(await h.send('GET', '/api/v1/devices', token: token));
      final Map<String, Object?> phone =
          (body['devices']! as List<Object?>).first! as Map<String, Object?>;
      expect(phone['pending_edits'], 1);
    });
  });

  group('storage', () {
    late Harness h;
    setUp(() async => h = await Harness.start());
    tearDown(() async => h.dispose());

    test('a write leaves no temporary file behind', () async {
      await h.auth.addUser('jay', password);
      final String token = await h.login('jay', password);
      await h.send('POST', '/api/v1/snapshot',
          body: snapshotBody(3), token: token, device: 'phone');

      final List<String> leftovers = h.dir
          .listSync(recursive: true)
          .map((FileSystemEntity e) => e.path)
          .where((String p) => p.endsWith('.tmp'))
          .toList();
      expect(leftovers, isEmpty);
    });

    test('the layout is per user and per device', () async {
      await h.auth.addUser('jay', password);
      final String token = await h.login('jay', password);
      await h.send('POST', '/api/v1/snapshot',
          body: snapshotBody(1), token: token, device: 'phone');

      expect(
        Directory('${h.dir.path}/users/jay/devices/phone/snapshots').existsSync(),
        isTrue,
      );
      expect(File('${h.dir.path}/users/jay/devices/phone/latest.json').existsSync(),
          isTrue);
    });

    test('a path component cannot traverse or hide', () {
      expect(safePathComponent('../../etc'), isNot(contains('..')));
      expect(safePathComponent('..'), isNot('..'));
      expect(safePathComponent('.hidden'), isNot(startsWith('.')));
      expect(safePathComponent('a/b'), isNot(contains('/')));
      expect(safePathComponent(''), isNotEmpty);
      expect(safePathComponent('ok-name_1.2'), 'ok-name_1.2');
    });

    test('concurrent writes all land', () async {
      // The write lock's job. Without it a push that reads, awaits and writes
      // back could discard what another interleaved with it.
      await h.auth.addUser('jay', password);
      final String token = await h.login('jay', password);

      await Future.wait<Response>(<Future<Response>>[
        for (int i = 0; i < 8; i++)
          h.send('POST', '/api/v1/edits',
              body: editBody('e$i'), token: token, device: 'phone'),
      ]);

      final Map<String, Object?> pending = await h.json(
          await h.send('GET', '/api/v1/edits', token: token, device: 'phone'));
      final List<Object?> edits = pending['edits']! as List<Object?>;
      expect(edits.length, 8, reason: 'none may be lost to a race');

      final Set<Object?> seqs = <Object?>{
        for (final Object? e in edits) (e! as Map<String, Object?>)['seq'],
      };
      expect(seqs.length, 8, reason: 'and no sequence number may be reused');
    });

    test('concurrent snapshot pushes all get distinct ids', () async {
      await h.auth.addUser('jay', password);
      final String token = await h.login('jay', password);

      await Future.wait<Response>(<Future<Response>>[
        for (int i = 1; i <= 5; i++)
          h.send('POST', '/api/v1/snapshot',
              body: snapshotBody(i), token: token, device: 'phone'),
      ]);

      final Map<String, Object?> body = await h.json(
          await h.send('GET', '/api/v1/snapshots', token: token, device: 'phone'));
      final List<Object?> snapshots = body['snapshots']! as List<Object?>;
      final Set<Object?> ids = <Object?>{
        for (final Object? s in snapshots) (s! as Map<String, Object?>)['id'],
      };
      expect(ids.length, snapshots.length);
    });
  });

  group('the web bundle', () {
    test('a missing bundle is a message, not a crash', () async {
      // The API is useful without it, so a build that ships no web assets should
      // still start and still say something helpful in a browser.
      final Harness h = await Harness.start();
      addTearDown(h.dispose);
      final Response response = await h.send('GET', '/');
      expect(response.statusCode, 404);
      expect(await response.readAsString(), contains('/api/health'));
    });
  });

  group('config', () {
    test('the defaults are the documented ones', () {
      final Config config = Config.fromEnvironment(<String, String>{});
      expect(config.port, 8099);
      expect(config.dataDir, '/data');
      expect(config.snapshotKeep, 30);
      expect(config.maxUploadBytes, 32 * 1024 * 1024);
      expect(config.editExpiryDays, 30);
      expect(config.trustProxyHeaders, isFalse);
    });

    test('a nonsense number is refused rather than silently defaulted', () {
      // Falling back to a default here would mean a typo in a compose file
      // quietly changed the retention policy.
      expect(
        () => Config.fromEnvironment(<String, String>{'PORT': 'eight thousand'}),
        throwsA(isA<ConfigError>()),
      );
      expect(
        () => Config.fromEnvironment(<String, String>{'SNAPSHOT_KEEP': '0'}),
        throwsA(isA<ConfigError>()),
      );
    });

    test('the summary carries no secrets', () {
      final String described = Config.fromEnvironment(<String, String>{
        'EXPENSE_ADMIN_USER': 'jay',
        'EXPENSE_ADMIN_PASSWORD': 'a long test passphrase',
      }).describe();
      expect(described, isNot(contains('passphrase')));
    });
  });

  group('constant-time comparison', () {
    test('equal strings are equal', () {
      expect(constantTimeEquals('abc', 'abc'), isTrue);
      expect(constantTimeEquals('', ''), isTrue);
    });

    test('anything else is not', () {
      expect(constantTimeEquals('abc', 'abd'), isFalse);
      expect(constantTimeEquals('abc', 'abcd'), isFalse);
      expect(constantTimeEquals('abc', ''), isFalse);
      expect(constantTimeEquals('abc', 'ABC'), isFalse);
    });
  });
}
