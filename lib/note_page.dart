import 'package:flutter/material.dart';
import 'dart:convert';
import 'package:stomp_dart_client/stomp_dart_client.dart';
import 'api_config.dart';
import 'api_client.dart';
import 'note_editor_page.dart';

class NotePage extends StatefulWidget {
  final int memberId;
  final int? coupleId;

  const NotePage({super.key, required this.memberId, this.coupleId});

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
      final response = await ApiClient.get(
        Uri.parse('${ApiConfig.baseUrl}/api/notes'),
      );
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
                  if (!_notes.any((n) => n['id'] == note['id'])) {
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
      final response = await ApiClient.post(
        Uri.parse('${ApiConfig.baseUrl}/api/notes'),
        body: jsonEncode({'title': '새 메모', 'content': ''}),
      );
      if (response.statusCode == 200 && mounted) {
        final note = jsonDecode(utf8.decode(response.bodyBytes));
        await Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => NoteEditorPage(
              note: Map<String, dynamic>.from(note),
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

  String _formatDate(String? dateStr) {
    if (dateStr == null) return '';
    try {
      final dt = DateTime.parse(dateStr);
      final now = DateTime.now();
      if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
        return '오늘 ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
      }
      return '${dt.month}/${dt.day}';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('메모장', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _notes.isEmpty
              ? const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.note_outlined, size: 64, color: Color(0xFFD4C5B9)),
                      SizedBox(height: 16),
                      Text(
                        '아직 메모가 없어요\n+ 버튼을 눌러 첫 메모를 작성해보세요',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Color(0xFFD4C5B9)),
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
                      onDismissed: (_) => _deleteNote(note['id']),
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
                                ),
                              ),
                            );
                            _fetchNotes();
                          },
                          title: Text(
                            note['title']?.isEmpty == true
                                ? '(제목 없음)'
                                : note['title'],
                            style: const TextStyle(fontWeight: FontWeight.w600),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: note['content']?.isNotEmpty == true
                              ? Text(
                                  note['content'],
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 13),
                                )
                              : null,
                          trailing: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text(
                                _formatDate(note['updatedAt']),
                                style: TextStyle(
                                  fontSize: 11, color: Theme.of(context).colorScheme.onSurfaceVariant),
                              ),
                              if (note['lastEditedByNickname'] != null) ...[
                                const SizedBox(height: 2),
                                Text(
                                  note['lastEditedByNickname'],
                                  style: const TextStyle(
                                    fontSize: 11, color: Color(0xFF8B7E74)),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton(
        onPressed: _createNote,
        child: const Icon(Icons.add),
      ),
    );
  }
}
