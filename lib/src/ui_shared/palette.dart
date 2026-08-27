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
import 'theme_controller.dart';
import 'theme_models.dart';

/// The default emojis mapped for standard categories.
const Map<String, String> _seededCategoryEmojis = <String, String>{
  'grocery': '🛒',
  'food': '🍔',
  'fuel': '⛽',
  'shopping': '🛍️',
  'bills & utilities': '💡',
  'bills and utilities': '💡',
  'bills': '💡',
  'travel': '✈️',
  'entertainment': '🎬',
  'health': '💊',
  'uncategorized': '❓',
  'income': '💰',
  'salary': '💰',
  'credit': '💰',
  'savings': '💰',
  'saving': '💰',
  'loans': '🏦',
  'loan': '🏦',
  'emi': '🏦',
  'egg': '🥚',
  'eggs': '🥚',
  'non veg': '🍗',
  'non-veg': '🍗',
  'nonveg': '🍗',
  'chicken': '🍗',
  'meat': '🥩',
  'fish': '🐟',
  'papa': '👨',
  'dad': '👨',
  'mom': '👩',
  'family': '👪',
  'cosmetics': '💄',
  'cosmetic': '💄',
  'milk': '🥛',
  'dairy': '🥛',
  'snacks': '🍿',
  'snack': '🍿',
  'veggies and fruits': '🥗',
  'veegies and fruits': '🥗',
  'fruits and veggies': '🥗',
  'veggies': '🥗',
  'veegies': '🥗',
  'vegetables': '🥗',
  'fruits': '🍎',
  'fruit': '🍎',
};

/// Popular emojis for category selection in pickers and sheets.
const List<String> kCuratedCategoryEmojis = <String>[
  '🛒', '🍔', '⛽', '🛍️', '💡', '✈️', '🎬', '💊',
  '☕', '🍕', '🍻', '🏠', '🏋️', '🚕', '🚗', '🎮',
  '🐾', '📚', '🎁', '📺', '💻', '📱', '✂️', '👗',
  '🏖️', '🍿', '🥖', '🍎', '🍰', '🍜', '💰', '🧾',
  '📈', '🛡️', '🩺', '⚡', '🔧', '📦', '🎓', '🏷️',
  '🏦', '🥚', '🍗', '🥩', '🐟', '💸', '🍳', '🍛',
  '👨', '🥛', '💄', '🥗', '🥦', '🥕', '🍪', '🪙', '🐖',
];

/// Smart emoji suggestions for any category name based on keyword matches.
String suggestCategoryEmoji(String category) {
  final String key = category.trim().toLowerCase();
  if (key.isEmpty) return '🏷️';
  if (_seededCategoryEmojis.containsKey(key)) {
    return _seededCategoryEmojis[key]!;
  }

  if (key.contains('loan') ||
      key.contains('emi') ||
      key.contains('debt') ||
      key.contains('lend') ||
      key.contains('borrow') ||
      key.contains('mortgage') ||
      key.contains('credit card bill') ||
      key.contains('repay') ||
      key == 'loans') {
    return '🏦';
  }
  if (key.contains('savings') ||
      key.contains('saving') ||
      key.contains('deposit') ||
      key.contains('emergency fund') ||
      key.contains('piggy')) {
    return '💰';
  }
  if (key.contains('papa') ||
      key.contains('dad') ||
      key.contains('father') ||
      key.contains('mom') ||
      key.contains('mother') ||
      key.contains('family') ||
      key.contains('parent') ||
      key.contains('amma') ||
      key.contains('appa')) {
    return '👨';
  }
  if (key.contains('cosmetic') ||
      key.contains('makeup') ||
      key.contains('skincare') ||
      key.contains('perfume') ||
      key.contains('lotion') ||
      key.contains('cream')) {
    return '💄';
  }
  if (key.contains('milk') ||
      key.contains('dairy') ||
      key.contains('curd') ||
      key.contains('cheese') ||
      key.contains('butter') ||
      key.contains('paneer') ||
      key.contains('ghee')) {
    return '🥛';
  }
  if (key.contains('non veg') ||
      key.contains('non-veg') ||
      key.contains('nonveg') ||
      key.contains('non_veg') ||
      key.contains('chicken') ||
      key.contains('poultry') ||
      key.contains('biryani') ||
      key.contains('kebab') ||
      key.contains('tikka') ||
      key.contains('mutton') ||
      key.contains('meat') ||
      key.contains('fish') ||
      key.contains('seafood') ||
      key.contains('prawn') ||
      key.contains('pork') ||
      key.contains('beef') ||
      key.contains('steak')) {
    if (key.contains('fish') ||
        key.contains('seafood') ||
        key.contains('prawn') ||
        key.contains('salmon') ||
        key.contains('tuna') ||
        key.contains('crab')) {
      return '🐟';
    }
    if (key.contains('meat') ||
        key.contains('mutton') ||
        key.contains('beef') ||
        key.contains('pork') ||
        key.contains('steak')) {
      return '🥩';
    }
    return '🍗';
  }
  if (key.contains('veg') ||
      key.contains('veeg') ||
      key.contains('fruit') ||
      key.contains('salad') ||
      key.contains('produce') ||
      key.contains('greens') ||
      key.contains('apple') ||
      key.contains('banana')) {
    return '🥗';
  }
  if (key.contains('egg') ||
      key.contains('omelet') ||
      key.contains('omlet') ||
      key.contains('anda') ||
      key == 'eggs') {
    return '🥚';
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
  if (key.contains('snack') ||
      key.contains('bakery') ||
      key.contains('biscuit') ||
      key.contains('cookie') ||
      key.contains('chips') ||
      key.contains('namkeen') ||
      key.contains('popcorn') ||
      key.contains('sandwich')) {
    return '🍿';
  }
  if (key.contains('food') ||
      key.contains('din') ||
      key.contains('pizza') ||
      key.contains('burger') ||
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
  if (key.contains('transport') ||
      key.contains('commute') ||
      key.contains('cab') ||
      key.contains('taxi') ||
      key.contains('uber') ||
      key.contains('ola') ||
      key.contains('rapido') ||
      key.contains('auto') ||
      key.contains('vehicle') ||
      key.contains('drive') ||
      key.contains('car')) {
    return '🚕';
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
      key.contains('sports') ||
      key == 'sport' ||
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
  final String? trimmed = explicitIcon?.trim();
  if (trimmed != null && trimmed.isNotEmpty && trimmed != '🏷️') {
    return trimmed;
  }
  return suggestCategoryEmoji(category);
}

/// Resolves a Material vector icon for any category name or keyword match.
///
/// Supports both [AppIconPack.outlined] and [AppIconPack.filled].
IconData categoryVectorIcon(String category, {bool filled = false}) {
  final String key = category.trim().toLowerCase();
  if (key == 'income' || key == 'salary' || key == 'credit') {
    return filled
        ? Icons.account_balance_wallet
        : Icons.account_balance_wallet_outlined;
  }
  if (key.contains('loan') ||
      key.contains('emi') ||
      key.contains('debt') ||
      key.contains('lend') ||
      key.contains('borrow') ||
      key.contains('mortgage') ||
      key.contains('credit card bill') ||
      key.contains('repay') ||
      key == 'loans') {
    return filled ? Icons.account_balance : Icons.account_balance_outlined;
  }
  if (key.contains('savings') ||
      key.contains('saving') ||
      key.contains('deposit') ||
      key.contains('emergency fund') ||
      key.contains('piggy')) {
    return filled ? Icons.savings : Icons.savings_outlined;
  }
  if (key.contains('papa') ||
      key.contains('dad') ||
      key.contains('father') ||
      key.contains('mom') ||
      key.contains('mother') ||
      key.contains('family') ||
      key.contains('parent') ||
      key.contains('amma') ||
      key.contains('appa')) {
    return filled ? Icons.person : Icons.person_outline;
  }
  if (key.contains('cosmetic') ||
      key.contains('makeup') ||
      key.contains('skincare') ||
      key.contains('perfume') ||
      key.contains('lotion') ||
      key.contains('cream')) {
    return filled ? Icons.face : Icons.face_outlined;
  }
  if (key.contains('milk') ||
      key.contains('dairy') ||
      key.contains('curd') ||
      key.contains('cheese') ||
      key.contains('butter') ||
      key.contains('paneer') ||
      key.contains('ghee')) {
    return filled ? Icons.local_drink : Icons.local_drink_outlined;
  }
  if (key.contains('non veg') ||
      key.contains('non-veg') ||
      key.contains('nonveg') ||
      key.contains('non_veg') ||
      key.contains('chicken') ||
      key.contains('poultry') ||
      key.contains('biryani') ||
      key.contains('kebab') ||
      key.contains('tikka') ||
      key.contains('mutton') ||
      key.contains('meat') ||
      key.contains('fish') ||
      key.contains('seafood') ||
      key.contains('prawn') ||
      key.contains('pork') ||
      key.contains('beef') ||
      key.contains('steak')) {
    if (key.contains('fish') ||
        key.contains('seafood') ||
        key.contains('prawn') ||
        key.contains('salmon') ||
        key.contains('tuna') ||
        key.contains('crab')) {
      return filled ? Icons.set_meal : Icons.set_meal_outlined;
    }
    return filled ? Icons.kebab_dining : Icons.kebab_dining_outlined;
  }
  if (key.contains('veg') ||
      key.contains('veeg') ||
      key.contains('fruit') ||
      key.contains('salad') ||
      key.contains('produce') ||
      key.contains('greens') ||
      key.contains('apple') ||
      key.contains('banana')) {
    return filled ? Icons.eco : Icons.eco_outlined;
  }
  if (key.contains('egg') ||
      key.contains('omelet') ||
      key.contains('omlet') ||
      key.contains('anda') ||
      key == 'eggs') {
    return filled ? Icons.egg : Icons.egg_outlined;
  }
  if (key.contains('coffee') ||
      key == 'tea' ||
      key.contains('tea ') ||
      key.contains(' tea') ||
      key.contains('chai') ||
      key.contains('cafe') ||
      key.contains('starbucks')) {
    return filled ? Icons.local_cafe : Icons.local_cafe_outlined;
  }
  if (key.contains('snack') ||
      key.contains('bakery') ||
      key.contains('biscuit') ||
      key.contains('cookie') ||
      key.contains('chips') ||
      key.contains('namkeen') ||
      key.contains('popcorn') ||
      key.contains('sandwich')) {
    return filled ? Icons.fastfood : Icons.fastfood_outlined;
  }
  if (key.contains('food') ||
      key.contains('pizza') ||
      key.contains('burger') ||
      key.contains('dine') ||
      key.contains('restau') ||
      key.contains('swiggy') ||
      key.contains('zomato')) {
    return filled ? Icons.restaurant : Icons.restaurant_outlined;
  }
  if (key.contains('beer') ||
      key.contains('wine') ||
      key.contains('bar') ||
      key.contains('pub') ||
      key.contains('drink') ||
      key.contains('alcohol')) {
    return filled ? Icons.sports_bar : Icons.sports_bar_outlined;
  }
  if (key.contains('grocery') ||
      key.contains('groceries') ||
      key.contains('zepto') ||
      key.contains('blinkit') ||
      key.contains('instamart') ||
      key.contains('supermarket')) {
    return filled
        ? Icons.local_grocery_store
        : Icons.local_grocery_store_outlined;
  }
  if (key.contains('rent') ||
      key.contains('house') ||
      key.contains('home') ||
      key.contains('flat') ||
      key.contains('apartment') ||
      key.contains('maint')) {
    return filled ? Icons.home : Icons.home_outlined;
  }
  if (key.contains('pet') ||
      key.contains('dog') ||
      key.contains('cat') ||
      key.contains('vet')) {
    return filled ? Icons.pets : Icons.pets_outlined;
  }
  if (key.contains('transport') ||
      key.contains('commute') ||
      key.contains('cab') ||
      key.contains('taxi') ||
      key.contains('uber') ||
      key.contains('ola') ||
      key.contains('rapido') ||
      key.contains('auto') ||
      key.contains('vehicle') ||
      key.contains('drive') ||
      key.contains('car')) {
    return filled ? Icons.directions_car : Icons.directions_car_outlined;
  }
  if (key.contains('gym') ||
      key.contains('fitness') ||
      key.contains('workout') ||
      key.contains('sports') ||
      key == 'sport' ||
      key.contains('yoga')) {
    return filled ? Icons.fitness_center : Icons.fitness_center_outlined;
  }
  if (key.contains('fuel') ||
      key.contains('petrol') ||
      key.contains('diesel') ||
      key.contains('cng') ||
      key.contains('gas')) {
    return filled ? Icons.local_gas_station : Icons.local_gas_station_outlined;
  }
  if (key.contains('salary') ||
      key.contains('income') ||
      key.contains('deposit') ||
      key.contains('earning') ||
      key.contains('credit') ||
      key.contains('revenue') ||
      key.contains('money') ||
      key.contains('cash')) {
    return filled
        ? Icons.account_balance_wallet
        : Icons.account_balance_wallet_outlined;
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
    return filled ? Icons.flight : Icons.flight_outlined;
  }
  if (key.contains('movie') ||
      key.contains('cinema') ||
      key.contains('theatre') ||
      key.contains('show') ||
      key.contains('event') ||
      key == 'entertainment') {
    return filled ? Icons.movie : Icons.movie_outlined;
  }
  if (key.contains('game') ||
      key.contains('gaming') ||
      key.contains('steam') ||
      key.contains('playstation') ||
      key.contains('xbox')) {
    return filled ? Icons.sports_esports : Icons.sports_esports_outlined;
  }
  if (key.contains('netflix') ||
      key.contains('spotify') ||
      key.contains('prime') ||
      key.contains('youtube') ||
      key.contains('subscrip') ||
      key.contains('ott')) {
    return filled ? Icons.tv : Icons.tv_outlined;
  }
  if (key.contains('book') ||
      key.contains('education') ||
      key.contains('course') ||
      key.contains('college') ||
      key.contains('school') ||
      key.contains('tuition')) {
    return filled ? Icons.school : Icons.school_outlined;
  }
  if (key.contains('health') ||
      key.contains('med') ||
      key.contains('doctor') ||
      key.contains('hospital') ||
      key.contains('pharmacy') ||
      key.contains('clinic')) {
    return filled ? Icons.medical_services : Icons.medical_services_outlined;
  }
  if (key.contains('salon') ||
      key.contains('barber') ||
      key.contains('hair') ||
      key.contains('spa') ||
      key.contains('beauty') ||
      key.contains('groom')) {
    return filled ? Icons.content_cut : Icons.content_cut_outlined;
  }
  if (key.contains('cloth') ||
      key.contains('wear') ||
      key.contains('dress') ||
      key.contains('shirt') ||
      key.contains('fashion') ||
      key.contains('myntra')) {
    return filled ? Icons.checkroom : Icons.checkroom_outlined;
  }
  if (key.contains('tech') ||
      key.contains('laptop') ||
      key.contains('comput') ||
      key.contains('apple') ||
      key.contains('gadget') ||
      key.contains('electron')) {
    return filled ? Icons.laptop : Icons.laptop_outlined;
  }
  if (key.contains('phone') ||
      key.contains('mobile') ||
      key.contains('recharge') ||
      key.contains('wifi') ||
      key.contains('broadband') ||
      key.contains('internet')) {
    return filled ? Icons.phone_android : Icons.phone_android_outlined;
  }
  if (key.contains('gift') ||
      key.contains('donat') ||
      key.contains('charity') ||
      key.contains('present')) {
    return filled ? Icons.card_giftcard : Icons.card_giftcard_outlined;
  }
  if (key.contains('invest') ||
      key.contains('stock') ||
      key.contains('mutual') ||
      key.contains('crypto') ||
      key.contains('gold') ||
      key.contains('share')) {
    return filled ? Icons.trending_up : Icons.trending_up_outlined;
  }
  if (key.contains('insur') ||
      key.contains('policy') ||
      key.contains('lic') ||
      key.contains('protect')) {
    return filled ? Icons.shield : Icons.shield_outlined;
  }
  if (key.contains('bill') ||
      key.contains('utilit') ||
      key.contains('electric') ||
      key.contains('power') ||
      key.contains('water') ||
      key == 'bills & utilities') {
    return filled ? Icons.receipt_long : Icons.receipt_long_outlined;
  }
  if (key == 'uncategorized' || key == '❓') {
    return filled ? Icons.help : Icons.help_outline;
  }

  return filled ? Icons.label : Icons.label_outline;
}

IconData categoryIcon(String category) =>
    categoryVectorIcon(category, filled: false);

/// A responsive category badge that automatically renders an emoji or vector
/// icon based on the active [AppIconPack] in [ThemeController].
class CategoryAvatar extends StatelessWidget {
  const CategoryAvatar({
    super.key,
    required this.category,
    this.explicitIcon,
    this.isCredit = false,
    this.size = 44,
    this.fontSize = 22,
    this.iconSize = 22,
    this.borderRadius = 12,
    this.iconPack,
    this.backgroundColor,
    this.borderColor,
  });

  final String category;
  final String? explicitIcon;
  final bool isCredit;
  final double size;
  final double fontSize;
  final double iconSize;
  final double borderRadius;
  final AppIconPack? iconPack;
  final Color? backgroundColor;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pack = iconPack ?? ThemeController.instance.appIconPack;
    final catColor = categoryColor(category, theme.brightness);
    final bg = backgroundColor ?? catColor.withValues(alpha: 0.16);
    final border = borderColor ?? catColor.withValues(alpha: 0.35);

    final Widget child = switch (pack) {
      AppIconPack.emojis => Text(
          isCredit ? '💰' : categoryEmoji(category, explicitIcon: explicitIcon),
          style: TextStyle(fontSize: fontSize),
        ),
      AppIconPack.outlined => Icon(
          isCredit
              ? Icons.account_balance_wallet_outlined
              : categoryVectorIcon(category, filled: false),
          color: catColor,
          size: iconSize,
        ),
      AppIconPack.filled => Icon(
          isCredit
              ? Icons.account_balance_wallet
              : categoryVectorIcon(category, filled: true),
          color: catColor,
          size: iconSize,
        ),
    };

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(color: border, width: 1),
      ),
      alignment: Alignment.center,
      child: child,
    );
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
