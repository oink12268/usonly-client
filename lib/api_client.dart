import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

class ApiClient {
  // 싱글턴 Client: TCP+TLS 연결을 재사용해 HTTPS 오버헤드를 줄임
  static final http.Client _client = http.Client();

  static Future<String?> _getToken() async {
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
  static Future<http.StreamedResponse> sendMultipart(http.MultipartRequest request) async {
    final token = await _getToken();
    if (token != null) {
      request.headers['Authorization'] = 'Bearer $token';
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
