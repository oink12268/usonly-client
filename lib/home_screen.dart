import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'dart:convert';
import 'auth_service.dart';
import 'debug_log_screen.dart';
import 'font_size_notifier.dart';
import 'theme_notifier.dart';
import 'chat_page.dart'; // ★ ChatPage 파일이 있어야 에러가 안 납니다!
import 'album_page.dart';
import 'anniversary_page.dart';
import 'calendar_page.dart';
import 'note_page.dart';
import 'work_schedule_page.dart';
import 'dino_game_page.dart';
import 'profile_edit_page.dart';
import 'notification_settings_page.dart';
import 'api_client.dart';
import 'api_endpoints.dart';
import 'share_intent_service.dart';
import 'fcm_service.dart';
import 'anniversary_page.dart';

class HomeScreen extends StatefulWidget {
  final User? user;
  final String? testUid;
  final int memberId;
  final int? coupleId;

  const HomeScreen({super.key, this.user, this.testUid, required this.memberId, this.coupleId});

  String get uid => user?.uid ?? testUid ?? '';

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _selectedIndex = 2; // 처음엔 채팅 탭
  late final List<Widget> _pages;
  StreamSubscription? _shareSubscription;

  @override
  void initState() {
    super.initState();
    _shareSubscription = ShareIntentService().stream.listen((_) {
      if (mounted) setState(() => _selectedIndex = 2);
    });

    // FCM 알림 탭 → 타입에 따라 네비게이션
    FcmService().onNavigate = (String type) {
      if (!mounted) return;
      _navigateByNotificationType(type);
    };
    // 앱이 종료 상태에서 알림 탭으로 열린 경우
    final pendingType = FcmService().consumePendingNavigation();
    if (pendingType != null) {
      if (pendingType == 'anniversary') {
        _selectedIndex = 4;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            Navigator.push(context, MaterialPageRoute(
              builder: (_) => AnniversaryPage(memberId: widget.memberId),
            ));
          }
        });
      } else {
        _selectedIndex = 2; // 채팅 탭 (기본)
      }
    }

_pages = [
      AlbumPage(memberId: widget.memberId),
      CalendarPage(memberId: widget.memberId),
      ChatPage(uid: widget.uid),
      NotePage(memberId: widget.memberId, coupleId: widget.coupleId),
      _MorePage(user: widget.user, memberId: widget.memberId, coupleId: widget.coupleId),
    ];
  }

  @override
  void dispose() {
    _shareSubscription?.cancel();
    FcmService().onNavigate = null;
    super.dispose();
  }

  void _navigateByNotificationType(String type) {
    if (type == 'anniversary') {
      setState(() => _selectedIndex = 4);
      Navigator.push(context, MaterialPageRoute(
        builder: (_) => AnniversaryPage(memberId: widget.memberId),
      ));
    } else {
      setState(() => _selectedIndex = 2); // 채팅 탭 (기본)
    }
  }

  void _onItemTapped(int index) {
    setState(() {
      _selectedIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: null,
      // bottom: false → BottomNavigationBar가 이미 하단 여백 처리함
      // SafeArea의 bottom padding이 키보드 등장 시 동적으로 0이 되면서
      // 입력창이 키보드 위에 붙은 직후 한 번 더 올라가는 2차 점프 원인
      body: SafeArea(bottom: false, child: _pages[_selectedIndex]),
      bottomNavigationBar: MediaQuery(
        data: MediaQuery.of(context).copyWith(
          padding: MediaQuery.of(context).padding.copyWith(
            bottom: MediaQuery.of(context).padding.bottom + 8,
          ),
        ),
        child: BottomNavigationBar(
          type: BottomNavigationBarType.fixed,
          currentIndex: _selectedIndex,
          onTap: _onItemTapped,
          items: const [
            BottomNavigationBarItem(icon: Icon(Icons.photo_album), label: '앨범'),
            BottomNavigationBarItem(icon: Icon(Icons.calendar_month), label: '캘린더'),
            BottomNavigationBarItem(icon: Icon(Icons.chat), label: '채팅'),
            BottomNavigationBarItem(icon: Icon(Icons.note_outlined), label: '메모장'),
            BottomNavigationBarItem(icon: Icon(Icons.more_horiz), label: '더보기'),
          ],
        ),
      ),
    );
  }
}

class _MorePage extends StatefulWidget {
  final User? user;
  final int memberId;
  final int? coupleId;
  const _MorePage({this.user, required this.memberId, this.coupleId});

  @override
  State<_MorePage> createState() => _MorePageState();
}

// 버전 변경 이력 (최신순)
const _changelog = [
  (
    version: '1.0.0',
    date: '2026.04.15',
    changes: [
      'PDF 파일 뷰어 지원',
      '채팅 파일 전송 개선',
      '메모 에디터 취소선 버튼 추가',
      '메모 에디터 이미지 업로드 오류 수정',
    ]
  ),
  (
    version: '0.9.5',
    date: '2026.03.30',
    changes: [
      '채팅 전체화면 이미지 저장 버튼 추가',
      '앨범 날짜 일괄 수정 기능 추가',
      '날짜 전송 로컬타임 버그 수정',
    ]
  ),
  (
    version: '0.9.0',
    date: '2026.03.01',
    changes: [
      '채팅 답장(Reply) 기능 추가',
      '채팅 이미지/파일 전송 개선',
      '다크모드 지원',
      '글자 크기 설정 추가',
    ]
  ),
];

class _MorePageState extends State<_MorePage> {
  String? _nickname;
  String? _profileImageUrl;
  String _appVersion = '';

  // 숨은 디버그 메뉴 진입: 빈공간 7번 탭
  int _debugTapCount = 0;
  Timer? _debugTapTimer;

  void _onDebugAreaTap() {
    _debugTapCount++;
    _debugTapTimer?.cancel();
    _debugTapTimer = Timer(const Duration(seconds: 2), () {
      _debugTapCount = 0;
    });
    if (_debugTapCount >= 7) {
      _debugTapCount = 0;
      _debugTapTimer?.cancel();
      Navigator.push(context, MaterialPageRoute(builder: (_) => const DebugLogScreen()));
    }
  }

  @override
  void dispose() {
    _debugTapTimer?.cancel();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadProfile();
    _loadAppVersion();
  }

  Future<void> _loadAppVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) setState(() => _appVersion = info.version);
  }

  void _showChangelogDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('업데이트 내역'),
        contentPadding: const EdgeInsets.fromLTRB(0, 12, 0, 0),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: _changelog.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final entry = _changelog[i];
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          'v${entry.version}',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 15,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          entry.date,
                          style: TextStyle(
                            fontSize: 12,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    ...entry.changes.map((c) => Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('• ', style: TextStyle(fontSize: 13)),
                          Expanded(child: Text(c, style: const TextStyle(fontSize: 13))),
                        ],
                      ),
                    )),
                  ],
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('확인'),
          ),
        ],
      ),
    );
  }

  Future<void> _loadProfile() async {
    try {
      final response = await ApiClient.get(Uri.parse(ApiEndpoints.me));
      if (response.statusCode == 200 && mounted) {
        final data = ApiClient.decodeBody(response) as Map<String, dynamic>;
        setState(() {
          _nickname = data['nickname'];
          _profileImageUrl = data['profileImageUrl'];
        });
      }
    } catch (e) {
      debugPrint("프로필 로딩 실패: $e");
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([fontSizeNotifier, themeNotifier]),
      builder: (context, _) => SafeArea(
      child: ListView(
        children: [
          const SizedBox(height: 20),
          // ── 프로필 영역 (탭하면 수정 페이지로) ──
          InkWell(
            onTap: () async {
              final changed = await Navigator.push<bool>(
                context,
                MaterialPageRoute(
                  builder: (_) => ProfileEditPage(
                    memberId: widget.memberId,
                    initialNickname: _nickname,
                    initialProfileImageUrl: _profileImageUrl,
                  ),
                ),
              );
              if (changed == true) _loadProfile();
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: Row(
                children: [
                  Stack(
                    children: [
                      CircleAvatar(
                        radius: 30,
                        backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                        backgroundImage: _profileImageUrl != null
                            ? CachedNetworkImageProvider(_profileImageUrl!)
                            : null,
                        child: _profileImageUrl == null
                            ? const Icon(Icons.person, size: 30)
                            : null,
                      ),
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: Container(
                          padding: const EdgeInsets.all(3),
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          child: Icon(Icons.edit, size: 11, color: Theme.of(context).colorScheme.onPrimary),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _nickname ?? widget.user?.displayName ?? '',
                          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                        Text(
                          widget.user?.email ?? '',
                          style: TextStyle(fontSize: 14, color: Theme.of(context).colorScheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right, color: Theme.of(context).colorScheme.onSurfaceVariant),
                ],
              ),
            ),
          ),
          const Divider(height: 40),
          // 기념일
          ListTile(
            leading: const Icon(Icons.favorite),
            title: const Text('기념일'),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => AnniversaryPage(memberId: widget.memberId),
                ),
              );
            },
          ),
          // 미니 게임
          ListTile(
            leading: const Icon(Icons.sports_esports),
            title: const Text('디노 런 🦖'),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const DinoGamePage()),
              );
            },
          ),
          // 알림 설정
          ListTile(
            leading: const Icon(Icons.notifications_outlined),
            title: const Text('알림 설정'),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const NotificationSettingsPage(),
                ),
              );
            },
          ),
          const Divider(height: 20),
          // 다크모드
          SwitchListTile(
            secondary: const Icon(Icons.dark_mode_outlined),
            title: const Text('다크모드'),
            value: themeNotifier.isDark,
            activeColor: Theme.of(context).colorScheme.primary,
            onChanged: (_) => themeNotifier.toggle(),
          ),
          // 글자 크기
          ListTile(
            leading: const Icon(Icons.text_fields),
            title: const Text('글자 크기'),
            trailing: SegmentedButton<double>(
              segments: const [
                ButtonSegment(value: 0.85, label: Text('작게')),
                ButtonSegment(value: 1.0, label: Text('보통')),
                ButtonSegment(value: 1.2, label: Text('크게')),
              ],
              selected: {fontSizeNotifier.scale},
              onSelectionChanged: (selected) {
                fontSizeNotifier.setScale(selected.first);
              },
              style: ButtonStyle(
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
                foregroundColor: WidgetStateProperty.resolveWith((states) =>
                  states.contains(WidgetState.selected)
                    ? Theme.of(context).colorScheme.onPrimary
                    : Theme.of(context).colorScheme.onSurface,
                ),
                backgroundColor: WidgetStateProperty.resolveWith((states) =>
                  states.contains(WidgetState.selected)
                    ? Theme.of(context).colorScheme.primary
                    : Colors.transparent,
                ),
              ),
            ),
          ),
          const Divider(height: 20),
          // 버전 정보
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('버전 정보'),
            trailing: Text(
              _appVersion.isNotEmpty ? 'v$_appVersion' : '',
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            onTap: _showChangelogDialog,
          ),
          // 로그아웃
          if (widget.user != null)
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('로그아웃'),
              onTap: () async {
                await AuthService().signOut();
              },
            ),
          // 숨은 디버그 진입 영역 (7번 빠르게 탭)
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _onDebugAreaTap,
            child: const SizedBox(height: 80),
          ),
        ],
      ),
    ),   // ListenableBuilder 끝
    );
  }
}