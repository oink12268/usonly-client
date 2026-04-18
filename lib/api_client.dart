import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'debug_log_service.dart';

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

  static void _log(String method, Uri url, int status, int ms) {
    final path = url.path + (url.query.isNotEmpty ? '?${url.query}' : '');
    final msg = '$method $path → $status (${ms}ms)';
    if (status >= 500) {
      appLog.error(msg);
    } else if (status >= 400) {
      appLog.warn(msg);
    } else {
      appLog.info(msg);
    }
  }

  static Future<http.Response> get(Uri url) async {
    final headers = await _authHeaders();
    final sw = Stopwatch()..start();
    final res = await _client.get(url, headers: headers);
    _log('GET', url, res.statusCode, sw.elapsedMilliseconds);
    return res;
  }

  static Future<http.Response> post(Uri url, {Object? body}) async {
    final headers = await _authHeaders(withJson: body != null);
    final sw = Stopwatch()..start();
    final res = await _client.post(url, headers: headers, body: body);
    _log('POST', url, res.statusCode, sw.elapsedMilliseconds);
    return res;
  }

  static Future<http.Response> put(Uri url, {Object? body}) async {
    final headers = await _authHeaders(withJson: body != null);
    final sw = Stopwatch()..start();
    final res = await _client.put(url, headers: headers, body: body);
    _log('PUT', url, res.statusCode, sw.elapsedMilliseconds);
    return res;
  }

  static Future<http.Response> patch(Uri url, {Object? body}) async {
    final headers = await _authHeaders(withJson: body != null);
    final sw = Stopwatch()..start();
    final res = await _client.patch(url, headers: headers, body: body);
    _log('PATCH', url, res.statusCode, sw.elapsedMilliseconds);
    return res;
  }

  static Future<http.Response> delete(Uri url) async {
    final headers = await _authHeaders();
    final sw = Stopwatch()..start();
    final res = await _client.delete(url, headers: headers);
    _log('DELETE', url, res.statusCode, sw.elapsedMilliseconds);
    return res;
  }

  // MultipartRequest 전송 (이미지 업로드 등)
  // token을 직접 넘기면 재사용 (다건 업로드 시 토큰을 한 번만 가져오기 위해)
  static Future<http.StreamedResponse> sendMultipart(http.MultipartRequest request, {String? token}) async {
    final t = token ?? await _getToken();
    if (t != null) {
      request.headers['Authorization'] = 'Bearer $t';
    }
    final sw = Stopwatch()..start();
    final res = await _client.send(request);
    final path = request.url.path;
    final msg = 'MULTIPART ${request.method} $path → ${res.statusCode} (${sw.elapsedMilliseconds}ms)';
    if (res.statusCode >= 400) { appLog.warn(msg); } else { appLog.info(msg); }
    return res;
  }

  // WebSocket STOMP 연결 헤더
  static Future<Map<String, String>> stompHeaders() async {
    final token = await _getToken();
    return {
      if (token != null) 'Authorization': 'Bearer $token',
    };
  }

  /// 응답 body를 디코딩합니다.
  /// 백엔드가 ApiResponse 형태({code, message, data})로 응답하면 data 필드를 반환하고,
  /// 그 외 형태(순수 List/Map)이면 그대로 반환합니다.
  static dynamic decodeBody(http.Response response) {
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is Map && decoded.containsKey('data')) {
      return decoded['data'];
    }
    return decoded;
  }

  /// decodeBody의 StreamedResponse 버전 (multipart 응답용)
  static Future<dynamic> decodeStreamedBody(http.StreamedResponse response) async {
    final bodyStr = await response.stream.bytesToString();
    final decoded = jsonDecode(bodyStr);
    if (decoded is Map && decoded.containsKey('data')) {
      return decoded['data'];
    }
    return decoded;
  }
}
