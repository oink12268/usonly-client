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
import 'api_config.dart';
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
        primaryColor: const Color(0xFF8B7E74),
        scaffoldBackgroundColor: const Color(0xFFFAF8F5),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFFAF8F5),
          foregroundColor: Color(0xFF8B7E74),
          elevation: 0,
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: Colors.white,
          selectedItemColor: Color(0xFF5C4A44),
          unselectedItemColor: Color(0xFFB0B0B0),
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: Color(0xFF8B7E74),
        ),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF8B7E74),
          primary: const Color(0xFF8B7E74),
          surface: const Color(0xFFFAF8F5),
        ),
      ),
      darkTheme: ThemeData(
        fontFamily: 'Pretendard',
        brightness: Brightness.dark,
        primaryColor: const Color(0xFF8B7E74),
        scaffoldBackgroundColor: const Color(0xFF282828),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF282828),
          foregroundColor: Color(0xFFFFFFFF),
          elevation: 0,
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: Color(0xFF323232),
          selectedItemColor: Color(0xFFFFFFFF),
          unselectedItemColor: Color(0xFF777777),
        ),
        floatingActionButtonTheme: const FloatingActionButtonThemeData(
          backgroundColor: Color(0xFF8B7E74),
        ),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF8B7E74),
          primary: const Color(0xFF8B7E74),
          surface: const Color(0xFF323232),
          onSurface: const Color(0xFFFFFFFF),
          brightness: Brightness.dark,
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
            return const LoginScreen();
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
        Uri.parse('${ApiConfig.baseUrl}/api/auth/login'),
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
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        
        setState(() {
          _myCode = data['invitationCode'] ?? "CODE_ERR";
          _isCouple = data['coupleId'] != null; // 커플 ID가 있으면 커플임
          _serverMemberId = data['memberId'];
          _coupleId = data['coupleId']?.toInt();
          _isLoading = false;
          _hasError = false;
        });

        // FCM 초기화
        FcmService().initialize();
      } else {
        print("서버 에러: ${response.statusCode} / ${response.body}");
        // [FIX #5] 에러 상태로 전환 (빈 코드로 MatchingScreen 진입 방지)
        setState(() {
          _isLoading = false;
          _hasError = true;
        });
      }
    } catch (e) {
      print("서버 통신 실패: $e");
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
