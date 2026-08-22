import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tu_expense_tracker/src/ui_shared/loading_dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AnimatedCoin', () {
    testWidgets('renders currency symbol and dimensions',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: AnimatedCoin(symbol: '₹', size: 64),
            ),
          ),
        ),
      );

      expect(find.text('₹'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('₹'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1000));
      expect(find.text('₹'), findsOneWidget);
    });
  });

  group('CoinProgressBar', () {
    testWidgets('renders without overflow', (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: Center(
              child: CoinProgressBar(height: 10, width: 220),
            ),
          ),
        ),
      );

      expect(find.byType(CoinProgressBar), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 800));
    });
  });

  group('LoadingModal', () {
    testWidgets('displays message, subtitle, coin, and progress bar',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LoadingModal(
              message: 'Importing SMS transactions…',
              subtitle: 'Scanning your inbox for bank alerts…',
              symbol: '₹',
            ),
          ),
        ),
      );

      expect(find.text('Importing SMS transactions…'), findsOneWidget);
      expect(find.text('Scanning your inbox for bank alerts…'), findsOneWidget);
      expect(find.byType(AnimatedCoin), findsOneWidget);
      expect(find.byType(CoinProgressBar), findsOneWidget);
    });

    testWidgets('renders correctly without subtitle',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LoadingModal(
              message: 'Syncing…',
            ),
          ),
        ),
      );

      expect(find.text('Syncing…'), findsOneWidget);
      expect(find.byType(AnimatedCoin), findsOneWidget);
    });
  });

  group('LoadingOverlay', () {
    testWidgets('renders child alone when loading is false',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LoadingOverlay(
              loading: false,
              child: Text('Main Content'),
            ),
          ),
        ),
      );

      expect(find.text('Main Content'), findsOneWidget);
      expect(find.byType(AnimatedCoin), findsNothing);
    });

    testWidgets('renders scrim and card when loading is true',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: LoadingOverlay(
              loading: true,
              message: 'Processing batch…',
              child: Text('Main Content'),
            ),
          ),
        ),
      );

      expect(find.text('Main Content'), findsOneWidget);
      expect(find.text('Processing batch…'), findsOneWidget);
      expect(find.byType(AnimatedCoin), findsOneWidget);
      expect(find.byType(CoinProgressBar), findsOneWidget);
    });
  });

  group('withLoadingModal', () {
    testWidgets('shows modal during async task and dismisses upon completion',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => ElevatedButton(
                onPressed: () async {
                  await withLoadingModal<void>(
                    context: context,
                    message: 'Running operation…',
                    subtitle: 'Please wait a moment…',
                    task: () async {
                      await Future<void>.delayed(
                          const Duration(milliseconds: 200));
                    },
                  );
                },
                child: const Text('Start'),
              ),
            ),
          ),
        ),
      );

      expect(find.byType(LoadingModal), findsNothing);

      // Tap button to start task
      await tester.tap(find.text('Start'));
      await tester.pump(); // frame to trigger dialog

      expect(find.byType(LoadingModal), findsOneWidget);
      expect(find.text('Running operation…'), findsOneWidget);
      expect(find.text('Please wait a moment…'), findsOneWidget);

      // Advance clock past task duration
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(); // dialog pop animation

      expect(find.byType(LoadingModal), findsNothing);
    });

    testWidgets('dismisses cleanly even when task throws an exception',
        (WidgetTester tester) async {
      String? caughtError;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (BuildContext context) => ElevatedButton(
                onPressed: () async {
                  try {
                    await withLoadingModal<void>(
                      context: context,
                      message: 'Faulty operation…',
                      task: () async {
                        await Future<void>.delayed(
                            const Duration(milliseconds: 100));
                        throw Exception('Network failed');
                      },
                    );
                  } catch (e) {
                    caughtError = e.toString();
                  }
                },
                child: const Text('Start Failing'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Start Failing'));
      await tester.pump();

      expect(find.byType(LoadingModal), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump();

      expect(find.byType(LoadingModal), findsNothing);
      expect(caughtError, contains('Network failed'));
    });
  });
}
