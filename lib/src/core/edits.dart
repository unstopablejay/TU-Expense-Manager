/// Edits made on the web, waiting for the phone to apply them.
///
/// The phone is the source of truth, so the browser never writes to the ledger.
/// It records *intent*: a queued edit says "set this transaction's category to
/// Grocery", and the phone applies it on its next sync through the same
/// `AppDatabase` methods its own screens use. Every invariant the app already
/// enforces — split sums, tombstones, the denormalised category cache — is
/// enforced by the code that already enforces it, so this needs no schema
/// migration, no `updated_at` columns and no conflict resolution.
///
/// The queue is per device on the server. An edit composed against one phone's
/// snapshot names a row id that means something else on another device, and
/// scoping the queue makes applying it to the wrong ledger impossible rather
/// than merely unlikely.
library;

import 'dart:convert';
import 'dart:math';

import 'models.dart';
import 'splits.dart';

/// What a queued edit asks for.
///
/// Deliberately the four things the ledger screens can already do, each mapping
/// onto one existing `AppDatabase` method. Anything that needed a new write path
/// would need new invariant checks to go with it.
enum EditOp {
  /// `setTransactionCategory` — also clears any split lines, as it does on the
  /// phone: a whole-transaction category and a set of split lines are two
  /// answers to the same question.
  setCategory('set_category'),

  /// `setTransactionNote`.
  setNote('set_note'),

  /// `saveSplits` — which throws unless the lines sum to the transaction.
  saveSplits('save_splits'),

  /// `deleteTransactions` — a hard delete plus a tombstone, so a later inbox
  /// rescan does not bring the row back.
  deleteTxn('delete_txn');

  const EditOp(this.wire);

  /// The string this op is carried as. Fixed, and separate from the Dart name:
  /// renaming the enum constant must not strip queued edits of their meaning.
  final String wire;

  static EditOp? byWire(String wire) {
    for (final EditOp op in EditOp.values) {
      if (op.wire == wire) return op;
    }
    return null;
  }
}

/// What became of a queued edit once the phone tried to apply it.
enum EditOutcome {
  /// Applied to the ledger.
  applied('applied'),

  /// The transaction it named is not there any more — most often because it was
  /// deleted on the phone after the snapshot the edit was composed against.
  /// Not an error: the edit is simply moot, and saying so is more useful than
  /// guessing at which row was meant.
  skippedMissingRow('skipped_missing_row'),

  /// The ledger refused it — split lines that do not sum, a category that no
  /// longer exists. The user needs to know, because their intent was not carried
  /// out and nothing about retrying would change that.
  rejectedInvalid('rejected_invalid');

  const EditOutcome(this.wire);

  final String wire;

  static EditOutcome? byWire(String wire) {
    for (final EditOutcome outcome in EditOutcome.values) {
      if (outcome.wire == wire) return outcome;
    }
    return null;
  }
}

/// One edit, as it travels from the browser to the server to the phone.
class LedgerEdit {
  const LedgerEdit({
    required this.editId,
    required this.op,
    required this.txnId,
    required this.naturalKey,
    required this.createdAt,
    this.snapshotId,
    this.seq,
    this.payload = const <String, Object?>{},
  });

  /// Reads one back off the wire, or null if it is not a usable edit.
  ///
  /// Null rather than an exception: a queue is a list, and one unreadable entry
  /// in it should cost that entry and not the whole sync. The caller counts what
  /// it dropped.
  static LedgerEdit? fromJson(Object? json) {
    if (json is! Map) return null;
    final Object? id = json['edit_id'];
    final Object? opWire = json['op'];
    final Object? key = json['natural_key'];
    if (id is! String || id.isEmpty || opWire is! String || key is! String) {
      return null;
    }
    final EditOp? op = EditOp.byWire(opWire);
    if (op == null) return null;

    final Object? created = json['created_at'];
    return LedgerEdit(
      editId: id,
      op: op,
      txnId: switch (json['txn_id']) {
        final int v => v,
        final num v => v.toInt(),
        final String v => int.tryParse(v) ?? -1,
        _ => -1,
      },
      naturalKey: key,
      snapshotId: json['snapshot_id'] is String
          ? json['snapshot_id']! as String
          : null,
      seq: switch (json['seq']) {
        final int v => v,
        final num v => v.toInt(),
        _ => null,
      },
      createdAt: created is String
          ? (DateTime.tryParse(created) ?? DateTime.fromMillisecondsSinceEpoch(0))
          : DateTime.fromMillisecondsSinceEpoch(0),
      payload: <String, Object?>{
        if (json['payload'] is Map)
          for (final MapEntry<Object?, Object?> e
              in (json['payload']! as Map).entries)
            if (e.key is String) e.key! as String: e.value,
      },
    );
  }

  /// Client-generated, and the idempotency key.
  ///
  /// The server ignores a repeat, and the phone applying the same id twice is a
  /// no-op. That is what makes a lost acknowledgement safe: the edit is applied
  /// again rather than dropped, and applying it again changes nothing.
  final String editId;

  /// Server-assigned, and the order edits must be applied in. Null before the
  /// edit has been posted.
  ///
  /// Two edits to one transaction have to land in the order they were made, or
  /// the earlier one wins.
  final int? seq;

  final EditOp op;

  /// The `transactions.id` the browser was looking at.
  ///
  /// Only meaningful relative to [snapshotId] — ids are per-device and are
  /// reused across devices — which is why [naturalKey] travels with it.
  final int txnId;

  /// [transactionNaturalKey] for the target row, from the columns as stored.
  ///
  /// The device-independent half of the address. When the id no longer resolves,
  /// or resolves to a row that is not the one meant, this is what finds it.
  final String naturalKey;

  /// Which snapshot the edit was composed against, where the browser knows.
  final String? snapshotId;

  final DateTime createdAt;

  /// The op's argument. Shape depends on [op]; see [categoryId], [note] and
  /// [splitLines].
  final Map<String, Object?> payload;

  /// For [EditOp.setCategory].
  int? get categoryId => switch (payload['category_id']) {
        final int v => v,
        final num v => v.toInt(),
        final String v => int.tryParse(v),
        _ => null,
      };

  /// For [EditOp.setNote]. Empty is meaningful — it is how a note is removed.
  String? get note =>
      payload['note'] is String ? payload['note']! as String : null;

  /// For [EditOp.saveSplits], in the order they should be stored.
  ///
  /// Carries no category *names*: the phone looks those up, because the browser's
  /// idea of a category name is as old as its snapshot and the phone's is
  /// current.
  List<({int categoryId, double amount})> get splitLines {
    final Object? raw = payload['lines'];
    if (raw is! List) return const <({int categoryId, double amount})>[];
    final List<({int categoryId, double amount})> lines =
        <({int categoryId, double amount})>[];
    for (final Object? line in raw) {
      if (line is! Map) continue;
      final Object? id = line['category_id'];
      final Object? amount = line['amount'];
      if (id is num && amount is num) {
        lines.add((categoryId: id.toInt(), amount: amount.toDouble()));
      }
    }
    return lines;
  }

  /// Whether this edit still describes [txn].
  ///
  /// Both halves must agree. The id alone is not enough — ids are reused across
  /// devices and after a restore — and the natural key alone cannot tell two
  /// genuinely identical charges apart. Requiring both means a mismatch is
  /// reported as [EditOutcome.skippedMissingRow] rather than applied to the
  /// wrong row.
  bool matches(ExpenseTxn txn) =>
      txn.id == txnId && txn.naturalKey == naturalKey;

  /// [txn] if this edit still describes something in [ledger], else null.
  ///
  /// Tries the id first, since that is the common case and is cheap, then falls
  /// back to the natural key for a row whose id has moved — which is what a
  /// restore from backup does to a whole ledger.
  ExpenseTxn? resolve(Iterable<ExpenseTxn> ledger) {
    ExpenseTxn? byKey;
    for (final ExpenseTxn txn in ledger) {
      if (matches(txn)) return txn;
      if (byKey == null && txn.naturalKey == naturalKey) byKey = txn;
    }
    return byKey;
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'edit_id': editId,
        if (seq != null) 'seq': seq,
        'op': op.wire,
        'txn_id': txnId,
        'natural_key': naturalKey,
        if (snapshotId != null) 'snapshot_id': snapshotId,
        'created_at': createdAt.toIso8601String(),
        'payload': payload,
      };

  LedgerEdit withSeq(int seq) => LedgerEdit(
        editId: editId,
        op: op,
        txnId: txnId,
        naturalKey: naturalKey,
        snapshotId: snapshotId,
        createdAt: createdAt,
        payload: payload,
        seq: seq,
      );

  @override
  String toString() => 'LedgerEdit(${op.wire} txn $txnId, edit $editId)';
}

/// What the phone reports back for one edit it drained.
class EditAck {
  const EditAck(this.editId, this.outcome, {this.detail});

  factory EditAck.fromJson(Map<String, Object?> json) => EditAck(
        json['edit_id'] as String,
        EditOutcome.byWire(json['outcome'] as String? ?? '') ??
            EditOutcome.rejectedInvalid,
        detail: json['detail'] as String?,
      );

  final String editId;
  final EditOutcome outcome;

  /// Why, when the outcome needs explaining — shown in the web UI beside the
  /// edit that did not take.
  final String? detail;

  Map<String, Object?> toJson() => <String, Object?>{
        'edit_id': editId,
        'outcome': outcome.wire,
        if (detail != null) 'detail': detail,
      };
}

/// A queue as it arrives from the server: edits in [LedgerEdit.seq] order, plus
/// a count of entries that could not be read at all.
class EditQueue {
  const EditQueue(this.edits, {this.unreadable = 0});

  /// Reads a `GET /api/v1/edits` body.
  factory EditQueue.fromJson(Object? json) {
    final Object? raw = json is Map ? json['edits'] : null;
    if (raw is! List) return const EditQueue(<LedgerEdit>[]);

    final List<LedgerEdit> edits = <LedgerEdit>[];
    int unreadable = 0;
    for (final Object? entry in raw) {
      final LedgerEdit? edit = LedgerEdit.fromJson(entry);
      if (edit == null) {
        unreadable++;
      } else {
        edits.add(edit);
      }
    }
    // Sorted here rather than trusted from the server, because applying two
    // edits to one transaction out of order silently keeps the wrong one.
    edits.sort((LedgerEdit a, LedgerEdit b) =>
        (a.seq ?? 0).compareTo(b.seq ?? 0));
    return EditQueue(edits, unreadable: unreadable);
  }

  static EditQueue decode(String body) {
    try {
      return EditQueue.fromJson(jsonDecode(body));
    } on FormatException {
      return const EditQueue(<LedgerEdit>[]);
    }
  }

  final List<LedgerEdit> edits;

  /// How many entries were dropped as unreadable. Surfaced rather than
  /// swallowed: a queue that silently shrinks is a queue nobody trusts.
  final int unreadable;

  bool get isEmpty => edits.isEmpty;
}

/// A fresh id for an edit.
///
/// Time plus randomness. The timestamp keeps ids sortable and legible in the
/// server's log; the random tail is what actually makes them unique, because
/// `DateTime.now()` has only **millisecond** resolution on the web — two clicks
/// in the same millisecond would otherwise collide on what is meant to be an
/// idempotency key.
///
/// The random part is drawn one hex digit at a time from `nextInt(16)`.
///
/// **Never `nextInt(1 << 32)`.** On the web an int is a JavaScript number and
/// shifts are 32-bit, so `1 << 32` evaluates to `0` and that call becomes
/// `nextInt(0)`, which throws `RangeError`. This function exists because that is
/// precisely what shipped: every edit made in a browser failed, silently, while
/// the same code passed on the VM where `1 << 32` is 4294967296.
String newEditId(DateTime now, Random random) {
  const String hex = '0123456789abcdef';
  final String tail = String.fromCharCodes(
    Iterable<int>.generate(8, (_) => hex.codeUnitAt(random.nextInt(hex.length))),
  );
  return 'web-${now.millisecondsSinceEpoch}-$tail';
}

/// Composes an edit against [txn], for the browser to post.
///
/// The natural key comes from [ExpenseTxn.naturalKey], which reads the merchant
/// **as stored** rather than as merged — writing the merged spelling would
/// address a row that does not exist, and the edit would be skipped for no
/// visible reason.
LedgerEdit composeEdit({
  required String editId,
  required EditOp op,
  required ExpenseTxn txn,
  required DateTime now,
  String? snapshotId,
  int? categoryId,
  String? note,
  List<TxnSplit> lines = const <TxnSplit>[],
}) =>
    LedgerEdit(
      editId: editId,
      op: op,
      txnId: txn.id,
      naturalKey: txn.naturalKey,
      snapshotId: snapshotId,
      createdAt: now,
      payload: switch (op) {
        EditOp.setCategory => <String, Object?>{'category_id': categoryId},
        EditOp.setNote => <String, Object?>{'note': note ?? ''},
        EditOp.saveSplits => <String, Object?>{
            'lines': <Map<String, Object?>>[
              for (final TxnSplit line in lines)
                <String, Object?>{
                  'category_id': line.categoryId,
                  'amount': line.amount,
                },
            ],
          },
        EditOp.deleteTxn => const <String, Object?>{},
      },
    );
