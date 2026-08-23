/// The app's look, in one place so both targets wear it.
library;

import 'package:flutter/material.dart';

/// The default seed every colour in the app is derived from.
const Color kSeedColor = Color(0xFF00518F);

/// The theme for [brightness].
///
/// Supports custom [seedColor] and [isOled] (pitch black scaffold and dark
/// obsidian container surfaces for true black OLED displays).
ThemeData appTheme(
  Brightness brightness, {
  Color seedColor = kSeedColor,
  bool isOled = false,
}) {
  if (brightness == Brightness.dark && isOled) {
    final ColorScheme baseScheme = ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: Brightness.dark,
    );
    final ColorScheme oledScheme = baseScheme.copyWith(
      surface: const Color(0xFF000000),
      surfaceContainerLowest: const Color(0xFF000000),
      surfaceContainerLow: const Color(0xFF0A0C10),
      surfaceContainer: const Color(0xFF121418),
      surfaceContainerHigh: const Color(0xFF1A1D24),
      surfaceContainerHighest: const Color(0xFF222630),
      surfaceDim: const Color(0xFF000000),
      surfaceBright: const Color(0xFF282C37),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: oledScheme,
      scaffoldBackgroundColor: const Color(0xFF000000),
      canvasColor: const Color(0xFF000000),
      cardColor: const Color(0xFF121418),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF000000),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: const Color(0xFF000000),
        surfaceTintColor: Colors.transparent,
        indicatorColor: oledScheme.primary.withValues(alpha: 0.24),
        iconTheme: WidgetStateProperty.resolveWith((Set<WidgetState> states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(color: oledScheme.primary);
          }
          return IconThemeData(color: oledScheme.onSurfaceVariant);
        }),
      ),
      cardTheme: const CardThemeData(
        color: Color(0xFF121418),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
          side: BorderSide(color: Color(0xFF222630), width: 1),
        ),
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: Color(0xFF121418),
        surfaceTintColor: Colors.transparent,
      ),
      dialogTheme: const DialogThemeData(
        backgroundColor: Color(0xFF121418),
        surfaceTintColor: Colors.transparent,
      ),
      dividerTheme: const DividerThemeData(
        color: Color(0xFF222630),
        thickness: 1,
        space: 1,
      ),
    );
  }

  return ThemeData(
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(
      seedColor: seedColor,
      brightness: brightness,
    ),
  );
}
