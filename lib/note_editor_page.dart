import 'package:flutter/material.dart';
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
      document = markdownToDocument(content);
    } catch (_) {
      document = Document.blank();
    }

    _editorState = EditorState(document: document);
    _lastSavedContent = content;
    _lastSavedTitle = widget.note['title'] ?? '';

    _editorState.transactionStream.listen((event) {
      if (event.$1 == TransactionTime.after) {
        if (mounted && !_hasUnsavedChanges) {
          setState(() => _hasUnsavedChanges = true);
        }
        _handleImageUpload(event.$2);
      }
    });

    _titleController.addListener(() {
      if (mounted && !_hasUnsavedChanges) {
        setState(() => _hasUnsavedChanges = true);
      }
    });
  }

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
      }
    } catch (e) {
      debugPrint('이미지 업로드 에러: $e');
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
    final content = _getMarkdown();
    final title = _titleController.text;
    if (content == _lastSavedContent && title == _lastSavedTitle) return;
    try {
      await ApiClient.put(
        Uri.parse('${ApiConfig.baseUrl}/api/notes/${widget.note['id']}'),
        body: jsonEncode({'title': title, 'content': content}),
      );
    } catch (e) {
      debugPrint('노트 강제 저장 오류: $e');
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _editorState.dispose();
    super.dispose();
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
            ],
          ),
        ],
      ),
    );
  }

}
