// The phone's half of the connection light.
//
// VM only: the monitor reaches [SyncClient], which reaches dart:io.
@TestOn('vm')
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tu_expense_tracker/main.dart';

/// A [SyncClient] that answers however a test wants, without a socket.
class StubSync extends SyncClient {
  StubSync({this.reachable = true});

  bool reachable;
  int checks = 0;

  @override
  Future<SyncOutcome> testConnection(Uri base) async {
    checks++;
    return reachable
        ? const SyncOutcome.ok(transactions: 0)
        : const SyncOutcome.failed('Could not reach the server.');
  }
}

void signedIn() {
  SharedPreferences.setMockInitialValues(<String, Object>{
    'sync.base_url': 'http://192.168.1.99:8099',
    'sync.token': 'a-session',
    'sync.username': 'jay',
    'sync.device_id': 'abcdefabcdefabcd',
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('what the light says', () {
    testWidgets('green once the server answers', (WidgetTester tester) async {
      signedIn();
      final StubSync sync = StubSync();
      final ConnectionMonitor monitor = ConnectionMonitor(client: sync);

      await monitor.start();
      await tester.pump();

      expect(monitor.status.value.state, LinkState.connected);
      // The tooltip names the server, so "why is it green" and "which one" are
      // the same question answered once.
      expect(monitor.status.value.detail, contains('192.168.1.99:8099'));
      monitor.stop();
    });

    testWidgets('red when it does not', (WidgetTester tester) async {
      signedIn();
      final ConnectionMonitor monitor =
          ConnectionMonitor(client: StubSync(reachable: false));

      await monitor.start();
      await tester.pump();

      expect(monitor.status.value.state, LinkState.disconnected);
      expect(monitor.status.value.detail, 'Could not reach the server.');
      monitor.stop();
    });

    testWidgets('grey — not red — when no server is set up',
        (WidgetTester tester) async {
      // Somebody who has never opened the sync settings has nothing wrong with
      // their setup, and a red light would say they did.
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final StubSync sync = StubSync();
      final ConnectionMonitor monitor = ConnectionMonitor(client: sync);

      await monitor.start();
      await tester.pump();

      expect(monitor.status.value.state, LinkState.unknown);
      expect(sync.checks, 0, reason: 'nothing to reach, so nothing was asked');
      monitor.stop();
    });

    testWidgets('grey when the session has expired, since that is not the '
        'network', (WidgetTester tester) async {
      signedIn();
      final ConnectionMonitor monitor = ConnectionMonitor(client: StubSync());

      monitor.record(const SyncOutcome.failed(
        'That session has expired. Sign in again.',
        signedOut: true,
      ));

      expect(monitor.status.value.state, LinkState.unknown);
    });
  });

  group('how it keeps current', () {
    testWidgets('asks again on its own schedule', (WidgetTester tester) async {
      signedIn();
      final StubSync sync = StubSync();
      // The fake clock moves with the pumped one. A widget test drives timers
      // through fake async but leaves DateTime.now alone, so without this the
      // monitor would think no time had passed and skip every tick as fresh.
      DateTime clock = DateTime.utc(2026, 8, 19, 12);
      final ConnectionMonitor monitor =
          ConnectionMonitor(client: sync, clock: () => clock);

      await monitor.start();
      await tester.pump();
      expect(sync.checks, 1);

      clock = clock.add(kConnectionCheckInterval);
      await tester.pump(kConnectionCheckInterval);
      await tester.pump();
      expect(sync.checks, 2);

      clock = clock.add(kConnectionCheckInterval);
      await tester.pump(kConnectionCheckInterval);
      await tester.pump();
      expect(sync.checks, 3);

      monitor.stop();
    });

    testWidgets('a sync that just succeeded answers the question, so no ping',
        (WidgetTester tester) async {
      signedIn();
      final StubSync sync = StubSync();
      final ConnectionMonitor monitor = ConnectionMonitor(client: sync);

      await monitor.start();
      await tester.pump();
      expect(sync.checks, 1);

      monitor.record(const SyncOutcome.ok(transactions: 40));
      await monitor.check();

      expect(sync.checks, 1, reason: 'the sync had already answered it');
      expect(monitor.status.value.state, LinkState.connected);
      monitor.stop();
    });

    testWidgets('a failed sync turns it red without waiting for the ping',
        (WidgetTester tester) async {
      signedIn();
      final ConnectionMonitor monitor = ConnectionMonitor(client: StubSync());

      await monitor.start();
      await tester.pump();
      expect(monitor.status.value.state, LinkState.connected);

      monitor.record(const SyncOutcome.failed(
        'Could not reach the server. Check the address, and the VPN if you '
        'are away from home.',
      ));

      expect(monitor.status.value.state, LinkState.disconnected);
      expect(monitor.status.value.detail, contains('VPN'));
      monitor.stop();
    });

    testWidgets('stops asking once stopped', (WidgetTester tester) async {
      signedIn();
      final StubSync sync = StubSync();
      final ConnectionMonitor monitor = ConnectionMonitor(client: sync);

      await monitor.start();
      await tester.pump();
      monitor.stop();

      await tester.pump(const Duration(hours: 1));
      await tester.pump();

      expect(sync.checks, 1);
    });
  });

  group('the dot itself', () {
    Future<void> pumpDot(WidgetTester tester, LinkState state) =>
        tester.pumpWidget(MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              actions: <Widget>[
                ConnectionDot(state: state, tooltip: 'why'),
              ],
            ),
          ),
        ));

    BoxDecoration decorationIn(WidgetTester tester) =>
        tester.widget<Container>(find.byType(Container)).decoration!
            as BoxDecoration;

    testWidgets('is filled when connected and hollow when not',
        (WidgetTester tester) async {
      // The shape carries the meaning as well as the colour: roughly one man in
      // twelve cannot tell this green from this red.
      await pumpDot(tester, LinkState.connected);
      expect(decorationIn(tester).color, isNot(Colors.transparent));

      await pumpDot(tester, LinkState.disconnected);
      expect(decorationIn(tester).color, Colors.transparent);
    });

    testWidgets('says which it is to a screen reader',
        (WidgetTester tester) async {
      final SemanticsHandle handle = tester.ensureSemantics();

      await pumpDot(tester, LinkState.disconnected);
      expect(
        find.bySemanticsLabel(RegExp('Not connected')),
        findsOneWidget,
      );

      await pumpDot(tester, LinkState.connected);
      expect(find.bySemanticsLabel(RegExp('^Connected')), findsOneWidget);

      handle.dispose();
    });
  });
}
