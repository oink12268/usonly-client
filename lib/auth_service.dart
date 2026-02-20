import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final GoogleSignIn _googleSignIn = GoogleSignIn();

  // 구글 로그인
  Future<User?> signInWithGoogle() async {
    try {
      // 1. 구글 팝업 띄우기
      final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();
      
      if (googleUser == null) return null; // 사용자가 취소함

      // 2. 인증 정보 가져오기
      final GoogleSignInAuthentication googleAuth = await googleUser.authentication;

      // 3. Firebase 자격 증명 만들기
      final AuthCredential credential = GoogleAuthProvider.credential(
        accessToken: googleAuth.accessToken,
        idToken: googleAuth.idToken,
      );

      // 4. Firebase 로그인
      final UserCredential userCredential = await _auth.signInWithCredential(credential);
      
      return userCredential.user;
    } catch (e) {
      print("에러 발생: $e");
      return null;
    }
  }

  // 로그아웃
  Future<void> signOut() async {
    try {
      // 1. 구글 로그아웃 시도 (에러가 나도 무시하고 진행해야 함)
      // 사용자 입장에서는 앱에서만 나가시면 되니까요.
      await _googleSignIn.signOut();
    } catch (e) {
      print("구글 로그아웃 중 에러 발생 (무시 가능): $e");
    }

    // 2. Firebase 로그아웃 (이게 진짜 핵심)
    await _auth.signOut();
  }
}