/// Reading and writing the JSON files this server keeps its state in.
///
/// There is no database. The state is a handful of JSON files under one volume,
/// which is the right size of tool for a household expense server: the files can
/// be read with `cat`, backed up by copying a directory, and repaired by hand if
/// it ever comes to that.
///
/// What that trades away is a database's atomicity, so this file puts it back.
/// Every write goes to a temporary file and is then renamed into place, and the
/// two mutating paths are serialised behind a lock. Get either wrong and a
/// container killed mid-write leaves a half-written file as the current one.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// A JSON file that is only ever replaced whole.
class JsonFile {
  JsonFile(this.file);

  final File file;

  bool get exists => file.existsSync();

  /// The file's contents, or null if it is not there.
  ///
  /// A file that exists but does not parse throws, deliberately. An unreadable
  /// users file is not an empty users file, and treating it as one would hand out
  /// a fresh unauthenticated server to whoever asked next.
  Future<Object?> read() async {
    if (!file.existsSync()) return null;
    final String body = await file.readAsString();
    if (body.trim().isEmpty) return null;
    return jsonDecode(body);
  }

  /// [value] as this file's new contents.
  ///
  /// Writes `<name>.tmp` and renames it over the target. `rename` within one
  /// filesystem is atomic, so a reader sees either the whole previous version or
  /// the whole new one, and a process killed at any point leaves one of the two
  /// rather than a truncated hybrid.
  Future<void> write(Object? value) async {
    await file.parent.create(recursive: true);
    final File tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
      const JsonEncoder.withIndent('  ').convert(value),
      flush: true, // so the bytes are on disk before the rename, not just queued
    );
    await tmp.rename(file.path);
  }

  /// Appends [line] to a log, creating it if needed.
  ///
  /// Not atomic in the sense above, and does not need to be: a log is a record
  /// of what happened, and a torn final line costs one entry rather than the
  /// file. Used for the applied-edits history, never for state that is read back.
  Future<void> appendLine(String line) async {
    await file.parent.create(recursive: true);
    await file.writeAsString('$line\n',
        mode: FileMode.writeOnlyAppend, flush: true);
  }
}

/// Serialises the writers so one cannot observe another half-done.
///
/// A Dart server runs one isolate, so handlers never interleave mid-statement —
/// but they do interleave at every `await`, and a snapshot upload has several.
/// Without this, a POST that read the device index, awaited a disk write, and
/// then wrote the index back could silently discard an edit queued in between.
///
/// One lock for all writers rather than one per file: the paths are few, the
/// writes are milliseconds, and a single lock cannot deadlock against itself.
class WriteLock {
  Future<void> _tail = Future<void>.value();

  /// Runs [action] once every earlier call has finished.
  Future<T> synchronized<T>(Future<T> Function() action) {
    final Completer<void> mine = Completer<void>();
    final Future<void> earlier = _tail;
    _tail = mine.future;

    return earlier.then((_) => action()).whenComplete(mine.complete);
  }
}

/// Everything the server keeps, rooted at one directory.
///
/// Paths live here rather than being built at each call site so that the layout
/// is stated once and can be read in one place:
///
/// ```
/// <root>/
///   users.json                        username, salt, hash
///   sessions.json                     token -> user, expiry
///   users/<user>/devices/<device>/
///       device.json                   label, first and last seen
///       latest.json                   which snapshot is current
///       snapshots/<id>.json           immutable, pruned to a limit
///       edits/queue.json              this device's pending edits
///       edits/applied.log             what the phone did with them
/// ```
class Paths {
  Paths(String root) : root = Directory(root);

  final Directory root;

  JsonFile get users => JsonFile(File('${root.path}/users.json'));

  JsonFile get sessions => JsonFile(File('${root.path}/sessions.json'));

  /// A user's directory name.
  ///
  /// Usernames are validated on creation, so this is belt and braces — but it is
  /// the belt that matters: a username reaching the filesystem unchecked is how
  /// `../../etc` becomes a path.
  Directory userDir(String user) =>
      Directory('${root.path}/users/${_safe(user)}');

  Directory deviceDir(String user, String device) =>
      Directory('${userDir(user).path}/devices/${_safe(device)}');

  JsonFile deviceMeta(String user, String device) =>
      JsonFile(File('${deviceDir(user, device).path}/device.json'));

  JsonFile latest(String user, String device) =>
      JsonFile(File('${deviceDir(user, device).path}/latest.json'));

  Directory snapshots(String user, String device) =>
      Directory('${deviceDir(user, device).path}/snapshots');

  File snapshot(String user, String device, String id) =>
      File('${snapshots(user, device).path}/${_safe(id)}.json');

  JsonFile queue(String user, String device) =>
      JsonFile(File('${deviceDir(user, device).path}/edits/queue.json'));

  JsonFile appliedLog(String user, String device) =>
      JsonFile(File('${deviceDir(user, device).path}/edits/applied.log'));

  /// Every device directory name a user has, in no particular order.
  List<String> deviceIds(String user) {
    final Directory dir = Directory('${userDir(user).path}/devices');
    if (!dir.existsSync()) return const <String>[];
    return dir
        .listSync()
        .whereType<Directory>()
        .map((Directory d) => d.path.split(Platform.pathSeparator).last)
        .toList();
  }
}

/// A path component with anything structural removed.
///
/// Not an escape: it rejects by replacing. A component that would traverse
/// upwards, name a hidden file or reach another directory cannot survive this,
/// and an empty result becomes a fixed placeholder rather than the parent
/// directory itself.
String _safe(String component) {
  final String cleaned =
      component.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_').replaceAll('..', '_');
  final String trimmed = cleaned.replaceAll(RegExp(r'^[._]+'), '');
  return trimmed.isEmpty ? 'unnamed' : trimmed;
}

/// [_safe], for tests and for validating input before it is stored.
String safePathComponent(String component) => _safe(component);
