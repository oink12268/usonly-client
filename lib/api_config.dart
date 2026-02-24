import 'package:flutter/foundation.dart';

class ApiConfig {
  // ★ 여기만 바꾸면 전체 앱의 서버 주소가 변경됩니다!
  // 로컬 개발 시: _host를 IP로 바꾸고 _localPort 사용
  // static const String _host = '10.0.2.2';       // 에뮬레이터
  // static const String _host = '192.168.0.13';   // 개발 PC
  // static const String _host = '192.168.0.16';   // 서버 PC (내부)
  static const String _host = 'usonly.duckdns.org';  // DDNS (운영)
  static const int _localPort = 30080;  // 로컬 개발 시에만 사용

  static String get baseUrl =>
      kIsWeb ? 'https://localhost' : 'https://$_host';

  static String get wsUrl =>
      kIsWeb ? 'wss://localhost/ws' : 'wss://$_host/ws';
}
