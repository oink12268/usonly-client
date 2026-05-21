import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:stomp_dart_client/stomp_dart_client.dart';
import 'api_client.dart';
import 'api_endpoints.dart';
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
  int? _draggingNoteId;
  int? _hoveringNoteId;
  int? _reorderTargetIndex;

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
      final url = widget.parentNoteId != null
          ? ApiEndpoints.notesWithParent(widget.parentNoteId!)
          : ApiEndpoints.notes;
      final response = await ApiClient.get(Uri.parse(url));
      if (response.statusCode == 200) {
        final data = ApiClient.decodeBody(response) as List;
        setState(() {
          _notes = data.cast<Map<String, dynamic>>();
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint("메모 로딩 에러: $e");
      setState(() => _isLoading = false);
    }
  }

  void _connectSocket(int coupleId) async {
    final headers = await ApiClient.stompHeaders();
    _stompClient = StompClient(
      config: StompConfig(
        url: ApiEndpoints.wsUrl,
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
                } else if (type == 'MOVED') {
                  final movedId = event['movedId'];
                  if (movedId != null) {
                    _notes.removeWhere((n) => n['id'] == movedId);
                  }
                } else if (type == 'REORDERED') {
                  final orderedIds = (event['orderedIds'] as List?)?.map((e) => e as int).toList();
                  final reorderParentId = event['reorderParentId'] as int?;
                  if (orderedIds != null && reorderParentId == widget.parentNoteId) {
                    _notes.sort((a, b) {
                      final ai = orderedIds.indexOf(a['id'] as int);
                      final bi = orderedIds.indexOf(b['id'] as int);
                      if (ai == -1) return 1;
                      if (bi == -1) return -1;
                      return ai.compareTo(bi);
                    });
                  }
                }
              });
            },
          );
        },
        onWebSocketError: (e) => debugPrint("노트 소켓 에러: $e"),
      ),
    );
    _stompClient!.activate();
  }

  Future<void> _createNote() async {
    try {
      final body = <String, dynamic>{'title': '새 메모', 'content': ''};
      if (widget.parentNoteId != null) body['parentId'] = widget.parentNoteId;
      final response = await ApiClient.post(
        Uri.parse(ApiEndpoints.notes),
        body: jsonEncode(body),
      );
      if (response.statusCode == 200 && mounted) {
        final note = ApiClient.decodeBody(response) as Map<String, dynamic>;
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
      debugPrint("메모 생성 에러: $e");
    }
  }

  Future<void> _deleteNote(int noteId) async {
    try {
      await ApiClient.delete(
        Uri.parse(ApiEndpoints.noteById(noteId)),
      );
      // WebSocket이 목록 자동 업데이트
    } catch (e) {
      debugPrint("메모 삭제 에러: $e");
      _fetchNotes();
    }
  }

  Future<void> _moveNote(int noteId, int? targetParentId) async {
    try {
      final response = await ApiClient.patch(
        Uri.parse(ApiEndpoints.noteMove(noteId)),
        body: jsonEncode({'targetParentId': targetParentId}),
      );
      if (response.statusCode == 200) {
        setState(() => _notes.removeWhere((n) => n['id'] == noteId));
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('이동 실패 (${response.statusCode}): ${response.body}')),
          );
        }
        _fetchNotes();
      }
    } catch (e) {
      debugPrint("메모 이동 에러: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('이동 중 오류: $e')),
        );
      }
      _fetchNotes();
    }
  }

  Future<void> _reorderNote(int draggedNoteId, int insertAtIndex) async {
    final draggedIndex = _notes.indexWhere((n) => n['id'] == draggedNoteId);
    if (draggedIndex == -1) return;

    final newNotes = List<Map<String, dynamic>>.from(_notes);
    final draggedNote = newNotes.removeAt(draggedIndex);
    int targetIndex = draggedIndex < insertAtIndex ? insertAtIndex - 1 : insertAtIndex;
    targetIndex = targetIndex.clamp(0, newNotes.length);
    newNotes.insert(targetIndex, draggedNote);

    setState(() => _notes = newNotes);

    try {
      await ApiClient.post(
        Uri.parse(ApiEndpoints.noteReorder),
        body: jsonEncode({
          'orderedIds': newNotes.map((n) => n['id']).toList(),
          'parentId': widget.parentNoteId,
        }),
      );
    } catch (e) {
      debugPrint('메모 순서 변경 에러: $e');
      _fetchNotes();
    }
  }

  String _formatDate(String? dateStr) => DateFormatter.formatRelative(dateStr);

  String _extractPlainText(String? content) {
    if (content == null || content.isEmpty) return '';
    try {
      final delta = jsonDecode(content);
      if (delta is List) {
        final buffer = StringBuffer();
        for (final op in delta) {
          if (op is Map && op['insert'] is String) {
            buffer.write(op['insert']);
          }
        }
        return buffer.toString().replaceAll('\n', ' ').trim();
      }
    } catch (_) {}
    return content;
  }

  Widget _buildSeparatorDropZone(BuildContext context, int insertIndex) {
    return DragTarget<int>(
      key: ValueKey('sep_$insertIndex'),
      onWillAcceptWithDetails: (details) {
        final draggedIndex = _notes.indexWhere((n) => n['id'] == details.data);
        // 바로 위/아래는 제자리이므로 거절
        if (draggedIndex == insertIndex || draggedIndex + 1 == insertIndex) return false;
        setState(() => _reorderTargetIndex = insertIndex);
        return true;
      },
      onLeave: (_) => setState(() {
        if (_reorderTargetIndex == insertIndex) _reorderTargetIndex = null;
      }),
      onAcceptWithDetails: (details) {
        setState(() => _reorderTargetIndex = null);
        _reorderNote(details.data, insertIndex);
      },
      builder: (context, candidateData, _) {
        final isActive = candidateData.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          height: isActive ? 24 : 6,
          child: isActive
              ? Center(
                  child: Container(
                    height: 3,
                    margin: const EdgeInsets.symmetric(horizontal: 16),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.primary,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                )
              : null,
        );
      },
    );
  }

  Widget _buildNoteCard(BuildContext context, Map<String, dynamic> note, int index,
      {required bool isHovering, required bool isDragging}) {
    final cs = Theme.of(context).colorScheme;
    final childCount = (note['childCount'] ?? 0) as int;
    final title = note['title']?.isEmpty == true ? '(제목 없음)' : note['title'] as String;
    final plainText = _extractPlainText(note['content']);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        border: isHovering ? Border.all(color: cs.primary, width: 1.5) : null,
      ),
      child: Dismissible(
        key: Key('dismiss_${note['id']}'),
        direction: isDragging ? DismissDirection.none : DismissDirection.endToStart,
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 20),
          decoration: BoxDecoration(
            color: Colors.red.shade400,
            borderRadius: BorderRadius.circular(16),
          ),
          child: const Icon(Icons.delete_outline, color: Colors.white),
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
        child: Material(
          color: isHovering
              ? cs.primaryContainer.withOpacity(0.25)
              : cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
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
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 76),
              child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            if (note['isPrivate'] == true) ...[
                              Icon(Icons.lock_outline, size: 13, color: cs.primary),
                              const SizedBox(width: 4),
                            ],
                            Expanded(
                              child: Text(
                                title,
                                style: const TextStyle(
                                    fontWeight: FontWeight.w500, fontSize: 15),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ],
                        ),
                        if (plainText.isNotEmpty) ...[
                          const SizedBox(height: 4),
                          Text(
                            plainText,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13, color: cs.onSurfaceVariant),
                          ),
                        ],
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Text(
                              _formatDate(note['updatedAt']),
                              style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant.withOpacity(0.7)),
                            ),
                            if (note['lastEditedByNickname'] != null) ...[
                              Text(
                                '  ·  ${note['lastEditedByNickname']}',
                                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant.withOpacity(0.7)),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (childCount > 0)
                    GestureDetector(
                      onTap: () async {
                        await Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => NotePage(
                              memberId: widget.memberId,
                              coupleId: widget.coupleId,
                              parentNoteId: note['id'],
                              parentTitle: title,
                            ),
                          ),
                        );
                        _fetchNotes();
                      },
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: cs.onSurface.withOpacity(0.08),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                '$childCount',
                                style: TextStyle(fontSize: 11, color: cs.onSurfaceVariant),
                              ),
                            ),
                            const SizedBox(width: 2),
                            Icon(Icons.chevron_right, size: 18, color: cs.onSurfaceVariant.withOpacity(0.5)),
                          ],
                        ),
                      ),
                    )
                  else
                    const SizedBox(width: 12),
                ],
              ),
            ),
            ),
          ),
        ),
      ),
    );
  }

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
                      Icon(Icons.note_outlined, size: 64, color: Color(0xFF9E9E9E)),
                      SizedBox(height: 16),
                      Text(
                        '아직 메모가 없어요\n+ 버튼을 눌러 첫 메모를 작성해보세요',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Color(0xFF9E9E9E)),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  // 아이템 사이사이 + 맨 위/아래에 드롭존 (separator)
                  // index: 짝수 = separator, 홀수 = note
                  itemCount: _notes.length * 2 + 1,
                  itemBuilder: (context, index) {
                    if (index.isEven) {
                      return _buildSeparatorDropZone(context, index ~/ 2);
                    }

                    final noteIndex = index ~/ 2;
                    final note = _notes[noteIndex];
                    final noteId = note['id'] as int;
                    final isDragging = _draggingNoteId == noteId;
                    final isHovering = _hoveringNoteId == noteId;

                    return DragTarget<int>(
                      key: ValueKey('note_$noteId'),
                      onWillAcceptWithDetails: (details) {
                        if (details.data == noteId) return false;
                        setState(() {
                          _hoveringNoteId = noteId;
                          _reorderTargetIndex = null;
                        });
                        return true;
                      },
                      onLeave: (_) => setState(() => _hoveringNoteId = null),
                      onAcceptWithDetails: (details) {
                        setState(() => _hoveringNoteId = null);
                        _moveNote(details.data, noteId);
                      },
                      builder: (context, candidateData, _) {
                        return LongPressDraggable<int>(
                          data: noteId,
                          delay: const Duration(milliseconds: 400),
                          onDragStarted: () => setState(() => _draggingNoteId = noteId),
                          onDragEnd: (_) => setState(() {
                            _draggingNoteId = null;
                            _reorderTargetIndex = null;
                          }),
                          feedback: Material(
                            elevation: 8,
                            borderRadius: BorderRadius.circular(16),
                            color: Theme.of(context).colorScheme.surfaceContainerHigh,
                            child: SizedBox(
                              width: MediaQuery.of(context).size.width - 32,
                              child: Opacity(
                                opacity: 0.95,
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                                  child: Row(
                                    children: [
                                      if (note['isPrivate'] == true) ...[
                                        Icon(Icons.lock_outline, size: 13,
                                            color: Theme.of(context).colorScheme.primary),
                                        const SizedBox(width: 4),
                                      ],
                                      Expanded(
                                        child: Text(
                                          note['title']?.isEmpty == true ? '(제목 없음)' : note['title'],
                                          style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 15),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                          childWhenDragging: Opacity(
                            opacity: 0.3,
                            child: _buildNoteCard(context, note, noteIndex, isHovering: false, isDragging: true),
                          ),
                          child: _buildNoteCard(context, note, noteIndex, isHovering: isHovering, isDragging: isDragging),
                        );
                      },
                    );
                  },
                ),
      floatingActionButton: FloatingActionButton.small(
        onPressed: _createNote,
        backgroundColor: Theme.of(context).colorScheme.primary,
        foregroundColor: Theme.of(context).colorScheme.onPrimary,
        elevation: 2,
        child: const Icon(Icons.add, size: 20),
      ),
    );
  }
}
