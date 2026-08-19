/// Snapshots, kept per user and per device.
///
/// The phone owns its ledger and pushes the whole thing; the server keeps the
/// last N of those pushes and hands the newest back. It never merges, never
/// parses a ledger and never needs to know the schema — the phone validates in
/// full before uploading, so this is a versioned blob store with opinions about
/// exactly two things: that a body looks like one of our snapshots, and that a
/// stored one is never half-written.
///
/// **Per device is not a detail.** A single slot would mean the last device to
/// push wins and every other device's ledger is destroyed — which, with a phone
/// and an emulator pointed at the same server, is data loss on the first sync.
library;

import 'dart:convert';
import 'dart:io';

import 'json_store.dart';

/// The marker a snapshot body must carry. Must match the app's `kBackupFormat`.
const String kSnapshotFormat = 'tu-expense-tracker-backup';

/// What is wrong with a pushed body, as a sentence and an HTTP status.
class SnapshotRejection {
  const SnapshotRejection(this.status, this.message);

  final int status;
  final String message;
}

/// One stored snapshot, described without being read.
class SnapshotInfo {
  const SnapshotInfo({
    required this.id,
    required this.at,
    required this.bytes,
    this.counts = const <String, String>{},
    this.appVersion,
    this.schemaVersion,
  });

  factory SnapshotInfo.fromJson(Map<String, Object?> json) => SnapshotInfo(
        id: json['id']! as String,
        at: DateTime.parse(json['at']! as String),
        bytes: (json['bytes']! as num).toInt(),
        counts: <String, String>{
          if (json['counts'] is Map)
            for (final MapEntry<Object?, Object?> e
                in (json['counts']! as Map).entries)
              '${e.key}': '${e.value}',
        },
        appVersion: json['app_version'] as String?,
        schemaVersion: (json['schema_version'] as num?)?.toInt(),
      );

  /// Sortable and filesystem-safe: the instant it was stored, plus a short
  /// counter so two pushes in the same second cannot collide.
  final String id;

  /// When the server stored it. Distinct from the snapshot's own `exported_at`,
  /// which is when the phone took it.
  final DateTime at;

  final int bytes;

  /// The row counts out of the snapshot's meta block, so a listing can say what
  /// is in a snapshot without opening it.
  final Map<String, String> counts;

  final String? appVersion;
  final int? schemaVersion;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'at': at.toIso8601String(),
        'bytes': bytes,
        'counts': counts,
        if (appVersion != null) 'app_version': appVersion,
        if (schemaVersion != null) 'schema_version': schemaVersion,
      };
}

/// A device that has synced at least once.
class DeviceInfo {
  const DeviceInfo({
    required this.id,
    required this.label,
    required this.firstSeen,
    required this.lastSeen,
    this.latest,
    this.pendingEdits = 0,
    this.syncIntervalMinutes,
  });

  final String id;

  /// What the user calls it — "Jay's Pixel", "Emulator". Free text, so the
  /// device picker in the browser is readable rather than a list of hashes.
  final String label;

  final DateTime firstSeen;
  final DateTime lastSeen;

  /// The current snapshot, or null for a device registered but never pushed.
  final SnapshotInfo? latest;

  final int pendingEdits;

  /// How often this device says it syncs, in minutes, or null if it has not
  /// said — a build from before it was reported.
  ///
  /// The server does nothing with it. It exists so the browser can tell a phone
  /// that has gone quiet from one that is simply between syncs: without it, the
  /// connection light would have to guess at an interval, and be wrong for
  /// anybody who changed the setting.
  final int? syncIntervalMinutes;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'label': label,
        'first_seen': firstSeen.toIso8601String(),
        'last_seen': lastSeen.toIso8601String(),
        'latest': latest?.toJson(),
        'pending_edits': pendingEdits,
        'sync_interval_minutes': syncIntervalMinutes,
      };
}

/// The snapshots on disk.
class SnapshotStore {
  SnapshotStore(this.paths, this.lock, {required this.keep});

  final Paths paths;
  final WriteLock lock;

  /// How many snapshots to keep per device.
  ///
  /// More than a cache: because every push is a whole ledger, the history *is*
  /// the backup. Recovering from a bad push means pointing at the previous
  /// snapshot rather than merging anything.
  final int keep;

  /// Checks [body] enough to store it, without understanding a ledger.
  ///
  /// Only the envelope. The phone runs the app's own `validateBackup` before
  /// uploading, and duplicating that here would be a second implementation of a
  /// hundred rules that could disagree with the first.
  SnapshotRejection? inspect(String body, {required int maxBytes}) {
    if (body.length > maxBytes) {
      return SnapshotRejection(
        413,
        'That snapshot is ${body.length} bytes, and the limit is $maxBytes.',
      );
    }
    final Object? parsed;
    try {
      parsed = jsonDecode(body);
    } on FormatException catch (error) {
      return SnapshotRejection(400, 'That is not valid JSON: ${error.message}');
    }
    if (parsed is! Map<String, Object?>) {
      return const SnapshotRejection(400, 'A snapshot has to be a JSON object.');
    }
    if (parsed['format'] != kSnapshotFormat) {
      return const SnapshotRejection(
        400,
        'That body is not a TU Expense Tracker snapshot.',
      );
    }
    return null;
  }

  /// Stores [body] as [device]'s current snapshot.
  ///
  /// Whole-file rename, then the pointer, then pruning — in that order, so an
  /// interruption at any point leaves the previous snapshot current rather than
  /// a pointer to something half-written.
  Future<SnapshotInfo> store({
    required String user,
    required String device,
    required String label,
    required String body,
    int? syncIntervalMinutes,
  }) =>
      lock.synchronized(() async {
        final DateTime now = DateTime.now().toUtc();
        final String id = await _freshId(user, device, now);

        final File target = paths.snapshot(user, device, id);
        await target.parent.create(recursive: true);
        final File tmp = File('${target.path}.tmp');
        await tmp.writeAsString(body, flush: true);
        await tmp.rename(target.path);

        final Map<String, String> meta = _metaOf(body);
        final SnapshotInfo info = SnapshotInfo(
          id: id,
          at: now,
          bytes: body.length,
          counts: <String, String>{
            for (final String key in <String>[
              'transactions',
              'splits',
              'categories',
              'merchant_defaults',
              'name_aliases',
              'deleted',
            ])
              if (meta[key] != null) key: meta[key]!,
          },
          appVersion: meta['app_version'],
          schemaVersion: int.tryParse(meta['schema_version'] ?? ''),
        );

        // The pointer is written after the snapshot it names exists, never
        // before. A reader that finds a pointer can rely on the file being there.
        await paths.latest(user, device).write(info.toJson());
        await _rememberDevice(user, device, label, now, syncIntervalMinutes);
        await _prune(user, device);
        return info;
      });

  /// [device]'s current snapshot body, or null if it has never pushed.
  Future<String?> latestBody(String user, String device) async {
    final SnapshotInfo? info = await latestInfo(user, device);
    if (info == null) return null;
    return bodyById(user, device, info.id);
  }

  Future<SnapshotInfo?> latestInfo(String user, String device) async {
    final Object? raw = await paths.latest(user, device).read();
    if (raw is! Map<String, Object?>) return null;
    try {
      final SnapshotInfo info = SnapshotInfo.fromJson(raw);
      // A pointer to a snapshot that is no longer there is not current. It can
      // happen if a volume is restored piecemeal, and answering with it would
      // give the client a 404 body it could not interpret.
      return paths.snapshot(user, device, info.id).existsSync() ? info : null;
    } on Object {
      return null;
    }
  }

  Future<String?> bodyById(String user, String device, String id) async {
    final File file = paths.snapshot(user, device, id);
    return file.existsSync() ? file.readAsString() : null;
  }

  /// Everything stored for [device], newest first.
  Future<List<SnapshotInfo>> history(String user, String device) async {
    final Directory dir = paths.snapshots(user, device);
    if (!dir.existsSync()) return const <SnapshotInfo>[];

    final List<SnapshotInfo> out = <SnapshotInfo>[];
    for (final File file in dir
        .listSync()
        .whereType<File>()
        .where((File f) => f.path.endsWith('.json'))) {
      final String id =
          file.uri.pathSegments.last.replaceFirst(RegExp(r'\.json$'), '');
      final FileStat stat = file.statSync();
      final Map<String, String> meta = _metaOf(await file.readAsString());
      out.add(SnapshotInfo(
        id: id,
        // The id is derived from the store time, so it is the better source —
        // mtime moves if a volume is copied without preserving timestamps.
        at: DateTime.tryParse(_idToIso(id)) ?? stat.modified.toUtc(),
        bytes: stat.size,
        counts: <String, String>{
          if (meta['transactions'] != null) 'transactions': meta['transactions']!,
        },
        appVersion: meta['app_version'],
        schemaVersion: int.tryParse(meta['schema_version'] ?? ''),
      ));
    }
    out.sort((SnapshotInfo a, SnapshotInfo b) => b.id.compareTo(a.id));
    return out;
  }

  /// Every device [user] has, most recently synced first.
  Future<List<DeviceInfo>> devices(String user) async {
    final List<DeviceInfo> out = <DeviceInfo>[];
    for (final String id in paths.deviceIds(user)) {
      final Object? raw = await paths.deviceMeta(user, id).read();
      final Map<String, Object?> meta =
          raw is Map<String, Object?> ? raw : <String, Object?>{};
      final SnapshotInfo? latest = await latestInfo(user, id);
      final DateTime fallback = latest?.at ?? DateTime.fromMillisecondsSinceEpoch(0);
      out.add(DeviceInfo(
        id: id,
        label: meta['label'] as String? ?? id,
        firstSeen: DateTime.tryParse(meta['first_seen'] as String? ?? '') ?? fallback,
        lastSeen: DateTime.tryParse(meta['last_seen'] as String? ?? '') ?? fallback,
        latest: latest,
        pendingEdits: await _pendingCount(user, id),
        syncIntervalMinutes: (meta['sync_interval_minutes'] as num?)?.toInt(),
      ));
    }
    out.sort((DeviceInfo a, DeviceInfo b) => b.lastSeen.compareTo(a.lastSeen));
    return out;
  }

  /// Registers [device] without storing a snapshot, so a phone that has logged
  /// in but not yet synced still appears.
  Future<void> registerDevice({
    required String user,
    required String device,
    required String label,
    int? syncIntervalMinutes,
  }) =>
      lock.synchronized(() => _rememberDevice(
            user,
            device,
            label,
            DateTime.now().toUtc(),
            syncIntervalMinutes,
          ));

  /// Records that [device] is still there, without storing anything.
  ///
  /// **This is what makes the browser's connection light true.** `last_seen`
  /// used to move only when a snapshot was pushed, and an automatic sync does
  /// not push a ledger that has not changed — so a phone syncing perfectly well
  /// every quarter of an hour, with no new transactions, went quiet as far as
  /// the server could tell and the light went red. Every sync pulls the edit
  /// queue, so that is the heartbeat.
  ///
  /// Only for a device already known. A heartbeat must not be a way to create
  /// devices: a typo in a header would otherwise litter the picker with entries
  /// that have no ledger behind them.
  Future<void> touchDevice({
    required String user,
    required String device,
    int? syncIntervalMinutes,
  }) =>
      lock.synchronized(() async {
        if (!paths.deviceMeta(user, device).exists) return;
        await _rememberDevice(
          user,
          device,
          '',
          DateTime.now().toUtc(),
          syncIntervalMinutes,
        );
      });

  /// Removes a device and everything under it.
  ///
  /// Only ever on an explicit request. Nothing here expires a device on its own:
  /// the snapshots are small, and automatically deleting the only copy of a
  /// ledger is the wrong default.
  Future<bool> forgetDevice(String user, String device) =>
      lock.synchronized(() async {
        final Directory dir = paths.deviceDir(user, device);
        if (!dir.existsSync()) return false;
        await dir.delete(recursive: true);
        return true;
      });

  Future<void> _rememberDevice(
    String user,
    String device,
    String label,
    DateTime now, [
    int? syncIntervalMinutes,
  ]) async {
    final Object? raw = await paths.deviceMeta(user, device).read();
    final Map<String, Object?> before =
        raw is Map<String, Object?> ? raw : <String, Object?>{};
    await paths.deviceMeta(user, device).write(<String, Object?>{
      'id': device,
      // A label already set is not overwritten by a client that did not send one.
      'label': label.trim().isEmpty
          ? (before['label'] as String? ?? device)
          : label.trim(),
      // Same rule, and it matters more here: a client that says nothing must
      // leave the last known interval in place, or the browser's connection
      // light would fall back to a guess every time an older build checked in.
      'sync_interval_minutes':
          syncIntervalMinutes ?? (before['sync_interval_minutes'] as num?)?.toInt(),
      'first_seen': before['first_seen'] ?? now.toIso8601String(),
      'last_seen': now.toIso8601String(),
    });
  }

  /// An id that sorts by time and cannot collide with one already there.
  Future<String> _freshId(String user, String device, DateTime now) async {
    final String stamp = now
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-')
        .replaceFirst(RegExp(r'Z$'), 'Z');
    String id = stamp;
    int suffix = 1;
    while (paths.snapshot(user, device, id).existsSync()) {
      id = '$stamp-$suffix';
      suffix++;
    }
    return id;
  }

  /// Drops all but the newest [keep] snapshots.
  Future<void> _prune(String user, String device) async {
    final Directory dir = paths.snapshots(user, device);
    if (!dir.existsSync()) return;
    final List<File> files = dir
        .listSync()
        .whereType<File>()
        .where((File f) => f.path.endsWith('.json'))
        .toList()
      ..sort((File a, File b) => b.path.compareTo(a.path));
    for (final File old in files.skip(keep)) {
      await old.delete();
    }
  }

  Future<int> _pendingCount(String user, String device) async {
    final Object? raw = await paths.queue(user, device).read();
    if (raw is! Map<String, Object?>) return 0;
    final Object? edits = raw['edits'];
    return edits is List ? edits.length : 0;
  }

  /// The snapshot's own meta block, flattened to strings.
  ///
  /// Parsed with a tolerance for anything: this runs on a body the server has
  /// already agreed to store, and a listing that cannot say how many
  /// transactions a snapshot holds is a great deal better than one that throws.
  Map<String, String> _metaOf(String body) {
    try {
      final Object? parsed = jsonDecode(body);
      if (parsed is! Map<String, Object?>) return const <String, String>{};
      final Object? meta = parsed['meta'];
      if (meta is! Map) return const <String, String>{};
      return <String, String>{
        for (final MapEntry<Object?, Object?> e in meta.entries)
          if (e.value != null) '${e.key}': '${e.value}',
      };
    } on Object {
      return const <String, String>{};
    }
  }
}

/// The ISO instant an id was minted from.
String _idToIso(String id) {
  // 2026-08-18T21-04-33-123Z[-n] back to 2026-08-18T21:04:33.123Z
  // 3 to 6 fractional digits: toIso8601String emits microseconds when they are
  // non-zero and milliseconds when they are not, so an id minted at a whole
  // millisecond is three digits shorter than one that was not.
  final RegExpMatch? m = RegExp(
    r'^(\d{4}-\d{2}-\d{2})T(\d{2})-(\d{2})-(\d{2})-(\d{3,6})Z',
  ).firstMatch(id);
  if (m == null) return '';
  return '${m.group(1)}T${m.group(2)}:${m.group(3)}:${m.group(4)}.${m.group(5)}Z';
}
