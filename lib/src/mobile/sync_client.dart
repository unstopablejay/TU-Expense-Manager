/// Pushing the ledger to a self-hosted server, and applying what came back.
///
/// The phone owns the ledger. A sync is four steps, in this order:
///
///   1. pull any edits made in a browser
///   2. apply them locally, through the same `AppDatabase` methods the app's own
///      screens use — so every invariant is enforced by the code that already
///      enforces it
///   3. push the resulting ledger as one whole snapshot
///   4. tell the server what became of each edit
///
/// Ordering matters. Applying before pushing means the snapshot the server ends
/// up holding already includes the edits, so a browser refresh shows them.
/// Acknowledging *after* the push means a crash in between re-applies an edit
/// rather than losing it, and re-applying is safe because every edit is
/// idempotent by `edit_id`.
///
/// Follows the updater's conventions: an explicit timeout on every request
/// because `http` has none of its own, and failures returned as a sentence fit
/// to show a person rather than thrown at the UI.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show compute;
import 'package:http/http.dart' as http;

import '../core/backup_data.dart';
import '../core/backup_json.dart';
import '../core/backup_validate.dart';
import '../core/constants.dart';
import '../core/edits.dart';
import '../core/ledger.dart';
import '../core/models.dart';
import '../core/splits.dart';
import 'database.dart';
import 'sync_prefs.dart';

/// How long each call may take.
///
/// A push carries the whole ledger over what may be a VPN, so it gets far longer
/// than the others. A login is slow for a different reason: the server hashes
/// with Argon2id on purpose, and on NAS hardware that is a second or three.
const Duration kSyncQuickTimeout = Duration(seconds: 15);
const Duration kSyncLoginTimeout = Duration(seconds: 45);
const Duration kSyncPushTimeout = Duration(seconds: 90);

/// How a sync went, in terms the Settings screen can show.
class SyncOutcome {
  const SyncOutcome.ok({
    required this.transactions,
    this.editsApplied = 0,
    this.editsSkipped = 0,
    this.editsRejected = 0,
  })  : error = null,
        signedOut = false;

  const SyncOutcome.failed(String this.error, {this.signedOut = false})
      : transactions = 0,
        editsApplied = 0,
        editsSkipped = 0,
        editsRejected = 0;

  final String? error;

  /// Whether the failure was the session expiring, so the screen can ask for a
  /// password rather than offering a pointless retry.
  final bool signedOut;

  final int transactions;
  final int editsApplied;
  final int editsSkipped;
  final int editsRejected;

  bool get failed => error != null;

  int get editsSeen => editsApplied + editsSkipped + editsRejected;

  /// One line for the user.
  String describe() {
    if (error != null) return error!;
    final StringBuffer out = StringBuffer(
      'Pushed $transactions transaction${transactions == 1 ? '' : 's'}',
    );
    if (editsApplied > 0) {
      out.write(', applied $editsApplied edit${editsApplied == 1 ? '' : 's'}');
    }
    // Said out loud rather than swallowed: an edit made on the PC that did not
    // take is exactly the thing the user needs to hear about.
    if (editsSkipped > 0) {
      out.write(', skipped $editsSkipped that no longer matched');
    }
    if (editsRejected > 0) {
      out.write(', refused $editsRejected');
    }
    return '${out.toString()}.';
  }
}

/// The phone's side of the sync.
class SyncClient {
  SyncClient({http.Client? client, AppDatabase? database, SyncPrefs? prefs})
      : _client = client ?? http.Client(),
        _db = database ?? AppDatabase.instance,
        _prefs = prefs ?? SyncPrefs.instance;

  static final SyncClient instance = SyncClient();

  final http.Client _client;
  final AppDatabase _db;
  final SyncPrefs _prefs;

  /// Whether a server is there and answering, without needing a session.
  ///
  /// Separate from signing in so that "wrong address" and "wrong password" are
  /// distinguishable, which is most of what makes setting this up bearable.
  Future<SyncOutcome> testConnection(Uri base) async {
    try {
      final http.Response response = await _client
          .get(_url(base, '/api/health'))
          .timeout(kSyncQuickTimeout);
      if (response.statusCode != 200) {
        return SyncOutcome.failed(
          'Something answered at that address, but it is not an expense '
          'server (${response.statusCode}).',
        );
      }
      final Map<String, Object?> body = _decode(response.body);
      if (body['service'] != 'tu-expense-server') {
        return const SyncOutcome.failed(
          'Something answered at that address, but it is not an expense server.',
        );
      }
      return const SyncOutcome.ok(transactions: 0);
    } on Object catch (error) {
      return SyncOutcome.failed(_explain(error));
    }
  }

  /// Exchanges a username and password for a session, and remembers it.
  Future<SyncOutcome> signIn({
    required Uri base,
    required String username,
    required String password,
  }) async {
    try {
      final String device = await _prefs.deviceId();
      final http.Response response = await _client
          .post(
            _url(base, '/api/v1/login'),
            headers: <String, String>{
              'Content-Type': 'application/json; charset=utf-8',
              'X-Expense-Device': device,
              'X-Expense-Device-Label': await _prefs.deviceLabel(),
            },
            body: jsonEncode(<String, Object?>{
              'username': username.trim().toLowerCase(),
              'password': password,
            }),
          )
          .timeout(kSyncLoginTimeout);

      if (response.statusCode == 401) {
        return const SyncOutcome.failed(
          'That username and password do not match an account on the server.',
        );
      }
      if (response.statusCode != 200) {
        return SyncOutcome.failed(
          _errorFrom(response) ?? 'Signing in failed (${response.statusCode}).',
        );
      }

      final Map<String, Object?> body = _decode(response.body);
      final Object? token = body['token'];
      if (token is! String || token.isEmpty) {
        return const SyncOutcome.failed(
          'The server did not return a session.',
        );
      }
      await _prefs.setSession(
        token: token,
        username: body['username'] as String? ?? username,
      );
      return const SyncOutcome.ok(transactions: 0);
    } on Object catch (error) {
      return SyncOutcome.failed(_explain(error));
    }
  }

  Future<void> signOut() async {
    final Uri? base = await _prefs.baseUrl();
    final String? token = await _prefs.token();
    if (base != null && token != null) {
      try {
        await _client
            .post(_url(base, '/api/v1/logout'),
                headers: <String, String>{'Authorization': 'Bearer $token'})
            .timeout(kSyncQuickTimeout);
      } on Object {
        // Local sign-out is what matters, and the session expires by itself.
        // Failing here would leave the user apparently unable to sign out.
      }
    }
    await _prefs.clearSession();
  }

  /// Drains the edit queue, applies it, pushes the ledger and acknowledges.
  ///
  /// [onChanged] is called if the ledger was actually modified, so the shell can
  /// reload — a background write it does not know about would otherwise leave
  /// stale rows on screen.
  Future<SyncOutcome> syncNow({VoidCallback? onChanged}) async {
    final Uri? base = await _prefs.baseUrl();
    final String? token = await _prefs.token();
    if (base == null) {
      return const SyncOutcome.failed(
        'No server address is set. Add one first.',
      );
    }
    if (token == null) {
      return const SyncOutcome.failed('Sign in to your server first.',
          signedOut: true);
    }

    try {
      // 1 & 2 — pull and apply. A failure to fetch the queue is not a reason to
      // skip the push: the ledger is still worth backing up.
      final _Applied applied = await _drainAndApply(base, token);
      if (applied.signedOut) {
        await _prefs.clearSession();
        return const SyncOutcome.failed(
          'That session has expired. Sign in again.',
          signedOut: true,
        );
      }
      if (applied.changedLedger) onChanged?.call();

      // 3 — push. Validated first, because a corrupt local ledger must never
      // replace the last good snapshot on the server.
      final BackupData data = await _db.exportAll();
      final List<String> problems =
          validateBackup(data, appSchemaVersion: kSchemaVersion);
      if (problems.isNotEmpty) {
        return SyncOutcome.failed(
          'Nothing was uploaded, because this ledger did not pass its own '
          'checks: ${problems.first}',
        );
      }

      // Off the UI isolate, exactly as the workbook writer does it: a few
      // thousand transactions is enough encoding to drop a frame.
      final String body = await compute(encodeBackupJson, data);
      final http.Response push = await _client
          .post(
            _url(base, '/api/v1/snapshot'),
            headers: <String, String>{
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json; charset=utf-8',
              'X-Expense-Device': await _prefs.deviceId(),
              'X-Expense-Device-Label': await _prefs.deviceLabel(),
            },
            body: body,
          )
          .timeout(kSyncPushTimeout);

      if (push.statusCode == 401) {
        await _prefs.clearSession();
        return const SyncOutcome.failed(
          'That session has expired. Sign in again.',
          signedOut: true,
        );
      }
      if (push.statusCode != 201) {
        return SyncOutcome.failed(
          _errorFrom(push) ?? 'The upload failed (${push.statusCode}).',
        );
      }

      // 4 — acknowledge, only now the push has succeeded. A crash before this
      // re-applies an edit next time, which is harmless; acknowledging first and
      // then failing to push would lose it.
      if (applied.acks.isNotEmpty) {
        await _acknowledge(base, token, applied.acks);
      }

      final SyncOutcome outcome = SyncOutcome.ok(
        transactions: data.transactions.length,
        editsApplied: applied.count(EditOutcome.applied),
        editsSkipped: applied.count(EditOutcome.skippedMissingRow),
        editsRejected: applied.count(EditOutcome.rejectedInvalid),
      );
      await _prefs.setLastResult(ok: true, message: outcome.describe());
      return outcome;
    } on Object catch (error) {
      final SyncOutcome outcome = SyncOutcome.failed(_explain(error));
      await _prefs.setLastResult(ok: false, message: outcome.describe());
      return outcome;
    }
  }

  /// Fetches the queue and applies each edit in sequence order.
  Future<_Applied> _drainAndApply(Uri base, String token) async {
    final http.Response response;
    try {
      response = await _client
          .get(
            _url(base, '/api/v1/edits'),
            headers: <String, String>{
              'Authorization': 'Bearer $token',
              'X-Expense-Device': await _prefs.deviceId(),
            },
          )
          .timeout(kSyncQuickTimeout);
    } on Object {
      // The push is still worth doing, so a queue that could not be read is not
      // fatal — it will be drained next time.
      return const _Applied(<EditAck>[], changedLedger: false);
    }

    if (response.statusCode == 401) {
      return const _Applied(<EditAck>[], changedLedger: false, signedOut: true);
    }
    if (response.statusCode != 200) {
      return const _Applied(<EditAck>[], changedLedger: false);
    }

    final EditQueue queue = EditQueue.decode(response.body);
    if (queue.isEmpty) {
      return const _Applied(<EditAck>[], changedLedger: false);
    }

    // Read once, and re-read after any change, because applying an edit can move
    // the rows a later edit resolves against.
    List<ExpenseTxn> ledger = await _db.transactions();
    final List<EditAck> acks = <EditAck>[];
    bool changed = false;

    for (final LedgerEdit edit in queue.edits) {
      final ExpenseTxn? target = edit.resolve(ledger);
      if (target == null) {
        acks.add(EditAck(
          edit.editId,
          EditOutcome.skippedMissingRow,
          detail: 'That transaction is no longer in this ledger.',
        ));
        continue;
      }

      try {
        await _apply(edit, target);
        acks.add(EditAck(edit.editId, EditOutcome.applied));
        changed = true;
        ledger = await _db.transactions();
      } on Object catch (error) {
        // A refusal, not a crash. `saveSplits` throws when lines do not sum, and
        // a category can have been deleted since the browser offered it.
        acks.add(EditAck(
          edit.editId,
          EditOutcome.rejectedInvalid,
          detail: _explain(error),
        ));
      }
    }

    return _Applied(acks, changedLedger: changed);
  }

  /// Applies one edit through the app's own write paths.
  ///
  /// Deliberately no new SQL. Every rule the app enforces — split sums, the
  /// denormalised category cache, a tombstone on delete so a rescan cannot
  /// resurrect the row — is enforced here by the same methods the phone's own
  /// screens call.
  Future<void> _apply(LedgerEdit edit, ExpenseTxn target) async {
    switch (edit.op) {
      case EditOp.setCategory:
        final int? categoryId = edit.categoryId;
        if (categoryId == null) {
          throw const FormatException('That edit named no category.');
        }
        await _db.setTransactionCategory(
          transactionId: target.id,
          categoryId: categoryId,
        );

      case EditOp.setNote:
        await _db.setTransactionNote(
          transactionId: target.id,
          // Through the app's own cleaner, so a note typed in a browser is
          // stored exactly as one typed on the phone would be.
          note: cleanNote(edit.note ?? ''),
        );

      case EditOp.saveSplits:
        final List<({int categoryId, double amount})> lines = edit.splitLines;
        if (lines.isEmpty) {
          await _db.clearSplits(target.id);
          return;
        }
        // The names come from this device's categories, not the browser's: its
        // idea of a name is as old as the snapshot it was looking at.
        final Map<int, String> names = <int, String>{
          for (final ExpenseCategory c in await _db.categories()) c.id: c.name,
        };
        await _db.saveSplits(
          target,
          <TxnSplit>[
            for (final ({int categoryId, double amount}) line in lines)
              TxnSplit(
                categoryId: line.categoryId,
                categoryName: names[line.categoryId] ?? kUncategorized,
                amount: line.amount,
              ),
          ],
        );

      case EditOp.deleteTxn:
        await _db.deleteTransaction(target);
    }
  }

  Future<void> _acknowledge(Uri base, String token, List<EditAck> acks) async {
    try {
      await _client
          .post(
            _url(base, '/api/v1/edits/ack'),
            headers: <String, String>{
              'Authorization': 'Bearer $token',
              'Content-Type': 'application/json; charset=utf-8',
              'X-Expense-Device': await _prefs.deviceId(),
            },
            body: jsonEncode(<String, Object?>{
              'outcomes': acks.map((EditAck a) => a.toJson()).toList(),
            }),
          )
          .timeout(kSyncQuickTimeout);
    } on Object {
      // Already applied and already pushed. A lost acknowledgement means the
      // same edits arrive again next sync and are applied again, which is a
      // no-op — so this is the one step that is safe to lose.
    }
  }

  Uri _url(Uri base, String path) => base.replace(
        path: '${base.path.replaceFirst(RegExp(r'/+$'), '')}$path',
        query: null,
      );

  Map<String, Object?> _decode(String body) {
    try {
      final Object? parsed = jsonDecode(body);
      return parsed is Map<String, Object?> ? parsed : <String, Object?>{};
    } on FormatException {
      return <String, Object?>{};
    }
  }

  String? _errorFrom(http.Response response) {
    final Object? error = _decode(response.body)['error'];
    return error is String && error.isNotEmpty ? error : null;
  }

  /// Anything thrown, as a sentence worth showing.
  ///
  /// The app's convention, from `UpdateService`: there is nothing a widget can do
  /// with a `SocketException` that it cannot do better with a message written for
  /// a person. The VPN hint earns its place — away from home it is by far the
  /// likeliest cause.
  String _explain(Object error) => switch (error) {
        TimeoutException() =>
          'The server did not answer in time. If you are away from home, check '
              'the VPN is connected.',
        SocketException() =>
          'Could not reach the server. Check the address, and the VPN if you '
              'are away from home.',
        http.ClientException() => 'Could not reach the server.',
        BackupFormatException(message: final String message) => message,
        FormatException(message: final String message) => message,
        _ => 'The sync failed: $error',
      };
}

/// What the drain step did.
class _Applied {
  const _Applied(
    this.acks, {
    required this.changedLedger,
    this.signedOut = false,
  });

  final List<EditAck> acks;

  /// Whether anything was actually written, so the shell only reloads when there
  /// is something to reload.
  final bool changedLedger;

  final bool signedOut;

  int count(EditOutcome outcome) =>
      acks.where((EditAck a) => a.outcome == outcome).length;
}

/// Matches Flutter's own, so `home_shell.dart` needs no import for it.
typedef VoidCallback = void Function();
