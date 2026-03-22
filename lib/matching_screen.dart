import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // 클립보드 복사 기능용
import 'package:firebase_auth/firebase_auth.dart';
import 'dart:convert'; // JSON 처리용
import 'auth_service.dart'; // 로그아웃용
import 'api_client.dart';
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
      final response = await ApiClient.post(
        Uri.parse('${ApiConfig.baseUrl}/api/couples/connect'),
        body: jsonEncode({
          "code": partnerCode,
        }),
      );

      if (!mounted) return; // 비동기 처리 중 화면이 닫혔으면 중단

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        
        final int myServerId = data['id'];
        // [FIX #7] coupleId를 응답에서 추출해 HomeScreen에 전달
        // 서버 응답 구조에 따라 'coupleId' 키로 포함되어 있다고 가정
        final int? coupleId = data['coupleId']?.toInt();

        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => HomeScreen(
              user: widget.user,
              memberId: myServerId,
              coupleId: coupleId, // coupleId 전달 (노트 실시간 동기화에 필요)
            ),
          ),
        );
        
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("축하합니다! 커플 연결에 성공했습니다 ❤️")),
        );
      } else {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        String errorMessage = data['message'] ?? "연결에 실패했습니다.";
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(errorMessage)),
        );
      }
    } catch (e) {
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
      appBar: AppBar(
        title: const Text("커플 연결"),
        centerTitle: true,
        elevation: 0,
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
              Text(
                "내 초대 코드",
                style: TextStyle(fontSize: 16, color: Theme.of(context).colorScheme.onSurfaceVariant),
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
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5)),
                  ),
                  child: Column(
                    children: [
                      Text(
                        widget.myCode,
                        style: TextStyle(
                          fontSize: 36,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 4,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        "터치해서 복사하기",
                        style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.outline),
                      ),
                    ],
                  ),
                ),
              ),
              
              const SizedBox(height: 60),
              const Divider(thickness: 1),
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
                maxLength: 6,
                textCapitalization: TextCapitalization.characters,
                decoration: InputDecoration(
                  hintText: "코드를 입력하세요",
                  prefixIcon: Icon(Icons.favorite, color: Theme.of(context).colorScheme.outline),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: Theme.of(context).colorScheme.primary),
                  ),
                  counterText: "",
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
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 2,
                  ),
                  child: _isConnecting
                      ? CircularProgressIndicator(color: Theme.of(context).colorScheme.onPrimary)
                      : Text(
                          "연결하기",
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: Theme.of(context).colorScheme.onPrimary,
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
