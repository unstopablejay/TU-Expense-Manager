/// Accounts, passwords and sessions.
///
/// A password crosses the wire exactly once, at login, and is exchanged for an
/// opaque session token that everything else uses. That is worth stating because
/// this server is expected to run over plain HTTP on a home LAN or a WireGuard
/// link: a token that leaks can be revoked, and a password that leaks cannot.
///
/// Nothing here is hand-rolled. Argon2id comes from pointycastle, the salts and
/// tokens come from the platform's secure random, and comparisons that could
/// otherwise be timed are done in constant time.
library;

import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'json_store.dart';

/// Argon2id cost. Comfortably above the OWASP floor of 19 MiB / t=2.
///
/// Measured at about 0.6 s on an M-series Mac and perhaps two or three times
/// that on NAS hardware. That is a lot for a web request and entirely fine here:
/// a login happens once per device per session lifetime, and the cost is the
/// whole point — it is what makes a stolen `users.json` expensive to attack.
const int kArgonMemoryKiB = 65536; // 64 MiB
const int kArgonIterations = 3;
const int kArgonLanes = 4;
const int kArgonKeyLength = 32;

/// How long a session lasts, renewed on every authenticated request.
///
/// Long, because the phone syncs unattended — an auto-push after an inbox scan
/// must not fail because a token quietly expired — and because the alternative
/// is storing the password on the device to re-login with, which is worse.
const Duration kSessionLifetime = Duration(days: 90);

/// A username that can be stored, addressed and put in a path.
///
/// Lower-case, because a user who signs in as `Jay` means the account they
/// created as `jay`, and two accounts differing only in case would be a trap
/// rather than a feature.
final RegExp _validUsername = RegExp(r'^[a-z0-9][a-z0-9._-]{1,31}$');

/// Whether [username] may be used, and why not if it may not.
String? usernameProblem(String username) {
  if (username != username.toLowerCase()) {
    return 'A username must be lower case.';
  }
  if (!_validUsername.hasMatch(username)) {
    return 'A username must be 2 to 32 characters of letters, digits, dot, '
        'dash or underscore, and must start with a letter or digit.';
  }
  return null;
}

/// Whether [password] may be used, and why not if it may not.
///
/// A length floor and nothing else. Composition rules push people towards
/// `Passw0rd!` and away from the long passphrase that actually resists the
/// offline attack this is hashed against.
String? passwordProblem(String password) {
  if (password.length < 10) {
    return 'A password must be at least 10 characters. A short phrase of a few '
        'words is both stronger and easier to type on a phone.';
  }
  if (password.length > 256) {
    return 'A password must be at most 256 characters.';
  }
  return null;
}

/// One account.
class User {
  const User({
    required this.username,
    required this.salt,
    required this.hash,
    required this.createdAt,
  });

  factory User.fromJson(Map<String, Object?> json) => User(
        username: json['username']! as String,
        salt: json['salt']! as String,
        hash: json['hash']! as String,
        createdAt: DateTime.parse(json['created_at']! as String),
      );

  final String username;

  /// Base64. Per-user, so identical passwords on two accounts hash differently
  /// and one cracked hash says nothing about the other.
  final String salt;

  /// Base64 Argon2id digest of the password with [salt].
  final String hash;

  final DateTime createdAt;

  Map<String, Object?> toJson() => <String, Object?>{
        'username': username,
        'salt': salt,
        'hash': hash,
        'created_at': createdAt.toIso8601String(),
      };
}

/// A live session.
class Session {
  const Session({
    required this.token,
    required this.username,
    required this.expiresAt,
  });

  factory Session.fromJson(Map<String, Object?> json) => Session(
        token: json['token']! as String,
        username: json['username']! as String,
        expiresAt: DateTime.parse(json['expires_at']! as String),
      );

  final String token;
  final String username;
  final DateTime expiresAt;

  bool isLiveAt(DateTime now) => now.isBefore(expiresAt);

  Map<String, Object?> toJson() => <String, Object?>{
        'token': token,
        'username': username,
        'expires_at': expiresAt.toIso8601String(),
      };
}

/// The accounts and sessions on disk.
class AuthStore {
  AuthStore(this.paths, this.lock);

  final Paths paths;
  final WriteLock lock;

  /// Every account, by username.
  Future<Map<String, User>> users() async {
    final Object? raw = await paths.users.read();
    if (raw is! List) return <String, User>{};
    return <String, User>{
      for (final Object? entry in raw)
        if (entry is Map<String, Object?>)
          (entry['username']! as String): User.fromJson(entry),
    };
  }

  Future<bool> hasAnyUser() async => (await users()).isNotEmpty;

  /// Creates [username] with [password].
  ///
  /// Returns a problem to show, or null on success. Refuses to overwrite an
  /// existing account: changing a password is [setPassword], and conflating the
  /// two would make a typo in a bootstrap variable silently reset an account.
  Future<String?> addUser(String username, String password) async {
    final String? bad = usernameProblem(username) ?? passwordProblem(password);
    if (bad != null) return bad;

    return lock.synchronized(() async {
      final Map<String, User> existing = await users();
      if (existing.containsKey(username)) {
        return 'There is already an account called "$username".';
      }
      final String salt = _randomBase64(16);
      existing[username] = User(
        username: username,
        salt: salt,
        hash: _hash(password, salt),
        createdAt: DateTime.now().toUtc(),
      );
      await _writeUsers(existing);
      return null;
    });
  }

  /// Replaces [username]'s password. Returns a problem to show, or null.
  ///
  /// Every session belonging to the account is dropped. Changing a password is
  /// what someone does when they think a credential has leaked, and leaving the
  /// old sessions alive would make the act pointless.
  Future<String?> setPassword(String username, String password) async {
    final String? bad = passwordProblem(password);
    if (bad != null) return bad;

    return lock.synchronized(() async {
      final Map<String, User> existing = await users();
      final User? user = existing[username];
      if (user == null) return 'There is no account called "$username".';

      final String salt = _randomBase64(16);
      existing[username] = User(
        username: username,
        salt: salt,
        hash: _hash(password, salt),
        createdAt: user.createdAt,
      );
      await _writeUsers(existing);
      await _writeSessions(
        (await sessions()).where((Session s) => s.username != username).toList(),
      );
      return null;
    });
  }

  /// A new session for [username] if [password] is right, else null.
  ///
  /// The work happens whether or not the account exists: a missing account is
  /// checked against a throwaway hash so that a wrong username and a wrong
  /// password take the same time to refuse, and the response cannot be used to
  /// enumerate accounts.
  Future<Session?> login(String username, String password) async {
    final User? user = (await users())[username];
    final String salt = user?.salt ?? _decoySalt;
    final String expected = user?.hash ?? _decoyHash;

    final bool ok = constantTimeEquals(_hash(password, salt), expected);
    if (!ok || user == null) return null;

    return lock.synchronized(() async {
      final Session session = Session(
        token: _randomBase64(32),
        username: username,
        expiresAt: DateTime.now().toUtc().add(kSessionLifetime),
      );
      final List<Session> live = await _liveSessions();
      await _writeSessions(<Session>[...live, session]);
      return session;
    });
  }

  /// Every session on disk, expired ones included.
  Future<List<Session>> sessions() async {
    final Object? raw = await paths.sessions.read();
    if (raw is! List) return <Session>[];
    return <Session>[
      for (final Object? entry in raw)
        if (entry is Map<String, Object?>) Session.fromJson(entry),
    ];
  }

  /// Who [token] belongs to, or null if it is unknown or expired.
  ///
  /// Compared in constant time against each candidate. A session token is a
  /// bearer credential, and `==` on a string returns as soon as two bytes differ.
  Future<String?> userForToken(String token) async {
    if (token.isEmpty) return null;
    final DateTime now = DateTime.now().toUtc();
    for (final Session session in await sessions()) {
      if (constantTimeEquals(session.token, token) && session.isLiveAt(now)) {
        return session.username;
      }
    }
    return null;
  }

  /// Extends [token]'s life, so an active device is never logged out.
  ///
  /// Only rewrites the file when the expiry has moved by more than a day, so a
  /// phone syncing every few minutes does not rewrite it every time.
  Future<void> touch(String token) async {
    final DateTime now = DateTime.now().toUtc();
    final DateTime renewed = now.add(kSessionLifetime);
    final List<Session> all = await sessions();
    final int i = all.indexWhere((Session s) => s.token == token);
    if (i < 0) return;
    if (renewed.difference(all[i].expiresAt) < const Duration(days: 1)) return;

    await lock.synchronized(() async {
      final List<Session> current = await sessions();
      final int j = current.indexWhere((Session s) => s.token == token);
      if (j < 0) return;
      current[j] = Session(
        token: current[j].token,
        username: current[j].username,
        expiresAt: renewed,
      );
      await _writeSessions(
        current.where((Session s) => s.isLiveAt(now)).toList(),
      );
    });
  }

  /// Ends one session.
  Future<void> logout(String token) => lock.synchronized(() async {
        final DateTime now = DateTime.now().toUtc();
        await _writeSessions((await sessions())
            .where((Session s) => s.token != token && s.isLiveAt(now))
            .toList());
      });

  Future<List<Session>> _liveSessions() async {
    final DateTime now = DateTime.now().toUtc();
    return (await sessions()).where((Session s) => s.isLiveAt(now)).toList();
  }

  Future<void> _writeUsers(Map<String, User> users) => paths.users.write(
        users.values.map((User u) => u.toJson()).toList(),
      );

  Future<void> _writeSessions(List<Session> sessions) =>
      paths.sessions.write(sessions.map((Session s) => s.toJson()).toList());
}

/// Argon2id of [password] with [salt], base64.
String hashPassword(String password, String salt) => _hash(password, salt);

String _hash(String password, String salt) {
  final Argon2Parameters params = Argon2Parameters(
    Argon2Parameters.ARGON2_id,
    Uint8List.fromList(base64.decode(salt)),
    desiredKeyLength: kArgonKeyLength,
    version: Argon2Parameters.ARGON2_VERSION_13,
    iterations: kArgonIterations,
    memory: kArgonMemoryKiB,
    lanes: kArgonLanes,
  );
  final Uint8List out = Uint8List(kArgonKeyLength);
  (Argon2BytesGenerator()..init(params))
      .deriveKey(Uint8List.fromList(utf8.encode(password)), 0, out, 0);
  return base64.encode(out);
}

/// Whether [a] and [b] are equal, in time that does not depend on where they
/// first differ.
///
/// `==` on a String returns at the first differing byte, which leaks the length
/// of a correct prefix to anyone who can measure it. That matters for a token
/// an attacker can guess at repeatedly.
bool constantTimeEquals(String a, String b) {
  final List<int> x = utf8.encode(a);
  final List<int> y = utf8.encode(b);
  // Length is not secret — a token's length is fixed and public — but the
  // comparison still has to run over a fixed number of bytes either way.
  int diff = x.length ^ y.length;
  final int n = x.length < y.length ? x.length : y.length;
  for (int i = 0; i < n; i++) {
    diff |= x[i] ^ y[i];
  }
  return diff == 0;
}

/// [bytes] of cryptographically secure randomness, base64.
String _randomBase64(int bytes) {
  final Random random = Random.secure();
  return base64.encode(
    List<int>.generate(bytes, (_) => random.nextInt(256), growable: false),
  );
}

/// A token or salt of [bytes] bytes, for callers outside this file.
String randomToken([int bytes = 32]) => _randomBase64(bytes);

/// A fixed salt and hash to check an unknown username against.
///
/// Constants rather than fresh randomness, so that the decoy costs exactly what
/// a real check costs and no allocation gives the difference away.
const String _decoySalt = 'AAAAAAAAAAAAAAAAAAAAAA==';
final String _decoyHash = _hash('no-such-user', _decoySalt);

/// Computes [_decoyHash] now, rather than on the first login that needs it.
///
/// A lazy `final` makes the *first* login for an unknown username pay for two
/// hashes, taking about twice as long as a wrong password for a real account --
/// measured at 1140ms against 628ms. That difference is a signal saying "no such
/// account", which is the one thing the decoy exists to hide.
void warmPasswordHasher() {
  _decoyHash.length;
}
