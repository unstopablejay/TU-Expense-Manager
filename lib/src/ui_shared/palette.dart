/// The colours and icons a category is drawn with.
///
/// Assigned from a category's *name*, never from its rank, so a category keeps
/// its colour across every month and every chart. Were slots handed out by
/// position in a sorted-by-spend list, the eye would read a colour change as a
/// change in the data.
library;

import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/ledger.dart';

IconData categoryIcon(String category) {
  switch (category.toLowerCase()) {
    case 'grocery':
      return Icons.local_grocery_store_outlined;
    case 'food':
      return Icons.restaurant_outlined;
    case 'fuel':
      return Icons.local_gas_station_outlined;
    case 'shopping':
      return Icons.shopping_bag_outlined;
    case 'bills & utilities':
      return Icons.receipt_outlined;
    case 'travel':
      return Icons.flight_takeoff_outlined;
    case 'entertainment':
      return Icons.movie_outlined;
    case 'health':
      return Icons.medical_services_outlined;
    case 'uncategorized':
      return Icons.help_outline;
    default:
      return Icons.label_outline;
  }
}

/// The eight categorical chart colours, light and dark.
///
/// A validated set rather than a pretty one: the order is the colour-blind
/// safety mechanism, and the dark row is the same eight hues *re-stepped* for a
/// dark surface — not the light row lightened programmatically, which is how
/// palettes lose their separation.
const List<Color> _chartHuesLight = <Color>[
  Color(0xFF2A78D6), // blue
  Color(0xFFEB6834), // orange
  Color(0xFF1BAF7A), // aqua
  Color(0xFFEDA100), // yellow
  Color(0xFFE87BA4), // magenta
  Color(0xFF008300), // green
  Color(0xFF4A3AA7), // violet
  Color(0xFFE34948), // red
];

const List<Color> _chartHuesDark = <Color>[
  Color(0xFF3987E5),
  Color(0xFFD95926),
  Color(0xFF199E70),
  Color(0xFFC98500),
  Color(0xFFD55181),
  Color(0xFF008300),
  Color(0xFF9085E9),
  Color(0xFFE66767),
];

/// The hues for [brightness]. The two lists are separate palettes rather than
/// one lightened programmatically, so callers ask for a brightness and never
/// have to know which list answered.
List<Color> chartHues(Brightness brightness) =>
    brightness == Brightness.dark ? _chartHuesDark : _chartHuesLight;

/// The seeded categories' fixed slots. Everything else hashes its name.
const Map<String, int> _seededCategorySlots = <String, int>{
  'grocery': 0,
  'food': 1,
  'fuel': 2,
  'shopping': 3,
  'bills & utilities': 4,
  'travel': 5,
  'entertainment': 6,
  'health': 7,
};

/// A stable colour for [category], in the given [brightness].
///
/// **Assigned from the name, never from the rank.** This is the whole point:
/// were slots handed out by position in the sorted-by-spend list, Food would be
/// blue in a month it led and orange in a month it did not, and the eye would
/// read a colour change as a change in the data. A category keeps its colour
/// across every month and every chart on the screen.
///
/// [kOtherCategory] and Uncategorized are deliberately grey — they are not a
/// category anyone spent money "on", and giving them a hue would let the tail
/// of the breakdown compete with the real answers.
Color categoryColor(String category, Brightness brightness) {
  final List<Color> hues = chartHues(brightness);
  final String key = category.toLowerCase();
  if (key == kOtherCategory.toLowerCase() ||
      key == kUncategorized.toLowerCase()) {
    return brightness == Brightness.dark
        ? const Color(0xFF898781)
        : const Color(0xFFC3C2B7);
  }
  final int? seeded = _seededCategorySlots[key];
  if (seeded != null) return hues[seeded];
  // `hashCode` on a String is stable within a run but not guaranteed across
  // them, so spell the hash out — a category must not change colour when the
  // app restarts.
  var hash = 0;
  for (final int unit in key.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return hues[hash % hues.length];
}

/// `ColorScheme` has no dependable green role, so money-in gets an explicit
/// colour picked for contrast against the current brightness.
Color creditColor(ThemeData theme) => theme.brightness == Brightness.dark
    ? Colors.greenAccent.shade200
    : Colors.green.shade800;
