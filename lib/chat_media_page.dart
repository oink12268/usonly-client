import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'api_client.dart';
import 'api_endpoints.dart';
import 'chat_search_page.dart';

class ChatMediaPage extends StatefulWidget {
  const ChatMediaPage({super.key});

  @override
  State<ChatMediaPage> createState() => _ChatMediaPageState();
}

class _ChatMediaPageState extends State<ChatMediaPage> {
  final List<String> _imageUrls = [];
  final ScrollController _scrollController = ScrollController();
  int _currentPage = 0;
  static const int _pageSize = 30;
  bool _hasMore = true;
  bool _isLoading = true;
  bool _isLoadingMore = false;

  @override
  void initState() {
    super.initState();
    _fetchImages();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 300) {
      if (_hasMore && !_isLoadingMore) {
        _fetchImages();
      }
    }
  }

  Future<void> _fetchImages() async {
    if (_isLoadingMore) return;
    setState(() => _isLoadingMore = true);

    try {
      final response = await ApiClient.get(
        Uri.parse(ApiEndpoints.chatImages(page: _currentPage, size: _pageSize)),
      );
      if (response.statusCode == 200) {
        final chats = ApiClient.decodeBody(response) as List;
        final urls = chats
            .map((c) => (c['message'] as String).replaceFirst('IMAGE:', ''))
            .where((url) => url.isNotEmpty)
            .toList();
        if (mounted) {
          setState(() {
            _imageUrls.addAll(urls);
            _hasMore = urls.length == _pageSize;
            _currentPage++;
            _isLoading = false;
            _isLoadingMore = false;
          });
        }
      } else {
        if (mounted) setState(() { _isLoading = false; _isLoadingMore = false; });
      }
    } catch (e) {
      debugPrint('채팅 이미지 로드 실패: $e');
      if (mounted) setState(() { _isLoading = false; _isLoadingMore = false; });
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
                  controller: _scrollController,
                  padding: const EdgeInsets.all(2),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 3,
                    crossAxisSpacing: 2,
                    mainAxisSpacing: 2,
                  ),
                  itemCount: _imageUrls.length + (_hasMore ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (index == _imageUrls.length) {
                      return const Center(
                        child: Padding(
                          padding: EdgeInsets.all(16),
                          child: CircularProgressIndicator(),
                        ),
                      );
                    }
                    final url = _imageUrls[index];
                    return GestureDetector(
                      onTap: () => _openFullScreen(context, index),
                      child: CachedNetworkImage(
                        imageUrl: url,
                        fit: BoxFit.cover,
                        placeholder: (_, __) => Container(
                            color: Theme.of(context).colorScheme.surfaceContainerHighest),
                        errorWidget: (_, __, ___) => Container(
                          color: Theme.of(context).colorScheme.surfaceContainerHighest,
                          child: Icon(Icons.broken_image,
                              color: Theme.of(context).colorScheme.onSurfaceVariant),
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
        builder: (_) => FullScreenImageView(
          imageUrls: _imageUrls,
          initialIndex: initialIndex,
        ),
      ),
    );
  }
}
