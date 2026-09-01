/// Automated and manual rolling backups for the entire server state.
///
/// Captures all users, credentials, device metadata, edit queues, and ledger
/// snapshots in atomic timestamped backup bundles.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'json_store.dart';
import 'xlsx_backup.dart';

/// The format marker that identifies full server state backup bundles.
const String kServerBackupFormat = 'tu-expense-server-backup';

/// Information about one server backup snapshot.
class BackupItem {
  const BackupItem({
    required this.id,
    required this.at,
    required this.bytes,
    required this.type,
    this.note,
    this.counts = const <String, String>{},
    this.serverVersion,
  });

  factory BackupItem.fromJson(Map<String, Object?> json) => BackupItem(
        id: json['id']! as String,
        at: DateTime.parse(json['at']! as String),
        bytes: (json['bytes']! as num).toInt(),
        type: json['type'] as String? ?? 'auto',
        note: json['note'] as String?,
        counts: <String, String>{
          if (json['counts'] is Map)
            for (final MapEntry<Object?, Object?> e
                in (json['counts']! as Map).entries)
              '${e.key}': '${e.value}',
        },
        serverVersion: json['server_version'] as String?,
      );

  final String id;
  final DateTime at;
  final int bytes;

  /// 'auto' (scheduled daily), 'manual' (on-demand), or 'pre_restore' (safety).
  final String type;
  final String? note;
  final Map<String, String> counts;
  final String? serverVersion;

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'at': at.toIso8601String(),
        'bytes': bytes,
        'type': type,
        if (note != null) 'note': note,
        'counts': counts,
        if (serverVersion != null) 'server_version': serverVersion,
      };
}

/// The result of a restoration operation.
class RestoreResult {
  const RestoreResult({
    required this.success,
    required this.restoredBackupId,
    required this.safetyBackupId,
    this.details = const <String, Object?>{},
  });

  final bool success;
  final String restoredBackupId;
  final String safetyBackupId;
  final Map<String, Object?> details;

  Map<String, Object?> toJson() => <String, Object?>{
        'ok': success,
        'restored_backup_id': restoredBackupId,
        'safety_backup_id': safetyBackupId,
        'details': details,
      };
}

/// Manages full server state snapshots on disk.
class BackupManager {
  BackupManager({
    required this.paths,
    required this.lock,
    required this.backupDir,
    required this.keep,
    this.serverVersion = '1.0.0',
  });

  final Paths paths;
  final WriteLock lock;
  final String backupDir;
  final int keep;
  final String serverVersion;

  Directory get directory => Directory(backupDir);

  /// Creates a full server state snapshot bundle.
  Future<BackupItem> createBackup({
    String type = 'auto',
    String? note,
  }) =>
      lock.synchronized(() async {
        await directory.create(recursive: true);
        final DateTime now = DateTime.now().toUtc();
        final String id = _freshId(now, type);

        final Map<String, Object?> bundle = await _collectState(now, type, note, id);
        final String encoded = const JsonEncoder.withIndent('  ').convert(bundle);

        final File target = File('${directory.path}/backup_$id.json');
        final File tmp = File('${target.path}.tmp');
        await tmp.writeAsString(encoded, flush: true);
        await tmp.rename(target.path);

        // A spreadsheet sibling per device, so the transactions can be opened
        // directly — the JSON above is still the only thing a restore reads.
        if (type == 'auto' || type == 'manual') {
          await _writeXlsxExports(id);
        }

        final BackupItem item = BackupItem(
          id: id,
          at: now,
          bytes: encoded.length,
          type: type,
          note: note,
          counts: bundle['meta'] is Map
              ? <String, String>{
                  for (final MapEntry<Object?, Object?> e
                      in (bundle['meta']! as Map).entries)
                    '${e.key}': '${e.value}',
                }
              : const <String, String>{},
          serverVersion: serverVersion,
        );

        // Enforce FIFO retention on rolling backups ('auto' and 'manual').
        // Pre-restore safety backups are not pruned by the 10-cap.
        if (type == 'auto' || type == 'manual') {
          await _prune();
        }

        return item;
      });

  /// Lists all available backup snapshots, newest first.
  Future<List<BackupItem>> listBackups() async {
    if (!directory.existsSync()) return const <BackupItem>[];

    final List<BackupItem> out = <BackupItem>[];
    for (final File file in directory
        .listSync()
        .whereType<File>()
        .where((File f) => f.path.endsWith('.json') && !f.path.endsWith('.tmp'))) {
      try {
        final RandomAccessFile raf = await file.open();
        try {
          final int length = await raf.length();
          if (length == 0) continue;

          // Read the first 2KB for top-level metadata
          final List<int> headBytes = await raf.read(length < 2048 ? length : 2048);
          final String headContent = utf8.decode(headBytes, allowMalformed: true);
          
          if (!headContent.contains(kServerBackupFormat)) continue;

          final String id = RegExp(r'"id"\s*:\s*"([^"]+)"')
                  .firstMatch(headContent)
                  ?.group(1) ??
              file.uri.pathSegments.last
                  .replaceFirst(RegExp(r'^backup_'), '')
                  .replaceFirst(RegExp(r'\.json$'), '');

          final String? createdAtRaw = RegExp(r'"created_at"\s*:\s*"([^"]+)"')
              .firstMatch(headContent)
              ?.group(1);

          final DateTime at = createdAtRaw != null
              ? DateTime.tryParse(createdAtRaw) ?? file.statSync().modified.toUtc()
              : file.statSync().modified.toUtc();

          final String type = RegExp(r'"type"\s*:\s*"([^"]+)"')
                  .firstMatch(headContent)
                  ?.group(1) ??
              'unknown';
              
          final String? note = RegExp(r'"note"\s*:\s*"([^"]+)"')
              .firstMatch(headContent)
              ?.group(1);
              
          final String? serverVersion = RegExp(r'"server_version"\s*:\s*"([^"]+)"')
              .firstMatch(headContent)
              ?.group(1);

          // Read the last 1KB for 'meta' object
          final Map<String, String> counts = <String, String>{};
          if (length > 1024) {
             await raf.setPosition(length - 1024);
          } else {
             await raf.setPosition(0);
          }
          final List<int> tailBytes = await raf.read(1024);
          final String tailContent = utf8.decode(tailBytes, allowMalformed: true);
          
          final RegExpMatch? metaMatch = RegExp(r'"meta"\s*:\s*(\{[^}]+\})').firstMatch(tailContent);
          if (metaMatch != null) {
             try {
               final Map<String, dynamic> metaMap = jsonDecode(metaMatch.group(1)!) as Map<String, dynamic>;
               for (final MapEntry<String, dynamic> e in metaMap.entries) {
                 counts[e.key] = '${e.value}';
               }
             } catch (_) {}
          }

          out.add(BackupItem(
            id: id,
            at: at,
            bytes: length,
            type: type,
            note: note,
            counts: counts,
            serverVersion: serverVersion,
          ));
        } finally {
          await raf.close();
        }
      } catch (e) {
        print('Error reading backup ${file.path}: $e');
      }
    }

    out.sort((BackupItem a, BackupItem b) => b.at.compareTo(a.at));
    return out;
  }

  /// Fetches a specific backup bundle by id.
  Future<Map<String, Object?>?> getBackupBundle(String id) async {
    final File file = File('${directory.path}/backup_${_safeId(id)}.json');
    if (!file.existsSync()) return null;
    try {
      final Object? parsed = jsonDecode(await file.readAsString());
      return parsed is Map<String, Object?> ? parsed : null;
    } on Object {
      return null;
    }
  }

  /// Restores full server state from a backup snapshot.
  Future<RestoreResult> restoreBackup(String backupId) =>
      lock.synchronized(() async {
        final Map<String, Object?>? bundle = await getBackupBundle(backupId);
        if (bundle == null) {
          throw BackupRestoreException('Backup snapshot "$backupId" not found.');
        }
        if (bundle['format'] != kServerBackupFormat) {
          throw BackupRestoreException(
            'Invalid backup format: expected "$kServerBackupFormat".',
          );
        }

        // 1. Take automatic pre-restore safety snapshot before applying restore
        final BackupItem safety = await _createInternalSnapshot(
          type: 'pre_restore',
          note: 'Pre-restore safety snapshot before restoring $backupId',
        );

        // 2. Restore state into paths.root
        await _applyState(bundle);

        return RestoreResult(
          success: true,
          restoredBackupId: backupId,
          safetyBackupId: safety.id,
          details: <String, Object?>{
            'restored_at': DateTime.now().toUtc().toIso8601String(),
            'counts': bundle['meta'] ?? <String, Object?>{},
          },
        );
      });

  /// Drops rolling snapshots exceeding the `keep` cap (FIFO).
  Future<void> _prune() async {
    final List<BackupItem> all = await listBackups();
    final List<BackupItem> rolling =
        all.where((BackupItem b) => b.type == 'auto' || b.type == 'manual').toList();

    for (final BackupItem old in rolling.skip(keep)) {
      final String safeId = _safeId(old.id);
      final File file = File('${directory.path}/backup_$safeId.json');
      if (file.existsSync()) {
        try {
          await file.delete();
        } on Object {
          // Ignore deletion errors
        }
      }
      // Every XLSX sibling this backup wrote, one per device — the "__" is the
      // delimiter written in _writeXlsxExports, so a shorter id that happens to
      // be a text-prefix of a longer one (e.g. from the `-1` de-dupe suffix in
      // _freshId) can never match another backup's files.
      for (final File sibling in directory
          .listSync()
          .whereType<File>()
          .where((File f) =>
              f.uri.pathSegments.last.startsWith('backup_${safeId}__') &&
              f.path.endsWith('.xlsx'))) {
        try {
          await sibling.delete();
        } on Object {
          // Ignore deletion errors
        }
      }
    }
  }

  /// Writes `backup_<id>__<user>__<device>.xlsx` for every device with a
  /// current snapshot — the same 7-sheet workbook the phone's own "Export to
  /// Excel" produces, so it can be opened directly without a restore.
  ///
  /// Best-effort per device: one snapshot that fails to decode (an old format,
  /// a corrupt file) is skipped rather than failing the backup — the JSON just
  /// written is the only thing a restore actually needs.
  Future<void> _writeXlsxExports(String id) async {
    final Directory usersDir = Directory('${paths.root.path}/users');
    if (!usersDir.existsSync()) return;

    for (final Directory uDir in usersDir.listSync().whereType<Directory>()) {
      final String user = uDir.path.split(Platform.pathSeparator).last;
      for (final String device in paths.deviceIds(user)) {
        try {
          final String? body = await _latestSnapshotBody(user, device);
          if (body == null) continue;

          final BackupData data = decodeBackupJson(body);
          final Uint8List bytes = encodeBackupWorkbook(data);

          final File target = File(
            '${directory.path}/backup_${_safeId(id)}__${_safeId(user)}__'
            '${_safeId(device)}.xlsx',
          );
          final File tmp = File('${target.path}.tmp');
          await tmp.writeAsBytes(bytes, flush: true);
          await tmp.rename(target.path);
        } on Object catch (error) {
          stdout.writeln(
            'backup $id: could not write the XLSX export for $user/$device: '
            '$error',
          );
        }
      }
    }
  }

  /// [device]'s current snapshot body, straight off disk via its `latest.json`
  /// pointer — the same two-step lookup `SnapshotStore.latestBody` does,
  /// without adding a `SnapshotStore` dependency here just for this.
  Future<String?> _latestSnapshotBody(String user, String device) async {
    final Object? latestRaw = await paths.latest(user, device).read();
    if (latestRaw is! Map<String, Object?>) return null;
    final Object? idRaw = latestRaw['id'];
    if (idRaw is! String) return null;
    final File file = paths.snapshot(user, device, idRaw);
    return file.existsSync() ? file.readAsString() : null;
  }

  Future<Map<String, Object?>> _collectState(
    DateTime now,
    String type,
    String? note,
    String id,
  ) async {
    final Object? usersRaw = await paths.users.read();
    final Object? sessionsRaw = await paths.sessions.read();

    final Map<String, Object?> userData = <String, Object?>{};
    int totalTransactions = 0;
    int totalDevices = 0;

    final Directory usersDir = Directory('${paths.root.path}/users');
    if (usersDir.existsSync()) {
      for (final Directory uDir in usersDir.listSync().whereType<Directory>()) {
        final String user = uDir.path.split(Platform.pathSeparator).last;
        final Map<String, Object?> userDevices = <String, Object?>{};

        for (final String deviceId in paths.deviceIds(user)) {
          totalDevices++;
          final Object? devMeta = await paths.deviceMeta(user, deviceId).read();
          final Object? latestMeta = await paths.latest(user, deviceId).read();
          final Object? queueRaw = await paths.queue(user, deviceId).read();

          String? appliedLog;
          final File logFile = paths.appliedLog(user, deviceId).file;
          if (logFile.existsSync()) {
            appliedLog = await logFile.readAsString();
          }

          final Map<String, Object?> snapshotFiles = <String, Object?>{};
          final Directory sDir = paths.snapshots(user, deviceId);
          if (sDir.existsSync()) {
            for (final File sFile in sDir
                .listSync()
                .whereType<File>()
                .where((File f) => f.path.endsWith('.json'))) {
              final String sId = sFile.uri.pathSegments.last
                  .replaceFirst(RegExp(r'\.json$'), '');
              try {
                final Object? sParsed = jsonDecode(await sFile.readAsString());
                snapshotFiles[sId] = sParsed;

                // Tally transaction count
                if (sParsed is Map<String, Object?> &&
                    sParsed['transactions'] is List) {
                  final int count = (sParsed['transactions']! as List).length;
                  if (count > totalTransactions) {
                    totalTransactions = count;
                  }
                }
              } on Object {
                // Ignore parse errors on individual older snapshots
              }
            }
          }

          userDevices[deviceId] = <String, Object?>{
            'device': devMeta,
            'latest': latestMeta,
            'snapshots': snapshotFiles,
            'queue': queueRaw,
            if (appliedLog case final String log) 'applied_log': log,
          };
        }

        userData[user] = <String, Object?>{'devices': userDevices};
      }
    }

    final int userCount =
        usersRaw is Map ? (usersRaw['users'] as Map?)?.length ?? 0 : userData.length;

    return <String, Object?>{
      'format': kServerBackupFormat,
      'format_version': 1,
      'id': id,
      'created_at': now.toIso8601String(),
      'type': type,
      if (note case final String n) 'note': n,
      'server_version': serverVersion,
      'users': usersRaw,
      'sessions': sessionsRaw,
      'user_data': userData,
      'meta': <String, String>{
        'users': '$userCount',
        'devices': '$totalDevices',
        'transactions': '$totalTransactions',
      },
    };
  }

  Future<void> _applyState(Map<String, Object?> bundle) async {
    // 1. Restore users.json
    if (bundle['users'] != null) {
      await paths.users.write(bundle['users']);
    }

    // 2. Restore sessions.json
    if (bundle['sessions'] != null) {
      await paths.sessions.write(bundle['sessions']);
    }

    // 3. Restore user data
    final Object? userData = bundle['user_data'];
    if (userData is Map<String, Object?>) {
      for (final MapEntry<String, Object?> uEntry in userData.entries) {
        final String user = uEntry.key;
        final Object? uVal = uEntry.value;
        if (uVal is! Map<String, Object?>) continue;

        final Object? devices = uVal['devices'];
        if (devices is! Map<String, Object?>) continue;

        for (final MapEntry<String, Object?> dEntry in devices.entries) {
          final String device = dEntry.key;
          final Object? dVal = dEntry.value;
          if (dVal is! Map<String, Object?>) continue;

          if (dVal['device'] != null) {
            await paths.deviceMeta(user, device).write(dVal['device']);
          }
          if (dVal['latest'] != null) {
            await paths.latest(user, device).write(dVal['latest']);
          }
          if (dVal['queue'] != null) {
            await paths.queue(user, device).write(dVal['queue']);
          }
          if (dVal['applied_log'] is String) {
            final File logFile = paths.appliedLog(user, device).file;
            await logFile.parent.create(recursive: true);
            await logFile.writeAsString(dVal['applied_log']! as String,
                flush: true);
          }

          final Object? snapshots = dVal['snapshots'];
          if (snapshots is Map<String, Object?>) {
            for (final MapEntry<String, Object?> sEntry in snapshots.entries) {
              final String sId = sEntry.key;
              final Object? sContent = sEntry.value;
              final File sFile = paths.snapshot(user, device, sId);
              await sFile.parent.create(recursive: true);
              final File tmp = File('${sFile.path}.tmp');
              await tmp.writeAsString(
                const JsonEncoder.withIndent('  ').convert(sContent),
                flush: true,
              );
              await tmp.rename(sFile.path);
            }
          }
        }
      }
    }
  }

  Future<BackupItem> _createInternalSnapshot({
    required String type,
    String? note,
  }) async {
    await directory.create(recursive: true);
    final DateTime now = DateTime.now().toUtc();
    final String id = _freshId(now, type);

    final Map<String, Object?> bundle = await _collectState(now, type, note, id);
    final String encoded = const JsonEncoder.withIndent('  ').convert(bundle);

    final File target = File('${directory.path}/backup_$id.json');
    final File tmp = File('${target.path}.tmp');
    await tmp.writeAsString(encoded, flush: true);
    await tmp.rename(target.path);

    return BackupItem(
      id: id,
      at: now,
      bytes: encoded.length,
      type: type,
      note: note,
      counts: bundle['meta'] is Map
          ? <String, String>{
              for (final MapEntry<Object?, Object?> e
                  in (bundle['meta']! as Map).entries)
                '${e.key}': '${e.value}',
            }
          : const <String, String>{},
      serverVersion: serverVersion,
    );
  }

  String _freshId(DateTime now, String type) {
    final String stamp = now
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '-')
        .replaceFirst(RegExp(r'Z$'), 'Z');
    final String prefix = type == 'pre_restore' ? 'safety_' : '';
    String id = '$prefix$stamp';
    int suffix = 1;
    while (File('${directory.path}/backup_$id.json').existsSync()) {
      id = '$prefix$stamp-$suffix';
      suffix++;
    }
    return id;
  }

  String _safeId(String id) =>
      id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_').replaceAll('..', '_');
}

/// Thrown when backup restore fails.
class BackupRestoreException implements Exception {
  const BackupRestoreException(this.message);
  final String message;

  @override
  String toString() => message;
}
