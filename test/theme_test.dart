import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tu_expense_tracker/main.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Theme models & enums', () {
    test('AppThemeMode translates to flutter ThemeMode correctly', () {
      expect(AppThemeMode.system.flutterThemeMode, ThemeMode.system);
      expect(AppThemeMode.light.flutterThemeMode, ThemeMode.light);
      expect(AppThemeMode.dark.flutterThemeMode, ThemeMode.dark);
      expect(AppThemeMode.oled.flutterThemeMode, ThemeMode.dark);
    });

    test('AppThemeMode.fromName parses names forgivingly with fallback', () {
      expect(AppThemeMode.fromName('system'), AppThemeMode.system);
      expect(AppThemeMode.fromName('light'), AppThemeMode.light);
      expect(AppThemeMode.fromName('DARK'), AppThemeMode.dark);
      expect(AppThemeMode.fromName('Oled'), AppThemeMode.oled);
      expect(AppThemeMode.fromName(null), AppThemeMode.system);
      expect(AppThemeMode.fromName('invalid_mode'), AppThemeMode.system);
    });

    test('AppAccentColor.fromName parses names forgivingly with fallback', () {
      expect(AppAccentColor.fromName('blue'), AppAccentColor.blue);
      expect(AppAccentColor.fromName('RED'), AppAccentColor.red);
      expect(AppAccentColor.fromName('green'), AppAccentColor.green);
      expect(AppAccentColor.fromName('Purple'), AppAccentColor.purple);
      expect(AppAccentColor.fromName('orange'), AppAccentColor.orange);
      expect(AppAccentColor.fromName('pink'), AppAccentColor.pink);
      expect(AppAccentColor.fromName('cyan'), AppAccentColor.cyan);
      expect(AppAccentColor.fromName('amber'), AppAccentColor.amber);
      expect(AppAccentColor.fromName(null), AppAccentColor.blue);
      expect(AppAccentColor.fromName('unknown_color'), AppAccentColor.blue);
    });
  });

  group('appTheme generator', () {
    test('generates Material 3 theme for light mode', () {
      final ThemeData theme = appTheme(Brightness.light, seedColor: AppAccentColor.blue.seedColor);
      expect(theme.useMaterial3, isTrue);
      expect(theme.brightness, Brightness.light);
    });

    test('generates Material 3 theme for standard dark mode', () {
      final ThemeData theme = appTheme(Brightness.dark, seedColor: AppAccentColor.blue.seedColor, isOled: false);
      expect(theme.useMaterial3, isTrue);
      expect(theme.brightness, Brightness.dark);
      expect(theme.scaffoldBackgroundColor, isNot(const Color(0xFF000000)));
    });

    test('generates Pitch Black OLED theme for dark mode with isOled=true', () {
      final ThemeData theme = appTheme(Brightness.dark, seedColor: AppAccentColor.red.seedColor, isOled: true);
      expect(theme.useMaterial3, isTrue);
      expect(theme.brightness, Brightness.dark);
      expect(theme.scaffoldBackgroundColor, const Color(0xFF000000));
      expect(theme.canvasColor, const Color(0xFF000000));
      expect(theme.cardColor, const Color(0xFF121418));
      expect(theme.colorScheme.surface, const Color(0xFF000000));
      expect(theme.colorScheme.surfaceContainer, const Color(0xFF121418));
      expect(theme.appBarTheme.backgroundColor, const Color(0xFF000000));
      expect(theme.navigationBarTheme.backgroundColor, const Color(0xFF000000));
    });

    test('isOled has no effect on Brightness.light', () {
      final ThemeData theme = appTheme(Brightness.light, seedColor: AppAccentColor.blue.seedColor, isOled: true);
      expect(theme.brightness, Brightness.light);
      expect(theme.scaffoldBackgroundColor, isNot(const Color(0xFF000000)));
    });
  });

  group('ThemePrefs and ThemeController', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
    });

    test('ThemeController defaults to system mode and blue accent', () {
      final ThemeController controller = ThemeController();
      expect(controller.appThemeMode, AppThemeMode.system);
      expect(controller.accentColor, AppAccentColor.blue);
      expect(controller.isOled, isFalse);
      expect(controller.flutterThemeMode, ThemeMode.system);
    });

    test('ThemeController updates and notifies on mode change', () async {
      final ThemeController controller = ThemeController();
      var notifications = 0;
      controller.addListener(() => notifications++);

      await controller.setThemeMode(AppThemeMode.oled);
      expect(controller.appThemeMode, AppThemeMode.oled);
      expect(controller.isOled, isTrue);
      expect(controller.flutterThemeMode, ThemeMode.dark);
      expect(notifications, 1);

      // Same mode shouldn't notify again
      await controller.setThemeMode(AppThemeMode.oled);
      expect(notifications, 1);
    });

    test('ThemeController updates and notifies on accent change', () async {
      final ThemeController controller = ThemeController();
      var notifications = 0;
      controller.addListener(() => notifications++);

      await controller.setAccentColor(AppAccentColor.purple);
      expect(controller.accentColor, AppAccentColor.purple);
      expect(notifications, 1);

      // Same accent shouldn't notify again
      await controller.setAccentColor(AppAccentColor.purple);
      expect(notifications, 1);
    });

    test('ThemeController persists and restores from ThemePrefs', () async {
      final ThemeController controller1 = ThemeController();
      await controller1.setThemeMode(AppThemeMode.dark);
      await controller1.setAccentColor(AppAccentColor.green);

      final ThemeController controller2 = ThemeController();
      await controller2.load();
      expect(controller2.appThemeMode, AppThemeMode.dark);
      expect(controller2.accentColor, AppAccentColor.green);
      expect(controller2.isLoaded, isTrue);
    });
  });
}
