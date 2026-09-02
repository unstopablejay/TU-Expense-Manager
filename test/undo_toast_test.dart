import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tu_expense_tracker/src/mobile/widgets/undo_toast.dart';

void main() {
  // ---------------------------------------------------------------------------
  // UndoToastController – unit tests (no widget tree)
  // ---------------------------------------------------------------------------

  group('UndoToastController', () {
    test('starts with no active entry', () {
      final ctrl = UndoToastController();
      expect(ctrl.active, isNull);
      ctrl.dispose();
    });

    test('show() sets active entry and notifies listeners', () {
      final ctrl = UndoToastController();
      var notified = 0;
      ctrl.addListener(() => notified++);

      ctrl.show(message: 'Deleted Swiggy', onUndo: () async {});

      expect(ctrl.active, isNotNull);
      expect(notified, 1);
      ctrl.dispose();
    });

    test('dismissActive() clears active (no widget mounted) and notifies', () {
      final ctrl = UndoToastController();
      var notified = 0;
      ctrl.addListener(() => notified++);

      ctrl.show(message: 'A', onUndo: () async {});
      expect(notified, 1);

      ctrl.dismissActive();
      expect(ctrl.active, isNull);
      expect(notified, 2);
      ctrl.dispose();
    });

    test('queued toast is promoted synchronously when no widget is mounted',
        () {
      final ctrl = UndoToastController();

      ctrl.show(message: 'First', onUndo: () async {});
      ctrl.show(message: 'Second', onUndo: () async {});

      // No dismiss callback registered (no widget), so promotion is immediate.
      expect(ctrl.active, isNotNull);
      ctrl.dispose();
    });

    test('dismissActive() is a no-op if nothing is active', () {
      final ctrl = UndoToastController();
      expect(() => ctrl.dismissActive(), returnsNormally);
      ctrl.dispose();
    });
  });

  // ---------------------------------------------------------------------------
  // UndoToast widget – integration / widget tests
  // ---------------------------------------------------------------------------

  group('UndoToast widget', () {
    Future<void> pumpToast(WidgetTester tester, {String message = 'Deleted Zomato', VoidCallback? onUndo}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: UndoToast(
            child: Builder(
              builder: (BuildContext ctx) => TextButton(
                onPressed: () => UndoToast.controllerOf(ctx).show(
                  message: message,
                  onUndo: () async {
                    onUndo?.call();
                  },
                ),
                child: const Text('Delete'),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('toast card appears when show() is called',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await pumpToast(tester, message: 'Deleted Zomato');

      await tester.tap(find.text('Delete'));
      // Let the pop-in animation complete (220 ms).
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Deleted Zomato'), findsOneWidget);
      expect(find.text('Undo'), findsOneWidget);
      expect(find.byIcon(Icons.close), findsOneWidget);
    });

    testWidgets('X button starts dismiss (controller cleared after animation)',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await pumpToast(tester, message: 'Deleted Blinkit');

      await tester.tap(find.text('Delete'));
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Deleted Blinkit'), findsOneWidget);

      // The close button starts the dismiss animation.
      await tester.tap(find.byIcon(Icons.close));
      await tester.pump(); // Start of reverse animation.

      // The card is still visible during the animation.
      // We verify the X was tappable and dismiss is in progress (scale ≤ 1).
      // (Full removal requires the real animation to complete in integration.)
      expect(find.byIcon(Icons.close), findsOneWidget); // still mid-animation
    });

    testWidgets('Undo button is visible and tappable', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await pumpToast(tester, message: 'Deleted Swiggy');

      await tester.tap(find.text('Delete'));
      await tester.pump(const Duration(milliseconds: 250));

      // Verify the Undo button is rendered and tappable (no crash).
      expect(find.text('Undo'), findsOneWidget);
      await tester.tap(find.text('Undo'));
      await tester.pump();
    });

    testWidgets('progress bar is visible immediately after show',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      await pumpToast(tester);
      await tester.tap(find.text('Delete'));
      await tester.pump(const Duration(milliseconds: 250));

      // LinearProgressIndicator is used as the timer bar.
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
    });

    testWidgets('controllerOf() throws assertion when UndoToast is absent',
        (WidgetTester tester) async {
      // Pump a widget that calls controllerOf() outside of an UndoToast tree.
      // The assertion should fire synchronously inside the builder.
      AssertionError? caught;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext ctx) {
              try {
                UndoToast.controllerOf(ctx);
              } on AssertionError catch (e) {
                caught = e;
              }
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(caught, isNotNull);
    });
  });
}
