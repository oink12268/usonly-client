import 'dart:async';
import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'api_client.dart';
import 'api_endpoints.dart';

// 읽지 않은 알림 유무 추적 (iOS 배지 동기화용).
// Android는 OS 표준대로 알림이 있으면 뱃지, 없으면 뱃지 없음.
const _kBadgeChatKey = 'fcm_has_chat_notif';
const _kBadgeOtherKey = 'fcm_has_other_notif';

// 알림 ID — 카테고리당 고정값 1개만 사용.
// 메시지마다 새 ID를 생성하면 알림이 누적되고, Samsung One UI가 자동 그룹화한 뒤
// 스와이프로 없앤 알림이 새 알림과 함께 재등장하는 문제 발생.
const _kChatNotifId = 1;
const _kOtherNotifId = 2;

const _kAuthTokenKey = 'cached_firebase_token';
const _kUserUidKey = 'cached_user_uid';
const _kReplyActionId = 'chat_reply_action';
// iOS 배지 강제 갱신용 silent notification ID
const _kIosBadgeSyncId = 2147483640;

bool get _isMobile =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

const _replyAction = AndroidNotificationAction(
  _kReplyActionId,
  '답장',
  inputs: [AndroidNotificationActionInput(label: '메시지를 입력하세요...')],
  // false: 앱을 열지 않고 BroadcastReceiver로 처리.
  // 포그라운드 알림(앱 실행 중 수신)에서만 사용 → _onForegroundNotificationResponse 호출됨.
  // 백그라운드 알림은 CustomFcmService가 네이티브로 표시 → NotificationReplyReceiver 처리.
  showsUserInterface: false,
  cancelNotification: true,
);

// SharedPreferences는 isolate별 in-memory 캐시를 가짐 — 백그라운드 isolate가
// 디스크에 쓴 값이 포그라운드 캐시에 자동 반영되지 않아 stale read 발생.
// 배지 상태를 만지기 전에는 항상 reload()로 디스크에서 최신 값을 끌어와야 함.
Future<SharedPreferences> _freshPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  return prefs;
}

// 알림 플래그를 1로 세팅하고 총합을 반환 (iOS 배지 동기화에 사용).
Future<int> _markBadge(SharedPreferences prefs, {required bool isChat}) async {
  await prefs.setInt(isChat ? _kBadgeChatKey : _kBadgeOtherKey, 1);
  return _readBadge(prefs);
}

// 어느 쪽이든 알림이 있으면 1, 없으면 0.
int _readBadge(SharedPreferences prefs) =>
    ((prefs.getInt(_kBadgeChatKey) ?? 0) > 0 ||
            (prefs.getInt(_kBadgeOtherKey) ?? 0) > 0)
        ? 1
        : 0;

// 지정 채널의 활성 알림을 모두 cancel.
Future<void> _cancelActiveByChannel(
    FlutterLocalNotificationsPlugin plugin, String channelId) async {
  if (defaultTargetPlatform != TargetPlatform.android) return;
  try {
    final androidPlugin = plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    final active = await androidPlugin?.getActiveNotifications() ?? [];
    for (final notif in active) {
      final id = notif.id;
      if (id != null && notif.channelId == channelId && id != _kIosBadgeSyncId) {
        await plugin.cancel(id, tag: notif.tag);
      }
    }
  } catch (_) {}
}

// iOS 배지를 prefs 총합으로 강제 동기화. silent notification으로 set한 뒤 즉시 cancel.
Future<void> _syncIosBadge(
    FlutterLocalNotificationsPlugin plugin, int total) async {
  if (defaultTargetPlatform != TargetPlatform.iOS) return;
  await plugin.show(
    _kIosBadgeSyncId,
    null,
    null,
    NotificationDetails(
      iOS: DarwinNotificationDetails(
        badgeNumber: total,
        presentAlert: false,
        presentBadge: true,
        presentSound: false,
        presentBanner: false,
        presentList: false,
      ),
    ),
  );
  await plugin.cancel(_kIosBadgeSyncId);
}

// 알림 표시 헬퍼 — 고정 ID로 덮어써서 항상 최신 메시지 1개만 유지.
Future<void> _showNotif(
  FlutterLocalNotificationsPlugin plugin, {
  required bool isChat,
  required String? title,
  required String? body,
  required String? uid,
}) async {
  final notifId = isChat ? _kChatNotifId : _kOtherNotifId;
  await plugin.show(
    notifId,
    title,
    body,
    NotificationDetails(
      android: AndroidNotificationDetails(
        isChat ? 'chat_channel_v2' : 'anniversary_channel',
        isChat ? '채팅 알림' : '알림',
        importance: Importance.max,
        priority: Priority.max,
        playSound: true,
        enableVibration: true,
        icon: '@mipmap/ic_launcher',
        actions: isChat && uid != null ? const [_replyAction] : null,
      ),
      iOS: DarwinNotificationDetails(
        presentSound: true,
        badgeNumber: 1,
      ),
    ),
    payload: uid != null ? jsonEncode({'uid': uid}) : null,
  );
}

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

  final prefs = await _freshPrefs();
  final type = message.data['type'];

  if (type == 'clear_chat') {
    await plugin.cancel(_kChatNotifId);
    await _cancelActiveByChannel(plugin, 'chat_channel_v2');
    await prefs.setInt(_kBadgeChatKey, 0);
    await _syncIosBadge(plugin, _readBadge(prefs));
    return;
  }

  try {
    final user = await FirebaseAuth.instance
        .authStateChanges()
        .first
        .timeout(const Duration(seconds: 5));
    if (user != null) {
      final freshToken =
          await user.getIdToken(true).timeout(const Duration(seconds: 10));
      if (freshToken != null) {
        await prefs.setString(_kAuthTokenKey, freshToken);
        await prefs.setString(_kUserUidKey, user.uid);
      }
    }
  } catch (_) {}

  final isChat = type == null || type == 'chat';
  final total = await _markBadge(prefs, isChat: isChat);

  final title = message.data['title'];
  final body = message.data['body'];

  // Android 채팅 알림: CustomFcmService(Kotlin)가 네이티브로 표시하므로 여기선 생략.
  final androidChat =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android && isChat;

  if (!androidChat && message.notification == null && (title != null || body != null)) {
    final uid = prefs.getString(_kUserUidKey);
    await _showNotif(plugin, isChat: isChat, title: title, body: body, uid: uid);
  } else if (defaultTargetPlatform == TargetPlatform.iOS) {
    await _syncIosBadge(plugin, total);
  }
}

@pragma('vm:entry-point')
Future<void> notificationReplyHandler(NotificationResponse response) async {
  if (response.actionId != _kReplyActionId) return;

  final text = response.input?.trim();
  if (text == null || text.isEmpty) return;

  final plugin = FlutterLocalNotificationsPlugin();
  try {
    await plugin.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
    ));
    await plugin.cancel(_kChatNotifId);
    await _cancelActiveByChannel(plugin, 'chat_channel_v2');
  } catch (_) {}

  final prefs = await _freshPrefs();
  final token = prefs.getString(_kAuthTokenKey);

  String? uid;
  try {
    if (response.payload != null) {
      uid = (jsonDecode(response.payload!) as Map<String, dynamic>)['uid']
          as String?;
    }
  } catch (_) {}
  uid ??= prefs.getString(_kUserUidKey);

  if (token == null || uid == null) return;

  try {
    await http
        .post(
          Uri.parse(ApiEndpoints.chats),
          headers: {
            'Content-Type': 'application/json; charset=utf-8',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode({'message': text, 'writerUid': uid}),
        )
        .timeout(const Duration(seconds: 15));
  } catch (_) {}
}

class FcmService with WidgetsBindingObserver {
  static final FcmService _instance = FcmService._internal();
  factory FcmService() => _instance;
  FcmService._internal();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  bool _isChatActive = false;
  void setChatActive(bool active) => _isChatActive = active;

  bool _isCalendarActive = false;
  void setCalendarActive(bool active) => _isCalendarActive = active;

  bool _initialized = false;

  void Function(String type)? onNavigate;
  String? _pendingNavigationType;
  String? consumePendingNavigation() {
    final type = _pendingNavigationType;
    _pendingNavigationType = null;
    return type;
  }

  Future<void> _cacheAuthInfo() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final token = await user.getIdToken(true);
      if (token == null) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kAuthTokenKey, token);
      await prefs.setString(_kUserUidKey, user.uid);
    } catch (_) {}
  }

  // 채팅 읽음 처리: 채팅 알림 취소 + iOS 배지 동기화
  Future<void> clearChatNotifications() async {
    if (!_isMobile) return;
    final prefs = await _freshPrefs();
    await _localNotifications.cancel(_kChatNotifId);
    await _cancelActiveByChannel(_localNotifications, 'chat_channel_v2');
    await prefs.setInt(_kBadgeChatKey, 0);
    await _syncIosBadge(_localNotifications, _readBadge(prefs));
  }

  // 캘린더/기념일 페이지 진입 시: 알림 취소 + iOS 배지 동기화
  Future<void> clearOtherNotifications() async {
    if (!_isMobile) return;
    final prefs = await _freshPrefs();
    await _localNotifications.cancel(_kOtherNotifId);
    await _cancelActiveByChannel(_localNotifications, 'anniversary_channel');
    await prefs.setInt(_kBadgeOtherKey, 0);
    await _syncIosBadge(_localNotifications, _readBadge(prefs));
  }

  // resumed 시 iOS 배지를 prefs 총합으로 재동기화.
  // Android는 OS가 알아서 관리하므로 처리 없음.
  Future<void> _resyncBadge() async {
    if (!_isMobile) return;
    if (defaultTargetPlatform != TargetPlatform.iOS) return;
    final prefs = await _freshPrefs();
    await _syncIosBadge(_localNotifications, _readBadge(prefs));
  }

  Future<void> initialize() async {
    if (!_isMobile || _initialized) return;
    _initialized = true;

    await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

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

    String? token = await _messaging.getToken();
    if (token != null) {
      await _sendTokenToServer(token);
    }
    await _cacheAuthInfo();

    // Kotlin NotificationReplyReceiver가 읽을 API URL 캐싱
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('api_chats_url', ApiEndpoints.chats);
    }

    _messaging.onTokenRefresh.listen((newToken) async {
      await _sendTokenToServer(newToken);
      await _cacheAuthInfo();
    });

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

    FirebaseMessaging.onMessage.listen(_onForegroundMessage);

    WidgetsBinding.instance.addObserver(this);
    await _resyncBadge();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _resyncBadge();
    }
  }

  Future<void> _onForegroundMessage(RemoteMessage message) async {
    final type = message.data['type'];
    if (type == 'clear_chat') {
      await clearChatNotifications();
      return;
    }
    final isChat = type == null || type == 'chat';
    if (isChat && _isChatActive) return;
    if (type == 'schedule' && _isCalendarActive) return;

    final title = message.data['title'] as String?;
    final body = message.data['body'] as String?;
    if (title == null && body == null) return;

    final prefs = await _freshPrefs();
    await _markBadge(prefs, isChat: isChat);
    final uid = FirebaseAuth.instance.currentUser?.uid;
    await _showNotif(_localNotifications,
        isChat: isChat, title: title, body: body, uid: uid);
  }

  void _onForegroundNotificationResponse(NotificationResponse response) {
    if (response.actionId == _kReplyActionId) {
      final text = response.input?.trim();
      if (text == null || text.isEmpty) return;
      _localNotifications.cancel(_kChatNotifId);
      _cancelActiveByChannel(_localNotifications, 'chat_channel_v2');
      _sendReplyFromForeground(text);
      return;
    }
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
      debugPrint('FCM 토큰 서버 전송 완료');
    } catch (e) {
      debugPrint('FCM 토큰 전송 실패: $e');
    }
  }
}
