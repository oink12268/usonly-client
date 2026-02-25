import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'auth_service.dart';
import 'font_size_notifier.dart';
import 'theme_notifier.dart';
import 'chat_page.dart'; // ★ ChatPage 파일이 있어야 에러가 안 납니다!
import 'album_page.dart';
import 'anniversary_page.dart';
import 'calendar_page.dart';
import 'note_page.dart';
import 'work_schedule_page.dart';

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

  @override
  void initState() {
    super.initState();
_pages = [
      AlbumPage(memberId: widget.memberId),
      CalendarPage(memberId: widget.memberId),
      ChatPage(uid: widget.uid),
      AnniversaryPage(memberId: widget.memberId),
      _MorePage(user: widget.user, memberId: widget.memberId, coupleId: widget.coupleId),
    ];
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
        selectedItemColor: const Color(0xFF8B7E74),
        unselectedItemColor: const Color(0xFFD4C5B9),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.photo_album), label: '앨범'),
          BottomNavigationBarItem(icon: Icon(Icons.calendar_month), label: '캘린더'),
          BottomNavigationBarItem(icon: Icon(Icons.chat), label: '채팅'),
          BottomNavigationBarItem(icon: Icon(Icons.favorite), label: '기념일'),
          BottomNavigationBarItem(icon: Icon(Icons.more_horiz), label: '더보기'),
        ],
      ),
    );
  }
}

class _MorePage extends StatelessWidget {
  final User? user;
  final int memberId;
  final int? coupleId;
  const _MorePage({this.user, required this.memberId, this.coupleId});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([fontSizeNotifier, themeNotifier]),
      builder: (context, _) => SafeArea(
      child: ListView(
        children: [
          const SizedBox(height: 20),
          // 프로필 영역
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                CircleAvatar(
                  radius: 30,
                  backgroundImage: user?.photoURL != null ? NetworkImage(user!.photoURL!) : null,
                  child: user?.photoURL == null ? const Icon(Icons.person, size: 30) : null,
                ),
                const SizedBox(width: 16),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(user?.displayName ?? '테스트 유저', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    Text(user?.email ?? '', style: TextStyle(fontSize: 14, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 40),
          // 메모장
          ListTile(
            leading: const Icon(Icons.note_outlined, color: Color(0xFF8B7E74)),
            title: const Text('메모장', style: TextStyle(color: Color(0xFF8B7E74))),
            // subtitle: const Text('커플 공유 마크다운 메모', style: TextStyle(fontSize: 12)),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => NotePage(memberId: memberId, coupleId: coupleId),
                ),
              );
            },
          ),
          // 근무 스케쥴
          ListTile(
            leading: const Icon(Icons.calendar_view_week, color: Color(0xFF8B7E74)),
            title: const Text('근무 스케쥴', style: TextStyle(color: Color(0xFF8B7E74))),
            // subtitle: const Text('스케쥴표 사진으로 내 근무 확인', style: TextStyle(fontSize: 12)),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => WorkSchedulePage(nickname: user?.displayName),
                ),
              );
            },
          ),
          const Divider(height: 20),
          // 다크모드
          SwitchListTile(
            secondary: const Icon(Icons.dark_mode_outlined, color: Color(0xFF8B7E74)),
            title: const Text('다크모드', style: TextStyle(color: Color(0xFF8B7E74))),
            value: themeNotifier.isDark,
            activeColor: const Color(0xFF8B7E74),
            onChanged: (_) => themeNotifier.toggle(),
          ),
          // 글자 크기
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              children: [
                const Icon(Icons.text_fields, color: Color(0xFF8B7E74)),
                const SizedBox(width: 16),
                const Text('글자 크기', style: TextStyle(color: Color(0xFF8B7E74), fontSize: 16)),
                const Spacer(),
                SegmentedButton<double>(
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
                    foregroundColor: WidgetStateProperty.resolveWith((states) =>
                      states.contains(WidgetState.selected)
                        ? Colors.white
                        : const Color(0xFF8B7E74),
                    ),
                    backgroundColor: WidgetStateProperty.resolveWith((states) =>
                      states.contains(WidgetState.selected)
                        ? const Color(0xFF8B7E74)
                        : Colors.transparent,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 20),
          // 로그아웃
          if (user != null)
            ListTile(
              leading: const Icon(Icons.logout, color: Color(0xFF8B7E74)),
              title: const Text('로그아웃', style: TextStyle(color: Color(0xFF8B7E74))),
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