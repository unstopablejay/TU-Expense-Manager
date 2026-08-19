/// What the phone remembers about its server.
///
/// Follows [UpdatePrefs] exactly: a const singleton, one
/// `SharedPreferences.getInstance()` per accessor, dotted keys. These are
/// preferences rather than data, so — like the updater's settings — they are
/// deliberately **not** part of the `.xlsx` backup.
///
/// That exclusion is load-bearing for [deviceId]. Restoring one phone's backup
/// onto another device must not hand over the first device's identity, or the
/// second would push into the first's slot and overwrite its ledger. The scan
/// watermark lives in `app_meta` for the opposite reason: it *should* travel.
library;

import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// How often an automatic sync runs while the app is open, in minutes.
///
/// Fifteen is the compromise. An edit made on a PC lands within a quarter of an
/// hour without being asked for, which is what makes the browser feel like part
/// of the same app; and the poll itself is one small request, because a ledger
/// that has not changed is not uploaded again. The floor is what keeps a hand-
/// edited preference from turning the app into a load generator.
const int kDefaultAutoSyncMinutes = 15;
const int kMinAutoSyncMinutes = 1;
const int kMaxAutoSyncMinutes = 24 * 60;

/// What Settings offers, in minutes.
///
/// Five is for someone sitting at the browser editing; an hour is for someone
/// who wants their ledger backed up and nothing more. Anything under five would
/// be a poll for the sake of it — an edit made in a browser is not urgent.
const List<int> kAutoSyncChoices = <int>[5, 15, 30, 60];

/// An interval in minutes, in words.
String describeSyncInterval(int minutes) => switch (minutes) {
      1 => 'Every minute',
      60 => 'Every hour',
      final int m when m % 60 == 0 => 'Every ${m ~/ 60} hours',
      final int m => 'Every $m minutes',
    };

/// What the last successful upload was and where it went.
///
/// Not just the fingerprint: see [SyncPrefs.lastPush] for why all three fields
/// have to agree before a push can be skipped.
class PushMemory {
  const PushMemory({
    required this.fingerprint,
    required this.snapshotId,
    required this.target,
  });

  /// [snapshotFingerprint] of the ledger that was sent.
  final String fingerprint;

  /// The id the server filed it under, so this device can tell that the copy it
  /// pushed is still the one the server holds.
  final String snapshotId;

  /// The server address and device id it was sent as, as one string.
  final String target;
}

/// How to spell a [PushMemory.target].
String pushTarget(Uri base, String device) => '$base|$device';

class SyncPrefs {
  const SyncPrefs();

  static const SyncPrefs instance = SyncPrefs();

  static const String _baseUrlKey = 'sync.base_url';
  static const String _tokenKey = 'sync.token';
  static const String _usernameKey = 'sync.username';
  static const String _deviceIdKey = 'sync.device_id';
  static const String _deviceLabelKey = 'sync.device_label';
  static const String _lastPushedKey = 'sync.last_pushed_ms';
  static const String _lastResultKey = 'sync.last_result';
  static const String _autoAfterScanKey = 'sync.auto_after_scan';
  static const String _autoKey = 'sync.auto';
  static const String _autoMinutesKey = 'sync.auto_minutes';
  static const String _lastPushKey = 'sync.last_push';

  /// The server, or null when sync has never been set up.
  ///
  /// Null is what makes the whole feature inert: with no address, nothing here
  /// ever opens a socket.
  Future<Uri?> baseUrl() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_baseUrlKey);
    if (raw == null || raw.trim().isEmpty) return null;
    return Uri.tryParse(raw.trim());
  }

  Future<void> setBaseUrl(String? value) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (value == null || value.trim().isEmpty) {
      await prefs.remove(_baseUrlKey);
      return;
    }
    await prefs.setString(_baseUrlKey, value.trim());
  }

  /// Whether a URL is usable as a server address, and why not if it is not.
  ///
  /// Accepts a bare `http://192.168.1.99:8099`, which is what anyone will
  /// actually type. Requires a scheme and a host, because `Uri.parse` cheerfully
  /// accepts `zima.local:8099` and reads `zima.local` as the *scheme* — which
  /// then fails at request time with something unrecognisable.
  static String? baseUrlProblem(String value) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty) return 'Enter the address of your server.';
    final Uri? uri = Uri.tryParse(trimmed);
    if (uri == null) return 'That is not a valid address.';
    if (!uri.hasScheme || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return 'Start with http:// or https:// — for example '
          'http://192.168.1.99:8099';
    }
    if (uri.host.isEmpty) {
      return 'That address has no host in it.';
    }
    return null;
  }

  /// The session token, or null when signed out.
  Future<String?> token() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getString(_tokenKey);
  }

  Future<String?> username() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getString(_usernameKey);
  }

  Future<void> setSession({required String token, required String username}) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
    await prefs.setString(_usernameKey, username);
  }

  /// Forgets the session but keeps the address and the device identity.
  ///
  /// Signing out should not orphan this device's slot on the server: signing
  /// back in has to land on the same one, or the ledger already there becomes
  /// unreachable and a second slot starts accumulating beside it.
  Future<void> clearSession() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_usernameKey);
  }

  /// This installation's identity on the server, minted once.
  ///
  /// Generated on first use rather than at install, so a phone that never syncs
  /// never acquires one. A reinstall gets a new id and therefore a new slot,
  /// which is the right trade: the alternative is an id that survives in a
  /// backup and lets two devices claim to be the same one.
  Future<String> deviceId() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? existing = prefs.getString(_deviceIdKey);
    if (existing != null && existing.isNotEmpty) return existing;

    final String minted = _mintDeviceId();
    await prefs.setString(_deviceIdKey, minted);
    return minted;
  }

  /// What to call this device in the browser's picker.
  ///
  /// Free text the user sets. Falls back to something recognisable rather than
  /// the raw id, since a list of hashes is no way to choose between two phones.
  Future<String> deviceLabel() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? label = prefs.getString(_deviceLabelKey);
    return (label == null || label.trim().isEmpty) ? 'This phone' : label.trim();
  }

  Future<void> setDeviceLabel(String value) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_deviceLabelKey, value.trim());
  }

  Future<DateTime?> lastPushed() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final int? millis = prefs.getInt(_lastPushedKey);
    return millis == null ? null : DateTime.fromMillisecondsSinceEpoch(millis);
  }

  /// Records how the last attempt went.
  ///
  /// The timestamp moves only on success, so "last synced" cannot be made to
  /// read as recent by a run that failed. The message is kept either way, so the
  /// screen can say what went wrong after the SnackBar has gone.
  Future<void> setLastResult({required bool ok, required String message}) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (ok) {
      await prefs.setInt(
        _lastPushedKey,
        DateTime.now().millisecondsSinceEpoch,
      );
    }
    await prefs.setString(_lastResultKey, message);
  }

  Future<String?> lastResult() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getString(_lastResultKey);
  }

  /// Whether to push after an inbox scan that found something.
  ///
  /// Defaults to **off**, unlike the update checker. A network call the user did
  /// not ask for should be opted into, and someone who has not finished setting
  /// up a server should not have failures reported at them.
  Future<bool> autoAfterScan() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoAfterScanKey) ?? false;
  }

  Future<void> setAutoAfterScan(bool value) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoAfterScanKey, value);
  }

  /// Whether the app syncs by itself while it is open.
  ///
  /// Defaults to **on**, unlike [autoAfterScan], and the difference is
  /// deliberate. That switch is about uploading; this one is what makes an edit
  /// made in a browser ever reach the phone at all. Left off, the browser is an
  /// editor whose changes only land when somebody remembers to open Settings and
  /// press a button — which is not a feature, it is a trap. It stays inert until
  /// a server is configured and signed into, so a user who never sets one up
  /// still never sees a network call.
  Future<bool> auto() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoKey) ?? true;
  }

  Future<void> setAuto(bool value) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoKey, value);
  }

  /// How often to sync while the app is open, in minutes.
  ///
  /// Clamped on the way out rather than trusted: a value of zero read back from
  /// a hand-edited preferences file would be a request for an infinite loop of
  /// network calls.
  Future<int> autoMinutes() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final int minutes = prefs.getInt(_autoMinutesKey) ?? kDefaultAutoSyncMinutes;
    return minutes.clamp(kMinAutoSyncMinutes, kMaxAutoSyncMinutes);
  }

  Future<void> setAutoMinutes(int value) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      _autoMinutesKey,
      value.clamp(kMinAutoSyncMinutes, kMaxAutoSyncMinutes),
    );
  }

  /// What the last successful upload was, so an unchanged ledger is not
  /// uploaded again.
  ///
  /// Three things together, because any one of them alone would be a way to skip
  /// a push that was actually needed: the fingerprint of what was sent, the
  /// snapshot id the server gave back, and the address and device it was sent
  /// to. Pointing the app at a second server, or a restore that mints a new
  /// device id, has to push in full rather than trusting a fingerprint that
  /// describes somewhere else.
  Future<PushMemory?> lastPush() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_lastPushKey);
    if (raw == null || raw.isEmpty) return null;
    // Three fields joined by a character none of them can contain: a
    // fingerprint is hex, a snapshot id has no spaces, and a target is a URL
    // plus a device id.
    final List<String> parts = raw.split(' ');
    if (parts.length != 3) return null;
    return PushMemory(
      fingerprint: parts[0],
      snapshotId: parts[1],
      target: parts[2],
    );
  }

  Future<void> setLastPush(PushMemory memory) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _lastPushKey,
      '${memory.fingerprint} ${memory.snapshotId} ${memory.target}',
    );
  }

  Future<void> clearLastPush() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastPushKey);
  }

  /// Whether there is enough here to try a sync.
  Future<bool> get isConfigured async =>
      (await baseUrl()) != null && (await token()) != null;
}

/// A random identifier for this installation.
///
/// `Random.secure()` and 16 bytes: this is not a secret, but it does have to be
/// unique across every device pointed at one server, and a timestamp or a
/// counter would collide between two installs made in the same second.
String _mintDeviceId() {
  final Random random = Random.secure();
  const String alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789';
  return List<String>.generate(
    16,
    (_) => alphabet[random.nextInt(alphabet.length)],
    growable: false,
  ).join();
}
