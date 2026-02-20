import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'auth_service.dart';
import 'home_screen.dart';
import 'login_screen.dart'; // 아래 4번 파일
import 'matching_screen.dart'; // 아래 5번 파일
import 'fcm_service.dart';
import 'api_config.dart';
import 'firebase_options.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'UsOnly',
      theme: ThemeData(
        primaryColor: const Color(0xFF8B7E74),
        scaffoldBackgroundColor: const Color(0xFFFAF8F5),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFFAF8F5),
          foregroundColor: Color(0xFF8B7E74),
          elevation: 0,
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: Colors.white,
          selectedItemColor: Color(0xFF8B7E74),
          unselectedItemColor: Color(0xFFD4C5B9),
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
    );
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
  String _myCode = "";

  @override
  void initState() {
    super.initState();
    _checkBackendStatus();
  }

  // 스프링 서버에 "나 누구야" 하고 물어보는 함수
  Future<void> _checkBackendStatus() async {
    try {
      final response = await http.post(
        Uri.parse('${ApiConfig.baseUrl}/api/auth/login'),
        headers: {"Content-Type": "application/json"},
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
          _isLoading = false;
        });

        // FCM 초기화 (서버에서 memberId 받은 후)
        FcmService().initialize(_serverMemberId);
      } else {
        print("서버 에러: ${response.statusCode}");
        // 에러 시 일단 로딩 해제 (재시도 로직 등은 추후 추가)
        setState(() => _isLoading = false);
      }
    } catch (e) {
      print("서버 통신 실패: $e");
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    // 커플이면 홈으로, 아니면 매칭(초대코드) 화면으로
    if (_isCouple) {
      return HomeScreen(user: widget.user, memberId: _serverMemberId);
    } else {
      return MatchingScreen(user: widget.user, myCode: _myCode);
    }
  }
}