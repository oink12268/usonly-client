import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:stomp_dart_client/stomp_dart_client.dart'; // 소켓 라이브러리
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'api_client.dart';
import 'api_endpoints.dart';
import 'fcm_service.dart';
import 'share_intent_service.dart';
import 'chat_media_page.dart';
import 'chat_search_page.dart';
import 'utils/date_formatter.dart';
import 'widgets/chat_bubble.dart';
import 'widgets/chat_search_toolbar.dart';
import 'widgets/chat_typing_indicator.dart';
import 'widgets/chat_reply_preview.dart';
import 'widgets/chat_input_bar.dart';

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
  bool _isConnecting = false;
  Timer? _reconnectTimer;
  // 연결 중 전송 시도한 메시지 큐 (연결 완료 시 일괄 전송)
  final List<Map<String, dynamic>> _pendingMessages = [];

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
  bool _hasNewer = false;   // 답장 이동 후 최신 방향으로 더 불러올 메시지 존재 여부
  bool _isLoadingNewer = false;

  // 채팅 검색 메뉴 표시 상태
  bool _showChatSearchMenu = false;

  // 검색 결과에서 이동한 메시지 하이라이트
  int? _highlightedMessageId;
  // 답장 이동 시 해당 아이템을 화면 중앙으로 스크롤하기 위한 GlobalKey
  final GlobalKey _targetMessageKey = GlobalKey();

  // 전송 버튼 애니메이션
  late AnimationController _sendAnimController;
  late Animation<double> _sendScaleAnim;

  // uid → 닉네임 / 프로필 이미지 캐시
  final Map<String, String> _nicknameCache = {};
  final Map<String, String?> _profileImageCache = {};

  final String socketUrl = ApiEndpoints.wsUrl;
  final String httpUrl = ApiEndpoints.chats;

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
      _reconnectTimer?.cancel();
      stompClient?.deactivate();
      stompClient = null;
      _isConnecting = false;
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
    _reconnectTimer?.cancel();
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
        Uri.parse(ApiEndpoints.memberInfo(uid)),
      );
      if (response.statusCode == 200) {
        final data = ApiClient.decodeBody(response) as Map<String, dynamic>;
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
    // 맨 위 → 오래된 메시지 로드 (reverse: true 이므로 maxScrollExtent = 화면 맨 위)
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent - 50 &&
        _hasMore &&
        !_isLoadingMore) {
      _loadMore();
    }
    // 맨 아래 → 최신 메시지 로드 (답장 이동 후 _hasNewer = true인 경우)
    if (_scrollController.hasClients &&
        _scrollController.position.pixels <= 50 &&
        _hasNewer &&
        !_isLoadingNewer) {
      _loadNewer();
    }
  }

  // --- [1] 지난 대화 로딩 (HTTP GET, 최신 50개) ---
  Future<void> _fetchHistory() async {
    try {
      final response = await ApiClient.get(Uri.parse('$httpUrl?size=50'));
      if (response.statusCode == 200) {
        final chats = ApiClient.decodeBody(response) as List;
        setState(() {
          _chats = chats;
          _hasMore = chats.length >= 50;
          _hasNewer = false;
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
      debugPrint("❌ 지난 대화 로딩 실패: $e");
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
        final older = ApiClient.decodeBody(response) as List;

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
      debugPrint("❌ 이전 메시지 로딩 실패: $e");
    } finally {
      setState(() => _isLoadingMore = false);
    }
  }

  // 최신 방향 메시지 추가 로드 (답장 이동 후 아래로 스크롤할 때)
  Future<void> _loadNewer() async {
    if (_chats.isEmpty) return;
    final lastId = _chats.last['id'];
    if (lastId == null) return;

    setState(() => _isLoadingNewer = true);
    try {
      final response = await ApiClient.get(
        Uri.parse('$httpUrl?after=$lastId&size=50'),
      );
      if (response.statusCode == 200) {
        final newer = ApiClient.decodeBody(response) as List;

        final partnerUids = newer
            .map((c) => c['writerUid']?.toString() ?? '')
            .where((uid) => uid.isNotEmpty && uid != widget.uid && !_nicknameCache.containsKey(uid))
            .toSet();
        if (partnerUids.isNotEmpty) {
          await Future.wait(partnerUids.map((uid) => _getNickname(uid)));
        }

        setState(() {
          // 중복 방지 (웹소켓으로 이미 받은 메시지 제외)
          final existingIds = _chats.map((c) => c['id']).toSet();
          final unique = newer.where((c) => !existingIds.contains(c['id'])).toList();
          _chats = [..._chats, ...unique];
          _hasNewer = newer.length >= 50;
        });
      }
    } catch (e) {
      debugPrint('최신 메시지 로딩 실패: $e');
    } finally {
      setState(() => _isLoadingNewer = false);
    }
  }

  // --- [2] 소켓 연결 및 구독 (WebSocket) ---
  void _connectSocket() async {
    if (_isConnecting) return;
    _isConnecting = true;
    final connectHeaders = await ApiClient.stompHeaders();
    if (!mounted) { _isConnecting = false; return; }
    stompClient = StompClient(
      config: StompConfig(
        url: socketUrl,
        stompConnectHeaders: connectHeaders,
        onConnect: (StompFrame frame) {
          debugPrint("✅ 소켓 연결 성공!");
          _isConnecting = false;
          // 연결 대기 중 쌓인 메시지 전송
          if (_pendingMessages.isNotEmpty) {
            final toSend = List<Map<String, dynamic>>.from(_pendingMessages);
            _pendingMessages.clear();
            for (final payload in toSend) {
              stompClient!.send(
                destination: '/pub/chat',
                body: jsonEncode(payload),
              );
            }
          }

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
        onWebSocketError: (dynamic error) {
          debugPrint("🚨 소켓 에러: $error");
          _isConnecting = false;
          _scheduleReconnect();
        },
        onDisconnect: (StompFrame frame) {
          debugPrint("🔌 소켓 연결 끊김, 재연결 예약...");
          _isConnecting = false;
          _scheduleReconnect();
        },
      ),
    );

    // 연결 활성화
    stompClient!.activate();
  }

  // --- 소켓 재연결 ---
  void _scheduleReconnect() {
    if (!mounted) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      if (stompClient == null || !stompClient!.connected) {
        debugPrint("🔄 소켓 재연결 시도...");
        stompClient?.deactivate();
        stompClient = null;
        _connectSocket();
      }
    });
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

    // 연결 안 됐을 때: 큐에 넣고 재연결 시도 (전송 취소하지 않음)
    if (stompClient == null || !stompClient!.connected) {
      _pendingMessages.add(Map<String, dynamic>.from(payload));
      _scheduleReconnect();
      _controller.clear();
      _cancelReply();
      _focusNode.requestFocus();
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

  void _showAttachmentSheet() {
    showModalBottomSheet(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('갤러리'),
              onTap: () {
                Navigator.pop(context);
                _pickAndUploadMultipleImages();
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt),
              title: const Text('카메라'),
              onTap: () {
                Navigator.pop(context);
                _pickAndUploadImage(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(Icons.attach_file),
              title: const Text('파일 첨부'),
              onTap: () {
                Navigator.pop(context);
                _pickAndUploadFile();
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
          Uri.parse(ApiEndpoints.chatImageUpload),
        );
        final bytes = await image.readAsBytes();
        request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: image.name));

        var response = await ApiClient.sendMultipart(request);
        if (response.statusCode == 200) {
          final data = await ApiClient.decodeStreamedBody(response);
          _sendImageMessage(data['imageUrl']);
          successCount++;
        } else {
          debugPrint("❌ 이미지 업로드 실패: ${response.statusCode}");
        }
      }
    } catch (e) {
      debugPrint("❌ 이미지 업로드 에러: $e");
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
          Uri.parse(ApiEndpoints.chatImageUpload),
        );
        request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));

        final response = await ApiClient.sendMultipart(request);
        if (response.statusCode == 200) {
          final data = await ApiClient.decodeStreamedBody(response);
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
        Uri.parse(ApiEndpoints.chatImageUpload),
      );
      final bytes = await image.readAsBytes();
      request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: image.name));

      var response = await ApiClient.sendMultipart(request);
      if (response.statusCode == 200) {
        final data = await ApiClient.decodeStreamedBody(response);
        _sendImageMessage(data['imageUrl']);
      } else {
        throw Exception('업로드 실패: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint("❌ 이미지 업로드 실패: $e");
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
      var request = http.MultipartRequest('POST', Uri.parse(ApiEndpoints.chatFileUpload));
      request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: picked.name));
      var response = await ApiClient.sendMultipart(request);
      if (response.statusCode == 200) {
        final data = await ApiClient.decodeStreamedBody(response);
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
              leading: const Icon(Icons.reply),
              title: const Text("답장"),
              onTap: () {
                Navigator.pop(context);
                _setReplyTarget(chat);
              },
            ),
            if (!isImage && !isFile)
              ListTile(
                leading: const Icon(Icons.copy),
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
        Uri.parse(ApiEndpoints.chatDelete(chatId)),
      );
      if (response.statusCode != 200) {
        debugPrint("메시지 삭제 실패: ${response.statusCode}");
      }
    } catch (e) {
      debugPrint("메시지 삭제 에러: $e");
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
      // 이전 메시지(타겟 포함)와 이후 메시지를 동시에 로드
      final responses = await Future.wait([
        ApiClient.get(Uri.parse('$httpUrl?before=${targetId + 1}&size=50')),
        ApiClient.get(Uri.parse('$httpUrl?after=$targetId&size=50')),
      ]);

      if (responses[0].statusCode == 200) {
        final older = ApiClient.decodeBody(responses[0]) as List;
        final newer = responses[1].statusCode == 200
            ? ApiClient.decodeBody(responses[1]) as List
            : <dynamic>[];

        // 닉네임 일괄 조회
        final allChats = [...older, ...newer];
        final partnerUids = allChats
            .map((c) => c['writerUid']?.toString() ?? '')
            .where((uid) => uid.isNotEmpty && uid != widget.uid && !_nicknameCache.containsKey(uid))
            .toSet();
        if (partnerUids.isNotEmpty) {
          await Future.wait(partnerUids.map((uid) => _getNickname(uid)));
        }

        setState(() {
          _chats = [...older, ...newer];
          _hasMore = older.length >= 50;
          _hasNewer = newer.length >= 50;
          _highlightedMessageId = targetId;
        });

        // 타겟 메시지를 화면 중앙으로 스크롤
        WidgetsBinding.instance.addPostFrameCallback((_) {
          final ctx = _targetMessageKey.currentContext;
          if (ctx != null) {
            Scrollable.ensureVisible(
              ctx,
              alignment: 0.5,
              duration: const Duration(milliseconds: 300),
            );
          }
        });

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
                Icon(Icons.auto_awesome, size: 20),
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
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  foregroundColor: Theme.of(context).colorScheme.onPrimary,
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
      builder: (_) => AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(color: Theme.of(context).colorScheme.primary),
            SizedBox(width: 16),
            Text('AI가 채팅을 분석 중...'),
          ],
        ),
      ),
    );

    try {
      final response = await ApiClient.get(
        Uri.parse(ApiEndpoints.aiSearchQuery(query)),
      );
      Navigator.pop(context); // 로딩 닫기

      if (response.statusCode == 200) {
        final data = ApiClient.decodeBody(response) as Map<String, dynamic>;
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
        title: Row(
          children: [
            Icon(Icons.auto_awesome, color: Theme.of(context).colorScheme.onSurface, size: 18),
            const SizedBox(width: 8),
            const Text('AI 검색 결과', style: TextStyle(fontSize: 16)),
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
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(query, style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurface)),
              ),
              const SizedBox(height: 12),
              Text(result, style: const TextStyle(fontSize: 14, height: 1.5)),
            ],
          ),
        ),
        actions: [
          IconButton(
            tooltip: '복사',
            icon: const Icon(Icons.copy, size: 20),
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
            icon: const Icon(Icons.send, size: 20),
            onPressed: () {
              Navigator.pop(context);
              _controller.text = result;
              _controller.selection = TextSelection.collapsed(offset: result.length);
              _focusNode.requestFocus();
            },
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('닫기'),
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

  bool _isSameDate(String? date1, String? date2) =>
      DateFormatter.isSameDate(date1, date2);

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_showChatSearchMenu,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_showChatSearchMenu) setState(() => _showChatSearchMenu = false);
      },
      child: Column(
        children: [
          // 채팅 검색 메뉴 툴바
          if (_showChatSearchMenu)
            ChatSearchToolbar(
              onSearch: _openWordSearch,
              onCalendar: _openCalendarSearch,
              onAiSearch: _showAiSearch,
              onMediaGallery: () {
                setState(() => _showChatSearchMenu = false);
                Navigator.push(context, MaterialPageRoute(builder: (_) => const ChatMediaPage()));
              },
              onClose: () => setState(() => _showChatSearchMenu = false),
            ),

          // 채팅 리스트 영역
          Expanded(
            child: GestureDetector(
              onLongPress: () => setState(() => _showChatSearchMenu = true),
              child: ListView.builder(
                controller: _scrollController,
                reverse: true,
                padding: const EdgeInsets.fromLTRB(8, 16, 8, 4),
                itemCount: _chats.length + (_isLoadingMore ? 1 : 0),
                itemBuilder: (context, index) {
                  if (_isLoadingMore && index == _chats.length) {
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Center(child: CircularProgressIndicator(strokeWidth: 2, color: Theme.of(context).colorScheme.primary)),
                    );
                  }
                  final chatIndex = _chats.length - 1 - index;
                  final chat = _chats[chatIndex];
                  final String? createdAt = chat['created_at'] ?? chat['createdAt'];

                  bool showDateDivider = false;
                  if (chatIndex == 0) {
                    showDateDivider = true;
                  } else {
                    final prevChat = _chats[chatIndex - 1];
                    final prevDate = prevChat['created_at'] ?? prevChat['createdAt'];
                    showDateDivider = !_isSameDate(createdAt, prevDate);
                  }

                  final isTarget = _highlightedMessageId != null && chat['id'] == _highlightedMessageId;

                  return ChatBubble(
                    key: ValueKey('chat_${chat['id'] ?? index}'),
                    chat: Map<String, dynamic>.from(chat),
                    myUid: widget.uid,
                    showDateDivider: showDateDivider,
                    isHighlighted: isTarget,
                    targetKey: isTarget ? _targetMessageKey : null,
                    nicknameCache: _nicknameCache,
                    profileImageCache: _profileImageCache,
                    allChats: _chats,
                    onReply: _setReplyTarget,
                    onLongPress: _showMessageOptions,
                    onScrollToReply: _loadAndScrollToMessage,
                  );
                },
              ),
            ),
          ),

          // 상대방 입력 중 표시
          ChatTypingIndicator(typingNotifier: _partnerTypingNotifier),

          // 사진 업로드 중 표시
          if (_isUploadingImage)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Theme.of(context).colorScheme.primary)),
                  const SizedBox(width: 10),
                  Text(
                    _uploadProgress.isEmpty ? "전송 중..." : "전송 중... ($_uploadProgress)",
                    style: TextStyle(fontSize: 13, color: Theme.of(context).colorScheme.onSurface),
                  ),
                ],
              ),
            ),

          // 답장 미리보기 바
          if (_replyTarget != null)
            ChatReplyPreview(
              replyTarget: Map<String, dynamic>.from(_replyTarget!),
              myUid: widget.uid,
              nicknameCache: _nicknameCache,
              onCancel: _cancelReply,
            ),

          // 입력창
          ChatInputBar(
            controller: _controller,
            focusNode: _focusNode,
            onTypingChanged: _onTypingChanged,
            onSend: _sendMessage,
            onAttachment: _showAttachmentSheet,
            sendScaleAnim: _sendScaleAnim,
            sendAnimController: _sendAnimController,
          ),
        ],
      ),
    );
  }
}
