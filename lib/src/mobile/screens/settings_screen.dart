/// Settings: categorization, cleanup, data and updates.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:file_picker/file_picker.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:share_plus/share_plus.dart';
import '../../core/aliases.dart';
import '../../core/backup_data.dart';
import '../../core/backup_validate.dart';
import '../../core/constants.dart';
import '../auto_sync.dart';
import '../backup_dialogs.dart';
import '../backup_files.dart';
import '../connection_monitor.dart';
import '../database.dart';
import '../sync_client.dart';
import '../sync_prefs.dart';
import '../update_service.dart';
import '../widgets/settings_header.dart';
import 'categories_screen.dart';
import 'merchant_defaults_screen.dart';
import 'merge_names_screen.dart';
import 'update_dialog.dart';

/// The second destination. A body only — the shell it sits in supplies the
/// Scaffold and the app bar, so there is no second one of either here.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.onChanged});

  /// Called when something here changed the ledger.
  ///
  /// A sync applies edits made in a browser, so this screen can now write to the
  /// database. The shell reloads on leaving Settings anyway, but relying on that
  /// alone would leave stale rows visible if the user syncs and then navigates
  /// somewhere else first. The pushed sub-screens already take this callback for
  /// the same reason.
  final VoidCallback? onChanged;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final DateFormat _checkedFormat = DateFormat('d MMM yyyy, h:mm a');

  bool _autoCheck = true;
  String _version = '';
  String _build = '';
  DateTime? _lastChecked;
  bool _loading = true;
  bool _checking = false;

  /// One at a time, and neither while the other runs: both walk the whole
  /// database, and a restore landing halfway through an export would write a
  /// workbook of two different ledgers.
  bool _exporting = false;
  bool _restoring = false;

  /// A sync walks the whole database too, so it joins the same queue.
  bool _syncing = false;

  bool get _busyWithData => _exporting || _restoring || _syncing;

  // Server sync, all read in _load().
  Uri? _serverUrl;
  String? _syncUser;
  String _deviceLabel = '';
  DateTime? _lastPushed;
  String? _syncStatus;
  bool _autoAfterScan = false;
  bool _auto = true;
  int _autoMinutes = kDefaultAutoSyncMinutes;

  /// The release a check on this screen turned up, kept so the Install button
  /// survives dismissing the dialog.
  AppRelease? _available;

  /// The outcome of the last manual check, in one line. Null before anything
  /// has been asked for, and while an update is being offered instead.
  String? _status;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final info = await PackageInfo.fromPlatform();
    final auto = await UpdatePrefs.instance.autoCheckEnabled();
    final last = await UpdatePrefs.instance.lastChecked();

    const SyncPrefs sync = SyncPrefs.instance;
    final Uri? serverUrl = await sync.baseUrl();
    final String? syncUser = await sync.username();
    final String deviceLabel = await sync.deviceLabel();
    final DateTime? lastPushed = await sync.lastPushed();
    final String? lastResult = await sync.lastResult();
    final bool autoAfterScan = await sync.autoAfterScan();
    final bool autoSync = await sync.auto();
    final int autoMinutes = await sync.autoMinutes();

    if (!mounted) return;
    setState(() {
      _version = info.version;
      _build = info.buildNumber;
      _autoCheck = auto;
      _lastChecked = last;
      _serverUrl = serverUrl;
      _syncUser = syncUser;
      _deviceLabel = deviceLabel;
      _lastPushed = lastPushed;
      _syncStatus = lastResult;
      _autoAfterScan = autoAfterScan;
      _auto = autoSync;
      _autoMinutes = autoMinutes;
      _loading = false;
    });
  }

  Future<void> _setAutoCheck(bool value) async {
    // Optimistic: the switch is the only writer, so there is nothing to lose a
    // race against and no reason to make it lag a disk write.
    setState(() => _autoCheck = value);
    await UpdatePrefs.instance.setAutoCheckEnabled(value);
  }

  /// Asks for the server address.
  Future<void> _editServerUrl() async {
    final String? entered = await _askForText(
      title: 'Server address',
      hint: 'http://192.168.1.99:8099',
      initial: _serverUrl?.toString() ?? 'http://',
      keyboardType: TextInputType.url,
      validate: SyncPrefs.baseUrlProblem,
    );
    if (entered == null) return;

    await SyncPrefs.instance.setBaseUrl(entered);
    if (!mounted) return;
    setState(() => _serverUrl = Uri.tryParse(entered.trim()));
  }

  /// Asks what to call this device in the browser's picker.
  Future<void> _editDeviceLabel() async {
    final String? entered = await _askForText(
      title: 'Name for this device',
      hint: "Jay's Pixel",
      initial: _deviceLabel,
      validate: (String value) =>
          value.trim().isEmpty ? 'Give this device a name.' : null,
    );
    if (entered == null) return;

    await SyncPrefs.instance.setDeviceLabel(entered);
    if (!mounted) return;
    setState(() => _deviceLabel = entered.trim());
  }

  /// Checks the server is there, without needing an account.
  ///
  /// Separate from signing in so a wrong address and a wrong password are
  /// distinguishable, which is most of what makes setting this up bearable.
  Future<void> _testConnection() async {
    final Uri? base = _serverUrl;
    if (base == null) {
      _say('Add the server address first.');
      return;
    }
    setState(() => _syncing = true);
    try {
      final SyncOutcome result = await SyncClient.instance.testConnection(base);
      // Whatever this found is what the light should be showing, immediately —
      // testing the connection is the one action whose whole purpose is to
      // answer that question.
      unawaited(ConnectionMonitor.instance.check(force: true));
      if (!mounted) return;
      setState(() => _syncStatus =
          result.failed ? result.error : 'The server answered. Sign in next.');
      _say(result.failed ? result.error! : 'The server is there.');
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  /// Signs in, or out.
  Future<void> _signIn() async {
    final Uri? base = _serverUrl;
    if (base == null) {
      _say('Add the server address first.');
      return;
    }

    final (String, String)? credentials = await _askForCredentials();
    if (credentials == null) return;

    setState(() => _syncing = true);
    try {
      final SyncOutcome result = await SyncClient.instance.signIn(
        base: base,
        username: credentials.$1,
        password: credentials.$2,
      );
      if (!mounted) return;
      if (result.failed) {
        setState(() => _syncStatus = result.error);
        _say(result.error!);
        return;
      }
      final String? user = await SyncPrefs.instance.username();
      if (!mounted) return;
      setState(() {
        _syncUser = user;
        _syncStatus = _auto
            ? 'Signed in. Syncing now, and automatically from here on.'
            : 'Signed in. Tap Sync now to upload.';
      });
      _say('Signed in as $user.');
      // Signing in is the moment sync becomes possible, and the timer was armed
      // before there was a session for it to use. Not awaited: the first upload
      // is a whole ledger, and nothing on this screen should wait for it.
      if (_auto) unawaited(AutoSync.instance.resume());
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _signOut() async {
    setState(() => _syncing = true);
    try {
      await SyncClient.instance.signOut();
      if (!mounted) return;
      setState(() {
        _syncUser = null;
        _syncStatus = 'Signed out.';
      });
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  /// Drains the edit queue, applies it, and uploads the ledger.
  Future<void> _syncNow() async {
    if (_busyWithData) return;
    setState(() => _syncing = true);
    try {
      final SyncOutcome result = await SyncClient.instance.syncNow(
        // A sync can apply edits made in a browser, so the shell has to know the
        // ledger moved underneath it.
        onChanged: widget.onChanged,
      );
      // The light in the app bar is looking at the same server this just spoke
      // to, and a manual sync is the strongest evidence there is about it.
      ConnectionMonitor.instance.record(result);
      if (!mounted) return;
      final DateTime? pushed = await SyncPrefs.instance.lastPushed();
      if (!mounted) return;
      setState(() {
        _syncStatus = result.describe();
        _lastPushed = pushed;
        if (result.signedOut) _syncUser = null;
      });
      _say(result.describe());
    } finally {
      if (mounted) setState(() => _syncing = false);
    }
  }

  Future<void> _setAutoAfterScan(bool value) async {
    setState(() => _autoAfterScan = value);
    await SyncPrefs.instance.setAutoAfterScan(value);
  }

  /// Turns automatic syncing on or off, and makes it so immediately.
  ///
  /// [AutoSync.resume] rather than waiting for the next launch: a switch that
  /// takes effect later is a switch the user will flick twice trying to work out
  /// whether it did anything.
  Future<void> _setAuto(bool value) async {
    setState(() => _auto = value);
    await SyncPrefs.instance.setAuto(value);
    if (value) {
      await AutoSync.instance.resume();
    } else {
      AutoSync.instance.pause();
    }
  }

  /// Asks how often, from a short list rather than a number field.
  Future<void> _editAutoMinutes() async {
    final int? chosen = await showDialog<int>(
      context: context,
      builder: (BuildContext dialogContext) => SimpleDialog(
        title: const Text('Sync how often?'),
        children: <Widget>[
          for (final int minutes in kAutoSyncChoices)
            ListTile(
              // The tick marks the current choice without a radio group, which
              // in a dialog that closes on the first tap would only ever be
              // seen mid-dismissal.
              leading: Icon(
                minutes == _autoMinutes
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
              ),
              title: Text(describeSyncInterval(minutes)),
              onTap: () => Navigator.of(dialogContext).pop(minutes),
            ),
        ],
      ),
    );
    if (chosen == null) return;

    setState(() => _autoMinutes = chosen);
    await SyncPrefs.instance.setAutoMinutes(chosen);
    // The running timer is on the old interval until it is rebuilt.
    await AutoSync.instance.resume();
  }

  /// One text field in a dialog, validated before it closes.
  Future<String?> _askForText({
    required String title,
    required String hint,
    required String initial,
    required String? Function(String) validate,
    TextInputType? keyboardType,
  }) =>
      showDialog<String>(
        context: context,
        builder: (BuildContext dialogContext) => _TextPromptDialog(
          title: title,
          hint: hint,
          initial: initial,
          validate: validate,
          keyboardType: keyboardType,
        ),
      );

  /// Username and password together, since one without the other is no use.
  Future<(String, String)?> _askForCredentials() async {
    final (String, String)? result = await showDialog<(String, String)>(
      context: context,
      builder: (BuildContext dialogContext) =>
          _CredentialsDialog(username: _syncUser ?? ''),
    );
    if (result == null) return null;
    if (result.$1.trim().isEmpty || result.$2.isEmpty) {
      _say('Both a username and a password are needed.');
      return null;
    }
    return result;
  }

  void _say(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  /// Writes the whole database to a workbook and offers it to the share sheet,
  /// which is how it reaches Drive — and from Drive, Google Sheets.
  Future<void> _export() async {
    if (_busyWithData) return;
    setState(() => _exporting = true);
    try {
      final BackupData data = await AppDatabase.instance.exportAll();
      final File file =
          await writeBackup(data, backupFileName(DateTime.now()));
      if (!mounted) return;
      await SharePlus.instance.share(
        ShareParams(
          files: <XFile>[XFile(file.path, mimeType: kXlsxMimeType)],
          subject: 'TU Expense Tracker backup',
          text: '${data.meta['transactions']} transactions, exported '
              '${DateFormat('d MMM yyyy').format(DateTime.now())}.',
        ),
      );
    } catch (error) {
      _say('The export failed: $error');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  /// Reads a workbook back over the top of everything.
  ///
  /// Nothing is deleted until the file has been decoded, validated and
  /// confirmed, and a copy of what is about to be replaced has been written —
  /// so every way this can fail is a way that leaves the ledger alone.
  Future<void> _restore() async {
    if (_busyWithData) return;

    final PlatformFile? picked = await FilePicker.pickFile(
      dialogTitle: 'Choose a backup workbook',
      type: FileType.custom,
      allowedExtensions: const <String>['xlsx'],
    );
    if (picked == null || !mounted) return;

    setState(() => _restoring = true);
    try {
      final (BackupData? backup, String? unreadable) =
          await decodeBackupInBackground(await picked.readAsBytes());
      if (!mounted) return;
      if (backup == null) {
        await showBackupProblems(context, <String>[unreadable!]);
        return;
      }

      final List<String> problems = validateBackup(
        backup,
        appSchemaVersion: kSchemaVersion,
      );
      if (problems.isNotEmpty) {
        await showBackupProblems(context, problems);
        return;
      }

      // Read before asking, so the question can name what is about to go.
      final BackupData current = await AppDatabase.instance.exportAll();
      if (!mounted) return;
      final bool go = await confirmRestore(
        context,
        replacing: current.transactions.length,
        incoming: backup.transactions.length,
      );
      if (!go || !mounted) return;

      // The one irreversible action in the app, made reversible. Written before
      // the wipe rather than after, so a crash in between still leaves it.
      final File safety = await writeBackup(
        current,
        backupFileName(DateTime.now(), beforeRestore: true),
      );
      await AppDatabase.instance.replaceAll(backup);
      if (!mounted) return;

      await showDialog<void>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: const Text('Restored'),
          content: Text(
            '${backup.transactions.length} transactions, '
            '${backup.categories.length} categories and '
            '${backup.deleted.length} deleted rows are back.\n\n'
            'What was here before was saved as ${p.basename(safety.path)}.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Done'),
            ),
          ],
        ),
      );
    } catch (error) {
      _say('The restore failed: $error');
    } finally {
      if (mounted) setState(() => _restoring = false);
    }
  }

  /// The explicit check. Unlike the launch one this always reports back, so a
  /// press of the button is never met with silence.
  Future<void> _checkNow() async {
    setState(() {
      _checking = true;
      _status = null;
      _available = null;
    });

    final result = await UpdateService.instance.check();
    final last = await UpdatePrefs.instance.lastChecked();
    if (!mounted) return;

    setState(() {
      _checking = false;
      _lastChecked = last;
      _available = result.release;
      _status = result.failed
          ? result.error
          : result.hasUpdate
              ? null
              : 'Up to date.';
    });

    if (result.hasUpdate) await showUpdateDialog(context, result.release!);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final release = _available;

    return _loading
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            children: <Widget>[
              SettingsHeader('Categorization'),
                ListTile(
                  leading: const Icon(Icons.storefront_outlined),
                  title: const Text('Merchants & defaults'),
                  subtitle: const Text(
                    'What each merchant is categorised as by default',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const MerchantDefaultsScreen(),
                    ),
                  ),
                ),
                const Divider(height: 32),
                SettingsHeader('Cleanup'),
                ListTile(
                  leading: const Icon(Icons.merge_type),
                  title: const Text('Merge merchants'),
                  subtitle: const Text(
                    'Fold several spellings of one shop into a single name',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          const MergeNamesScreen(kind: NameKind.merchant),
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.credit_card),
                  title: const Text('Merge cards & accounts'),
                  subtitle: const Text(
                    'One account can arrive labelled differently by each alert',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          const MergeNamesScreen(kind: NameKind.card),
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.label_outline),
                  title: const Text('Categories'),
                  subtitle: const Text(
                    'Add one, or drop one you never use — its transactions '
                    'move, not go',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const CategoriesScreen(),
                    ),
                  ),
                ),
                const Divider(height: 32),
                SettingsHeader('Data'),
                ListTile(
                  leading: const Icon(Icons.table_view_outlined),
                  title: const Text('Export data'),
                  subtitle: const Text(
                    'A spreadsheet of everything — and the same file a '
                    'restore reads back',
                  ),
                  trailing: _exporting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : FilledButton.tonal(
                          onPressed: _busyWithData ? null : _export,
                          child: const Text('Export'),
                        ),
                ),
                ListTile(
                  leading: const Icon(Icons.settings_backup_restore),
                  title: const Text('Restore from backup'),
                  subtitle: const Text(
                    'Replaces everything in the app with an exported '
                    'workbook',
                  ),
                  trailing: _restoring
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : FilledButton.tonal(
                          onPressed: _busyWithData ? null : _restore,
                          child: const Text('Restore'),
                        ),
                ),
                const Divider(height: 32),
                SettingsHeader('Server sync'),
                ListTile(
                  leading: const Icon(Icons.dns_outlined),
                  title: const Text('Server address'),
                  subtitle: Text(_serverUrl?.toString() ?? 'Not set'),
                  onTap: _busyWithData ? null : _editServerUrl,
                ),
                ListTile(
                  leading: const Icon(Icons.smartphone_outlined),
                  title: const Text('Name for this device'),
                  // Shown in the browser's device picker, so it is worth being
                  // able to tell two phones apart.
                  subtitle: Text(_deviceLabel),
                  onTap: _busyWithData ? null : _editDeviceLabel,
                ),
                ListTile(
                  leading: Icon(_syncUser == null
                      ? Icons.person_outline
                      : Icons.verified_user_outlined),
                  title: Text(_syncUser == null ? 'Sign in' : 'Signed in'),
                  subtitle: Text(_syncUser ?? 'Not signed in'),
                  trailing: _syncUser == null
                      ? null
                      : TextButton(
                          onPressed: _busyWithData ? null : _signOut,
                          child: const Text('Sign out'),
                        ),
                  onTap: _busyWithData || _syncUser != null ? null : _signIn,
                ),
                ListTile(
                  leading: const Icon(Icons.network_check_outlined),
                  title: const Text('Test connection'),
                  subtitle: const Text(
                    'Checks the address without needing an account.',
                  ),
                  trailing: _syncing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : FilledButton.tonal(
                          onPressed: _busyWithData ? null : _testConnection,
                          child: const Text('Test'),
                        ),
                ),
                ListTile(
                  leading: const Icon(Icons.cloud_upload_outlined),
                  title: const Text('Sync now'),
                  subtitle: Text(
                    _syncStatus ??
                        (_lastPushed == null
                            ? 'Never synced'
                            : 'Last synced '
                                '${_checkedFormat.format(_lastPushed!)}'),
                  ),
                  trailing: _syncing
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : FilledButton.tonal(
                          onPressed: _busyWithData || _syncUser == null
                              ? null
                              : _syncNow,
                          child: const Text('Sync'),
                        ),
                ),
                SwitchListTile(
                  value: _auto,
                  onChanged: _syncUser == null ? null : _setAuto,
                  title: const Text('Sync automatically'),
                  subtitle: Text(
                    'While the app is open: on opening it, when you come back '
                    'to it, ${describeSyncInterval(_autoMinutes).toLowerCase()}, '
                    'and shortly after you change something. This is what '
                    'applies edits made in a browser.',
                  ),
                ),
                if (_auto)
                  ListTile(
                    leading: const Icon(Icons.schedule_outlined),
                    title: const Text('How often'),
                    subtitle: Text(describeSyncInterval(_autoMinutes)),
                    enabled: _syncUser != null,
                    onTap: _editAutoMinutes,
                  ),
                SwitchListTile(
                  value: _autoAfterScan,
                  onChanged: _syncUser == null ? null : _setAutoAfterScan,
                  title: const Text('Sync after each inbox scan'),
                  subtitle: const Text(
                    'Uploads as soon as a scan finds something, without waiting '
                    'for the next automatic sync. Off by default.',
                  ),
                ),
                const Divider(height: 32),
                SettingsHeader('Updates'),
                SwitchListTile(
                  value: _autoCheck,
                  onChanged: _setAutoCheck,
                  title: const Text('Check automatically'),
                  subtitle: const Text(
                    'On launch, at most once a week. Nothing is downloaded '
                    'without asking.',
                  ),
                ),
                ListTile(
                  title: const Text('Check for updates'),
                  subtitle: Text(
                    _status ??
                        (_lastChecked == null
                            ? 'Not checked yet'
                            : 'Last checked '
                                '${_checkedFormat.format(_lastChecked!)}'),
                  ),
                  trailing: _checking
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : FilledButton.tonal(
                          onPressed: _checkNow,
                          child: const Text('Check now'),
                        ),
                ),
                if (release != null)
                  ListTile(
                    leading: Icon(
                      Icons.system_update_alt,
                      color: theme.colorScheme.primary,
                    ),
                    title: Text('Version ${release.version} available'),
                    subtitle: const Text('Downloads, then Android installs it'),
                    trailing: FilledButton(
                      onPressed: () => showUpdateDialog(context, release),
                      child: const Text('Install'),
                    ),
                  ),
                const Divider(height: 32),
                SettingsHeader('About'),
                ListTile(
                  title: const Text('TU Expense Tracker'),
                  subtitle: const Text(
                    'Turns bank SMS alerts into a categorised expense ledger.',
                  ),
                ),
                ListTile(
                  title: const Text('Version'),
                  // The build number distinguishes two APKs that report the
                  // same version, which matters while diagnosing an install.
                  subtitle: Text('$_version (build $_build)'),
                ),
                ListTile(
                  title: const Text('Releases'),
                  subtitle: const Text('github.com/$kUpdateRepo'),
                ),
                const SizedBox(height: 24),
              ],
            );
  }
}

/// A single validated text field in a dialog.
///
/// Stateful so that it owns its controller. A controller created beside
/// `showDialog` and disposed once it awaits is disposed too early: showDialog
/// completes when the route *starts* closing, while the dialog is still being
/// built through its exit animation, which throws "A TextEditingController was
/// used after being disposed". A State's dispose runs when the route is gone.
class _TextPromptDialog extends StatefulWidget {
  const _TextPromptDialog({
    required this.title,
    required this.hint,
    required this.initial,
    required this.validate,
    this.keyboardType,
  });

  final String title;
  final String hint;
  final String initial;
  final String? Function(String) validate;
  final TextInputType? keyboardType;

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
    // Caret at the end rather than the whole field selected, so typing after a
    // port number does not wipe the address.
  )..selection = TextSelection.collapsed(offset: widget.initial.length);

  String? _problem;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit(String value) {
    final String? bad = widget.validate(value);
    if (bad == null) {
      Navigator.pop(context, value);
    } else {
      setState(() => _problem = bad);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        content: TextField(
          controller: _controller,
          autofocus: true,
          keyboardType: widget.keyboardType,
          decoration: InputDecoration(
            hintText: widget.hint,
            errorText: _problem,
            border: const OutlineInputBorder(),
          ),
          onSubmitted: _submit,
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => _submit(_controller.text),
            child: const Text('Save'),
          ),
        ],
      );
}

/// Username and password, asked for together.
class _CredentialsDialog extends StatefulWidget {
  const _CredentialsDialog({required this.username});

  final String username;

  @override
  State<_CredentialsDialog> createState() => _CredentialsDialogState();
}

class _CredentialsDialogState extends State<_CredentialsDialog> {
  late final TextEditingController _username =
      TextEditingController(text: widget.username);
  final TextEditingController _password = TextEditingController();
  bool _obscurePassword = true;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  void _submit() =>
      Navigator.pop(context, (_username.text, _password.text));

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Sign in to your server'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            TextField(
              controller: _username,
              autofocus: true,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'Username',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: _obscurePassword,
              decoration: InputDecoration(
                labelText: 'Password',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  tooltip:
                      _obscurePassword ? 'Show password' : 'Hide password',
                  onPressed: () =>
                      setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 8),
            const Text(
              'Signing in can take a few seconds: the server hashes your '
              'password deliberately slowly.',
              style: TextStyle(fontSize: 11),
            ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(onPressed: _submit, child: const Text('Sign in')),
        ],
      );
}
