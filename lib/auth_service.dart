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
  final GoogleSignIn _googleSignIn = GoogleSignIn();

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
    final hasEmailProvider = user.providerData
        .any((p) => p.providerId == 'password');
    if (hasEmailProvider) return; // 이미 연결됨

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
  Future<User?> _signInWindowsGoogle() async {
    // 1. 빈 포트로 로컬 서버 시작
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;

    // 2. PKCE 생성 (client_secret 없이도 안전하게 인증)
    final codeVerifier = _generateCodeVerifier();
    final codeChallenge = _generateCodeChallenge(codeVerifier);

    // 3. Google OAuth URL 구성
    final authUrl = Uri.https('accounts.google.com', '/o/oauth2/v2/auth', {
      'client_id': _windowsClientId,
      'redirect_uri': 'http://localhost:$port',
      'response_type': 'code',
      'scope': 'email profile openid',
      'code_challenge': codeChallenge,
      'code_challenge_method': 'S256',
    });

    // 4. 기본 브라우저로 열기
    await launchUrl(authUrl, mode: LaunchMode.externalApplication);

    // 5. 브라우저 리다이렉트 대기
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

    // 6. 인증 코드 → 토큰 교환 (PKCE: client_secret 불필요)
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

    if (idToken == null) {
      throw Exception('토큰 교환 실패: ${tokenResponse.body}');
    }

    // 7. Firebase 로그인
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

  // ⚠️ 개발용 전용 - 빌드 전 반드시 제거 또는 kDebugMode 체크 필수
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
    await _auth.signOut();
  }
}



