import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'api_client.dart';
import 'api_endpoints.dart';
import 'utils/date_formatter.dart';

// ─────────────────────────────────────────────
// 채팅 키워드 검색 결과 페이지
// ─────────────────────────────────────────────
class ChatSearchListPage extends StatefulWidget {
  final String uid;
  const ChatSearchListPage({super.key, required this.uid});

  @override
  State<ChatSearchListPage> createState() => _ChatSearchListPageState();
}

class _ChatSearchListPageState extends State<ChatSearchListPage> {
  final TextEditingController _controller = TextEditingController();
  List<dynamic> _results = [];
  bool _isLoading = false;

  Future<void> _search(String query) async {
    if (query.trim().isEmpty) {
      setState(() => _results = []);
      return;
    }

    setState(() => _isLoading = true);

    try {
      final response = await ApiClient.get(
        Uri.parse(ApiEndpoints.chatSearchQuery(query.trim())),
      );
      if (response.statusCode == 200) {
        setState(() {
          _results = json.decode(utf8.decode(response.bodyBytes)) as List;
        });
      }
    } catch (e) {
      debugPrint('Search error: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('채팅 검색'),
        backgroundColor: Theme.of(context).colorScheme.surface,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: TextField(
              controller: _controller,
              autofocus: true,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: '검색어를 입력해주세요.',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: () => _search(_controller.text),
                ),
                filled: true,
                fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              ),
              onChanged: (val) {
                if (val.isEmpty) setState(() => _results = []);
              },
              onSubmitted: _search,
            ),
          ),
          if (_controller.text.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '${_results.length}개',
                  style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurface),
                ),
              ),
            ),
          Expanded(
            child: _isLoading
                ? Center(child: CircularProgressIndicator(color: Theme.of(context).colorScheme.primary))
                : _controller.text.isNotEmpty && _results.isEmpty
                    ? Center(
                        child: Text('검색 결과가 없어', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
                      )
                    : ListView.builder(
                        itemCount: _results.length,
                        itemBuilder: (context, index) {
                          final chat = _results[index];
                          final msg = (chat['message'] as String?) ?? '';
                          final isMe = chat['writerUid'] == widget.uid;
                          final createdAt = chat['created_at'] ?? chat['createdAt'];
                          return ListTile(
                            onTap: () {
                              final id = chat['id'];
                              if (id != null) Navigator.pop(context, id as int);
                            },
                            leading: CircleAvatar(
                              radius: 18,
                              backgroundColor: Theme.of(context).colorScheme.primary.withOpacity(0.15),
                              child: Icon(
                                isMe ? Icons.person : Icons.person_outline,
                                color: Theme.of(context).colorScheme.primary,
                                size: 18,
                              ),
                            ),
                            title: Text(
                              isMe ? '나' : '상대방',
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                            ),
                            subtitle: Text(
                              msg,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 13),
                            ),
                            trailing: Text(
                              DateFormatter.formatDateTime(createdAt),
                              style: TextStyle(fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────
// 날짜별 채팅 달력 페이지
// ─────────────────────────────────────────────
class ChatCalendarPage extends StatefulWidget {
  final String uid;
  const ChatCalendarPage({super.key, required this.uid});

  @override
  State<ChatCalendarPage> createState() => _ChatCalendarPageState();
}

class _ChatCalendarPageState extends State<ChatCalendarPage> {
  late DateTime _focusedMonth;
  Map<String, int> _countByDate = {};
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _focusedMonth = DateTime.now();
    _fetchCalendarData();
  }

  Future<void> _fetchCalendarData() async {
    setState(() => _isLoading = true);
    try {
      final response = await ApiClient.get(
        Uri.parse(ApiEndpoints.chatCalendar),
      );
      if (response.statusCode == 200) {
        final List<dynamic> data = ApiClient.decodeBody(response) as List;
        setState(() {
          _countByDate = {
            for (final e in data) e['date'] as String: (e['count'] as num).toInt()
          };
        });
      }
    } catch (e) {
      debugPrint('Calendar data error: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('날짜별 채팅'),
        backgroundColor: Theme.of(context).colorScheme.surface,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _fetchCalendarData,
          ),
        ],
      ),
      body: _isLoading && _countByDate.isEmpty
          ? Center(child: CircularProgressIndicator(color: Theme.of(context).colorScheme.primary))
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragEnd: (details) {
                if (details.primaryVelocity! < -500) {
                  setState(() {
                    _focusedMonth = DateTime(_focusedMonth.year, _focusedMonth.month + 1);
                  });
                } else if (details.primaryVelocity! > 500) {
                  setState(() {
                    _focusedMonth = DateTime(_focusedMonth.year, _focusedMonth.month - 1);
                  });
                }
              },
              child: Column(
                children: [
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.chevron_left),
                        onPressed: () => setState(() {
                          _focusedMonth = DateTime(_focusedMonth.year, _focusedMonth.month - 1);
                        }),
                      ),
                      Text(
                        '${_focusedMonth.year}년 ${_focusedMonth.month}월',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      IconButton(
                        icon: const Icon(Icons.chevron_right),
                        onPressed: () => setState(() {
                          _focusedMonth = DateTime(_focusedMonth.year, _focusedMonth.month + 1);
                        }),
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        Expanded(child: Center(child: Text('일', style: TextStyle(fontSize: 12, color: Colors.red, fontWeight: FontWeight.bold)))),
                        const Expanded(child: Center(child: Text('월', style: TextStyle(fontSize: 12)))),
                        const Expanded(child: Center(child: Text('화', style: TextStyle(fontSize: 12)))),
                        const Expanded(child: Center(child: Text('수', style: TextStyle(fontSize: 12)))),
                        const Expanded(child: Center(child: Text('목', style: TextStyle(fontSize: 12)))),
                        const Expanded(child: Center(child: Text('금', style: TextStyle(fontSize: 12)))),
                        Expanded(child: Center(child: Text('토', style: TextStyle(fontSize: 12, color: Colors.blue, fontWeight: FontWeight.bold)))),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: _buildCalendarGrid(),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildCalendarGrid() {
    final firstDay = DateTime(_focusedMonth.year, _focusedMonth.month, 1);
    final lastDay = DateTime(_focusedMonth.year, _focusedMonth.month + 1, 0);
    final startWeekday = firstDay.weekday % 7;
    final today = DateTime.now();

    final cells = <Widget>[];

    for (int i = 0; i < startWeekday; i++) {
      cells.add(const SizedBox());
    }

    for (int day = 1; day <= lastDay.day; day++) {
      final date = DateTime(_focusedMonth.year, _focusedMonth.month, day);
      final dateStr = DateFormatter.formatDate(date);
      final count = _countByDate[dateStr] ?? 0;
      final isToday = date.year == today.year && date.month == today.month && date.day == today.day;
      final isSunday = date.weekday == DateTime.sunday;
      final isSaturday = date.weekday == DateTime.saturday;

      cells.add(
        GestureDetector(
          onTap: count > 0
              ? () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => ChatDayListPage(date: dateStr, uid: widget.uid),
                    ),
                  )
              : null,
          child: Container(
            height: 60,
            decoration: BoxDecoration(
              border: isToday ? Border.all(color: Theme.of(context).colorScheme.primary, width: 1.5) : null,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '$day',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: isToday ? FontWeight.bold : FontWeight.normal,
                    color: isSunday ? Colors.red : isSaturday ? Colors.blue : null,
                  ),
                ),
                if (count > 0) ...[
                  const SizedBox(height: 2),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '$count',
                      style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.onPrimary),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return GridView.count(
      crossAxisCount: 7,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      children: cells,
    );
  }
}

// ─────────────────────────────────────────────
// 특정 날짜의 채팅 리스트 페이지
// ─────────────────────────────────────────────
class ChatDayListPage extends StatefulWidget {
  final String date;
  final String uid;
  const ChatDayListPage({super.key, required this.date, required this.uid});

  @override
  State<ChatDayListPage> createState() => _ChatDayListPageState();
}

class _ChatDayListPageState extends State<ChatDayListPage> {
  List<dynamic> _chats = [];
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _fetchDayChats();
  }

  Future<void> _fetchDayChats() async {
    setState(() => _isLoading = true);
    try {
      final response = await ApiClient.get(
        Uri.parse(ApiEndpoints.chatsByDateQuery(widget.date)),
      );
      if (response.statusCode == 200) {
        setState(() {
          _chats = ApiClient.decodeBody(response) as List;
        });
      }
    } catch (e) {
      debugPrint('Day chats error: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.date),
        backgroundColor: Theme.of(context).colorScheme.surface,
      ),
      body: _isLoading
          ? Center(child: CircularProgressIndicator(color: Theme.of(context).colorScheme.primary))
          : ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
              itemCount: _chats.length,
              itemBuilder: (context, index) {
                final chat = _chats[index];
                final msg = (chat['message'] as String?) ?? '';
                final isMe = chat['writerUid'] == widget.uid;
                final createdAt = chat['created_at'] ?? chat['createdAt'];
                final isImage = msg.startsWith('IMAGE:');
                final content = isImage ? msg.replaceFirst('IMAGE:', '') : msg;

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (!isMe)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: CircleAvatar(
                            radius: 16,
                            backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                            child: Icon(Icons.person, size: 16, color: Theme.of(context).colorScheme.onSurface),
                          ),
                        ),
                      if (isMe)
                        Padding(
                          padding: const EdgeInsets.only(right: 4, bottom: 2),
                          child: Text(
                            DateFormatter.formatTime(createdAt),
                            style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.onSurfaceVariant),
                          ),
                        ),
                      ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: isMe ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.surface,
                            borderRadius: BorderRadius.only(
                              topLeft: const Radius.circular(15),
                              topRight: const Radius.circular(15),
                              bottomLeft: isMe ? const Radius.circular(15) : const Radius.circular(0),
                              bottomRight: isMe ? const Radius.circular(0) : const Radius.circular(15),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withOpacity(0.05),
                                blurRadius: 1,
                                offset: const Offset(1, 1),
                              ),
                            ],
                          ),
                          child: isImage
                              ? CachedNetworkImage(
                                  imageUrl: content,
                                  width: 150,
                                  height: 150,
                                  fit: BoxFit.cover,
                                )
                              : Text(
                                  content,
                                  style: TextStyle(
                                    fontSize: 15,
                                    color: isMe ? Theme.of(context).colorScheme.onPrimary : Theme.of(context).colorScheme.onSurface,
                                  ),
                                ),
                        ),
                      ),
                      if (!isMe)
                        Padding(
                          padding: const EdgeInsets.only(left: 4, bottom: 2),
                          child: Text(
                            DateFormatter.formatTime(createdAt),
                            style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.onSurfaceVariant),
                          ),
                        ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

// ─────────────────────────────────────────────
// 전체화면 이미지 뷰어 (슬라이드 갤러리)
// ─────────────────────────────────────────────
class FullScreenImageView extends StatefulWidget {
  final List<String> imageUrls;
  final int initialIndex;

  const FullScreenImageView({
    super.key,
    required this.imageUrls,
    this.initialIndex = 0,
  });

  /// 단일 이미지용 편의 생성자
  factory FullScreenImageView.single({Key? key, required String imageUrl}) {
    return FullScreenImageView(key: key, imageUrls: [imageUrl], initialIndex: 0);
  }

  @override
  State<FullScreenImageView> createState() => _FullScreenImageViewState();
}

class _FullScreenImageViewState extends State<FullScreenImageView> {
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
    final total = widget.imageUrls.length;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
        title: total > 1
            ? Text(
                '${_currentIndex + 1} / $total',
                style: const TextStyle(color: Colors.white, fontSize: 14),
              )
            : null,
        centerTitle: true,
      ),
      body: PageView.builder(
        controller: _pageController,
        itemCount: total,
        onPageChanged: (i) => setState(() => _currentIndex = i),
        itemBuilder: (context, index) {
          return InteractiveViewer(
            minScale: 0.5,
            maxScale: 4.0,
            child: Center(
              child: CachedNetworkImage(
                imageUrl: widget.imageUrls[index],
                fit: BoxFit.contain,
                placeholder: (context, url) =>
                    const CircularProgressIndicator(color: Colors.white),
                errorWidget: (context, url, error) =>
                    const Icon(Icons.error, color: Colors.white),
              ),
            ),
          );
        },
      ),
    );
  }
}
