import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:convert';
import 'album_detail_page.dart';
import 'api_config.dart';
import 'api_client.dart';

class AlbumPage extends StatefulWidget {
  final int memberId; // 우리 서버의 pk (member 테이블의 id)

  const AlbumPage({super.key, required this.memberId});

  @override
  State<AlbumPage> createState() => _AlbumPageState();
}

class _AlbumPageState extends State<AlbumPage> {
  List<dynamic> _albums = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  bool _isReorderMode = false;
  int _currentPage = 0;
  static const int _pageSize = 12;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _fetchAlbums();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 200
        && _hasMore && !_isLoadingMore) {
      _loadMore();
    }
  }

  // 서버에서 앨범 목록 가져오기 (첫 페이지)
  Future<void> _fetchAlbums() async {
    _currentPage = 0;
    try {
      final response = await ApiClient.get(
        Uri.parse('${ApiConfig.baseUrl}/api/archives/albums?page=0&size=$_pageSize'),
      );
      if (response.statusCode == 200) {
        final albums = jsonDecode(utf8.decode(response.bodyBytes)) as List;
        setState(() {
          _albums = albums;
          _hasMore = albums.length >= _pageSize;
          _isLoading = false;
        });
      }
    } catch (e) {
      print("앨범 로딩 에러: $e");
      setState(() => _isLoading = false);
    }
  }

  // 다음 페이지 로드
  Future<void> _loadMore() async {
    setState(() => _isLoadingMore = true);
    _currentPage++;
    try {
      final response = await ApiClient.get(
        Uri.parse('${ApiConfig.baseUrl}/api/archives/albums?page=$_currentPage&size=$_pageSize'),
      );
      if (response.statusCode == 200) {
        final more = jsonDecode(utf8.decode(response.bodyBytes)) as List;
        setState(() {
          _albums = [..._albums, ...more];
          _hasMore = more.length >= _pageSize;
        });
      }
    } catch (e) {
      print("앨범 추가 로딩 에러: $e");
    } finally {
      setState(() => _isLoadingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());

    return Scaffold(
      body: _albums.isEmpty
          ? const Center(child: Text("우리의 첫 번째 앨범을 만들어보세요!"))
          : Column(
              children: [
                // 순서 변경 토글 버튼
                Padding(
                  padding: const EdgeInsets.only(right: 8, top: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton.icon(
                        onPressed: () async {
                          if (_isReorderMode) await _saveOrder();
                          setState(() => _isReorderMode = !_isReorderMode);
                        },
                        icon: Icon(
                          _isReorderMode ? Icons.check : Icons.swap_vert,
                          color: const Color(0xFF8B7E74),
                          size: 18,
                        ),
                        label: Text(
                          _isReorderMode ? "완료" : "순서 변경",
                          style: const TextStyle(color: Color(0xFF8B7E74), fontSize: 13),
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _isReorderMode
                      ? _buildReorderableList()
                      : GridView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 2,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                            childAspectRatio: 0.85,
                          ),
                          itemCount: _albums.length,
                          itemBuilder: (context, index) {
                            final album = _albums[index];
                            return _buildAlbumCard(album);
                          },
                        ),
                ),
                if (_isLoadingMore && !_isReorderMode)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF8B7E74)),
                  ),
              ],
            ),
      floatingActionButton: _isReorderMode
          ? null
          : FloatingActionButton(
              onPressed: _showCreateAlbumDialog,
              backgroundColor: const Color(0xFF8B7E74),
              child: const Icon(Icons.add_a_photo, color: Colors.white),
            ),
    );
  }

  Widget _buildReorderableList() {
    return ReorderableListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      itemCount: _albums.length,
      onReorder: (oldIndex, newIndex) {
        setState(() {
          if (newIndex > oldIndex) newIndex--;
          final item = _albums.removeAt(oldIndex);
          _albums.insert(newIndex, item);
        });
      },
      itemBuilder: (context, index) {
        final album = _albums[index];
        return ListTile(
          key: ValueKey(album['id']),
          contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          leading: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: album['coverImageUrl'] != null
                ? CachedNetworkImage(
                    imageUrl: album['coverImageUrl'],
                    width: 56,
                    height: 56,
                    fit: BoxFit.cover,
                    memCacheWidth: 120,
                    placeholder: (context, url) => Container(
                      width: 56,
                      height: 56,
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    ),
                    errorWidget: (context, url, error) => Container(
                      width: 56,
                      height: 56,
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      child: const Icon(Icons.image, color: Colors.grey),
                    ),
                  )
                : Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.image, color: Colors.grey),
                  ),
          ),
          title: Text(
            album['title'] ?? "무제",
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 15),
          ),
          trailing: const Icon(Icons.drag_handle, color: Colors.grey),
        );
      },
    );
  }

  Future<void> _saveOrder() async {
    final ids = _albums.map((a) => a['id'] as int).toList();
    try {
      final response = await ApiClient.post(
        Uri.parse('${ApiConfig.baseUrl}/api/archives/reorder'),
        body: jsonEncode(ids),
      );
      if (response.statusCode != 200 && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("순서 저장에 실패했습니다")),
        );
      }
    } catch (e) {
      print("순서 변경 에러: $e");
    }
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
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
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
                        maxWidthDiskCache: 300,
                        placeholder: (context, url) => Container(color: Theme.of(context).colorScheme.surfaceContainerHighest),
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
      final response = await ApiClient.put(
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
      final response = await ApiClient.delete(
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
    final response = await ApiClient.post(
      Uri.parse('${ApiConfig.baseUrl}/api/archives/create?title=$title'),
    );
    if (response.statusCode == 200) {
      _fetchAlbums(); // 목록 새로고침
    }
  }
}