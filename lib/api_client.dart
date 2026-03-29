import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

class ApiClient {
  // 싱글턴 Client: TCP+TLS 연결을 재사용해 HTTPS 오버헤드를 줄임
  static final http.Client _client = http.Client();

  // 앱 시작 시 토큰을 미리 받아두기 위한 Future
  static Future<String?>? _prewarmedToken;

  // main()에서 Firebase 초기화 직후 호출 → 토큰 fetch를 백그라운드에서 미리 시작
  static void prewarmToken() {
    _prewarmedToken = FirebaseAuth.instance.currentUser?.getIdToken();
  }

  static Future<String?> _getToken() async {
    if (_prewarmedToken != null) {
      final token = await _prewarmedToken;
      _prewarmedToken = null;
      return token;
    }
    return await FirebaseAuth.instance.currentUser?.getIdToken();
  }

  static Future<Map<String, String>> _authHeaders({bool withJson = false}) async {
    final token = await _getToken();
    return {
      if (withJson) 'Content-Type': 'application/json',
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  static Future<http.Response> get(Uri url) async {
    final headers = await _authHeaders();
    return _client.get(url, headers: headers);
  }

  static Future<http.Response> post(Uri url, {Object? body}) async {
    final headers = await _authHeaders(withJson: body != null);
    return _client.post(url, headers: headers, body: body);
  }

  static Future<http.Response> put(Uri url, {Object? body}) async {
    final headers = await _authHeaders(withJson: body != null);
    return _client.put(url, headers: headers, body: body);
  }

  static Future<http.Response> delete(Uri url) async {
    final headers = await _authHeaders();
    return _client.delete(url, headers: headers);
  }

  // MultipartRequest 전송 (이미지 업로드 등)
  // token을 직접 넘기면 재사용 (다건 업로드 시 토큰을 한 번만 가져오기 위해)
  static Future<http.StreamedResponse> sendMultipart(http.MultipartRequest request, {String? token}) async {
    final t = token ?? await _getToken();
    if (t != null) {
      request.headers['Authorization'] = 'Bearer $t';
    }
    return _client.send(request);
  }

  // WebSocket STOMP 연결 헤더
  static Future<Map<String, String>> stompHeaders() async {
    final token = await _getToken();
    return {
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }
}
