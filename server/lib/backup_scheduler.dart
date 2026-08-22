/// Schedules daily automated server backups.
///
/// Runs inside the server process and fires at the configured local hour & minute
/// (defaulting to 21:00 / 9:00 PM).
library;

import 'dart:async';
import 'dart:io';

import 'backup_manager.dart';

class BackupScheduler {
  BackupScheduler({
    required this.manager,
    required this.hour,
    required this.minute,
    this.enabled = true,
    this.logger,
  });

  final BackupManager manager;
  final int hour;
  final int minute;
  final bool enabled;
  final void Function(String message)? logger;

  Timer? _timer;
  DateTime? _nextRun;

  DateTime? get nextRun => _nextRun;
  bool get isRunning => _timer != null && _timer!.isActive;

  /// Starts the scheduler.
  void start() {
    cancel();
    if (!enabled) {
      _log('Automated daily backups are disabled by configuration.');
      return;
    }

    final DateTime now = DateTime.now();
    final DateTime target = calculateNextRun(now: now, targetHour: hour, targetMinute: minute);
    _nextRun = target;
    final Duration delay = target.difference(now);

    _log('Automated daily backup scheduled for ${target.toLocal().toIso8601String()} '
        '(in ${delay.inHours}h ${delay.inMinutes % 60}m).');

    _timer = Timer(delay, _onTrigger);
  }

  /// Cancels any pending scheduled timer.
  void cancel() {
    _timer?.cancel();
    _timer = null;
    _nextRun = null;
  }

  Future<void> _onTrigger() async {
    _log('Executing automated daily rolling backup...');
    try {
      final BackupItem item = await manager.createBackup(
        type: 'auto',
        note: 'Scheduled daily backup at ${DateTime.now().toLocal().toIso8601String()}',
      );
      _log('Automated backup created: ${item.id} (${item.bytes} bytes, '
          '${item.counts['transactions'] ?? 0} transactions).');
    } catch (error, stack) {
      _log('Automated daily backup failed: $error\n$stack');
    } finally {
      // Schedule next run for tomorrow
      start();
    }
  }

  void _log(String message) {
    if (logger != null) {
      logger!(message);
    } else {
      stdout.writeln('[BackupScheduler] $message');
    }
  }

  /// Calculates the next occurrence of [targetHour]:[targetMinute] after [now].
  static DateTime calculateNextRun({
    required DateTime now,
    required int targetHour,
    required int targetMinute,
  }) {
    DateTime target = DateTime(
      now.year,
      now.month,
      now.day,
      targetHour,
      targetMinute,
      0,
    );
    if (!target.isAfter(now)) {
      target = target.add(const Duration(days: 1));
    }
    return target;
  }
}
