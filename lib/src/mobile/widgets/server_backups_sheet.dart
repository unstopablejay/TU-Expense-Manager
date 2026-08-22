/// Displays and manages rolling server backups on the Docker/ZimaOS backend.
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/backup_data.dart';
import '../../core/models.dart';
import '../../ui_shared/loading_dialog.dart';
import '../backup_files.dart';
import '../database.dart';
import '../sync_client.dart';

/// Shows the server backups bottom sheet.
Future<void> showServerBackupsSheet(
  BuildContext context, {
  SyncClient? client,
  AppDatabase? database,
  VoidCallback? onChanged,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (BuildContext sheetContext) => _ServerBackupsSheet(
        client: client,
        database: database,
        onChanged: onChanged,
      ),
    );

class _ServerBackupsSheet extends StatefulWidget {
  const _ServerBackupsSheet({this.client, this.database, this.onChanged});

  final SyncClient? client;
  final AppDatabase? database;
  final VoidCallback? onChanged;

  @override
  State<_ServerBackupsSheet> createState() => _ServerBackupsSheetState();
}

class _ServerBackupsSheetState extends State<_ServerBackupsSheet> {
  final DateFormat _dateFormat = DateFormat('d MMM yyyy, h:mm a');

  SyncClient get _client => widget.client ?? SyncClient.instance;
  AppDatabase get _db => widget.database ?? AppDatabase.instance;

  bool _loading = true;
  String? _error;
  List<ServerBackupItem> _backups = <ServerBackupItem>[];
  ServerBackupSchedule? _schedule;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    final result = await _client.fetchServerBackups();
    if (!mounted) return;

    setState(() {
      _loading = false;
      _backups = result.backups;
      _schedule = result.schedule;
      _error = result.error;
    });
  }

  Future<void> _backupNow() async {
    final (ServerBackupItem? backup, String? error) =
        await withLoadingModal<(ServerBackupItem?, String?)>(
      context: context,
      message: 'Creating backup…',
      subtitle: 'Saving server state snapshot…',
      task: () async {
        final res = await _client.createServerBackup(
          note: 'Manual snapshot from mobile settings',
        );
        return (res.backup, res.error);
      },
    );

    if (!mounted) return;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error)),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Server backup created successfully.')),
    );
    await _load();
  }

  Future<void> _restore(ServerBackupItem item) async {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    BackupData current;
    try {
      current = await _db.exportAll();
    } catch (_) {
      current = BackupData.empty();
    }
    final int currentTxns = current.transactions.length;

    if (!mounted) return;

    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Restore Server Backup?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'This restores the server and this phone to the snapshot created at '
              '${_dateFormat.format(item.at.toLocal())} '
              '(${item.transactionsCount} transactions).',
            ),
            const SizedBox(height: 12),
            if (currentTxns > 0)
              Text(
                'Safety Shield: A local safety backup of your $currentTxns '
                'transactions will be saved on this device before restoring, '
                'so no data is lost.',
                style: TextStyle(
                  color: scheme.primary,
                  fontWeight: FontWeight.w500,
                ),
              ),
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: scheme.error,
              foregroundColor: scheme.onError,
            ),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Restore Snapshot'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    File? localSafety;
    final (bool ok, String? err) =
        await withLoadingModal<(bool, String?)>(
      context: context,
      message: 'Restoring snapshot…',
      subtitle: 'Saving safety copy and applying data…',
      task: () async {
        // 1. Local safety copy if phone has data
        if (currentTxns > 0) {
          localSafety = await writeBackup(
            current,
            backupFileName(DateTime.now(), beforeRestore: true),
          );
        }

        // 2. Server restore
        final res = await _client.restoreServerBackup(item.id);
        if (!res.ok) return (false, res.error);

        // 3. Pull restored snapshot and apply locally
        final pull = await _client.fetchRestoredSnapshotData();
        if (pull.data == null) return (false, pull.error);

        await AppDatabase.instance.replaceAll(pull.data!);
        widget.onChanged?.call();
        return (true, null);
      },
    );

    if (!mounted) return;

    if (!ok) {
      await showDialog<void>(
        context: context,
        builder: (BuildContext dContext) => AlertDialog(
          title: const Text('Restore Failed'),
          content: Text(err ?? 'Could not restore backup.'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(dContext),
              child: const Text('Close'),
            ),
          ],
        ),
      );
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (BuildContext dContext) => AlertDialog(
        title: const Text('Restore Complete'),
        content: Text(
          'Successfully restored snapshot from '
          '${_dateFormat.format(item.at.toLocal())}.\n\n'
          'Both your server and this device are in sync.'
          '${localSafety != null ? '\n\nA safety copy of previous data was saved to:\n${localSafety!.path}' : ''}',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dContext),
            child: const Text('Done'),
          ),
        ],
      ),
    );

    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final ServerBackupSchedule? schedule = _schedule;

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (BuildContext ctx, ScrollController scrollController) => Column(
        children: <Widget>[
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
            child: Row(
              children: <Widget>[
                const Icon(Icons.backup_outlined),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'Server Rolling Backups',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                IconButton(
                  tooltip: 'Close',
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.pop(context),
                ),
              ],
            ),
          ),
          const Divider(height: 1),

          // Schedule Summary Card
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Card(
              elevation: 0,
              color: scheme.surfaceContainerHighest,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Icon(
                          schedule?.enabled == true
                              ? Icons.schedule
                              : Icons.schedule_outlined,
                          size: 18,
                          color: scheme.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            schedule?.enabled == true
                                ? 'Daily Schedule: ${schedule!.timeFormatted}'
                                : 'Automated Backups: Disabled',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ),
                        FilledButton.tonalIcon(
                          onPressed: _loading ? null : _backupNow,
                          icon: const Icon(Icons.add, size: 18),
                          label: const Text('Backup now'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Retention: ${schedule?.keep ?? 10} rolling snapshots (FIFO rotation).\n'
                      'Location: ${schedule?.path ?? '/data/backups'}',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Backups List
          Expanded(
            child: _buildBody(scrollController),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ScrollController scrollController) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const Icon(Icons.cloud_off, size: 48, color: Colors.grey),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.tonal(
                onPressed: _load,
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_backups.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              const Icon(Icons.inventory_2_outlined, size: 48, color: Colors.grey),
              const SizedBox(height: 12),
              const Text(
                'No server snapshots yet.\nTap "Backup now" to create one.',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: _backups.length,
      separatorBuilder: (BuildContext context, int index) => const Divider(height: 1),
      itemBuilder: (BuildContext context, int index) {
        final ServerBackupItem item = _backups[index];
        final (String badgeText, Color badgeColor) = _badgeFor(item);

        return ListTile(
          contentPadding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          leading: CircleAvatar(
            backgroundColor: badgeColor.withValues(alpha: 0.15),
            child: Icon(
              item.isSafetyBackup
                  ? Icons.shield_outlined
                  : (item.isAuto ? Icons.schedule : Icons.touch_app),
              color: badgeColor,
              size: 20,
            ),
          ),
          title: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  _dateFormat.format(item.at.toLocal()),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: badgeColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  badgeText,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    color: badgeColor,
                  ),
                ),
              ),
            ],
          ),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const SizedBox(height: 2),
              Text(
                '${item.transactionsCount} transactions · '
                '${(item.bytes / 1024).toStringAsFixed(1)} KB',
              ),
              if (item.note != null && item.note!.isNotEmpty)
                Text(
                  item.note!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
            ],
          ),
          trailing: FilledButton.tonal(
            onPressed: () => _restore(item),
            child: const Text('Restore'),
          ),
        );
      },
    );
  }

  (String, Color) _badgeFor(ServerBackupItem item) {
    if (item.isSafetyBackup) return ('Safety Copy', Colors.amber.shade800);
    if (item.isAuto) return ('Daily Auto', Colors.blue.shade700);
    return ('Manual', Colors.teal.shade700);
  }
}
