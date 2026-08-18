/// Reading bank alerts off the device.
///
/// Android only, and degrades quietly everywhere else — [SmsSource.isSupported]
/// is false rather than throwing, so the rest of the app needs no platform
/// checks of its own.
library;

import 'package:another_telephony/telephony.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:permission_handler/permission_handler.dart';


/// An SMS body together with when it landed on the device. The arrival time is
/// what gives UPI alerts — which carry a date but no clock time — a sensible
/// position in the ledger.
class InboxSms {
  const InboxSms(this.body, this.receivedAt);

  final String body;
  final DateTime? receivedAt;
}

class SmsSource {
  final Telephony _telephony = Telephony.instance;

  bool get isSupported => defaultTargetPlatform == TargetPlatform.android;

  Future<bool> requestPermission() async {
    if (!isSupported) return false;
    final status = await Permission.sms.request();
    return status.isGranted;
  }

  /// Live listener for new alerts while the app is in the foreground.
  void listen(void Function(InboxSms sms) onMessage) {
    if (!isSupported) return;
    try {
      _telephony.listenIncomingSms(
        onNewMessage: (SmsMessage message) {
          final body = message.body;
          if (body != null) onMessage(InboxSms(body, _timestampOf(message)));
        },
        listenInBackground: false,
      );
    } catch (_) {
      // Plugin unavailable (e.g. running on a desktop target) — ignore.
    }
  }

  /// Reads the inbox. With [since] the query is narrowed to messages newer than
  /// that instant, which is what turns every scan after the first into a cheap
  /// look at only what has arrived. The filter is a real `WHERE` on the SMS
  /// content provider, not a fetch-everything-then-discard.
  Future<List<InboxSms>> readInbox({DateTime? since}) async {
    if (!isSupported) return const <InboxSms>[];
    try {
      final messages = await _telephony.getInboxSms(
        columns: <SmsColumn>[SmsColumn.ADDRESS, SmsColumn.BODY, SmsColumn.DATE],
        filter: since == null
            ? null
            : SmsFilter.where(SmsColumn.DATE)
                .greaterThan(since.millisecondsSinceEpoch.toString()),
      );
      return messages
          .map((SmsMessage m) {
            final body = m.body;
            return body == null ? null : InboxSms(body, _timestampOf(m));
          })
          .whereType<InboxSms>()
          .toList();
    } catch (_) {
      return const <InboxSms>[];
    }
  }

  /// `SmsMessage.date` is epoch milliseconds, or null when the provider did not
  /// supply it.
  static DateTime? _timestampOf(SmsMessage message) {
    final date = message.date;
    return date == null ? null : DateTime.fromMillisecondsSinceEpoch(date);
  }
}
