import 'dart:async';
import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'api_client.dart';
import 'api_endpoints.dart';

// 알림 유무만 추적 (읽지 않은 알림이 있으면 1, 없으면 0).
// 정확한 카운트 대신 boolean 플래그로 관리해 race condition / 중복배달 문제를 원천 차단.
const _kBadgeChatKey = 'fcm_has_chat_notif';
const _kBadgeOtherKey = 'fcm_has_other_notif';

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

// 알림 플래그를 1로 세팅하고, 배지에 표시할 값(1)을 반환.
Future<int> _markBadge(SharedPreferences prefs,
    {required bool isChat}) async {
  await prefs.setInt(isChat ? _kBadgeChatKey : _kBadgeOtherKey, 1);
  final total = _readBadge(prefs);
  await _syncAndroidBadge(total);
  return total;
}

// Android 앱 아이콘 뱃지를 알림과 독립적으로 관리.
// notification.number 는 알림이 사라지면 뱃지도 함께 사라지므로,
// 알림을 스와이프해도 뱃지가 유지되려면 Samsung badge ContentProvider를 별도 호출해야 함.
// MainActivity의 MethodChannel을 통해 Kotlin 쪽에서 처리.
// 백그라운드 isolate(firebase_messaging)에서도 method channel이 등록되므로 동작하며,
// flutter_local_notifications isolate 등 미지원 환경에서는 silently 무시.
final _kBadgeChannel = const MethodChannel('com.example.usonly_client/badge');

Future<void> _syncAndroidBadge(int count) async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  try {
    await _kBadgeChannel.invokeMethod('updateBadge', {'count': count});
  } catch (_) {}
}

// 어느 쪽이든 알림이 있으면 1, 없으면 0.
int _readBadge(SharedPreferences prefs) =>
    ((prefs.getInt(_kBadgeChatKey) ?? 0) > 0 ||
            (prefs.getInt(_kBadgeOtherKey) ?? 0) > 0)
        ? 1
        : 0;

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
// 배지는 항상 1 (알림 있음/없음만 표시).
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
        number: 1,
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
    // 채팅 알림만 cancel — anniversary/schedule 알림과 플래그는 보존.
    await plugin.cancel(_kChatNotifId);
    await _cancelActiveByChannel(plugin, 'chat_channel_v2');
    await prefs.setInt(_kBadgeChatKey, 0);
    await _syncIosBadge(plugin, _readBadge(prefs));
    return;
  }

  // FCM 수신 시점에 Firebase는 초기화되어 있지만,
  // Firebase Auth는 내부 상태를 비동기로 로드하므로 currentUser가 즉시 null일 수 있음.
  // authStateChanges().first로 Auth 상태가 확정될 때까지 기다린 뒤 토큰을 갱신·캐싱.
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
  await _markBadge(prefs, isChat: isChat);

  // notification 필드가 있으면 FCM이 OS 레벨에서 이미 표시함 → 수동 표시 생략
  // data-only 메시지(notification == null)일 때만 직접 표시
  final title = message.data['title'];
  final body = message.data['body'];

  // Android 채팅 알림: CustomFcmService(Kotlin)가 네이티브로 표시하므로 여기선 생략.
  // Kotlin 네이티브 알림의 답장 action → NotificationReplyReceiver (Flutter isolate 불필요).
  final androidChat =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android && isChat;

  if (!androidChat && message.notification == null && (title != null || body != null)) {
    final uid = prefs.getString(_kUserUidKey);
    await _showNotif(plugin,
        isChat: isChat, title: title, body: body, uid: uid);
  } else if (defaultTargetPlatform == TargetPlatform.iOS) {
    await _syncIosBadge(plugin, 1);
  }
}

// 알림 답장 처리 핸들러 — showsUserInterface: true로 전환 후 이 핸들러는
// 앱이 완전히 종료(terminated)된 극단적 케이스에만 호출될 수 있음.
// 주 경로: showsUserInterface: true → 앱이 포그라운드로 오면서
//          _onForegroundNotificationResponse → _sendReplyFromForeground
// top-level 함수여야 하며, @pragma 필수
@pragma('vm:entry-point')
Future<void> notificationReplyHandler(NotificationResponse response) async {
  if (response.actionId != _kReplyActionId) return;

  final text = response.input?.trim();
  if (text == null || text.isEmpty) return;

  // 알림 취소
  final plugin = FlutterLocalNotificationsPlugin();
  try {
    await plugin.initialize(const InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
      iOS: DarwinInitializationSettings(),
    ));
    await plugin.cancel(_kChatNotifId);
    await _cancelActiveByChannel(plugin, 'chat_channel_v2');
  } catch (_) {}

  // flutter_local_notifications 백그라운드 isolate에서는 Firebase Auth currentUser가
  // 항상 null → Firebase 초기화 시도 자체를 제거하고 캐시된 토큰만 사용.
  // 토큰은 FCM 수신 시 firebaseMessagingBackgroundHandler에서 갱신·캐싱됨.
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

  // 채팅 화면이 열려 있을 때 포그라운드 FCM 알림 억제
  bool _isChatActive = false;
  void setChatActive(bool active) => _isChatActive = active;

  // 캘린더 화면이 열려 있을 때 포그라운드 schedule 알림 억제
  bool _isCalendarActive = false;
  void setCalendarActive(bool active) => _isCalendarActive = active;

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
  // getIdToken(true)로 강제 갱신 → 최대 1시간짜리 신선한 토큰을 보장
  Future<void> _cacheAuthInfo() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return;
      final token = await user.getIdToken(true); // 강제 갱신
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
    final total = _readBadge(prefs);
    await _syncIosBadge(_localNotifications, total);
    await _syncAndroidBadge(total);
  }

  // 캘린더/기념일 페이지 진입 시 호출: 플래그 0 + 실제 OS 알림도 cancel
  Future<void> clearOtherNotifications() async {
    if (!_isMobile) return;
    final prefs = await _freshPrefs();
    await _localNotifications.cancel(_kOtherNotifId);
    await _cancelActiveByChannel(_localNotifications, 'anniversary_channel');
    await prefs.setInt(_kBadgeOtherKey, 0);
    final total = _readBadge(prefs);
    await _syncIosBadge(_localNotifications, total);
    await _syncAndroidBadge(total);
  }

  // resumed 시 호출: iOS/Android 배지를 prefs 총합으로 보정.
  // 알림을 스와이프해서 사라진 경우에도 prefs 기준으로 뱃지를 복원.
  Future<void> _resyncBadge() async {
    if (!_isMobile) return;
    final prefs = await _freshPrefs();
    final total = _readBadge(prefs);
    await _syncIosBadge(_localNotifications, total);
    await _syncAndroidBadge(total);
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

    // Kotlin NotificationReplyReceiver가 읽을 API URL 캐싱
    // SharedPreferences에 저장 → Kotlin: "flutter.api_chats_url"
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('api_chats_url', ApiEndpoints.chats);
    }

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

  // 앱이 포그라운드일 때 알림 액션 처리
  void _onForegroundNotificationResponse(NotificationResponse response) {
    if (response.actionId == _kReplyActionId) {
      // 포그라운드에서는 Firebase 정상 동작하므로 바로 전송
      final text = response.input?.trim();
      if (text == null || text.isEmpty) return;
      // Samsung One UI: cancelNotification: true가 포그라운드에서도 무시됨 → 명시적 cancel
      _localNotifications.cancel(_kChatNotifId);
      _cancelActiveByChannel(_localNotifications, 'chat_channel_v2');
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
