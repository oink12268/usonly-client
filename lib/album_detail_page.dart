import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import 'dart:convert';
import 'api_config.dart';
import 'api_client.dart';

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
    final response = await ApiClient.get(
      Uri.parse('${ApiConfig.baseUrl}/api/archives/${widget.albumId}'),
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
    // 갤러리 확인 직후 압축 시간 동안 스피너가 안 보이는 문제 방지:
    // pickMultiImage 호출 전에 미리 로딩 상태로 전환
    // (갤러리가 열려있는 동안은 어차피 갤러리가 화면을 덮으므로 문제없음)
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

        request.fields['albumId'] = widget.albumId.toString();
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

        var response = await ApiClient.sendMultipart(request);

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
      final response = await ApiClient.delete(
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

  // 사진 롱프레스 → 옵션 바텀시트
  void _showPhotoOptions(dynamic photo) {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (photo['mediaType'] == 'IMAGE')
              ListTile(
                leading: const Icon(Icons.image_outlined),
                title: const Text("커버로 설정"),
                onTap: () {
                  Navigator.pop(context);
                  _setCoverImage(photo['id']);
                },
              ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.red),
              title: const Text("삭제", style: TextStyle(color: Colors.red)),
              onTap: () {
                Navigator.pop(context);
                _showDeleteDialog(photo);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _setCoverImage(int mediaId) async {
    try {
      final response = await ApiClient.put(
        Uri.parse('${ApiConfig.baseUrl}/api/archives/${widget.albumId}/cover?mediaId=$mediaId'),
      );
      if (response.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("커버 이미지가 변경되었습니다")),
        );
      }
    } catch (e) {
      print("커버 변경 에러: $e");
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
                // 그리드: 썸네일 사용 (없으면 원본으로 폴백)
                final thumbUrl = _photos[index]['thumbnailUrl'] as String?
                    ?? _photos[index]['mediaUrl'] as String;
                return GestureDetector(
                  onTap: () => _openPhotoViewer(index),
                  onLongPress: () => _showPhotoOptions(_photos[index]),
                  child: CachedNetworkImage(
                    imageUrl: thumbUrl,
                    fit: BoxFit.cover,
                    memCacheWidth: 300,
                    maxWidthDiskCache: 300,
                    placeholder: (context, url) => Container(color: Theme.of(context).colorScheme.surfaceContainerHighest),
                    errorWidget: (context, url, error) => Container(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
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
  bool _isZoomed = false;
  int _pointerCount = 0;
  TapDownDetails? _doubleTapDetails;
  final Map<int, TransformationController> _transformControllers = {};

  TransformationController _controllerFor(int index) {
    return _transformControllers.putIfAbsent(index, () {
      final controller = TransformationController();
      controller.addListener(() {
        if (index == _currentIndex) {
          final scale = controller.value.getMaxScaleOnAxis();
          final zoomed = scale > 1.05;
          if (zoomed != _isZoomed) setState(() => _isZoomed = zoomed);
        }
      });
      return controller;
    });
  }

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: widget.initialIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    for (final c in _transformControllers.values) c.dispose();
    super.dispose();
  }

  void _onPageChanged(int index) {
    _transformControllers[_currentIndex]?.value = Matrix4.identity();
    setState(() {
      _currentIndex = index;
      _isZoomed = false;
    });
  }

  void _onDoubleTap(TransformationController controller) {
    final scale = controller.value.getMaxScaleOnAxis();
    if (scale > 1.05) {
      controller.value = Matrix4.identity();
      return;
    }
    if (_doubleTapDetails == null) return;
    final x = _doubleTapDetails!.localPosition.dx;
    final y = _doubleTapDetails!.localPosition.dy;
    const double s = 2.5;
    controller.value = Matrix4.identity()
      ..translate(x, y)
      ..scale(s)
      ..translate(-x, -y);
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
      body: Listener(
        onPointerDown: (_) {
          _pointerCount++;
          if (_pointerCount >= 2 && !_isZoomed) setState(() => _isZoomed = true);
        },
        onPointerUp: (_) {
          _pointerCount = (_pointerCount - 1).clamp(0, 100);
          if (_pointerCount < 2) {
            final scale = _controllerFor(_currentIndex).value.getMaxScaleOnAxis();
            setState(() => _isZoomed = scale > 1.05);
          }
        },
        child: PageView.builder(
          physics: _isZoomed
              ? const NeverScrollableScrollPhysics()
              : const PageScrollPhysics(),
          controller: _pageController,
          itemCount: widget.photos.length,
          onPageChanged: _onPageChanged,
          itemBuilder: (context, index) {
            final controller = _controllerFor(index);
            return GestureDetector(
              onDoubleTapDown: (d) => _doubleTapDetails = d,
              onDoubleTap: () => _onDoubleTap(controller),
              child: InteractiveViewer(
                transformationController: controller,
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
              ),
            );
          },
        ),
      ),
    );
  }
}
