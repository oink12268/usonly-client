import 'package:flutter/material.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'api_config.dart';
import 'api_client.dart';
import 'note_page.dart';

class NoteEditorPage extends StatefulWidget {
  final Map<String, dynamic> note;
  final int? memberId;
  final int? coupleId;

  const NoteEditorPage({super.key, required this.note, this.memberId, this.coupleId});

  @override
  State<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends State<NoteEditorPage> {
  late EditorState _editorState;
  late TextEditingController _titleController;
  late final MobileToolbarItem _imagePickerToolbarItem; // [Fix 4] 매 빌드마다 재생성 방지
  StreamSubscription? _transactionSubscription;        // [Fix 1] 메모리 누수 방지
  Timer? _autoSaveDebounce;                            // [Fix 5] 자동저장 디바운스 타이머
  Timer? _autoSaveForceTimer;                          // [Fix 5] 최대 30초 강제저장 타이머

  bool _isSaving = false;
  bool _hasUnsavedChanges = false;
  int _pendingUploads = 0;
  String? _lastSavedContent;
  String? _lastSavedTitle;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.note['title'] ?? '');

    final content = widget.note['content'] as String? ?? '';
    Document document;
    try {
      document = content.isEmpty ? Document.blank() : markdownToDocument(content);
    } catch (_) {
      document = Document.blank();
    }

    _editorState = EditorState(document: document);
    _lastSavedContent = content;
    _lastSavedTitle = widget.note['title'] ?? '';

    // [Fix 4] 한 번만 생성
    _imagePickerToolbarItem = _buildImagePickerToolbarItem();

    // [Fix 1] subscription 저장 → dispose에서 cancel
    _transactionSubscription = _editorState.transactionStream.listen((event) {
      if (event.$1 == TransactionTime.after) {
        if (mounted && !_hasUnsavedChanges) {
          setState(() => _hasUnsavedChanges = true);
        }
        _handleImageUpload(event.$2);
        _scheduleAutoSave(); // [Fix 5] 변경 시 자동저장 예약
      }
    });

    _titleController.addListener(() {
      if (mounted && !_hasUnsavedChanges) {
        setState(() => _hasUnsavedChanges = true);
      }
      _scheduleAutoSave(); // [Fix 5] 제목 변경 시도 자동저장 예약
    });

    // 새 메모(빈 내용)일 때 에디터에 자동 포커스 및 커서 설정
    if (content.isEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _editorState.updateSelectionWithReason(
          Selection.collapsed(Position(path: [0], offset: 0)),
          reason: SelectionUpdateReason.uiEvent,
        );
      });
    }
  }

  // [Fix 5] 자동저장: 타이핑 멈춘 후 3초 뒤 저장, 최대 30초 강제저장
  void _scheduleAutoSave() {
    // 디바운스: 타이핑 중엔 계속 리셋, 멈추면 3초 후 저장
    _autoSaveDebounce?.cancel();
    _autoSaveDebounce = Timer(const Duration(seconds: 3), () {
      if (_pendingUploads == 0) _saveInternal();
      _autoSaveForceTimer?.cancel();
      _autoSaveForceTimer = null;
    });

    // 강제저장: 첫 변경 후 30초가 지나면 무조건 저장 (앱 강제종료 대비)
    _autoSaveForceTimer ??= Timer(const Duration(seconds: 30), () {
      _autoSaveDebounce?.cancel();
      _autoSaveDebounce = null;
      _autoSaveForceTimer = null;
      if (_pendingUploads == 0) _saveInternal();
    });
  }

  MobileToolbarItem _buildImagePickerToolbarItem() => MobileToolbarItem.action(
        itemIconBuilder: (_, __, ___) =>
            const Icon(Icons.image_outlined, size: 22),
        actionHandler: (context, editorState) async {
          final xFile = await ImagePicker().pickImage(
            source: ImageSource.gallery,
          );
          if (xFile == null) return;

          final selection = editorState.selection;
          final imagePath = selection != null
              ? selection.end.path.next
              : [editorState.document.root.children.length];
          final paraPath = imagePath.next;

          final txn = editorState.transaction;
          txn.insertNode(
            imagePath,
            Node(
              type: ImageBlockKeys.type,
              attributes: {ImageBlockKeys.url: xFile.path},
            ),
          );
          txn.insertNode(paraPath, paragraphNode());
          txn.afterSelection = Selection.collapsed(
            Position(path: paraPath, offset: 0),
          );
          await editorState.apply(txn);

          await Future.delayed(const Duration(milliseconds: 100));
          final newSel = editorState.selection;
          if (newSel != null) {
            await editorState.updateSelectionWithReason(
              newSel,
              reason: SelectionUpdateReason.uiEvent,
            );
          }
        },
      );

  void _handleImageUpload(Transaction transaction) {
    for (final op in transaction.operations) {
      if (op is InsertOperation) {
        for (final node in op.nodes) {
          if (node.type == ImageBlockKeys.type) {
            final url = node.attributes[ImageBlockKeys.url] as String?;
            if (url != null && !url.startsWith('http')) {
              _uploadImage(node, url);
            }
          }
        }
      }
    }
  }

  Future<void> _uploadImage(Node node, String localPath) async {
    if (mounted) setState(() => _pendingUploads++);
    try {
      final bytes = await File(localPath).readAsBytes();
      final filename = localPath.split('/').last;

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('${ApiConfig.baseUrl}/api/notes/image'),
      );
      request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));

      final response = await ApiClient.sendMultipart(request);
      if (response.statusCode == 200) {
        final data = jsonDecode(await response.stream.bytesToString());
        final serverUrl = data['imageUrl'] as String;

        final transaction = _editorState.transaction;
        transaction.updateNode(node, {ImageBlockKeys.url: serverUrl});
        await _editorState.apply(transaction);

        await _saveInternal();
      } else {
        // [Fix 3] 업로드 실패 시 깨진 이미지 노드 제거 + 유저에게 알림
        if (mounted) {
          final transaction = _editorState.transaction;
          transaction.deleteNode(node);
          await _editorState.apply(transaction);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('이미지 업로드에 실패했습니다. 다시 시도해주세요.')),
          );
        }
      }
    } catch (e) {
      debugPrint('이미지 업로드 에러: $e');
      // [Fix 3] 예외 발생 시에도 깨진 노드 제거 + 유저에게 알림
      if (mounted) {
        try {
          final transaction = _editorState.transaction;
          transaction.deleteNode(node);
          await _editorState.apply(transaction);
        } catch (_) {}
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('이미지 업로드에 실패했습니다. 다시 시도해주세요.')),
        );
      }
    } finally {
      if (mounted) setState(() => _pendingUploads--);
    }
  }

  String _getMarkdown() {
    return documentToMarkdown(_editorState.document);
  }

  Future<void> _save() async {
    if (_pendingUploads > 0) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('이미지 업로드 중입니다. 완료 후 자동 저장됩니다.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    await _saveInternal();
  }

  Future<void> _saveInternal() async {
    if (_isSaving) return;
    final content = _getMarkdown();
    final title = _titleController.text;
    if (content == _lastSavedContent && title == _lastSavedTitle) {
      if (mounted) setState(() => _hasUnsavedChanges = false);
      return;
    }
    if (mounted) setState(() => _isSaving = true);
    try {
      await ApiClient.put(
        Uri.parse('${ApiConfig.baseUrl}/api/notes/${widget.note['id']}'),
        body: jsonEncode({'title': title, 'content': content}),
      );
      _lastSavedContent = content;
      _lastSavedTitle = title;
      if (mounted) setState(() => _hasUnsavedChanges = false);
    } catch (e) {
      debugPrint('메모 저장 에러: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _forceSave() async {
    _autoSaveDebounce?.cancel();   // 예약된 자동저장 취소 후 즉시 저장
    _autoSaveForceTimer?.cancel();
    _autoSaveForceTimer = null;
    final content = _getMarkdown();
    final title = _titleController.text;
    if (content == _lastSavedContent && title == _lastSavedTitle) return;
    try {
      await ApiClient.put(
        Uri.parse('${ApiConfig.baseUrl}/api/notes/${widget.note['id']}'),
        body: jsonEncode({'title': title, 'content': content}),
      );
      // [Fix 2] 저장 성공 후 기준값 갱신
      _lastSavedContent = content;
      _lastSavedTitle = title;
    } catch (e) {
      debugPrint('노트 강제 저장 오류: $e');
    }
  }

  @override
  void dispose() {
    _autoSaveDebounce?.cancel();        // [Fix 5]
    _autoSaveForceTimer?.cancel();      // [Fix 5]
    _transactionSubscription?.cancel(); // [Fix 1]
    _titleController.dispose();
    _editorState.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false, // AppFlowyEditor + MobileToolbar이 keyboard inset을 내부적으로 처리함
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () async {
            await _forceSave();
            if (!mounted) return;
            // ignore: use_build_context_synchronously
            Navigator.pop(context);
          },
        ),
        title: TextField(
          controller: _titleController,
          decoration: const InputDecoration(
            hintText: '제목을 입력하세요',
            border: InputBorder.none,
          ),
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.folder_open),
            tooltip: '하위 메모',
            onPressed: () async {
              final nav = Navigator.of(context);
              await _forceSave();
              if (!mounted) return;
              await nav.push(
                MaterialPageRoute(
                  builder: (_) => NotePage(
                    memberId: widget.memberId ?? 0,
                    coupleId: widget.coupleId,
                    parentNoteId: widget.note['id'],
                    parentTitle: _titleController.text.isEmpty
                        ? '(제목 없음)'
                        : _titleController.text,
                  ),
                ),
              );
            },
          ),
          if (_isSaving || _pendingUploads > 0)
            const Padding(
              padding: EdgeInsets.all(12),
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              icon: Icon(
                _hasUnsavedChanges ? Icons.save : Icons.cloud_done_outlined,
                color: _hasUnsavedChanges ? const Color(0xFF8B7E74) : Colors.grey,
              ),
              tooltip: _hasUnsavedChanges ? '저장' : '저장됨',
              onPressed: _hasUnsavedChanges ? _save : null,
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: AppFlowyEditor(
              editorState: _editorState,
              editorStyle: EditorStyle.mobile().copyWith(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                textStyleConfiguration: TextStyleConfiguration(
                  text: const TextStyle(color: Colors.white),
                ),
              ),
            ),
          ),
          MobileToolbar(
            editorState: _editorState,
            toolbarItems: [
              textDecorationMobileToolbarItem,
              headingMobileToolbarItem,
              todoListMobileToolbarItem,
              listMobileToolbarItem,
              linkMobileToolbarItem,
              quoteMobileToolbarItem,
              codeMobileToolbarItem,
              _imagePickerToolbarItem,
            ],
          ),
        ],
      ),
    );
  }
}
