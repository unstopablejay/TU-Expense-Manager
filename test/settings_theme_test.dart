import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tu_expense_tracker/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  PackageInfo.setMockInitialValues(
    appName: 'TU Expense Tracker',
    packageName: 'com.tu.expense.manager',
    version: '1.0.0',
    buildNumber: '1',
    buildSignature: '',
  );

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('SettingsScreen displays Appearance section with theme modes and accents',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    final controller = ThemeController.instance;
    await controller.setThemeMode(AppThemeMode.system);
    await controller.setAccentColor(AppAccentColor.blue);

    await tester.pumpWidget(
      MaterialApp(
        theme: controller.lightTheme,
        home: const Scaffold(
          body: SettingsScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Verify Appearance section header
    expect(find.text('Appearance'), findsOneWidget);
    expect(find.text('Theme mode'), findsOneWidget);
    expect(find.text('Accent color'), findsOneWidget);

    // Verify theme mode segments
    expect(find.text('System'), findsOneWidget);
    expect(find.text('Light'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
    expect(find.text('OLED'), findsOneWidget);

    // Tap OLED segment
    await tester.tap(find.text('OLED'));
    await tester.pumpAndSettle();

    expect(controller.appThemeMode, AppThemeMode.oled);
    expect(controller.isOled, isTrue);

    // Tap Crimson Red accent color swatch tooltip/button
    final redSwatch = find.byTooltip('Crimson Red');
    expect(redSwatch, findsOneWidget);
    await tester.tap(redSwatch);
    await tester.pumpAndSettle();

    expect(controller.accentColor, AppAccentColor.red);
  });

  testWidgets('TuExpenseTrackerApp builds with custom theme controller and reacts to mode change',
      (WidgetTester tester) async {
    final customController = ThemeController();
    await customController.setThemeMode(AppThemeMode.dark);
    await customController.setAccentColor(AppAccentColor.purple);

    await tester.pumpWidget(
      ListenableBuilder(
        listenable: customController,
        builder: (context, _) => MaterialApp(
          theme: customController.lightTheme,
          darkTheme: customController.darkTheme,
          themeMode: customController.flutterThemeMode,
          home: const Scaffold(body: Text('Theme Home')),
        ),
      ),
    );
    await tester.pump();

    var app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.dark);

    await customController.setThemeMode(AppThemeMode.light);
    await tester.pump();

    app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.themeMode, ThemeMode.light);
  });
}
