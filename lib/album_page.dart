import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:convert';
import 'album_detail_page.dart';
import 'photo_gallery_page.dart';
import 'api_config.dart';
import 'api_client.dart';

// ─────────────────────────────────────────────
// AlbumPage: 앨범/사진 전환 + FAB 관리 루트 위젯
// ─────────────────────────────────────────────
class AlbumPage extends StatefulWidget {
  final int memberId;

  const AlbumPage({super.key, required this.memberId});

  @override
  State<AlbumPage> createState() => _AlbumPageState();
}

class _AlbumPageState extends State<AlbumPage> {
  bool _showPhotos = false;
  bool _isReorderMode = false;

  final _albumListKey = GlobalKey<_AlbumListContentState>();
  final _galleryKey = GlobalKey<PhotoGalleryPageState>();

  // ── 앨범 생성 다이얼로그 ──
  void _showCreateAlbumDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("새 앨범 만들기"),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: "앨범 이름을 입력하세요"),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("취소")),
          ElevatedButton(
            onPressed: () async {
              if (controller.text.isNotEmpty) {
                final response = await ApiClient.post(
                  Uri.parse('${ApiConfig.baseUrl}/api/archives/create?title=${controller.text}'),
                );
                if (response.statusCode == 200) {
                  _albumListKey.currentState?._fetchAlbums();
                }
                if (mounted) Navigator.pop(context);
              }
            },
            child: const Text("만들기"),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // ── 콘텐츠 영역 (IndexedStack으로 상태 보존) ──
          Positioned.fill(
            child: IndexedStack(
              index: _showPhotos ? 1 : 0,
              children: [
                _AlbumListContent(
                  key: _albumListKey,
                  memberId: widget.memberId,
                  isReorderMode: _isReorderMode,
                  onEnterReorder: () => setState(() => _isReorderMode = true),
                ),
                PhotoGalleryPage(
                  key: _galleryKey,
                  memberId: widget.memberId,
                ),
              ],
            ),
          ),

          // ── FAB 영역 ──
          if (_isReorderMode)
            // 순서 변경 모드: 완료 버튼만 표시
            Positioned(
              bottom: 24,
              right: 16,
              child: FloatingActionButton.extended(
                heroTag: 'reorderDone',
                onPressed: () async {
                  await _albumListKey.currentState?._saveOrder();
                  setState(() => _isReorderMode = false);
                },
                backgroundColor: const Color(0xFF8B7E74),
                icon: const Icon(Icons.check, color: Colors.white),
                label: const Text("완료", style: TextStyle(color: Colors.white)),
              ),
            )
          else ...[
            // 상단 소형 FAB: 앨범 ↔ 사진 전환
            Positioned(
              bottom: 92,
              right: 16,
              child: FloatingActionButton.small(
                heroTag: 'viewToggle',
                onPressed: () => setState(() => _showPhotos = !_showPhotos),
                backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
                foregroundColor: Theme.of(context).colorScheme.onSecondaryContainer,
                elevation: 2,
                child: Icon(
                  _showPhotos ? Icons.auto_stories_rounded : Icons.collections_rounded,
                ),
              ),
            ),
            // 하단 메인 FAB: 새 앨범 / 사진 추가
            Positioned(
              bottom: 24,
              right: 16,
              child: FloatingActionButton(
                heroTag: 'mainAction',
                onPressed: _showPhotos
                    ? () => _galleryKey.currentState?.pickAndUploadImage()
                    : _showCreateAlbumDialog,
                backgroundColor: const Color(0xFF8B7E74),
                child: Icon(
                  _showPhotos ? Icons.add_a_photo : Icons.add,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// _AlbumListContent: 앨범 목록 (FAB·Scaffold 없음)
// ─────────────────────────────────────────────
class _AlbumListContent extends StatefulWidget {
  final int memberId;
  final bool isReorderMode;
  final VoidCallback onEnterReorder;

  const _AlbumListContent({
    super.key,
    required this.memberId,
    required this.isReorderMode,
    required this.onEnterReorder,
  });

  @override
  State<_AlbumListContent> createState() => _AlbumListContentState();
}

class _AlbumListContentState extends State<_AlbumListContent> {
  List<dynamic> _albums = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
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
      debugPrint("앨범 로딩 에러: $e");
      setState(() => _isLoading = false);
    }
  }

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
      debugPrint("앨범 추가 로딩 에러: $e");
    } finally {
      setState(() => _isLoadingMore = false);
    }
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
      debugPrint("순서 변경 에러: $e");
    }
  }

  void _showAlbumOptions(dynamic album) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.swap_vert, color: Color(0xFF8B7E74)),
              title: const Text("순서 변경"),
              onTap: () {
                Navigator.pop(context);
                widget.onEnterReorder();
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit, color: Color(0xFF8B7E74)),
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

  void _showRenameDialog(dynamic album) {
    final controller = TextEditingController(text: album['title']);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("앨범 이름 수정"),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: "새 앨범 이름"),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text("취소")),
          ElevatedButton(
            onPressed: () async {
              if (controller.text.isNotEmpty) {
                final response = await ApiClient.put(
                  Uri.parse('${ApiConfig.baseUrl}/api/archives/${album['id']}?title=${Uri.encodeComponent(controller.text)}'),
                );
                if (response.statusCode == 200) _fetchAlbums();
                if (mounted) Navigator.pop(context);
              }
            },
            child: const Text("수정"),
          ),
        ],
      ),
    );
  }

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
              final response = await ApiClient.delete(
                Uri.parse('${ApiConfig.baseUrl}/api/archives/$albumId'),
              );
              if (response.statusCode == 200) _fetchAlbums();
              if (mounted) Navigator.pop(context);
            },
            child: const Text("삭제", style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    if (_albums.isEmpty) return const Center(child: Text("우리의 첫 번째 앨범을 만들어보세요!"));

    return Column(
      children: [
        Expanded(
          child: widget.isReorderMode
              ? _buildReorderableList()
              : GridView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 100), // FAB 여백
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                    childAspectRatio: 0.85,
                  ),
                  itemCount: _albums.length,
                  itemBuilder: (context, index) => _buildAlbumCard(_albums[index]),
                ),
        ),
        if (_isLoadingMore && !widget.isReorderMode)
          const Padding(
            padding: EdgeInsets.all(16),
            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF8B7E74)),
          ),
      ],
    );
  }

  Widget _buildAlbumCard(dynamic album) {
    return GestureDetector(
      onTap: () async {
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AlbumDetailPage(albumId: album['id'], memberId: widget.memberId),
          ),
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
                boxShadow: const [
                  BoxShadow(color: Colors.black12, blurRadius: 4, offset: Offset(2, 2)),
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
                        placeholder: (context, url) => Container(
                          color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        ),
                        errorWidget: (context, url, error) =>
                            const Center(child: Icon(Icons.error, color: Colors.grey)),
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

  Widget _buildReorderableList() {
    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 100),
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
}
