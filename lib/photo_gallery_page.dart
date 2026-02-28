import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'api_config.dart';
import 'api_client.dart';

class PhotoGalleryPage extends StatefulWidget {
  final int memberId;

  const PhotoGalleryPage({super.key, required this.memberId});

  @override
  State<PhotoGalleryPage> createState() => PhotoGalleryPageState();
}

// State를 public으로 선언 → album_page.dart에서 GlobalKey로 접근 가능
class PhotoGalleryPageState extends State<PhotoGalleryPage> {
  final ImagePicker _picker = ImagePicker();
  List<dynamic> _photos = [];
  bool _isLoading = true;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  bool _isUploading = false;
  int _currentPage = 0;
  static const int _pageSize = 30;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _fetchPhotos();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 300
        && _hasMore && !_isLoadingMore) {
      _loadMore();
    }
  }

  Future<void> _fetchPhotos() async {
    _currentPage = 0;
    try {
      final response = await ApiClient.get(
        Uri.parse('${ApiConfig.baseUrl}/api/archives/media?page=0&size=$_pageSize'),
      );
      if (response.statusCode == 200) {
        final photos = jsonDecode(utf8.decode(response.bodyBytes)) as List;
        setState(() {
          _photos = photos;
          _hasMore = photos.length >= _pageSize;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint("사진 로딩 에러: $e");
      setState(() => _isLoading = false);
    }
  }

  Future<void> _loadMore() async {
    setState(() => _isLoadingMore = true);
    _currentPage++;
    try {
      final response = await ApiClient.get(
        Uri.parse('${ApiConfig.baseUrl}/api/archives/media?page=$_currentPage&size=$_pageSize'),
      );
      if (response.statusCode == 200) {
        final more = jsonDecode(utf8.decode(response.bodyBytes)) as List;
        setState(() {
          _photos = [..._photos, ...more];
          _hasMore = more.length >= _pageSize;
        });
      }
    } catch (e) {
      debugPrint("사진 추가 로딩 에러: $e");
    } finally {
      setState(() => _isLoadingMore = false);
    }
  }

  // album_page.dart에서 GlobalKey로 호출
  Future<void> pickAndUploadImage() async {
    setState(() => _isUploading = true);

    final List<XFile> images = await _picker.pickMultiImage(imageQuality: 85, maxWidth: 2000);
    if (images.isEmpty) {
      setState(() => _isUploading = false);
      return;
    }

    int success = 0;
    int fail = 0;

    for (final image in images) {
      try {
        DateTime? takenAt;
        try {
          takenAt = await image.lastModified();
        } catch (_) {}

        var request = http.MultipartRequest(
          'POST',
          Uri.parse('${ApiConfig.baseUrl}/api/archives/upload'),
        );
        request.fields['type'] = 'IMAGE';
        if (takenAt != null) {
          final local = takenAt.toLocal();
          request.fields['takenAt'] =
              "${local.year.toString().padLeft(4, '0')}-"
              "${local.month.toString().padLeft(2, '0')}-"
              "${local.day.toString().padLeft(2, '0')}T"
              "${local.hour.toString().padLeft(2, '0')}:"
              "${local.minute.toString().padLeft(2, '0')}:"
              "${local.second.toString().padLeft(2, '0')}";
        }
        final bytes = await image.readAsBytes();
        request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: image.name));

        final response = await ApiClient.sendMultipart(request);
        if (response.statusCode == 200) {
          success++;
        } else {
          fail++;
        }
      } catch (e) {
        fail++;
        debugPrint("업로드 에러: $e");
      }
    }

    setState(() => _isUploading = false);
    _fetchPhotos();

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(fail == 0 ? "$success장 업로드 성공!" : "성공 $success장 / 실패 $fail장")),
      );
    }
  }

  Future<void> _deleteMedia(int mediaId) async {
    try {
      final response = await ApiClient.delete(
        Uri.parse('${ApiConfig.baseUrl}/api/archives/media/$mediaId'),
      );
      if (response.statusCode == 200) {
        _fetchPhotos();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("사진 삭제 완료")));
        }
      }
    } catch (e) {
      debugPrint("사진 삭제 에러: $e");
    }
  }

  void _openPhotoViewer(int initialIndex) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _PhotoViewerPage(
          photos: _photos,
          initialIndex: initialIndex,
          onDelete: (photo) {
            _deleteMedia(photo['id']);
            Navigator.pop(context);
          },
        ),
      ),
    );
  }

  void _showPhotoOptions(dynamic photo) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text("삭제", style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(context);
                showDialog(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text("사진 삭제"),
                    content: const Text("이 사진을 삭제할까요?"),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(context), child: const Text("취소")),
                      ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                        onPressed: () {
                          Navigator.pop(context);
                          _deleteMedia(photo['id']);
                        },
                        child: const Text("삭제", style: TextStyle(color: Colors.white)),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isUploading) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Color(0xFF8B7E74)),
            SizedBox(height: 16),
            Text("업로드 중...", style: TextStyle(color: Color(0xFF8B7E74))),
          ],
        ),
      );
    }

    if (_isLoading) return const Center(child: CircularProgressIndicator());

    if (_photos.isEmpty) return const Center(child: Text("사진을 추가해보세요!"));

    // Scaffold 없이 콘텐츠만 반환 — FAB은 AlbumPage가 관리
    return Column(
      children: [
        Expanded(
          child: GridView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.fromLTRB(2, 2, 2, 100), // FAB 여백
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              crossAxisSpacing: 2,
              mainAxisSpacing: 2,
            ),
            itemCount: _photos.length,
            itemBuilder: (context, index) {
              final photo = _photos[index];
              final thumbUrl = photo['thumbnailUrl'] as String? ?? photo['mediaUrl'] as String;
              return GestureDetector(
                onTap: () => _openPhotoViewer(index),
                onLongPress: () => _showPhotoOptions(photo),
                child: CachedNetworkImage(
                  imageUrl: thumbUrl,
                  fit: BoxFit.cover,
                  memCacheWidth: 300,
                  maxWidthDiskCache: 300,
                  placeholder: (context, url) => Container(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  ),
                  errorWidget: (context, url, error) => Container(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    child: const Icon(Icons.broken_image, color: Colors.grey),
                  ),
                ),
              );
            },
          ),
        ),
        if (_isLoadingMore)
          const Padding(
            padding: EdgeInsets.all(16),
            child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF8B7E74)),
          ),
      ],
    );
  }
}

// ── 전체화면 사진 뷰어 ──
class _PhotoViewerPage extends StatefulWidget {
  final List<dynamic> photos;
  final int initialIndex;
  final Function(dynamic photo) onDelete;

  const _PhotoViewerPage({
    required this.photos,
    required this.initialIndex,
    required this.onDelete,
  });

  @override
  State<_PhotoViewerPage> createState() => _PhotoViewerPageState();
}

class _PhotoViewerPageState extends State<_PhotoViewerPage> {
  late PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(
          "${_currentIndex + 1} / ${widget.photos.length}",
          style: const TextStyle(color: Colors.white),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.white),
            onPressed: () {
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text("사진 삭제"),
                  content: const Text("이 사진을 삭제할까요?"),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context), child: const Text("취소")),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
                      onPressed: () {
                        Navigator.pop(context);
                        widget.onDelete(widget.photos[_currentIndex]);
                      },
                      child: const Text("삭제", style: TextStyle(color: Colors.white)),
                    ),
                  ],
                ),
              );
            },
          ),
        ],
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.photos.length,
        onPageChanged: (index) => setState(() => _currentIndex = index),
        itemBuilder: (context, index) {
          return InteractiveViewer(
            minScale: 1.0,
            maxScale: 4.0,
            child: Center(
              child: CachedNetworkImage(
                imageUrl: widget.photos[index]['mediaUrl'],
                fit: BoxFit.contain,
                placeholder: (context, url) =>
                    const CircularProgressIndicator(color: Colors.white),
                errorWidget: (context, url, error) =>
                    const Icon(Icons.broken_image, color: Colors.white54, size: 64),
              ),
            ),
          );
        },
      ),
    );
  }
}
