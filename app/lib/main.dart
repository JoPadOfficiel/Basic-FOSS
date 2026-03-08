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

class AppState extends ChangeNotifier with WidgetsBindingObserver {
  var loggedIn = false;
  String? qrData;
  LoginStatus loginStatus = LoginStatus.idle;

  var _initialized = false;

  Timer? _pollTimer;
  int _pollGeneration = 0;
  bool _isForeground = true;

  AppState() {
    globalAppState = this;
    // Observe app lifecycle to pause/resume background polling
    WidgetsBinding.instance.addObserver(this);
    // Default to true: the app starts in the foreground, and no lifecycle
    // change event fires on initial launch (lifecycleState is null).
    _isForeground = WidgetsBinding.instance.lifecycleState != AppLifecycleState.paused
        && WidgetsBinding.instance.lifecycleState != AppLifecycleState.detached
        && WidgetsBinding.instance.lifecycleState != AppLifecycleState.inactive
        && WidgetsBinding.instance.lifecycleState != AppLifecycleState.hidden;
    if (!appStateReady.isCompleted) {
      appStateReady.complete();
    }
    print('AppState: created, initial foreground=$_isForeground');
  }

  Future<void> init({bool timed = false}) async {
    print('AppState.init called (timed=$timed)');
    if (_initialized && !timed) return;

    var success = false;
    try {
      var isLoggedIn = await oauth.isLoggedIn();
      if (!_isForeground) return; // app went to background during await
      if (isLoggedIn) {
        qrData = await qrutil.generateBasicQrData();
        if (!_isForeground) return; // app went to background during await
      }
      loggedIn = isLoggedIn;

      notifyListeners();

      success = true;
    } catch (e) {
      print('Error in init: $e');
    }

    if (!timed) {
      if (success) {
        _initialized = true;
      }
      _startPollTimer();
    }
  }

  void _startPollTimer() {
    _stopPollTimer();
    if (!_isForeground) {
      print('PollTimer: not starting because app is not foreground');
      return;
    }
    // _stopPollTimer() already bumped the generation, so capture the
    // current value — any older in-flight callback is already invalid.
    final int gen = _pollGeneration;
    const interval = Duration(seconds: 5);
    void scheduleNext() {
      if (gen != _pollGeneration) {
        print('PollTimer: stale generation ($gen != $_pollGeneration), not rescheduling');
        return;
      }
      if (!_isForeground) {
        print('PollTimer: not scheduling next because app not foreground');
        return;
      }
      print('PollTimer: scheduling one-shot (5s) [gen=$gen]');
      _pollTimer = Timer(interval, () async {
        if (gen != _pollGeneration || !_isForeground) {
          print('PollTimer: fired but stale/backgrounded, skipping [gen=$gen, current=$_pollGeneration, fg=$_isForeground]');
          return;
        }
        print('PollTimer: fired — calling init(timed: true) [gen=$gen]');
        await init(timed: true);
        scheduleNext();
      });
    }

    scheduleNext();
  }

  void _stopPollTimer() {
    if (_pollTimer != null) {
      print('PollTimer: stopping');
    }
    _pollTimer?.cancel();
    _pollTimer = null;
    // Invalidate any in-flight async callbacks from the previous chain
    _pollGeneration++;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    print('Lifecycle: didChangeAppLifecycleState -> $state');
    if (state == AppLifecycleState.resumed) {
      _isForeground = true;
      Future.microtask(() => refreshQrCode());
      _startPollTimer();
    } else {
      _isForeground = false;
      _stopPollTimer();
    }
  }

  @override
  void dispose() {
    print('AppState: dispose');
    WidgetsBinding.instance.removeObserver(this);
    _stopPollTimer();
    super.dispose();
  }

  Future<void> refreshQrCode() async {
    print('AppState.refreshQrCode called');
    if (!_isForeground) return;
    try {
      var isLoggedIn = await oauth.isLoggedIn();
      if (!_isForeground) return; // app went to background during await
      if (isLoggedIn) {
        qrData = await qrutil.generateBasicQrData();
        if (!_isForeground) return; // app went to background during await
        print('refreshQrCode: updated qrData length=${qrData?.length ?? 0}');
        loginStatus = LoginStatus.idle;
      } else {
        qrData = null;
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
          ? (appState.qrData != null
            ? QrImageView(
              data: appState.qrData!,
              version: QrVersions.auto,
              errorCorrectionLevel: QrErrorCorrectLevel.M,
              )
            : const Text('Generating QR code...'))
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
