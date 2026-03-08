import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:stomp_dart_client/stomp_dart_client.dart'; // 소켓 라이브러리
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/gestures.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';
import 'api_config.dart';
import 'api_client.dart';
import 'fcm_service.dart';
import 'share_intent_service.dart';
import 'chat_media_page.dart';

class ChatPage extends StatefulWidget {
  final String uid; // 내 아이디
  const ChatPage({super.key, required this.uid});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> with WidgetsBindingObserver, TickerProviderStateMixin {
  // 텍스트 입력 및 스크롤 제어기
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  final FocusNode _focusNode = FocusNode();
  // 포커스 상태 (ValueNotifier: setState 없이 하트 아이콘만 업데이트 → 키보드 뜰 때 전체 rebuild 방지)
  final ValueNotifier<bool> _focusNotifier = ValueNotifier(false);
  // 채팅 데이터 담을 리스트
  List<dynamic> _chats = [];

  // 소켓 클라이언트 객체
  StompClient? stompClient;

  // 답장 관련 상태
  Map<String, dynamic>? _replyTarget;
  bool _isUploadingImage = false;
  String _uploadProgress = '';

  // 타이핑 인디케이터 상태 (ValueNotifier: setState 없이 해당 위젯만 업데이트 → 키보드 유지)
  final ValueNotifier<bool> _partnerTypingNotifier = ValueNotifier(false);
  Timer? _typingTimer;
  Timer? _partnerTypingTimer;

  // 페이지네이션 상태
  bool _hasMore = true;
  bool _isLoadingMore = false;

  // 채팅 검색 메뉴 표시 상태
  bool _showChatSearchMenu = false;

  // 검색 결과에서 이동한 메시지 하이라이트
  int? _highlightedMessageId;

  // 전송 버튼 애니메이션
  late AnimationController _sendAnimController;
  late Animation<double> _sendScaleAnim;

  // uid → 닉네임 / 프로필 이미지 캐시
  final Map<String, String> _nicknameCache = {};
  final Map<String, String?> _profileImageCache = {};

  final String socketUrl = ApiConfig.wsUrl;
  final String httpUrl = '${ApiConfig.baseUrl}/api/chats';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sendAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 120),
    );
    _sendScaleAnim = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.35), weight: 40),
      TweenSequenceItem(tween: Tween(begin: 1.35, end: 0.85), weight: 30),
      TweenSequenceItem(tween: Tween(begin: 0.85, end: 1.0), weight: 30),
    ]).animate(CurvedAnimation(parent: _sendAnimController, curve: Curves.easeOut));
    // 채팅 화면 진입: 포그라운드 알림 억제 + 기존 알림/배지 소거
    FcmService().setChatActive(true);
    FcmService().clearChatNotifications();
    // 1. 방에 들어오자마자 지난 대화 기록 가져오기 (HTTP)
    _fetchHistory();
    // 2. 소켓 연결 시작 (전화기 들기)
    _connectSocket();

    _scrollController.addListener(_onScroll);

    // 공유 인텐트로 앱이 열렸을 때 처리
    WidgetsBinding.instance.addPostFrameCallback((_) => _handlePendingShare());

    _focusNode.addListener(() {
      if (!mounted || !_focusNode.hasFocus) return;
      // 키보드 애니메이션이 끝난 뒤 1회만 스크롤
      Future.delayed(const Duration(milliseconds: 350), () {
        if (mounted && _focusNode.hasFocus) _scrollToBottom();
      });
    });
  }

  // 앱이 포그라운드로 돌아올 때 채팅 새로고침 + 소켓 재연결
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 채팅 화면으로 복귀: 알림/배지 소거
      FcmService().clearChatNotifications();
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
    // 채팅 화면 이탈: 포그라운드 알림 억제 해제
    FcmService().setChatActive(false);
    // 방 나가면 소켓 끊기 (필수)
    stompClient?.deactivate();
    _typingTimer?.cancel();
    _partnerTypingTimer?.cancel();
    _partnerTypingNotifier.dispose();
    _focusNotifier.dispose();
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    _sendAnimController.dispose();
    super.dispose();
  }

  // --- [멤버 정보 조회: 닉네임 + 프로필 이미지] ---
  Future<void> _getNickname(String uid) async {
    if (_nicknameCache.containsKey(uid)) return;
    try {
      final response = await ApiClient.get(
        Uri.parse('${ApiConfig.baseUrl}/api/members/info?providerId=$uid'),
      );
      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        _nicknameCache[uid] = data['nickname'] ?? uid.substring(0, 4);
        _profileImageCache[uid] = data['profileImageUrl'];
      }
    } catch (e) {
      debugPrint("멤버 정보 조회 실패: $e");
      _nicknameCache[uid] = uid.substring(0, 4);
    }
  }

  // 스크롤 맨 위 도달 시 이전 메시지 추가 로드
  // (reverse: true 이므로 pixels가 maxScrollExtent에 가까울 때 = 화면 맨 위)
  void _onScroll() {
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 50 &&
        _hasMore &&
        !_isLoadingMore) {
      _loadMore();
    }
  }

  // --- [1] 지난 대화 로딩 (HTTP GET, 최신 50개) ---
  Future<void> _fetchHistory() async {
    try {
      final response = await ApiClient.get(Uri.parse('$httpUrl?size=50'));
      if (response.statusCode == 200) {
        final chats = jsonDecode(utf8.decode(response.bodyBytes)) as List;
        setState(() {
          _chats = chats;
          _hasMore = chats.length >= 50;
        });

        // 상대방 닉네임 병렬 조회
        final partnerUids = chats
            .map((c) => c['writerUid']?.toString() ?? '')
            .where((uid) => uid.isNotEmpty && uid != widget.uid)
            .toSet();
        if (partnerUids.isNotEmpty) {
          await Future.wait(partnerUids.map((uid) => _getNickname(uid)));
          setState(() {});
        }

        // 로딩 끝나면 스크롤 맨 아래로
        _scrollToBottom();
      }
    } catch (e) {
      print("❌ 지난 대화 로딩 실패: $e");
    }
  }

  // 이전 메시지 추가 로드 (스크롤 위로 올릴 때)
  Future<void> _loadMore() async {
    if (_chats.isEmpty) return;
    final firstId = _chats.first['id'];
    if (firstId == null) return;

    setState(() => _isLoadingMore = true);
    try {
      final response = await ApiClient.get(
        Uri.parse('$httpUrl?before=$firstId&size=50'),
      );
      if (response.statusCode == 200) {
        final older = jsonDecode(utf8.decode(response.bodyBytes)) as List;

        // 새로 로드한 메시지의 닉네임 병렬 조회
        final partnerUids = older
            .map((c) => c['writerUid']?.toString() ?? '')
            .where((uid) => uid.isNotEmpty && uid != widget.uid && !_nicknameCache.containsKey(uid))
            .toSet();
        if (partnerUids.isNotEmpty) {
          await Future.wait(partnerUids.map((uid) => _getNickname(uid)));
        }

        // reverse: true ListView에서는 앞에 아이템 추가 시 기존 아이템의
        // 시각적 위치가 변하지 않으므로 스크롤 보정 불필요
        setState(() {
          _chats = [...older, ..._chats];
          _hasMore = older.length >= 50;
        });
      }
    } catch (e) {
      print("❌ 이전 메시지 로딩 실패: $e");
    } finally {
      setState(() => _isLoadingMore = false);
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
                  // setState 대신 notifier만 업데이트 → 전체 리빌드 없음 → 키보드 유지
                  _partnerTypingNotifier.value = data['typing'] == true;
                  _partnerTypingTimer?.cancel();
                  if (data['typing'] == true) {
                    _partnerTypingTimer = Timer(const Duration(seconds: 3), () {
                      _partnerTypingNotifier.value = false;
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

                // [FIX #6] 중복 메시지 방지: 재연결 시 소켓 중복 수신 차단
                final newId = newChat['id'];
                if (newId != null && _chats.any((c) => c['id'] == newId)) return;

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
    if (stompClient == null || !stompClient!.connected) return;
    stompClient!.send(
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

    // [FIX #1] stompClient null 안전성 체크
    if (stompClient == null || !stompClient!.connected) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('서버 연결 중입니다. 잠시 후 다시 시도해주세요.')),
        );
      }
      return;
    }
    stompClient!.send(
      destination: '/pub/chat', // Controller의 @MessageMapping 주소
      body: jsonEncode(payload),
    );

    _controller.clear(); // 입력창 비우기
    _sendTypingEvent(false); // 타이핑 상태 해제
    _typingTimer?.cancel();
    _cancelReply();       // 답장 상태 초기화
    _focusNode.requestFocus(); // 전송 후 포커스 유지
  }

  void _showImageSourceSheet() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library, color: Color(0xFF8B7E74)),
              title: const Text('갤러리 (여러 장 선택 가능)'),
              onTap: () {
                Navigator.pop(context);
                _pickAndUploadMultipleImages();
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt, color: Color(0xFF8B7E74)),
              title: const Text('카메라'),
              onTap: () {
                Navigator.pop(context);
                _pickAndUploadImage(ImageSource.camera);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickAndUploadMultipleImages() async {
    final ImagePicker picker = ImagePicker();
    final List<XFile> images = await picker.pickMultiImage(imageQuality: 80, maxWidth: 1200);
    if (images.isEmpty) return;

    setState(() {
      _isUploadingImage = true;
      _uploadProgress = '0/${images.length}';
    });
    int successCount = 0;
    try {
      for (int i = 0; i < images.length; i++) {
        final image = images[i];
        setState(() => _uploadProgress = '${i + 1}/${images.length}');
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
          successCount++;
        } else {
          print("❌ 이미지 업로드 실패: ${response.statusCode}");
        }
      }
    } catch (e) {
      print("❌ 이미지 업로드 에러: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('사진 전송 중 오류가 발생했습니다.')),
        );
      }
    } finally {
      setState(() {
        _isUploadingImage = false;
        _uploadProgress = '';
      });
    }
  }

  // --- [공유 인텐트 처리] ---
  void _handlePendingShare() {
    final share = ShareIntentService().consumePending();
    if (share == null) return;

    if (share.type == 'text' && share.text != null) {
      _controller.text = share.text!;
      _controller.selection = TextSelection.collapsed(offset: share.text!.length);
      _focusNode.requestFocus();
    } else if (share.type == 'images' && share.imagePaths != null) {
      _uploadSharedImages(share.imagePaths!);
    }
  }

  Future<void> _uploadSharedImages(List<String> paths) async {
    setState(() => _isUploadingImage = true);
    try {
      for (final path in paths) {
        final bytes = await File(path).readAsBytes();
        final filename = path.split('/').last;

        var request = http.MultipartRequest(
          'POST',
          Uri.parse('${ApiConfig.baseUrl}/api/chat/image'),
        );
        request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));

        final response = await ApiClient.sendMultipart(request);
        if (response.statusCode == 200) {
          final data = jsonDecode(await response.stream.bytesToString());
          _sendImageMessage(data['imageUrl']);
        } else {
          throw Exception('업로드 실패: ${response.statusCode}');
        }
      }
    } catch (e) {
      debugPrint("공유 이미지 업로드 실패: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('공유 이미지 전송 실패!')),
        );
      }
    } finally {
      if (mounted) setState(() => _isUploadingImage = false);
    }
  }

  Future<void> _pickAndUploadImage(ImageSource source) async {
    final ImagePicker picker = ImagePicker();
    final XFile? image = await picker.pickImage(source: source, imageQuality: 80, maxWidth: 1200);
    if (image == null) return;

    setState(() {
      _isUploadingImage = true;
      _uploadProgress = '';
    });
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
      setState(() {
        _isUploadingImage = false;
        _uploadProgress = '';
      });
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

  Future<void> _pickAndUploadFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'txt', 'csv', 'zip'],
    );
    if (result == null || result.files.isEmpty) return;
    final picked = result.files.first;
    final bytes = picked.bytes ?? await File(picked.path!).readAsBytes();

    setState(() {
      _isUploadingImage = true;
      _uploadProgress = '';
    });
    try {
      var request = http.MultipartRequest('POST', Uri.parse('${ApiConfig.baseUrl}/api/chat/file'));
      request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: picked.name));
      var response = await ApiClient.sendMultipart(request);
      if (response.statusCode == 200) {
        final data = jsonDecode(await response.stream.bytesToString());
        _sendFileMessage(data['fileUrl'], data['originalName']);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('파일 전송 실패!')));
      }
    } finally {
      setState(() {
        _isUploadingImage = false;
        _uploadProgress = '';
      });
    }
  }

  void _sendFileMessage(String fileUrl, String fileName) {
    stompClient?.send(
      destination: '/pub/chat',
      body: jsonEncode({'message': 'FILE:$fileUrl|||$fileName', 'writerUid': widget.uid}),
    );
  }

  // --- 메시지 롱프레스 옵션 ---
  void _showMessageOptions(dynamic chat) {
    final isMe = chat['writerUid'] == widget.uid;
    final msg = (chat['message'] as String?) ?? '';
    final isImage = msg.startsWith('IMAGE:');
    final isFile = msg.startsWith('FILE:');
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
            if (!isImage && !isFile)
              ListTile(
                leading: const Icon(Icons.copy, color: Color(0xFF8B7E74)),
                title: const Text("복사"),
                onTap: () {
                  Navigator.pop(context);
                  Clipboard.setData(ClipboardData(text: msg));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('복사됐어'), duration: Duration(seconds: 1)),
                  );
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

  // URL 파싱 후 클릭 가능한 위젯으로 렌더링
  Widget _buildMessageContent(String text, bool isMe) {
    final urlRegex = RegExp(
      r'(https?://[^\s]+)',
      caseSensitive: false,
    );
    final matches = urlRegex.allMatches(text);
    if (matches.isEmpty) {
      return Text(
        text,
        style: TextStyle(fontSize: 16, color: isMe ? Colors.white : Theme.of(context).colorScheme.onSurface),
      );
    }

    final spans = <InlineSpan>[];
    int last = 0;
    for (final m in matches) {
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      final url = m.group(0)!;
      spans.add(TextSpan(
        text: url,
        style: TextStyle(
          color: isMe ? Colors.white : const Color(0xFF8B7E74),
          decoration: TextDecoration.underline,
          decorationColor: isMe ? Colors.white : const Color(0xFF8B7E74),
        ),
        recognizer: TapGestureRecognizer()
          ..onTap = () async {
            final uri = Uri.tryParse(url);
            if (uri != null) {
              await launchUrl(uri, mode: LaunchMode.externalApplication);
            }
          },
      ));
      last = m.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last)));
    }

    return RichText(
      text: TextSpan(
        style: TextStyle(fontSize: 16, color: isMe ? Colors.white : Theme.of(context).colorScheme.onSurface),
        children: spans,
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
    // 즉시 로컬 상태 업데이트 (optimistic update)
    setState(() {
      _chats.removeWhere((c) => c['id'] == chatId);
    });
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
    if (message.startsWith('FILE:')) return '파일';
    if (message.length > 30) return '${message.substring(0, 30)}...';
    return message;
  }

  // --- 채팅 검색 메뉴 ---
  void _openWordSearch() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatSearchListPage(uid: widget.uid),
      ),
    ).then((result) {
      if (result != null && result is int) {
        _loadAndScrollToMessage(result);
      }
    });
  }

  // 검색 결과 클릭 시 해당 메시지 로드 후 스크롤
  Future<void> _loadAndScrollToMessage(int targetId) async {
    try {
      final response = await ApiClient.get(
        Uri.parse('$httpUrl?before=${targetId + 1}&size=50'),
      );
      if (response.statusCode == 200) {
        final chats = jsonDecode(utf8.decode(response.bodyBytes)) as List;
        final partnerUids = chats
            .map((c) => c['writerUid']?.toString() ?? '')
            .where((uid) => uid.isNotEmpty && uid != widget.uid && !_nicknameCache.containsKey(uid))
            .toSet();
        if (partnerUids.isNotEmpty) {
          await Future.wait(partnerUids.map((uid) => _getNickname(uid)));
        }
        setState(() {
          _chats = chats;
          _hasMore = chats.length >= 50;
          _highlightedMessageId = targetId;
        });
        _scrollToBottom();
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) setState(() => _highlightedMessageId = null);
        });
      }
    } catch (e) {
      debugPrint('메시지 이동 실패: $e');
    }
  }

  void _openCalendarSearch() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChatCalendarPage(uid: widget.uid),
      ),
    );
  }

  Widget _searchMenuButton(IconData icon, String label, VoidCallback onTap) {
    return InkWell(
      onTap: () {
        setState(() => _showChatSearchMenu = false);
        onTap();
      },
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: const Color(0xFF8B7E74), size: 24),
            const SizedBox(height: 4),
            Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF8B7E74))),
          ],
        ),
      ),
    );
  }

  // 스크롤 맨 아래로 내리는 함수
  // (reverse: true 이므로 pixels == 0 이 맨 아래 = 최신 메시지)
  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    });
  }

  // --- AI 채팅 검색 ---
  void _showAiSearch() {
    final TextEditingController queryController = TextEditingController();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          left: 20, right: 20, top: 20,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.auto_awesome, color: Color(0xFF8B7E74), size: 20),
                SizedBox(width: 8),
                Text('AI 채팅 검색', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ],
            ),
            const SizedBox(height: 12),
            TextField(
              controller: queryController,
              autofocus: true,
              decoration: InputDecoration(
                hintText: '예) 최근에 놀러가고 싶다고 했던 곳들',
                hintStyle: TextStyle(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.4), fontSize: 14),
                filled: true,
                fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              ),
              onSubmitted: (_) {
                if (queryController.text.isNotEmpty) {
                  Navigator.pop(context);
                  _callAiSearch(queryController.text);
                }
              },
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF8B7E74),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                onPressed: () {
                  if (queryController.text.isNotEmpty) {
                    Navigator.pop(context);
                    _callAiSearch(queryController.text);
                  }
                },
                child: const Text('검색'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _callAiSearch(String query) async {
    // 로딩 다이얼로그
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(color: Color(0xFF8B7E74)),
            SizedBox(width: 16),
            Text('AI가 채팅을 분석 중...'),
          ],
        ),
      ),
    );

    try {
      final response = await ApiClient.get(
        Uri.parse('${ApiConfig.baseUrl}/api/chat/ai-search?q=${Uri.encodeComponent(query)}'),
      );
      Navigator.pop(context); // 로딩 닫기

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes));
        final result = data['result'] as String;
        _showAiResult(query, result);
      } else {
        _showAiError();
      }
    } catch (e) {
      Navigator.pop(context);
      _showAiError();
    }
  }

  void _showAiResult(String query, String result) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.auto_awesome, color: Color(0xFF8B7E74), size: 18),
            SizedBox(width: 8),
            Text('AI 검색 결과', style: TextStyle(fontSize: 16)),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xFFF5F0EB),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(query, style: const TextStyle(fontSize: 13, color: Color(0xFF8B7E74))),
              ),
              const SizedBox(height: 12),
              Text(result, style: const TextStyle(fontSize: 14, height: 1.5)),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: '복사',
            icon: const Icon(Icons.copy, size: 20, color: Color(0xFF8B7E74)),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: result));
              Navigator.pop(context);
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('결과가 클립보드에 복사되었습니다.')),
              );
            },
          ),
          IconButton(
            tooltip: '채팅으로 전송',
            icon: const Icon(Icons.send, size: 20, color: Color(0xFF8B7E74)),
            onPressed: () {
              Navigator.pop(context);
              _controller.text = result;
              _controller.selection = TextSelection.collapsed(offset: result.length);
              _focusNode.requestFocus();
            },
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('닫기', style: TextStyle(color: Color(0xFF8B7E74))),
          ),
        ],
      ),
    );
  }

  void _showAiError() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('AI 검색에 실패했습니다. 잠시 후 다시 시도해주세요.')),
    );
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
    return PopScope(
      canPop: !_showChatSearchMenu,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_showChatSearchMenu) {
          setState(() {
            _showChatSearchMenu = false;
          });
        }
      },
      child: Column(
        children: [
          // 채팅 검색 메뉴 툴바 (롱프레스 시 표시)
          if (_showChatSearchMenu)
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                border: Border(
                  bottom: BorderSide(color: Colors.grey.withOpacity(0.2)),
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _searchMenuButton(Icons.search, '검색', _openWordSearch),
                  _searchMenuButton(Icons.calendar_month, '날짜', _openCalendarSearch),
                  _searchMenuButton(Icons.auto_awesome, 'AI 검색', _showAiSearch),
                  _searchMenuButton(Icons.photo_library_outlined, '사진 모음', () {
                    setState(() => _showChatSearchMenu = false);
                    Navigator.push(context, MaterialPageRoute(builder: (_) => const ChatMediaPage()));
                  }),
                  IconButton(
                    icon: const Icon(Icons.close, color: Color(0xFF8B7E74)),
                    onPressed: () => setState(() => _showChatSearchMenu = false),
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
            ),

          // 채팅 리스트 영역
          Expanded(
            child: GestureDetector(
              onLongPress: () => setState(() => _showChatSearchMenu = true),
              child: ListView.builder(
                controller: _scrollController,
                reverse: true, // 최신 메시지(index 0)가 맨 아래에 표시됨
                padding: const EdgeInsets.fromLTRB(8, 16, 8, 4),
                itemCount: _chats.length + (_isLoadingMore ? 1 : 0),
                itemBuilder: (context, index) {
                  // 맨 위 로딩 인디케이터 (reverse이므로 가장 높은 index = 화면 맨 위)
                  if (_isLoadingMore && index == _chats.length) {
                    return const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12),
                      child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF8B7E74))),
                    );
                  }
                  // reverse: true → index 0 = 최신(_chats.last), index n = 오래된(_chats.first)
                  final chatIndex = _chats.length - 1 - index;
                  final chat = _chats[chatIndex];
                  final message = chat['message'] as String;
                  final String? createdAt = chat['created_at'] ?? chat['createdAt'];
                  final isMe = chat['writerUid'] == widget.uid;

                  // ★ 날짜 구분선 표시 여부 판단
                  bool showDateDivider = false;
                  if (chatIndex == 0) {
                    showDateDivider = true;
                  } else {
                    final prevChat = _chats[chatIndex - 1];
                    final prevDate = prevChat['created_at'] ?? prevChat['createdAt'];
                    showDateDivider = !_isSameDate(createdAt, prevDate);
                  }

                  // 메시지 내용 처리 (사진 vs 파일 vs 텍스트)
                  final isImage = message.startsWith('IMAGE:');
                  final isFile = message.startsWith('FILE:');
                  final String content = isImage
                      ? message.replaceFirst('IMAGE:', '')
                      : isFile
                          ? message.replaceFirst('FILE:', '')
                          : message;

                  // 파일인 경우 url과 파일명 분리
                  String fileUrl = '';
                  String fileName = '';
                  if (isFile) {
                    final parts = content.split('|||');
                    fileUrl = parts[0];
                    fileName = parts.length > 1 ? parts[1] : '파일';
                  }

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
                      if (_highlightedMessageId != null && chat['id'] == _highlightedMessageId)
                        Container(
                          margin: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                          decoration: BoxDecoration(
                            color: const Color(0xFF8B7E74).withOpacity(0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text('검색된 메시지', style: TextStyle(fontSize: 11, color: Color(0xFF8B7E74))),
                        ),
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
                            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
                            child: Row(
                              mainAxisAlignment: isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                if (!isMe)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 8.0),
                                    child: GestureDetector(
                                      onTap: () {
                                        final imageUrl = _profileImageCache[chat['writerUid']?.toString()];
                                        if (imageUrl != null) {
                                          showDialog(
                                            context: context,
                                            builder: (_) => Dialog(
                                              backgroundColor: Colors.black,
                                              insetPadding: EdgeInsets.zero,
                                              child: Stack(
                                                children: [
                                                  SizedBox.expand(
                                                    child: InteractiveViewer(
                                                      child: Center(
                                                        child: CachedNetworkImage(imageUrl: imageUrl),
                                                      ),
                                                    ),
                                                  ),
                                                  Positioned(
                                                    top: 40,
                                                    right: 16,
                                                    child: IconButton(
                                                      icon: const Icon(Icons.close, color: Colors.white, size: 28),
                                                      onPressed: () => Navigator.of(context).pop(),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          );
                                        }
                                      },
                                      child: CircleAvatar(
                                        backgroundColor: Theme.of(context).colorScheme.surface,
                                        backgroundImage: _profileImageCache[chat['writerUid']?.toString()] != null
                                            ? CachedNetworkImageProvider(
                                                _profileImageCache[chat['writerUid']!.toString()]!,
                                              )
                                            : null,
                                        child: _profileImageCache[chat['writerUid']?.toString()] == null
                                            ? Icon(Icons.person, color: Theme.of(context).colorScheme.onSurfaceVariant)
                                            : null,
                                      ),
                                    ),
                                  ),
                                // 내 메시지: 시간 왼쪽 + 말풍선 오른쪽
                                if (isMe)
                                  Padding(
                                    padding: const EdgeInsets.only(right: 4, top: 4),
                                    child: Align(
                                      alignment: Alignment.bottomRight,
                                      child: Text(
                                        _formatTime(createdAt),
                                        style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.onSurfaceVariant),
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
                                            style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                                          ),
                                        ),

                                      // 답장 인용 표시
                                      if (hasReply && replyToMessage != null)
                                        Container(
                                          margin: const EdgeInsets.only(bottom: 4),
                                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                                          decoration: BoxDecoration(
                                            color: Theme.of(context).colorScheme.surfaceContainerHighest,
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
                                                style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
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
                                              height: 200,
                                              fit: BoxFit.cover,
                                              memCacheWidth: 300,
                                              placeholder: (context, url) => Container(
                                                  width: 200, height: 200, color: Theme.of(context).colorScheme.surfaceContainerHighest),
                                              errorWidget: (context, url, error) => const Icon(Icons.error),
                                            ),
                                          ),
                                        )
                                      else if (isFile)
                                        GestureDetector(
                                          onTap: () => launchUrl(Uri.parse(fileUrl), mode: LaunchMode.externalApplication),
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                            decoration: BoxDecoration(
                                              color: isMe ? const Color(0xFF8B7E74) : Theme.of(context).colorScheme.surface,
                                              borderRadius: BorderRadius.circular(15),
                                              boxShadow: [
                                                BoxShadow(
                                                    color: Colors.black.withOpacity(0.05),
                                                    blurRadius: 1,
                                                    offset: const Offset(1, 1))
                                              ],
                                            ),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Icon(Icons.insert_drive_file,
                                                    size: 28,
                                                    color: isMe ? Colors.white : Theme.of(context).colorScheme.onSurface),
                                                const SizedBox(width: 8),
                                                Flexible(
                                                  child: Text(
                                                    fileName,
                                                    style: TextStyle(
                                                        fontSize: 13,
                                                        color: isMe ? Colors.white : Theme.of(context).colorScheme.onSurface),
                                                  ),
                                                ),
                                                const SizedBox(width: 6),
                                                Icon(Icons.download,
                                                    size: 18,
                                                    color: isMe ? Colors.white70 : Theme.of(context).colorScheme.onSurfaceVariant),
                                              ],
                                            ),
                                          ),
                                        )
                                      else
                                        Container(
                                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                                          decoration: BoxDecoration(
                                            color: isMe ? const Color(0xFF8B7E74) : Theme.of(context).colorScheme.surface,
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
                                                  offset: const Offset(1, 1))
                                            ],
                                          ),
                                          child: _buildMessageContent(content, isMe),
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
                                        style: TextStyle(fontSize: 10, color: Theme.of(context).colorScheme.onSurfaceVariant),
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

          // 상대방 입력 중 표시 (ValueListenableBuilder: 전체 리빌드 없이 이 위젯만 업데이트)
          ValueListenableBuilder<bool>(
            valueListenable: _partnerTypingNotifier,
            builder: (context, isTyping, _) {
              if (!isTyping) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text("입력 중...", style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant)),
                ),
              );
            },
          ),

          // 사진 업로드 중 표시
          if (_isUploadingImage)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFF8B7E74))),
                  const SizedBox(width: 10),
                  Text(
                    _uploadProgress.isEmpty ? "전송 중..." : "전송 중... ($_uploadProgress)",
                    style: const TextStyle(fontSize: 13, color: Color(0xFF8B7E74)),
                  ),
                ],
              ),
            ),

          // 답장 미리보기 바
          if (_replyTarget != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
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
                    child: Icon(Icons.close, size: 20, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),

          // 입력창 영역
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(Icons.add_photo_alternate_rounded, color: Theme.of(context).colorScheme.onSurfaceVariant, size: 22),
                  onPressed: _showImageSourceSheet,
                  padding: const EdgeInsets.all(2),
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 2),
                IconButton(
                  icon: Icon(Icons.attach_file, color: Theme.of(context).colorScheme.onSurfaceVariant, size: 22),
                  onPressed: _pickAndUploadFile,
                  padding: const EdgeInsets.all(2),
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    decoration: InputDecoration(
                      hintText: "",
                      filled: true,
                      fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(30),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    ),
                    onChanged: _onTypingChanged,
                    onSubmitted: (_) => _sendMessage(), // 엔터 치면 전송
                  ),
                ),
                const SizedBox(width: 8),
                ScaleTransition(
                  scale: _sendScaleAnim,
                  child: CircleAvatar(
                    backgroundColor: const Color(0xFF8B7E74),
                    radius: 20,
                    child: IconButton(
                      icon: const Icon(Icons.send, color: Colors.white, size: 18),
                      onPressed: () {
                        _sendAnimController.forward(from: 0.0);
                        _sendMessage();
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

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
      setState(() {
        _results = [];
      });
      return;
    }

    setState(() => _isLoading = true);

    try {
      final response = await ApiClient.get(
        Uri.parse('${ApiConfig.baseUrl}/api/chats/search?q=${Uri.encodeComponent(query.trim())}'),
      );
      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(utf8.decode(response.bodyBytes));
        setState(() {
          _results = data;
        });
      }
    } catch (e) {
      debugPrint('Search error: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  String _formatDateTime(String? dateTime) {
    if (dateTime == null) return '';
    try {
      final dt = DateTime.parse(dateTime);
      final hour = dt.hour;
      final minute = dt.minute.toString().padLeft(2, '0');
      String timeStr;
      if (hour == 0) timeStr = '오전 12:$minute';
      else if (hour < 12) timeStr = '오전 $hour:$minute';
      else if (hour == 12) timeStr = '오후 12:$minute';
      else timeStr = '오후 ${hour - 12}:$minute';
      return '${dt.month}/${dt.day} $timeStr';
    } catch (_) {
      return '';
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
                prefixIcon: const Icon(Icons.search, color: Color(0xFF8B7E74)),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.send, color: Color(0xFF8B7E74)),
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
                if (val.isEmpty) {
                  setState(() {
                    _results = [];
                  });
                }
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
                  style: const TextStyle(fontSize: 12, color: Color(0xFF8B7E74)),
                ),
              ),
            ),
          Expanded(
            child: _controller.text.isNotEmpty && _results.isEmpty
                ? const Center(
                    child: Text('검색 결과가 없어', style: TextStyle(color: Colors.grey)),
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
                          backgroundColor: const Color(0xFF8B7E74).withOpacity(0.15),
                          child: Icon(
                            isMe ? Icons.person : Icons.person_outline,
                            color: const Color(0xFF8B7E74),
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
                          _formatDateTime(createdAt),
                          style: const TextStyle(fontSize: 11, color: Colors.grey),
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
        Uri.parse('${ApiConfig.baseUrl}/api/chats/calendar'),
      );
      if (response.statusCode == 200) {
        final Map<String, dynamic> data = json.decode(utf8.decode(response.bodyBytes));
        setState(() {
          _countByDate = data.map((key, value) => MapEntry(key, (value as num).toInt()));
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
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF8B7E74)))
          : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragEnd: (details) {
                if (details.primaryVelocity! < -500) {
                  // 다음 달로 이동 (오른쪽 -> 왼쪽 스와이프)
                  setState(() {
                    _focusedMonth = DateTime(_focusedMonth.year, _focusedMonth.month + 1);
                  });
                } else if (details.primaryVelocity! > 500) {
                  // 이전 달로 이동 (왼쪽 -> 오른쪽 스와이프)
                  setState(() {
                    _focusedMonth = DateTime(_focusedMonth.year, _focusedMonth.month - 1);
                  });
                }
              },
              child: Column(
                children: [
                  const SizedBox(height: 8),
                  // 월 이동
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.chevron_left, color: Color(0xFF8B7E74)),
                        onPressed: () => setState(() {
                          _focusedMonth = DateTime(_focusedMonth.year, _focusedMonth.month - 1);
                        }),
                      ),
                      Text(
                        '${_focusedMonth.year}년 ${_focusedMonth.month}월',
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      IconButton(
                        icon: const Icon(Icons.chevron_right, color: Color(0xFF8B7E74)),
                        onPressed: () => setState(() {
                          _focusedMonth = DateTime(_focusedMonth.year, _focusedMonth.month + 1);
                        }),
                      ),
                    ],
                  ),
                  // 요일 헤더
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      children: [
                        Expanded(child: Center(child: Text('일', style: TextStyle(fontSize: 12, color: Colors.red, fontWeight: FontWeight.bold)))),
                        Expanded(child: Center(child: Text('월', style: TextStyle(fontSize: 12)))),
                        Expanded(child: Center(child: Text('화', style: TextStyle(fontSize: 12)))),
                        Expanded(child: Center(child: Text('수', style: TextStyle(fontSize: 12)))),
                        Expanded(child: Center(child: Text('목', style: TextStyle(fontSize: 12)))),
                        Expanded(child: Center(child: Text('금', style: TextStyle(fontSize: 12)))),
                        Expanded(child: Center(child: Text('토', style: TextStyle(fontSize: 12, color: Colors.blue, fontWeight: FontWeight.bold)))),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  // 달력 그리드
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: _buildCalendarGrid(),
                  ),
                ],
              ),
            ),    );
  }

  Widget _buildCalendarGrid() {
    final firstDay = DateTime(_focusedMonth.year, _focusedMonth.month, 1);
    final lastDay = DateTime(_focusedMonth.year, _focusedMonth.month + 1, 0);
    final startWeekday = firstDay.weekday % 7; // 0=일요일
    final today = DateTime.now();

    final cells = <Widget>[];

    // 첫 날 이전 빈 칸
    for (int i = 0; i < startWeekday; i++) {
      cells.add(const SizedBox());
    }

    for (int day = 1; day <= lastDay.day; day++) {
      final date = DateTime(_focusedMonth.year, _focusedMonth.month, day);
      final dateStr = '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
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
                      builder: (_) => ChatDayListPage(
                        date: dateStr,
                        uid: widget.uid,
                      ),
                    ),
                  )
              : null,
          child: Container(
            height: 60,
            decoration: BoxDecoration(
              border: isToday
                  ? Border.all(color: const Color(0xFF8B7E74), width: 1.5)
                  : null,
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
                    color: isSunday
                        ? Colors.red
                        : isSaturday
                            ? Colors.blue
                            : null,
                  ),
                ),
                if (count > 0) ...[
                  const SizedBox(height: 2),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: const Color(0xFF8B7E74),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '$count',
                      style: const TextStyle(fontSize: 10, color: Colors.white),
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
        Uri.parse('${ApiConfig.baseUrl}/api/chats/by-date?date=${widget.date}'),
      );
      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(utf8.decode(response.bodyBytes));
        setState(() {
          _chats = data;
        });
      }
    } catch (e) {
      debugPrint('Day chats error: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

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
    } catch (_) {
      return '';
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
          ? const Center(child: CircularProgressIndicator(color: Color(0xFF8B7E74)))
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
                        const Padding(
                          padding: EdgeInsets.only(right: 8),
                          child: CircleAvatar(
                            radius: 16,
                            backgroundColor: Color(0xFFEEEEEE),
                            child: Icon(Icons.person, size: 16, color: Color(0xFF8B7E74)),
                          ),
                        ),
                      if (isMe)
                        Padding(
                          padding: const EdgeInsets.only(right: 4, bottom: 2),
                          child: Text(
                            _formatTime(createdAt),
                            style: const TextStyle(fontSize: 10, color: Colors.grey),
                          ),
                        ),
                      ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                          decoration: BoxDecoration(
                            color: isMe ? const Color(0xFF8B7E74) : Theme.of(context).colorScheme.surface,
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
                                    color: isMe ? Colors.white : Theme.of(context).colorScheme.onSurface,
                                  ),
                                ),
                        ),
                      ),
                      if (!isMe)
                        Padding(
                          padding: const EdgeInsets.only(left: 4, bottom: 2),
                          child: Text(
                            _formatTime(createdAt),
                            style: const TextStyle(fontSize: 10, color: Colors.grey),
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




