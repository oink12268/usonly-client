import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:io';
import 'package:appflowy_editor/appflowy_editor.dart';
import 'package:http/http.dart' as http;
import 'package:image_picker/image_picker.dart';
import 'api_config.dart';
import 'api_client.dart';

// 불릿/번호/체크 리스트 아이템의 세로 간격 (기본값보다 좁게)
EdgeInsets _tightListPadding(Node node) =>
    const EdgeInsets.symmetric(vertical: 0);

class NoteEditorPage extends StatefulWidget {
  final Map<String, dynamic> note;

  const NoteEditorPage({super.key, required this.note});

  @override
  State<NoteEditorPage> createState() => _NoteEditorPageState();
}

class _NoteEditorPageState extends State<NoteEditorPage> {
  late EditorState _editorState;
  late TextEditingController _titleController;
  StreamSubscription? _transactionSubscription;
  Timer? _debounce;
  bool _isSaving = false;
  bool _canUndo = false;
  bool _canRedo = false;
  String? _lastSavedContent;
  String? _lastSavedTitle;

  bool get _isMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(
      text: widget.note['title'] ?? '',
    );

    // 저장된 마크다운 → AppFlowy Document 변환
    final content = widget.note['content'] as String? ?? '';
    final document = content.trim().isEmpty
        ? EditorState.blank().document
        : markdownToDocument(content);

    _editorState = EditorState(document: document);
    // transactionStream: 문서 변경(입력, 삭제, 서식 등)이 생길 때마다 이벤트 발생
    _transactionSubscription = _editorState.transactionStream.listen((event) {
      final (time, transaction, _) = event;
      // 트랜잭션 적용 후 이미지 블록 감지 → 서버 업로드
      if (time == TransactionTime.after) {
        _handleImageUploads(transaction);
      }
      _onContentChanged();
      if (mounted) setState(() {
        _canUndo = _editorState.undoManager.undoStack.isNotEmpty;
        _canRedo = _editorState.undoManager.redoStack.isNotEmpty;
      });
    });
    _titleController.addListener(_onContentChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _transactionSubscription?.cancel();
    _editorState.dispose();
    _titleController.dispose();
    super.dispose();
  }

  // 이미지 블록 삽입 감지 → 로컬 경로면 서버 업로드 후 URL 교체
  void _handleImageUploads(Transaction transaction) {
    for (final op in transaction.operations) {
      if (op is InsertOperation) {
        for (final node in op.nodes) {
          _uploadLocalImageIfNeeded(node);
        }
      }
    }
  }

  Future<void> _uploadLocalImageIfNeeded(Node node) async {
    if (node.type != ImageBlockKeys.type) return;

    final url = node.attributes[ImageBlockKeys.url] as String?;
    // 이미 서버 URL이면 스킵
    if (url == null || url.startsWith('http')) return;

    try {
      final file = File(url);
      if (!await file.exists()) return;

      final bytes = await file.readAsBytes();
      final filename = url.split('/').last;

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('${ApiConfig.baseUrl}/api/notes/image'),
      );
      request.files.add(
        http.MultipartFile.fromBytes('file', bytes, filename: filename),
      );

      final response = await ApiClient.sendMultipart(request);
      if (response.statusCode == 200) {
        final data = jsonDecode(await response.stream.bytesToString());
        final serverUrl = data['imageUrl'] as String;

        // 로컬 경로 → 서버 URL로 교체
        final txn = _editorState.transaction;
        txn.updateNode(node, {ImageBlockKeys.url: serverUrl});
        await _editorState.apply(txn);
      }
    } catch (e) {
      print('노트 이미지 업로드 에러: $e');
    }
  }

  // 갤러리에서 사진 선택 → 에디터에 이미지 블록 삽입
  MobileToolbarItem get _imagePickerToolbarItem => MobileToolbarItem.action(
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
          // 이미지 아래에 빈 단락 삽입 후 커서 이동
          txn.insertNode(paraPath, paragraphNode());
          txn.afterSelection = Selection.collapsed(
            Position(path: paraPath, offset: 0),
          );
          await editorState.apply(txn);

          // 갤러리에서 돌아온 후 키보드 재활성화
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

  // 불릿/번호 리스트 아이템 간격 줄이기
  Map<String, BlockComponentBuilder> _buildComponentBuilders() {
    const tightPadding = BlockComponentConfiguration(
      padding: _tightListPadding,
    );
    return {
      ...standardBlockComponentBuilderMap,
      BulletedListBlockKeys.type: BulletedListBlockComponentBuilder(
        configuration: tightPadding,
      ),
      NumberedListBlockKeys.type: NumberedListBlockComponentBuilder(
        configuration: tightPadding,
      ),
      TodoListBlockKeys.type: TodoListBlockComponentBuilder(
        configuration: tightPadding,
      ),
    };
  }

  // 타이핑 멈춘 후 800ms 뒤 자동 저장
  void _onContentChanged() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 800), _save);
  }

  Future<void> _save() async {
    if (_isSaving) return;

    final markdown = documentToMarkdown(_editorState.document);
    final title = _titleController.text;

    // 마지막 저장 내용과 동일하면 PUT 생략
    if (markdown == _lastSavedContent && title == _lastSavedTitle) return;

    if (mounted) setState(() => _isSaving = true);
    try {
      await ApiClient.put(
        Uri.parse('${ApiConfig.baseUrl}/api/notes/${widget.note['id']}'),
        body: jsonEncode({'title': title, 'content': markdown}),
      );
      _lastSavedContent = markdown;
      _lastSavedTitle = title;
    } catch (e) {
      print("메모 저장 에러: $e");
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // AppFlowyEditor + MobileToolbar이 keyboard inset을 내부적으로 처리함
      // true(기본값)로 두면 Scaffold resize + AppFlowy 내부 처리가 중복되어 "뚜뚝" 끊김 발생
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () async {
            // 뒤로가기 시 즉시 저장 후 pop
            _debounce?.cancel();
            await _save();
            if (mounted) Navigator.pop(context);
          },
        ),
        title: TextField(
          controller: _titleController,
          decoration: const InputDecoration(
            hintText: '제목을 입력하세요',
            border: InputBorder.none,
          ),
          style: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.undo),
            tooltip: '실행 취소',
            onPressed: _canUndo ? () => _editorState.undoManager.undo() : null,
          ),
          IconButton(
            icon: const Icon(Icons.redo),
            tooltip: '다시 실행',
            onPressed: _canRedo ? () => _editorState.undoManager.redo() : null,
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: _isSaving
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(
                    Icons.cloud_done_outlined,
                    color: Color(0xFF8B7E74),
                  ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: AppFlowyEditor(
              editorState: _editorState,
              editorStyle: EditorStyle.mobile().copyWith(
                textStyleConfiguration: TextStyleConfiguration(
                  text: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 16),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              blockComponentBuilders: _buildComponentBuilders(),
            ),
          ),
          // 모바일에서만 툴바 표시
          if (_isMobile)
            MobileToolbar(
              editorState: _editorState,
              toolbarItems: [
                textDecorationMobileToolbarItem, // Bold, Italic, Underline
                headingMobileToolbarItem,         // H1, H2, H3
                todoListMobileToolbarItem,        // 체크박스
                listMobileToolbarItem,            // 불릿/번호 리스트
                linkMobileToolbarItem,            // 링크
                dividerMobileToolbarItem,         // 구분선
                codeMobileToolbarItem,            // 코드블록
                _imagePickerToolbarItem,          // 사진 첨부
              ],
            ),
        ],
      ),
    );
  }
}
