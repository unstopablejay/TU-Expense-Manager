/// Talking to the self-hosted server from the browser.
///
/// The bundle is served by that same server on the same port, so the base URL is
/// just wherever the page was loaded from. There is nothing to configure and no
/// CORS to get wrong, which is the main reason the API and the web assets share a
/// container.
///
/// Follows the app's existing network conventions: an explicit timeout on every
/// request because `http` has none of its own, and failures returned as a result
/// carrying a sentence fit to show a person rather than thrown at the UI.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/backup_data.dart';
import '../core/backup_json.dart';
import '../core/backup_validate.dart';
import '../core/constants.dart';
import '../core/edits.dart';
import '../core/snapshot_store.dart';

/// How long to wait. A snapshot can be a few megabytes over a VPN, so pulling
/// one is given a great deal longer than asking who you are.
const Duration kQuickTimeout = Duration(seconds: 10);
const Duration kSnapshotTimeout = Duration(seconds: 60);

/// A device the server holds a ledger for.
class RemoteDevice {
  const RemoteDevice({
    required this.id,
    required this.label,
    required this.lastSeen,
    this.transactions,
    this.pendingEdits = 0,
    this.snapshotId,
    this.syncMinutes,
  });

  factory RemoteDevice.fromJson(Map<String, Object?> json) {
    final Object? latest = json['latest'];
    final Map<String, Object?>? counts = latest is Map<String, Object?> &&
            latest['counts'] is Map<String, Object?>
        ? latest['counts']! as Map<String, Object?>
        : null;
    return RemoteDevice(
      id: json['id'] as String? ?? '',
      label: json['label'] as String? ?? json['id'] as String? ?? 'Unnamed',
      lastSeen: DateTime.tryParse(json['last_seen'] as String? ?? ''),
      transactions: int.tryParse('${counts?['transactions'] ?? ''}'),
      pendingEdits: (json['pending_edits'] as num?)?.toInt() ?? 0,
      syncMinutes: (json['sync_interval_minutes'] as num?)?.toInt(),
      snapshotId: latest is Map<String, Object?> ? latest['id'] as String? : null,
    );
  }

  final String id;
  final String label;
  final DateTime? lastSeen;

  /// How many transactions its current snapshot holds, or null if it has never
  /// synced. The device picker shows this so an empty ledger is distinguishable
  /// from a device that has not reported yet.
  final int? transactions;

  final int pendingEdits;
  final String? snapshotId;

  /// How often that device says it syncs, in minutes — null if it has not said,
  /// or if it syncs only when somebody presses the button.
  ///
  /// This is what lets the connection light tell "gone quiet" from "between
  /// syncs" without guessing at an interval.
  final int? syncMinutes;

  bool get hasSynced => snapshotId != null;
}

/// How a call went. Named constructors rather than nullable fields, the same
/// shape the updater's `UpdateCheck` uses.
class ApiResult<T> {
  const ApiResult.ok(T this.value) : error = null;

  const ApiResult.failed(String this.error) : value = null;

  final T? value;
  final String? error;

  bool get failed => error != null;
}

/// The browser's view of the server.
class ApiClient {
  ApiClient({http.Client? client, Uri? base})
      : _client = client ?? http.Client(),
        _base = base ?? Uri.base;

  final http.Client _client;
  final Uri _base;

  /// The session token, held in memory only.
  ///
  /// Persistence is [WebSession]'s job. Keeping the two apart means this class
  /// can be tested without a browser.
  String? token;

  Uri _url(String path) => _base.replace(path: path, query: '');

  Map<String, String> _headers({String? device, bool json = false}) =>
      <String, String>{
        if (token case final String t) 'Authorization': 'Bearer $t',
        if (device case final String d) 'X-Expense-Device': d,
        if (json) 'Content-Type': 'application/json; charset=utf-8',
      };

  /// Whether the server is there, and whether it has any accounts yet.
  Future<ApiResult<Map<String, Object?>>> health() =>
      _guard(() async {
        final http.Response response =
            await _client.get(_url('/api/health')).timeout(kQuickTimeout);
        if (response.statusCode != 200) {
          return ApiResult<Map<String, Object?>>.failed(
            'The server answered with ${response.statusCode}.',
          );
        }
        return ApiResult<Map<String, Object?>>.ok(_decodeMap(response.body));
      });

  /// Exchanges a username and password for a session token.
  Future<ApiResult<String>> login(String username, String password) =>
      _guard(() async {
        final http.Response response = await _client
            .post(
              _url('/api/v1/login'),
              headers: _headers(json: true),
              body: jsonEncode(<String, Object?>{
                'username': username,
                'password': password,
              }),
            )
            // Argon2id is deliberately slow, and slower still on NAS hardware, so
            // a login gets far longer than the other quick calls.
            .timeout(const Duration(seconds: 45));

        if (response.statusCode == 401) {
          return const ApiResult<String>.failed(
            'That username and password do not match an account.',
          );
        }
        if (response.statusCode != 200) {
          return ApiResult<String>.failed(
            _errorFrom(response) ??
                'Signing in failed (${response.statusCode}).',
          );
        }
        final Object? value = _decodeMap(response.body)['token'];
        return value is String
            ? ApiResult<String>.ok(value)
            : const ApiResult<String>.failed(
                'The server did not return a session.',
              );
      });

  Future<void> logout() async {
    try {
      await _client
          .post(_url('/api/v1/logout'), headers: _headers())
          .timeout(kQuickTimeout);
    } on Object {
      // Signing out locally is what matters, and the session expires on its own.
      // Failing here would leave the user apparently stuck signed in.
    }
    token = null;
  }

  /// Every device this account has a ledger for.
  Future<ApiResult<List<RemoteDevice>>> devices() => _guard(() async {
        final http.Response response = await _client
            .get(_url('/api/v1/devices'), headers: _headers())
            .timeout(kQuickTimeout);
        if (response.statusCode == 401) return _expired<List<RemoteDevice>>();
        if (response.statusCode != 200) {
          return ApiResult<List<RemoteDevice>>.failed(
            'The server answered with ${response.statusCode}.',
          );
        }
        final Object? raw = _decodeMap(response.body)['devices'];
        return ApiResult<List<RemoteDevice>>.ok(<RemoteDevice>[
          if (raw is List)
            for (final Object? entry in raw)
              if (entry is Map<String, Object?>) RemoteDevice.fromJson(entry),
        ]);
      });

  /// A device's current ledger, decoded, checked and joined.
  ///
  /// `validateBackup` runs here as well as on the phone. It is already written
  /// and costs nothing, and it turns a truncated download into a sentence the
  /// user can read instead of a stack trace behind a blank screen.
  Future<ApiResult<SnapshotStore>> snapshot({String? device, String? id}) =>
      _guard(() async {
        final String path = id == null
            ? '/api/v1/snapshot'
            : '/api/v1/snapshot/$id';
        final http.Response response = await _client
            .get(_url(path), headers: _headers(device: device))
            .timeout(kSnapshotTimeout);

        if (response.statusCode == 401) return _expired<SnapshotStore>();
        if (response.statusCode == 404) {
          return const ApiResult<SnapshotStore>.failed(
            'Nothing has been synced to this account yet. Open the app on your '
            'phone and tap Sync now.',
          );
        }
        if (response.statusCode != 200) {
          return ApiResult<SnapshotStore>.failed(
            'The server answered with ${response.statusCode}.',
          );
        }

        // utf8.decode rather than `.body`, because `.body` guesses the charset
        // from the headers and a merchant name with a rupee sign in it would
        // come back mangled.
        final BackupData data = decodeBackupJson(utf8.decode(response.bodyBytes));
        final List<String> problems =
            validateBackup(data, appSchemaVersion: kSchemaVersion);
        if (problems.isNotEmpty) {
          return ApiResult<SnapshotStore>.failed(problems.first);
        }
        return ApiResult<SnapshotStore>.ok(SnapshotStore.fromBackup(data));
      });

  /// A device's snapshot history, newest first.
  Future<ApiResult<List<Map<String, Object?>>>> history({String? device}) =>
      _guard(() async {
        final http.Response response = await _client
            .get(_url('/api/v1/snapshots'), headers: _headers(device: device))
            .timeout(kQuickTimeout);
        if (response.statusCode == 401) {
          return _expired<List<Map<String, Object?>>>();
        }
        if (response.statusCode != 200) {
          return ApiResult<List<Map<String, Object?>>>.failed(
            'The server answered with ${response.statusCode}.',
          );
        }
        final Object? raw = _decodeMap(response.body)['snapshots'];
        return ApiResult<List<Map<String, Object?>>>.ok(
          <Map<String, Object?>>[
            if (raw is List)
              for (final Object? entry in raw)
                if (entry is Map<String, Object?>) entry,
          ],
        );
      });

  /// Queues [edit] for [device] to apply on its next sync.
  Future<ApiResult<int>> queueEdit(LedgerEdit edit, {required String device}) =>
      _guard(() async {
        final http.Response response = await _client
            .post(
              _url('/api/v1/edits'),
              headers: _headers(device: device, json: true),
              body: jsonEncode(edit.toJson()),
            )
            .timeout(kQuickTimeout);
        if (response.statusCode == 401) return _expired<int>();
        if (response.statusCode != 201) {
          return ApiResult<int>.failed(
            _errorFrom(response) ??
                'The edit was not accepted (${response.statusCode}).',
          );
        }
        final Object? pending = _decodeMap(response.body)['pending'];
        return ApiResult<int>.ok((pending as num?)?.toInt() ?? 0);
      });

  /// What became of edits already applied, so the browser can say so.
  Future<ApiResult<List<Map<String, Object?>>>> appliedEdits({
    required String device,
  }) =>
      _guard(() async {
        final http.Response response = await _client
            .get(_url('/api/v1/edits/applied'), headers: _headers(device: device))
            .timeout(kQuickTimeout);
        if (response.statusCode != 200) {
          return const ApiResult<List<Map<String, Object?>>>.ok(
            <Map<String, Object?>>[],
          );
        }
        final Object? raw = _decodeMap(response.body)['applied'];
        return ApiResult<List<Map<String, Object?>>>.ok(<Map<String, Object?>>[
          if (raw is List)
            for (final Object? entry in raw)
              if (entry is Map<String, Object?>) entry,
        ]);
      });

  ApiResult<T> _expired<T>() => const ApiResult<Never>.failed(
        'That session has expired. Sign in again.',
      ) as ApiResult<T>;

  /// Turns anything thrown into a sentence.
  ///
  /// The app's own convention, from `UpdateService`: network code never throws at
  /// the UI, because there is nothing useful a widget can do with a SocketException
  /// that it cannot do with a message written for a person.
  Future<ApiResult<T>> _guard<T>(Future<ApiResult<T>> Function() call) async {
    try {
      return await call();
    } on TimeoutException {
      return ApiResult<T>.failed(
        'The server did not answer in time. If you are away from home, check '
        'the VPN is connected.',
      );
    } on BackupFormatException catch (error) {
      return ApiResult<T>.failed(error.message);
    } on http.ClientException catch (error) {
      return ApiResult<T>.failed('Could not reach the server: ${error.message}');
    } on Object {
      return ApiResult<T>.failed('Could not reach the server.');
    }
  }

  Map<String, Object?> _decodeMap(String body) {
    final Object? parsed = jsonDecode(body);
    return parsed is Map<String, Object?> ? parsed : <String, Object?>{};
  }

  /// The server's own message for a failure, where it sent one.
  String? _errorFrom(http.Response response) {
    try {
      final Object? error = _decodeMap(response.body)['error'];
      return error is String && error.isNotEmpty ? error : null;
    } on Object {
      return null;
    }
  }
}
