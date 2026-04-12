import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:exif/exif.dart';
import 'package:http/http.dart' as http;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:video_player/video_player.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'api_client.dart';
import 'api_endpoints.dart';
import 'widgets/confirm_delete_dialog.dart';
import 'widgets/film_filters.dart';
import 'photo_gallery_page.dart';

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
      Uri.parse(ApiEndpoints.archiveAlbumById(widget.albumId)),
    );
    if (response.statusCode == 200) {
      final data = ApiClient.decodeBody(response) as Map<String, dynamic>;
      setState(() {
        _albumTitle = data['title'] ?? "추억 보기";
        _photos = data['mediaList'];
      });
    }
  }

  // TODO: 날짜 일괄 수정 기능 (임시, 사용 후 제거)
  Future<void> _showBulkTakenAtDialog() async {
    DateTime? picked = await showDatePicker(
      context: context,
      initialDate: DateTime.now(),
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked == null || !mounted) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('날짜 일괄 수정'),
        content: Text('앨범 내 사진 ${_photos.length}장의 촬영일을\n${picked.year}.${picked.month.toString().padLeft(2,'0')}.${picked.day.toString().padLeft(2,'0')}로 변경할까요?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('취소')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('변경')),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    final takenAtStr =
        "${picked.year.toString().padLeft(4,'0')}-"
        "${picked.month.toString().padLeft(2,'0')}-"
        "${picked.day.toString().padLeft(2,'0')}T00:00:00";
    final response = await ApiClient.put(
      Uri.parse('${ApiEndpoints.archiveAlbumMediaTakenAt(widget.albumId)}?takenAt=$takenAtStr'),
    );
    if (!mounted) return;
    if (response.statusCode == 200) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('날짜 변경 완료!')));
      _fetchPhotos();
    } else {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('변경 실패')));
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

    // 토큰을 루프 전에 한 번만 가져와서 재사용 (Windows에서 매번 갱신 시 401 오류 방지)
    final uploadToken = await FirebaseAuth.instance.currentUser?.getIdToken(true);

    for (final file in mediaFiles) {
      try {
        final isVideo = _isVideoFile(file.name);
        final type = isVideo ? 'VIDEO' : 'IMAGE';
        Uint8List bytes = await file.readAsBytes();

        // Windows는 imageQuality/maxWidth가 무시되므로 직접 압축 (순수 Dart)
        if (!isVideo && defaultTargetPlatform == TargetPlatform.windows) {
          try {
            final decoded = img.decodeImage(bytes);
            if (decoded != null && (decoded.width > 2000 || decoded.height > 2000)) {
              final resized = img.copyResize(decoded,
                width: decoded.width > decoded.height ? 2000 : -1,
                height: decoded.height >= decoded.width ? 2000 : -1,
              );
              bytes = Uint8List.fromList(img.encodeJpg(resized, quality: 85));
            }
          } catch (_) {}
        }

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
          Uri.parse(ApiEndpoints.archiveUpload),
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

        final streamed = await ApiClient.sendMultipart(request, token: uploadToken);
        final response = await http.Response.fromStream(streamed);

        if (response.statusCode == 200) {
          success++;
        } else {
          fail++;
          debugPrint("업로드 실패: ${response.statusCode} / ${response.body}");
        }
      } catch (e) {
        fail++;
        debugPrint("업로드 에러: $e");
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
        Uri.parse(ApiEndpoints.archiveMediaDelete(mediaId)),
      );
      if (response.statusCode == 200) {
        _fetchPhotos();
        // [FIX #4] mounted 체크 추가
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("사진 삭제 완료")));
        }
      }
    } catch (e) {
      debugPrint("사진 삭제 에러: $e");
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
        Uri.parse('${ApiEndpoints.archiveAlbumCover(widget.albumId)}?mediaId=$mediaId'),
      );
      if (response.statusCode == 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("커버 이미지가 변경되었습니다")),
        );
      }
    } catch (e) {
      debugPrint("커버 변경 에러: $e");
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
      appBar: AppBar(
        title: Text(_albumTitle),
        actions: [
          if (_photos.isNotEmpty)
            // TODO: 날짜 일괄 수정 기능 (임시, 사용 후 제거)
            IconButton(
              icon: const Icon(Icons.edit_calendar),
              tooltip: '앨범 날짜 일괄 수정',
              onPressed: () => _showBulkTakenAtDialog(),
            ),
          if (_photos.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.slideshow),
              tooltip: '슬라이드쇼',
              onPressed: () {
                final imageOnly = _photos
                    .where((p) => p['mediaType'] != 'VIDEO')
                    .toList();
                if (imageOnly.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('사진이 없어 슬라이드쇼를 시작할 수 없어요')),
                  );
                  return;
                }
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => SlideshowPage(photos: imageOnly),
                  ),
                );
              },
            ),
        ],
      ),
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
                        cacheKey: '${thumbUrl}_thumb',
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
  bool _isDownloading = false;
  bool _isPeeking = false; // 롱프레스 중 원본 보기

  bool get _isCurrentVideo => widget.photos[_currentIndex]['mediaType'] == 'VIDEO';

  // ── 영상 프리로드 ──
  final Map<int, VideoPlayerController> _videoControllers = {};

  void _preloadVideo(int index) {
    if (index < 0 || index >= widget.photos.length) return;
    if (widget.photos[index]['mediaType'] != 'VIDEO') return;
    if (_videoControllers.containsKey(index)) return;

    final url = widget.photos[index]['mediaUrl'] as String;
    final controller = VideoPlayerController.networkUrl(Uri.parse(url));
    _videoControllers[index] = controller;
    controller.initialize().then((_) {
      if (mounted) setState(() {});
    });
  }

  void _cleanupVideoControllers(int currentIndex) {
    // currentIndex-1 ~ currentIndex+2 범위 밖 controller 해제
    final keysToRemove = _videoControllers.keys
        .where((k) => k < currentIndex - 1 || k > currentIndex + 2)
        .toList();
    for (final k in keysToRemove) {
      _videoControllers[k]?.dispose();
      _videoControllers.remove(k);
    }
  }

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
    // 현재 + 다음 영상 미리 로드
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _preloadVideo(_currentIndex);
      _preloadVideo(_currentIndex + 1);
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    for (final c in _transformControllers.values) c.dispose();
    for (final c in _videoControllers.values) c.dispose();
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
    _preloadVideo(index + 1);
    _preloadVideo(index + 2);
    _cleanupVideoControllers(index);
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
        Uri.parse(ApiEndpoints.archiveUpload),
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
        Uri.parse(ApiEndpoints.archiveMediaDelete(photo['id'])),
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

  Future<void> _downloadMedia() async {
    final photo = widget.photos[_currentIndex];
    final url = photo['mediaUrl'] as String;
    final isVideo = photo['mediaType'] == 'VIDEO';
    final filename = url.split('/').last.split('?').first;

    setState(() => _isDownloading = true);
    try {
      if (defaultTargetPlatform == TargetPlatform.windows) {
        final downloadsPath = '${Platform.environment['USERPROFILE']}\\Downloads\\$filename';
        final response = await http.get(Uri.parse(url));
        await File(downloadsPath).writeAsBytes(response.bodyBytes);
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('다운로드 완료 (Downloads 폴더)')),
        );
      } else {
        if (!await Gal.hasAccess(toAlbum: true)) await Gal.requestAccess(toAlbum: true);
        final response = await http.get(Uri.parse(url));
        if (isVideo) {
          final tempDir = await getTemporaryDirectory();
          final tempFile = File('${tempDir.path}/$filename');
          await tempFile.writeAsBytes(response.bodyBytes);
          await Gal.putVideo(tempFile.path, album: 'UsOnly');
          await tempFile.delete();
        } else {
          await Gal.putImageBytes(response.bodyBytes, album: 'UsOnly');
        }
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('갤러리에 저장되었습니다')),
        );
      }
    } catch (e) {
      debugPrint('다운로드 오류: $e');
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('저장 실패: $e')),
      );
    } finally {
      if (mounted) setState(() => _isDownloading = false);
    }
  }

  void _showPhotoInfo() {
    final photo = widget.photos[_currentIndex];
    final mediaType = photo['mediaType'] as String? ?? 'IMAGE';

    String _buildDateStr(String? takenAt) {
      if (takenAt == null) return '-';
      try {
        final dt = DateTime.parse(takenAt).toLocal();
        return '${dt.year}년 ${dt.month}월 ${dt.day}일 '
            '${dt.hour.toString().padLeft(2, '0')}:'
            '${dt.minute.toString().padLeft(2, '0')}';
      } catch (_) {
        return '-';
      }
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.black87,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          final takenAt = photo['takenAt'] as String?;
          final dateStr = _buildDateStr(takenAt);
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('사진 정보', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(child: _infoRow(Icons.calendar_today_outlined, '촬영일시', dateStr)),
                      TextButton(
                        onPressed: () => _editTakenAt(photo, setSheetState),
                        child: const Text('수정', style: TextStyle(color: Colors.white54, fontSize: 13)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _infoRow(
                    mediaType == 'VIDEO' ? Icons.videocam_outlined : Icons.image_outlined,
                    '파일 유형',
                    mediaType == 'VIDEO' ? '동영상' : '사진',
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _editTakenAt(Map<String, dynamic> photo, StateSetter setSheetState) async {
    final mediaId = photo['id'] as int?;
    if (mediaId == null) return;

    final currentTakenAt = photo['takenAt'] as String?;
    DateTime initial;
    try {
      initial = currentTakenAt != null ? DateTime.parse(currentTakenAt).toLocal() : DateTime.now();
    } catch (_) {
      initial = DateTime.now();
    }

    final pickedDate = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
      builder: (ctx, child) => Theme(
        data: ThemeData.dark(),
        child: child!,
      ),
    );
    if (pickedDate == null || !mounted) return;

    final pickedTime = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
      builder: (ctx, child) => Theme(
        data: ThemeData.dark(),
        child: child!,
      ),
    );
    if (pickedTime == null || !mounted) return;

    final newDt = DateTime(pickedDate.year, pickedDate.month, pickedDate.day, pickedTime.hour, pickedTime.minute);
    final newDtStr = newDt.toIso8601String().substring(0, 19);

    try {
      final response = await ApiClient.put(
        Uri.parse('${ApiEndpoints.archiveMediaTakenAt(mediaId)}?takenAt=${Uri.encodeComponent(newDtStr)}'),
      );
      if (response.statusCode == 200) {
        photo['takenAt'] = newDt.toIso8601String();
        setSheetState(() {});
        setState(() {});
      }
    } catch (e) {
      debugPrint('촬영일시 수정 오류: $e');
    }
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, color: Colors.white54, size: 20),
        const SizedBox(width: 12),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12)),
            Text(value, style: const TextStyle(color: Colors.white, fontSize: 14)),
          ],
        ),
      ],
    );
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
          _isDownloading
              ? const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2)),
                )
              : IconButton(
                  icon: const Icon(Icons.download_outlined, color: Colors.white),
                  onPressed: _downloadMedia,
                ),
          IconButton(
            icon: const Icon(Icons.info_outline, color: Colors.white),
            onPressed: _showPhotoInfo,
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
                      child: _VideoPlayerWidget(
                        url: photo['mediaUrl'] as String,
                        preloadedController: _videoControllers[index],
                      ),
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
  final VideoPlayerController? preloadedController;
  const _VideoPlayerWidget({required this.url, this.preloadedController});

  @override
  State<_VideoPlayerWidget> createState() => _VideoPlayerWidgetState();
}

class _VideoPlayerWidgetState extends State<_VideoPlayerWidget> {
  VideoPlayerController? _ownController;
  bool _initialized = false;

  VideoPlayerController get _controller =>
      widget.preloadedController ?? _ownController!;

  void _onControllerUpdate() {
    if (_controller.value.isInitialized && !_initialized) {
      if (mounted) setState(() => _initialized = true);
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.preloadedController != null) {
      // 이미 초기화된 경우 바로 사용, 아니면 리스너로 대기
      _initialized = widget.preloadedController!.value.isInitialized;
      if (!_initialized) {
        widget.preloadedController!.addListener(_onControllerUpdate);
      }
    } else {
      _ownController = VideoPlayerController.networkUrl(Uri.parse(widget.url))
        ..initialize().then((_) {
          if (mounted) setState(() => _initialized = true);
        });
    }
  }

  @override
  void dispose() {
    widget.preloadedController?.removeListener(_onControllerUpdate);
    _ownController?.dispose(); // 직접 만든 controller만 dispose
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



