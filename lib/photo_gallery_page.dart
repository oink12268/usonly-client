import 'dart:math';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:image_picker/image_picker.dart';
import 'package:exif/exif.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'api_client.dart';
import 'api_endpoints.dart';
import 'widgets/confirm_delete_dialog.dart';
import 'widgets/film_filters.dart';

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
        Uri.parse(ApiEndpoints.archiveMediaPaged(page: 0, size: _pageSize)),
      );
      if (response.statusCode == 200) {
        final photos = ApiClient.decodeBody(response) as List;
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
        Uri.parse(ApiEndpoints.archiveMediaPaged(page: _currentPage, size: _pageSize)),
      );
      if (response.statusCode == 200) {
        final more = ApiClient.decodeBody(response) as List;
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
  Future<void> startSlideshow() async {
    if (_photos.isEmpty) return;

    // 전체 사진 로딩 중 표시
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator(color: Colors.white)),
    );

    try {
      // 전체 사진 한 번에 가져오기
      final response = await ApiClient.get(
        Uri.parse(ApiEndpoints.archiveMediaPaged(page: 0, size: 9999)),
      );
      if (!mounted) return;
      Navigator.pop(context); // 로딩 닫기

      if (response.statusCode == 200) {
        final allPhotos = ApiClient.decodeBody(response) as List;
        if (allPhotos.isEmpty) return;
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => SlideshowPage(photos: allPhotos),
          ),
        );
      }
    } catch (e) {
      if (mounted) Navigator.pop(context);
      debugPrint("슬라이드쇼 로딩 에러: $e");
    }
  }

  bool _isVideoFile(String filename) {
    final ext = filename.toLowerCase().split('.').last;
    return ['mp4', 'mov', 'avi', 'mkv'].contains(ext);
  }

  Future<void> pickAndUploadImage() async {
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
        Uri.parse(ApiEndpoints.archiveMediaDelete(mediaId)),
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
          onSaved: _fetchPhotos,
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
              onTap: () async {
                Navigator.pop(context);
                final confirmed = await ConfirmDeleteDialog.show(
                  context,
                  title: '사진 삭제',
                  content: '이 사진을 삭제할까요?',
                );
                if (confirmed) _deleteMedia(photo['id']);
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
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 16),
            Text("업로드 중...", style: TextStyle(color: Theme.of(context).colorScheme.primary)),
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
                      placeholder: (context, url) => Container(
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      ),
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
        ),
        if (_isLoadingMore)
          Padding(
            padding: const EdgeInsets.all(16),
            child: CircularProgressIndicator(strokeWidth: 2, color: Theme.of(context).colorScheme.primary),
          ),
      ],
    );
  }
}

// ── 전체화면 사진 뷰어 (좌우 스와이프 + 필름 필터) ──
class _PhotoViewerPage extends StatefulWidget {
  final List<dynamic> photos;
  final int initialIndex;
  final Function(dynamic photo) onDelete;
  final VoidCallback? onSaved;

  const _PhotoViewerPage({
    required this.photos,
    required this.initialIndex,
    required this.onDelete,
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
  bool _showUI = false;

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
      _showUI = false;
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
        Uri.parse(ApiEndpoints.archiveUpload),
      );
      final albumId = photo['albumId'] as int?;
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
      } else if (defaultTargetPlatform == TargetPlatform.macOS) {
        final downloadsDir = await getDownloadsDirectory();
        final filePath = '${downloadsDir!.path}/$filename';
        final response = await http.get(Uri.parse(url));
        await File(filePath).writeAsBytes(response.bodyBytes);
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

    // 날짜 선택
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

    // 시간 선택
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
      appBar: _showUI ? AppBar(
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
      ) : null,
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
                    onTap: () => setState(() => _showUI = !_showUI),
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
          if (_showUI && !_isCurrentVideo) _buildFilterBar(),
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
  bool _unsupported = false;

  @override
  void initState() {
    super.initState();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.url));
    _controller.initialize().then((_) {
      if (mounted) setState(() => _initialized = true);
    }).catchError((e) {
      debugPrint('비디오 초기화 실패: $e');
      if (mounted) setState(() => _unsupported = true);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_unsupported) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.videocam_off, color: Colors.white54, size: 48),
            SizedBox(height: 8),
            Text('이 기기에서는 동영상을 재생할 수 없어요', style: TextStyle(color: Colors.white54)),
          ],
        ),
      );
    }
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

// ── 슬라이드쇼 페이지 ──
class SlideshowPage extends StatefulWidget {
  final List<dynamic> photos;

  const SlideshowPage({super.key, required this.photos});

  @override
  State<SlideshowPage> createState() => _SlideshowPageState();
}

class _SlideshowPageState extends State<SlideshowPage>
    with SingleTickerProviderStateMixin {
  int _currentIndex = 0;
  bool _isPlaying = true;
  bool _showControls = true;
  bool _isShuffle = true;
  int _intervalSeconds = 3;
  Timer? _timer;
  Timer? _progressTimer;
  double _progress = 0.0;
  late AnimationController _fadeController;
  final List<int> _shuffleQueue = [];

  static const List<int> _intervals = [2, 3, 5, 8];

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
      value: 1.0,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _buildShuffleQueue();
      _startTimer();
      _scheduleHideControls();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _progressTimer?.cancel();
    _fadeController.dispose();
    super.dispose();
  }

  void _buildShuffleQueue() {
    final indices = List<int>.generate(widget.photos.length, (i) => i)
      ..remove(_currentIndex)
      ..shuffle(Random());
    _shuffleQueue
      ..clear()
      ..addAll(indices);
    debugPrint('🔀 셔플큐 생성: $_shuffleQueue (현재: $_currentIndex)');
  }

  void _preloadAhead() {
    final toPreload = <int>[];
    if (_isShuffle) {
      for (int i = 0; i < 2 && i < _shuffleQueue.length; i++) {
        toPreload.add(_shuffleQueue[i]);
      }
    } else {
      for (int i = 1; i <= 2; i++) {
        toPreload.add((_currentIndex + i) % widget.photos.length);
      }
    }
    for (final index in toPreload) {
      final photo = widget.photos[index];
      final mediaType = photo['mediaType'] as String?;
      if (mediaType == 'VIDEO') continue;
      final url = photo['mediaUrl'] as String?;
      if (url != null && mounted) {
        precacheImage(CachedNetworkImageProvider(url), context);
      }
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _progressTimer?.cancel();
    _progress = 0.0;
    _preloadAhead();

    const tickMs = 50;
    final totalTicks = (_intervalSeconds * 1000) ~/ tickMs;
    int ticks = 0;

    _progressTimer = Timer.periodic(const Duration(milliseconds: tickMs), (t) {
      ticks++;
      if (mounted) setState(() => _progress = ticks / totalTicks);
    });

    _timer = Timer(Duration(seconds: _intervalSeconds), _nextPhoto);
  }

  void _nextPhoto() {
    if (!mounted) return;
    if (_isShuffle && widget.photos.length > 1) {
      if (_shuffleQueue.isEmpty) _buildShuffleQueue();
      final next = _shuffleQueue.removeAt(0);
      debugPrint('🔀 다음사진: $next (셔플큐 남은것: $_shuffleQueue)');
      setState(() => _currentIndex = next);
    } else {
      final next = (_currentIndex + 1) % widget.photos.length;
      debugPrint('▶ 다음사진: $next (순서재생)');
      setState(() => _currentIndex = next);
    }
    _startTimer();
  }

  void _stopTimer() {
    _timer?.cancel();
    _progressTimer?.cancel();
    if (mounted) setState(() => _progress = 0.0);
  }

  void _togglePlay() {
    setState(() => _isPlaying = !_isPlaying);
    if (_isPlaying) {
      _startTimer();
    } else {
      _stopTimer();
    }
    _scheduleHideControls();
  }

  void _scheduleHideControls() {
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted && _isPlaying) {
        _fadeController.reverse();
        setState(() => _showControls = false);
      }
    });
  }

  void _onTap() {
    if (!_showControls) {
      setState(() => _showControls = true);
      _fadeController.forward();
      _scheduleHideControls();
    } else {
      _togglePlay();
    }
  }

  void _setInterval(int seconds) {
    setState(() => _intervalSeconds = seconds);
    if (_isPlaying) _startTimer();
    _scheduleHideControls();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: _onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // ── 사진 페이드 전환 ──
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 600),
              transitionBuilder: (child, animation) =>
                  FadeTransition(opacity: animation, child: child),
              child: CachedNetworkImage(
                key: ValueKey(_currentIndex),
                imageUrl: widget.photos[_currentIndex]['mediaUrl'],
                fit: BoxFit.contain,
                width: double.infinity,
                height: double.infinity,
                placeholder: (context, url) => const Center(
                  child: CircularProgressIndicator(color: Colors.white54),
                ),
                errorWidget: (context, url, error) =>
                    const Icon(Icons.broken_image, color: Colors.white54, size: 64),
              ),
            ),

            // ── 컨트롤 오버레이 ──
            FadeTransition(
              opacity: _fadeController,
              child: _showControls
                  ? _buildControls()
                  : const SizedBox.shrink(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildControls() {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 상단 그라디언트 + 닫기 버튼
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.black54, Colors.transparent],
              ),
            ),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.pop(context),
                    ),
                    const Spacer(),
                    Text(
                      "${_currentIndex + 1} / ${widget.photos.length}",
                      style: const TextStyle(color: Colors.white, fontSize: 14),
                    ),
                    const SizedBox(width: 16),
                  ],
                ),
              ),
            ),
          ),
        ),

        // 하단 컨트롤
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.bottomCenter,
                end: Alignment.topCenter,
                colors: [Colors.black54, Colors.transparent],
              ),
            ),
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 진행 바
                    ClipRRect(
                      borderRadius: BorderRadius.circular(2),
                      child: LinearProgressIndicator(
                        value: _progress.clamp(0.0, 1.0),
                        backgroundColor: Colors.white30,
                        valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                        minHeight: 3,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // 이전
                        IconButton(
                          icon: const Icon(Icons.skip_previous_rounded, color: Colors.white, size: 32),
                          onPressed: () {
                            setState(() {
                              _currentIndex = (_currentIndex - 1 + widget.photos.length) % widget.photos.length;
                            });
                            if (_isPlaying) _startTimer();
                          },
                        ),
                        const SizedBox(width: 16),
                        // 재생/일시정지
                        GestureDetector(
                          onTap: _togglePlay,
                          child: Container(
                            width: 56,
                            height: 56,
                            decoration: const BoxDecoration(
                              color: Colors.white24,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              _isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                              color: Colors.white,
                              size: 36,
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        // 다음
                        IconButton(
                          icon: const Icon(Icons.skip_next_rounded, color: Colors.white, size: 32),
                          onPressed: () => _nextPhoto(),
                        ),
                        const Spacer(),
                        // 셔플
                        IconButton(
                          icon: Icon(
                            Icons.shuffle_rounded,
                            color: _isShuffle ? Colors.white : Colors.white38,
                            size: 24,
                          ),
                          onPressed: () {
                            setState(() {
                              _isShuffle = !_isShuffle;
                            });
                            debugPrint('🔀 셔플 토글: $_isShuffle');
                            if (_isShuffle) _buildShuffleQueue();
                          },
                        ),
                        // 간격 선택
                        Row(
                          children: _intervals.map((sec) {
                            final selected = _intervalSeconds == sec;
                            return GestureDetector(
                              onTap: () => _setInterval(sec),
                              child: Container(
                                margin: const EdgeInsets.symmetric(horizontal: 4),
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                decoration: BoxDecoration(
                                  color: selected ? Colors.white : Colors.white24,
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  '${sec}s',
                                  style: TextStyle(
                                    color: selected ? Colors.black : Colors.white,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            );
                          }).toList(),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
