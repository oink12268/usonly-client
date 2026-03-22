import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:cached_network_image/cached_network_image.dart';
import 'api_config.dart';
import 'api_client.dart';

class ChatMediaPage extends StatefulWidget {
  const ChatMediaPage({super.key});

  @override
  State<ChatMediaPage> createState() => _ChatMediaPageState();
}

class _ChatMediaPageState extends State<ChatMediaPage> {
  List<String> _imageUrls = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _fetchImages();
  }

  Future<void> _fetchImages() async {
    try {
      final response = await ApiClient.get(
        Uri.parse('${ApiConfig.baseUrl}/api/chats/images'),
      );
      if (response.statusCode == 200) {
        final chats = jsonDecode(utf8.decode(response.bodyBytes)) as List;
        final urls = chats
            .map((c) => (c['message'] as String).replaceFirst('IMAGE:', ''))
            .where((url) => url.isNotEmpty)
            .toList();
        if (mounted) setState(() { _imageUrls = urls; _isLoading = false; });
      } else {
        if (mounted) setState(() => _isLoading = false);
      }
    } catch (e) {
      debugPrint('채팅 이미지 로드 실패: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('채팅 사진'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _imageUrls.isEmpty
              ? const Center(child: Text('아직 공유된 사진이 없어요'))
              : GridView.builder(
                  padding: const EdgeInsets.all(2),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 2,
                    mainAxisSpacing: 2,
                  ),
                  itemCount: _imageUrls.length,
                  itemBuilder: (context, index) {
                    final url = _imageUrls[index];
                    return GestureDetector(
                      onTap: () => _openFullScreen(context, index),
                      child: CachedNetworkImage(
                        imageUrl: url,
                        fit: BoxFit.cover,
                        placeholder: (_, __) => Container(color: Theme.of(context).colorScheme.surfaceContainerHighest),
                        errorWidget: (_, __, ___) => Container(
                          color: Theme.of(context).colorScheme.surfaceContainerHighest,
                          child: Icon(Icons.broken_image, color: Theme.of(context).colorScheme.onSurfaceVariant),
                        ),
                      ),
                    );
                  },
                ),
    );
  }

  void _openFullScreen(BuildContext context, int initialIndex) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => _FullScreenGallery(
          urls: _imageUrls,
          initialIndex: initialIndex,
        ),
      ),
    );
  }
}

class _FullScreenGallery extends StatefulWidget {
  final List<String> urls;
  final int initialIndex;
  const _FullScreenGallery({required this.urls, required this.initialIndex});

  @override
  State<_FullScreenGallery> createState() => _FullScreenGalleryState();
}

class _FullScreenGalleryState extends State<_FullScreenGallery> {
  late final PageController _pageController;
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
        title: Text('${_currentIndex + 1} / ${widget.urls.length}'),
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: widget.urls.length,
        onPageChanged: (i) => setState(() => _currentIndex = i),
        itemBuilder: (context, index) {
          return InteractiveViewer(
            child: Center(
              child: CachedNetworkImage(
                imageUrl: widget.urls[index],
                fit: BoxFit.contain,
                placeholder: (_, __) =>
                    const Center(child: CircularProgressIndicator(color: Colors.white)),
                errorWidget: (_, __, ___) =>
                    const Icon(Icons.broken_image, color: Colors.white, size: 64),
              ),
            ),
          );
        },
      ),
    );
  }
}
