import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'debug_log_service.dart';

/// 서버가 code >= 400 을 반환했을 때 던지는 예외
class ApiException implements Exception {
  final int code;
  final String message;
  const ApiException({required this.code, required this.message});

  @override
  String toString() => 'ApiException($code): $message';
}

class ApiClient {
  // 싱글턴 Client: TCP+TLS 연결을 재사용해 HTTPS 오버헤드를 줄임
  static final http.Client _client = http.Client();

  // 토큰 캐시: 만료 5분 전까지 재사용 → foreground 복귀 후에도 네트워크 왕복 없음
  static String? _cachedToken;
  static DateTime? _tokenExpiry;

  static bool _tokenIsValid() =>
      _cachedToken != null &&
      _tokenExpiry != null &&
      _tokenExpiry!.isAfter(DateTime.now().add(const Duration(minutes: 5)));

  static Future<String?> _getToken({bool forceRefresh = false}) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return null;
    if (!forceRefresh && _tokenIsValid()) return _cachedToken;
    // getIdTokenResult 는 만료 시간도 함께 반환
    final result = await user.getIdTokenResult(forceRefresh);
    _cachedToken = result.token;
    _tokenExpiry = result.expirationTime;
    return _cachedToken;
  }

  static Future<Map<String, String>> _authHeaders({
    bool withJson = false,
    bool forceRefresh = false,
  }) async {
    final token = await _getToken(forceRefresh: forceRefresh);
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

  // 401 응답 시 토큰 강제 갱신 후 1회 재시도
  static Future<http.Response> _send(
    Future<http.Response> Function(Map<String, String> headers) request, {
    bool withJson = false,
  }) async {
    var headers = await _authHeaders(withJson: withJson);
    var res = await request(headers);
    if (res.statusCode == 401) {
      headers = await _authHeaders(withJson: withJson, forceRefresh: true);
      res = await request(headers);
    }
    return res;
  }

  static Future<http.Response> get(Uri url) async {
    final sw = Stopwatch()..start();
    final res = await _send((h) => _client.get(url, headers: h));
    _log('GET', url, res.statusCode, sw.elapsedMilliseconds);
    return res;
  }

  static Future<http.Response> post(Uri url, {Object? body}) async {
    final sw = Stopwatch()..start();
    final res = await _send(
      (h) => _client.post(url, headers: h, body: body),
      withJson: body != null,
    );
    _log('POST', url, res.statusCode, sw.elapsedMilliseconds);
    return res;
  }

  static Future<http.Response> put(Uri url, {Object? body}) async {
    final sw = Stopwatch()..start();
    final res = await _send(
      (h) => _client.put(url, headers: h, body: body),
      withJson: body != null,
    );
    _log('PUT', url, res.statusCode, sw.elapsedMilliseconds);
    return res;
  }

  static Future<http.Response> patch(Uri url, {Object? body}) async {
    final sw = Stopwatch()..start();
    final res = await _send(
      (h) => _client.patch(url, headers: h, body: body),
      withJson: body != null,
    );
    _log('PATCH', url, res.statusCode, sw.elapsedMilliseconds);
    return res;
  }

  static Future<http.Response> delete(Uri url) async {
    final sw = Stopwatch()..start();
    final res = await _send((h) => _client.delete(url, headers: h));
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
  /// 백엔드 ApiResponse({code, message, data}) 형태면:
  ///   - code >= 400 → ApiException 던짐 (message 포함)
  ///   - 성공 → data 반환
  /// 그 외 형태(순수 List/Map)이면 그대로 반환합니다.
  static dynamic decodeBody(http.Response response) {
    final decoded = jsonDecode(utf8.decode(response.bodyBytes));
    if (decoded is Map) {
      final code = (decoded['code'] as num?)?.toInt() ?? response.statusCode;
      final message = decoded['message'] as String? ?? '오류가 발생했습니다.';
      if (code >= 400) {
        throw ApiException(code: code, message: message);
      }
      return decoded['data'];
    }
    return decoded;
  }

  /// decodeBody의 StreamedResponse 버전 (multipart 응답용)
  static Future<dynamic> decodeStreamedBody(http.StreamedResponse response) async {
    final bodyStr = await response.stream.bytesToString();
    final decoded = jsonDecode(bodyStr);
    if (decoded is Map) {
      final code = (decoded['code'] as num?)?.toInt() ?? response.statusCode;
      final message = decoded['message'] as String? ?? '오류가 발생했습니다.';
      if (code >= 400) {
        throw ApiException(code: code, message: message);
      }
      return decoded['data'];
    }
    return decoded;
  }
}
