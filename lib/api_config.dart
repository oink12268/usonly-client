import 'package:flutter/foundation.dart';

class ApiConfig {
  // ★ 여기만 바꾸면 전체 앱의 서버 주소가 변경됩니다!
  // 에뮬레이터: 10.0.2.2  |  실제 핸드폰: PC의 IP (예: 192.168.0.10)
  // static const String _host = '15.164.123.38';  // EC2
  // static const String _host = '192.168.0.13';   // 개발 PC
  // static const String _host = '192.168.0.16';   // 서버 PC (내부)
  static const String _host = 'usonly.iptime.org';  // DDNS (어디서든 접속)
  static const int _port = 30080;  // 로컬: 8080, 서버: 30080

  static String get baseUrl =>
      kIsWeb ? 'http://localhost:$_port' : 'http://$_host:$_port';

  static String get wsUrl =>
      kIsWeb ? 'ws://localhost:$_port/ws' : 'ws://$_host:$_port/ws';
}
