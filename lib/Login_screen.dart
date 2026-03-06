import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'auth_service.dart';

// ⚠️ 개발용
const _devEmail = 'ink12268@gmail.com';
const _devPassword = 'dev-usonly-1234';

class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
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
            Text("우리 둘만의 공간", style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 50),
            
            // 개발용 빠른 로그인 (debug 빌드에서만 표시)
            if (kDebugMode) ...[
              TextButton(
                onPressed: () async {
                  try {
                    await AuthService().devSignIn(
                      email: _devEmail,
                      password: _devPassword,
                    );
                  } catch (e) {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Dev 로그인 실패: $e')),
                      );
                    }
                  }
                },
                child: const Text('[DEV] 자동 로그인', style: TextStyle(color: Colors.grey)),
              ),
              const SizedBox(height: 10),
            ],

            // 구글 로그인 버튼
            ElevatedButton.icon(
              icon: const Icon(Icons.login),
              label: const Text("Google로 시작하기"),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 30, vertical: 15),
              ),
              onPressed: () async {
                try {
                  await AuthService().signInWithGoogle();
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('로그인 실패: $e')),
                    );
                  }
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}