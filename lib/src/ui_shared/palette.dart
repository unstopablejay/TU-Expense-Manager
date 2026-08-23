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

/// The default emojis mapped for standard categories.
const Map<String, String> _seededCategoryEmojis = <String, String>{
  'grocery': '🛒',
  'food': '🍔',
  'fuel': '⛽',
  'shopping': '🛍️',
  'bills & utilities': '💡',
  'bills': '💡',
  'travel': '✈️',
  'entertainment': '🎬',
  'health': '💊',
  'uncategorized': '❓',
  'income': '💰',
  'salary': '💰',
  'credit': '💰',
};

/// Popular emojis for category selection in pickers and sheets.
const List<String> kCuratedCategoryEmojis = <String>[
  '🛒', '🍔', '⛽', '🛍️', '💡', '✈️', '🎬', '💊',
  '☕', '🍕', '🍻', '🏠', '🏋️', '🚕', '🚗', '🎮',
  '🐾', '📚', '🎁', '📺', '💻', '📱', '✂️', '👗',
  '🏖️', '🍿', '🥖', '🍎', '🍰', '🍜', '💰', '🧾',
  '📈', '🛡️', '🩺', '⚡', '🔧', '📦', '🎓', '🏷️',
];

/// Smart emoji suggestions for any category name based on keyword matches.
String suggestCategoryEmoji(String category) {
  final String key = category.trim().toLowerCase();
  if (key.isEmpty) return '🏷️';
  if (_seededCategoryEmojis.containsKey(key)) {
    return _seededCategoryEmojis[key]!;
  }

  if (key.contains('coffee') ||
      key == 'tea' ||
      key.contains('tea ') ||
      key.contains(' tea') ||
      key.contains('chai') ||
      key.contains('cafe') ||
      key.contains('starbucks')) {
    return '☕';
  }
  if (key.contains('pizza') ||
      key.contains('burger') ||
      key.contains('snack') ||
      key.contains('dine') ||
      key.contains('restau') ||
      key.contains('swiggy') ||
      key.contains('zomato')) {
    return '🍔';
  }
  if (key.contains('beer') ||
      key.contains('wine') ||
      key.contains('bar') ||
      key.contains('pub') ||
      key.contains('drink') ||
      key.contains('alcohol')) {
    return '🍻';
  }
  if (key.contains('grocery') ||
      key.contains('zepto') ||
      key.contains('blinkit') ||
      key.contains('instamart') ||
      key.contains('supermarket')) {
    return '🛒';
  }
  if (key.contains('rent') ||
      key.contains('house') ||
      key.contains('home') ||
      key.contains('flat') ||
      key.contains('apartment') ||
      key.contains('maint')) {
    return '🏠';
  }
  if (key.contains('pet') ||
      key.contains('dog') ||
      key.contains('cat') ||
      key.contains('vet')) {
    return '🐾';
  }
  if (key.contains('gym') ||
      key.contains('fitness') ||
      key.contains('workout') ||
      key.contains('sport') ||
      key.contains('yoga')) {
    return '🏋️';
  }
  if (key.contains('fuel') ||
      key.contains('petrol') ||
      key.contains('diesel') ||
      key.contains('cng') ||
      key.contains('gas')) {
    return '⛽';
  }
  if (key.contains('cab') ||
      key.contains('taxi') ||
      key.contains('uber') ||
      key.contains('ola') ||
      key.contains('rapido') ||
      key.contains('auto')) {
    return '🚕';
  }
  if (key.contains('flight') ||
      key.contains('airline') ||
      key.contains('airfare') ||
      key.contains('airport') ||
      key.contains('trip') ||
      key.contains('travel') ||
      key.contains('hotel') ||
      key.contains('vacation') ||
      key.contains('tour')) {
    return '✈️';
  }
  if (key.contains('movie') ||
      key.contains('cinema') ||
      key.contains('theatre') ||
      key.contains('show') ||
      key.contains('event')) {
    return '🎬';
  }
  if (key.contains('game') ||
      key.contains('gaming') ||
      key.contains('steam') ||
      key.contains('playstation') ||
      key.contains('xbox')) {
    return '🎮';
  }
  if (key.contains('netflix') ||
      key.contains('spotify') ||
      key.contains('prime') ||
      key.contains('youtube') ||
      key.contains('subscrip') ||
      key.contains('ott')) {
    return '📺';
  }
  if (key.contains('book') ||
      key.contains('education') ||
      key.contains('course') ||
      key.contains('college') ||
      key.contains('school') ||
      key.contains('tuition')) {
    return '📚';
  }
  if (key.contains('health') ||
      key.contains('med') ||
      key.contains('doctor') ||
      key.contains('hospital') ||
      key.contains('pharmacy') ||
      key.contains('clinic')) {
    return '💊';
  }
  if (key.contains('salon') ||
      key.contains('barber') ||
      key.contains('hair') ||
      key.contains('spa') ||
      key.contains('beauty') ||
      key.contains('groom')) {
    return '✂️';
  }
  if (key.contains('cloth') ||
      key.contains('wear') ||
      key.contains('dress') ||
      key.contains('shirt') ||
      key.contains('fashion') ||
      key.contains('myntra')) {
    return '👗';
  }
  if (key.contains('tech') ||
      key.contains('laptop') ||
      key.contains('comput') ||
      key.contains('apple') ||
      key.contains('gadget') ||
      key.contains('electron')) {
    return '💻';
  }
  if (key.contains('phone') ||
      key.contains('mobile') ||
      key.contains('recharge') ||
      key.contains('wifi') ||
      key.contains('broadband') ||
      key.contains('internet')) {
    return '📱';
  }
  if (key.contains('gift') ||
      key.contains('donat') ||
      key.contains('charity') ||
      key.contains('present')) {
    return '🎁';
  }
  if (key.contains('invest') ||
      key.contains('stock') ||
      key.contains('mutual') ||
      key.contains('crypto') ||
      key.contains('gold') ||
      key.contains('share')) {
    return '📈';
  }
  if (key.contains('insur') ||
      key.contains('policy') ||
      key.contains('lic') ||
      key.contains('protect')) {
    return '🛡️';
  }
  if (key.contains('salary') ||
      key.contains('bonus') ||
      key.contains('freelance') ||
      key.contains('income') ||
      key.contains('earn')) {
    return '💰';
  }
  if (key.contains('bill') ||
      key.contains('utilit') ||
      key.contains('electric') ||
      key.contains('power') ||
      key.contains('water')) {
    return '💡';
  }
  if (key.contains('shop') ||
      key.contains('amazon') ||
      key.contains('flipkart') ||
      key.contains('store') ||
      key.contains('mall')) {
    return '🛍️';
  }

  return '🏷️';
}

/// Resolves the emoji for a category, honoring [explicitIcon] if provided.
String categoryEmoji(String category, {String? explicitIcon}) {
  if (explicitIcon != null && explicitIcon.trim().isNotEmpty) {
    return explicitIcon.trim();
  }
  return suggestCategoryEmoji(category);
}

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
