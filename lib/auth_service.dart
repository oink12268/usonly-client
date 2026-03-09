import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'windows_oauth_config.dart';

// ⚠️ 개발용 - Google 로그인 최초 1회 후 자동 연결됨
const _devPassword = 'dev-usonly-1234';

const _windowsClientId = windowsClientId;
const _windowsClientSecret = windowsClientSecret;

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // Calendar 스코프 포함한 GoogleSignIn (static으로 공유)
  static final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: [
      'email',
      'https://www.googleapis.com/auth/calendar',
    ],
  );

  // Google Calendar 토큰 캐시
  static String? _cachedAccessToken;
  static DateTime? _tokenExpiry;
  static String? _windowsRefreshToken; // Windows 전용

  /// Google Calendar API용 액세스 토큰 반환.
  /// 만료 시 자동 갱신. 권한 없으면 null 반환.
  static Future<String?> getGoogleAccessToken() async {
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      return _getWindowsToken();
    }

    // Mobile: google_sign_in에서 토큰 획득 (자동 갱신 포함)
    try {
      var account = _googleSignIn.currentUser;
      account ??= await _googleSignIn.signInSilently();
      if (account == null) return null;

      // Calendar 스코프 미승인 시 요청
      final hasScope = await _googleSignIn.requestScopes(
        ['https://www.googleapis.com/auth/calendar'],
      );
      if (!hasScope) return null;

      final auth = await account.authentication;
      return auth.accessToken;
    } catch (e) {
      print('Google Calendar 토큰 획득 실패: $e');
      return null;
    }
  }

  static Future<String?> _getWindowsToken() async {
    // 캐시된 토큰이 유효하면 (5분 여유) 바로 반환
    if (_cachedAccessToken != null &&
        _tokenExpiry != null &&
        _tokenExpiry!.isAfter(DateTime.now().add(const Duration(minutes: 5)))) {
      return _cachedAccessToken;
    }

    if (_windowsRefreshToken != null) {
      return _refreshWindowsToken();
    }
    return null;
  }

  static Future<String?> _refreshWindowsToken() async {
    try {
      final response = await http.post(
        Uri.parse('https://oauth2.googleapis.com/token'),
        headers: {'Content-Type': 'application/x-www-form-urlencoded'},
        body: {
          'client_id': _windowsClientId,
          'client_secret': _windowsClientSecret,
          'refresh_token': _windowsRefreshToken!,
          'grant_type': 'refresh_token',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        _cachedAccessToken = data['access_token'] as String?;
        final expiresIn = data['expires_in'] as int? ?? 3600;
        _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));
        return _cachedAccessToken;
      }
    } catch (e) {
      print('Windows 토큰 갱신 실패: $e');
    }
    return null;
  }

  Future<User?> signInWithGoogle() async {
    try {
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
        return await _signInWindowsGoogle();
      }

      // Mobile
      final googleUser = await _googleSignIn.signIn();
      if (googleUser == null) return null;

      final googleAuth = await googleUser.authentication;
      final credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );
      final userCredential = await _auth.signInWithCredential(credential);
      if (kDebugMode) await _linkDevPassword(userCredential.user);
      return userCredential.user;
    } catch (e) {
      print("로그인 실패: $e");
      rethrow;
    }
  }

  // debug 전용: Google 로그인 후 Email/Password 연결 (최초 1회)
  Future<void> _linkDevPassword(User? user) async {
    if (user == null) return;
    final hasEmailProvider = user.providerData.any((p) => p.providerId == 'password');
    if (hasEmailProvider) return;

    try {
      final credential = EmailAuthProvider.credential(
        email: user.email!,
        password: _devPassword,
      );
      await user.linkWithCredential(credential);
      print('[DEV] Email/Password 연결 완료 → 다음부터 Dev 버튼 사용 가능');
    } catch (e) {
      print('[DEV] Email/Password 연결 실패 (무시): $e');
    }
  }

  // Windows: 로컬 HTTP 서버 + PKCE OAuth 플로우
  // Calendar 스코프 포함, access_type=offline으로 refresh_token 획득
  Future<User?> _signInWindowsGoogle() async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;

    final codeVerifier = _generateCodeVerifier();
    final codeChallenge = _generateCodeChallenge(codeVerifier);

    final authUrl = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
      'client_id': _windowsClientId,
      'redirect_uri': 'http://localhost:$port',
      'response_type': 'code',
      'scope': 'email profile openid https://www.googleapis.com/auth/calendar',
      'code_challenge': codeChallenge,
      'code_challenge_method': 'S256',
      'access_type': 'offline',
      'prompt': 'consent', // refresh_token 발급 위해 항상 동의 화면 표시
    });

    await launchUrl(authUrl, mode: LaunchMode.externalApplication);

    String? code;
    try {
      await for (final request in server.timeout(const Duration(minutes: 3))) {
        code = request.uri.queryParameters['code'];
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.html
          ..write('''
            <html><body style="font-family:sans-serif;text-align:center;padding:60px">
              <h2>✅ 로그인 완료!</h2>
              <p>앱으로 돌아가세요.</p>
              <script>setTimeout(()=>window.close(), 2000)</script>
            </body></html>
          ''');
        await request.response.close();
        break;
      }
    } on TimeoutException catch (_) {
      await server.close(force: true);
      throw Exception('Google 로그인 시간이 초과되었습니다. 다시 시도해주세요.');
    } catch (e) {
      await server.close(force: true);
      rethrow;
    }
    await server.close();

    if (code == null) throw Exception('인증 코드를 받지 못했습니다');

    final tokenResponse = await http.post(
      Uri.parse('https://oauth2.googleapis.com/token'),
      headers: {'Content-Type': 'application/x-www-form-urlencoded'},
      body: {
        'code': code,
        'client_id': _windowsClientId,
        'client_secret': _windowsClientSecret,
        'redirect_uri': 'http://localhost:$port',
        'grant_type': 'authorization_code',
        'code_verifier': codeVerifier,
      },
    );

    final tokenData = jsonDecode(tokenResponse.body) as Map<String, dynamic>;
    final idToken = tokenData['id_token'] as String?;
    final accessToken = tokenData['access_token'] as String?;
    final refreshToken = tokenData['refresh_token'] as String?;
    final expiresIn = tokenData['expires_in'] as int? ?? 3600;

    if (idToken == null) {
      throw Exception('토큰 교환 실패: ${tokenResponse.body}');
    }

    // Calendar API용 토큰 저장
    _cachedAccessToken = accessToken;
    _tokenExpiry = DateTime.now().add(Duration(seconds: expiresIn));
    if (refreshToken != null) {
      _windowsRefreshToken = refreshToken;
    }

    final credential = GoogleAuthProvider.credential(
      idToken: idToken,
      accessToken: accessToken,
    );
    final userCredential = await _auth.signInWithCredential(credential);
    return userCredential.user;
  }

  String _generateCodeVerifier() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (i) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }

  String _generateCodeChallenge(String verifier) {
    final bytes = utf8.encode(verifier);
    final digest = sha256.convert(bytes);
    return base64UrlEncode(digest.bytes).replaceAll('=', '');
  }

  // ⚠️ 개발용 전용
  Future<User?> devSignIn({
    required String email,
    required String password,
  }) async {
    final result = await _auth.signInWithEmailAndPassword(
      email: email,
      password: password,
    );
    return result.user;
  }

  Future<void> signOut() async {
    try {
      await _googleSignIn.signOut();
    } catch (e) {
      print("구글 로그아웃 중 에러 발생 (무시 가능): $e");
    }
    // 캐시 토큰 초기화
    _cachedAccessToken = null;
    _tokenExpiry = null;
    _windowsRefreshToken = null;
    await _auth.signOut();
  }
}
