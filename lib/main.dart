/// TU Expense Tracker — an Android app that turns bank SMS alerts into a
/// categorized expense ledger.
///
/// This file is the mobile entrypoint. It is also the package's barrel: every
/// name the app once declared in one file is re-exported here, so
/// `package:tu_expense_tracker/main.dart` still resolves all of them and the
/// test suite needs no knowledge of the layout underneath.
library;

import 'package:flutter/widgets.dart';

import 'src/mobile/home_shell.dart';
import 'src/ui_shared/theme_controller.dart';

export 'src/core/aliases.dart';
export 'src/core/backup_data.dart';
export 'src/core/backup_json.dart';
export 'src/core/backup_validate.dart';
export 'src/core/constants.dart';
export 'src/core/edits.dart';
export 'src/core/ledger.dart';
export 'src/core/ledger_view.dart';
export 'src/core/link_state.dart';
export 'src/core/models.dart';
export 'src/core/parser.dart';
export 'src/core/snapshot_store.dart';
export 'src/core/splits.dart';
export 'src/mobile/auto_sync.dart';
export 'src/mobile/backup_dialogs.dart';
export 'src/mobile/backup_files.dart';
export 'src/mobile/backup_xlsx.dart';
export 'src/mobile/connection_monitor.dart';
export 'src/mobile/database.dart';
export 'src/mobile/home_shell.dart';
export 'src/mobile/screens/categories_screen.dart';
export 'src/mobile/screens/category_picker_sheet.dart';
export 'src/mobile/screens/deleted_screen.dart';
export 'src/mobile/screens/merchant_defaults_screen.dart';
export 'src/mobile/screens/merge_names_screen.dart';
export 'src/mobile/screens/settings_screen.dart';
export 'src/mobile/screens/split_screen.dart';
export 'src/mobile/screens/transaction_actions_sheet.dart';
export 'src/mobile/screens/update_dialog.dart';
export 'src/mobile/sms_source.dart';
export 'src/mobile/sync_client.dart';
export 'src/mobile/sync_prefs.dart';
export 'src/mobile/update_service.dart';
export 'src/mobile/widgets/server_backups_sheet.dart';
export 'src/mobile/widgets/settings_header.dart';
export 'src/ui_shared/connection_dot.dart';
export 'src/ui_shared/dashboard_tab.dart';
export 'src/ui_shared/formats.dart';
export 'src/ui_shared/palette.dart';
export 'src/ui_shared/shared_controls.dart';
export 'src/ui_shared/theme.dart';
export 'src/ui_shared/theme_controller.dart';
export 'src/ui_shared/theme_models.dart';
export 'src/ui_shared/transactions_tab.dart';
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ThemeController.instance.load();
  runApp(const TuExpenseTrackerApp());
}
