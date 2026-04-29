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
import 'api_config.dart';
import 'api_endpoints.dart';

// 배지 카운터를 type별로 분리: chat은 채팅 진입 시 0으로 리셋,
// other(anniversary/schedule)는 별도 누적 — 한쪽 리셋이 다른쪽을 지우지 않도록.
const _kBadgeChatKey = 'fcm_badge_count_chat';
const _kBadgeOtherKey = 'fcm_badge_count_other';

// 알림 ID — 카테고리당 고정값 1개만 사용.
// 메시지마다 새 ID를 생성하면 알림이 누적되고, Samsung One UI가 자동 그룹화한 뒤
// 스와이프로 없앤 알림이 새 알림과 함께 재등장하는 문제 발생.
// 고정 ID로 덮어쓰면 항상 최신 메시지 1개만 표시되고 그룹화 부작용이 없음.
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

// prefs 기반 atomic 카운터 증가.
Future<int> _incrementBadge(SharedPreferences prefs,
    {required bool isChat}) async {
  final key = isChat ? _kBadgeChatKey : _kBadgeOtherKey;
  final next = (prefs.getInt(key) ?? 0) + 1;
  await prefs.setInt(key, next);
  return _readTotalBadge(prefs);
}

int _readTotalBadge(SharedPreferences prefs) =>
    (prefs.getInt(_kBadgeChatKey) ?? 0) +
    (prefs.getInt(_kBadgeOtherKey) ?? 0);

// 지정 채널의 활성 알림을 모두 cancel.
// 서버가 FCM `notification` payload로 보내면 OS가 직접 표시하므로 고정 ID cancel 외에
// 채널 기반 enumerate로 나머지도 정리.
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
        // FCM이 notify(tag, id, ...) 로 띄운 알림은 tag가 있음.
        // cancel(id) 만 쓰면 tag 불일치로 취소가 안 되므로 tag도 같이 전달.
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
  required int total,
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
        number: total,
        actions: isChat && uid != null ? const [_replyAction] : null,
      ),
      iOS: DarwinNotificationDetails(
        presentSound: true,
        badgeNumber: total,
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
    // 채팅 알림만 cancel — anniversary/schedule 알림과 카운터는 보존.
    await plugin.cancel(_kChatNotifId);
    await _cancelActiveByChannel(plugin, 'chat_channel_v2');
    await prefs.setInt(_kBadgeChatKey, 0);
    await _syncIosBadge(plugin, _readTotalBadge(prefs));
    return;
  }

  // FCM 수신 시점에 Firebase가 초기화된 상태이므로 토큰을 강제 갱신·캐싱
  // → 이후 답장 핸들러에서 항상 유효한 토큰을 사용할 수 있도록 보장
  try {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) {
      final freshToken = await user.getIdToken(true);
      if (freshToken != null) {
        await prefs.setString(_kAuthTokenKey, freshToken);
        await prefs.setString(_kUserUidKey, user.uid);
      }
    }
  } catch (_) {}

  final isChat = type == null || type == 'chat';
  final total = await _incrementBadge(prefs, isChat: isChat);

  // notification 필드가 있으면 FCM이 OS 레벨에서 이미 표시함 → 수동 표시 생략
  // data-only 메시지(notification == null)일 때만 직접 표시
  final title = message.data['title'];
  final body = message.data['body'];
  if (message.notification == null && (title != null || body != null)) {
    final uid = prefs.getString(_kUserUidKey);
    await _showNotif(plugin,
        isChat: isChat, title: title, body: body, total: total, uid: uid);
  } else if (defaultTargetPlatform == TargetPlatform.iOS) {
    // OS가 직접 표시한 경우에도 iOS 배지를 prefs 총합으로 보정
    await _syncIosBadge(plugin, total);
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
      uid = (jsonDecode(response.payload!) as Map<String, dynamic>)['uid']
          as String?;
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

class FcmService with WidgetsBindingObserver {
  static final FcmService _instance = FcmService._internal();
  factory FcmService() => _instance;
  FcmService._internal();

  final FirebaseMessaging _messaging = FirebaseMessaging.instance;
  final FlutterLocalNotificationsPlugin _localNotifications =
      FlutterLocalNotificationsPlugin();

  // 채팅 화면이 열려 있을 때 포그라운드 FCM 알림 억제
  bool _isChatActive = false;
  void setChatActive(bool active) => _isChatActive = active;

  bool _initialized = false;

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

  // 채팅 읽음 처리: 채팅 알림 + 채팅 카운터만 0으로, anniversary/schedule 보존
  Future<void> clearChatNotifications() async {
    if (!_isMobile) return;
    final prefs = await _freshPrefs();
    await _localNotifications.cancel(_kChatNotifId);
    // FCM이 직접 표시한 채팅 알림도 cleanup (notification payload 모드)
    await _cancelActiveByChannel(_localNotifications, 'chat_channel_v2');
    await prefs.setInt(_kBadgeChatKey, 0);
    await _syncIosBadge(_localNotifications, _readTotalBadge(prefs));
  }

  // 캘린더/기념일 페이지 진입 시 호출: 카운터 0 + 실제 OS 알림도 cancel
  Future<void> clearOtherNotifications() async {
    if (!_isMobile) return;
    final prefs = await _freshPrefs();
    await _localNotifications.cancel(_kOtherNotifId);
    // FCM이 직접 표시한 기념일 알림도 cleanup
    await _cancelActiveByChannel(_localNotifications, 'anniversary_channel');
    await prefs.setInt(_kBadgeOtherKey, 0);
    await _syncIosBadge(_localNotifications, _readTotalBadge(prefs));
  }

  // 서버 truth-source(unread-count)로 chat 카운터를 강제 보정
  // — multi-device에서 다른 기기가 읽었을 때 이 기기 배지를 자가복구
  Future<void> syncChatBadgeFromServer() async {
    if (!_isMobile) return;
    try {
      final response =
          await ApiClient.get(Uri.parse(ApiEndpoints.chatUnreadCount));
      if (response.statusCode != 200) return;
      final body = ApiClient.decodeBody(response);
      if (body is! num) return;
      final serverCount = body.toInt();
      final prefs = await _freshPrefs();
      final localChat = prefs.getInt(_kBadgeChatKey) ?? 0;
      if (serverCount == 0) {
        await _localNotifications.cancel(_kChatNotifId);
        await _cancelActiveByChannel(_localNotifications, 'chat_channel_v2');
        await prefs.setInt(_kBadgeChatKey, 0);
      } else if (serverCount != localChat) {
        // 카운터만 보정 — 다음 새 메시지가 오면 알림 number도 갱신됨
        await prefs.setInt(_kBadgeChatKey, serverCount);
      }
      await _syncIosBadge(_localNotifications, _readTotalBadge(prefs));
    } catch (_) {}
  }

  // resumed 시 호출: 로컬 prefs를 OS 배지에 반영하고, 서버와도 chat 카운터를 sync
  Future<void> _resyncBadge() async {
    if (!_isMobile) return;
    final prefs = await _freshPrefs();
    await _syncIosBadge(_localNotifications, _readTotalBadge(prefs));
    // 서버 동기화는 백그라운드로 — 네트워크 실패해도 로컬 보정은 이미 완료
    unawaited(syncChatBadgeFromServer());
  }

  Future<void> initialize() async {
    if (!_isMobile || _initialized) return;
    _initialized = true;

    // 1. 알림 권한 요청
    await _messaging.requestPermission(
      alert: true,
      badge: true,
      sound: true,
    );

    // 2. 로컬 알림 초기화
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

    // 3. FCM 토큰 서버 전송 + 인증 정보 캐싱
    String? token = await _messaging.getToken();
    if (token != null) {
      await _sendTokenToServer(token);
    }
    await _cacheAuthInfo();

    _messaging.onTokenRefresh.listen((newToken) async {
      await _sendTokenToServer(newToken);
      await _cacheAuthInfo();
    });

    // 4. 알림 탭으로 앱 진입 처리
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

    // 5. 포그라운드 메시지 수신
    FirebaseMessaging.onMessage.listen(_onForegroundMessage);

    // 6. 라이프사이클 옵저버 등록 — resumed 시 iOS 배지를 prefs 총합으로 재동기화
    WidgetsBinding.instance.addObserver(this);
    // 시작 시점에도 한 번 보정 (백그라운드 카운터가 늘어난 상태에서 콜드부트 됐을 수 있음)
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

    final title = message.data['title'] as String?;
    final body = message.data['body'] as String?;
    if (title == null && body == null) return;

    final prefs = await _freshPrefs();
    final total = await _incrementBadge(prefs, isChat: isChat);
    final uid = FirebaseAuth.instance.currentUser?.uid;
    await _showNotif(_localNotifications,
        isChat: isChat, title: title, body: body, total: total, uid: uid);
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
      debugPrint('FCM 토큰 서버 전송 완료');
    } catch (e) {
      debugPrint('FCM 토큰 전송 실패: $e');
    }
  }
}
