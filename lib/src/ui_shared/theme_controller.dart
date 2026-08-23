/// Manages and persists active theme mode and accent color across the app.
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'theme.dart';
import 'theme_models.dart';

/// The stored preferences for theme and accent colors.
class ThemePrefs {
  const ThemePrefs();

  static const ThemePrefs instance = ThemePrefs();

  static const String _themeModeKey = 'theme.mode';
  static const String _accentColorKey = 'theme.accent';
  static const String _iconPackKey = 'theme.icon_pack';

  Future<AppThemeMode> themeMode() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_themeModeKey);
    return AppThemeMode.fromName(raw);
  }

  Future<void> setThemeMode(AppThemeMode mode) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_themeModeKey, mode.name);
  }

  Future<AppAccentColor> accentColor() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_accentColorKey);
    return AppAccentColor.fromName(raw);
  }

  Future<void> setAccentColor(AppAccentColor accent) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_accentColorKey, accent.name);
  }

  Future<AppIconPack> iconPack() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? raw = prefs.getString(_iconPackKey);
    return AppIconPack.fromName(raw);
  }

  Future<void> setIconPack(AppIconPack pack) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(_iconPackKey, pack.name);
  }
}

/// Global controller holding active [AppThemeMode], [AppAccentColor], and [AppIconPack].
class ThemeController extends ChangeNotifier {
  ThemeController({ThemePrefs? prefs}) : _prefs = prefs ?? ThemePrefs.instance;

  static final ThemeController instance = ThemeController();

  final ThemePrefs _prefs;

  AppThemeMode _themeMode = AppThemeMode.system;
  AppAccentColor _accentColor = AppAccentColor.blue;
  AppIconPack _iconPack = AppIconPack.emojis;
  bool _loaded = false;

  AppThemeMode get appThemeMode => _themeMode;
  AppAccentColor get accentColor => _accentColor;
  AppIconPack get appIconPack => _iconPack;
  bool get isOled => _themeMode == AppThemeMode.oled;
  bool get isLoaded => _loaded;

  /// Flutter [ThemeMode] enum to pass to MaterialApp.
  ThemeMode get flutterThemeMode => _themeMode.flutterThemeMode;

  /// Resolves the Light [ThemeData] for MaterialApp.
  ThemeData get lightTheme => appTheme(
        Brightness.light,
        seedColor: _accentColor.seedColor,
        isOled: false,
      );

  /// Resolves the Dark [ThemeData] for MaterialApp.
  ThemeData get darkTheme => appTheme(
        Brightness.dark,
        seedColor: _accentColor.seedColor,
        isOled: isOled,
      );

  /// Loads stored preferences on startup.
  Future<void> load() async {
    _themeMode = await _prefs.themeMode();
    _accentColor = await _prefs.accentColor();
    _iconPack = await _prefs.iconPack();
    _loaded = true;
    notifyListeners();
  }

  /// Sets and persists [AppThemeMode].
  Future<void> setThemeMode(AppThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    notifyListeners();
    await _prefs.setThemeMode(mode);
  }

  /// Sets and persists [AppAccentColor].
  Future<void> setAccentColor(AppAccentColor accent) async {
    if (_accentColor == accent) return;
    _accentColor = accent;
    notifyListeners();
    await _prefs.setAccentColor(accent);
  }

  /// Sets and persists [AppIconPack].
  Future<void> setIconPack(AppIconPack pack) async {
    if (_iconPack == pack) return;
    _iconPack = pack;
    notifyListeners();
    await _prefs.setIconPack(pack);
  }
}

