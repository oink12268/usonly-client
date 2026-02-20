import 'package:flutter/material.dart';
import 'auth_service.dart';

class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text(
              "UsOnly",
              style: TextStyle(
                fontSize: 40,
                fontWeight: FontWeight.bold,
                color: Color(0xFF8B7E74),
              ),
            ),
            const SizedBox(height: 10),
            const Text("우리 둘만의 공간", style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 50),
            
            // 구글 로그인 버튼
            ElevatedButton.icon(
              icon: const Icon(Icons.login),
              label: const Text("Google로 시작하기"),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 15),
              ),
              onPressed: () async {
                // 로그인 시도 -> 성공하면 main.dart의 StreamBuilder가 감지해서 화면 전환
                await AuthService().signInWithGoogle();
              },
            ),
          ],
        ),
      ),
    );
  }
}