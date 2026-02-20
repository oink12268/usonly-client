import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // 클립보드 복사 기능용
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http; // 서버 통신용
import 'dart:convert'; // JSON 처리용
import 'auth_service.dart'; // 로그아웃용
import 'home_screen.dart'; // 매칭 성공 시 이동할 화면
import 'api_config.dart';

class MatchingScreen extends StatefulWidget {
  final User user;
  final String myCode; // 서버에서 받아온 내 초대 코드

  const MatchingScreen({
    super.key,
    required this.user,
    required this.myCode,
  });

  @override
  State<MatchingScreen> createState() => _MatchingScreenState();
}

class _MatchingScreenState extends State<MatchingScreen> {
  // 상대방 코드 입력값을 제어하는 컨트롤러
  final TextEditingController _codeController = TextEditingController();
  
  // 로딩 상태 표시용
  bool _isConnecting = false;

  @override
  void dispose() {
    _codeController.dispose();
    super.dispose();
  }

  // ★ 핵심: 커플 연결 API 호출 함수
  void _connectCouple() async {
    // 1. 입력값 가져오기 (공백 제거 및 대문자 변환)
    String partnerCode = _codeController.text.trim().toUpperCase();

    if (partnerCode.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("상대방의 코드를 입력해주세요.")),
      );
      return;
    }

    if (partnerCode == widget.myCode) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("본인의 코드는 입력할 수 없습니다.")),
      );
      return;
    }

    setState(() {
      _isConnecting = true; // 로딩 시작
    });

    try {
      // 2. 스프링 부트 서버로 요청 전송
      // (안드로이드 에뮬레이터 기준 localhost는 10.0.2.2 입니다)
      final response = await http.post(
        Uri.parse('${ApiConfig.baseUrl}/api/couples/connect'),
        headers: {"Content-Type": "application/json"},
        body: jsonEncode({
          "email": widget.user.email, // 내 이메일 (누가 요청했는지 식별)
          "code": partnerCode,        // 입력한 상대방 코드
        }),
      );

      if (!mounted) return; // 비동기 처리 중 화면이 닫혔으면 중단

      if (response.statusCode == 200) {
        // 1. 서버가 준 응답 바디를 파싱합니다.
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        
        // 2. 파싱한 데이터에서 내 PK(id)를 가져옵니다. 
        // (보통 서버 응답에 본인의 id가 포함되어 있어야 합니다.)
        final int myServerId = data['id'];
        // 3. 성공 시 처리
        // 홈 화면(채팅방)으로 이동하면서 이전 화면 스택 제거
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => HomeScreen(user: widget.user, memberId: myServerId)),
        );
        
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("축하합니다! 커플 연결에 성공했습니다 ❤️")),
        );
      } else {
        // 4. 실패 시 처리 (서버에서 보낸 에러 메시지 표시)
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        String errorMessage = data['message'] ?? "연결에 실패했습니다.";
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(errorMessage)),
        );
      }
    } catch (e) {
      // 5. 네트워크 등 기타 에러 처리
      print("커플 연결 에러: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("서버와 통신 중 오류가 발생했습니다.")),
      );
    } finally {
      if (mounted) {
        setState(() {
          _isConnecting = false; // 로딩 종료
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text("커플 연결"),
        centerTitle: true,
        elevation: 0,
        backgroundColor: Colors.white,
        foregroundColor: Colors.black,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            onPressed: () async {
              await AuthService().signOut();
            },
          )
        ],
      ),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const SizedBox(height: 40),
              
              // --- 내 코드 표시 영역 ---
              const Text(
                "내 초대 코드",
                style: TextStyle(fontSize: 16, color: Colors.grey),
              ),
              const SizedBox(height: 12),
              
              InkWell(
                onTap: () {
                  Clipboard.setData(ClipboardData(text: widget.myCode));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text("코드가 클립보드에 복사되었습니다!")),
                  );
                },
                borderRadius: BorderRadius.circular(16),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 48),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF0EBE5),
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: const Color(0xFF8B7E74).withValues(alpha: 0.5)),
                  ),
                  child: Column(
                    children: [
                      Text(
                        widget.myCode,
                        style: const TextStyle(
                          fontSize: 36,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 4,
                          color: const Color(0xFF8B7E74),
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        "터치해서 복사하기",
                        style: TextStyle(fontSize: 12, color: const Color(0xFFD4C5B9)),
                      ),
                    ],
                  ),
                ),
              ),
              
              const SizedBox(height: 60),
              const Divider(thickness: 1, color: Colors.grey),
              const SizedBox(height: 40),

              // --- 상대방 코드 입력 영역 ---
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  "상대방 코드 입력",
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 16),
              
              TextField(
                controller: _codeController,
                maxLength: 6, // 코드는 보통 6자리
                textCapitalization: TextCapitalization.characters, // 자동 대문자
                decoration: InputDecoration(
                  hintText: "코드를 입력하세요",
                  prefixIcon: const Icon(Icons.favorite, color: Colors.grey),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: const Color(0xFF8B7E74)),
                  ),
                  counterText: "", // 글자수 카운터 숨김
                ),
              ),
              
              const SizedBox(height: 24),

              // --- 연결하기 버튼 ---
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _isConnecting ? null : _connectCouple,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF8B7E74),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 2,
                  ),
                  child: _isConnecting
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text(
                          "연결하기",
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}