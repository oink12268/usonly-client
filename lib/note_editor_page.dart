import 'package:flutter/material.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
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
  late QuillController _controller;
  late TextEditingController _titleController;
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();

  bool _isSaving = false;
  bool _hasUnsavedChanges = false;
  int _pendingUploads = 0;
  String? _lastSavedContent;
  String? _lastSavedTitle;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.note['title'] ?? '');

    // 저장된 내용 로드: Delta JSON → 실패하면 일반 텍스트로 처리 (구버전 마크다운 노트)
    final content = widget.note['content'] as String? ?? '';
    Document doc;
    try {
      if (content.trim().startsWith('[') || content.trim().startsWith('{')) {
        final deltaJson = jsonDecode(content) as List;
        doc = Document.fromJson(deltaJson);
      } else if (content.trim().isNotEmpty) {
        // 구버전 마크다운 → 평문으로 표시
        doc = Document()..insert(0, content);
      } else {
        doc = Document();
      }
    } catch (_) {
      doc = Document();
    }

    _controller = QuillController(
      document: doc,
      selection: const TextSelection.collapsed(offset: 0),
    );

    _lastSavedContent = _getContentJson();
    _lastSavedTitle = widget.note['title'] ?? '';

    _controller.addListener(() {
      if (mounted && !_hasUnsavedChanges) {
        setState(() => _hasUnsavedChanges = true);
      }
    });
    _titleController.addListener(() {
      if (mounted && !_hasUnsavedChanges) {
        setState(() => _hasUnsavedChanges = true);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _titleController.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  String _getContentJson() {
    return jsonEncode(_controller.document.toDelta().toJson());
  }

  // 갤러리에서 사진 선택 → 서버 업로드 → 에디터에 삽입
  Future<void> _pickAndInsertImage() async {
    final xFile = await ImagePicker().pickImage(source: ImageSource.gallery);
    if (xFile == null) return;

    if (mounted) setState(() => _pendingUploads++);
    try {
      final bytes = await File(xFile.path).readAsBytes();
      final filename = xFile.path.split('/').last;

      final request = http.MultipartRequest(
        'POST',
        Uri.parse('${ApiConfig.baseUrl}/api/notes/image'),
      );
      request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));

      final response = await ApiClient.sendMultipart(request);
      if (response.statusCode == 200) {
        final data = jsonDecode(await response.stream.bytesToString());
        final serverUrl = data['imageUrl'] as String;

        // 현재 커서 위치에 이미지 삽입
        final offset = _controller.selection.baseOffset;
        final safeOffset = offset < 0 ? _controller.document.length - 1 : offset;
        _controller.replaceText(safeOffset, 0, BlockEmbed.image(serverUrl), null);

        // 이미지 삽입 후 자동 저장 (서버 URL 반영)
        await _saveInternal();
      }
    } catch (e) {
      debugPrint('이미지 업로드 에러: $e');
    } finally {
      if (mounted) setState(() => _pendingUploads--);
    }
  }

  // 수동 저장 버튼
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
    final contentJson = _getContentJson();
    final title = _titleController.text;
    if (contentJson == _lastSavedContent && title == _lastSavedTitle) {
      if (mounted) setState(() => _hasUnsavedChanges = false);
      return;
    }
    if (mounted) setState(() => _isSaving = true);
    try {
      await ApiClient.put(
        Uri.parse('${ApiConfig.baseUrl}/api/notes/${widget.note['id']}'),
        body: jsonEncode({'title': title, 'content': contentJson}),
      );
      _lastSavedContent = contentJson;
      _lastSavedTitle = title;
      if (mounted) setState(() => _hasUnsavedChanges = false);
    } catch (e) {
      debugPrint('메모 저장 에러: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  // 뒤로가기 시 미저장 내용 강제 저장
  Future<void> _forceSave() async {
    final contentJson = _getContentJson();
    final title = _titleController.text;
    if (contentJson == _lastSavedContent && title == _lastSavedTitle) return;
    try {
      await ApiClient.put(
        Uri.parse('${ApiConfig.baseUrl}/api/notes/${widget.note['id']}'),
        body: jsonEncode({'title': title, 'content': contentJson}),
      );
    } catch (e) {
      debugPrint('노트 강제 저장 오류: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: true,
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
          // 서식 툴바
          QuillSimpleToolbar(
            controller: _controller,
            config: QuillSimpleToolbarConfig(
              multiRowsDisplay: false,
              showDividers: false,
              showFontFamily: false,
              showFontSize: false,
              showBoldButton: true,
              showItalicButton: true,
              showUnderLineButton: true,
              showStrikeThrough: false,
              showInlineCode: false,
              showColorButton: false,
              showBackgroundColorButton: false,
              showClearFormat: false,
              showAlignmentButtons: false,
              showHeaderStyle: true,
              showListNumbers: true,
              showListBullets: true,
              showListCheck: true,
              showCodeBlock: false,
              showQuote: false,
              showIndent: false,
              showLink: false,
              showUndo: true,
              showRedo: true,
              showSearchButton: false,
              showSubscript: false,
              showSuperscript: false,
              showClipboardCut: false,
              showClipboardCopy: false,
              showClipboardPaste: false,
              customButtons: [
                QuillToolbarCustomButtonOptions(
                  icon: const Icon(Icons.image_outlined),
                  tooltip: '사진 첨부',
                  onPressed: _pickAndInsertImage,
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          // 에디터 본문
          Expanded(
            child: QuillEditor(
              controller: _controller,
              focusNode: _focusNode,
              scrollController: _scrollController,
              config: QuillEditorConfig(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                placeholder: '내용을 입력하세요...',
                textCapitalization: TextCapitalization.none,
                embedBuilders: [NoteImageEmbedBuilder()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// 서버 이미지 URL → CachedNetworkImage로 표시
class NoteImageEmbedBuilder extends EmbedBuilder {
  @override
  String get key => BlockEmbed.imageType;

  @override
  bool get expanded => false;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final imageUrl = embedContext.node.value.data as String;
    // 로컬 경로면 File로, 서버 URL이면 CachedNetworkImage로
    if (imageUrl.startsWith('http')) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: CachedNetworkImage(
          imageUrl: imageUrl,
          fit: BoxFit.contain,
          placeholder: (context, url) =>
              const Center(child: CircularProgressIndicator()),
          errorWidget: (context, url, error) =>
              const Icon(Icons.broken_image, size: 48),
        ),
      );
    }
    // 업로드 전 로컬 파일 미리보기
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Image.file(File(imageUrl), fit: BoxFit.contain),
    );
  }
}
