/// The queue of edits made in the browser, waiting for a phone to apply them.
///
/// The server never touches a ledger. It holds intent in order and hands it over
/// when the owning device next syncs, then records what became of each one. That
/// is what lets the browser be genuinely editable while the phone stays the
/// single source of truth: no merge, no conflict rules, no schema knowledge here.
///
/// **The queue is per device.** An edit composed against one phone's snapshot
/// names a row id that means something else on another device, so a shared queue
/// would be a way to apply an edit to the wrong ledger.
library;

import 'dart:convert';

import 'json_store.dart';

/// The ops a queued edit may ask for. Must match the app's `EditOp.wire`.
///
/// Checked rather than passed through, so a body naming an op this server has
/// never heard of is refused at the door instead of sitting in a queue that no
/// phone will ever be able to drain.
const Set<String> kEditOps = <String>{
  'set_category',
  'set_note',
  'save_splits',
  'delete_txn',
};

/// What a phone reports back. Must match the app's `EditOutcome.wire`.
const Set<String> kEditOutcomes = <String>{
  'applied',
  'skipped_missing_row',
  'rejected_invalid',
};

/// What is wrong with a posted edit.
class EditRejection {
  const EditRejection(this.status, this.message);

  final int status;
  final String message;
}

/// The result of queueing one edit.
class Queued {
  const Queued(this.seq, this.pending, {this.duplicate = false});

  final int seq;
  final int pending;

  /// Whether this `edit_id` was already queued and nothing new was stored.
  ///
  /// Reported rather than hidden, but not an error: a browser that retried a
  /// request it was unsure about should be told it landed the first time.
  final bool duplicate;
}

/// The queues on disk.
class EditQueueStore {
  EditQueueStore(this.paths, this.lock, {required this.expiry});

  final Paths paths;
  final WriteLock lock;

  /// How long an unacknowledged edit is kept.
  ///
  /// A phone that is never synced again must not be able to grow a queue
  /// forever. Long enough that a fortnight's holiday costs nothing.
  final Duration expiry;

  /// Checks [json] enough to queue it.
  EditRejection? inspect(Object? json) {
    if (json is! Map<String, Object?>) {
      return const EditRejection(400, 'An edit has to be a JSON object.');
    }
    final Object? id = json['edit_id'];
    if (id is! String || id.isEmpty || id.length > 128) {
      return const EditRejection(
        400,
        'An edit needs an "edit_id" of 1 to 128 characters.',
      );
    }
    final Object? op = json['op'];
    if (op is! String || !kEditOps.contains(op)) {
      return EditRejection(
        400,
        '"$op" is not an edit this server knows how to queue.',
      );
    }
    if (json['natural_key'] is! String) {
      return const EditRejection(
        400,
        'An edit needs a "natural_key" naming the transaction it is about.',
      );
    }
    return null;
  }

  /// Queues [json] for [device], or reports that it was already there.
  ///
  /// `edit_id` is the idempotency key. A repeat is accepted and ignored, and the
  /// sequence number of the original is returned — which is what makes a browser
  /// retrying an uncertain request safe.
  Future<Queued> add({
    required String user,
    required String device,
    required Map<String, Object?> json,
  }) =>
      lock.synchronized(() async {
        final _Queue queue = await _read(user, device);
        final String id = json['edit_id']! as String;

        final int at =
            queue.edits.indexWhere((Map<String, Object?> e) => e['edit_id'] == id);
        if (at >= 0) {
          return Queued(
            (queue.edits[at]['seq'] as num?)?.toInt() ?? 0,
            queue.edits.length,
            duplicate: true,
          );
        }

        final int seq = queue.nextSeq;
        queue.edits.add(<String, Object?>{
          ...json,
          // Assigned here, never taken from the client: the order edits are
          // applied in has to be the server's decision, since two browsers
          // cannot agree on it between themselves.
          'seq': seq,
          'queued_at': DateTime.now().toUtc().toIso8601String(),
        });
        await _write(user, device, _Queue(queue.edits, seq + 1));
        return Queued(seq, queue.edits.length);
      });

  /// [device]'s pending edits in sequence order, expired ones dropped.
  Future<List<Map<String, Object?>>> pending({
    required String user,
    required String device,
  }) async {
    final _Queue queue = await _read(user, device);
    final List<Map<String, Object?>> live = _live(queue.edits);

    // Expiring on read as well as on write, so a queue that is only ever polled
    // still shrinks. Written back only when something actually went.
    if (live.length != queue.edits.length) {
      await lock.synchronized(() async {
        final _Queue current = await _read(user, device);
        await _write(
          user,
          device,
          _Queue(_live(current.edits), current.nextSeq),
        );
      });
    }

    live.sort((Map<String, Object?> a, Map<String, Object?> b) =>
        ((a['seq'] as num?)?.toInt() ?? 0)
            .compareTo((b['seq'] as num?)?.toInt() ?? 0));
    return live;
  }

  /// Records what the phone did with each edit and removes them from the queue.
  ///
  /// Unknown ids are counted and ignored rather than refused: the phone acking
  /// an edit that expired in between is a race, not a mistake, and failing the
  /// whole call would strand the edits that *were* applied.
  Future<({int removed, int unknown, int pending})> acknowledge({
    required String user,
    required String device,
    required List<Map<String, Object?>> outcomes,
  }) =>
      lock.synchronized(() async {
        final _Queue queue = await _read(user, device);
        final Map<String, Map<String, Object?>> byId =
            <String, Map<String, Object?>>{
          for (final Map<String, Object?> o in outcomes)
            if (o['edit_id'] is String) o['edit_id']! as String: o,
        };

        final List<Map<String, Object?>> keep = <Map<String, Object?>>[];
        int removed = 0;
        final DateTime now = DateTime.now().toUtc();
        for (final Map<String, Object?> edit in queue.edits) {
          final Map<String, Object?>? outcome = byId.remove(edit['edit_id']);
          if (outcome == null) {
            keep.add(edit);
            continue;
          }
          removed++;
          final String named = outcome['outcome'] as String? ?? '';
          await paths.appliedLog(user, device).appendLine(jsonEncode(
                <String, Object?>{
                  'edit_id': edit['edit_id'],
                  'op': edit['op'],
                  'seq': edit['seq'],
                  'queued_at': edit['queued_at'],
                  'acknowledged_at': now.toIso8601String(),
                  // An outcome this server does not recognise is recorded as a
                  // refusal. Recording it as applied is the one wrong answer:
                  // it would tell the user their edit took when it may not have.
                  'outcome': kEditOutcomes.contains(named)
                      ? named
                      : 'rejected_invalid',
                  if (outcome['detail'] != null) 'detail': outcome['detail'],
                },
              ));
        }

        await _write(user, device, _Queue(keep, queue.nextSeq));
        return (removed: removed, unknown: byId.length, pending: keep.length);
      });

  /// The last [limit] acknowledged edits, newest first.
  ///
  /// So the browser can say what happened to an edit rather than having it
  /// silently vanish from the pending list.
  Future<List<Map<String, Object?>>> applied({
    required String user,
    required String device,
    int limit = 50,
  }) async {
    final JsonFile log = paths.appliedLog(user, device);
    if (!log.exists) return const <Map<String, Object?>>[];
    final List<String> lines = (await log.file.readAsLines())
        .where((String l) => l.trim().isNotEmpty)
        .toList()
        .reversed
        .take(limit)
        .toList();
    return <Map<String, Object?>>[
      for (final String line in lines)
        if (_tryDecode(line) case final Map<String, Object?> row) row,
    ];
  }

  List<Map<String, Object?>> _live(List<Map<String, Object?>> edits) {
    final DateTime cutoff = DateTime.now().toUtc().subtract(expiry);
    return edits.where((Map<String, Object?> e) {
      final DateTime? queued =
          DateTime.tryParse(e['queued_at'] as String? ?? '');
      // An edit with no readable timestamp is kept. Dropping it would make a
      // hand-edited queue lose entries, which is the more surprising failure.
      return queued == null || queued.isAfter(cutoff);
    }).toList();
  }

  Future<_Queue> _read(String user, String device) async {
    final Object? raw = await paths.queue(user, device).read();
    if (raw is! Map<String, Object?>) return _Queue(<Map<String, Object?>>[], 1);
    final Object? edits = raw['edits'];
    return _Queue(
      <Map<String, Object?>>[
        if (edits is List)
          for (final Object? e in edits)
            if (e is Map<String, Object?>) e,
      ],
      (raw['next_seq'] as num?)?.toInt() ?? 1,
    );
  }

  Future<void> _write(String user, String device, _Queue queue) =>
      paths.queue(user, device).write(<String, Object?>{
        'next_seq': queue.nextSeq,
        'edits': queue.edits,
      });
}

/// A queue plus its sequence counter.
///
/// The counter is stored rather than derived from the highest seq present,
/// because draining the queue would reset it and a later edit would reuse a
/// number an earlier one already had.
class _Queue {
  _Queue(this.edits, this.nextSeq);

  final List<Map<String, Object?>> edits;
  final int nextSeq;
}

Object? _tryDecode(String line) {
  try {
    return jsonDecode(line);
  } on FormatException {
    return null;
  }
}
