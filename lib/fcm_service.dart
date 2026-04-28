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
// 알림 ID 누적 — 카테고리별로 cancel 가능하도록 type별 분리.
// 채팅: clear_chat / 채팅 진입 시 chat 알림만 cancel (anniversary 보존)
// other: 캘린더/기념일 진입 시 other 알림만 cancel (chat 보존)
const _kChatNotifIdsKey = 'fcm_chat_notification_ids';
const _kOtherNotifIdsKey = 'fcm_other_notification_ids';
const _kAuthTokenKey = 'cached_firebase_token';
const _kUserUidKey = 'cached_user_uid';
const _kReplyActionId = 'chat_reply_action';
// iOS 배지 강제 갱신용 silent notification ID — 일반 알림 ID와 충돌 안 나도록 별도 영역
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

// 충돌 없는 알림 ID 생성 — 시간 기반 unique 값 (Android int 범위로 한정).
// _kIosBadgeSyncId 영역과 분리되도록 상한 0x7FFFFFF0.
int _generateNotificationId() =>
    DateTime.now().millisecondsSinceEpoch.remainder(0x7FFFFFF0);

// SharedPreferences는 isolate별 in-memory 캐시를 가짐 — 백그라운드 isolate가
// 디스크에 쓴 값이 포그라운드 캐시에 자동 반영되지 않아 stale read 발생.
// 배지 상태를 만지기 전에는 항상 reload()로 디스크에서 최신 값을 끌어와야 함.
Future<SharedPreferences> _freshPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.reload();
  return prefs;
}

// prefs 기반 atomic 카운터 증가. 메모리 캐시를 두지 않아 fg/bg isolate 간 desync 차단.
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

Future<void> _appendNotifId(SharedPreferences prefs, int id,
    {required bool isChat}) async {
  final key = isChat ? _kChatNotifIdsKey : _kOtherNotifIdsKey;
  final list = prefs.getStringList(key) ?? <String>[];
  list.add(id.toString());
  await prefs.setStringList(key, list);
}

Future<List<int>> _drainNotifIds(SharedPreferences prefs,
    {required bool isChat}) async {
  final key = isChat ? _kChatNotifIdsKey : _kOtherNotifIdsKey;
  final list = prefs.getStringList(key) ?? <String>[];
  await prefs.setStringList(key, <String>[]);
  return list.map(int.parse).toList();
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
    final ids = await _drainNotifIds(prefs, isChat: true);
    for (final id in ids) {
      await plugin.cancel(id);
    }
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
    final id = _generateNotificationId();
    await _appendNotifId(prefs, id, isChat: isChat);
    await plugin.show(
      id,
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
    final ids = await _drainNotifIds(prefs, isChat: true);
    for (final id in ids) {
      await _localNotifications.cancel(id);
    }
    await prefs.setInt(_kBadgeChatKey, 0);
    await _syncIosBadge(_localNotifications, _readTotalBadge(prefs));
  }

  // 캘린더/기념일 페이지 진입 시 호출: 카운터 0 + 실제 OS 알림도 cancel
  // (counter만 0으로 두면 알림 패널엔 남아있어 사용자 혼란 + Android 런처 자동 카운트와 desync)
  Future<void> clearOtherNotifications() async {
    if (!_isMobile) return;
    final prefs = await _freshPrefs();
    final ids = await _drainNotifIds(prefs, isChat: false);
    for (final id in ids) {
      await _localNotifications.cancel(id);
    }
    await prefs.setInt(_kBadgeOtherKey, 0);
    await _syncIosBadge(_localNotifications, _readTotalBadge(prefs));
  }

  // 서버 truth-source(unread-count)로 chat 카운터를 강제 보정
  // — multi-device에서 다른 기기가 읽었을 때 이 기기 배지를 자가복구
  Future<void> syncChatBadgeFromServer() async {
    if (!_isMobile) return;
    try {
      final response = await ApiClient.get(Uri.parse(ApiEndpoints.chatUnreadCount));
      if (response.statusCode != 200) return;
      final body = ApiClient.decodeBody(response);
      if (body is! num) return;
      final serverCount = body.toInt();
      final prefs = await _freshPrefs();
      final localChat = prefs.getInt(_kBadgeChatKey) ?? 0;
      // 서버가 더 작다면 다른 기기가 읽은 것 → 카운터 + 알림(오래된 것부터) 동시 정리
      // 서버가 더 크다면 우리가 놓친 것 → 서버 값으로 보정 (다음 chat FCM이 가시성 회복)
      if (serverCount == 0) {
        final ids = await _drainNotifIds(prefs, isChat: true);
        for (final id in ids) {
          await _localNotifications.cancel(id);
        }
        await prefs.setInt(_kBadgeChatKey, 0);
      } else if (serverCount < localChat) {
        // 초과분만큼 가장 오래된 chat 알림부터 cancel (list 앞쪽 = 오래된 것)
        final list = prefs.getStringList(_kChatNotifIdsKey) ?? <String>[];
        final excess = list.length - serverCount;
        if (excess > 0) {
          final toCancel = list.sublist(0, excess);
          final remain = list.sublist(excess);
          for (final s in toCancel) {
            await _localNotifications.cancel(int.parse(s));
          }
          await prefs.setStringList(_kChatNotifIdsKey, remain);
        }
        await prefs.setInt(_kBadgeChatKey, serverCount);
      } else if (serverCount > localChat) {
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
    final initialMessage =
        await FirebaseMessaging.instance.getInitialMessage();
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
    final id = _generateNotificationId();
    await _appendNotifId(prefs, id, isChat: isChat);
    final uid = FirebaseAuth.instance.currentUser?.uid;
    await _localNotifications.show(
      id,
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
          actions: isChat ? const [_replyAction] : null,
        ),
        iOS: DarwinNotificationDetails(
          presentSound: true,
          badgeNumber: total,
        ),
      ),
      payload: uid != null ? jsonEncode({'uid': uid}) : null,
    );
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
