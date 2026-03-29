import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:exif/exif.dart';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:video_player/video_player.dart';
import 'dart:convert';
import 'dart:ui' as ui;
import 'api_config.dart';
import 'api_client.dart';
import 'widgets/confirm_delete_dialog.dart';
import 'widgets/film_filters.dart';

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

  bool _isVideoFile(String filename) {
    final ext = filename.toLowerCase().split('.').last;
    return ['mp4', 'mov', 'avi', 'mkv'].contains(ext);
  }

  Future<void> _pickAndUploadImage() async {
    setState(() => _isUploading = true);

    final List<XFile> mediaFiles = await _picker.pickMultipleMedia(imageQuality: 85, maxWidth: 2000);
    if (mediaFiles.isEmpty) {
      setState(() => _isUploading = false);
      return;
    }

    int success = 0;
    int fail = 0;

    for (final file in mediaFiles) {
      try {
        final isVideo = _isVideoFile(file.name);
        final type = isVideo ? 'VIDEO' : 'IMAGE';
        final bytes = await file.readAsBytes();

        DateTime? takenAt;
        if (!isVideo) {
          try {
            final exifData = await readExifFromBytes(bytes);
            final dateStr = exifData['EXIF DateTimeOriginal']?.printable
                         ?? exifData['Image DateTime']?.printable;
            if (dateStr != null && dateStr.length >= 19) {
              final datePart = dateStr.substring(0, 10).replaceAll(':', '-');
              final timePart = dateStr.substring(11, 19);
              takenAt = DateTime.parse('${datePart}T$timePart');
            }
          } catch (_) {}
        }
        takenAt ??= await file.lastModified();

        var request = http.MultipartRequest(
          'POST',
          Uri.parse('${ApiConfig.baseUrl}/api/archives/upload'),
        );

        request.fields['albumId'] = widget.albumId.toString();
        request.fields['type'] = type;
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
        request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: file.name));

        final streamed = await ApiClient.sendMultipart(request);
        final response = await http.Response.fromStream(streamed);

        if (response.statusCode == 200) {
          success++;
        } else {
          fail++;
          print("업로드 실패: ${response.statusCode} / ${response.body}");
        }
      } catch (e) {
        fail++;
        print("업로드 에러: $e");
      }
    }

    setState(() => _isUploading = false);
    _fetchPhotos();
    // [FIX #4] mounted 체크 추가 - 업로드 중 화면 이탈 시 크래시 방지
    if (mounted) {
      if (fail == 0) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("${success}장 업로드 성공!")));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("성공 ${success}장 / 실패 ${fail}장")));
      }
    }
  }

  Future<void> _deleteMedia(int mediaId) async {
    try {
      final response = await ApiClient.delete(
        Uri.parse('${ApiConfig.baseUrl}/api/archives/media/$mediaId'),
      );
      if (response.statusCode == 200) {
        _fetchPhotos();
        // [FIX #4] mounted 체크 추가
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("사진 삭제 완료")));
        }
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
  Future<void> _showDeleteDialog(dynamic photo) async {
    final confirmed = await ConfirmDeleteDialog.show(
      context,
      title: '사진 삭제',
      content: '이 사진을 삭제할까요?',
    );
    if (confirmed) _deleteMedia(photo['id']);
  }

  // 사진 탭 → 전체화면 뷰어
  void _openPhotoViewer(int initialIndex) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _PhotoViewerPage(
          photos: _photos,
          initialIndex: initialIndex,
          albumId: widget.albumId,
          onDelete: (photo) {
            _deleteMedia(photo['id']);
            Navigator.pop(context);
          },
          onSaved: _fetchPhotos,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_albumTitle)),
      body: _isUploading
          ? Center(child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 16),
                Text("업로드 중...", style: TextStyle(color: Theme.of(context).colorScheme.onSurface)),
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
                final photo = _photos[index];
                final thumbUrl = photo['thumbnailUrl'] as String?
                    ?? photo['mediaUrl'] as String;
                final isVideo = photo['mediaType'] == 'VIDEO';
                return GestureDetector(
                  onTap: () => _openPhotoViewer(index),
                  onLongPress: () => _showPhotoOptions(photo),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      CachedNetworkImage(
                        imageUrl: thumbUrl,
                        fit: BoxFit.cover,
                        memCacheWidth: 300,
                        maxWidthDiskCache: 300,
                        placeholder: (context, url) => Container(color: Theme.of(context).colorScheme.surfaceContainerHighest),
                        errorWidget: (context, url, error) => Container(
                          color: Theme.of(context).colorScheme.surfaceContainerHighest,
                          child: Icon(
                            isVideo ? Icons.videocam : Icons.broken_image,
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      if (isVideo)
                        const Center(
                          child: Icon(Icons.play_circle_outline, color: Colors.white, size: 36,
                            shadows: [Shadow(color: Colors.black54, blurRadius: 8)],
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _pickAndUploadImage,
        backgroundColor: Theme.of(context).colorScheme.primary,
        child: Icon(Icons.add_a_photo, color: Theme.of(context).colorScheme.onPrimary),
      ),
    );
  }
}

// 전체화면 사진 뷰어 (좌우 스와이프 + 필름 필터)
class _PhotoViewerPage extends StatefulWidget {
  final List<dynamic> photos;
  final int initialIndex;
  final Function(dynamic photo) onDelete;
  final int? albumId;
  final VoidCallback? onSaved;

  const _PhotoViewerPage({
    required this.photos,
    required this.initialIndex,
    required this.onDelete,
    this.albumId,
    this.onSaved,
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
  int _selectedFilterIndex = 0;
  bool _isSaving = false;
  bool _isPeeking = false; // 롱프레스 중 원본 보기

  bool get _isCurrentVideo => widget.photos[_currentIndex]['mediaType'] == 'VIDEO';

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
      _selectedFilterIndex = 0;
      _isPeeking = false;
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

  Future<void> _saveWithFilter() async {
    final photo = widget.photos[_currentIndex];
    final filter = filmFilters[_selectedFilterIndex];
    if (filter.matrix == null) return;

    setState(() => _isSaving = true);
    try {
      // 1. 원본 이미지 다운로드
      final imgResponse = await http.get(Uri.parse(photo['mediaUrl'] as String));
      final originalBytes = imgResponse.bodyBytes;

      // 2. 이미지 디코딩 후 필터 적용 (dart:ui 캔버스 사용)
      final codec = await ui.instantiateImageCodec(originalBytes);
      final frame = await codec.getNextFrame();
      final srcImage = frame.image;
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawImage(
        srcImage,
        Offset.zero,
        Paint()..colorFilter = ColorFilter.matrix(filter.matrix!),
      );
      final picture = recorder.endRecording();
      final filteredImage = await picture.toImage(srcImage.width, srcImage.height);
      final byteData = await filteredImage.toByteData(format: ui.ImageByteFormat.png);
      final filteredBytes = byteData!.buffer.asUint8List();

      // 3. 필터 적용된 이미지를 서버에 업로드
      final uploadRequest = http.MultipartRequest(
        'POST',
        Uri.parse('${ApiConfig.baseUrl}/api/archives/upload'),
      );
      final albumId = widget.albumId ?? (photo['albumId'] as int?);
      if (albumId != null) uploadRequest.fields['albumId'] = albumId.toString();
      uploadRequest.fields['type'] = 'IMAGE';
      final takenAt = photo['takenAt'] as String?;
      if (takenAt != null) {
        uploadRequest.fields['takenAt'] =
            takenAt.length > 19 ? takenAt.substring(0, 19) : takenAt;
      }
      uploadRequest.files.add(
        http.MultipartFile.fromBytes(
          'file',
          filteredBytes,
          filename: 'filtered_${photo['id']}.png',
        ),
      );
      final uploadResponse = await ApiClient.sendMultipart(uploadRequest);
      if (uploadResponse.statusCode != 200) throw Exception('업로드 실패');

      // 4. 원본 삭제
      await ApiClient.delete(
        Uri.parse('${ApiConfig.baseUrl}/api/archives/media/${photo['id']}'),
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('필터 저장 완료!')),
        );
        widget.onSaved?.call();
        Navigator.pop(context);
      }
    } catch (e) {
      debugPrint('필터 저장 오류: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('저장 실패: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Widget _buildFilterBar() {
    final photo = widget.photos[_currentIndex];
    final thumbUrl = photo['thumbnailUrl'] as String? ?? photo['mediaUrl'] as String;
    return Container(
      height: 90,
      color: Colors.black,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        itemCount: filmFilters.length,
        itemBuilder: (context, index) {
          final filter = filmFilters[index];
          final isSelected = _selectedFilterIndex == index;
          return GestureDetector(
            onTap: () => setState(() => _selectedFilterIndex = index),
            child: Container(
              width: 62,
              margin: const EdgeInsets.symmetric(horizontal: 4),
              child: Column(
                children: [
                  Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      border: Border.all(
                        color: isSelected ? Colors.white : Colors.grey.shade800,
                        width: isSelected ? 2 : 1,
                      ),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: filter.matrix != null
                          ? ColorFiltered(
                              colorFilter: ColorFilter.matrix(filter.matrix!),
                              child: CachedNetworkImage(
                                imageUrl: thumbUrl,
                                fit: BoxFit.cover,
                              ),
                            )
                          : CachedNetworkImage(
                              imageUrl: thumbUrl,
                              fit: BoxFit.cover,
                            ),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    filter.name,
                    style: TextStyle(
                      color: isSelected ? Colors.white : Colors.grey,
                      fontSize: 10,
                    ),
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final filter = filmFilters[_selectedFilterIndex];
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
          if (!_isCurrentVideo && _selectedFilterIndex != 0)
            _isSaving
                ? const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    ),
                  )
                : TextButton(
                    onPressed: _saveWithFilter,
                    child: const Text(
                      '저장',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                  ),
          IconButton(
            icon: const Icon(Icons.delete_outline, color: Colors.white),
            onPressed: () async {
              final confirmed = await ConfirmDeleteDialog.show(
                context,
                title: '삭제',
                content: '이 항목을 삭제할까요?',
              );
              if (confirmed) widget.onDelete(widget.photos[_currentIndex]);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Listener(
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
                  final photo = widget.photos[index];
                  final isVideo = photo['mediaType'] == 'VIDEO';

                  if (isVideo) {
                    return Center(
                      child: _VideoPlayerWidget(url: photo['mediaUrl'] as String),
                    );
                  }

                  final controller = _controllerFor(index);
                  Widget imageWidget = CachedNetworkImage(
                    imageUrl: photo['mediaUrl'],
                    fit: BoxFit.contain,
                    placeholder: (context, url) =>
                        const CircularProgressIndicator(color: Colors.white),
                    errorWidget: (context, url, error) =>
                        const Icon(Icons.broken_image, color: Colors.white54, size: 64),
                  );
                  if (index == _currentIndex && filter.matrix != null && !_isPeeking) {
                    imageWidget = ColorFiltered(
                      colorFilter: ColorFilter.matrix(filter.matrix!),
                      child: imageWidget,
                    );
                  }
                  return GestureDetector(
                    onDoubleTapDown: (d) => _doubleTapDetails = d,
                    onDoubleTap: () => _onDoubleTap(controller),
                    onLongPress: () => setState(() => _isPeeking = true),
                    onLongPressUp: () => setState(() => _isPeeking = false),
                    child: InteractiveViewer(
                      transformationController: controller,
                      minScale: 1.0,
                      maxScale: 4.0,
                      child: Center(child: imageWidget),
                    ),
                  );
                },
              ),
            ),
          ),
          if (!_isCurrentVideo) _buildFilterBar(),
        ],
      ),
    );
  }
}

class _VideoPlayerWidget extends StatefulWidget {
  final String url;
  const _VideoPlayerWidget({required this.url});

  @override
  State<_VideoPlayerWidget> createState() => _VideoPlayerWidgetState();
}

class _VideoPlayerWidgetState extends State<_VideoPlayerWidget> {
  late VideoPlayerController _controller;
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url))
      ..initialize().then((_) {
        if (mounted) setState(() => _initialized = true);
      });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return const Center(child: CircularProgressIndicator(color: Colors.white));
    }
    return GestureDetector(
      onTap: () {
        setState(() {
          _controller.value.isPlaying ? _controller.pause() : _controller.play();
        });
      },
      child: Stack(
        alignment: Alignment.center,
        children: [
          AspectRatio(
            aspectRatio: _controller.value.aspectRatio,
            child: VideoPlayer(_controller),
          ),
          if (!_controller.value.isPlaying)
            const Icon(Icons.play_circle_outline, color: Colors.white70, size: 72,
              shadows: [Shadow(color: Colors.black54, blurRadius: 8)],
            ),
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: VideoProgressIndicator(
              _controller,
              allowScrubbing: true,
              colors: const VideoProgressColors(
                playedColor: Colors.white,
                bufferedColor: Colors.white38,
                backgroundColor: Colors.white12,
              ),
            ),
          ),
        ],
      ),
    );
  }
}



