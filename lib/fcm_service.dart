import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'api_client.dart';
import 'api_endpoints.dart';

bool get _isMobile => !kIsWeb && (
  defaultTargetPlatform == TargetPlatform.android ||
  defaultTargetPlatform == TargetPlatform.iOS
);

// 백그라운드 메시지 핸들러 (top-level 함수여야 함)
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  if (message.data['type'] == 'clear_chat') {
    final plugin = FlutterLocalNotificationsPlugin();
    const initSettings = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await plugin.initialize(initSettings);
    await plugin.cancelAll();
  }
}

class FcmService {
  static final FcmService _instance = FcmService._internal();
  factory FcmService() => _instance;
  FcmService._internal();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  // 채팅 화면이 열려 있을 때 포그라운드 FCM 알림 억제
  bool _isChatActive = false;
  void setChatActive(bool active) => _isChatActive = active;

  // 알림 ID 카운터 (고유 ID 생성용)
  int _notificationId = 1;
  int _badgeCount = 0;

  // 알림 탭 → 네비게이션 콜백 (HomeScreen이 등록, type: 'chat' | 'anniversary')
  void Function(String type)? onNavigate;
  // 앱이 종료 상태에서 알림 탭으로 열린 경우 pending 저장
  String? _pendingNavigationType;
  String? consumePendingNavigation() {
    final type = _pendingNavigationType;
    _pendingNavigationType = null;
    return type;
  }

  // 채팅 읽음 처리: 알림 영역 + 앱 아이콘 배지 초기화
  Future<void> clearChatNotifications() async {
    if (!_isMobile) return;
    _badgeCount = 0;
    _notificationId = 1;
    // 알림 영역에서 채팅 알림 제거 (Android: 배지도 함께 제거됨)
    await _localNotifications.cancelAll();
    // iOS: 별도로 배지 카운트 0으로 초기화
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await _localNotifications.show(
        0, null, null,
        const NotificationDetails(
          iOS: DarwinNotificationDetails(
            badgeNumber: 0,
            presentAlert: false,
            presentBadge: true,
            presentSound: false,
          ),
        ),
      );
    }
  }

  Future<void> initialize() async {
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
    const anniversaryChannel = AndroidNotificationChannel(
      'anniversary_channel',
      '기념일 알림',
      description: '기념일 D-7, D-1 알림',
      importance: Importance.high,
    );
    final androidPlugin = _localNotifications
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.createNotificationChannel(androidChannel);
    await androidPlugin?.createNotificationChannel(anniversaryChannel);

    // 3. FCM 토큰 가져와서 서버에 전송
    String? token = await _messaging.getToken();
    if (token != null) {
      await _sendTokenToServer(token);
    }

    // 토큰 갱신 시 자동 업데이트
    _messaging.onTokenRefresh.listen((newToken) {
      _sendTokenToServer(newToken);
    });

    // 4. 알림 탭으로 앱 진입 처리
    // 4-1. 앱이 완전히 종료된 상태에서 알림 탭
    final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
    if (initialMessage != null) {
      _pendingNavigationType = initialMessage.data['type'] ?? 'chat';
    }
    // 4-2. 앱이 백그라운드 상태에서 알림 탭
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      final type = message.data['type'] ?? 'chat';
      if (onNavigate != null) {
        onNavigate!(type);
      } else {
        _pendingNavigationType = type;
      }
    });

    // 5. 포그라운드 메시지 수신 → 채팅 화면이 열려 있으면 알림 억제
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      // 다른 기기에서 읽음 처리 시 알림 소거
      if (message.data['type'] == 'clear_chat') {
        clearChatNotifications();
        return;
      }
      if (_isChatActive) return; // 채팅 화면 중이면 알림 표시 안 함
      final notification = message.notification;
      if (notification != null) {
        _badgeCount++;
        final id = _notificationId++;
        _localNotifications.show(
          id,
          notification.title,
          notification.body,
          NotificationDetails(
            android: AndroidNotificationDetails(
              'chat_channel_v2',
              '채팅 알림',
              importance: Importance.max,
              priority: Priority.max,
              playSound: true,
              enableVibration: true,
              icon: '@mipmap/ic_launcher',
              number: _badgeCount,
            ),
            iOS: DarwinNotificationDetails(
              presentSound: true,
              badgeNumber: _badgeCount,
            ),
          ),
        );
      }
    });
  }

  Future<void> _sendTokenToServer(String token) async {
    try {
      await ApiClient.post(
        Uri.parse('${ApiEndpoints.fcmToken}?token=$token'),
      );
      print("FCM 토큰 서버 전송 완료");
    } catch (e) {
      print("FCM 토큰 전송 실패: $e");
    }
  }
}
