import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:stomp_dart_client/stomp_dart_client.dart'; // 소켓 라이브러리
import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'api_config.dart';
import 'api_client.dart';

class ChatPage extends StatefulWidget {
  final String uid; // 내 아이디
  const ChatPage({super.key, required this.uid});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver {
  // 텍스트 입력 및 스크롤 제어기
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  final FocusNode _focusNode = FocusNode();
  // 채팅 데이터 담을 리스트
  List<dynamic> _chats = [];

  // 소켓 클라이언트 객체
  StompClient? stompClient;

  // 답장 관련 상태
  Map<String, dynamic>? _replyTarget;
  bool _isUploadingImage = false;

  // 타이핑 인디케이터 상태
  bool _partnerTyping = false;
  Timer? _typingTimer;
  Timer? _partnerTypingTimer;

  // 검색 관련 상태
  bool _isSearching = false;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();
  List<int> _searchMatchIndices = [];
  int _currentMatchIndex = -1;

  // uid → 닉네임 캐시
  final Map<String, String> _nicknameCache = {};

  final String socketUrl = ApiConfig.wsUrl;
  final String httpUrl = '${ApiConfig.baseUrl}/api/chats';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 1. 방에 들어오자마자 지난 대화 기록 가져오기 (HTTP)
    _fetchHistory();
    // 2. 소켓 연결 시작 (전화기 들기)
    _connectSocket();

    _focusNode.addListener(() {
      setState(() {}); // 포커스 변경 시 하트 아이콘 토글
      if (_focusNode.hasFocus) {
        Future.delayed(
          const Duration(milliseconds: 300),
          () => _scrollToBottom(),
        );
      }
    });
  }

  // 앱이 포그라운드로 돌아올 때 채팅 새로고침 + 소켓 재연결
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _fetchHistory();
      // 기존 소켓 끊고 재연결
      stompClient?.deactivate();
      stompClient = null;
      _connectSocket();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // 방 나가면 소켓 끊기 (필수)
    stompClient?.deactivate();
    _typingTimer?.cancel();
    _partnerTypingTimer?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    _searchController.dispose();
    super.dispose();
  }

  // --- [닉네임 조회] ---
  Future<String> _getNickname(String uid) async {
    if (_nicknameCache.containsKey(uid)) return _nicknameCache[uid]!;
    try {
      final response = await ApiClient.get(
        Uri.parse('${ApiConfig.baseUrl}/api/members/nickname?providerId=$uid'),
      );
      if (response.statusCode == 200) {
        final nickname = utf8.decode(response.bodyBytes);
        _nicknameCache[uid] = nickname;
        return nickname;
      }
    } catch (e) {
      print("닉네임 조회 실패: $e");
    }
    return uid.substring(0, 4);
  }

  // --- [1] 지난 대화 로딩 (HTTP GET) ---
  Future<void> _fetchHistory() async {
    try {
      final response = await ApiClient.get(Uri.parse(httpUrl));
      if (response.statusCode == 200) {
        final chats = jsonDecode(utf8.decode(response.bodyBytes)) as List;
        setState(() {
          _chats = chats;
        });

        // 상대방 닉네임 미리 조회
        final partnerUids = chats
            .map((c) => c['writerUid']?.toString() ?? '')
            .where((uid) => uid.isNotEmpty && uid != widget.uid)
            .toSet();
        for (final uid in partnerUids) {
          await _getNickname(uid);
        }
        if (partnerUids.isNotEmpty) setState(() {});

        // 로딩 끝나면 스크롤 맨 아래로
        _scrollToBottom();
      }
    } catch (e) {
      print("❌ 지난 대화 로딩 실패: $e");
    }
  }

  // --- [2] 소켓 연결 및 구독 (WebSocket) ---
  void _connectSocket() async {
    final connectHeaders = await ApiClient.stompHeaders();
    stompClient = StompClient(
      config: StompConfig(
        url: socketUrl,
        stompConnectHeaders: connectHeaders,
        onConnect: (StompFrame frame) {
          print("✅ 소켓 연결 성공!");

          // 타이핑 이벤트 구독
          stompClient!.subscribe(
            destination: '/sub/chat/typing',
            callback: (StompFrame frame) {
              if (frame.body != null) {
                final data = jsonDecode(frame.body!);
                if (data['writerUid'] != widget.uid) {
                  setState(() => _partnerTyping = data['typing'] == true);
                  _partnerTypingTimer?.cancel();
                  if (data['typing'] == true) {
                    _partnerTypingTimer = Timer(const Duration(seconds: 3), () {
                      setState(() => _partnerTyping = false);
                    });
                  }
                }
              }
            },
          );

          // 채팅 삭제 이벤트 구독
          stompClient!.subscribe(
            destination: '/sub/chat/delete',
            callback: (StompFrame frame) {
              if (frame.body != null) {
                final data = jsonDecode(frame.body!);
                final deletedId = data['id'];
                setState(() {
                  _chats.removeWhere((c) => c['id'] == deletedId);
                });
              }
            },
          );

          // 구독(Subscribe): 서버가 '/sub/chat'으로 뭐 보내면 내가 낚아챔
          stompClient!.subscribe(
            destination: '/sub/chat',
            callback: (StompFrame frame) async {
              if (frame.body != null) {
                // 받은 메시지를 JSON으로 변환
                var newChat = jsonDecode(frame.body!);

                // 새 메시지 작성자 닉네임 조회
                final uid = newChat['writerUid']?.toString() ?? '';
                if (uid.isNotEmpty && uid != widget.uid && !_nicknameCache.containsKey(uid)) {
                  await _getNickname(uid);
                }

                // 화면 갱신: 리스트에 추가하고 스크롤 내리기
                setState(() {
                  _chats.add(newChat);
                });
                _scrollToBottom();
              }
            },
          );
        },
        onWebSocketError: (dynamic error) => print("🚨 소켓 에러: $error"),
      ),
    );

    // 연결 활성화
    stompClient!.activate();
  }

  // --- 타이핑 이벤트 전송 ---
  void _onTypingChanged(String text) {
    if (text.isNotEmpty) {
      _sendTypingEvent(true);
      _typingTimer?.cancel();
      _typingTimer = Timer(const Duration(seconds: 2), () => _sendTypingEvent(false));
    } else {
      _sendTypingEvent(false);
    }
  }

  void _sendTypingEvent(bool isTyping) {
    stompClient?.send(
      destination: '/pub/chat/typing',
      body: jsonEncode({'writerUid': widget.uid, 'typing': isTyping}),
    );
  }

  // --- [3] 메시지 전송 (Publish) ---
  void _sendMessage() {
    if (_controller.text.isEmpty) return;

    final payload = {
      'message': _controller.text,
      'writerUid': widget.uid,
    };

    // 답장 정보가 있으면 같이 보냄
    if (_replyTarget != null) {
      payload['replyToId'] = _replyTarget!['id']?.toString() ?? '0';
      payload['replyToMessage'] = _replyTarget!['message']?.toString() ?? '';
      payload['replyToUid'] = _replyTarget!['writerUid']?.toString() ?? '';
    }

    // 소켓으로 메시지 쏘기
    stompClient!.send(
      destination: '/pub/chat', // Controller의 @MessageMapping 주소
      body: jsonEncode(payload),
    );

    _controller.clear(); // 입력창 비우기
    _sendTypingEvent(false); // 타이핑 상태 해제
    _typingTimer?.cancel();
    _cancelReply();       // 답장 상태 초기화
  }

  Future<void> _pickAndUploadImage() async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: ImageSource.gallery, imageQuality: 30, maxWidth: 800);
    if (image == null) return;

    setState(() => _isUploadingImage = true);
    try {
      var request = http.MultipartRequest(
        'POST',
        Uri.parse('${ApiConfig.baseUrl}/api/chat/image'),
      );
      final bytes = await image.readAsBytes();
      request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: image.name));

      var response = await ApiClient.sendMultipart(request);
      if (response.statusCode == 200) {
        final respBody = await response.stream.bytesToString();
        final data = jsonDecode(respBody);
        _sendImageMessage(data['imageUrl']);
      } else {
        throw Exception('업로드 실패: ${response.statusCode}');
      }
    } catch (e) {
      print("❌ 이미지 업로드 실패: $e");
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('사진 전송 실패!')),
      );
    } finally {
      setState(() => _isUploadingImage = false);
    }
  }

  void _sendImageMessage(String imageUrl) {
    if (stompClient == null) return;

    stompClient!.send(
      destination: '/pub/chat',
      body: jsonEncode({
        'message': 'IMAGE:$imageUrl',
        'writerUid': widget.uid,
      }),
    );
  }

  // --- 메시지 롱프레스 옵션 ---
  void _showMessageOptions(dynamic chat) {
    final isMe = chat['writerUid'] == widget.uid;
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.reply, color: Color(0xFF8B7E74)),
              title: const Text("답장"),
              onTap: () {
                Navigator.pop(context);
                _setReplyTarget(chat);
              },
            ),
            if (isMe && chat['id'] != null)
              ListTile(
                leading: const Icon(Icons.delete, color: Colors.red),
                title: const Text("삭제"),
                onTap: () {
                  Navigator.pop(context);
                  _showDeleteDialog(chat);
                },
              ),
          ],
        ),
      ),
    );
  }

  // --- 메시지 삭제 ---
  void _showDeleteDialog(dynamic chat) {
    // 자기 메시지만 삭제 가능
    if (chat['writerUid'] != widget.uid) return;
    if (chat['id'] == null) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text("메시지 삭제"),
        content: const Text("이 메시지를 삭제할까요?"),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text("취소"),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              _deleteChat(chat['id']);
            },
            child: const Text("삭제", style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  Future<void> _deleteChat(dynamic chatId) async {
    try {
      final response = await ApiClient.delete(
        Uri.parse('${ApiConfig.baseUrl}/api/chats/$chatId'),
      );
      if (response.statusCode != 200) {
        print("메시지 삭제 실패: ${response.statusCode}");
      }
    } catch (e) {
      print("메시지 삭제 에러: $e");
    }
  }

  // 답장 대상 설정
  void _setReplyTarget(dynamic chat) {
    setState(() {
      _replyTarget = chat;
    });
    _focusNode.requestFocus();
  }

  // 답장 취소
  void _cancelReply() {
    setState(() {
      _replyTarget = null;
    });
  }

  // 답장 미리보기 텍스트
  String _replyPreviewText(String message) {
    if (message.startsWith('IMAGE:')) return '사진';
    if (message.length > 30) return '${message.substring(0, 30)}...';
    return message;
  }

  // --- 검색 기능 ---
  void _startSearch() {
    setState(() {
      _isSearching = true;
      _searchQuery = '';
      _searchMatchIndices = [];
      _currentMatchIndex = -1;
      _searchController.clear();
    });
  }

  void _stopSearch() {
    setState(() {
      _isSearching = false;
      _searchQuery = '';
      _searchMatchIndices = [];
      _currentMatchIndex = -1;
      _searchController.clear();
    });
  }

  void _onSearchChanged(String query) {
    final lowerQuery = query.toLowerCase();
    final matches = <int>[];
    if (lowerQuery.isNotEmpty) {
      for (int i = 0; i < _chats.length; i++) {
        final msg = (_chats[i]['message'] as String?) ?? '';
        if (msg.startsWith('IMAGE:')) continue;
        if (msg.toLowerCase().contains(lowerQuery)) {
          matches.add(i);
        }
      }
    }
    setState(() {
      _searchQuery = query;
      _searchMatchIndices = matches;
      _currentMatchIndex = matches.isNotEmpty ? 0 : -1;
    });
    if (matches.isNotEmpty) {
      _jumpToMatch(0);
    }
  }

  void _jumpToMatch(int matchIndex) {
    if (matchIndex < 0 || matchIndex >= _searchMatchIndices.length) return;
    final chatIndex = _searchMatchIndices[matchIndex];
    // 대략적인 아이템 높이로 스크롤 위치 추정
    final estimatedOffset = chatIndex * 80.0;
    final maxScroll = _scrollController.position.maxScrollExtent;
    _scrollController.animateTo(
      estimatedOffset.clamp(0.0, maxScroll),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  void _prevMatch() {
    if (_searchMatchIndices.isEmpty) return;
    setState(() {
      _currentMatchIndex = (_currentMatchIndex - 1 + _searchMatchIndices.length) % _searchMatchIndices.length;
    });
    _jumpToMatch(_currentMatchIndex);
  }

  void _nextMatch() {
    if (_searchMatchIndices.isEmpty) return;
    setState(() {
      _currentMatchIndex = (_currentMatchIndex + 1) % _searchMatchIndices.length;
    });
    _jumpToMatch(_currentMatchIndex);
  }

  // 스크롤 맨 아래로 내리는 함수
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
      }
    });
  }

  bool _isSameDate(String? date1, String? date2) {
    if (date1 == null || date2 == null) return false;
    return date1.split('T')[0] == date2.split('T')[0];
  }

  // 시간 포맷 (createdAt → "오후 3:05" 형태)
  String _formatTime(String? dateTime) {
    if (dateTime == null) return '';
    try {
      final dt = DateTime.parse(dateTime);
      final hour = dt.hour;
      final minute = dt.minute.toString().padLeft(2, '0');
      if (hour == 0) return '오전 12:$minute';
      if (hour < 12) return '오전 $hour:$minute';
      if (hour == 12) return '오후 12:$minute';
      return '오후 ${hour - 12}:$minute';
    } catch (e) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // 검색바
        if (_isSearching)
          Container(
            color: const Color(0xFFF5F0EB),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchController,
                    autofocus: true,
                    decoration: InputDecoration(
                      hintText: '메시지 검색...',
                      hintStyle: TextStyle(color: Colors.grey[400], fontSize: 14),
                      filled: true,
                      fillColor: Colors.white,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(20),
                        borderSide: BorderSide.none,
                      ),
                      prefixIcon: const Icon(Icons.search, color: Color(0xFF8B7E74), size: 20),
                    ),
                    onChanged: _onSearchChanged,
                  ),
                ),
                const SizedBox(width: 8),
                if (_searchQuery.isNotEmpty)
                  Text(
                    _searchMatchIndices.isEmpty
                        ? '0/0'
                        : '${_currentMatchIndex + 1}/${_searchMatchIndices.length}',
                    style: const TextStyle(fontSize: 13, color: Color(0xFF8B7E74)),
                  ),
                IconButton(
                  icon: const Icon(Icons.keyboard_arrow_up, color: Color(0xFF8B7E74)),
                  onPressed: _prevMatch,
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  icon: const Icon(Icons.keyboard_arrow_down, color: Color(0xFF8B7E74)),
                  onPressed: _nextMatch,
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  icon: const Icon(Icons.close, color: Color(0xFF8B7E74)),
                  onPressed: _stopSearch,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),

        // 채팅 리스트 영역
        Expanded(
          child: GestureDetector(
            onLongPress: _startSearch,
            child: ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.all(16),
            itemCount: _chats.length,
            itemBuilder: (context, index) {
              final chat = _chats[index];
              final message = chat['message'] as String;
              final String? createdAt = chat['created_at'] ?? chat['createdAt'];
              final isMe = chat['writerUid'] == widget.uid;

              // ★ 날짜 구분선 표시 여부 판단
              bool showDateDivider = false;
              if (index == 0) {
                showDateDivider = true;
              } else {
                final prevChat = _chats[index - 1];
                final prevDate = prevChat['created_at'] ?? prevChat['createdAt'];
                showDateDivider = !_isSameDate(createdAt, prevDate);
              }

              // 메시지 내용 처리 (사진 vs 텍스트)
              final isImage = message.startsWith('IMAGE:');
              final String content = isImage ? message.replaceFirst('IMAGE:', '') : message;

              // 검색 매치 여부
              final bool isSearchMatch = _isSearching && _searchMatchIndices.contains(index);
              final bool isCurrentMatch = isSearchMatch && _currentMatchIndex >= 0 &&
                  _currentMatchIndex < _searchMatchIndices.length &&
                  _searchMatchIndices[_currentMatchIndex] == index;

              // 답장 정보
              final hasReply = chat['replyToId'] != null;
              final String? replyToMessage = chat['replyToMessage'];
              final String? replyToUid = chat['replyToUid'];

              return Column(
                children: [
                  // [1] 날짜 구분선
                  if (showDateDivider && createdAt != null)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          decoration: BoxDecoration(
                            color: Colors.black.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            createdAt.split('T')[0],
                            style: const TextStyle(color: Colors.white, fontSize: 12),
                          ),
                        ),
                      ),
                    ),

                  // [2] 말풍선 (스와이프 or 롱프레스로 답장)
                  Dismissible(
                    key: ValueKey(chat['id'] ?? index),
                    direction: DismissDirection.startToEnd,
                    confirmDismiss: (_) async {
                      _setReplyTarget(chat);
                      return false;
                    },
                    background: Container(
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.only(left: 20),
                      child: const Icon(Icons.reply, color: Color(0xFF8B7E74)),
                    ),
                    child: GestureDetector(
                      onLongPress: () => _showMessageOptions(chat),
                      child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      child: Row(
                        mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          if (!isMe)
                            const Column(
                              mainAxisAlignment: MainAxisAlignment.start,
                              children: [
                                Padding(
                                  padding: EdgeInsets.only(right: 8.0),
                                  child: CircleAvatar(
                                    backgroundColor: Colors.white,
                                    child: Icon(Icons.person, color: Colors.grey),
                                  ),
                                ),
                              ],
                            ),
                          // 내 메시지: 시간 왼쪽 + 말풍선 오른쪽
                          if (isMe)
                            Padding(
                              padding: const EdgeInsets.only(right: 4, top: 4),
                              child: Align(
                                alignment: Alignment.bottomRight,
                                child: Text(
                                  _formatTime(createdAt),
                                  style: TextStyle(fontSize: 10, color: Colors.grey[500]),
                                ),
                              ),
                            ),
                          Flexible(
                            child: Column(
                              crossAxisAlignment: isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                              children: [
                                if (!isMe)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 4, left: 2),
                                    child: Text(
                                      _nicknameCache[chat['writerUid']?.toString()] ?? chat['writerUid'].toString().substring(0, 4),
                                      style: const TextStyle(fontSize: 12, color: Colors.black54),
                                    ),
                                  ),

                                // 답장 인용 표시
                                if (hasReply && replyToMessage != null)
                                  Container(
                                    margin: const EdgeInsets.only(bottom: 4),
                                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: Colors.grey[200],
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border(
                                        left: BorderSide(color: const Color(0xFF8B7E74), width: 3),
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          replyToUid != null && replyToUid == widget.uid
                                              ? "나"
                                              : _nicknameCache[replyToUid] ?? replyToUid?.substring(0, 4) ?? "",
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontWeight: FontWeight.bold,
                                            color: const Color(0xFF8B7E74),
                                          ),
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          _replyPreviewText(replyToMessage),
                                          style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ],
                                    ),
                                  ),

                                if (isImage)
                                  GestureDetector(
                                    onTap: () => Navigator.push(
                                      context,
                                      MaterialPageRoute(
                                        builder: (_) => FullScreenImageView(imageUrl: content),
                                      ),
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(15),
                                      child: CachedNetworkImage(
                                        imageUrl: content,
                                        width: 200,
                                        fit: BoxFit.cover,
                                        memCacheWidth: 300,
                                        placeholder: (context, url) => Container(
                                            width: 200, height: 200, color: Colors.grey[300]),
                                        errorWidget: (context, url, error) => const Icon(Icons.error),
                                      ),
                                    ),
                                  )
                                else
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                    decoration: BoxDecoration(
                                      color: isMe ? const Color(0xFF8B7E74) : const Color(0xFFF0EBE5),
                                      borderRadius: BorderRadius.only(
                                        topLeft: const Radius.circular(15),
                                        topRight: const Radius.circular(15),
                                        bottomLeft: isMe ? const Radius.circular(15) : const Radius.circular(0),
                                        bottomRight: isMe ? const Radius.circular(0) : const Radius.circular(15),
                                      ),
                                      border: isCurrentMatch
                                          ? Border.all(color: Colors.orange, width: 2.5)
                                          : isSearchMatch
                                              ? Border.all(color: Colors.orange.withValues(alpha: 0.5), width: 1.5)
                                              : null,
                                      boxShadow: [
                                        BoxShadow(
                                            color: Colors.black.withOpacity(0.05),
                                            blurRadius: 1,
                                            offset: const Offset(1, 1))
                                      ],
                                    ),
                                    child: Text(content, style: TextStyle(fontSize: 16, color: isMe ? Colors.white : Colors.black87)),
                                  ),
                              ],
                            ),
                          ),
                          // 상대 메시지: 말풍선 왼쪽 + 시간 오른쪽
                          if (!isMe)
                            Padding(
                              padding: const EdgeInsets.only(left: 4, top: 4),
                              child: Align(
                                alignment: Alignment.bottomLeft,
                                child: Text(
                                  _formatTime(createdAt),
                                  style: TextStyle(fontSize: 10, color: Colors.grey[500]),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  ),
                ],
              );
            },
          ),
          ),
        ),

        // 상대방 입력 중 표시
        if (_partnerTyping)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text("입력 중...", style: TextStyle(fontSize: 12, color: Colors.grey)),
            ),
          ),

        // 사진 업로드 중 표시
        if (_isUploadingImage)
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF8B7E74))),
                SizedBox(width: 10),
                Text("사진 전송 중...", style: TextStyle(fontSize: 13, color: Color(0xFF8B7E74))),
              ],
            ),
          ),

        // 답장 미리보기 바
        if (_replyTarget != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: Colors.grey[100],
            child: Row(
              children: [
                Container(
                  width: 3,
                  height: 36,
                  color: const Color(0xFF8B7E74),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _replyTarget!['writerUid'] == widget.uid
                            ? "나에게 답장"
                            : "${_replyTarget!['writerUid'].toString().substring(0, 4)}에게 답장",
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: const Color(0xFF8B7E74),
                        ),
                      ),
                      Text(
                        _replyPreviewText(_replyTarget!['message']),
                        style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                GestureDetector(
                  onTap: _cancelReply,
                  child: const Icon(Icons.close, size: 20, color: Colors.grey),
                ),
              ],
            ),
          ),

        // 입력창 영역
        Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.add_photo_alternate_rounded, color: Colors.grey),
                onPressed: _pickAndUploadImage,
              ),
              Expanded(
                child: TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  decoration: InputDecoration(
                    hintText: "",
                    prefixIcon: _focusNode.hasFocus ? null : const Icon(Icons.favorite, color: Colors.grey, size: 20),
                    filled: true,
                    fillColor: Colors.grey[100],
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(30),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 20),
                  ),
                  onChanged: _onTypingChanged,
                  onSubmitted: (_) => _sendMessage(), // 엔터 치면 전송
                ),
              ),
              const SizedBox(width: 8),
              CircleAvatar(
                backgroundColor: const Color(0xFF8B7E74),
                radius: 24,
                child: IconButton(
                  icon: const Icon(Icons.send, color: Colors.white, size: 20),
                  onPressed: _sendMessage,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class FullScreenImageView extends StatelessWidget {
  final String imageUrl;
  const FullScreenImageView({super.key, required this.imageUrl});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        iconTheme: const IconThemeData(color: Colors.white),
        elevation: 0,
      ),
      body: Center(
        child: InteractiveViewer(
          minScale: 0.5,
          maxScale: 4.0,
          child: CachedNetworkImage(
            imageUrl: imageUrl,
            fit: BoxFit.contain,
            placeholder: (context, url) =>
                const CircularProgressIndicator(color: Colors.white),
            errorWidget: (context, url, error) =>
                const Icon(Icons.error, color: Colors.white),
          ),
        ),
      ),
    );
  }
}
