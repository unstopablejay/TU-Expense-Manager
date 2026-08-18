/// What the server reads from its environment.
///
/// Everything has a default that works except the data directory's contents and
/// the first account. There is deliberately no default password and no
/// open-by-default mode: a server that came up unauthenticated because a variable
/// was misspelled would be the worst possible failure here.
library;

import 'dart:io';

/// The parsed environment.
class Config {
  const Config({
    required this.port,
    required this.dataDir,
    required this.webRoot,
    required this.snapshotKeep,
    required this.maxUploadBytes,
    required this.editExpiryDays,
    required this.bootstrapUser,
    required this.bootstrapPassword,
    required this.trustProxyHeaders,
  });

  /// Reads [env], falling back to the process environment.
  factory Config.fromEnvironment([Map<String, String>? env]) {
    final Map<String, String> e = env ?? Platform.environment;

    int number(String key, int fallback, {int min = 1}) {
      final String? raw = e[key];
      if (raw == null || raw.trim().isEmpty) return fallback;
      final int? value = int.tryParse(raw.trim());
      if (value == null || value < min) {
        throw ConfigError(
          '$key is "$raw", which is not a whole number of at least $min.',
        );
      }
      return value;
    }

    return Config(
      port: number('PORT', 8099),
      dataDir: e['DATA_DIR']?.trim().isNotEmpty == true
          ? e['DATA_DIR']!.trim()
          : '/data',
      webRoot: e['WEB_ROOT']?.trim().isNotEmpty == true
          ? e['WEB_ROOT']!.trim()
          : '/app/web',
      snapshotKeep: number('SNAPSHOT_KEEP', 30),
      maxUploadBytes: number('MAX_UPLOAD_BYTES', 32 * 1024 * 1024, min: 1024),
      editExpiryDays: number('EDIT_EXPIRY_DAYS', 30),
      bootstrapUser: e['EXPENSE_ADMIN_USER']?.trim(),
      bootstrapPassword: e['EXPENSE_ADMIN_PASSWORD'],
      // Off by default. Believing an X-Forwarded-For from an untrusted source
      // is how a log becomes fiction, and this server's normal deployment has
      // no proxy in front of it.
      trustProxyHeaders: (e['TRUST_PROXY_HEADERS'] ?? '').toLowerCase() == 'true',
    );
  }

  final int port;
  final String dataDir;

  /// Where the Flutter web bundle lives. Serving it is optional — a missing
  /// directory means the API runs and the browser gets a plain message, which is
  /// better than refusing to start.
  final String webRoot;

  final int snapshotKeep;
  final int maxUploadBytes;
  final int editExpiryDays;

  /// The account to create if there are none yet.
  ///
  /// Only ever creates; never resets an existing account. So leaving these set in
  /// a compose file is harmless after the first run, which is exactly how people
  /// actually use compose files.
  final String? bootstrapUser;
  final String? bootstrapPassword;

  final bool trustProxyHeaders;

  Duration get editExpiry => Duration(days: editExpiryDays);

  /// A one-line summary for the startup log. Carries no secrets.
  String describe() => 'port $port, data $dataDir, web $webRoot, '
      'keep $snapshotKeep snapshots, max upload '
      '${(maxUploadBytes / (1024 * 1024)).toStringAsFixed(0)} MB, '
      'edits expire after $editExpiryDays days';
}

/// A configuration problem worth refusing to start over.
class ConfigError implements Exception {
  const ConfigError(this.message);

  final String message;

  @override
  String toString() => message;
}
