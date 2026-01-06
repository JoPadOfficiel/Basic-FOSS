import 'package:url_launcher/url_launcher.dart';
import 'package:crypto/crypto.dart';
import 'dart:math';
import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'dart:io';
import 'main.dart' show globalAppState, LoginStatus;

// String redirectUri = 'com.basicfit.trainingapp:/oauthredirect';
// String clientId = 'hMN33iw3DpHNg5VQaeNKoRUQKmIIvQV5vxOKba8AnrM';

// use iOS values on android, to prevent clashing redirect with both apps installed
String redirectUri = 'com.basicfit.bfa:/oauthredirect';
String clientId = 'q6KqjlQINmjOC86rqt9JdU_i41nhD_Z4DwygpBxGiIs';

final storage = FlutterSecureStorage();

String? _lastProcessedCode;

String generateCodeVerifier([int length = 128]) {
  const charset =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
  final rand = Random.secure();
  return List.generate(
    length,
    (_) => charset[rand.nextInt(charset.length)],
  ).join();
}

String generateCodeChallenge(String codeVerifier) {
  return base64UrlEncode(
    sha256.convert(utf8.encode(codeVerifier)).bytes,
  ).replaceAll('=', '');
}

Future<void> login() async {
  globalAppState?.setLoginStatus(LoginStatus.loggingIn);

  String codeVerifier = generateCodeVerifier();
  String codeChallenge = generateCodeChallenge(codeVerifier);

  if (!await launchUrl(
    Uri.parse(
      'https://login.basic-fit.com/?redirect_uri=${Uri.encodeComponent(redirectUri)}&client_id=${Uri.encodeComponent(clientId)}&response_type=code&app=true&code_challenge=${Uri.encodeComponent(codeChallenge)}&code_challenge_method=S256',
    ),
    mode: LaunchMode.inAppBrowserView,
  )) {
    globalAppState?.setLoginStatus(LoginStatus.failed);
    throw Exception('Could not open browser.');
  } else {
    await storage.write(key: "code_verifier", value: codeVerifier);
  }
}

Future<void> code(Uri uri) async {
  try {
    // Close the in-app browser first to free up the UI
    closeInAppWebView();

    // Small delay to let the browser close
    await Future.delayed(const Duration(milliseconds: 100));

    globalAppState?.setLoginStatus(LoginStatus.loggingIn);

    String? code = uri.queryParameters['code'];
    if (code == null) {
      return;
    }

    // Prevent processing the same code twice
    if (code == _lastProcessedCode) {
      return;
    }
    _lastProcessedCode = code;

    String? codeVerifier = await storage.read(key: "code_verifier");
    if (codeVerifier == null) {
      print('No code verifier found');
      globalAppState?.setLoginStatus(LoginStatus.failed);
      return;
    } else {
      await storage.delete(key: "code_verifier");
    }

    // Perform token exchange in a microtask to avoid blocking
    await _performTokenExchange(code, codeVerifier);
  } catch (e) {
    print('Error in code(): $e');
    globalAppState?.setLoginStatus(LoginStatus.failed);
  }
}

Future<void> _performTokenExchange(String code, String codeVerifier) async {
  HttpClient httpClient = HttpClient();
  try {
    HttpClientRequest tokenExchange = await httpClient.postUrl(
      Uri.parse('https://auth.basic-fit.com/token'),
    );
    tokenExchange.headers.set(
      "Content-Type",
      'application/x-www-form-urlencoded',
    );

    tokenExchange.write(
      'redirect_uri=${Uri.encodeComponent(redirectUri)}&client_id=${Uri.encodeComponent(clientId)}&grant_type=authorization_code&code=${Uri.encodeComponent(code)}&code_verifier=${Uri.encodeComponent(codeVerifier)}',
    );
    HttpClientResponse response = await tokenExchange.close();
    String responseBody = await response.transform(utf8.decoder).join();

    if (response.statusCode == 200) {
      Map<String, dynamic> jsonResponse = jsonDecode(responseBody);
      String accessToken = jsonResponse['access_token'];
      String refreshToken = jsonResponse['refresh_token'];

      await storage.write(key: "access_token", value: accessToken);
      await storage.write(key: "refresh_token", value: refreshToken);

      // print('Access Token: $accessToken');
      // print('Refresh Token: $refreshToken');

      await _fetchMemberInfo(httpClient, accessToken);
    } else {
      globalAppState?.setLoginStatus(LoginStatus.failed);
      throw Exception('Failed to get tokens: $responseBody');
    }
  } finally {
    httpClient.close();
  }
}

Future<void> _fetchMemberInfo(HttpClient httpClient, String accessToken) async {
  var memberInfoRequest = await httpClient.getUrl(
    Uri.parse('https://bfa.basic-fit.com/api/member/info'),
  );
  memberInfoRequest.headers.set('Authorization', 'Bearer $accessToken');
  memberInfoRequest.headers.set('Bfa-Version', '1.79.5.2738');
  memberInfoRequest.headers.set(
    'User-Agent',
    'Basic Fit App/1.79.5.2738 (Android)',
  );
  memberInfoRequest.headers.set('Client-Id', clientId);
  memberInfoRequest.headers.set('Redirect-Uri', redirectUri);
  var memberInfoResponse = await memberInfoRequest.close();
  String memberInfoResponseBody = await memberInfoResponse
      .transform(utf8.decoder)
      .join();
  if (memberInfoResponse.statusCode == 200) {
    Map<String, dynamic> memberInfoJson = jsonDecode(memberInfoResponseBody);

    if (memberInfoJson['member']?['deviceId'] != null &&
        memberInfoJson['member']?['cardnumber'] != null) {
      // print('Device ID: ${memberInfoJson['member']['deviceId']}');
      await storage.write(
        key: "device_id",
        value: memberInfoJson['member']['deviceId'],
      );

      // print('Card Number: ${memberInfoJson['member']['cardnumber']}');
      await storage.write(
        key: "card_number",
        value: memberInfoJson['member']['cardnumber'],
      );

      // Immediately refresh the QR code after successful login
      await globalAppState?.refreshQrCode();
    } else {
      globalAppState?.setLoginStatus(LoginStatus.failed);
    }
  } else {
    globalAppState?.setLoginStatus(LoginStatus.failed);
  }
}

Future<bool> isLoggedIn() async {
  String? accessToken = await storage.read(key: "access_token");
  String? refreshToken = await storage.read(key: "refresh_token");
  String? deviceId = await storage.read(key: "device_id");
  String? cardNumber = await storage.read(key: "card_number");
  return accessToken != null &&
      refreshToken != null &&
      deviceId != null &&
      cardNumber != null;
}

/// Decodes the payload of a JWT token without verification
Map<String, dynamic>? decodeJwtPayload(String token) {
  try {
    final parts = token.split('.');
    if (parts.length != 3) return null;

    final payload = parts[1];
    // Add padding if needed
    final normalized = base64Url.normalize(payload);
    final decoded = utf8.decode(base64Url.decode(normalized));
    return jsonDecode(decoded);
  } catch (e) {
    return null;
  }
}

/// Checks if the access token is expired or will expire within [bufferSeconds]
Future<bool> isTokenExpired({int bufferSeconds = 60}) async {
  String? accessToken = await storage.read(key: "access_token");
  if (accessToken == null) return true;

  final payload = decodeJwtPayload(accessToken);
  if (payload == null || payload['exp'] == null) return true;

  final exp = payload['exp'] as int;
  final expiryTime = DateTime.fromMillisecondsSinceEpoch(exp * 1000);
  final now = DateTime.now().add(Duration(seconds: bufferSeconds));

  return now.isAfter(expiryTime);
}

/// Refreshes the access token using the stored refresh token
Future<bool> refreshAccessToken() async {
  String? refreshToken = await storage.read(key: "refresh_token");
  if (refreshToken == null) return false;

  HttpClient httpClient = HttpClient();
  try {
    HttpClientRequest request = await httpClient.postUrl(
      Uri.parse('https://auth.basic-fit.com/token'),
    );
    request.headers.set("Content-Type", 'application/x-www-form-urlencoded');
    request.headers.set("Accept", 'application/json');

    request.write(
      'refresh_token=${Uri.encodeComponent(refreshToken)}&grant_type=refresh_token&redirect_uri=${Uri.encodeComponent(redirectUri)}&client_id=${Uri.encodeComponent(clientId)}',
    );

    HttpClientResponse response = await request.close();
    String responseBody = await response.transform(utf8.decoder).join();

    if (response.statusCode == 200) {
      Map<String, dynamic> jsonResponse = jsonDecode(responseBody);
      String newAccessToken = jsonResponse['access_token'];
      String newRefreshToken = jsonResponse['refresh_token'];

      await storage.write(key: "access_token", value: newAccessToken);
      await storage.write(key: "refresh_token", value: newRefreshToken);

      print('Token refreshed successfully');
      return true;
    } else {
      print('Failed to refresh token: $responseBody');
      return false;
    }
  } catch (e) {
    print('Error refreshing token: $e');
    return false;
  } finally {
    httpClient.close();
  }
}

/// Ensures a valid access token is available, refreshing if necessary
Future<String?> getValidAccessToken() async {
  if (await isTokenExpired()) {
    bool refreshed = await refreshAccessToken();
    if (!refreshed) return null;
  }
  return await storage.read(key: "access_token");
}

/// Opens the friends page in an in-app browser
Future<void> openFriendsPage() async {
  String? accessToken = await getValidAccessToken();
  if (accessToken == null) {
    throw Exception('No valid access token available');
  }

  if (!await launchUrl(
    Uri.parse(
      'https://my.basic-fit.com/sso?token=${Uri.encodeComponent(accessToken)}&returl=%2Ffriends%3Fapp%3Dtrue',
    ),
    mode: LaunchMode.inAppBrowserView,
  )) {
    throw Exception('Could not open browser.');
  }
}

/// Logs out by clearing all stored credentials
Future<void> logout() async {
  await storage.delete(key: "access_token");
  await storage.delete(key: "refresh_token");
  await storage.delete(key: "device_id");
  await storage.delete(key: "card_number");
  await storage.delete(key: "code_verifier");

  // Update UI state
  await globalAppState?.refreshQrCode();
}
