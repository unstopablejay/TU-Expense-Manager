/// Syncing without being asked to.
///
/// [SyncClient] knows how to do one sync. This decides when, and it exists
/// because the browser is only half an editor without it: an edit made on a PC
/// is queued on the server and applied by the phone, so until the phone syncs,
/// "Queued. It will be applied the next time that phone syncs" is a promise
/// nobody keeps. Pressing a button in Settings is not a sync strategy.
///
/// Four moments, and between them they cover what a person would actually do by
/// hand:
///
///   * the app starts — the ledger on screen should be the current one
///   * the app comes back to the foreground — same reason, and it is the moment
///     someone walks back to their phone after editing on a PC
///   * every [SyncPrefs.autoMinutes] while it is open — for the phone sitting on
///     a desk beside the browser being edited
///   * shortly after a local change — so the browser sees the phone's edits as
///     quickly as the phone sees the browser's
///
/// **This is foreground only.** Nothing here runs while the app is closed:
/// Android will not run a Flutter isolate on a timer without a background
/// worker, and one of those brings a plugin, a foreground-service notification
/// on some OEM builds, and a battery-optimisation setting per manufacturer that
/// silently disables it. Sync when the app is open, and say so honestly in
/// Settings, rather than shipping something that works on one phone and not the
/// next.
///
/// Every path lands in [_run], which is the only place that decides whether a
/// sync may proceed. Two syncs at once would have both encoding the same ledger
/// and racing to upload it.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import 'connection_monitor.dart';
import 'sync_client.dart';
import 'sync_prefs.dart';

/// How long after a local change to push it.
///
/// Long enough that categorising a screenful of transactions is one upload
/// rather than fifteen, short enough that someone who tidies up their ledger and
/// puts the phone down sees it in the browser before they have opened it.
const Duration kAutoSyncSettle = Duration(seconds: 20);

/// The least time between two syncs that nobody asked for.
///
/// Coming back to the foreground triggers a sync, and on Android that can happen
/// several times in a few seconds — a permission dialog, the notification
/// shade, a share sheet all pause and resume the app. Without this, walking past
/// a notification would sync three times.
const Duration kAutoSyncMinGap = Duration(minutes: 1);

/// Runs syncs on its own, while the app is in the foreground.
class AutoSync with WidgetsBindingObserver {
  AutoSync({SyncClient? client, SyncPrefs? prefs, ConnectionMonitor? monitor})
      : _client = client ?? SyncClient.instance,
        _prefs = prefs ?? SyncPrefs.instance,
        _monitor = monitor ?? ConnectionMonitor.instance;

  static final AutoSync instance = AutoSync();

  final SyncClient _client;
  final SyncPrefs _prefs;
  final ConnectionMonitor _monitor;

  Timer? _interval;
  Timer? _settle;

  /// Set for the whole of a sync, so a timer that fires mid-upload does nothing
  /// rather than starting a second one.
  bool _busy = false;

  /// When the last automatic attempt started, successful or not. Failures count:
  /// retrying a dead VPN every second is worse than waiting a minute.
  DateTime? _lastAttempt;

  /// Told when a sync changed the ledger, so the shell can reload.
  VoidCallback? _onChanged;

  /// Whether a sync is in flight. For tests and for the Settings screen, which
  /// should not offer a manual sync on top of a running automatic one.
  bool get isBusy => _busy;

  /// Begins watching. Safe to call more than once.
  ///
  /// [onChanged] is called on the platform's own thread of control rather than
  /// from a user gesture, so it must be something that can cope with being
  /// invoked at any moment — reloading the shell's ledger, and nothing that
  /// pushes a route or shows a dialog.
  Future<void> start({required VoidCallback onChanged}) async {
    _onChanged = onChanged;
    WidgetsBinding.instance.addObserver(this);
    await resume();
  }

  /// Stops everything and forgets the callback.
  void stop() {
    WidgetsBinding.instance.removeObserver(this);
    _interval?.cancel();
    _interval = null;
    _settle?.cancel();
    _settle = null;
    _onChanged = null;
  }

  /// Re-reads the settings and starts, restarts or stops the timer to match.
  ///
  /// Called on resume and whenever Settings changes something, so turning
  /// automatic sync on takes effect there and then rather than at the next
  /// launch.
  ///
  /// [quiet] asks for the sync to be skipped if one has just run — see
  /// [kAutoSyncMinGap]. The lifecycle passes true, because Android resumes an
  /// app several times in a row for reasons that have nothing to do with the
  /// user coming back to it. Someone who just changed the setting passes false,
  /// because a switch that appears to do nothing gets flicked twice.
  Future<void> resume({bool quiet = false}) async {
    _interval?.cancel();
    _interval = null;

    if (!await _prefs.auto()) return;

    final Duration every = Duration(minutes: await _prefs.autoMinutes());
    // The tick is not rate limited: the interval is its own rate limit, and the
    // shortest one on offer is five minutes.
    _interval = Timer.periodic(every, (Timer _) => unawaited(_run()));
    // Immediately as well as on the interval: the first tick of a fifteen-minute
    // timer is fifteen minutes away, and the moment the app opens is exactly
    // when its ledger is most likely to be behind.
    await _run(respectQuietPeriod: quiet);
  }

  /// Suspends the timer while the app is not in front of anybody.
  void pause() {
    _interval?.cancel();
    _interval = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(resume(quiet: true));
      case AppLifecycleState.inactive:
        // Not a background state — it is a notification shade, a call, a share
        // sheet. Tearing the timer down for it would mean rebuilding it seconds
        // later, and each rebuild costs a sync.
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        pause();
    }
  }

  /// The ledger changed on this device; push it once the dust settles.
  ///
  /// Debounced rather than immediate, because the changes that matter arrive in
  /// runs: an inbox scan inserting forty rows, or someone working down a list
  /// assigning categories. Each call restarts the clock, so a run of edits is
  /// one upload at the end of it.
  void nudge() {
    _settle?.cancel();
    _settle = Timer(kAutoSyncSettle, () => unawaited(_run()));
  }

  /// One automatic sync, if the settings and the moment allow it.
  ///
  /// Returns what the sync did, or null when it declined to run — which is the
  /// ordinary case and not a failure.
  Future<SyncOutcome?> _run({bool respectQuietPeriod = false}) async {
    if (_busy) return null;
    if (!await _prefs.auto()) return null;
    // Inert until there is a server and a session. This is what keeps a user who
    // has never set up sync from ever seeing a network call, let alone an error
    // about one.
    if (!await _prefs.isConfigured) return null;

    final DateTime now = DateTime.now();
    if (respectQuietPeriod &&
        _lastAttempt != null &&
        now.difference(_lastAttempt!) < kAutoSyncMinGap) {
      return null;
    }

    _busy = true;
    _lastAttempt = now;
    try {
      // force: false — the ledger is only uploaded if it has actually moved.
      // Nobody pressed anything, so there is no reason to write a new snapshot
      // on the server saying the same thing as the last one.
      final SyncOutcome outcome =
          await _client.syncNow(onChanged: _onChanged, force: false);
      // A sync that just spoke to the server is the best evidence the light can
      // have, and it costs nothing to hand it over.
      _monitor.record(outcome);
      return outcome;
    } on Object {
      // SyncClient returns its failures rather than throwing, so this is for
      // whatever it did not anticipate. An automatic sync is silent either way:
      // it runs without anyone asking, and Settings shows the last result for
      // anyone who wants to know.
      return null;
    } finally {
      _busy = false;
    }
  }

  /// Runs a sync now, ignoring the quiet period. For tests, and for anything
  /// that legitimately knows better than the timer.
  @visibleForTesting
  Future<SyncOutcome?> runNow() => _run();
}
