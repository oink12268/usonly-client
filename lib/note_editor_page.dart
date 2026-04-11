import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_quill/flutter_quill.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:image_picker/image_picker.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:http/http.dart' as http;
import 'api_client.dart';
import 'api_endpoints.dart';
import 'note_page.dart';
import 'google_calendar_service.dart';

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

  // ValueNotifier로 UI 상태 관리 → setState 없이 AppBar만 갱신 (한글 IME 조합 보호)
  final ValueNotifier<bool> _isSaving = ValueNotifier(false);
  final ValueNotifier<bool> _hasUnsavedChanges = ValueNotifier(false);
  final ValueNotifier<bool> _isExtractingSchedule = ValueNotifier(false);
  final ValueNotifier<int> _pendingUploads = ValueNotifier(0);

  String? _lastSavedContent;
  String? _lastSavedTitle;
  bool _applyingLink = false;
  late bool _isPrivate;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.note['title'] ?? '');
    _isPrivate = widget.note['isPrivate'] as bool? ?? false;

    final content = widget.note['content'] as String? ?? '';
    _controller = QuillController(
      document: _buildDocument(content),
      selection: const TextSelection.collapsed(offset: 0),
    );

    // 변환된 Delta JSON 기준으로 비교 (불필요한 자동저장 방지)
    _lastSavedContent = _getContent();
    _lastSavedTitle = widget.note['title'] ?? '';

    _controller.addListener(() {
      if (!_hasUnsavedChanges.value) _hasUnsavedChanges.value = true;
      _autoLinkUrl();
    });
    _titleController.addListener(() {
      if (!_hasUnsavedChanges.value) _hasUnsavedChanges.value = true;
    });
  }

  /// 커서 앞 단어가 http/https URL이면 자동으로 링크 속성 적용
  void _autoLinkUrl() {
    if (_applyingLink) return;

    final selection = _controller.selection;
    if (!selection.isCollapsed) return;

    final offset = selection.baseOffset;
    if (offset < 8) return; // 최소 'http://' 길이

    final text = _controller.document.toPlainText();
    if (offset > text.length) return;

    // 공백/개행 다음에만 트리거 (단어가 끝났을 때)
    final charBefore = text[offset - 1];
    if (charBefore != ' ' && charBefore != '\n') return;

    // 커서 바로 앞 단어 추출
    final textBefore = text.substring(0, offset - 1);
    final lastDelim = textBefore.lastIndexOf(RegExp(r'[ \n]'));
    final wordStart = lastDelim + 1;
    final word = textBefore.substring(wordStart);

    if (!word.startsWith('http://') && !word.startsWith('https://')) return;

    // 이미 링크 속성이 있으면 중복 적용 방지
    final style = _controller.document.collectStyle(wordStart, word.length);
    if (style.containsKey('link')) return;

    debugPrint('[autoLink] applying link: $word at $wordStart len=${word.length}');
    _applyingLink = true;
    _controller.formatText(wordStart, word.length, LinkAttribute(word));
    _applyingLink = false;
    debugPrint('[autoLink] done. delta: ${_getContent().substring(0, 100)}');
  }

  /// 저장된 내용 로드:
  /// 1. Delta JSON (flutter_quill 형식) → 그대로 파싱
  /// 2. AppFlowy 마크다운 → heading/list 구조 보존 변환
  Document _buildDocument(String content) {
    if (content.isEmpty) return Document();

    // Delta JSON 형식 (이전 flutter_quill 저장본 호환)
    if (content.trimLeft().startsWith('[')) {
      try {
        return Document.fromJson(jsonDecode(content) as List);
      } catch (_) {}
    }
    // 이후는 마크다운 (AppFlowy 저장본 or 신규 저장본) → 아래에서 파싱

    // 마크다운 → Quill Delta JSON ops 변환 (Delta 클래스 없이 raw JSON 사용)
    final ops = <Map<String, dynamic>>[];
    for (final line in content.split('\n')) {
      if (line.startsWith('### ')) {
        ops.add({'insert': _stripInline(line.substring(4))});
        ops.add({'insert': '\n', 'attributes': {'header': 3}});
      } else if (line.startsWith('## ')) {
        ops.add({'insert': _stripInline(line.substring(3))});
        ops.add({'insert': '\n', 'attributes': {'header': 2}});
      } else if (line.startsWith('# ')) {
        ops.add({'insert': _stripInline(line.substring(2))});
        ops.add({'insert': '\n', 'attributes': {'header': 1}});
      } else if (line.startsWith('- [x] ')) {
        ops.add({'insert': _stripInline(line.substring(6))});
        ops.add({'insert': '\n', 'attributes': {'list': 'checked'}});
      } else if (line.startsWith('- [ ] ')) {
        ops.add({'insert': _stripInline(line.substring(6))});
        ops.add({'insert': '\n', 'attributes': {'list': 'unchecked'}});
      } else if (line.startsWith('- ') || line.startsWith('* ')) {
        ops.add({'insert': _stripInline(line.substring(2))});
        ops.add({'insert': '\n', 'attributes': {'list': 'bullet'}});
      } else if (RegExp(r'^\d+\. ').hasMatch(line)) {
        ops.add({'insert': _stripInline(line.replaceFirst(RegExp(r'^\d+\. '), ''))});
        ops.add({'insert': '\n', 'attributes': {'list': 'ordered'}});
      } else if (line.startsWith('![')) {
        final match = RegExp(r'!\[.*?\]\((.+?)\)').firstMatch(line);
        if (match != null) {
          ops.add({'insert': <String, dynamic>{'image': match.group(1)!}});
        }
        ops.add({'insert': '\n'});
      } else {
        ops.add({'insert': _stripInline(line)});
        ops.add({'insert': '\n'});
      }
    }

    try {
      return Document.fromJson(ops);
    } catch (_) {
      return Document()..insert(0, content);
    }
  }

  /// 인라인 마크다운 기호 제거 (**bold**, *italic*, `code`, [link](url))
  String _stripInline(String text) {
    return text
        .replaceAllMapped(RegExp(r'\*\*(.+?)\*\*'), (m) => m.group(1)!)
        .replaceAllMapped(RegExp(r'\*(.+?)\*'), (m) => m.group(1)!)
        .replaceAllMapped(RegExp(r'`(.+?)`'), (m) => m.group(1)!)
        .replaceAllMapped(RegExp(r'\[(.+?)\]\(.+?\)'), (m) => m.group(1)!);
  }


  // Delta JSON으로 저장 (링크·볼드·이탤릭 등 모든 속성 보존)
  String _getContent() {
    return jsonEncode(_controller.document.toDelta().toJson());
  }

  // 일정 추출 등 순수 텍스트만 필요할 때
  String _getPlainText() {
    return _controller.document.toPlainText().trim();
  }

  Future<void> _pickAndInsertImage() async {
    final xFile = await ImagePicker().pickImage(source: ImageSource.gallery, imageQuality: 50);
    if (xFile == null) return;

    if (mounted) _pendingUploads.value++;
    try {
      final bytes = await File(xFile.path).readAsBytes();
      final filename = xFile.path.split('/').last;

      final request = http.MultipartRequest(
        'POST',
        Uri.parse(ApiEndpoints.noteImage),
      );
      request.files.add(http.MultipartFile.fromBytes('file', bytes, filename: filename));

      final response = await ApiClient.sendMultipart(request);
      if (response.statusCode == 200) {
        final data = jsonDecode(await response.stream.bytesToString());
        final serverUrl = data['imageUrl'] as String;

        final offset = _controller.selection.baseOffset;
        final safeOffset = offset < 0 ? _controller.document.length - 1 : offset;
        _controller.replaceText(safeOffset, 0, BlockEmbed.image(serverUrl), null);

        await _saveInternal();
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('이미지 업로드에 실패했습니다. 다시 시도해주세요.')),
          );
        }
      }
    } catch (e) {
      debugPrint('이미지 업로드 에러: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('이미지 업로드에 실패했습니다. 다시 시도해주세요.')),
        );
      }
    } finally {
      if (mounted) _pendingUploads.value--;
    }
  }

  Future<void> _save() async {
    if (_pendingUploads.value > 0) {
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
    if (_isSaving.value) return;
    final content = _getContent();
    final title = _titleController.text;
    if (content == _lastSavedContent && title == _lastSavedTitle) {
      _hasUnsavedChanges.value = false;
      return;
    }
    _isSaving.value = true;
    try {
      await ApiClient.put(
        Uri.parse(ApiEndpoints.noteById(widget.note['id'])),
        body: jsonEncode({'title': title, 'content': content, 'isPrivate': _isPrivate}),
      );
      _lastSavedContent = content;
      _lastSavedTitle = title;
      _hasUnsavedChanges.value = false;
    } catch (e) {
      debugPrint('메모 저장 에러: $e');
    } finally {
      _isSaving.value = false;
    }
  }

  Future<void> _forceSave() async {
    final content = _getContent();
    final title = _titleController.text;
    debugPrint('[forceSave] content starts: ${content.substring(0, content.length.clamp(0, 80))}');
    debugPrint('[forceSave] changed: ${content != _lastSavedContent}');
    if (content == _lastSavedContent && title == _lastSavedTitle) return;
    try {
      final res = await ApiClient.put(
        Uri.parse(ApiEndpoints.noteById(widget.note['id'])),
        body: jsonEncode({'title': title, 'content': content, 'isPrivate': _isPrivate}),
      );
      debugPrint('[forceSave] status: ${res.statusCode}');
      _lastSavedContent = content;
      _lastSavedTitle = title;
    } catch (e) {
      debugPrint('노트 강제 저장 오류: $e');
    }
  }

  Future<void> _extractAndSaveToCalendar() async {
    final plainText = _getPlainText();
    if (plainText.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('메모 내용이 없습니다.')),
      );
      return;
    }

    _isExtractingSchedule.value = true;
    try {
      final response = await ApiClient.post(
        Uri.parse(ApiEndpoints.noteExtractSchedule),
        body: jsonEncode({'content': plainText}),
      );

      if (!mounted) return;

      if (response.statusCode == 204) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('메모에서 일정을 찾지 못했습니다.')),
        );
        return;
      }

      if (response.statusCode != 200) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('일정 추출에 실패했습니다.')),
        );
        return;
      }

      final events = (jsonDecode(response.body) as List).cast<Map<String, dynamic>>();
      await _showScheduleListDialog(events);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('오류가 발생했습니다: $e')),
      );
    } finally {
      if (mounted) _isExtractingSchedule.value = false;
    }
  }

  Future<void> _showScheduleListDialog(List<Map<String, dynamic>> events) async {
    final titleCtrls = events.map((e) => TextEditingController(text: e['title'] as String? ?? '')).toList();
    final descCtrls = events.map((e) => TextEditingController(text: e['description'] as String? ?? '')).toList();
    final dates = events.map((e) {
      final d = e['date'] as String?;
      return (d != null && d.isNotEmpty) ? DateTime.tryParse(d) : null;
    }).toList();
    final startTimes = events.map((e) {
      final t = e['startTime'] as String?;
      return (t != null && t.isNotEmpty) ? t : null;
    }).toList();
    final endTimes = events.map((e) {
      final t = e['endTime'] as String?;
      return (t != null && t.isNotEmpty) ? t : null;
    }).toList();
    final locations = events.map((e) {
      final t = e['location'] as String?;
      return (t != null && t.isNotEmpty) ? t : null;
    }).toList();

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.auto_awesome, size: 20),
              SizedBox(width: 8),
              Text('AI 추출 일정'),
            ],
          ),
          content: SizedBox(
            width: double.maxFinite,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: List.generate(events.length, (i) => _buildEventCard(
                  ctx, setDialogState, i, titleCtrls[i], descCtrls[i], dates,
                )),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('취소'),
            ),
            FilledButton(
              onPressed: () async {
                Navigator.pop(ctx);
                int saved = 0;
                for (int i = 0; i < events.length; i++) {
                  final title = titleCtrls[i].text.trim();
                  final date = dates[i];
                  if (title.isEmpty || date == null) continue;
                  final desc = descCtrls[i].text.trim();
                  final id = await GoogleCalendarService().createEvent(
                    title, date,
                    memo: desc.isEmpty ? null : desc,
                    startTime: startTimes[i],
                    endTime: endTimes[i],
                    location: locations[i],
                  );
                  if (id != null) saved++;
                }
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(saved > 0
                      ? '구글 캘린더에 $saved개 일정이 저장되었습니다!'
                      : '날짜를 입력해야 저장할 수 있습니다.')),
                );
              },
              child: const Text('전체 저장'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEventCard(
    BuildContext ctx,
    StateSetter setDialogState,
    int i,
    TextEditingController titleCtrl,
    TextEditingController descCtrl,
    List<DateTime?> dates,
  ) {
    final date = dates[i];
    final dateStr = date != null
        ? '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}'
        : '날짜 선택 필요';

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: titleCtrl,
              decoration: const InputDecoration(labelText: '일정 제목', isDense: true),
            ),
            const SizedBox(height: 8),
            InkWell(
              onTap: () async {
                final picked = await showDatePicker(
                  context: ctx,
                  initialDate: dates[i] ?? DateTime.now(),
                  firstDate: DateTime(2020),
                  lastDate: DateTime(2035),
                );
                if (picked != null) setDialogState(() => dates[i] = picked);
              },
              child: InputDecorator(
                decoration: InputDecoration(
                  labelText: '날짜',
                  isDense: true,
                  suffixIcon: date == null
                      ? const Icon(Icons.warning_amber, color: Colors.orange, size: 18)
                      : null,
                ),
                child: Text(
                  dateStr,
                  style: TextStyle(color: date == null ? Colors.orange : null),
                ),
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: descCtrl,
              decoration: const InputDecoration(labelText: '설명 (선택)', isDense: true),
              maxLines: 2,
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _titleController.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    _isSaving.dispose();
    _hasUnsavedChanges.dispose();
    _isExtractingSchedule.dispose();
    _pendingUploads.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop) return;
        await _forceSave();
        if (mounted) Navigator.pop(context);
      },
      child: Scaffold(
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
          StatefulBuilder(
            builder: (context, setIconState) => IconButton(
              icon: Icon(_isPrivate ? Icons.lock : Icons.lock_open),
              tooltip: _isPrivate ? '나만 보기 (탭하여 해제)' : '공개 (탭하여 나만 보기)',
              color: _isPrivate ? Theme.of(context).colorScheme.primary : null,
              onPressed: () {
                setIconState(() => _isPrivate = !_isPrivate);
                _hasUnsavedChanges.value = true;
                _forceSave();
              },
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: _isExtractingSchedule,
            builder: (_, extracting, __) => extracting
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  )
                : IconButton(
                    icon: const Icon(Icons.auto_awesome),
                    tooltip: 'AI로 구글 캘린더에 저장',
                    onPressed: _extractAndSaveToCalendar,
                  ),
          ),
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
                    parentTitle: _titleController.text.isEmpty ? '(제목 없음)' : _titleController.text,
                  ),
                ),
              );
            },
          ),
          ValueListenableBuilder<bool>(
            valueListenable: _isSaving,
            builder: (_, saving, __) => ValueListenableBuilder<int>(
              valueListenable: _pendingUploads,
              builder: (_, uploads, __) {
                if (saving || uploads > 0) {
                  return const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
                  );
                }
                return ValueListenableBuilder<bool>(
                  valueListenable: _hasUnsavedChanges,
                  builder: (_, unsaved, __) => IconButton(
                    icon: Icon(
                      unsaved ? Icons.save : Icons.cloud_done_outlined,
                      color: unsaved ? Theme.of(context).colorScheme.primary : Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    tooltip: unsaved ? '저장' : '저장됨',
                    onPressed: unsaved ? _save : null,
                  ),
                );
              },
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: QuillEditor(
              controller: _controller,
              focusNode: _focusNode,
              scrollController: _scrollController,
              config: QuillEditorConfig(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                placeholder: '내용을 입력하세요...',
                textCapitalization: TextCapitalization.none,
                characterShortcutEvents: standardCharactersShortcutEvents,
                spaceShortcutEvents: standardSpaceShorcutEvents,
                onLaunchUrl: (url) async {
                  final uri = Uri.tryParse(url);
                  if (uri != null && await canLaunchUrl(uri)) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                },
                customRecognizerBuilder: (attribute, leaf) {
                  if (attribute.key == Attribute.link.key && attribute.value != null) {
                    final url = attribute.value as String;
                    return TapGestureRecognizer()
                      ..onTap = () async {
                        final uri = Uri.tryParse(url);
                        if (uri != null && await canLaunchUrl(uri)) {
                          await launchUrl(uri, mode: LaunchMode.externalApplication);
                        }
                      };
                  }
                  return null;
                },
                embedBuilders: [NoteImageEmbedBuilder()],
              ),
            ),
          ),
          const Divider(height: 1),
          QuillSimpleToolbar(
            controller: _controller,
            config: QuillSimpleToolbarConfig(
              multiRowsDisplay: false,
              iconTheme: QuillIconTheme(
                iconButtonUnselectedData: IconButtonData(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7)),
                iconButtonSelectedData: IconButtonData(color: Theme.of(context).colorScheme.primary),
              ),
              showFontFamily: false,
              showFontSize: false,
              showStrikeThrough: false,
              showInlineCode: false,
              showColorButton: false,
              showBackgroundColorButton: false,
              showClearFormat: false,
              showAlignmentButtons: false,
              showCodeBlock: false,
              showQuote: false,
              showIndent: false,
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
        ],
      ),
    ), // Scaffold
    ); // PopScope
  }
}

/// 서버 이미지 URL → CachedNetworkImage / 로컬 파일 미리보기
class NoteImageEmbedBuilder extends EmbedBuilder {
  @override
  String get key => BlockEmbed.imageType;

  @override
  bool get expanded => false;

  @override
  Widget build(BuildContext context, EmbedContext embedContext) {
    final imageUrl = embedContext.node.value.data as String;
    if (imageUrl.startsWith('http')) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: CachedNetworkImage(
          imageUrl: imageUrl,
          fit: BoxFit.contain,
          placeholder: (context, url) => const Center(child: CircularProgressIndicator()),
          errorWidget: (context, url, error) => const Icon(Icons.broken_image, size: 48),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Image.file(File(imageUrl), fit: BoxFit.contain),
    );
  }
}
