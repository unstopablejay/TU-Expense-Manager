import 'dart:io';
// Imports core directly rather than main.dart: core is pure Dart, so this runs
// under plain `dart run` with no Flutter toolchain. That is the purity boundary
// paying for itself — main.dart would drag in Material and fail to compile here.
import 'package:tu_expense_tracker/src/core/backup_data.dart';
import 'package:tu_expense_tracker/src/core/backup_json.dart';
import 'package:tu_expense_tracker/src/core/constants.dart';

void main(List<String> args) {
  final int n = int.parse(args.isEmpty ? '3' : args[0]);
  final String merchantPrefix = args.length > 1 ? args[1] : 'SWIGGY';
  stdout.write(encodeBackupJson(BackupData(
    categories: <Map<String, Object?>>[
      <String, Object?>{'id': 1, 'name': kUncategorized},
      <String, Object?>{'id': 2, 'name': 'Grocery'},
      <String, Object?>{'id': 3, 'name': 'Food'},
    ],
    merchantMappings: <Map<String, Object?>>[
      <String, Object?>{'merchant_name': merchantPrefix, 'category_id': 3},
    ],
    transactions: <Map<String, Object?>>[
      for (int i = 0; i < n; i++)
        <String, Object?>{
          'id': i + 1,
          'amount': 100.0 * (i + 1),
          'payment_type': 'YES BANK Card X2858',
          'merchant': '$merchantPrefix-$i',
          'date': 1755000000000 + i * 60000,
          'category_id': (i % 3) + 1,
          'direction': i.isEven ? 'debit' : 'credit',
          'reference': '',
          'note': i == 0 ? 'dinner' : '',
        },
    ],
    splits: const <Map<String, Object?>>[],
    deleted: const <Map<String, Object?>>[],
    aliases: const <Map<String, Object?>>[],
    appMeta: <Map<String, Object?>>[
      <String, Object?>{'key': 'last_scanned_sms_date', 'value': '1755000000000'},
    ],
    meta: buildBackupMeta(
      appVersion: '1.1.0', appBuild: '2',
      exportedAt: DateTime.now().toUtc(),
      transactions: n, splits: 0, categories: 3,
      merchantDefaults: 1, nameAliases: 0, deleted: 0,
    ),
  )));
}
