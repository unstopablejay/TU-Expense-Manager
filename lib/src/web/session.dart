/// Remembering that you are signed in, between page loads.
///
/// The token lives in `shared_preferences`, which on web is `localStorage`. It is
/// a bearer credential readable by any script on this origin — acceptable here
/// because the origin is a LAN or VPN-only host serving nothing but this app, and
/// because the alternative is retyping a password on every refresh. Two things
/// make it defensible rather than merely convenient: the password itself is never
/// stored, and signing out clears the token so a shared machine can be left.
library;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The stored token's key.
///
/// The same name the phone uses for its own sync settings, so the two halves read
/// alike. On web the browser key is `flutter.sync.token`, per origin.
const String kTokenKey = 'sync.token';
const String kUsernameKey = 'sync.username';

/// Whether there is a session, and the means to end it.
///
/// A [ChangeNotifier] rather than plain state: the API client can discover a
/// token has expired in the middle of any call, and every screen needs to hear
/// about it from wherever that happened.
class WebSession extends ChangeNotifier {
  WebSession();

  String? _token;
  String? _username;
  bool _restored = false;

  String? get token => _token;
  String? get username => _username;

  /// Whether the stored session has been looked for yet.
  ///
  /// The first frame must not show a login form to someone who is already signed
  /// in, so the app waits for this rather than assuming signed-out.
  bool get restored => _restored;

  bool get signedIn => _token != null;

  /// Reads any stored session.
  Future<void> restore() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    _token = prefs.getString(kTokenKey);
    _username = prefs.getString(kUsernameKey);
    _restored = true;
    notifyListeners();
  }

  Future<void> signIn(String token, String username) async {
    _token = token;
    _username = username;
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.setString(kTokenKey, token);
    await prefs.setString(kUsernameKey, username);
    notifyListeners();
  }

  /// Forgets the session.
  ///
  /// Notifies first and writes after, so the UI leaves immediately rather than
  /// waiting on a disk write to show a signed-out screen.
  void signOut() {
    _token = null;
    _username = null;
    notifyListeners();
    SharedPreferences.getInstance().then((SharedPreferences prefs) async {
      await prefs.remove(kTokenKey);
      await prefs.remove(kUsernameKey);
    });
  }
}
