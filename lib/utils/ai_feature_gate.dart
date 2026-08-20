import 'package:firebase_auth/firebase_auth.dart';

/// 스토어 배포 전, AI 기능(채팅 AI 검색 / 메모 AI 일정 추출)을
/// 특정 계정에서만 노출하기 위한 화이트리스트 가드.
class AiFeatureGate {
  static const Set<String> _allowedEmails = {
    'oink12268@gmail.com',
    'jinaoj@gmail.com',
  };

  static bool get isEnabled {
    final email = FirebaseAuth.instance.currentUser?.email?.toLowerCase();
    if (email == null) return false;
    return _allowedEmails.contains(email);
  }
}
