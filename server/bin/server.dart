/// The server binary.
///
/// Also the account-management tool and its own healthcheck, so the runtime image
/// needs no shell utilities and there is never an unauthenticated setup page:
///
///   server                          serve
///   server --healthcheck            exit 0 if the local server is answering
///   server --add-user jay           create an account, prompting for a password
///   server --set-password jay       change one
///   server --list-users
library;

import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

import 'package:tu_expense_server/api.dart';
import 'package:tu_expense_server/auth.dart';
import 'package:tu_expense_server/backup_manager.dart';
import 'package:tu_expense_server/backup_scheduler.dart';
import 'package:tu_expense_server/config.dart';
import 'package:tu_expense_server/edit_queue.dart';
import 'package:tu_expense_server/json_store.dart';
import 'package:tu_expense_server/snapshots.dart';

const String kVersion = String.fromEnvironment('APP_VERSION', defaultValue: 'dev');

Future<void> main(List<String> argv) async {
  final ArgParser parser = ArgParser()
    ..addFlag('healthcheck',
        negatable: false,
        help: 'Ask the local server whether it is answering, then exit.')
    ..addOption('add-user', help: 'Create an account with this username.')
    ..addOption('set-password', help: "Change an account's password.")
    ..addFlag('list-users', negatable: false)
    ..addFlag('backup-now',
        negatable: false,
        help: 'Take an immediate full server backup snapshot, then exit.')
    ..addOption('password',
        help: 'Supply the password instead of being prompted. Visible in the '
            'process list and the shell history, so prefer the prompt.')
    ..addFlag('help', abbr: 'h', negatable: false);

  final ArgResults args;
  try {
    args = parser.parse(argv);
  } on FormatException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln(parser.usage);
    exit(64);
  }

  if (args.flag('help')) {
    stdout.writeln('TU Expense Tracker server $kVersion\n');
    stdout.writeln(parser.usage);
    return;
  }

  final Config config;
  try {
    config = Config.fromEnvironment();
  } on ConfigError catch (error) {
    stderr.writeln('Configuration problem: ${error.message}');
    exit(78); // EX_CONFIG
  }

  if (args.flag('healthcheck')) {
    exit(await _healthcheck(config.port));
  }

  final Paths paths = Paths(config.dataDir);
  final WriteLock lock = WriteLock();
  final AuthStore auth = AuthStore(paths, lock);
  final BackupManager backupManager = BackupManager(
    paths: paths,
    lock: lock,
    backupDir: config.backupDir,
    keep: config.backupKeep,
    serverVersion: kVersion,
  );

  if (args.flag('backup-now')) {
    stdout.writeln('Creating on-demand server backup snapshot...');
    final BackupItem item = await backupManager.createBackup(
      type: 'manual',
      note: 'Manual CLI snapshot trigger',
    );
    stdout.writeln('Backup created: ${item.id} (${item.bytes} bytes, '
        '${item.counts['transactions'] ?? 0} transactions)');
    return;
  }

  if (args.option('add-user') case final String username) {
    exit(await _addUser(auth, username, args.option('password')));
  }
  if (args.option('set-password') case final String username) {
    exit(await _setPassword(auth, username, args.option('password')));
  }
  if (args.flag('list-users')) {
    for (final User user in (await auth.users()).values) {
      stdout.writeln('${user.username}\tcreated ${user.createdAt.toIso8601String()}');
    }
    return;
  }

  await _serve(config, paths, lock, auth, backupManager);
}

Future<void> _serve(
  Config config,
  Paths paths,
  WriteLock lock,
  AuthStore auth,
  BackupManager backupManager,
) async {
  await paths.root.create(recursive: true);

  // Before the first request, so that no login pays a one-off initialisation
  // cost which would leak whether an account exists.
  warmPasswordHasher();

  // Written before the first request is served, so there is no window in which
  // the server is up with no accounts on it.
  await _bootstrap(auth, config);

  if (!await auth.hasAnyUser()) {
    stderr.writeln(
      'Refusing to start: there are no accounts, and no EXPENSE_ADMIN_USER and\n'
      'EXPENSE_ADMIN_PASSWORD to create one from. A server nobody can sign in to\n'
      'would either be useless or, worse, look like it was working.\n\n'
      'Set both variables, or run:  server --add-user <name>',
    );
    exit(78);
  }

  final BackupScheduler scheduler = BackupScheduler(
    manager: backupManager,
    hour: config.backupScheduleHour,
    minute: config.backupScheduleMinute,
    enabled: config.backupEnabled,
  );
  scheduler.start();

  final Api api = Api(
    config: config,
    auth: auth,
    snapshots: SnapshotStore(paths, lock, keep: config.snapshotKeep),
    edits: EditQueueStore(paths, lock, expiry: config.editExpiry),
    backupManager: backupManager,
    scheduler: scheduler,
    version: kVersion,
  );

  final Handler handler = const Pipeline()
      .addMiddleware(_logRequests())
      .addMiddleware(_noStoreForApi)
      .addHandler(api.handler);

  final HttpServer server = await shelf_io.serve(
    handler,
    InternetAddress.anyIPv4,
    config.port,
    // Snapshots are a few MB of JSON and compress extremely well, which matters
    // on a phone syncing over a VPN.
    shared: false,
  );
  server.autoCompress = true;

  stdout.writeln('TU Expense Tracker server $kVersion');
  stdout.writeln('listening on http://${server.address.address}:${server.port}');
  stdout.writeln(config.describe());

  // So `docker stop` is a clean shutdown rather than a kill: in-flight writes
  // finish, and the atomic renames mean anything unfinished leaves the previous
  // state intact.
  for (final ProcessSignal signal in <ProcessSignal>[
    ProcessSignal.sigint,
    ProcessSignal.sigterm,
  ]) {
    signal.watch().listen((_) async {
      stdout.writeln('shutting down');
      scheduler.cancel();
      await server.close(force: false);
      exit(0);
    });
  }
}

/// Creates the first account from the environment, if there is none.
///
/// Only ever creates. Leaving the variables set in a compose file after the first
/// run is harmless, which is how compose files are actually used — and it means a
/// typo in one cannot silently reset a password.
Future<void> _bootstrap(AuthStore auth, Config config) async {
  final String? username = config.bootstrapUser;
  final String? password = config.bootstrapPassword;
  if (username == null || password == null) return;
  if (await auth.hasAnyUser()) return;

  final String? problem = await auth.addUser(username.toLowerCase(), password);
  if (problem != null) {
    stderr.writeln('Could not create the first account: $problem');
    exit(78);
  }
  stdout.writeln('Created the first account: ${username.toLowerCase()}');
}

Future<int> _addUser(AuthStore auth, String username, String? given) async {
  final String? password = given ?? _prompt('Password for $username: ');
  if (password == null) return 64;
  final String? problem = await auth.addUser(username.toLowerCase(), password);
  if (problem != null) {
    stderr.writeln(problem);
    return 65;
  }
  stdout.writeln('Created ${username.toLowerCase()}.');
  return 0;
}

Future<int> _setPassword(AuthStore auth, String username, String? given) async {
  final String? password = given ?? _prompt('New password for $username: ');
  if (password == null) return 64;
  final String? problem =
      await auth.setPassword(username.toLowerCase(), password);
  if (problem != null) {
    stderr.writeln(problem);
    return 65;
  }
  stdout.writeln('Changed the password for ${username.toLowerCase()}. '
      'Every session for that account has been signed out.');
  return 0;
}

/// Reads a password without echoing it.
String? _prompt(String message) {
  stdout.write(message);
  final bool interactive = stdin.hasTerminal;
  if (interactive) stdin.echoMode = false;
  try {
    final String? line = stdin.readLineSync();
    return (line == null || line.isEmpty) ? null : line;
  } finally {
    if (interactive) {
      stdin.echoMode = true;
      stdout.writeln();
    }
  }
}

/// Asks the local server whether it is answering.
///
/// Part of the binary so the runtime image needs no curl — the only job that
/// utility would have had is this one request.
Future<int> _healthcheck(int port) async {
  final HttpClient client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 3);
  try {
    final HttpClientRequest request = await client
        .get('127.0.0.1', port, '/api/health')
        .timeout(const Duration(seconds: 5));
    final HttpClientResponse response = await request.close();
    await response.drain<void>();
    return response.statusCode == 200 ? 0 : 1;
  } on Object {
    return 1;
  } finally {
    client.close(force: true);
  }
}

/// One line per request: what was asked, what came back, how big and how long.
///
/// Deliberately never the Authorization header, never a password and never a
/// snapshot body — the last of those is the user's entire financial history, and
/// a log is the easiest place to leak it from.
Middleware _logRequests() => (Handler inner) => (Request request) async {
      final Stopwatch watch = Stopwatch()..start();
      final Response response = await inner(request);
      watch.stop();
      final int? length = response.contentLength;
      stdout.writeln(
        '${request.method} /${request.url.path} '
        '${response.statusCode} '
        '${length == null ? '-' : '${length}b'} '
        '${watch.elapsedMilliseconds}ms',
      );
      return response;
    };

/// Stops a browser caching an API answer.
///
/// The snapshot endpoint returns a different body as soon as the phone syncs, and
/// a cached one would show a stale ledger with no way to tell. Static assets are
/// left alone, so the bundle still caches normally.
Handler _noStoreForApi(Handler inner) => (Request request) async {
      final Response response = await inner(request);
      if (!request.url.path.startsWith('api/')) return response;
      return response.change(headers: <String, String>{
        'Cache-Control': 'no-store',
      });
    };
