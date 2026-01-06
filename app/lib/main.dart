import 'dart:async';
import 'package:flutter/material.dart';
import 'package:app_links/app_links.dart';
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'oauth.dart' as oauth;
import 'qr.dart' as qrutil;

final appLinks = AppLinks();
AppState? globalAppState;
final Completer<void> appStateReady = Completer<void>();

enum LoginStatus { idle, loggingIn, failed }

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  runApp(const App());

  appLinks.uriLinkStream.listen((uri) async {
    try {
      await appStateReady.future;
      // Schedule the OAuth code processing to not block the main thread
      Future.microtask(() => oauth.code(uri));
    } catch (e) {
      print('Error processing deep link: $e');
    }
  });

  appLinks.getInitialLink().then((uri) async {
    try {
      await appStateReady.future;
      if (uri != null) {
        // Schedule the OAuth code processing to not block the main thread
        Future.microtask(() => oauth.code(uri));
      } else {
        if (!await oauth.isLoggedIn()) {
          oauth.login();
        }
      }
    } catch (e) {
      print('Error processing initial link: $e');
    }
  });
}

class App extends StatelessWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (context) => AppState(),
      child: MaterialApp(
        title: 'Basic-FOSS',
        theme: ThemeData(colorScheme: ColorScheme.highContrastLight()),
        darkTheme: ThemeData(
          colorScheme: ColorScheme.highContrastDark(surface: Colors.black),
        ),
        home: const Main(),
      ),
    );
  }
}

class AppState extends ChangeNotifier {
  var loggedIn = false;
  QrImageView? qr;
  LoginStatus loginStatus = LoginStatus.idle;

  var _initialized = false;

  AppState() {
    globalAppState = this;
    if (!appStateReady.isCompleted) {
      appStateReady.complete();
    }
  }

  Future<void> init({bool timed = false}) async {
    if (_initialized && !timed) return;
    _initialized = true;

    try {
      var isLoggedIn = await oauth.isLoggedIn();
      if (isLoggedIn) {
        qr = await qrutil.generateBasicQrCode();
      }
      loggedIn = isLoggedIn;

      notifyListeners();

      if (!timed) {
        Timer.periodic(const Duration(seconds: 5), (_) async {
          await init(timed: true);
        });
      }
    } catch (e) {
      print('Error in init: $e');
    }
  }

  Future<void> refreshQrCode() async {
    try {
      var isLoggedIn = await oauth.isLoggedIn();
      if (isLoggedIn) {
        qr = await qrutil.generateBasicQrCode();
        loginStatus = LoginStatus.idle;
      } else {
        qr = null;
      }
      loggedIn = isLoggedIn;
      notifyListeners();
    } catch (e) {
      print('Error in refreshQrCode: $e');
    }
  }

  void setLoginStatus(LoginStatus status) {
    loginStatus = status;
    notifyListeners();
  }
}

class Main extends StatefulWidget {
  const Main({super.key});

  @override
  State<Main> createState() => _MainState();
}

class _MainState extends State<Main> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<AppState>().init();
    });
  }

  @override
  Widget build(BuildContext context) {
    var appState = context.watch<AppState>();

    String getStatusText() {
      switch (appState.loginStatus) {
        case LoginStatus.loggingIn:
          return 'Logging in...';
        case LoginStatus.failed:
          return 'Login failed';
        case LoginStatus.idle:
          return 'Not logged in';
      }
    }

    return Scaffold(
      body: Center(
        child: appState.loggedIn
            ? (appState.qr ?? const Text('Generating QR code...'))
            : Text(getStatusText()),
      ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          if (appState.loggedIn)
            Padding(
              padding: const EdgeInsets.only(bottom: 16.0),
              child: FloatingActionButton(
                onPressed: oauth.openFriendsPage,
                tooltip: 'Friends',
                child: const Icon(Icons.people),
              ),
            ),
          FloatingActionButton(
            onPressed: appState.loggedIn ? oauth.logout : oauth.login,
            tooltip: appState.loggedIn ? 'Logout' : 'Login',
            child: Icon(appState.loggedIn ? Icons.logout : Icons.login),
          ),
        ],
      ),
    );
  }
}
