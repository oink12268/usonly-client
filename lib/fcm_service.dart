import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'api_config.dart';

bool get _isMobile => !kIsWeb && (
  defaultTargetPlatform == TargetPlatform.android ||
  defaultTargetPlatform == TargetPlatform.iOS
);

// 백그라운드 메시지 핸들러 (top-level 함수여야 함)
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  print("백그라운드 메시지 수신: ${message.notification?.title}");
}

class FcmService {
  static final FcmService _instance = FcmService._internal();
  factory FcmService() => _instance;
  FcmService._internal();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  Future<void> initialize(int memberId) async {
    if (!_isMobile) return; // Windows/Web에서는 FCM 스킵 (WebSocket으로 실시간 수신)

    // 1. 알림 권한 요청
    await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    // 2. 로컬 알림 초기화 (포그라운드용)
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings();
    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );
    await _localNotifications.initialize(initSettings);

    // Android 알림 채널 생성
    const androidChannel = AndroidNotificationChannel(
      'chat_channel_v2',
      '채팅 알림',
      description: '새 채팅 메시지 알림',
      importance: Importance.max,
      playSound: true,
      enableVibration: true,
    );
    await _localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(androidChannel);

    // 3. FCM 토큰 가져와서 서버에 전송
    String? token = await _messaging.getToken();
    if (token != null) {
      await _sendTokenToServer(memberId, token);
    }

    // 토큰 갱신 시 자동 업데이트
    _messaging.onTokenRefresh.listen((newToken) {
      _sendTokenToServer(memberId, newToken);
    });

    // 4. 포그라운드 메시지 수신 → 로컬 알림 표시
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      final notification = message.notification;
      if (notification != null) {
        _localNotifications.show(
          0, // 고정 ID → 항상 마지막 알림 하나만 표시
          notification.title,
          notification.body,
          const NotificationDetails(
            android: AndroidNotificationDetails(
              'chat_channel_v2',
              '채팅 알림',
              importance: Importance.max,
              priority: Priority.max,
              playSound: true,
              enableVibration: true,
              icon: '@mipmap/ic_launcher',
            ),
            iOS: DarwinNotificationDetails(
              presentSound: true,
            ),
          ),
        );
      }
    });
  }

  Future<void> _sendTokenToServer(int memberId, String token) async {
    try {
      await http.post(
        Uri.parse('${ApiConfig.baseUrl}/api/members/fcm-token?userId=$memberId&token=$token'),
      );
      print("FCM 토큰 서버 전송 완료");
    } catch (e) {
      print("FCM 토큰 전송 실패: $e");
    }
  }
}
