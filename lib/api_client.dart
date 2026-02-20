import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

class ApiClient {
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
    return http.get(url, headers: headers);
  }

  static Future<http.Response> post(Uri url, {Object? body}) async {
    final headers = await _authHeaders(withJson: body != null);
    return http.post(url, headers: headers, body: body);
  }

  static Future<http.Response> put(Uri url, {Object? body}) async {
    final headers = await _authHeaders(withJson: body != null);
    return http.put(url, headers: headers, body: body);
  }

  static Future<http.Response> delete(Uri url) async {
    final headers = await _authHeaders();
    return http.delete(url, headers: headers);
  }

  // MultipartRequest 전송 (이미지 업로드 등)
  static Future<http.StreamedResponse> sendMultipart(http.MultipartRequest request) async {
    final token = await _getToken();
    if (token != null) {
      request.headers['Authorization'] = 'Bearer $token';
    }
    return request.send();
  }

  // WebSocket STOMP 연결 헤더
  static Future<Map<String, String>> stompHeaders() async {
    final token = await _getToken();
    return {
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }
}
