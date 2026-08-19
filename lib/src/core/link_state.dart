/// Whether the phone and the server are in touch, as one small piece of state.
///
/// Both ends show this and they mean the same thing by it, which is why the rule
/// lives here rather than twice: the phone knows because it just spoke to the
/// server, and the browser knows because the server records when each device
/// last reported. Two different sources of truth for one indicator would sooner
/// or later disagree in front of the user.
library;

/// What the indicator says.
enum LinkState {
  /// Reachable, and — in the browser — the phone has reported recently enough.
  connected,

  /// Was expected to be reachable and is not, or the phone has gone quiet for
  /// longer than its own sync interval can explain.
  disconnected,

  /// Nothing to say. No server configured, not signed in, or nothing has been
  /// checked yet. Deliberately not [disconnected]: a red light for a feature
  /// somebody has not set up is a bug report waiting to be filed.
  unknown,
}

/// The light, and the sentence behind it.
///
/// Shared for the same reason [LinkState] is: the phone builds one of these from
/// what its last request did, the browser builds one from what the server says
/// about a device, and both hand it to the same widget.
class LinkStatus {
  const LinkStatus(this.state, this.detail);

  final LinkState state;

  /// What the tooltip says. The dot is the summary; this is the answer to "why
  /// is it red", which otherwise costs a trip to Settings.
  final String detail;
}

/// How long a device may stay quiet before it reads as disconnected.
///
/// Twice its own sync interval, so missing a single sync — a phone in a lift, a
/// VPN reconnecting — does not turn the light red. The floor covers a device
/// that reports a very short interval, and the default covers one whose build
/// is too old to report one at all.
Duration quietAllowance(int? syncMinutes) {
  final int minutes = (syncMinutes ?? kAssumedSyncMinutes) * 2;
  return Duration(minutes: minutes < kMinQuietMinutes ? kMinQuietMinutes : minutes);
}

/// What to assume for a device that has not said how often it syncs.
///
/// The app's own default. A device running a build from before the interval was
/// reported is almost certainly on it.
const int kAssumedSyncMinutes = 15;

/// The shortest window worth judging a device by.
const int kMinQuietMinutes = 5;

/// Whether a device that last reported at [lastSeen] counts as connected.
///
/// [syncMinutes] is what that device says its interval is, or null if it has not
/// said. A device that has never reported at all is [LinkState.unknown] rather
/// than disconnected — it is not that the link is broken, it is that there has
/// never been one.
LinkState deviceLinkState({
  required DateTime? lastSeen,
  required int? syncMinutes,
  required DateTime now,
}) {
  if (lastSeen == null) return LinkState.unknown;
  return now.difference(lastSeen) <= quietAllowance(syncMinutes)
      ? LinkState.connected
      : LinkState.disconnected;
}
