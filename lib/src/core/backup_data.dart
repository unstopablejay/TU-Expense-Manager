/// A whole-database snapshot, as raw rows, and the envelope that stamps it.
///
/// The container both the `.xlsx` backup and the JSON sync snapshot are built
/// from, so the two cannot disagree about what a backup holds or how it is
/// labelled.
library;

import 'constants.dart';

/// The marker that says a backup is one of ours. A file without it is somebody
/// else's spreadsheet, or somebody else's JSON, and is refused rather than
/// guessed at.
///
/// Shared by the `.xlsx` workbook and the JSON snapshot on purpose: one marker
/// means one [validateBackup] covers both, and neither can drift into accepting
/// what the other would reject.
const String kBackupFormat = 'tu-expense-tracker-backup';

/// The layout of a backup, which moves independently of the database schema.
/// Bumped only if a field is renamed or changes meaning — *adding* one needs no
/// bump, because both readers key on names rather than on position.
const int kBackupFormatVersion = 1;

/// The Meta block that stamps a backup or a snapshot.
///
/// One function rather than a literal at each writer: the `.xlsx` workbook and
/// the JSON snapshot carry the same keys, and a key spelled two ways would only
/// show up when the wrong one failed to read back.
///
/// Counts are a cheap sanity check for a human reading the file, and give the
/// confirmation dialog something to say before it commits.
Map<String, String> buildBackupMeta({
  required String appVersion,
  required String appBuild,
  required DateTime exportedAt,
  required int transactions,
  required int splits,
  required int categories,
  required int merchantDefaults,
  required int nameAliases,
  required int deleted,
}) =>
    <String, String>{
      'format': kBackupFormat,
      'format_version': '$kBackupFormatVersion',
      'schema_version': '$kSchemaVersion',
      'app_version': appVersion,
      'app_build': appBuild,
      'exported_at': exportedAt.toIso8601String(),
      'transactions': '$transactions',
      'splits': '$splits',
      'categories': '$categories',
      'merchant_defaults': '$merchantDefaults',
      'name_aliases': '$nameAliases',
      'deleted': '$deleted',
    };

/// A backup that cannot be read at all — not the wrong contents, but the wrong
/// shape: not a workbook, a sheet missing, a required column absent, a number
/// where text was promised. Carries a sentence fit to show the user.
class BackupFormatException implements Exception {
  const BackupFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Every table, as the raw rows the database holds — not the domain models.
///
/// [ExpenseTxn] deliberately reports *merged* names and synthesises a split line
/// for unsplit transactions, both of which are exactly wrong for a backup: the
/// merchant is part of the natural key that finds a row again, and a synthesised
/// line would restore as a real one. So this carries what `db.query` returned
/// and nothing else.
class BackupData {
  const BackupData({
    required this.categories,
    required this.merchantMappings,
    required this.transactions,
    required this.splits,
    required this.deleted,
    required this.aliases,
    required this.appMeta,
    required this.meta,
  });

  final List<Map<String, Object?>> categories;
  final List<Map<String, Object?>> merchantMappings;
  final List<Map<String, Object?>> transactions;
  final List<Map<String, Object?>> splits;
  final List<Map<String, Object?>> deleted;
  final List<Map<String, Object?>> aliases;
  final List<Map<String, Object?>> appMeta;

  /// The Meta sheet, already keyed. Holds the format marker, the schema version
  /// the file was written at, and the row counts.
  final Map<String, String> meta;

  int? get formatVersion => int.tryParse(meta['format_version'] ?? '');
  int? get schemaVersion => int.tryParse(meta['schema_version'] ?? '');
}
