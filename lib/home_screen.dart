import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'auth_service.dart';
import 'chat_page.dart'; // ★ ChatPage 파일이 있어야 에러가 안 납니다!
import 'album_page.dart';
import 'anniversary_page.dart';
import 'calendar_page.dart';
import 'work_schedule_page.dart';

class HomeScreen extends StatefulWidget {
  final User? user;
  final String? testUid;
  final int memberId;

  const HomeScreen({super.key, this.user, this.testUid, required this.memberId});

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
      _MorePage(user: widget.user),
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
      body: SafeArea(child: _pages[_selectedIndex]),
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
  const _MorePage({this.user});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
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
                    Text(user?.email ?? '', style: TextStyle(fontSize: 14, color: Colors.grey[600])),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 40),
          // 근무 스케쥴 분석
          ListTile(
            leading: const Icon(Icons.calendar_view_week, color: Color(0xFF8B7E74)),
            title: const Text('근무 스케쥴 분석', style: TextStyle(color: Color(0xFF8B7E74))),
            subtitle: const Text('스케쥴표 사진으로 내 근무 확인', style: TextStyle(fontSize: 12)),
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
    );
  }
}