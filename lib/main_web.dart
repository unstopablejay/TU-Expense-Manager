/// TU Expense Tracker, in a browser.
///
/// The web entrypoint. Renders the same Dashboard and Transactions screens the
/// phone does, from a snapshot the phone pushed to a self-hosted server, rather
/// than from a database it does not have.
///
/// Imports only `src/core`, `src/ui_shared` and `src/web` — never `main.dart` and
/// never `src/mobile`, both of which reach for sqflite and the SMS plugin. That
/// boundary is enforced by `test/purity_test.dart` rather than by good intentions.
library;

import 'package:flutter/material.dart';

import 'src/ui_shared/theme_controller.dart';
import 'src/web/api_client.dart';
import 'src/web/login_screen.dart';
import 'src/web/session.dart';
import 'src/web/web_shell.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await ThemeController.instance.load();
  runApp(const WebApp());
}

class WebApp extends StatefulWidget {
  const WebApp({super.key});

  @override
  State<WebApp> createState() => _WebAppState();
}

class _WebAppState extends State<WebApp> {
  /// One client and one session for the app's life.
  ///
  /// The client holds the token in memory and the session persists it; keeping
  /// them here means a sign-out from anywhere reaches both.
  final ApiClient _api = ApiClient();
  final WebSession _session = WebSession();

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSessionChanged);
    _restore();
  }

  @override
  void dispose() {
    _session.removeListener(_onSessionChanged);
    _session.dispose();
    super.dispose();
  }

  Future<void> _restore() async {
    await _session.restore();
    _api.token = _session.token;
    if (mounted) setState(() {});
  }

  void _onSessionChanged() {
    // The client's copy of the token has to follow the session's, since an
    // expiry discovered mid-call signs out from underneath whatever asked.
    _api.token = _session.token;
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: ThemeController.instance,
      builder: (BuildContext context, Widget? child) {
        return MaterialApp(
          title: 'TU Expense Tracker',
          debugShowCheckedModeBanner: false,
          theme: ThemeController.instance.lightTheme,
          darkTheme: ThemeController.instance.darkTheme,
          themeMode: ThemeController.instance.flutterThemeMode,
          home: !_session.restored
              // A blank frame rather than a login form, so someone already signed
              // in is never shown one for an instant on every page load.
              ? const Scaffold(body: Center(child: CircularProgressIndicator()))
              : _session.signedIn
                  ? WebShell(api: _api, session: _session)
                  : LoginScreen(api: _api, session: _session),
        );
      },
    );
  }
}
