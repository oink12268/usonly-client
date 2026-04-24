import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'api_client.dart';
import 'api_config.dart';
import 'api_endpoints.dart';

const _kBadgeCountKey = 'fcm_badge_count';
const _kAuthTokenKey = 'cached_firebase_token';
const _kUserUidKey = 'cached_user_uid';
const _kReplyActionId = 'chat_reply_action';

bool get _isMobile =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

// 알림에 붙이는 "답장" 액션 (Android 전용)
const _replyAction = AndroidNotificationAction(
  _kReplyActionId,
  '답장',
  inputs: [AndroidNotificationActionInput(label: '메시지를 입력하세요...')],
  showsUserInterface: false,
  cancelNotification: false,
);

// 백그라운드 메시지 핸들러 (top-level 함수여야 함)
@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  final plugin = FlutterLocalNotificationsPlugin();
  const initSettings = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    iOS: DarwinInitializationSettings(),
  );
  await plugin.initialize(
    initSettings,
    onDidReceiveBackgroundNotificationResponse: notificationReplyHandler,
  );

  if (message.data['type'] == 'clear_chat') {
    await plugin.cancelAll();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kBadgeCountKey, 0);
    return;
  }

  final prefs = await SharedPreferences.getInstance();
  final count = (prefs.getInt(_kBadgeCountKey) ?? 0) + 1;
  await prefs.setInt(_kBadgeCountKey, count);

  // notification 필드가 있으면 FCM이 OS 레벨에서 이미 표시함 → 수동 표시 생략
  // data-only 메시지(notification == null)일 때만 직접 표시
  final title = message.data['title'];
  final body = message.data['body'];
  if (message.notification == null && (title != null || body != null)) {
    final uid = prefs.getString(_kUserUidKey);
    await plugin.show(
      count,
      title,
      body,
      NotificationDetails(
        android: AndroidNotificationDetails(
          'chat_channel_v2',
          '채팅 알림',
          importance: Importance.max,
          priority: Priority.max,
          playSound: true,
          enableVibration: true,
          icon: '@mipmap/ic_launcher',
          number: count,
          actions: uid != null ? const [_replyAction] : null,
        ),
      ),
      payload: uid != null ? jsonEncode({'uid': uid}) : null,
    );
  }
}

// 알림 답장 처리 핸들러 (앱이 백그라운드/종료 상태일 때도 동작)
// top-level 함수여야 하며, @pragma 필수
@pragma('vm:entry-point')
Future<void> notificationReplyHandler(NotificationResponse response) async {
  if (response.actionId != _kReplyActionId) return;

  final text = response.input?.trim();
  if (text == null || text.isEmpty) return;

  final prefs = await SharedPreferences.getInstance();
  final token = prefs.getString(_kAuthTokenKey);

  // payload에서 uid 추출, 없으면 SharedPreferences fallback
  String? uid;
  try {
    if (response.payload != null) {
      uid = (jsonDecode(response.payload!) as Map<String, dynamic>)['uid'] as String?;
    }
  } catch (_) {}
  uid ??= prefs.getString(_kUserUidKey);

  if (token == null || uid == null) return;

  try {
    await http.post(
      Uri.parse('${ApiConfig.baseUrl}/api/chats'),
      headers: {
        'Content-Type': 'application/json; charset=utf-8',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode({'message': text, 'writerUid': uid}),
    );
  } catch (_) {}
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
  String? _pendingNavigationType;
  String? consumePendingNavigation() {
    final type = _pendingNavigationType;
    _pendingNavigationType = null;
    return type;
  }

  // Firebase 토큰 + UID를 SharedPreferences에 캐싱
  // → 앱 종료 상태에서 알림 답장 시 사용 (Firebase SDK 미초기화 상태)
  Future<void> _cacheAuthInfo() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final token = await user.getIdToken();
      if (token == null) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kAuthTokenKey, token);
      await prefs.setString(_kUserUidKey, user.uid);
    } catch (_) {}
  }

  // 채팅 읽음 처리: 알림 영역 + 앱 아이콘 배지 초기화
  Future<void> clearChatNotifications() async {
    if (!_isMobile) return;
    _badgeCount = 0;
    _notificationId = 1;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_kBadgeCountKey, 0);
    await _localNotifications.cancelAll();
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      await _localNotifications.show(
        0,
        null,
        null,
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
    if (!_isMobile) return;

    // 1. 알림 권한 요청
    await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    // 2. 배지 카운트 복원
    final prefs = await SharedPreferences.getInstance();
    _badgeCount = prefs.getInt(_kBadgeCountKey) ?? 0;

    // 3. 로컬 알림 초기화
    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings();
    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );
    await _localNotifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onForegroundNotificationResponse,
      onDidReceiveBackgroundNotificationResponse: notificationReplyHandler,
    );

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

    // 4. FCM 토큰 서버 전송 + 인증 정보 캐싱
    String? token = await _messaging.getToken();
    if (token != null) {
      await _sendTokenToServer(token);
    }
    await _cacheAuthInfo();

    _messaging.onTokenRefresh.listen((newToken) async {
      await _sendTokenToServer(newToken);
      await _cacheAuthInfo(); // 토큰 갱신 시 캐시도 갱신
    });

    // 5. 알림 탭으로 앱 진입 처리
    final initialMessage = await FirebaseMessaging.instance.getInitialMessage();
    if (initialMessage != null) {
      _pendingNavigationType = initialMessage.data['type'] ?? 'chat';
    }
    FirebaseMessaging.onMessageOpenedApp.listen((message) {
      final type = message.data['type'] ?? 'chat';
      if (onNavigate != null) {
        onNavigate!(type);
      } else {
        _pendingNavigationType = type;
      }
    });

    // 6. 포그라운드 메시지 수신
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      if (message.data['type'] == 'clear_chat') {
        clearChatNotifications();
        return;
      }
      if (_isChatActive) return;
      // data-only 메시지: data['title'], data['body'] 사용
      final title = message.data['title'] as String?;
      final body = message.data['body'] as String?;
      if (title != null || body != null) {
        _badgeCount++;
        SharedPreferences.getInstance()
            .then((p) => p.setInt(_kBadgeCountKey, _badgeCount));
        final uid = FirebaseAuth.instance.currentUser?.uid;
        final id = _notificationId++;
        _localNotifications.show(
          id,
          title,
          body,
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
              actions: const [_replyAction],
            ),
            iOS: DarwinNotificationDetails(
              presentSound: true,
              badgeNumber: _badgeCount,
            ),
          ),
          payload: uid != null ? jsonEncode({'uid': uid}) : null,
        );
      }
    });

  }

  // 앱이 포그라운드일 때 알림 액션 처리
  void _onForegroundNotificationResponse(NotificationResponse response) {
    if (response.actionId == _kReplyActionId) {
      // 포그라운드에서는 Firebase 정상 동작하므로 바로 전송
      final text = response.input?.trim();
      if (text == null || text.isEmpty) return;
      _sendReplyFromForeground(text);
      return;
    }
    // 일반 알림 탭 → 채팅 화면으로 이동
    if (onNavigate != null) {
      onNavigate!('chat');
    } else {
      _pendingNavigationType = 'chat';
    }
  }

  Future<void> _sendReplyFromForeground(String text) async {
    try {
      final uid = FirebaseAuth.instance.currentUser?.uid;
      if (uid == null) return;
      await ApiClient.post(
        Uri.parse(ApiEndpoints.chats),
        body: jsonEncode({'message': text, 'writerUid': uid}),
      );
    } catch (_) {}
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
