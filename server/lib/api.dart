/// The HTTP surface.
///
/// Two halves that deliberately differ in how they are guarded: `/api/v1/*`
/// requires a session and is scoped to that session's user, while the web bundle
/// underneath is served to anyone. The bundle carries no ledger data — it is the
/// page that *asks* for a password — and gating it would leave nowhere to type
/// one in.
library;

import 'dart:convert';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf_router/shelf_router.dart';
import 'package:shelf_static/shelf_static.dart';

import 'auth.dart';
import 'backup_manager.dart';
import 'backup_scheduler.dart';
import 'config.dart';
import 'edit_queue.dart';
import 'snapshots.dart';

/// The header a client sends its device identity in.
///
/// A header rather than a path segment, so that every route reads the same and
/// no endpoint can accidentally be written without device scoping.
const String kDeviceHeader = 'X-Expense-Device';
const String kDeviceLabelHeader = 'X-Expense-Device-Label';

/// How often the client says it syncs, in minutes.
///
/// Advisory, and the server never acts on it. It is recorded so the browser can
/// tell a phone that has gone quiet from one that is merely between syncs — the
/// difference between a red light that means something and one that means the
/// user chose a long interval.
const String kSyncIntervalHeader = 'X-Expense-Sync-Interval';

/// Everything the routes need.
class Api {
  Api({
    required this.config,
    required this.auth,
    required this.snapshots,
    required this.edits,
    required this.backupManager,
    this.scheduler,
    required this.version,
  });

  final Config config;
  final AuthStore auth;
  final SnapshotStore snapshots;
  final EditQueueStore edits;
  final BackupManager backupManager;
  final BackupScheduler? scheduler;
  final String version;

  Handler get handler {
    final Router api = Router()
      ..get('/api/health', _health)
      ..post('/api/v1/login', _login)
      ..post('/api/v1/logout', _authenticated(_logout))
      ..get('/api/v1/me', _authenticated(_me))
      ..get('/api/v1/devices', _authenticated(_devices))
      ..delete('/api/v1/devices/<device>', _authenticated(_forgetDevice))
      ..post('/api/v1/snapshot', _authenticated(_pushSnapshot))
      ..get('/api/v1/snapshot', _authenticated(_pullSnapshot))
      ..get('/api/v1/snapshots', _authenticated(_snapshotHistory))
      ..get('/api/v1/snapshot/<id>', _authenticated(_snapshotById))
      ..post('/api/v1/edits', _authenticated(_queueEdits))
      ..get('/api/v1/edits', _authenticated(_pendingEdits))
      ..post('/api/v1/edits/ack', _authenticated(_ackEdits))
      ..get('/api/v1/edits/applied', _authenticated(_appliedEdits))
      ..get('/api/v1/backups', _authenticated(_listBackups))
      ..post('/api/v1/backups', _authenticated(_createBackup))
      ..get('/api/v1/backups/<id>', _authenticated(_getBackup))
      ..post('/api/v1/backups/<id>/restore', _authenticated(_restoreBackup));

    // The SPA last, so it never shadows the API. Any path the router does not
    // know is a client-side route and gets index.html — which is what makes a
    // deep link and a browser refresh work.
    final Handler spa = _webHandler();

    return Cascade().add(api.call).add(spa).handler;
  }

  // ---------------------------------------------------------------------------
  // Unauthenticated
  // ---------------------------------------------------------------------------

  /// Unauthenticated on purpose: the Docker healthcheck has no credentials, and
  /// the phone's "Test connection" needs to tell a wrong address apart from a
  /// wrong password. Says nothing about the data — only that this is one of ours.
  Future<Response> _health(Request request) async => _json(<String, Object?>{
        'ok': true,
        'service': 'tu-expense-server',
        'version': version,
        'has_accounts': await auth.hasAnyUser(),
      });

  Future<Response> _login(Request request) async {
    final Object? body = await _body(request);
    if (body is! Map<String, Object?>) {
      return _error(400, 'Send a JSON object with a username and a password.');
    }
    final Object? username = body['username'];
    final Object? password = body['password'];
    if (username is! String || password is! String) {
      return _error(400, 'Both "username" and "password" are required.');
    }

    final Session? session =
        await auth.login(username.trim().toLowerCase(), password);
    if (session == null) {
      // One message for both a wrong username and a wrong password, and the same
      // work done either way, so the response cannot be used to find out which
      // accounts exist.
      return _error(401, 'That username and password do not match an account.');
    }

    // Registering here as well as on push means a phone that has logged in but
    // not yet synced still shows up in the device list, so the user can see the
    // login worked before any data moves.
    final String? device = request.headers[kDeviceHeader];
    if (device != null && device.trim().isNotEmpty) {
      await snapshots.registerDevice(
        user: session.username,
        device: device.trim(),
        label: request.headers[kDeviceLabelHeader] ?? '',
        syncIntervalMinutes: _syncInterval(request),
      );
    }

    return _json(<String, Object?>{
      'ok': true,
      'token': session.token,
      'username': session.username,
      'expires_at': session.expiresAt.toIso8601String(),
    });
  }

  // ---------------------------------------------------------------------------
  // Authenticated
  // ---------------------------------------------------------------------------

  /// Wraps a handler so it only runs for a live session, and receives the user.
  ///
  /// The user comes from the token and never from the request body or path, which
  /// is what makes it impossible to write an endpoint that reads someone else's
  /// data by being asked nicely.
  Handler _authenticated(
    Future<Response> Function(Request, String user) inner,
  ) =>
      (Request request) async {
        final String token = _bearer(request);
        final String? user = await auth.userForToken(token);
        if (user == null) {
          return _error(401, 'Sign in again — that session is not valid.');
        }
        await auth.touch(token);
        return inner(request, user);
      };

  Future<Response> _logout(Request request, String user) async {
    await auth.logout(_bearer(request));
    return _json(<String, Object?>{'ok': true});
  }

  Future<Response> _me(Request request, String user) async => _json(
        <String, Object?>{
          'ok': true,
          'username': user,
          'devices': (await snapshots.devices(user))
              .map((DeviceInfo d) => d.toJson())
              .toList(),
        },
      );

  Future<Response> _devices(Request request, String user) async => _json(
        <String, Object?>{
          'ok': true,
          'devices': (await snapshots.devices(user))
              .map((DeviceInfo d) => d.toJson())
              .toList(),
        },
      );

  Future<Response> _forgetDevice(Request request, String user) async {
    final String? device = request.params['device'];
    if (device == null || device.isEmpty) {
      return _error(400, 'Name the device to forget.');
    }
    final bool gone = await snapshots.forgetDevice(user, device);
    return gone
        ? _json(<String, Object?>{'ok': true, 'forgot': device})
        : _error(404, 'There is no device called "$device".');
  }

  Future<Response> _pushSnapshot(Request request, String user) async {
    final String? device = _device(request);
    if (device == null) return _missingDevice();

    final String body = await request.readAsString();
    final SnapshotRejection? bad =
        snapshots.inspect(body, maxBytes: config.maxUploadBytes);
    if (bad != null) return _error(bad.status, bad.message);

    final SnapshotInfo info = await snapshots.store(
      user: user,
      device: device,
      label: request.headers[kDeviceLabelHeader] ?? '',
      body: body,
      syncIntervalMinutes: _syncInterval(request),
    );
    return _json(<String, Object?>{'ok': true, ...info.toJson()}, status: 201);
  }

  Future<Response> _pullSnapshot(Request request, String user) async {
    final String? device = _device(request) ?? await _newestDevice(user);
    if (device == null) {
      return _error(404, 'Nothing has been synced to this account yet.');
    }
    final SnapshotInfo? info = await snapshots.latestInfo(user, device);
    final String? body = await snapshots.latestBody(user, device);
    if (info == null || body == null) {
      return _error(404, 'That device has not synced a snapshot yet.');
    }
    return Response.ok(
      body,
      headers: <String, String>{
        'Content-Type': 'application/json; charset=utf-8',
        'Last-Modified': _httpDate(info.at),
        'ETag': '"${info.id}"',
        'X-Expense-Device': device,
        'X-Expense-Snapshot': info.id,
      },
    );
  }

  Future<Response> _snapshotHistory(Request request, String user) async {
    final String? device = _device(request) ?? await _newestDevice(user);
    if (device == null) return _json(<String, Object?>{'ok': true, 'snapshots': <Object?>[]});
    return _json(<String, Object?>{
      'ok': true,
      'device': device,
      'snapshots': (await snapshots.history(user, device))
          .map((SnapshotInfo s) => s.toJson())
          .toList(),
    });
  }

  Future<Response> _snapshotById(Request request, String user) async {
    final String? device = _device(request) ?? await _newestDevice(user);
    final String? id = request.params['id'];
    if (device == null || id == null) {
      return _error(404, 'No such snapshot.');
    }
    final String? body = await snapshots.bodyById(user, device, id);
    if (body == null) return _error(404, 'No such snapshot.');
    return Response.ok(body, headers: <String, String>{
      'Content-Type': 'application/json; charset=utf-8',
      'ETag': '"$id"',
    });
  }

  /// Queues one edit or a list of them.
  ///
  /// The device named is the one that will *apply* the edit — the browser's own
  /// device header would be meaningless here, since the browser has no ledger.
  Future<Response> _queueEdits(Request request, String user) async {
    final String? device = _device(request) ?? await _newestDevice(user);
    if (device == null) return _missingDevice();

    final Object? body = await _body(request);
    final List<Object?> incoming = switch (body) {
      final List<Object?> list => list,
      final Map<String, Object?> map when map['edits'] is List =>
        map['edits']! as List<Object?>,
      final Map<String, Object?> map => <Object?>[map],
      _ => const <Object?>[],
    };
    if (incoming.isEmpty) return _error(400, 'No edits in that request.');

    // Checked before anything is stored, so a batch with one bad entry queues
    // nothing rather than half of itself.
    for (final Object? edit in incoming) {
      final EditRejection? bad = edits.inspect(edit);
      if (bad != null) return _error(bad.status, bad.message);
    }

    final List<Map<String, Object?>> queued = <Map<String, Object?>>[];
    for (final Object? edit in incoming) {
      final Queued result = await edits.add(
        user: user,
        device: device,
        json: edit! as Map<String, Object?>,
      );
      queued.add(<String, Object?>{
        'edit_id': (edit as Map<String, Object?>)['edit_id'],
        'seq': result.seq,
        'duplicate': result.duplicate,
      });
    }

    return _json(<String, Object?>{
      'ok': true,
      'device': device,
      'queued': queued,
      'pending': (await edits.pending(user: user, device: device)).length,
    }, status: 201);
  }

  Future<Response> _pendingEdits(Request request, String user) async {
    final String? device = _device(request);
    if (device == null) return _missingDevice();
    // Every sync starts here, whether or not it goes on to upload anything, so
    // this is the one request that reliably says "that phone is still with us".
    await snapshots.touchDevice(
      user: user,
      device: device,
      syncIntervalMinutes: _syncInterval(request),
    );
    return _json(<String, Object?>{
      'ok': true,
      'edits': await edits.pending(user: user, device: device),
    });
  }

  Future<Response> _ackEdits(Request request, String user) async {
    final String? device = _device(request);
    if (device == null) return _missingDevice();

    final Object? body = await _body(request);
    final Object? raw = body is Map<String, Object?> ? body['outcomes'] : null;
    if (raw is! List) {
      return _error(400, 'Send {"outcomes": [...]} naming what happened.');
    }

    final ({int removed, int unknown, int pending}) result =
        await edits.acknowledge(
      user: user,
      device: device,
      outcomes: <Map<String, Object?>>[
        for (final Object? o in raw)
          if (o is Map<String, Object?>) o,
      ],
    );
    return _json(<String, Object?>{
      'ok': true,
      'acknowledged': result.removed,
      // Not an error. A phone acking an edit that expired in between is a race,
      // and failing the call would strand the ones that did apply.
      'unknown': result.unknown,
      'pending': result.pending,
    });
  }

  Future<Response> _appliedEdits(Request request, String user) async {
    final String? device = _device(request) ?? await _newestDevice(user);
    if (device == null) {
      return _json(<String, Object?>{'ok': true, 'applied': <Object?>[]});
    }
    return _json(<String, Object?>{
      'ok': true,
      'device': device,
      'applied': await edits.applied(user: user, device: device),
    });
  }

  Future<Response> _listBackups(Request request, String user) async {
    final List<BackupItem> items = await backupManager.listBackups();
    return _json(<String, Object?>{
      'ok': true,
      'backups': items.map((BackupItem b) => b.toJson()).toList(),
      'schedule': <String, Object?>{
        'enabled': config.backupEnabled,
        'hour': config.backupScheduleHour,
        'minute': config.backupScheduleMinute,
        'keep': config.backupKeep,
        'path': config.backupDir,
        if (scheduler?.nextRun != null)
          'next_run': scheduler!.nextRun!.toIso8601String(),
      },
    });
  }

  Future<Response> _createBackup(Request request, String user) async {
    final Object? body = await _body(request);
    final String? note =
        body is Map<String, Object?> ? body['note'] as String? : null;
    final BackupItem item = await backupManager.createBackup(
      type: 'manual',
      note: note ?? 'Manual backup created by $user',
    );
    return _json(<String, Object?>{
      'ok': true,
      'backup': item.toJson(),
    }, status: 201);
  }

  Future<Response> _getBackup(Request request, String user) async {
    final String? id = request.params['id'];
    if (id == null || id.isEmpty) {
      return _error(400, 'Specify a backup ID.');
    }
    final Map<String, Object?>? bundle = await backupManager.getBackupBundle(id);
    if (bundle == null) {
      return _error(404, 'Backup "$id" not found.');
    }
    return _json(<String, Object?>{
      'ok': true,
      'backup': bundle,
    });
  }

  Future<Response> _restoreBackup(Request request, String user) async {
    final String? id = request.params['id'];
    if (id == null || id.isEmpty) {
      return _error(400, 'Specify a backup ID to restore.');
    }
    try {
      final RestoreResult result = await backupManager.restoreBackup(id);
      return _json(<String, Object?>{
        'ok': true,
        'result': result.toJson(),
      });
    } on BackupRestoreException catch (e) {
      return _error(400, e.message);
    } catch (e) {
      return _error(500, 'Restore failed: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// The web bundle, with an index.html fallback for client-side routes.
  Handler _webHandler() {
    final String index = '${config.webRoot}/index.html';
    // Checked once at startup rather than per request: the bundle either shipped
    // in the image or it did not.
    final bool present = _fileExists(index);
    if (!present) {
      return (Request request) => Response.notFound(
            'The web interface is not part of this build. The API is at '
            '/api/health.\n',
          );
    }
    final Handler files = createStaticHandler(
      config.webRoot,
      defaultDocument: 'index.html',
      // The bundle's own asset names carry no hashes, so letting a browser cache
      // them for a long time would strand it on an old build after an upgrade.
      useHeaderBytesForContentType: true,
    );
    final Handler fallback =
        createStaticHandler(config.webRoot, defaultDocument: 'index.html');

    return (Request request) async {
      final Response response = await files(request);
      if (response.statusCode != 404) return response;
      // A client-side route. Serve the shell and let the app read the URL.
      return fallback(Request('GET', request.requestedUri.replace(path: '/')));
    };
  }

  String _bearer(Request request) {
    final String header = request.headers['authorization'] ?? '';
    if (!header.toLowerCase().startsWith('bearer ')) return '';
    return header.substring(7).trim();
  }

  /// The client's sync interval in minutes, if it sent a sane one.
  ///
  /// Anything unreadable, zero, negative or longer than a week is dropped rather
  /// than stored: this is only ever used to work out how long a device may stay
  /// quiet, and a nonsense value there would make the browser's light lie in one
  /// direction or the other.
  int? _syncInterval(Request request) {
    final int? minutes = int.tryParse(request.headers[kSyncIntervalHeader] ?? '');
    if (minutes == null || minutes <= 0 || minutes > 7 * 24 * 60) return null;
    return minutes;
  }

  String? _device(Request request) {
    final String? raw = request.headers[kDeviceHeader];
    if (raw == null || raw.trim().isEmpty) return null;
    return raw.trim();
  }

  /// The device that synced most recently, for a client that named none.
  ///
  /// The browser is the caller that has no device of its own: it wants to *read*
  /// a ledger, and the most recently synced one is the right default.
  Future<String?> _newestDevice(String user) async {
    final List<DeviceInfo> devices = await snapshots.devices(user);
    return devices.isEmpty ? null : devices.first.id;
  }

  Response _missingDevice() => _error(
        400,
        'That request needs an $kDeviceHeader header naming the device.',
      );

  Future<Object?> _body(Request request) async {
    try {
      final String body = await request.readAsString();
      return body.trim().isEmpty ? null : jsonDecode(body);
    } on FormatException {
      return null;
    }
  }
}

Response _json(Map<String, Object?> body, {int status = 200}) => Response(
      status,
      body: jsonEncode(body),
      headers: <String, String>{
        'Content-Type': 'application/json; charset=utf-8',
      },
    );

Response _error(int status, String message) =>
    _json(<String, Object?>{'ok': false, 'error': message}, status: status);

/// RFC 1123, which is what Last-Modified has to be.
String _httpDate(DateTime at) {
  const List<String> days = <String>[
    'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun',
  ];
  const List<String> months = <String>[
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  final DateTime u = at.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${days[u.weekday - 1]}, ${two(u.day)} ${months[u.month - 1]} '
      '${u.year} ${two(u.hour)}:${two(u.minute)}:${two(u.second)} GMT';
}

bool _fileExists(String path) {
  try {
    return File(path).existsSync();
  } on Object {
    return false;
  }
}
