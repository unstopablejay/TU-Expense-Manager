/// The app's look, in one place so both targets wear it.
library;

import 'package:flutter/material.dart';

/// The seed every colour in the app is derived from.
const Color kSeedColor = Color(0xFF00518F);

/// The theme for [brightness].
///
/// One function taking a brightness rather than two constants, because the only
/// difference between them is that argument, and a second literal is a second
/// place for the seed to be changed in.
ThemeData appTheme(Brightness brightness) => ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: kSeedColor,
        brightness: brightness,
      ),
    );
