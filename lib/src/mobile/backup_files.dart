/// Getting a backup onto the device and back off it.
///
/// The platform half of the backup feature: storage directories, the share
/// sheet's MIME type, and the two `compute()` hops that keep encoding and
/// decoding a large workbook off the frame.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../core/backup_data.dart';
import 'backup_xlsx.dart';

// --- files, isolates and the share sheet -----------------------------------

/// What Android and Google Drive need to be told an `.xlsx` is, so that Sheets
/// offers to open it rather than the file being treated as an unknown blob.
const String kXlsxMimeType =
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet';

/// What a backup is called. Dated, because the first thing anyone wants to know
/// about a file found in Drive a year later is when it was taken.
///
/// The pre-restore copy carries the time as well: a restore that went wrong is
/// likely to be followed by another attempt within the minute, and two safety
/// copies from one afternoon must not overwrite each other.
String backupFileName(DateTime at, {bool beforeRestore = false}) =>
    beforeRestore
        ? 'tu-expense-before-restore-'
            '${DateFormat('yyyy-MM-dd-HHmm').format(at)}.xlsx'
        : 'tu-expense-${DateFormat('yyyy-MM-dd').format(at)}.xlsx';

/// Where backups land. App-specific external storage, for the same reasons the
/// updater uses it: writable without a storage permission, and readable by the
/// app a share hands the file on to.
Future<Directory> _backupFolder() async {
  final Directory base = await getExternalStorageDirectory() ??
      await getApplicationSupportDirectory();
  final Directory folder = Directory(p.join(base.path, 'backups'));
  await folder.create(recursive: true);
  return folder;
}

/// Builds the workbook and writes it, returning the file.
///
/// The encoding happens on a background isolate. A workbook is zipped XML built
/// a cell at a time, so a few thousand transactions is comfortably enough work
/// to freeze a spinner mid-spin if it were done here.
Future<File> writeBackup(BackupData data, String fileName) async {
  final Directory folder = await _backupFolder();
  final File file = File(p.join(folder.path, fileName));
  await file.writeAsBytes(await compute(encodeBackupWorkbook, data));
  return file;
}

/// [decodeBackupWorkbook] on a background isolate.
///
/// Returns the failure rather than throwing it: the message is written for the
/// user, and having it survive the isolate boundary as a plain string is surer
/// than trusting an exception object to.
Future<(BackupData?, String?)> decodeBackupInBackground(Uint8List bytes) =>
    compute(_decodeOrMessage, bytes);

(BackupData?, String?) _decodeOrMessage(Uint8List bytes) {
  try {
    return (decodeBackupWorkbook(bytes), null);
  } on BackupFormatException catch (error) {
    return (null, error.message);
  } catch (error) {
    return (null, 'That file could not be read as a backup ($error).');
  }
}
