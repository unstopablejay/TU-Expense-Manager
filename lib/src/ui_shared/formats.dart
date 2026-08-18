/// How money and timestamps are spelled, wherever they are shown.
library;

import 'package:intl/intl.dart';

/// Rupees, as every screen shows them.
///
/// A function rather than a shared instance: `NumberFormat` is mutable, so one
/// instance handed to several screens is a shared object any of them could
/// reconfigure for all the others.
NumberFormat appMoneyFormat() =>
    NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 2);

/// A transaction's timestamp, as the tiles show it.
DateFormat appDateFormat() => DateFormat('dd MMM yyyy · h:mm a');
