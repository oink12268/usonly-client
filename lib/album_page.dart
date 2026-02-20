import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:convert';
import 'album_detail_page.dart'; // 곧 만들 상세 페이지
import 'api_config.dart';

class AlbumPage extends StatefulWidget {
  final int memberId; // 우리 서버의 pk (member 테이블의 id)

  const AlbumPage({super.key, required this.memberId});

  @override
  State<AlbumPage> createState() => _AlbumPageState();
}

class _AlbumPageState extends State<AlbumPage> {
  List<dynamic> _albums = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchAlbums();
  }

  // 서버에서 앨범 목록 가져오기 (우리 커플 것만)
  Future<void> _fetchAlbums() async {
    try {
      final response = await http.get(
        // userId를 쿼리 파라미터로 넘겨서 서버가 내 커플 정보를 찾게 함
        Uri.parse('${ApiConfig.baseUrl}/api/archives/albums?userId=${widget.memberId}'),
      );

      if (response.statusCode == 200) {
        setState(() {
          _albums = jsonDecode(utf8.decode(response.bodyBytes));
          _isLoading = false;
        });
      }
    } catch (e) {
      print("앨범 로딩 에러: $e");
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    return Scaffold(
      backgroundColor: Colors.white,
      body: _albums.isEmpty
          ? const Center(child: Text("우리의 첫 번째 앨범을 만들어보세요!"))
          : GridView.builder(
              padding: const EdgeInsets.all(12),
              // ★ 2열(2x무한) 격자 설정
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,         // 가로 갯수
                crossAxisSpacing: 12,      // 가로 간격
                mainAxisSpacing: 12,       // 세로 간격
                childAspectRatio: 0.85,    // 카드 높이 조절
              ),
              itemCount: _albums.length,
              itemBuilder: (context, index) {
                final album = _albums[index];
                return _buildAlbumCard(album);
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showCreateAlbumDialog,
        backgroundColor: const Color(0xFF8B7E74),
        child: const Icon(Icons.add_a_photo, color: Colors.white),
      ),
    );
  }

  // 앨범 하나하나의 카드 디자인
  Widget _buildAlbumCard(dynamic album) {
    return GestureDetector(
      onTap: () async {
        // 상세 페이지로 이동 (albumId 전달) — 돌아오면 새로고침
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => AlbumDetailPage(albumId: album['id'], memberId: widget.memberId)),
        );
        _fetchAlbums();
      },
      onLongPress: () => _showAlbumOptions(album),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: Colors.grey[100],
                boxShadow: [
                  BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(2, 2))
                ],
              ),
              child: album['coverImageUrl'] != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: CachedNetworkImage(
                        imageUrl: album['coverImageUrl'],
                        fit: BoxFit.cover,
                        width: double.infinity,
                        height: double.infinity,
                        memCacheWidth: 300,
                        placeholder: (context, url) => const Center(
                          child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF8B7E74))),
                        ),
                        errorWidget: (context, url, error) => const Center(child: Icon(Icons.error, color: Colors.grey)),
                      ),
                    )
                  : const Center(child: Icon(Icons.image, size: 40, color: Colors.grey)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 4),
            child: Text(
              album['title'] ?? "무제",
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  // 앨범 롱프레스 → 수정/삭제 옵션
  void _showAlbumOptions(dynamic album) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.edit, color: const Color(0xFF8B7E74)),
              title: const Text("앨범 이름 수정"),
              onTap: () {
                Navigator.pop(context);
                _showRenameDialog(album);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text("앨범 삭제"),
              onTap: () {
                Navigator.pop(context);
                _confirmDeleteAlbum(album['id']);
              },
            ),
          ],
        ),
      ),
    );
  }

  // 앨범 이름 수정 다이얼로그
  void _showRenameDialog(dynamic album) {
    final controller = TextEditingController(text: album['title']);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("앨범 이름 수정"),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: "새 앨범 이름"),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("취소")),
          ElevatedButton(
            onPressed: () async {
              if (controller.text.isNotEmpty) {
                await _renameAlbum(album['id'], controller.text);
                Navigator.pop(context);
              }
            },
            child: const Text("수정"),
          ),
        ],
      ),
    );
  }

  Future<void> _renameAlbum(int albumId, String title) async {
    try {
      final response = await http.put(
        Uri.parse('${ApiConfig.baseUrl}/api/archives/$albumId?title=${Uri.encodeComponent(title)}'),
      );
      if (response.statusCode == 200) {
        _fetchAlbums();
      }
    } catch (e) {
      print("앨범 수정 에러: $e");
    }
  }

  // 앨범 삭제 확인
  void _confirmDeleteAlbum(int albumId) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("앨범 삭제"),
        content: const Text("앨범과 사진이 모두 삭제됩니다. 정말 삭제할까요?"),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("취소")),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              await _deleteAlbum(albumId);
              Navigator.pop(context);
            },
            child: const Text("삭제", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteAlbum(int albumId) async {
    try {
      final response = await http.delete(
        Uri.parse('${ApiConfig.baseUrl}/api/archives/$albumId'),
      );
      if (response.statusCode == 200) {
        _fetchAlbums();
      }
    } catch (e) {
      print("앨범 삭제 에러: $e");
    }
  }

  // 앨범 생성 팝업
  void _showCreateAlbumDialog() {
    final TextEditingController titleController = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("새 앨범 만들기"),
        content: TextField(
          controller: titleController,
          decoration: const InputDecoration(hintText: "앨범 이름을 입력하세요"),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("취소")),
          ElevatedButton(
            onPressed: () async {
              if (titleController.text.isNotEmpty) {
                await _createAlbum(titleController.text);
                Navigator.pop(context);
              }
            },
            child: const Text("만들기"),
          ),
        ],
      ),
    );
  }

  // 서버에 앨범 생성 요청
  Future<void> _createAlbum(String title) async {
    final response = await http.post(
      Uri.parse('${ApiConfig.baseUrl}/api/archives/create?title=$title&userId=${widget.memberId}'),
    );
    if (response.statusCode == 200) {
      _fetchAlbums(); // 목록 새로고침
    }
  }
}