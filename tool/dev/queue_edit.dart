// Queues an edit against the server the way the browser does, for testing.
//
// Not part of the app, and not shipped in the image — it exists so an
// end-to-end sync can be exercised without a human clicking in a browser. It
// pulls the snapshot the phone pushed, reads it with the same `SnapshotStore`
// the web build uses, composes the edit with the same `composeEdit`, and posts
// it to the same endpoint with the same headers.
//
//   dart tool/dev/queue_edit.dart <base> <user> <password> <device> <merchant>
//       [--legacy]
//
// --legacy spells the amount in the natural key the way browser builds before
// `canonicalAmountKey` did — "500" rather than "500.0" — which is what is
// already sitting in the queues on a running server, and what the phone has to
// keep being able to apply.
library;

import 'dart:convert';
import 'dart:io';

import 'package:tu_expense_tracker/src/core/backup_json.dart';
import 'package:tu_expense_tracker/src/core/edits.dart';
import 'package:tu_expense_tracker/src/core/models.dart';
import 'package:tu_expense_tracker/src/core/snapshot_store.dart';

/// The natural key's field separator.
final String nul = String.fromCharCode(0);

Future<void> main(List<String> args) async {
  final String base = args[0];
  final String device = args[3];
  final String wanted = args[4].toLowerCase();
  final bool legacy = args.contains('--legacy');

  final HttpClient http = HttpClient();

  Future<Map<String, Object?>> call(
    String method,
    String path, {
    String? token,
    Object? body,
    String? deviceHeader,
    bool raw = false,
  }) async {
    final HttpClientRequest request =
        await http.openUrl(method, Uri.parse('$base$path'));
    if (token != null) request.headers.set('Authorization', 'Bearer $token');
    if (deviceHeader != null) {
      request.headers.set('X-Expense-Device', deviceHeader);
    }
    if (body != null) {
      request.headers.contentType =
          ContentType('application', 'json', charset: 'utf-8');
      request.write(jsonEncode(body));
    }
    final HttpClientResponse response = await request.close();
    final String text = await response.transform(utf8.decoder).join();
    if (raw) {
      return <String, Object?>{'raw': text, 'status': response.statusCode};
    }
    return <String, Object?>{
      ...jsonDecode(text) as Map<String, Object?>,
      'status': response.statusCode,
    };
  }

  final Map<String, Object?> login = await call(
    'POST',
    '/api/v1/login',
    body: <String, Object?>{'username': args[1], 'password': args[2]},
  );
  final String token = login['token']! as String;

  final Map<String, Object?> pulled = await call(
    'GET',
    '/api/v1/snapshot',
    token: token,
    deviceHeader: device,
    raw: true,
  );
  final SnapshotStore store =
      SnapshotStore.fromBackup(decodeBackupJson(pulled['raw']! as String));

  final ExpenseTxn target = store.transactions
      .firstWhere((ExpenseTxn t) => t.merchant.toLowerCase().contains(wanted));
  final ExpenseCategory category = store.categories
      .firstWhere((ExpenseCategory c) => c.name != 'Uncategorized');

  final LedgerEdit edit = composeEdit(
    editId: 'test-${legacy ? 'legacy' : 'current'}-${target.id}',
    op: EditOp.setCategory,
    txn: target,
    now: DateTime.now().toUtc(),
    categoryId: category.id,
  );

  Map<String, Object?> json = edit.toJson();
  if (legacy) {
    // What a browser built before the fix sent: on the web an integral double
    // prints without its fractional part.
    final List<String> fields = (json['natural_key']! as String).split(nul);
    fields[0] = fields[0].replaceFirst(RegExp(r'\.0$'), '');
    json = <String, Object?>{...json, 'natural_key': fields.join(nul)};
  }

  stdout.writeln(
      'target      : ${target.merchant} ${target.amount} (id ${target.id})');
  stdout.writeln('new category: ${category.name} (id ${category.id})');
  stdout.writeln('natural_key : '
      '${(json['natural_key']! as String).replaceAll(nul, ' | ')}');

  final Map<String, Object?> queued = await call(
    'POST',
    '/api/v1/edits',
    token: token,
    deviceHeader: device,
    body: json,
  );
  stdout.writeln('queued      : $queued');
  http.close();
}
