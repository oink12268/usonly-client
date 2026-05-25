import 'package:flutter/foundation.dart';

class ApiConfig {
  // 빌드 시 --dart-define-from-file 로 주입 (dart_defines/dev.json 또는 prod.json)
  // 기본값 = 프로덕션 서버 (dart-define 없이 빌드하면 prod)
  static const String _host = String.fromEnvironment(
    'API_HOST',
    defaultValue: 'usonly.duckdns.org',
  );
  static const String _scheme = String.fromEnvironment(
    'API_SCHEME',
    defaultValue: 'https',  // dev 에서는 'http' 로 오버라이드
  );

  static String get baseUrl =>
      kIsWeb ? 'http://localhost:8080' : '$_scheme://$_host';

  static String get wsUrl {
    if (kIsWeb) return 'ws://localhost:8080/ws';
    final wsScheme = _scheme == 'https' ? 'wss' : 'ws';
    return '$wsScheme://$_host/ws';
  }
}