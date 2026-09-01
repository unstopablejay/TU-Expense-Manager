/// Whether the phone can reach its server, kept current enough to show a light.
///
/// Two sources, and it needs both. Every sync reports what happened, which is
/// free and authoritative — a sync that just succeeded is proof of a working
/// link. But syncs are a quarter of an hour apart, and a light that is fifteen
/// minutes out of date is not a light. So between them this pings `/api/health`,
/// which is about eighty bytes and needs no session.
///
/// Foreground only, like [AutoSync], and for the same reason: there is nobody
/// looking at an indicator on a screen that is off.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../core/link_state.dart';
import 'sync_client.dart';
import 'sync_prefs.dart';

/// How often to ask, when nothing else has answered the question.
///
/// Half a minute is what makes it feel live without being a poll worth
/// noticing: the request is smaller than the TCP handshake that carries it.
const Duration kConnectionCheckInterval = Duration(seconds: 30);

/// How recently something must have proved the link for a ping to be skipped.
///
/// A sync that finished a moment ago has already answered, and asking again
/// immediately would be asking the same question twice.
const Duration kConnectionFreshFor = Duration(seconds: 20);

/// What the light says before anything has been set up.
const LinkStatus kNotConfigured =
    LinkStatus(LinkState.unknown, 'Server sync is not set up.');

/// Watches the link and publishes it.
class ConnectionMonitor with WidgetsBindingObserver {
  ConnectionMonitor({
    SyncClient? client,
    SyncPrefs? prefs,
    DateTime Function()? clock,
  })  : _client = client ?? SyncClient.instance,
        _prefs = prefs ?? SyncPrefs.instance,
        _clock = clock ?? DateTime.now;

  static final ConnectionMonitor instance = ConnectionMonitor();

  final SyncClient _client;
  final SyncPrefs _prefs;

  /// The clock, injectable because this class is mostly a statement about time.
  ///
  /// A widget test drives `Timer` through a fake clock but leaves `DateTime.now`
  /// alone, so without this seam the freshness check below would see no time
  /// pass at all and the timer could never be tested.
  final DateTime Function() _clock;

  /// What the app bar listens to.
  final ValueNotifier<LinkStatus> status =
      ValueNotifier<LinkStatus>(kNotConfigured);

  Timer? _timer;
  bool _checking = false;

  /// When the state last came from something that actually reached the server.
  DateTime? _answeredAt;

  Future<void> start() async {
    WidgetsBinding.instance.addObserver(this);
    _timer?.cancel();
    _timer = Timer.periodic(
      kConnectionCheckInterval,
      (Timer _) => unawaited(check()),
    );
    await check();
  }

  void stop() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _timer = null;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        // Coming back is exactly when the answer is most likely to be stale —
        // the phone may have changed network entirely since it was last asked.
        unawaited(check(force: true));
      case AppLifecycleState.inactive:
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
      case AppLifecycleState.hidden:
        _timer?.cancel();
        _timer = null;
    }
  }

  /// Asks the server whether it is there, unless something just did.
  Future<void> check({bool force = false}) async {
    if (_checking) return;

    final Uri? base = await _prefs.baseUrl();
    if (base == null || !await _prefs.isConfigured) {
      // Not disconnected — not set up. The difference matters: one is a fault to
      // investigate and the other is a feature nobody switched on.
      _publish(kNotConfigured, answered: false);
      return;
    }

    if (!force && _answeredAt != null) {
      if (_clock().difference(_answeredAt!) < kConnectionFreshFor) return;
    }

    _checking = true;
    try {
      final SyncOutcome result = await _client.testConnection(base);
      _publish(
        result.failed
            ? LinkStatus(LinkState.disconnected, result.error!)
            : LinkStatus(
                LinkState.connected,
                // The authority as typed — host and port — so the tooltip names
                // the server the user configured rather than a normalised
                // spelling of it they would have to recognise.
                'Connected to ${base.authority}'
                '${result.serverVersion != null ? ' (server v${result.serverVersion})' : ''}.',
              ),
        answered: true,
      );
    } on Object {
      // testConnection returns its failures rather than throwing, so this is for
      // whatever it did not anticipate. An indicator must never be the thing
      // that takes the app down.
      _publish(
        const LinkStatus(LinkState.disconnected, 'Could not reach the server.'),
        answered: true,
      );
    } finally {
      _checking = false;
    }
  }

  /// Records what a sync just proved, so the light is right without a ping.
  ///
  /// A sync talks to the server for real — with a session, carrying a ledger —
  /// so its verdict outranks a health check and is taken as the answer.
  void record(SyncOutcome outcome) {
    if (outcome.signedOut) {
      _publish(
        const LinkStatus(
          LinkState.unknown,
          'That session has expired. Sign in again.',
        ),
        answered: false,
      );
      return;
    }
    _publish(
      outcome.failed
          ? LinkStatus(LinkState.disconnected, outcome.error!)
          : LinkStatus(LinkState.connected, 'Synced just now.'),
      answered: true,
    );
  }

  void _publish(LinkStatus next, {required bool answered}) {
    if (answered) _answeredAt = _clock();
    if (status.value.state == next.state &&
        status.value.detail == next.detail) {
      return;
    }
    status.value = next;
  }
}
