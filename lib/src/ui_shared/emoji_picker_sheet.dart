/// WhatsApp-style full categorized emoji picker bottom sheet.
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A category grouping of emojis with a distinct navigation icon.
class EmojiCategory {
  const EmojiCategory({
    required this.name,
    required this.icon,
    required this.emojis,
  });

  final String name;
  final IconData icon;
  final List<String> emojis;
}

/// The standard WhatsApp / Unicode categorized emoji catalog.
const List<EmojiCategory> kWhatsAppEmojiCategories = <EmojiCategory>[
  EmojiCategory(
    name: 'Smileys & Emotion',
    icon: Icons.sentiment_satisfied_alt_outlined,
    emojis: <String>[
      '😀', '😃', '😄', '😁', '😆', '😅', '🤣', '😂', '🙂', '🙃',
      '😉', '😊', '😇', '🥰', '😍', '🤩', '😘', '😗', '😚', '😋',
      '😛', '😜', '🤪', '😝', '🤑', '🤗', '🤭', '🤫', '🤔', '🤐',
      '🤨', '😐', '😑', '😶', '😏', '😒', '🙄', '😬', '🤥', '😌',
      '😔', '😪', '🤤', '😴', '😷', '🤒', '🤕', '🤢', '🤮', '🤧',
      '🥵', '🥶', '🥴', '😵', '🤯', '🤠', '🥳', '🥸', '😎', '🤓',
      '🧐', '😕', '😟', '🙁', '😮', '😯', '😲', '😳', '🥺', '😦',
      '😧', '😨', '😰', '😥', '😢', '😭', '😱', '😖', '😣', '😞',
      '😓', '😩', '😫', '🥱', '😤', '😡', '😠', '🤬', '😈', '👿',
      '💀', '☠️', '💩', '🤡', '👹', '👺', '👻', '👽', '👾', '🤖',
    ],
  ),
  EmojiCategory(
    name: 'People & Body',
    icon: Icons.person_outline,
    emojis: <String>[
      '👋', '🤚', '🖐️', '✋', '🖖', '🫱', '🫲', '🫳', '🫴', '👌',
      '🤌', '🤏', '✌️', '🤞', '🫰', '🤟', '🤘', '🤙', '👈', '👉',
      '👆', '🖕', '👇', '☝️', '🫵', '👍', '👎', '✊', '👊', '🤛',
      '🤜', '👏', '🙌', '🫶', '👐', '🤲', '🤝', '🙏', '✍️', '💅',
      '🤳', '💪', '🦾', '🦿', '🦵', '🦶', '👂', '🦻', '👃', '🧠',
      '🫀', '🫁', '🦷', '🦴', '👀', '👁️', '👅', '👄', '🫦', '👶',
      '🧒', '👦', '👧', '🧑', '👱', '👨', '🧔', '👩', '🧓', '👴',
      '👵', '👨‍⚕️', '👩‍⚕️', '👨‍🎓', '👩‍🎓', '👨‍🏫', '👩‍🏫', '👨‍⚖️', '👩‍⚖️', '👨‍🌾',
      '👩‍🌾', '👨‍🍳', '👩‍🍳', '👨‍🔧', '👩‍🔧', '👨‍🏭', '👩‍🏭', '👨‍💼', '👩‍💼', '👨‍🔬',
      '👩‍🔬', '👨‍💻', '👩‍💻', '👨‍🎤', '👩‍🎤', '👨‍🎨', '👩‍🎨', '👨‍✈️', '👩‍✈️', '👨‍🚀',
      '👩‍🚀', '👨‍🚒', '👩‍🚒', '👮', '🕵️', '💂', '👷', '🤴', '👸', '👳',
      '👲', '🧕', '🤵', '👰', '🤰', '🤱', '👼', '🎅', '🤶', '🦸',
      '🦹', '🧙', '🧚', '🧛', '🧜', '🧝', '🧞', '🧟', '💆', '💇',
      '🚶', '🏃', '💃', '🕺', '🧗', '🧘', '🛀', '🛌',
    ],
  ),
  EmojiCategory(
    name: 'Animals & Nature',
    icon: Icons.pets_outlined,
    emojis: <String>[
      '🐶', '🐱', '🐭', '🐹', '🐰', '🦊', '🐻', '🐼', '🐨', '🐯',
      '🦁', '🐮', '🐷', '🐽', '🐸', '🐵', '🙈', '🙉', '🙊', '🐒',
      '🐔', '🐧', '🐦', '🐤', '🐣', '🐥', '🦆', '🦅', '🦉', '🦇',
      '🐺', '🐗', '🐴', '🦄', '🐝', '🪱', '🐛', '🦋', '🐌', '🐞',
      '🐜', '🪰', '🪲', '🪳', '🦟', '🦗', '🕷️', '🕸️', '🦂', '🐢',
      '🐍', '🦎', '🦖', '🦕', '🐙', '🦑', '🦐', '🦞', '🦀', '🐡',
      '🐠', '🐟', '🐬', '🐳', '🐋', '🦈', '🐊', '🐅', '🐆', '🦓',
      '🦍', '🦧', '🦣', '🐘', '🦛', '🦏', '🐪', '🐫', '🦒', '🦘',
      '🦬', '🐃', '🐂', '🐄', '🐎', '🐖', '🐏', '🐑', '🦙', '🐐',
      '🦌', '🐕', '🐩', '🦮', '🐕‍🦺', '🐈', '🐈‍⬛', '🪶', '🐓', '🦃',
      '🦤', '🦚', '🦜', '🦢', '🦩', '🕊️', '🐇', '🦝', '🦨', '🦡',
      '🦫', '🦦', '🦥', '🐁', '🐀', '🐿️', '🦔', '🐾', '🐉', '🐲',
      '🌵', '🎄', '🌲', '🌳', '🌴', '🪵', '🌱', '🌿', '☘️', '🍀',
      '🎍', '🪴', '🎋', '🍃', '🍂', '🍁', '🍄', '🌾', '💐', '🌷',
      '🌹', '🥀', '🌺', '🌸', '🌼', '🌻', '🌞', '🌝', '🌛', '🌜',
      '🌚', '🌕', '🌖', '🌗', '🌘', '🌑', '🌒', '🌓', '🌔', '🌙',
      '🌎', '🌍', '🌏', '🪐', '💫', '⭐️', '🌟', '✨', '⚡️', '☄️',
      '💥', '🔥', '🌪️', '🌈', '☀️', '🌤️', '⛅️', '🌥️', '☁️', '🌦️',
      '🌧️', '⛈️', '🌩️', '🌨️', '❄️', '☃️', '⛄️', '🌬️', '💨', '💧',
      '💦', '🫧', '☔️', '☂️', '🌊', '🌫️',
    ],
  ),
  EmojiCategory(
    name: 'Food & Drink',
    icon: Icons.restaurant_outlined,
    emojis: <String>[
      '🍏', '🍎', '🍐', '🍊', '🍋', '🍌', '🍉', '🍇', '🍓', '🫐',
      '🍈', '🍒', '🍑', '🥭', '🍍', '🥥', '🥝', '🍅', '🍆', '🥑',
      '🥦', '🥬', '🥒', '🌶️', '🫑', '🌽', '🥕', '🫒', '🧄', '🧅',
      '🥔', '🍠', '🫘', '🥐', '🥯', '🍞', '🥖', '🥨', '🧀', '🥚',
      '🍳', '🧈', '🥞', '🧇', '🥓', '🥩', '🍗', '🍖', '🦴', '🌭',
      '🍔', '🍟', '🍕', '🫓', '🥪', '🥙', '🧆', '🌮', '🌯', '🫔',
      '🥗', '🥘', '🫕', '🥫', '🫙', '🍝', '🍜', '🍲', '🍛', '🍣',
      '🍱', '🥟', '🦪', '🍤', '🍙', '🍚', '🍘', '🍥', '🥠', '🥮',
      '🍢', '🍡', '🍧', '🍨', '🍦', '🥧', '🧁', '🍰', '🎂', '🍮',
      '🍭', '🍬', '🍫', '🍿', '🍩', '🍪', '🌰', '🥜', '🫖', '☕️',
      '🍵', '🧃', '🥤', '🧋', '🍶', '🍺', '🍻', '🥂', '🍷', '🥃',
      '🍸', '🍹', '🧉', '🍾', '🧊', '🥄', '🍴', '🍽️', '🥢', '🥣',
    ],
  ),
  EmojiCategory(
    name: 'Travel & Places',
    icon: Icons.flight_outlined,
    emojis: <String>[
      '🚗', '🚕', '🚙', '🚌', '🚎', '🏎️', '🚓', '🚑', '🚒', '🚐',
      '🛻', '🚚', '🚛', '🚜', '🦯', '🦽', '🦼', '🛴', '🚲', '🛵',
      '🏍️', '🛺', '🚨', '🚔', '🚍', '🚘', '🚖', '🚡', '🚠', '🚟',
      '🚃', '🚋', '🚞', '🚝', '🚄', '🚅', '🚈', '🚂', '🚆', '🚇',
      '🚊', '🚉', '✈️', '🛫', '🛬', '🛩️', '💺', '🛰️', '🚀', '🛸',
      '🚁', '🛶', '⛵️', '🚤', '🛥️', '🛳️', '⛴️', '🚢', '⚓️', '🛟',
      '⛽️', '🚧', '🚦', '🚥', '🗺️', '🗿', '🗽', '🗼', '🏰', '🏯',
      '🏟️', '🎡', '🎢', '🎠', '⛲️', '⛱️', '🏖️', '🏝️', '🏜️', '🌋',
      '⛰️', '🏔️', '🗻', '🏕️', '⛺️', '🛖', '🏠', '🏡', '🏘️', '🏚️',
      '🏗️', '🏭', '🏢', '🏬', '🏣', '🏤', '🏥', '🏦', '🏨', '🏪',
      '🏫', '🏩', '💒', '🏛️', '⛪️', '🕌', '🛕', '🕍', '🕋', '⛩️',
      '🛤️', '🛣️', '🗾', '🎑', '🏞️', '🌅', '🌄', '🌠', '🏙️', '🌆',
      '🌇', '🌃', '🌌', '🌉', '🌁',
    ],
  ),
  EmojiCategory(
    name: 'Activities & Gaming',
    icon: Icons.sports_esports_outlined,
    emojis: <String>[
      '⚽️', '🏀', '🏈', '⚾️', '🥎', '🎾', '🏐', '🏉', '🥏', '🎱',
      '🪀', '🏓', '🏸', '🏒', '🏑', '🥍', '🏏', '🪃', '🥅', '⛳️',
      '🪁', '🏹', '🎣', '🤿', '🥊', '🥋', '🎽', '🛹', '🛼', '🛷',
      '⛸️', '🥌', '🎿', '⛷️', '🏂', '🪂', '🏋️', '🤼', '🤸', '⛹️',
      '🤺', '🤾', '🏌️', '🏇', '🧘', '🏄', '🏊', '🤽', '🚣', '🧗',
      '🚵', '🚴', '🏆', '🥇', '🥈', '🥉', '🏅', '🎖️', '🏵️', '🎗️',
      '🎫', '🎟️', '🎪', '🤹', '🎭', '🩰', '🎨', '🎬', '🎤', '🎧',
      '🎼', '🎹', '🥁', '🪘', '🎷', '🎺', '🪗', '🎸', '🪕', '🎻',
      '🎲', '♟️', '🎯', '🎳', '🎮', '🎰', '🧩',
    ],
  ),
  EmojiCategory(
    name: 'Objects & Tools',
    icon: Icons.lightbulb_outline,
    emojis: <String>[
      '📱', '📲', '☎️', '📞', '📟', '📠', '🔋', '🪫', '🔌', '💻',
      '🖥️', '🖨️', '⌨️', '🖱️', '🖲️', '💽', '💾', '💿', '📀', '📼',
      '📷', '📸', '📹', '🎥', '📽️', '🎞️', '📺', '📻', '🎙️', '🎚️',
      '🎛️', '⏱️', '⏲️', '⏰', '🕰️', '⌛️', '⏳', '📡', '💡', '🔦',
      '🕯️', '🪔', '🧯', '🛢️', '💸', '💵', '💴', '💶', '💷', '🪙',
      '💰', '💳', '💎', '⚖️', '🪜', '🧰', '🪛', '🔧', '🔨', '⚒️',
      '🛠️', '⛏️', '🪚', '🔩', '⚙️', '🪤', '🧱', '⛓️', '🧲', '🔫',
      '💣', '🧨', '🪓', '🔪', '🗡️', '⚔️', '🛡️', '🚬', '⚰️', '🪦',
      '⚱️', '🏺', '🔮', '📿', '🧿', '💈', '⚗️', '🔭', '🔬', '🕳️',
      '🩹', '🩺', '💊', '💉', '🩸', '🧬', '🦠', '🧫', '🧪', '🌡️',
      '🧹', '🪠', '🧺', '🧻', '🚽', '🚰', '🚿', '🛁', '🛀', '🧼',
      '🪥', '🪒', '🧽', '🪣', '🧴', '🛎️', '🔑', '🗝️', '🚪', '🪑',
      '🛋️', '🛏️', '🛌', '🧸', '🪆', '🖼️', '🪞', '🪟', '🛍️', '🛒',
      '🎁', '🎈', '🎏', '🎀', '🪄', '🪅', '🎊', '🎉', '🎎', '🏮',
      '🎐', '🧧', '✉️', '📩', '📨', '📧', '💌', '📮', '📦', '🏷️',
      '🪧', '📪', '📫', '📬', '📭', '📜', '📄', '📰', '🗞️', '📑',
      '🔖', '🧾', '📊', '📈', '📉', '🗒️', '🗓️', '📆', '📅', '📇',
      '🗃️', '🗳️', '🗄️', '📋', '📁', '📂', '🗂️', '📓', '📕', '📗',
      '📘', '📙', '📚', '📖', '🧷', '🔗', '📎', '🖇️', '📐', '📏',
      '🧮', '📌', '📍', '✂️', '🖊️', '🖋️', '✒️', '🖌️', '🖍️', '📝',
      '✏️', '🔍', '🔎', '🔏', '🔐', '🔒', '🔓',
    ],
  ),
  EmojiCategory(
    name: 'Symbols & Finance',
    icon: Icons.attach_money_outlined,
    emojis: <String>[
      '💰', '💳', '🧾', '💵', '💶', '💷', '💴', '💸', '🪙', '📈',
      '📉', '📊', '🏷️', '🏧', '💲', '💹', '💱', '🏦', '💎', '⚖️',
      '🔒', '🔓', '🔑', '🗝️', '❤️', '🧡', '💛', '💚', '💙', '💜',
      '🖤', '🤍', '🤎', '💔', '❣️', '💕', '💞', '💓', '💗', '💖',
      '💘', '💝', '💟', '☮️', '✝️', '☪️', '🕉️', '☸️', '✡️', '🔯',
      '🕎', '☯️', '☦️', '🛐', '⛎', '♈️', '♉️', '♊️', '♋️', '♌️',
      '♍️', '♎️', '♏️', '♐️', '♑️', '♒️', '♓️', '🆔', '⚛️', '🉑',
      '☢️', '☣️', '📴', '📳', '🈶', '🈚️', '🈸', '🈺', '🈷️', '✴️',
      '🆚', '💮', '🉐', '㊙️', '㊗️', '🈴', '🈵', '🈹', '🈲', '🅰️',
      '🅱️', '🆎', '🆑', '🅾️', '🆘', '❌', '⭕️', '🛑', '⛔️', '📛',
      '🚫', '💯', '💢', '♨️', '🚷', '🚯', '🚳', '🚱', '🔞', '📵',
      '🚭', '❗️', '❕', '❓', '❔', '‼️', '⁉️', '🔅', '🔆', '〽️',
      '⚠️', '🚸', '🔱', '⚜️', '🔰', '♻️', '✅', '🈯️', '❇️', '✳️',
      '❎', '🌐', '💠', 'Ⓜ️', '🌀', '💤', '🚾', '♿️', '🅿️', '🈳',
      '🈂️', '🛂', '🛃', '🛄', '🛅', '🚹', '🚺', '🚼', '⚧️', '🚻',
      '🚮', '🎦', '📶', '🈁', '🔣', 'ℹ️', '🔤', '🔡', '🔠', '🆖',
      '🆗', '🆙', '🆒', '🆕', '🆓', '0️⃣', '1️⃣', '2️⃣', '3️⃣', '4️⃣',
      '5️⃣', '6️⃣', '7️⃣', '8️⃣', '9️⃣', '🔟', '🔢', '#️⃣', '*️⃣', '⏏️',
      '▶️', '⏸️', '⏯️', '⏹️', '⏺️', '⏭️', '⏮️', '⏩', '⏪', '⏫',
      '⏬', '◀️', '🔼', '🔽', '➡️', '⬅️', '⬆️', '⬇️', '↗️', '↘️',
      '↙️', '↖️', '↕️', '↔️', '↪️', '↩️', '⤴️', '⤵️', '🔀', '🔁',
      '🔂', '🔄', '🔃', '🎵', '🎶', '➕', '➖', '➗', '✖️', '🟰',
      '♾️', '™️', '©️', '®️', '👁️‍🗨️', '🔚', '🔙', '🔛', '🔝', '🔜',
      '〰️', '➰', '➿', '✔️', '🔘', '🔴', '🟠', '🟡', '🟢', '🔵',
      '🟣', '⚫️', '⚪️', '🟤', '🔺', '🔻', '🔸', '🔹', '🔶', '🔷',
      '🔳', '🔲', '▪️', '▫️', '◾️', '◽️', '◼️', '◻️', '🟥', '🟧',
      '🟨', '🟩', '🟦', '🟪', '⬛️', '⬜️', '🟫', '🔈', '🔇', '🔉',
      '🔊', '🔔', '🔕', '📣', '📢',
    ],
  ),
  EmojiCategory(
    name: 'Flags',
    icon: Icons.flag_outlined,
    emojis: <String>[
      '🏁', '🚩', '🎌', '🏴', '🏳️', '🏳️‍🌈', '🏳️‍⚧️', '🏴‍☠️', '🇮🇳', '🇺🇸',
      '🇬🇧', '🇨🇦', '🇦🇺', '🇩🇪', '🇫🇷', '🇯🇵', '🇨🇳', '🇧🇷', '🇷🇺', '🇮🇹',
      '🇪🇸', '🇰🇷', '🇸🇬', '🇦🇪', '🇿🇦', '🇲🇽', '🇳🇿', '🇳🇱', '🇸🇪', '🇨🇭',
      '🇸🇦', '🇹🇷', '🇦🇷', '🇮🇩', '🇹🇭', '🇻🇳', '🇵🇭', '🇲🇾', '🇳🇬', '🇪🇬',
    ],
  ),
];

/// Keywords dictionary for fast emoji search.
const Map<String, List<String>> _emojiKeywords = <String, List<String>>{
  '☕️': <String>['coffee', 'tea', 'cafe', 'starbucks', 'drink', 'hot', 'breakfast', 'chai'],
  '☕': <String>['coffee', 'tea', 'cafe', 'starbucks', 'drink', 'hot', 'breakfast', 'chai'],
  '🍔': <String>['burger', 'food', 'fastfood', 'mcdonalds', 'dinner', 'lunch', 'eat', 'snack'],
  '🍕': <String>['pizza', 'food', 'cheese', 'italian', 'dominos', 'slice', 'dinner'],
  '🍟': <String>['fries', 'chips', 'potato', 'fastfood', 'snack', 'side'],
  '🛒': <String>['grocery', 'cart', 'shop', 'shopping', 'supermarket', 'market', 'store', 'blinkit', 'zepto'],
  '🛍️': <String>['shopping', 'bag', 'mall', 'clothes', 'fashion', 'store', 'buy', 'purchase', 'myntra', 'amazon'],
  '⛽️': <String>['fuel', 'gas', 'petrol', 'diesel', 'oil', 'station', 'car'],
  '⛽': <String>['fuel', 'gas', 'petrol', 'diesel', 'oil', 'station', 'car'],
  '💡': <String>['bill', 'light', 'electric', 'electricity', 'power', 'utility', 'energy', 'idea'],
  '✈️': <String>['flight', 'airplane', 'travel', 'trip', 'airline', 'vacation', 'airport', 'holiday'],
  '🎬': <String>['movie', 'cinema', 'theatre', 'film', 'show', 'entertainment', 'netflix'],
  '💊': <String>['medicine', 'health', 'pill', 'pharmacy', 'doctor', 'hospital', 'medical', 'drug'],
  '🏠': <String>['home', 'house', 'rent', 'flat', 'apartment', 'property', 'stay', 'building'],
  '🏋️': <String>['gym', 'fitness', 'workout', 'weights', 'sport', 'exercise', 'training', 'health'],
  '🚕': <String>['taxi', 'cab', 'uber', 'ola', 'rapido', 'car', 'ride', 'travel'],
  '🚗': <String>['car', 'automobile', 'vehicle', 'drive', 'transport', 'road'],
  '🎮': <String>['game', 'gaming', 'steam', 'playstation', 'xbox', 'controller', 'esports', 'fun'],
  '🐾': <String>['pet', 'dog', 'cat', 'paw', 'animal', 'vet', 'puppy', 'kitten'],
  '📚': <String>['book', 'education', 'school', 'college', 'study', 'course', 'tuition', 'read'],
  '🎁': <String>['gift', 'present', 'donation', 'charity', 'birthday', 'surprise'],
  '📺': <String>['tv', 'television', 'netflix', 'youtube', 'screen', 'subscription', 'stream'],
  '💻': <String>['laptop', 'computer', 'tech', 'work', 'code', 'electronics', 'apple', 'mac'],
  '📱': <String>['phone', 'mobile', 'cell', 'smartphone', 'recharge', 'call', 'device'],
  '✂️': <String>['scissors', 'salon', 'barber', 'hair', 'cut', 'grooming', 'beauty', 'spa'],
  '👗': <String>['dress', 'clothes', 'fashion', 'wear', 'shopping', 'outfit'],
  '💰': <String>['money', 'cash', 'salary', 'income', 'wealth', 'rich', 'dollar', 'rupee', 'profit'],
  '💳': <String>['card', 'credit', 'debit', 'payment', 'bank', 'visa', 'mastercard'],
  '🧾': <String>['receipt', 'bill', 'invoice', 'paper', 'tax', 'expense', 'account'],
  '📈': <String>['invest', 'stocks', 'mutual', 'crypto', 'growth', 'market', 'trade', 'share', 'chart'],
  '📉': <String>['loss', 'decline', 'down', 'bear', 'market', 'chart'],
  '🛡️': <String>['insurance', 'shield', 'protect', 'safety', 'security', 'policy', 'lic'],
  '🍻': <String>['beer', 'alcohol', 'bar', 'pub', 'cheers', 'drink', 'party', 'wine'],
  '🍜': <String>['noodles', 'ramen', 'soup', 'food', 'asian', 'dinner', 'lunch'],
  '🍎': <String>['apple', 'fruit', 'food', 'healthy', 'fresh', 'red'],
  '⚡️': <String>['power', 'lightning', 'energy', 'charge', 'fast', 'electric'],
  '🔧': <String>['tool', 'wrench', 'repair', 'maintenance', 'fix', 'hardware'],
  '📦': <String>['package', 'box', 'delivery', 'courier', 'amazon', 'order', 'parcel'],
  '🎓': <String>['graduation', 'degree', 'college', 'university', 'student', 'education'],
  '🏷️': <String>['tag', 'label', 'category', 'item', 'other', 'custom', 'price'],
};

/// Presents a WhatsApp-style emoji selection bottom sheet.
Future<String?> showEmojiPickerSheet(
  BuildContext context, {
  String? initialEmoji,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (BuildContext ctx) => _EmojiPickerSheetBody(
      initialEmoji: initialEmoji,
    ),
  );
}

class _EmojiPickerSheetBody extends StatefulWidget {
  const _EmojiPickerSheetBody({this.initialEmoji});

  final String? initialEmoji;

  @override
  State<_EmojiPickerSheetBody> createState() => _EmojiPickerSheetBodyState();
}

class _EmojiPickerSheetBodyState extends State<_EmojiPickerSheetBody>
    with SingleTickerProviderStateMixin {
  static const String _recentKey = 'theme.recent_emojis';
  final TextEditingController _searchCtrl = TextEditingController();
  final ScrollController _scrollCtrl = ScrollController();

  List<String> _recentEmojis = <String>[];
  String _searchQuery = '';
  int _selectedCategoryIndex = 0;
  bool _loadingRecents = true;

  @override
  void initState() {
    super.initState();
    _loadRecents();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadRecents() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final List<String>? stored = prefs.getStringList(_recentKey);
    if (mounted) {
      setState(() {
        _recentEmojis = stored ??
            <String>[
              '🛒', '🍔', '⛽', '🛍️', '💡', '✈️', '🎬', '💊',
              '☕', '🍕', '🍻', '🏠', '🏋️', '🚕', '🎮', '💰',
            ];
        _loadingRecents = false;
      });
    }
  }

  Future<void> _saveRecent(String emoji) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final updated = <String>[emoji, ..._recentEmojis.where((e) => e != emoji)]
        .take(24)
        .toList();
    await prefs.setStringList(_recentKey, updated);
  }

  void _onEmojiTapped(String emoji) {
    _saveRecent(emoji);
    Navigator.of(context).pop(emoji);
  }

  List<String> _filterEmojis(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return <String>[];

    final Set<String> results = <String>{};

    // 1. Direct keyword map match
    _emojiKeywords.forEach((emoji, keywords) {
      if (keywords.any((k) => k.contains(q))) {
        results.add(emoji);
      }
    });

    // 2. Category name match
    for (final cat in kWhatsAppEmojiCategories) {
      if (cat.name.toLowerCase().contains(q)) {
        results.addAll(cat.emojis);
      }
    }

    return results.toList();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final searchResults =
        _searchQuery.isNotEmpty ? _filterEmojis(_searchQuery) : null;

    return Container(
      height: MediaQuery.sizeOf(context).height * 0.75,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.4 : 0.15),
            blurRadius: 16,
            spreadRadius: 2,
          ),
        ],
      ),
      child: Column(
        children: <Widget>[
          // Drag handle & Header
          Center(
            child: Container(
              margin: const EdgeInsets.only(top: 8, bottom: 4),
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: <Widget>[
                Text(
                  'Choose Emoji',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.close, size: 20),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),

          // Search Bar
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Search emoji (e.g. coffee, burger, uber, cash)…',
                hintStyle: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
                ),
                prefixIcon: const Icon(Icons.search, size: 20),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                filled: true,
                fillColor: theme.colorScheme.surfaceContainerHighest
                    .withValues(alpha: 0.5),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              onChanged: (val) => setState(() => _searchQuery = val),
            ),
          ),
          const SizedBox(height: 8),

          // Category Navigation Tabs (WhatsApp style)
          if (_searchQuery.isEmpty)
            Container(
              height: 44,
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                  ),
                ),
              ),
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: <Widget>[
                  // Recents tab
                  _CategoryTab(
                    icon: Icons.history,
                    label: 'Recent',
                    isSelected: _selectedCategoryIndex == 0,
                    onTap: () {
                      setState(() => _selectedCategoryIndex = 0);
                      _scrollCtrl.animateTo(
                        0,
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOut,
                      );
                    },
                  ),
                  for (int i = 0; i < kWhatsAppEmojiCategories.length; i++)
                    _CategoryTab(
                      icon: kWhatsAppEmojiCategories[i].icon,
                      label: kWhatsAppEmojiCategories[i].name,
                      isSelected: _selectedCategoryIndex == i + 1,
                      onTap: () {
                        setState(() => _selectedCategoryIndex = i + 1);
                        // Approximate scroll offset calculation for fast jump
                        final targetOffset = 180.0 + (i * 260.0);
                        _scrollCtrl.animateTo(
                          targetOffset.clamp(0.0, _scrollCtrl.position.maxScrollExtent),
                          duration: const Duration(milliseconds: 300),
                          curve: Curves.easeOut,
                        );
                      },
                    ),
                ],
              ),
            ),

          // Emoji Grid Content
          Expanded(
            child: _loadingRecents
                ? const Center(child: CircularProgressIndicator())
                : searchResults != null
                    ? _buildSearchResultsGrid(searchResults, theme)
                    : _buildFullCatalogList(theme),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchResultsGrid(List<String> emojis, ThemeData theme) {
    if (emojis.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.search_off,
              size: 48,
              color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 8),
            Text(
              'No emojis matching "$_searchQuery"',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 7,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
      ),
      itemCount: emojis.length,
      itemBuilder: (BuildContext ctx, int i) => _EmojiButton(
        emoji: emojis[i],
        onTap: () => _onEmojiTapped(emojis[i]),
      ),
    );
  }

  Widget _buildFullCatalogList(ThemeData theme) {
    return ListView(
      controller: _scrollCtrl,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      children: <Widget>[
        // Recents section
        if (_recentEmojis.isNotEmpty) ...<Widget>[
          _SectionHeader('Recently Used'),
          _EmojiGrid(emojis: _recentEmojis, onSelect: _onEmojiTapped),
          const SizedBox(height: 16),
        ],

        // Category sections
        for (final cat in kWhatsAppEmojiCategories) ...<Widget>[
          _SectionHeader(cat.name),
          _EmojiGrid(emojis: cat.emojis, onSelect: _onEmojiTapped),
          const SizedBox(height: 16),
        ],
      ],
    );
  }
}

class _CategoryTab extends StatelessWidget {
  const _CategoryTab({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: isSelected ? theme.colorScheme.primary : Colors.transparent,
                width: 2.5,
              ),
            ),
          ),
          child: Icon(
            icon,
            size: 22,
            color: isSelected
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8.0, top: 4.0),
      child: Text(
        title,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _EmojiGrid extends StatelessWidget {
  const _EmojiGrid({
    required this.emojis,
    required this.onSelect,
  });

  final List<String> emojis;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final crossAxisCount = (constraints.maxWidth / 48).floor().clamp(6, 9);
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            mainAxisSpacing: 6,
            crossAxisSpacing: 6,
          ),
          itemCount: emojis.length,
          itemBuilder: (BuildContext ctx, int i) => _EmojiButton(
            emoji: emojis[i],
            onTap: () => onSelect(emojis[i]),
          ),
        );
      },
    );
  }
}

class _EmojiButton extends StatelessWidget {
  const _EmojiButton({
    required this.emoji,
    required this.onTap,
  });

  final String emoji;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        ),
        alignment: Alignment.center,
        child: Text(
          emoji,
          style: const TextStyle(fontSize: 24),
        ),
      ),
    );
  }
}
