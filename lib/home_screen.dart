import 'dart:async';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:convert';
import 'auth_service.dart';
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
import 'api_config.dart';
import 'api_client.dart';
import 'share_intent_service.dart';
import 'fcm_service.dart';

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

    // FCM 알림 탭 → 채팅 탭으로 이동
    FcmService().onNavigateToTab = (int index) {
      if (mounted) setState(() => _selectedIndex = index);
    };
    // 앱이 종료 상태에서 알림 탭으로 열린 경우
    final pendingTab = FcmService().consumePendingNavigation();
    if (pendingTab != null) _selectedIndex = pendingTab;

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
    FcmService().onNavigateToTab = null;
    super.dispose();
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
      bottomNavigationBar: BottomNavigationBar(
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

class _MorePageState extends State<_MorePage> {
  String? _nickname;
  String? _profileImageUrl;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    try {
      final response = await ApiClient.get(
        Uri.parse('${ApiConfig.baseUrl}/api/members/me'),
      );
      if (response.statusCode == 200 && mounted) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
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
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.black,
                          ),
                          child: const Icon(Icons.edit, size: 11, color: Colors.white),
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
                  const Icon(Icons.chevron_right, color: Colors.grey),
                ],
              ),
            ),
          ),
          const Divider(height: 40),
          // 기념일
          ListTile(
            leading: const Icon(Icons.favorite, color: Colors.black),
            title: const Text('기념일', style: TextStyle(color: Colors.black)),
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
            leading: const Icon(Icons.sports_esports, color: Colors.black),
            title: const Text('디노 런 🦖', style: TextStyle(color: Colors.black)),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const DinoGamePage()),
              );
            },
          ),
          const Divider(height: 20),
          // 다크모드
          SwitchListTile(
            secondary: const Icon(Icons.dark_mode_outlined, color: Colors.black),
            title: const Text('다크모드', style: TextStyle(color: Colors.black)),
            value: themeNotifier.isDark,
            activeColor: Colors.black,
            onChanged: (_) => themeNotifier.toggle(),
          ),
          // 글자 크기
          ListTile(
            leading: const Icon(Icons.text_fields, color: Colors.black),
            title: const Text('글자 크기', style: TextStyle(color: Colors.black)),
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
                    ? Colors.white
                    : Colors.black,
                ),
                backgroundColor: WidgetStateProperty.resolveWith((states) =>
                  states.contains(WidgetState.selected)
                    ? Colors.black
                    : Colors.transparent,
                ),
              ),
            ),
          ),
          const Divider(height: 20),
          // 로그아웃
          if (widget.user != null)
            ListTile(
              leading: const Icon(Icons.logout, color: Colors.black),
              title: const Text('로그아웃', style: TextStyle(color: Colors.black)),
              onTap: () async {
                await AuthService().signOut();
              },
            ),
        ],
      ),
    ),   // ListenableBuilder 끝
    );
  }
}