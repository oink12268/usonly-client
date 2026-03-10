import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:stomp_dart_client/stomp_dart_client.dart';
import 'api_config.dart';
import 'api_client.dart';
import 'note_editor_page.dart';
import 'utils/date_formatter.dart';

class NotePage extends StatefulWidget {
  final int memberId;
  final int? coupleId;
  final int? parentNoteId;
  final String? parentTitle;

  const NotePage({
    super.key,
    required this.memberId,
    this.coupleId,
    this.parentNoteId,
    this.parentTitle,
  });

  @override
  State<NotePage> createState() => _NotePageState();
}

class _NotePageState extends State<NotePage> with WidgetsBindingObserver {
  List<Map<String, dynamic>> _notes = [];
  bool _isLoading = true;
  StompClient? _stompClient;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _fetchNotes();
    if (widget.coupleId != null) _connectSocket(widget.coupleId!);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _fetchNotes();
      if (widget.coupleId != null) {
        _stompClient?.deactivate();
        _stompClient = null;
        _connectSocket(widget.coupleId!);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stompClient?.deactivate();
    super.dispose();
  }

  Future<void> _fetchNotes() async {
    try {
      final uri = widget.parentNoteId != null
          ? Uri.parse('${ApiConfig.baseUrl}/api/notes?parentId=${widget.parentNoteId}')
          : Uri.parse('${ApiConfig.baseUrl}/api/notes');
      final response = await ApiClient.get(uri);
      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes)) as List;
        setState(() {
          _notes = data.cast<Map<String, dynamic>>();
          _isLoading = false;
        });
      }
    } catch (e) {
      print("메모 로딩 에러: $e");
      setState(() => _isLoading = false);
    }
  }

  void _connectSocket(int coupleId) async {
    final headers = await ApiClient.stompHeaders();
    _stompClient = StompClient(
      config: StompConfig(
        url: ApiConfig.wsUrl,
        stompConnectHeaders: headers,
        onConnect: (StompFrame frame) {
          _stompClient!.subscribe(
            destination: '/sub/couple/$coupleId/notes',
            callback: (StompFrame frame) {
              if (frame.body == null) return;
              final event = jsonDecode(frame.body!);
              final type = event['type'] as String;
              final noteData = event['note'];
              final deletedId = event['deletedId'];

              setState(() {
                if (type == 'CREATED' && noteData != null) {
                  final note = Map<String, dynamic>.from(noteData);
                  // 현재 레벨의 노트만 추가 (parentId가 현재 화면과 일치해야 함)
                  final noteParentId = note['parentId'] as int?;
                  final isSameLevel = noteParentId == widget.parentNoteId;
                  if (isSameLevel && !_notes.any((n) => n['id'] == note['id'])) {
                    _notes.insert(0, note);
                  }
                } else if (type == 'UPDATED' && noteData != null) {
                  final note = Map<String, dynamic>.from(noteData);
                  final idx = _notes.indexWhere((n) => n['id'] == note['id']);
                  if (idx != -1) _notes[idx] = note;
                } else if (type == 'DELETED' && deletedId != null) {
                  _notes.removeWhere((n) => n['id'] == deletedId);
                }
              });
            },
          );
        },
        onWebSocketError: (e) => print("노트 소켓 에러: $e"),
      ),
    );
    _stompClient!.activate();
  }

  Future<void> _createNote() async {
    try {
      final body = <String, dynamic>{'title': '새 메모', 'content': ''};
      if (widget.parentNoteId != null) body['parentId'] = widget.parentNoteId;
      final response = await ApiClient.post(
        Uri.parse('${ApiConfig.baseUrl}/api/notes'),
        body: jsonEncode(body),
      );
      if (response.statusCode == 200 && mounted) {
        final note = jsonDecode(utf8.decode(response.bodyBytes));
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => NoteEditorPage(
              note: Map<String, dynamic>.from(note),
              memberId: widget.memberId,
              coupleId: widget.coupleId,
            ),
          ),
        );
        _fetchNotes();
      }
    } catch (e) {
      print("메모 생성 에러: $e");
    }
  }

  Future<void> _deleteNote(int noteId) async {
    try {
      await ApiClient.delete(
        Uri.parse('${ApiConfig.baseUrl}/api/notes/$noteId'),
      );
      // WebSocket이 목록 자동 업데이트
    } catch (e) {
      print("메모 삭제 에러: $e");
      _fetchNotes();
    }
  }

  String _formatDate(String? dateStr) => DateFormatter.formatRelative(dateStr);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.parentTitle ?? '메모장',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _notes.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.note_outlined, size: 64, color: Colors.grey),
                      SizedBox(height: 16),
                      Text(
                        '아직 메모가 없어요\n+ 버튼을 눌러 첫 메모를 작성해보세요',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey),
                      ),
                    ],
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _notes.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final note = _notes[index];
                    return Dismissible(
                      key: Key(note['id'].toString()),
                      direction: DismissDirection.endToStart,
                      background: Container(
                        alignment: Alignment.centerRight,
                        padding: const EdgeInsets.only(right: 20),
                        decoration: BoxDecoration(
                          color: Colors.red.shade400,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(Icons.delete, color: Colors.white),
                      ),
                      onDismissed: (_) async {
                        final deletedNote = Map<String, dynamic>.from(note);
                        final deletedIndex = index;
                        setState(() => _notes.removeAt(deletedIndex));

                        bool undone = false;
                        final controller = ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: const Text('메모가 삭제되었습니다'),
                            action: SnackBarAction(
                              label: '실행 취소',
                              onPressed: () {
                                undone = true;
                                if (mounted) {
                                  setState(() => _notes.insert(
                                    deletedIndex.clamp(0, _notes.length),
                                    deletedNote,
                                  ));
                                }
                              },
                            ),
                          ),
                        );

                        await controller.closed;
                        if (!undone) _deleteNote(deletedNote['id']);
                      },
                      child: Card(
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
                        ),
                        child: ListTile(
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 8),
                          onTap: () async {
                            await Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => NoteEditorPage(
                                  note: Map<String, dynamic>.from(note),
                                  memberId: widget.memberId,
                                  coupleId: widget.coupleId,
                                ),
                              ),
                            );
                            _fetchNotes();
                          },
                          title: Text(
                            note['title']?.isEmpty == true
                                ? '(제목 없음)'
                                : note['title'],
                            style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: note['content']?.isNotEmpty == true
                              ? Text(
                                  note['content'],
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white, fontSize: 13),
                                )
                              : null,
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    _formatDate(note['updatedAt']),
                                    style: const TextStyle(
                                      fontSize: 11, color: Colors.white),
                                  ),
                                  if (note['lastEditedByNickname'] != null) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      note['lastEditedByNickname'],
                                      style: const TextStyle(
                                        fontSize: 11, color: Colors.white),
                                    ),
                                  ],
                                ],
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                padding: EdgeInsets.zero,
                                constraints: const BoxConstraints(),
                                icon: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      (note['childCount'] ?? 0) > 0
                                          ? Icons.folder
                                          : Icons.folder_outlined,
                                      size: 20,
                                      color: Colors.white,
                                    ),
                                    if ((note['childCount'] ?? 0) > 0)
                                      Text(
                                        '${note['childCount']}',
                                        style: const TextStyle(fontSize: 10, color: Colors.white),
                                      ),
                                  ],
                                ),
                                onPressed: () async {
                                  await Navigator.push(
                                    context,
                                    MaterialPageRoute(
                                      builder: (_) => NotePage(
                                        memberId: widget.memberId,
                                        coupleId: widget.coupleId,
                                        parentNoteId: note['id'],
                                        parentTitle: note['title']?.isEmpty == true
                                            ? '(제목 없음)'
                                            : note['title'],
                                      ),
                                    ),
                                  );
                                  _fetchNotes();
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: _createNote,
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        child: const Icon(Icons.add),
      ),
    );
  }
}
