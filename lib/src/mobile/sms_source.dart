/// Reading bank alerts off the device (SMS & MMS / RCS).
///
/// Android only, and degrades quietly everywhere else — [SmsSource.isSupported]
/// is false rather than throwing, so the rest of the app needs no platform
/// checks of its own.
library;

import 'package:another_telephony/telephony.dart';
import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:permission_handler/permission_handler.dart';

/// An SMS or MMS/RCS body together with when it landed on the device. The arrival time is
/// what gives UPI alerts — which carry a date but no clock time — a sensible
/// position in the ledger.
class InboxSms {
  const InboxSms(this.body, this.receivedAt);

  final String body;
  final DateTime? receivedAt;
}

class SmsSource {
  SmsSource({
    this.telephony,
    MethodChannel? channel,
  }) : _channel = channel ?? const MethodChannel('com.tu.expense.manager/telephony');

  final Telephony? telephony;
  final MethodChannel _channel;
  Telephony get _telephonyInstance => telephony ?? Telephony.instance;

  void Function(InboxSms sms)? _listener;
  bool _isListening = false;

  /// Retains recent incoming SMS signatures with their receipt timestamps to
  /// filter out duplicate broadcast events from multi-part SMS or carrier re-deliveries.
  final Map<String, DateTime> _recentlyReceived = <String, DateTime>{};

  bool get isSupported => defaultTargetPlatform == TargetPlatform.android;

  Future<bool> requestPermission() async {
    if (!isSupported) return false;
    final status = await Permission.sms.request();
    return status.isGranted;
  }

  /// Live listener for new alerts while the app is in the foreground.
  void listen(void Function(InboxSms sms) onMessage) {
    _listener = onMessage;
    if (!isSupported || _isListening) return;
    try {
      _isListening = true;
      _telephonyInstance.listenIncomingSms(
        onNewMessage: (SmsMessage message) {
          final body = message.body;
          if (body != null) {
            final sms = InboxSms(body, _timestampOf(message));
            _dispatchIncoming(sms);
          }
        },
        listenInBackground: false,
      );
    } catch (_) {
      _isListening = false;
      // Plugin unavailable (e.g. running on a desktop target) — ignore.
    }

    try {
      _channel.setMethodCallHandler((MethodCall call) async {
        if (call.method == 'onIncomingMessage') {
          final dynamic args = call.arguments;
          if (args is Map) {
            final body = args['body'] as String?;
            final dateMillis = args['date'] as int?;
            if (body != null && body.isNotEmpty) {
              final receivedAt = dateMillis == null
                  ? null
                  : DateTime.fromMillisecondsSinceEpoch(dateMillis);
              onMessage(InboxSms(body, receivedAt));
            }
          }
        }
      });
      _channel.invokeMethod<void>('startListening').catchError((_) {});
    } catch (_) {
      // Plugin unavailable
    }
  }

  void _dispatchIncoming(InboxSms sms) {
    final now = DateTime.now();
    _recentlyReceived.removeWhere(
      (String _, DateTime seenAt) => now.difference(seenAt).inSeconds > 60,
    );

    final String key =
        '${sms.body.trim()}|${sms.receivedAt?.millisecondsSinceEpoch ?? 0}';
    if (_recentlyReceived.containsKey(key)) {
      return; // Duplicate broadcast dropped
    }
    _recentlyReceived[key] = now;
    _listener?.call(sms);
  }

  /// Simulates an incoming SMS message for testing or previewing.
  void simulateIncomingSms(InboxSms sms) {
    _dispatchIncoming(sms);
  }

  /// Reads the inbox (both SMS and MMS/RCS messages). With [since] the query
  /// is narrowed to messages newer than that instant.
  Future<List<InboxSms>> readInbox({DateTime? since}) async {
    if (!isSupported) return const <InboxSms>[];

    try {
      final dynamic rawMessages = await _channel.invokeMethod<dynamic>(
        'readInbox',
        <String, Object?>{
          if (since != null) 'since': since.millisecondsSinceEpoch,
        },
      );
      if (rawMessages is List && rawMessages.isNotEmpty) {
        return rawMessages
            .whereType<Map>()
            .map((Map m) {
              final body = m['body'] as String?;
              final dateMillis = m['date'] as int?;
              if (body == null || body.isEmpty) return null;
              final receivedAt = dateMillis == null
                  ? null
                  : DateTime.fromMillisecondsSinceEpoch(dateMillis);
              return InboxSms(body, receivedAt);
            })
            .whereType<InboxSms>()
            .toList();
      }
    } catch (_) {
      // Fallback to telephony plugin if native channel is unavailable
    }

    try {
      final messages = await _telephonyInstance.getInboxSms(
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
