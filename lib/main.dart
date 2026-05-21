import 'package:flutter/material.dart';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:flutter/foundation.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'dart:convert';
import 'auth_service.dart';
import 'api_client.dart';
import 'home_screen.dart';
import 'login_screen.dart';
import 'matching_screen.dart';
import 'fcm_service.dart';
import 'api_endpoints.dart';
import 'firebase_options.dart';
import 'font_size_notifier.dart';
import 'theme_notifier.dart';
import 'share_intent_service.dart';

bool get _isMobile => !kIsWeb && (
  defaultTargetPlatform == TargetPlatform.android ||
  defaultTargetPlatform == TargetPlatform.iOS
);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  // 토큰 fetch를 백그라운드에서 미리 시작 (authStateChanges 대기 시간과 겹치게)
  ApiClient.prewarmToken();

  if (_isMobile) {
    FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
    ShareIntentService().init();
    ShareIntentService().checkInitialShare();
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([fontSizeNotifier, themeNotifier]),
      builder: (context, _) => MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'UsOnly',
      localizationsDelegates: const [FlutterQuillLocalizations.delegate],
      themeMode: themeNotifier.themeMode,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(fontSizeNotifier.scale),
        ),
        child: child!,
      ),
      theme: ThemeData(
        fontFamily: 'Pretendard',
        scaffoldBackgroundColor: const Color(0xFFF5F5F5),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF5F5F5),
          foregroundColor: Color(0xFF1A1A1A),
          elevation: 0,
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: Colors.white,
          selectedItemColor: Color(0xFF1A1A1A),
          unselectedItemColor: Color(0xFFAAAAAA),
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: Color(0xFF1A1A1A),
          foregroundColor: Colors.white,
        ),
        iconTheme: const IconThemeData(opticalSize: 24, weight: 200, fill: 0),
        colorScheme: const ColorScheme(
          brightness: Brightness.light,
          primary: Color(0xFF1A1A1A),
          onPrimary: Colors.white,
          primaryContainer: Color(0xFFE8E8E8),
          onPrimaryContainer: Color(0xFF1A1A1A),
          secondary: Color(0xFF555555),
          onSecondary: Colors.white,
          secondaryContainer: Color(0xFFEEEEEE),
          onSecondaryContainer: Color(0xFF1A1A1A),
          tertiary: Color(0xFF777777),
          onTertiary: Colors.white,
          tertiaryContainer: Color(0xFFF0F0F0),
          onTertiaryContainer: Color(0xFF1A1A1A),
          error: Color(0xFFBA1A1A),
          onError: Colors.white,
          errorContainer: Color(0xFFFFDAD6),
          onErrorContainer: Color(0xFF410002),
          surface: Color(0xFFF5F5F5),
          onSurface: Color(0xFF1A1A1A),
          surfaceContainerHighest: Color(0xFFE0E0E0),
          surfaceContainerHigh: Color(0xFFE8E8E8),
          surfaceContainer: Color(0xFFEEEEEE),
          surfaceContainerLow: Color(0xFFF2F2F2),
          surfaceContainerLowest: Colors.white,
          onSurfaceVariant: Color(0xFF666666),
          outline: Color(0xFFAAAAAA),
          outlineVariant: Color(0xFFDDDDDD),
          shadow: Colors.black,
          scrim: Colors.black,
          inverseSurface: Color(0xFF2A2A2A),
          onInverseSurface: Color(0xFFF0F0F0),
          inversePrimary: Color(0xFFCCCCCC),
        ),
      ),
      darkTheme: ThemeData(
        fontFamily: 'Pretendard',
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF1A1A1A),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF1A1A1A),
          foregroundColor: Color(0xFFE8E8E8),
          elevation: 0,
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: Color(0xFF202020),
          selectedItemColor: Color(0xFFE8E8E8),
          unselectedItemColor: Color(0xFF555555),
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: Color(0xFFE0E0E0),
          foregroundColor: Color(0xFF1A1A1A),
        ),
        iconTheme: const IconThemeData(opticalSize: 24, weight: 200, fill: 0),
        colorScheme: const ColorScheme(
          brightness: Brightness.dark,
          primary: Color(0xFFE0E0E0),
          onPrimary: Color(0xFF1A1A1A),
          primaryContainer: Color(0xFF3A3A3A),
          onPrimaryContainer: Color(0xFFE0E0E0),
          secondary: Color(0xFFBBBBBB),
          onSecondary: Color(0xFF1A1A1A),
          secondaryContainer: Color(0xFF3D3D3D),
          onSecondaryContainer: Color(0xFFE0E0E0),
          tertiary: Color(0xFF999999),
          onTertiary: Color(0xFF1A1A1A),
          tertiaryContainer: Color(0xFF454545),
          onTertiaryContainer: Color(0xFFE0E0E0),
          error: Color(0xFFFFB4AB),
          onError: Color(0xFF690005),
          errorContainer: Color(0xFF93000A),
          onErrorContainer: Color(0xFFFFDAD6),
          surface: Color(0xFF1A1A1A),
          onSurface: Color(0xFFE8E8E8),
          surfaceContainerHighest: Color(0xFF383838),
          surfaceContainerHigh: Color(0xFF2E2E2E),
          surfaceContainer: Color(0xFF272727),
          surfaceContainerLow: Color(0xFF222222),
          surfaceContainerLowest: Color(0xFF161616),
          onSurfaceVariant: Color(0xFFAAAAAA),
          outline: Color(0xFF666666),
          outlineVariant: Color(0xFF3A3A3A),
          shadow: Colors.black,
          scrim: Colors.black,
          inverseSurface: Color(0xFFE8E8E8),
          onInverseSurface: Color(0xFF1A1A1A),
          inversePrimary: Color(0xFF404040),
        ),
      ),
      home: StreamBuilder<User?>(
          stream: FirebaseAuth.instance.authStateChanges(),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snapshot.hasData) {
              return AuthCheckWrapper(user: snapshot.data!);
            }
            return FutureBuilder<User?>(
              future: AuthService.silentSignInMacOS(),
              builder: (context, silentSnapshot) {
                if (silentSnapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (silentSnapshot.data != null) {
                  return AuthCheckWrapper(user: silentSnapshot.data!);
                }
                return const LoginScreen();
              },
            );
          },
        ),
    ),    // MaterialApp 끝
    );   // ListenableBuilder 끝
  }
}

// ★ 핵심: Firebase 로그인 후, 우리 서버(MySQL)에서 유저 상태를 확인하는 중간 관리자
class AuthCheckWrapper extends StatefulWidget {
  final User user;
  const AuthCheckWrapper({super.key, required this.user});

  @override
  State<AuthCheckWrapper> createState() => _AuthCheckWrapperState();
}

class _AuthCheckWrapperState extends State<AuthCheckWrapper> {
  bool _isLoading = true;
  bool _isCouple = false;
  int _serverMemberId = -1;
  int? _coupleId;
  String _myCode = "";
  // [FIX #5] 백엔드 연결 실패 상태 추적
  bool _hasError = false;

  @override
  void initState() {
    super.initState();
    _checkBackendStatus();
  }

  // 스프링 서버에 "나 누구야" 하고 물어보는 함수
  Future<void> _checkBackendStatus() async {
    try {
      final response = await ApiClient.post(
        Uri.parse(ApiEndpoints.login),
        body: jsonEncode({
          "email": widget.user.email,
          "nickname": widget.user.displayName ?? "이름없음",
          "provider": "GOOGLE",
          "providerId": widget.user.uid,
          "profileImageUrl": widget.user.photoURL ?? ""
        }),
      );

      if (response.statusCode == 200) {
        // 한글 깨짐 방지 디코딩
        final data = ApiClient.decodeBody(response) as Map<String, dynamic>;

        setState(() {
          _myCode = data['invitationCode'] ?? "CODE_ERR";
          _isCouple = data['coupleId'] != null;
          _serverMemberId = data['memberId'];
          _coupleId = data['coupleId']?.toInt();
          _isLoading = false;
          _hasError = false;
        });

        // FCM 초기화
        FcmService().initialize();
      } else {
        debugPrint("서버 에러: ${response.statusCode} / ${response.body}");
        // [FIX #5] 에러 상태로 전환 (빈 코드로 MatchingScreen 진입 방지)
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
      }
    } catch (e) {
      debugPrint("서버 통신 실패: $e");
      // [FIX #5] 에러 상태로 전환
      setState(() {
        _isLoading = false;
        _hasError = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    // [FIX #5] 서버 연결 실패 시 재시도 화면 (빈 코드로 MatchingScreen 진입 방지)
    if (_hasError) {
      return Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.wifi_off, size: 64, color: Theme.of(context).colorScheme.outline),
              const SizedBox(height: 16),
              const Text('서버 연결에 실패했습니다', style: TextStyle(fontSize: 16)),
              const SizedBox(height: 8),
              ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.primary),
                onPressed: () {
                  setState(() { _hasError = false; _isLoading = true; });
                  _checkBackendStatus();
                },
                child: Text('다시 시도', style: TextStyle(color: Theme.of(context).colorScheme.onPrimary)),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => AuthService().signOut(),
                child: Text('로그아웃', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
              ),
            ],
          ),
        ),
      );
    }

    // 커플이면 홈으로, 아니면 매칭(초대코드) 화면으로
    if (_isCouple) {
      return HomeScreen(user: widget.user, memberId: _serverMemberId, coupleId: _coupleId);
    } else {
      return MatchingScreen(user: widget.user, myCode: _myCode);
    }
  }
}
