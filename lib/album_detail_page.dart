import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:convert';
import 'api_config.dart';

class AlbumDetailPage extends StatefulWidget {
  final int albumId;
  final int memberId;

  const AlbumDetailPage({super.key, required this.albumId, required this.memberId});

  @override
  State<AlbumDetailPage> createState() => _AlbumDetailPageState();
}

class _AlbumDetailPageState extends State<AlbumDetailPage> {
  final ImagePicker _picker = ImagePicker();
  List<dynamic> _photos = [];
  String _albumTitle = "";
  bool _isUploading = false;

  @override
  void initState() {
    super.initState();
    _fetchPhotos();
  }

  Future<void> _fetchPhotos() async {
    final response = await http.get(
      Uri.parse('${ApiConfig.baseUrl}/api/archives/${widget.albumId}?userId=${widget.memberId}'),
    );
    if (response.statusCode == 200) {
      final data = jsonDecode(utf8.decode(response.bodyBytes));
      setState(() {
        _albumTitle = data['title'] ?? "추억 보기";
        _photos = data['mediaList'];
      });
    }
  }

  Future<void> _pickAndUploadImage() async {
    final List<XFile> images = await _picker.pickMultiImage(imageQuality: 85, maxWidth: 2000);
    if (images.isEmpty) return;

    setState(() => _isUploading = true);

    int success = 0;
    int fail = 0;

    for (final image in images) {
      try {
        var request = http.MultipartRequest(
          'POST',
          Uri.parse('${ApiConfig.baseUrl}/api/archives/upload'),
        );

        request.fields['albumId'] = widget.albumId.toString();
        request.fields['userId'] = widget.memberId.toString();
        request.fields['type'] = 'IMAGE';
        request.files.add(await http.MultipartFile.fromPath('file', image.path));

        var response = await request.send();

        if (response.statusCode == 200) {
          success++;
        } else {
          fail++;
          var responseBody = await response.stream.bytesToString();
          print("업로드 실패: ${response.statusCode} / $responseBody");
        }
      } catch (e) {
        fail++;
        print("업로드 에러: $e");
      }
    }

    setState(() => _isUploading = false);
    _fetchPhotos();
    if (fail == 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("$success장 업로드 성공!")));
    } else {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("성공 $success장 / 실패 $fail장")));
    }
  }

  Future<void> _deleteMedia(int mediaId) async {
    try {
      final response = await http.delete(
        Uri.parse('${ApiConfig.baseUrl}/api/archives/media/$mediaId'),
      );
      if (response.statusCode == 200) {
        _fetchPhotos();
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("사진 삭제 완료")));
      }
    } catch (e) {
      print("사진 삭제 에러: $e");
    }
  }

  // 사진 롱프레스 → 삭제 확인
  void _showDeleteDialog(dynamic photo) {
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
  }

  // 사진 탭 → 전체화면 뷰어
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_albumTitle)),
      body: _isUploading
          ? const Center(child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(color: Color(0xFF8B7E74)),
                SizedBox(height: 16),
                Text("업로드 중...", style: TextStyle(color: Color(0xFF8B7E74))),
              ],
            ))
          : _photos.isEmpty
          ? const Center(child: Text("사진을 추가해보세요!"))
          : GridView.builder(
              padding: const EdgeInsets.all(4),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 3,
                crossAxisSpacing: 2,
                mainAxisSpacing: 2,
              ),
              itemCount: _photos.length,
              itemBuilder: (context, index) {
                return GestureDetector(
                  onTap: () => _openPhotoViewer(index),
                  onLongPress: () => _showDeleteDialog(_photos[index]),
                  child: CachedNetworkImage(
                    imageUrl: _photos[index]['mediaUrl'],
                    fit: BoxFit.cover,
                    memCacheWidth: 300,
                    maxWidthDiskCache: 300,
                    placeholder: (context, url) => Container(
                      color: Colors.grey[200],
                      child: const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                    errorWidget: (context, url, error) => Container(
                      color: Colors.grey[200],
                      child: const Icon(Icons.broken_image, color: Colors.grey),
                    ),
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _pickAndUploadImage,
        backgroundColor: const Color(0xFF8B7E74),
        child: const Icon(Icons.add_a_photo, color: Colors.white),
      ),
    );
  }
}

// 전체화면 사진 뷰어 (좌우 스와이프)
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
