// The rule behind the connection light.
//
// Deliberately about the *rule* rather than about either screen. The phone shows
// this and the browser shows this, and if the two ever disagreed about what
// green means the indicator would be worse than nothing — so the arithmetic
// lives in one function and this pins it.

import 'package:flutter_test/flutter_test.dart';
import 'package:tu_expense_tracker/src/core/link_state.dart';

final DateTime now = DateTime.utc(2026, 8, 19, 12);

LinkState stateAfter(Duration quiet, {int? syncMinutes}) => deviceLinkState(
      lastSeen: now.subtract(quiet),
      syncMinutes: syncMinutes,
      now: now,
    );

void main() {
  group('a device that syncs every 15 minutes', () {
    test('is connected while it keeps to that', () {
      expect(stateAfter(Duration.zero, syncMinutes: 15), LinkState.connected);
      expect(
        stateAfter(const Duration(minutes: 14), syncMinutes: 15),
        LinkState.connected,
      );
    });

    test('survives missing one sync, which is the point of doubling it', () {
      // A phone in a lift, a VPN reconnecting, a laptop lid. A light that went
      // red at the first missed sync would be red often enough to be ignored,
      // and an indicator nobody believes is worse than no indicator.
      expect(
        stateAfter(const Duration(minutes: 25), syncMinutes: 15),
        LinkState.connected,
      );
    });

    test('is disconnected once it has missed two', () {
      expect(
        stateAfter(const Duration(minutes: 31), syncMinutes: 15),
        LinkState.disconnected,
      );
      expect(
        stateAfter(const Duration(hours: 6), syncMinutes: 15),
        LinkState.disconnected,
      );
    });
  });

  group('a device that syncs hourly', () {
    test('is not called disconnected for being slow', () {
      // The whole reason the interval travels with the device. Forty minutes of
      // silence is a fault at fifteen-minute syncing and unremarkable at hourly.
      expect(
        stateAfter(const Duration(minutes: 40), syncMinutes: 60),
        LinkState.connected,
      );
      expect(
        stateAfter(const Duration(minutes: 40), syncMinutes: 15),
        LinkState.disconnected,
      );
    });

    test('is still disconnected eventually', () {
      expect(
        stateAfter(const Duration(hours: 3), syncMinutes: 60),
        LinkState.disconnected,
      );
    });
  });

  group('a device that has not said how often it syncs', () {
    test('is judged by the app default', () {
      // An older build. Assuming the default is the only assumption available,
      // and it is the one almost every such device is running.
      expect(
        stateAfter(const Duration(minutes: 20)),
        LinkState.connected,
      );
      expect(
        stateAfter(const Duration(minutes: 45)),
        LinkState.disconnected,
      );
    });
  });

  group('edges', () {
    test('a device that has never reported is unknown, not disconnected', () {
      // Nothing is broken — there has simply never been a link. Red here would
      // send somebody looking for a fault that does not exist.
      expect(
        deviceLinkState(lastSeen: null, syncMinutes: 15, now: now),
        LinkState.unknown,
      );
    });

    test('a very short interval still gets a floor', () {
      // Two minutes of allowance would have the light flickering on ordinary
      // jitter, which is not information.
      expect(quietAllowance(1), const Duration(minutes: kMinQuietMinutes));
      expect(quietAllowance(2), const Duration(minutes: kMinQuietMinutes));
      expect(quietAllowance(5), const Duration(minutes: 10));
    });

    test('a clock that has run backwards reads as connected, not as quiet', () {
      // A phone whose time is ahead of the server's reports a last_seen in the
      // future. Nothing is wrong with the link, and this is not the place to
      // start diagnosing clocks.
      expect(
        deviceLinkState(
          lastSeen: now.add(const Duration(minutes: 5)),
          syncMinutes: 15,
          now: now,
        ),
        LinkState.connected,
      );
    });
  });
}
